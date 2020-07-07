#!/bin/bash

LANG=C
RQG_DIR=`pwd`

# set -x
set -e
set -o pipefail

CALL_LINE="$0 $*"


WRK_DIR=$1
if [ "$WRK_DIR" = "" ]
then
   echo "No RQG workdir was assigned."
   echo "The call was ->$CALL_LINE<-"
   echo "Therefore picking the default 'last_batch_workdir'."
#  echo -e "$USAGE"
   WRK_DIR="last_batch_workdir"
fi
if [ ! -d "$WRK_DIR" ]
then
   echo "The directory '$WRK_DIR' does not exist or is not a directory"
   echo "The call was ->$CALL_LINE<-"
#  echo -e "$USAGE"
   exit
fi

set -u

NUM_LOGS=`ls -ld "$WRK_DIR"/*.log | wc -l`
if [ $NUM_LOGS -eq 0 ]
then
   echo "The directory '$WRK_DIR' does not contain files ending with '.log'"
   exit
fi

set +e

NUM=`ls -d "$WRK_DIR"/RQG_Simplifier.cfg 2>/dev/null | wc -l`
if [ $NUM -gt 0 ]
then
    echo "The directory '$WRK_DIR' contains a Simplifier run"
    echo "== It is or was a test battery with decreasing complexity."
fi
for log_file in "$WRK_DIR"/*.log
do
    INFO=`perl verdict.pl --config=verdict_for_combinations.cfg --log_file="$log_file" 2>&1 \
          | egrep ' Verdict: ' | sed -e 's/^.* Verdict: .*, Extra_info: //g'`
    SLF=`basename $log_file`
    #^ignore_blacklist | STATUS_OK                              | --gendata=conf/engines/engine_stress.zz --views --grammar=conf/engines/engine_stress.yy --redefine=conf/mariadb/modules/locks.yy --redefine=conf/mariadb/modules/sql_mode.yy --reporters=Mariabackup_linux --mysqld=--innodb_use_native_aio=1 --mysqld=--innodb_stats_persistent=off --mysqld=--innodb_lock_schedule_algorithm=fcfs --mysqld=--loose-idle_write_transaction_timeout=0 --mysqld=--loose-idle_transaction_timeout=0 --mysqld=--loose-idle_readonly_transaction_timeout=0 --mysqld=--connect_timeout=60 --mysqld=--interactive_timeout=28800 --mysqld=--slave_net_timeout=60 --mysqld=--net_read_timeout=30 --mysqld=--net_write_timeout=60 --mysqld=--loose-table_lock_wait_timeout=50 --mysqld=--wait_timeout=28800 --mysqld=--lock-wait-timeout=86400 --mysqld=--innodb-lock-wait-timeout=50 --no-mask --queries=10000000 --duration=300 --seed=random --reporters=Backtrace --reporters=ErrorLog --reporters=Deadlock1 --validators=None --mysqld=--log_output=none --mysqld=--log-bin --mysqld=--log_bin_trust_function_creators=1 --mysqld=--loose-max-statement-time=30 --mysqld=--loose-debug_assert_on_not_freed_memory=0 --engine=InnoDB --restart_timeout=120 --threads=2 --mysqld=--innodb_page_size=8K --mysqld=--innodb-buffer-pool-size=8M --no_mask |   1207 | 001206.log
    SETUP=`grep $SLF "$WRK_DIR"/setup.txt | sed -e 's/^.* | S.* | \(--.*\)/| \1/g'`
    # echo "$INFO        $log_file  $SLF"
    echo "$INFO $SETUP"
done

