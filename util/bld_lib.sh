#!/bin/bash
# Copyright (C) 2021 MariaDB Corporation Ab.
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

# Library with functions used during Build of MariaDB for use in InnoDB RQG testing

function set_parallel()
{
    if [ "$PARALLEL" = "" ]
    then
        PARALLEL=`nproc`
        echo "Setting PARALLEL to $PARALLEL"
    fi
    VAL=$(($PARALLEL + 1 - 1))
    if [ $PARALLEL != $VAL ]
    then
        echo "ERROR: The value ->$VAL<- assigned to PARALLEL seems to be not an INTEGER >= 0."
        echo
        echo "The call line was ->$CALL_LINE<-"
        echo
        echo -e $USAGE
        exit 4
    fi
    PARALLEL_M=$((PARALLEL + PARALLEL / 2))
    echo "Parallelization for"
    echo "- make        (variable PARALLEL_M): $PARALLEL_M"
    echo "- compression (variable PARALLEL):   $PARALLEL"
}

function set_comp_prog()
{
    # We use later tar and generate the compression option here.
    #   tar -c [-f ARCHIVE] [OPTIONS] [FILE...]
    #        --use-compress-program=COMMAND
    #
    #   tar -t ... and tar -x ... do not seem to need the --use-compress-program=... because
    #   tar simply detects if an archive was compressed with xz.
    #

    set +e
    type xz
    RC=$?
    set -e
    if [ $RC -eq 0 ]
    then
        COMP_PROG="xz -v -T $PARALLEL"
        SUFFIX="tar.xz"
        # The build gets usually started when no parallel testing happens. And so we have often
        # several up till many CPU cores.
        # Hence rise the compression with the number of cores assigned or calculated.i
        # But try to stay below 60s.
        if   [ $PARALLEL -lt 2 ]
        then
            COMP_PROG="$COMP_PROG"" -2"
        elif [ $PARALLEL -le 4 ]
        then
            COMP_PROG="$COMP_PROG"" -3"
        elif [ $PARALLEL -le 8 ]
        then
            COMP_PROG="$COMP_PROG"" -4"
        elif [ $PARALLEL -le 16 ]
        then
            COMP_PROG="$COMP_PROG"" -6"
        elif [ $PARALLEL -le 32 ]
        then
            COMP_PROG="$COMP_PROG"" -7"
        elif [ $PARALLEL -le 64 ]
        then
            COMP_PROG="$COMP_PROG"" -8"
        else
            COMP_PROG="$COMP_PROG"" -8"
        fi
        echo "Will use ->$COMP_PROG<- for compression"
    else
        echo "ERROR: Compression program 'xz' not found."
        exit 4
    fi
}

# In case one of the following environment variables is set than the corresponding
# directory must already exist.
# Variable               | Default
# -----------------------+--------------
# GENERAL_SOURCE_DIR     | /Server
# GENERAL_BIN_DIR        | /Server_bin
# GENERAL_STORE_DIR      | /data

function check_environment()
{
    # The code of these plugins gets pulled when cloning the tree.
    # The settings below will prevent pulling the changes on "git fetch".
    git config --global submodule.storage/rocksdb.update none
    git config --global submodule.storage/columnstore.update none
    git config --global submodule.storage/xpand.update none
    git config --global submodule.storage/spider.update none
    git config --global submodule.storage/mroonga.update none
    git config --global submodule.storage/connect.update none
    git config --global submodule.storage/sphinx.update none
    git config --global submodule.storage/oqgraph.update none
    git config --global submodule.storage/federated.update none
    git config --global submodule.storage/federatedx.update none
    git config --global submodule.storage/archive.update none
    MESSAGE_END="does not exist or is not a directory."
    if [ "$GENERAL_SOURCE_DIR" = "" ]
    then
        GENERAL_SOURCE_DIR="/Server"
    fi
    GENERAL_SOURCE_DIR=`realpath "$GENERAL_SOURCE_DIR"`
    if [ ! -d "$GENERAL_SOURCE_DIR" ]
    then
        echo "ERROR: The general source directory (variable GENERAL_SOURCE_DIR) '$GENERAL_SOURCE_DIR' $MESSAGE_END"
        echo
        echo -e $USAGE
        exit 16
    fi
    if [ "$GENERAL_BIN_DIR" = "" ]
    then
        GENERAL_BIN_DIR="/Server_bin"
    fi
    GENERAL_BIN_DIR=`realpath "$GENERAL_BIN_DIR"`
    if [ ! -d "$GENERAL_BIN_DIR" ]
    then
        echo "ERROR: The general DB bin directory (variable GENERAL_BIN_DIR) '$GENERAL_BIN_DIR' $MESSAGE_END"
        echo
        echo -e $USAGE
        exit 16
    fi
    if [ "$GENERAL_STORE_DIR" = "" ]
    then
        GENERAL_STORE_DIR="/data"
    fi
    GENERAL_WORK_DIR=`realpath "$GENERAL_STORE_DIR"`
    if [ ! -d "$GENERAL_STORE_DIR" ]
    then
        echo "ERROR: The general store directory (variable GENERAL_STORE_DIR ) '$GENERAL_STORE_DIR' $MESSAGE_END"
        echo
        echo -e $USAGE
        exit 16
    fi
    SOURCE_DIR="$GENERAL_SOURCE_DIR""/""$RELEASE"
    if [ ! -d "$GENERAL_SOURCE_DIR" ]
    then
        echo "ERROR: The source directory (variable SOURCE_DIR) '$SOURCE_DIR' $MESSAGE_END"
        echo
        echo -e $USAGE
        exit 16
    fi
    RQG_ARCH_DIR="$GENERAL_STORE_DIR""/binarchs"
    ls -ld $RQG_ARCH_DIR
    if [ ! -d "$RQG_ARCH_DIR" ]
    then
        set -e
        mkdir $RQG_ARCH_DIR
        set +e
    fi

    # Abort if its obvious not a source tree.
    STORAGE_DIR="$SOURCE_DIR""/storage"
    if [ ! -d "$STORAGE_DIR" ]
    then
        echo "No '$STORAGE_DIR' found. Is the current position '$SOURCE_DIR' really the root of a source tree?"
        echo
        echo -e $USAGE
        exit 16
    fi

    # One directory on tmpfs for all kinds of builds.
    # Thrown away and recreated for every build.
    # We build in 'out of source dir' style.
    OOS_DIR="/dev/shm/build_dir"
    if [ ! -d "$OOS_DIR" ]
    then
        echo "No '$OOS_DIR' found. Will create it"
        set -e
        mkdir "$OOS_DIR"
        set +e
    else
        echo "OOS_DIR '$OOS_DIR' found. Will drop and recreate it."
        set -e
        rm -rf "$OOS_DIR"
        mkdir "$OOS_DIR"
        set +e
    fi
    SRV_DIR="/dev/shm/srv_dir"
    if [ ! -d "$SRV_DIR" ]
    then
        echo "No '$SRV_DIR' found. Will create it"
        set -e
        mkdir "$SRV_DIR"
        set +e
    else
        echo "SRV_DIR '$SRV_DIR' found. Will drop and recreate it."
        set -e
        rm -rf "$OOS_DIR"
        mkdir "$OOS_DIR"
        set +e
    fi

    INSTALL_PREFIX="$GENERAL_BIN_DIR""/""$RELEASE""$BUILD_TYPE"

    BLD_PROT="$OOS_DIR""/build.prt"
    set -e
    rm -f "$BLD_PROT"
    touch "$BLD_PROT"
    set +e
}

function clean_source_dir()
{
    set -e
    cd "$SOURCE_DIR"
    # In case
    # - OOS_DIR is inside of SOURCE_DIR
    # and
    # - there was some previous 'in source' build in SOURCE_DIR
    # than wipe it to a significant extend.
    # Otherwise settings of that historic 'in source' build will influence our current build.
    set +e
    make clean
    set -e
    rm -f CMakeCache.txt
    # The following files are critical, might got sometimes manipulated without resetting.
    git checkout cmake/maintainer.cmake
    git checkout storage/innobase/innodb.cmake
    git checkout storage/innobase/CMakeLists.txt
    set +e
}

function run_make()
{
    set -e
    cd "$OOS_DIR"
    echo 'Environment dump -------------------- begin'                      | tee -a "$BLD_PROT"
    env | sort                                                              | tee -a "$BLD_PROT"
    echo 'Environment dump ---------------------- end'                      | tee -a "$BLD_PROT"
    START_TS=`date '+%s'`
    # nice -19 make -j $PARALLEL_M                                     2>&1   | tee -a "$BLD_PROT"
    nice -19 make -j $PARALLEL_M --trace                             2>&1   | tee -a "$BLD_PROT"
    END_TS=`date '+%s'`
    RUNTIME=$(($END_TS - $START_TS))
    echo -e "\nElapsed time for nice -19 make -j $PARALLEL: $RUNTIME\n"     | tee -a "$BLD_PROT"
    echo "#--------------------------------------------------------------"  | tee -a "$BLD_PROT"

    set +e
    ls -ld sql/mysqld                                                2>&1   | tee -a "$BLD_PROT"
    ls -ld sql/mariadbd                                              2>&1   | tee -a "$BLD_PROT"
    NUM=0
    LIST=' '
    if [ -e sql/mysqld ]
    then
        LIST="sql/mysqld "
        NUM=$((NUM + 1))
    fi
    if [ -e sql/mariadbd ]
    then
        LIST=$LIST"sql/mariadbd "
        NUM=$((NUM + 1))
    fi
    # echo "-->$LIST<--"

    set -e
    if [ $NUM -eq 0 ]
    then
        echo "ERROR: Neither sql/mysqld nor sql/mariadbd found"
        exit 8
    fi
}

function remove_some_tests()
{
    # Delete tests which
    # - are dedicated to plugins which I do not build
    # - I never use
    # ~ 46900KB uncompressed data
    set -e
    rm -f mysql-test/suite/s3
    rm -f mysql-test/plugin/spider
    rm -f mysql-test/plugin/rocksdb
    rm -f mysql-test/plugin/sphinx
    rm -f mysql-test/suite/federated
    rm -f mysql-test/plugin/connect
    set +e
}

function archiving()
{
    set -e
    echo "# Archiving of the installed release"                             | tee -a "$BLD_PROT"
    echo "#=============================================================="  | tee -a "$BLD_PROT"
    cd "$INSTALL_PREFIX"
    echo "INSTALL_PREFIX=$INSTALL_PREFIX"                                   | tee -a "$BLD_PROT"
    echo "Generating compressed archive with binaries (for use in RQG)"     | tee -a "$BLD_PROT"

    TARGET="$RQG_ARCH_DIR""/bin_arch.""$SUFFIX"
    TARGET_PRT="$RQG_ARCH_DIR""/bin_arch.prt"
    rm -f "$TARGET" "$TARGET_PRT"

    echo "    Will use ->$COMP_PROG<- for compression"                      | tee -a "$BLD_PROT"
    # Archives of trees with binaries serve
    # - for the rather rare case that we need to restore an old tree with binaries
    #   for running a rr replay.
    # - not for running MTR tests on some historic tree
    # Hence we can save space by removing all MTR tests.
    tar --use-compress-program="$COMP_PROG" --exclude="mysql-test"          \
                                            -cf "$TARGET" .          2>&1   | tee -a "$BLD_PROT"
    MD5SUM=`md5sum "$TARGET" | cut -f1 -d' '`
    echo "MD5SUM of archive: $MD5SUM"                                       | tee -a "$BLD_PROT"
    DATE=`date -u +%s`
    echo "The archive of the release before renaming"                       | tee -a "$BLD_PROT"
    ls -ld "$TARGET"                                                 2>&1   | tee -a "$BLD_PROT"
    echo "BASENAME of the archive and protocol: $DATE"                      | tee -a "$BLD_PROT"
    cp "$BLD_PROT"   "$INSTALL_PREFIX""/"
    cp "$BLD_PROT"   "$TARGET_PRT"

    mv "$TARGET"     "$RQG_ARCH_DIR""/""$DATE"".""$SUFFIX"
    mv "$TARGET_PRT" "$RQG_ARCH_DIR""/""$DATE"".prt"
    PROT="$RQG_ARCH_DIR""/""$DATE"".prt"
    ls -ld "$RQG_ARCH_DIR""/""$DATE"".""$SUFFIX"                            | tee -a "$PROT"
    ls -d  "$RQG_ARCH_DIR""/""$DATE"".prt"                                  | tee -a "$PROT"
    set -e
}

function check_1st()
{
    BINDIR=$1
    echo "# Check if the release in '"$BINDIR"' basically works"            | tee -a "$BLD_PROT"
    cd "$BINDIR"
    cd mysql-test
    # Assigning a MTR_BUILD_THREAD serves to avoid collisions with RQG (starts at 730).
    perl ./mysql-test-run.pl --mtr-build-thread=700 --mem 1st        2>&1   | tee -a "$BLD_PROT"
    rm -rf var/*
    rm -f var
}

function git_info()
{
    cd "$SOURCE_DIR"
    GIT_SHOW=`git show --pretty='format:%D %H %cI' -s 2>&1`
    echo "GIT_SHOW: $GIT_SHOW"                                              | tee -a "$BLD_PROT"
    echo                                                                    | tee -a "$BLD_PROT"
    git status --untracked-files=no                                  2>&1   | tee -a "$BLD_PROT"
    echo                                                                    | tee -a "$BLD_PROT"
    git diff                                                         2>&1   | tee -a "$BLD_PROT"
    echo "#--------------------------------------------------------------"  | tee -a "$BLD_PROT"
}

