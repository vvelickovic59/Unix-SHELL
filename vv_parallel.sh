#!/bin/bash

##########################################################################################
######################### GLOBAL VARIABLES ###############################################
##########################################################################################
declare -i parentPID
declare -l fifo_child
declare -l fifo_parent
declare -l process_log

##########################################################################################
######################### SUB FUNCTIONS ##################################################
##########################################################################################
function wait_for_task
{
   loc_child=$1
   shift

   ###################### REPLACE STDIN WITH CHILD FIFO ##################################
   exec 0< $fifo_child

   while :; do
      ################### LOCK THE PIPE AND WAIT FOR THE TASK ############################
      flock 0

      IFS= read line && {   flock -u 0
                            [ "$line" = 'quit' ] && {   echo child_quit > $fifo_parent
                                                        break
                                                    }

                            ################### EXECUTE THE TASK #########################
#                            sleep 1
                            loc_command="${@//\{\}/$line}"
                            loc_command="${loc_command[@]//\[\]/$loc_child}"
                            eval ${loc_command[@]}
                            echo $? > $fifo_parent
                        }
   done

   ###################### RESET FD #######################################################
   exec 0<&-
}

function usage
{
   clear
   echo " "
   echo " "
   echo "$0 reads STDIN and opens 'parallel' number of child processes. Each child process will execute 'command' using provided list of parameters"
   echo " "
   echo "USAGE: $0 parallel [-p x] [command command_parameters...]"
   echo " "
   echo "   - parallel                     - (MANDATORY) Number of parallel processes"
   echo "   - -p x                         - (OPTIONAL) print progress to STDOUT using modulo x (x>=1)"
   echo "   - command                      - (OPTIONAL) command or script to be executed"
   echo "   - command_parameters...        - list of parameters required for 'command'"
   echo "                                    {} (if used in a list of command parameters) in a run-time will be substituted with the \"line\" value read by parent and sent to child process"
   echo "                                    [] (if used in a list of command parameters) in a run-time will be substituted with the child ID"
   echo " "
   echo "   EXAMPLE: seq 100 | $0 3 echo Parameters passed to child: [] are: {}"
   echo "            The above command will generate a sequence of 100 numbers and call $0 with 3 parallel process, each child process will execute 'echo'"
   echo " "
   exit 1
}

##########################################################################################
######################### MAIN ###########################################################
##########################################################################################
progress=0; progress_bar='.'
[ $# -lt 1 -o -z "${1##*[!0-9]*}" ] && usage || parallel=$1
shift
[[ "$1" =~ "-p" ]] && {   [ ! -z "${1##-p}" ] && progress_bar="${1##-p}"
                          shift
                          [ -z "${1##*[!0-9]*}" ] && usage || progress=$1
                          shift
                      }

######################### INITIALIZATION #################################################
parentPID=$$
fifo_child="/tmp/vv_child_fifo_$parentPID"
fifo_parent="/tmp/vv_parent_fifo_$parentPID"
process_log="/tmp/vv_process_log_$parentPID"

######################### CREATE PARENT PIPE AND REDIRECT TO FD 3 ########################
mkfifo "$fifo_parent"
exec 3<> $fifo_parent
[ -p "$fifo_child" ] || mkfifo "$fifo_child"

i=1
while [ $i -le $parallel ]; do
   ###################### START $parallel NUMBER OF CHILD PROCESSES ######################
   wait_for_task $i $@ &
   ((i++))
done
child_number=$((i-1))

exec 4> $fifo_child

i=1; j=0
while IFS= read loc_seq; do
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
   echo "$loc_seq" > $fifo_child
   ((i++)); ((j++))
   [ $progress -gt 1 ] && [ $(( $j % $progress )) -eq 0 ] && printf $j || [ $progress -gt 0 ] && printf $progress_bar
done
[ $progress -gt 0 ] && printf $j

i=1
while [ $i -le $parallel ]; do
   ###################### SEND LAST MESSSAGE TO CHILD PROCESSES ##########################
   echo quit > $fifo_child
   ((i++))
done

wait
echo

######################### CLEAN UP #######################################################
rm -f $fifo_child
rm -f $fifo_parent
rm -f $process_log
#echo Exiting...

