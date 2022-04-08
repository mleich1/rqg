#!/bin/bash

# This shellscript is "Work in progress"
# Unpack the archive of some RQG test where the restart after intentional DB server crash failed
# and try the restart again with invocation of rr.
LANG=C

USAGE="\n$0 <BASEDIR1> <ARCHIVE>\n\n"
USAGE="$USAGE""    Purpose: Rerun an 'intentional crash + restart + check' scenario under 'rr'.\n"
USAGE="$USAGE""    1. Use the archive for reconstructing the situation just before the restart.\n"
USAGE="$USAGE""    2. Start a DB server (setup is roughly like the historic run) under 'rr'.\n"
USAGE="$USAGE""    3. Run mysqlcheck.\n"
USAGE="$USAGE""    4. Kill the DB server process.\n"
USAGE="$USAGE""    5. Make a backtrace based on the rr trace.\n\n"
USAGE="$USAGE""Use absolute paths.\n"
USAGE="$USAGE""<BASEDIR> should be some MariaDB install.\n"
USAGE="$USAGE""<ARCHIVE> should be the remains of some RQG test which failed in that scenario.\n"
USAGE="$USAGE""The current working directory needs to be the top directory of some RQG install.\n"
CALL_LINE="$0 $*"

RQG_DIR=$PWD
if [ ! -d $RQG_DIR/lib/GenTest ]
then
    echo "ERROR: Your current working directory is not the top directory of some RQG install."
    echo "Current working directory '$PWD'."
    echo -e $USAGE
    exit
fi

# Path to MariaDB binaries
BASEDIR1="$1"
if [ "$BASEDIR1" = "" ]
then
    echo "ERROR: You need to assign a basedir == path to MariaDB binaries like '/work/10.3/bld_asan'"
    echo "The call was ->$CALL_LINE<-"
    echo -e $USAGE
    exit
fi
if [ ! -d "$BASEDIR1" ]
then
    echo "ERROR: BASEDIR1 '$BASEDIR1' does not exist or is not a directory."
    echo "The call was ->$CALL_LINE<-"
    echo -e $USAGE
    exit
fi
BASEDIR1=`realpath "$BASEDIR1"`
echo "INFO: BASEDIR1 '$BASEDIR1'"

ARCHIVE="$2"
if [ "$ARCHIVE" = "" ]
then
    echo "ERROR: You need to assign an archive == path to some archive like '/data/results/1647347990/000437.tar.xz'"
    echo "The call was ->$CALL_LINE<-"
    echo -e $USAGE
    exit
fi
if [ ! -f "$ARCHIVE" ]
then
    echo "ERROR: ARCHIVE '$ARCHIVE' does not exist or is not a plain file."
    echo "The call was ->$CALL_LINE<-"
    echo -e $USAGE
    exit
fi
ARCHIVE=`realpath "$ARCHIVE"`
echo "INFO: ARCHIVE '$ARCHIVE'"

export RESTORE_DIR="/dev/shm/rqg/SINGLE_RUN"
# In case the RESTORE_DIR exists and a server is running on stuff located there than give up.
if [ -d "$RESTORE_DIR" ]
then
    VAL=`ps -elf | egrep "mysqld|mariadbd" | grep -v grep | grep $RESTORE_DIR`
    if [ "$VAL" != "" ]
    then
        echo "ERROR: Cannot proceed because DB servers are running around $RESTORE_DIR"
        ps -elf | egrep "mysqld|mariadbd" | grep -v grep | grep $RESTORE_DIR
        exit 1
    fi
fi
rm -rf "$RESTORE_DIR"
mkdir  "$RESTORE_DIR"
cd     "$RESTORE_DIR"
echo "INFO: RESTORE_DIR '$RESTORE_DIR'"
# $PWD is without trailing slash
tar xf $ARCHIVE
exit
set +e
COPY_DIR=`find "$PWD" -type d -name data_copy`
if [ "$COPY_DIR" = "" ]
then
    COPY_DIR=`find "$PWD" -type d -name data_backup`
    if [ "$COPY_DIR" = "" ]
    then
        echo "ERROR: Determining COPY_DIR failed"
        echo "ERROR: Is that really a RQG test with crash recovery?"
        exit 8
    fi
fi
echo "INFO: COPY_DIR '$COPY_DIR'"
rm -f "$COPY_DIR"/core*

# set +e
# killall -9 mysqld
# set -e

# Extract from the RQG log how the server gets startet
CMD_SNIP=`grep 'INFO: Starting MySQL ' "$RESTORE_DIR""/rqg.log" | tail -1 | sed -e "s/^.*: //g" -e "s/--core-file//g"` 
if [ "$CMD_SNIP" = "" ]
then
    echo "ERROR: Extracting the DB server start command from '$RESTORE_DIR/rqg.log' failed."
    exit
else
    : # echo "CMD_SNIP ->""$CMD_SNIP""<-"
fi
# Adjust to future storage places etc.
SOCKET_FILE="$PWD""/mysql.sock"
CMD_SNIP=$CMD_SNIP'"--tmpdir='"$PWD"'/tmp" "--port=16000" "--datadir='"$PWD"'/data" "--socket='"$SOCKET_FILE"'" "--pid-file='"$PWD"'/mysql.pid" "--general-log-file='"$PWD"'/mysql.log"'
# echo "CMD_SNIP ->""$CMD_SNIP""<-"

# Adjust to future start under rr etc.
CMD_SNIP1='rr record --wait --chaos --disable-cpuid-features-ext 0xfc230000,0x2c42,0xc --mark-stdio '$CMD_SNIP' "--innodb_use_native_aio=0"'
# echo "CMD_SNIP1 ->""$CMD_SNIP1""<-"

# Add to the historic server start adjustments to the new work directories                                                  !MODIFY the port number!
CMD_SNIP2=$CMD_SNIP
# echo "CMD_SNIP2 ->""$CMD_SNIP2""<-"

# Example
# ulimit -c 0; rr record --wait --chaos --disable-cpuid-features-ext 0xfc230000,0x2c42,0xc --mark-stdio "$BASEDIR/bin/mysqld" "--no-defaults" "--basedir=$BASEDIR" "--lc-messages-dir=$BASEDIR/share" "--character-sets-dir=$BASEDIR/share/charsets" "--tmpdir=$PWD/tmp" "--datadir=$PWD/data_copy" "--max-allowed-packet=128Mb" "--port=28340" "--socket=$PWD/mysql.sock" "--pid-file=$PWD/mysql.pid" "--general-log" "--general-log-file=$PWD/mysql.log" "--loose-innodb_lock_schedule_algorithm=fcfs" "--loose-idle_write_transaction_timeout=0" "--loose-idle_transaction_timeout=0" "--loose-idle_readonly_transaction_timeout=0" "--connect_timeout=60" "--interactive_timeout=28800" "--slave_net_timeout=60" "--net_read_timeout=30" "--net_write_timeout=60" "--loose-table_lock_wait_timeout=50" "--wait_timeout=28800" "--lock-wait-timeout=86400" "--innodb-lock-wait-timeout=50" "--log_output=none" "--log_bin_trust_function_creators=1" "--loose-debug_assert_on_not_freed_memory=0" "--plugin-load-add=file_key_management.so" "--loose-file-key-management-filename=/home/mleich/RQG_N/conf/mariadb/encryption_keys.txt" "--loose-innodb_fatal_semaphore_wait_threshold=300" "--loose-innodb_read_only_compressed=OFF" "--loose-innodb-sync-debug" "--innodb_stats_persistent=on" "--innodb_adaptive_hash_index=on" "--log-bin" "--sync-binlog=1" "--loose-innodb_evict_tables_on_commit_debug=off" "--loose-max-statement-time=30" "--innodb_use_native_aio=0" "--innodb_undo_tablespaces=3" "--innodb_undo_log_truncate=ON" "--innodb_rollback_on_timeout=OFF" "--innodb_page_size=32K" "--innodb-buffer-pool-size=25M" "--sql-mode=no_engine_substitution" "--loose-max-statement-time=0" &

function extract_pid()
{
    PID=`grep "mysqld .*starting as process" "$ERRORLOG" | sed -e 's/^.*starting as process *\(.*\) \.\.\./\1/g'`
    # echo "PID ->""$PID""<-"
}
function runs_pid()
{
    local PID=$1
    local VAL=`ps -p $1 | wc -l`
    if [ $VAL -gt 1 ]
    then
        echo "Pid $PID runs"
        echo 1
    else
        echo "Pid $PID is no more running"
        echo 0
    fi
}
function wait_till_pid_gone()
{
    local PID=$1
    NUM=20
    RUN=1
    echo -n "    "
    while [ $RUN ]
    do
        NUM=$(($NUM - 1))
        if [ $NUM -eq 0 ]
        then
            RUN=0
            break
        else
            echo -n "."
            sleep 1
            VAL=`runs_pid $PID | tail -1`
            if [ $VAL -eq 0 ]
            then
                RUN=0
                echo
                break
            fi
        fi
    done
    if [ $VAL -eq 1 ]
    then
        echo "WARN: The process $PID did not exit. Sending SIGKILL"
        kill -9 $PID
        exit
    else
        echo "INFO: The process $PID has exited."
    fi
}


LOOPS=100
LOOPS=2
while [ $LOOPS -gt 0 ]
do
    echo "---- Recover+Check LOOP""$LOOPS"" ----"
    LOOPS=$(($LOOPS - 1))
    MAKE_BACKTRACE=0

    rm -f "$PWD""/mysql.sock"
    rm -f "$PWD""/mysql.pid"
    rm -f "$PWD""/mysql.log"
    ERRORLOG="$PWD""/mysql.err"
    rm -f "$ERRORLOG"

    DATADIR="$PWD""/data"
    rm -rf "$DATADIR"

    TMPDIR="$PWD""/tmp"
    rm -rf "$TMPDIR"
    mkdir "$TMPDIR"

    export _RR_TRACE_DIR="$PWD""/rr"
    rm -rf "$_RR_TRACE_DIR"
    mkdir "$_RR_TRACE_DIR"

    cp -R "$COPY_DIR" "$DATADIR"
    # ls -ld "$COPY_DIR" "$DATADIR"

      eval $CMD_SNIP1 > "$ERRORLOG" 2>&1 &
    # eval $CMD_SNIP2 > "$ERRORLOG" 2>&1 &
    AUX_PID=$!
    if [ "$AUX_PID" = "" ]
    then
        echo "ERROR: No AUX_PID got."
        exit 4
    else
        echo "INFO: Auxiliary processs $AUX_PID started"
    fi
    RUNNING=`runs_pid $AUX_PID | tail -1`
    if [ $RUNNING -eq 0 ]
    then
        sleep 1
        echo "ERROR: Auxiliary process $AUX_PID is no more running. Abort"
        cat "$ERRORLOG"
        MAKE_BACKTRACE=1
        break
    fi

    # Wait till DB Server pid has shown up in server error log or timeout exceeded.
    echo "INFO: Wait till the DB server pid shows up in server error log or timeout exceeded."
    echo -n "    "
    NUM=20
    while [ $NUM -ge 0 ]
    do
        NUM=$(($NUM - 1))
        extract_pid
        if [ "$PID" != "" ]
        then
            break
        else
            echo -n "."
            sleep 1
        fi
    done
    echo
    if [ "$PID" = "" ]
    then
        echo "ERROR: No DB server pid found"
        cat "$ERRORLOG"
        MAKE_BACKTRACE=1
        break
    else
        echo "INFO: DB Server pid $PID"
        RUNNING=`runs_pid $PID | tail -1`
        if [ $RUNNING -eq 0 ]
        then
            sleep 1
            echo "ERROR: DB Server process $PID is no more running. Abort"
            cat "$ERRORLOG"
            MAKE_BACKTRACE=1
            break
        fi
    fi

    echo "INFO: Wait till DB Server is ready for connections or timeout exceeded."
    NUM=100;
    echo -n "    "
    while [ $NUM -ge 0 ]
    do
        NUM=$(($NUM - 1))
        VAL=`grep 'mysqld: ready for connections' "$ERRORLOG" | wc -l`
        if [ $VAL -gt 0 ]
        then
            # Just give a bit time for finishing whatever.
            sleep 3
            break
        fi
        RUNNING=`runs_pid $PID | tail -1`
        if [ $RUNNING -eq 0 ]
        then
            sleep 1
            echo "ERROR: DB Server process $PID is no more running. Abort"
            cat "$ERRORLOG"
            MAKE_BACKTRACE=1
            break
        fi
        echo -n "."
        sleep 1
    done
    echo

    if [ $VAL -eq 0 ]
    then
        echo "ALARM: DB Server is not ready for connections"
        cat "$ERRORLOG"
        MAKE_BACKTRACE=1
        break
    fi
    set +e
    MYSQLCHECK=$PWD/mysqlcheck.out
    $BASEDIR1/bin/mysqlcheck --user=root --socket="$SOCKET_FILE" --check --extended \
                             --all-databases 2>&1 > "$MYSQLCHECK"
    RC=$?
    set -e
    if [ $RC -ne 0 ]
    then
        echo "ALARM: DB Server checking failed with exit code $RC"
        sleep 3
        cat "$ERRORLOG"
        MAKE_BACKTRACE=1
        break
    fi
    NON_OK=`grep -iv ' ok$' "$MYSQLCHECK" | wc -l`
    if [ $NON_OK -gt 0 ]
    then
        echo "mysqlcheck wrote output lines without ok"
        echo "---- Output of mysqlcheck ----"
        cat "$MYSQLCHECK"
        echo "------------------------------"
                MAKE_BACKTRACE=1
        break
    fi
    RUNNING=`runs_pid $PID | tail -1`
    if [ $RUNNING -eq 0 ]
    then
        sleep 1
        echo "ERROR: DB Server process $PID is no more running. Abort"
        cat "$ERRORLOG"
        MAKE_BACKTRACE=1
        break
    fi
    if [ $MAKE_BACKTRACE -eq 0 ]
    then
        kill -9 $PID $AUX_PID
        sleep 3
    fi
done
if [ $MAKE_BACKTRACE -eq 0 ]
then
    echo "INFO: Nothing of interest found. Giving up"
    exit
fi

echo "INFO: Killing DB server process $PID with SIGABRT"
kill -6 $PID
echo "INFO: Waiting till the auxiliary process $AUX_PID has exited"
wait_till_pid_gone $AUX_PID
set +e
BACKTRACE="$PWD""/backtrace.out"
BACKTRACE_CFG="$RQG_DIR""/backtrace-rr.gdb"
_RR_TRACE_DIR="$_RR_TRACE_DIR" rr replay --mark-stdio >"$BACKTRACE" 2>/dev/null < "$BACKTRACE_CFG"
cat "$BACKTRACE"

echo
echo "==============================================================================="
echo
echo "INFO: DB Server error log '$ERRORLOG'"
echo "INFO: DB Server data dir  '$DATADIR' (already modified by restart attempt etc.)"
echo "INFO: Output of mysqlcheck shown above '$MYSQLCHECK'"
echo "INFO: Backtrace shown above '$BACKTRACE'"
echo "INFO: _RR_TRACE_DIR '$_RR_TRACE_DIR'"
echo
echo "INFO: How to repeat the rr replay interactive?"
echo
echo "_RR_TRACE_DIR='$_RR_TRACE_DIR' rr replay --mark-stdio"
exit

