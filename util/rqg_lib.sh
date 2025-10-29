#!/bin/bash
# Copyright (C) 2025 MariaDB plc
# Use is subject to license terms.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301
# USA

# Library with functions used in shell scripts for RQG testing campaigns managed
# by rqg_batch.pl

function set_combinator_usage()
{
    USAGE="USAGE: $0 <Config file for the RQG test Combinator> <Basedir1 == path to MariaDB binaries> [<Basedir2>]"
    EXAMPLE="EXAMPLE: $0 conf/mariadb/InnoDB_standard.cc /Server_bin/bb-10.2-marko_asan_Og "
    USAGE="\n$USAGE\n\n$EXAMPLE\n"
}

function set_simplifier_usage()
{
    USAGE="USAGE:   $0 <Config file for the RQG test Simplifier> <Basedir == path to MariaDB binaries> [<YY grammar>]"
    EXAMPLE="EXAMPLE: $0 simp_1.cfg /Server_bin/bb-10.2-marko_asan_Og table_stress.yy"
    USAGE="\n$USAGE\n\n$EXAMPLE\n"
}

function check_simplifier_config()
{
    if [ "$CONFIG" = "" ]
    then
        echo "You need to assign a config file for the RQG test Simplifier as first parameter."
        echo "The call was ->$CALL_LINE<-"
        echo -e "$USAGE"
        exit
    fi
    if [ ! -e "$CONFIG" ]
    then
       echo "The config file for the RQG test Simplifier '$CONFIG' does not exist."
       echo "The call was ->$CALL_LINE<-"
       echo -e "$USAGE"
       exit
    fi

    CASE0=`basename $CONFIG`
    CASE=`basename $CASE0 .cfg`
    if [ $CASE = $CASE0 ]
    then
        echo "You need to assign a Combinator config file (extension .cc)."
        echo "The call was ->$CALL_LINE<-"
        echo -e "$USAGE"
        exit
    fi
}

function check_combinator_config()
{
    if [ "$CONFIG" = "" ]
    then
        echo "You need to assign a config file for the RQG test Combinator as first parameter."
        echo "The call was ->$CALL_LINE<-"
        echo -e "$USAGE"
        exit
    fi
    if [ ! -e "$CONFIG" ]
    then
       echo "The config file for the RQG test Combinator '$CONFIG' does not exist."
       echo "The call was ->$CALL_LINE<-"
       echo -e "$USAGE"
       exit
    fi

    CASE0=`basename $CONFIG`
    CASE=`basename $CASE0 .cc`
    if [ $CASE = $CASE0 ]
    then
        echo "You need to assign a Combinator config file (extension .cc)."
        echo "The call was ->$CALL_LINE<-"
        echo -e "$USAGE"
        exit
    fi
}

function check_basedir1()
{
    if [ "$BASEDIR1" = "" ]
    then
        echo "You need to assign a basedir (path to MariaDB binaries) as second parameter."
        echo "The call was ->$CALL_LINE<-"
        echo -e "$USAGE"
        exit
    fi
    if [ ! -d "$BASEDIR1" ]
    then
        echo "BASEDIR1 '$BASEDIR1' does not exist or is not a directory."
        exit
    fi
}

function set_check_basedir2()
{
    if [ "$BASEDIR2" = "" ]
    then
        echo "Setting basedir2 = basedir1"
        BASEDIR2="$BASEDIR1"
    fi
    if [ ! -d "$BASEDIR2" ]
    then
        echo "BASEDIR2 '$BASEDIR2' does not exist or is not a directory."
        exit
    fi
}

function check_edit_optional_grammar()
{
    if [ "$GRAMMAR" != "" ]
    then
        if [ ! -f "$GRAMMAR" ]
        then
            echo "The RQG grammar '$GRAMMAR' does not exist or is not a plain file."
            echo "The call was ->$CALL_LINE<-"
            echo -e "$USAGE"
            exit
        else
            GRAMMAR_PART="--grammar=$GRAMMAR"
            vi "$GRAMMAR"
        fi
    else
        GRAMMAR_PART=""
    fi
}

function prevent_conflicts()
{
    # ----------------------------------------------------------------------------------------------
    # rqg_batch.pl (like mariadb-test-run.pl) not prepared to coexist with concurrent programs
    # using some MariaDB or MySQL server.
    # 1. There could happen clashes of tests runs on the same resources (vardir, ports, files etc.)
    # 2. There is in addition some serious increased likelihood that the current test campaign
    #    suffers sooner or later from important filesystems full etc.
    #
    # Testing tool | Programs                           | Standard locations
    # -------------+------------------------------------+----------------------------
    # rqg_batch.pl | perl, mariadbd, mysqld, rr, rqg.pl | /dev/shm/rqg*/* /data/rqg/*
    # -------------+------------------------------------+----------------------------
    # MTR          | perl, mariadbd, mysqld, rr,        | /dev/shm/var*
    #              | lib/My/SafeProcess/my_safe_process |
    #              | mtr, mariadb-test-run.pl           |
    #
    # A) The radical solution.
    #    Main disadvantages:
    #    - Other user running "rr replay" are affected.
    #    - Whatever process running "perl" is affected
    # sudo killall -9 perl mysqld mariadbd rr
    # sudo rm -rf /dev/shm/rqg*/* /dev/shm/var* /data/rqg/*
    #
    # B) Detect if there is some ongoing rqg_batch.pl or mysql-test-run.pl run.
    #    If yes than abort.
    #    Disadvantage: Its not a solution.
    #
    # All top-level/main programs of RQG and MTR get interpreted by perl.
    # Hence "-C perl" sorts out thinkable exotic stuff like "vi rqg.pl" of "vi perl rqg.pl".
    FOUND=0
    ps -o pid,user,command --no-headers -C perl | egrep -e ' perl .*rqg\.pl| perl .*rqg_batch\.pl' \
        > active_runs.tmp
    AR=`cat active_runs.tmp | wc -l`
    if [ $AR -gt 0 ]
    then
        FOUND=1
        echo "There seem to be already active RQG runs. Will not start because of that."
        cat active_runs.tmp
    fi
    ps -o pid,user,command --no-headers -C perl | \
        egrep -e ' perl .*mtr| perl .*mariadb-stress-test\.pl| perl .*mariadb-test-run\.pl| perl .*mysql-test-run\.pl' \
        > active_runs.tmp
    AR=`cat active_runs.tmp | wc -l`
    if [ $AR -gt 0 ]
    then
        FOUND=1
        echo "There seem to be already active MTR runs. Will not start because of that."
        cat active_runs.tmp
    fi
    ps -o pid,user,command --no-headers -C mariadbd,mysql > active_runs.tmp
    AR=`cat active_runs.tmp | wc -l`
    if [ $AR -gt 0 ]
    then
        FOUND=1
        echo "There seem to be already active DB server. Will not start because of that."
        cat active_runs.tmp
    fi
    rm active_runs.tmp
    if [ $FOUND -eq 1 ]
    then
        exit 4;
    fi
}

function set_parallel()
{
    # Go with heavy load in case the rqg_batch.pl ResourceControl allows it.
    # The rqg_batch.pl ResourceControl should be capable to avoid trouble with resources.
    # Per experience:
    # More general load on the testing box raises the likelihood to find or replay a
    # concurrency bug.
    NPROC=`nproc`
    GUEST_ON_BOX=`who | egrep -v "$USER|root" | wc -l`
    echo "Number of guests logged into the box: $GUEST_ON_BOX"
    # GUEST_ON_BOX=0
    if [ $GUEST_ON_BOX -gt 0 ]
    then
       # Colleagues are on the box and most probably running rr replay.
       # So do not raise the load too much.
       PARALLEL=$((8 * $NPROC / 10))
    else
       PARALLEL=$(($NPROC * 3))
    fi
    # If $PARALLEL > ~270 than we get trouble with some resources especially ports.
    if [ $PARALLEL -gt 270 ]
    then
       PARALLEL=270
    fi
}

function wait_for_protocol()
{
    STATE=2
    NUM=0
    while [ $STATE -eq 2 ]
    do
        sleep 0.1
        NUM=$(($NUM + 1))
    if [ $NUM -gt 20 ]
    then
        STATE=1
    fi
    if [ -f $PROT ]
    then
        STATE=0
    fi
    done

    if [ $STATE -eq 1 ]
    then
        echo "ERROR: Most probably in RQG mechanics or setup."
        echo "ERROR: The (expected) protocol file '$PROT' did not show up"
        exit 4
    fi

}

