#!/bin/bash

##########################################################################################
######################### GLOBAL VARIABLES ###############################################
##########################################################################################
declare -i parentPID
declare -i parallel
declare -l fifo_child
declare -l fifo_parent
declare -l process_log

##########################################################################################
######################### SUB FUNCTIONS ##################################################
##########################################################################################

trap vv_exit INT TERM

function wait_for_task
{
   esc_out="\>"; esc_in="\<"; esc_pipe="\|"
   loc_child=$1
   shift
   loc_parameters=$@
   loc_parameters="${loc_parameters//\[\]/$loc_child}"
   loc_parameters="${loc_parameters//\|/ \|}"
   loc_parameters="${loc_parameters//\>/ \>}"
   loc_parameters="${loc_parameters//;/ ;}"

   ###################### REPLACE STDIN WITH CHILD FIFO ##################################
   exec 0< $fifo_child

   while :; do
      ################### LOCK THE PIPE AND WAIT FOR THE TASK ############################
      flock 0

      IFS= read line && {   flock -u 0
                            #[ $to_log -gt 0 ] && echo child $parentPID $line >> $process_log
                            [ "$line" = 'quit' ] && {   echo child_quit > $fifo_parent
                                                        [ $to_log -gt 0 ] && echo child QUIT $parentPID >> $process_log
                                                        break
                                                    }

                            ################### EXECUTE THE TASK #########################
#                            sleep 1
                            loc_command=()
                            for i in ${loc_parameters[@]}; do
                               [ -z "${i##*\{*}" ] && {   for j in ${line}; do
                                                             loc_command+=( "${i//\{\}/$j}" )
                                                          done
                                                      } || loc_command+=( $i )
                            done

                            eval ${loc_command[@]}
                            echo $? > $fifo_parent
                        }
   done

   ###################### RESET FD #######################################################
   exec 0<&-
}

function vv_exit
{
   i=1
   while [ $i -le $parallel ]; do
      ###################### SEND LAST MESSSAGE TO CHILD PROCESSES #######################
      [ $to_log -gt 0 ] && echo $parentPID I: $i PARALLEL: $parallel 'echo quit > $fifo_child' >> $process_log
      echo quit > $fifo_child
      ((i++))
   done

   [ $to_log -gt 0 ] && echo $parentPID before WAIT $parentPID >> $process_log
   wait

   ######################### CLEAN UP ####################################################
   [ $to_log -gt 0 ] && echo $parentPID before RM >> $process_log
   rm -f $fifo_child
   rm -f $fifo_parent
#   rm -f $process_log
   #echo Exiting...
   exit
}

function usage
{
   clear
   echo " "
   echo " "
   echo "$0 reads STDIN and opens 'parallel' number of child processes. Each child process will execute 'command' using provided list of parameters"
   echo " "
   echo "USAGE: $0 parallel [-p x -l] [command command_parameters...]"
   echo " "
   echo "   - parallel                     - (MANDATORY) Number of parallel processes"
   echo "   - -X x                         - (OPTIONAL) Multiple (i.e. x>=1) arguments with context replace. If {} is used multiple times each {} will be replaced with the arguments."
   echo "                                    If {} is used as part of a word then the whole word will be repeated."
   echo "   - -p x                         - (OPTIONAL) print progress to STDERR using modulo x (x>=1)"
   echo "   - -l                           - (OPTIONAL) set process log ON"
   echo "   - command                      - (OPTIONAL) command or script to be executed"
   echo "   - command_parameters...        - list of parameters expected by 'command'"
   echo "                                    {} (if used in a list of command parameters) in a run-time will be substituted with the \"line\" value read by parent and sent to child process"
   echo "                                    [] (if used in a list of command parameters) in a run-time will be substituted with the child ID"
   echo " "
   echo "   EXAMPLE: seq 100 | $0 3 echo Parameters passed to child#[] are: {}"
   echo "            The above command will generate a sequence of 100 numbers and call $0 with 3 parallel process, each child process will execute 'echo'"
   echo " "
   exit 1
}

##########################################################################################
######################### MAIN ###########################################################
##########################################################################################

######################### INITIALIZATION #################################################
parentPID=$$
fifo_child="/tmp/vv_child_fifo_$parentPID"
fifo_parent="/tmp/vv_parent_fifo_$parentPID"
process_log="/tmp/vv_process_log_$parentPID"

######################### PARSE PARAMETERS ###############################################
parallel=0; progress=0; progress_bar='.'; to_log=0; loc_xargs=1
while :; do
   [[ "$1" =~ "-X" ]] && {   shift
                             [ -z "${1##*[!0-9]*}" ] && usage || loc_xargs=$1
                             shift
                             continue
                         }
   [[ "$1" =~ "-p" ]] && {   [ ! -z "${1##-p}" ] && progress_bar="${1##-p}"
                             shift
                             [ -z "${1##*[!0-9]*}" ] && usage || progress=$1
                             shift
                             continue
                         }
   [ "$1" == "-l" ] && {   to_log=1
                           shift
                           continue
                       }

   [ $# -lt 1 -o -z "${1##*[!0-9]*}" ] || {   parallel=$1
                                              shift
                                              continue
                                          }
   break
done

[ $parallel -gt 0 ] || usage

[ $loc_xargs -gt 0 ] || loc_xargs=$parallel

[ $to_log -gt 0 ] && {   echo PARALLEL: $parallel >> $process_log
                         [ $progress -gt 0 ] && echo PROGRESS: $progress BAR: $progress_bar >> $process_log || echo NO PROGRESS >> $process_log
                         [[ ! -z "$@" ]] && echo COMMAND: $@ >> $process_log
                     }

######################### CREATE PARENT PIPE AND REDIRECT TO FD 3 ########################
mkfifo "$fifo_parent"
exec 3<> $fifo_parent
[ -p "$fifo_child" ] || mkfifo "$fifo_child"

######################### START $parallel NUMBER OF CHILD PROCESSES ######################
i=1
while [ $i -le $parallel ]; do
   wait_for_task $i $@ &
   ((i++))
done
child_number=$((i-1))

exec 4> $fifo_child

i=1; j=0; loc_seq_arr=(); loc_xargs_count=1
while IFS= read loc_seq; do

   ###################### SUPPORT FOR MULTIPLE ARGUMENTS #################################
   loc_seq_arr+=( $loc_seq )
   ((loc_xargs_count++))
   [ $loc_xargs_count -le $loc_xargs ] && continue

   [ $i -gt $parallel ] && {   while :; do
                                  ################### READ PARENT PIPE ###################
                                  IFS= read -u 3 line

                                  ################ CLEAN-UP IF REQUIRED AND QUIT #########
                                  [ "$line" = 'quit' ] && break

                                  if [ "$line" = 'more' ]; then
                                     ################ ADD NEW CHILD PROCESS ##############
                                     ((parallel++))
                                     ((child_number++))
                                     wait_for_task $i $@ &
                                     break
                                  elif [ "$line" = 'less' ]; then
                                     ################ REMOVE ONE CHILD PROCESS ###########
                                     echo quit > $fifo_child
                                     ((parallel--))
                                     [ $parallel -lt 1 ] && {   line="quit"
                                                                break
                                                            }
                                  else
                                     ((i--))
                                     break
                                  fi
                               done
                           }

   [ "$line" = 'quit' ] && break

   ###################### DISTRIBUTE TASKS TO CHILD PROCESSES ############################
   echo ${loc_seq_arr[@]} > $fifo_child
   loc_seq_arr=(); loc_xargs_count=1; ((i++)); ((j++))

   ###################### PRINT PROGRESS #################################################
   [ $progress -gt 1 ] && [ $(( $j % $progress )) -eq 0 ] && printf $j>&2 || [ $progress -gt 0 ] && printf $progress_bar>&2
done

######################### DISTRIBUTE REMAINING TASKS TO CHILD PROCESSES ##################
[ ${#loc_seq_arr[@]} -eq 0 ] || echo ${loc_seq_arr[@]} > $fifo_child

[ $progress -gt 0 ] && printf "%s\n" $j>&2

vv_exit
