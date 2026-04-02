#!/bin/bash

# Typical use case
# ----------------
# Run a specific RQG test
#
# Please see this shell script rather as template how to call rqg.pl even though
# it might be already in its current state sufficient for doing a lot around RQG.
#

export LANG=C
CALL_LINE="$0 $*"

USAGE="USAGE: $0 <Basedir1 == path to MariaDB binaries> [<Basedir2>]"

if [ ! -e "./util/rqg_lib.sh" ]
then
    echo "ERROR: The curren working directory '$PWD' does not contain some RQG install."
    echo "       The required file './util/rqg_lib.sh' was not found."
    exit 4
fi

set -e
source util/rqg_lib.sh

RQG_HOME=`pwd`

# Path to MariaDB binaries for first server
BASEDIR1="$1"
check_basedir1
BASEDIR1_NAME=`basename "$BASEDIR1"`

# Path to MariaDB binaries for second server if required
BASEDIR2="$2"
set_check_basedir2

SQL_GRAMMAR="conf/mariadb/table_stress.sql"
ZZ_GRAMMAR="conf/mariadb/table_stress.zz"
YY_GRAMMAR="conf/mariadb/table_stress_innodb_basic.yy"
if [ "$SQL_GRAMMAR" = "" ]
then
   echo "ERROR: You need to assign a sql grammar."
   echo "The call was ->$CALL_LINE<-"
   echo $USAGE
   exit
fi
if [ ! -e "$ZZ_GRAMMAR" ]
then
   echo "ERROR: SQL_GRAMMAR '$ZZ_GRAMMAR' does not exist."
   exit
fi
if [ "$ZZ_GRAMMAR" = "" ]
then
   echo "ERROR: You need to assign a zz grammar."
   echo "The call was ->$CALL_LINE<-"
   echo $USAGE
   exit
fi
if [ ! -e "$ZZ_GRAMMAR" ]
then
   echo "ERROR: ZZ_GRAMMAR '$ZZ_GRAMMAR' does not exist."
   exit
fi
if [ "$YY_GRAMMAR" = "" ]
then
   echo "ERROR: You need to assign a yy grammar."
   echo "The call was ->$CALL_LINE<-"
   echo $USAGE
   exit
fi
if [ ! -e "$YY_GRAMMAR" ]
then
   echo "ERROR: YY_GRAMMAR '$YY_GRAMMAR' does not exist."
   exit
fi

set +e
# Radical Cleanup
# killall -9 perl ; killall -9 mysqld mariadbd ;  killall -9 rr
# rm -rf /dev/shm/rqg*/* /dev/shm/var_* /data/rqg/*
#
# Check if there is already some running MariaDB or MySQL server or test
prevent_conflicts

RUNID=SINGLE_RUN

# Take care that we can get core files if running with ASAN
# ---------------------------------------------------------
# There should be at sufficient space for a few fat core files in the filesystem containing the
# VARDIR at any time. The rqg_batch.pl ResourceControl will also prevent a VARDIR full.
# If its not an ASAN build than this environment variable should be harmless anyway.
export ASAN_OPTIONS=abort_on_error=1,disable_coredump=0
echo "Have set "`env | grep ASAN`

# Warning: Up till today my RQG version is not capable to work well with Galera.
export WSREP_PROVIDER=/usr/lib/libgalera_smm.so

# Options (Hint: Please take care that there must be a '\' at line end.)
# ----------------------------------------------------------------------
# 1. Debugging of rqg.pl
#    Default: Minimal debug output.
#    Assigning '_all_' causes maximum debug output.
#    Warning: Significant more output of rqg.pl.
# --script_debug=_all_                                                 \
#
# 2. Use "rr" (https://github.com/mozilla/rr/wiki/Usage) for tracing DB
#    servers and other programs.
#
#    Ensure that "rr" will be invoked
# --rr='rr record --chaos --wait'                                      \
#    Ensure that "rr" will be not invoked
# --rr=''                                                              \
# or just remove the corresponding line from the call of rqg.pl.
#
# 3. SQL tracing within RQG (Client side tracing)
#    Trace SQL's sent to the DB server
# --sqltrace=Simple                                                    \
#    Trace SQL's sent to the DB server and its response (error code only)
# --sqltrace=MarkErrors                                                \
#


echo -e "$0: End of preparations. Will now start the test.\n\n"
perl -w ./rqg.pl                                                                              \
--minor_runid=SINGLE_RUN                                                                      \
--seed=random                                                                                 \
--queries=1000000                                                                             \
--reporter=ErrorLog,Deadlock,None                                                             \
--validator=None                                                                              \
--sqltrace=MarkErrors                                                                         \
--duration=300                                                                                \
--gendata="$ZZ_GRAMMAR"                                                                       \
--gendata_sql="$SQL_GRAMMAR"                                                                  \
--grammar="$YY_GRAMMAR"                                                                       \
--basedir1="$BASEDIR1"/                                                                       \
$BASEDIR2_SETTING                                                                             \
--mysqld=--innodb_lock_schedule_algorithm=fcfs                                                \
--mysqld=--innodb_use_native_aio=0                                                            \
--mysqld=--loose-idle_write_transaction_timeout=0                                             \
--mysqld=--loose-idle_transaction_timeout=0                                                   \
--mysqld=--loose-idle_readonly_transaction_timeout=0                                          \
--mysqld=--connect_timeout=60                                                                 \
--mysqld=--interactive_timeout=28800                                                          \
--mysqld=--slave_net_timeout=60                                                               \
--mysqld=--net_read_timeout=30                                                                \
--mysqld=--net_write_timeout=60                                                               \
--mysqld=--loose-table_lock_wait_timeout=50                                                   \
--mysqld=--wait_timeout=28800                                                                 \
--mysqld=--lock-wait-timeout=86400                                                            \
--mysqld=--innodb-lock-wait-timeout=50                                                        \
--mysqld=--log-output=none                                                                    \
--mysqld=--log-bin                                                                            \
--mysqld=--sync-binlog=1                                                                      \
--mysqld=--log_bin_trust_function_creators=1                                                  \
--mysqld=--loose-max-statement-time=30                                                        \
--mysqld=--loose-debug_assert_on_not_freed_memory=0                                           \
--engine=InnoDB                                                                               \
--mysqld=--plugin-load-add=file_key_management.so                                             \
--mysqld=--loose-file-key-management-filename="$RQG_HOME"/conf/mariadb/encryption_keys.txt    \
--querytimeout=30                                                                             \
--threads=10                                                                                  \
--vardir_type=fast                                                                            \
--rr="rr record --chaos --wait"                                                               \
--mask-level=0                                                                                \
--mask=0                                                                                      \
2>&1 | tee rqg.log


