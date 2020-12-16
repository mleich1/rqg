#!/bin/bash

# Please see this shell script rather as template how to call rqg.pl even though
# it might be already in its current state sufficient for doing a lot around RQG.
#

USAGE="USAGE: $0 <Basedir>"
CALL_LINE="$0 $*"

# killall -9 perl ; killall -9 mysqld ; rm -rf /dev/shm/var_*

set -e
RUNID=SINGLE_RQG
VARDIR="/dev/shm/vardir/""$RUNID"
rm -rf $VARDIR ;
mkdir -p $VARDIR
if [ ! -d $VARDIR ]
then
   echo "The attempt to create the VARDIR '$VARDIR' failed"
   exit
fi

# Prevent the traditional pollution of directories with remainings of
# historic, current and future RQG runs.
TMP="$VARDIR"
export TMP

WORKDIR="storage/""$RUNID"
rm -rf $WORKDIR
mkdir -p $WORKDIR
touch $WORKDIR/rqg.log
touch $WORKDIR/rqg.job
touch $WORKDIR/rqg_phase.init
touch $WORKDIR/rqg_verdict.init
set +e

# Path to MariaDB binaries
BASEDIR1="$1"
if [ "$BASEDIR1" = "" ]
then
   echo "You need to assign a basedir == path to MariaDB binaries like '/work/10.3/bld_asan'"
   echo "The call was ->$CALL_LINE<-"
   echo $USAGE
   exit
fi
if [ ! -d "$BASEDIR1" ]
then
   echo "BASEDIR1 '$BASEDIR1' does not exist."
   exit
fi
BASEDIR2="$2"
if [ "$BASEDIR2" != "" ]
then
   if [ ! -d "$BASEDIR1" ]
   then
      echo "BASEDIR2 '$BASEDIR2' does not exist."
      exit
   else
      BASEDIR2_SETTING="--basedir2=$BASEDIR2"
   fi
else
   BASEDIR2_SETTING=""
fi

YY_GRAMMAR="conf/mariadb/table_stress_innodb_nocopy.yy"
SQL_GRAMMAR="conf/mariadb/table_stress.sql"
ZZ_GRAMMAR="conf/mariadb/table_stress.zz"

export ASAN_OPTIONS=abort_on_error=1,disable_coredump=0

# Warning: Up till today my RQG version is not capable to work well with Galera.
export WSREP_PROVIDER=/usr/lib/libgalera_smm.so


if [ "$ZZ_GRAMMAR" = "" ]
then
   echo "You need to assign a zz grammar "
   echo "The call was ->$CALL_LINE<-"
   echo $USAGE
   exit
fi
if [ ! -e "$ZZ_GRAMMAR" ]
then
   echo "ZZ_GRAMMAR '$ZZ_GRAMMAR' does not exist."
   exit
fi
if [ "$YY_GRAMMAR" = "" ]
then
   echo "You need to assign a yy grammar "
   echo "The call was ->$CALL_LINE<-"
   echo $USAGE
   exit
fi
if [ ! -e "$YY_GRAMMAR" ]
then
   echo "YY_GRAMMAR '$YY_GRAMMAR' does not exist."
   exit
fi

perl  ./rqg.pl                                                                 \
--seed=random                                                                  \
--queries=1000000                                                              \
--reporter=ErrorLog,Backtrace,Deadlock1,None                                   \
--validator=None                                                               \
--sqltrace=MarkErrors                                                          \
--duration=300                                                                 \
--gendata="$ZZ_GRAMMAR"                                                        \
--gendata_sql="$SQL_GRAMMAR"                                                   \
--grammar="$YY_GRAMMAR"                                                        \
--basedir1="$BASEDIR1"/                                                        \
$BASEDIR2_SETTING                                                              \
--mysqld=--innodb_lock_schedule_algorithm=fcfs                                 \
--mysqld=--innodb_use_native_aio=1                                             \
--mysqld=--loose-idle_write_transaction_timeout=0                              \
--mysqld=--loose-idle_transaction_timeout=0                                    \
--mysqld=--loose-idle_readonly_transaction_timeout=0                           \
--mysqld=--connect_timeout=60                                                  \
--mysqld=--interactive_timeout=28800                                           \
--mysqld=--slave_net_timeout=60                                                \
--mysqld=--net_read_timeout=30                                                 \
--mysqld=--net_write_timeout=60                                                \
--mysqld=--loose-table_lock_wait_timeout=50                                    \
--mysqld=--wait_timeout=28800                                                  \
--mysqld=--lock-wait-timeout=86400                                             \
--mysqld=--innodb-lock-wait-timeout=50                                         \
--mysqld=--log-output=none                                                     \
--mysqld=--log-bin                                                             \
--mysqld=--log_bin_trust_function_creators=1                                   \
--mysqld=--loose-max-statement-time=30                                         \
--mysqld=--loose-debug_assert_on_not_freed_memory=0                            \
--engine=InnoDB                                                                \
--querytimeout=30                                                              \
--threads=10                                                                   \
--vardir="$VARDIR"                                                             \
--workdir="$WORKDIR"                                                           \
--mask-level=0                                                                 \
--mask=0                                                                       \
 > $WORKDIR/rqg.log 2>&1 &

sleep 3;
tail -f $WORKDIR/rqg.log

