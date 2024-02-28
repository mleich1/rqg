#!/bin/bash
# Copyright (C) 2021, 2022 MariaDB Corporation Ab.
# Copyright (C) 2023, 2024 MariaDB plc
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
        COMP_PROG="xz --verbose --stdout --threads $PARALLEL"
        TAR_SUFFIX="tar.xz"
        # The build gets usually started when no parallel testing happens. And so we have often
        # several up till many CPU cores.
        # Hence rise the compression with the number of cores assigned or calculated.
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
    # Cloning submodules with --depth=1 accelerates git clone
    git config -f .gitmodules submodule.wsrep-lib.shallow true
    git config -f .gitmodules submodule.libmariadb.shallow true
    git config -f .gitmodules submodule.extra/wolfssl/wolfssl.shallow true
    git config -f .gitmodules submodule.storage/rocksdb/rocksdb.shallow true
    git config -f .gitmodules submodule.storage/maria/libmarias3.shallow true
    git config -f .gitmodules submodule.storage/columnstore/columnstore.shallow true

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

    BLD_NAME="$RELEASE""$BUILD_TYPE"
    INSTALL_PREFIX="$GENERAL_BIN_DIR""/""$BLD_NAME"

    BLD_PROT="$OOS_DIR""/build.prt"
    SHORT_PROT="$OOS_DIR""/short.prt"
    set -e
    rm -f "$BLD_PROT"
    touch "$BLD_PROT"
    rm -f "$SHORT_PROT"
    touch "$SHORT_PROT"

    # Prepare for required patches
    # 1. check if patch exists
    # 2. collect required checkouts

    CHECKOUT_LST="$SRV_DIR""/checkout.lst"
    rm -f "$CHECKOUT_LST"

    #    Try to reduce the amount of fake hangs if rr invoked.
    RR_HANG_PATCH="$GENERAL_SOURCE_DIR""/rr_hang.patch"
    if [ ! -f "$RR_HANG_PATCH" ]
    then
        echo "No plain file '$RR_HANG_PATCH' found."
        exit 4
    fi
    echo "git checkout storage/innobase/include/os0file.h" >> "$CHECKOUT_LST"
    #    Let mariabackup print its process id to STDOUT.
    BACKUP_PID_PATCH="$GENERAL_SOURCE_DIR""/backup_pid_print.patch"
    if [ ! -f "$BACKUP_PID_PATCH" ]
    then
        echo "No plain file '$BACKUP_PID_PATCH' found."
        exit 4
    fi
    echo "git checkout extra/mariabackup/xtrabackup.cc" >> "$CHECKOUT_LST"
    #    Use SIGABRT instead of SIGKILL so that we avoid rotten rr traces.
    MTR_RR_PATCH="$GENERAL_SOURCE_DIR""/mtr-rr-friendly.patch"
    if [ ! -f "$MTR_RR_PATCH" ]
    then
        echo "No plain file '$MTR_RR_PATCH' found."
        exit 4
    fi
    echo "git checkout storage/innobase/include/ut0new.h" >> "$CHECKOUT_LST"
    echo "git checkout mysql-test/lib/My/SafeProcess/safe_process.cc" >> "$CHECKOUT_LST"

    #    Enable the inclusion of bufferpool content in core files
    BP_IN_CORE_PATCH="$GENERAL_SOURCE_DIR""/RelWithDebInfo_BP_in_core.patch"
    if [ ! -f "$BP_IN_CORE_PATCH" ]
    then
        echo "No plain file '$BP_IN_CORE_PATCH' found."
        exit 4
    fi
    echo "git checkout storage/innobase/include/ut0new.h" >> "$CHECKOUT_LST"

    cp "$CHECKOUT_LST" "$CHECKOUT_LST".res
    sort -u "$CHECKOUT_LST" > "$CHECKOUT_LST"".usrt"
    mv "$CHECKOUT_LST"".usrt" "$CHECKOUT_LST"
    bash "$CHECKOUT_LST"

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
    git checkout storage/innobase/CMakeLists.txt
    # 2022-09
    # The content of storage/innobase/innodb.cmake was moved into storage/innobase/CMakeLists.txt.
    if [ -e storage/innobase/innodb.cmake ]
    then
        git checkout storage/innobase/innodb.cmake
    fi
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
    rm -f mariadb-test/suite/s3
    rm -f mariadb-test/plugin/spider
    rm -f mariadb-test/plugin/rocksdb
    rm -f mariadb-test/plugin/sphinx
    rm -f mariadb-test/suite/federated
    rm -f mariadb-test/plugin/connect
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

    TARGET_ARCH="$RQG_ARCH_DIR""/arch.""$TAR_SUFFIX"
    TARGET_BUILD="$RQG_ARCH_DIR""/build_prt.xz"
    TARGET_SHORT="$RQG_ARCH_DIR""/short.prt"
    rm -f "$TARGET_ARCH" "$TARGET_BUILD" "$TARGET_SHORT"

    echo "    Will use ->$COMP_PROG<- for compression"                      | tee -a "$BLD_PROT"
    # Archives of trees with binaries serve
    # - for the rather rare case that we need to restore an old tree with binaries
    #   for running a rr replay.
    # - not for running MTR tests on some historic tree
    # Hence we can save space by removing all MTR tests.
    tar --exclude="mariadb-test" --exclude="mysql-test" -cf - . | \
        $COMP_PROG > "$TARGET_ARCH" 2>&1                                    | tee -a "$BLD_PROT"

    MD5SUM=`md5sum "$TARGET_ARCH" | cut -f1 -d' '`
    echo "MD5SUM of archive: $MD5SUM"                                       | tee -a "$BLD_PROT"
    ls -ld "$TARGET_ARCH"                                                   | tee -a "$BLD_PROT"
    echo "MD5SUM of archive: $MD5SUM"                                       >> "$SHORT_PROT"
    ls -ld "$TARGET_ARCH"                                                   >> "$SHORT_PROT"

    DATE=`date -u +%s`
    echo "The archive of the release before renaming"                       | tee -a "$BLD_PROT"
    ls -ld "$TARGET_ARCH"                                            2>&1   | tee -a "$BLD_PROT"

    BLD_NAME_D="$BLD_NAME""_""$DATE"
    echo "BASENAME of the archive and protocols: $BLD_NAME_D"               >> "$SHORT_PROT"

    cp "$BLD_PROT"   "$INSTALL_PREFIX""/"
    cat "$BLD_PROT" | $COMP_PROG > "$TARGET_BUILD"
    cp "$SHORT_PROT" "$INSTALL_PREFIX""/"
    cp "$SHORT_PROT" "$TARGET_SHORT"

    FINAL_ARCH="$RQG_ARCH_DIR""/""$BLD_NAME_D"".""$TAR_SUFFIX"
    FINAL_BUILD="$RQG_ARCH_DIR""/""$BLD_NAME_D"".prt.xz"
    FINAL_SHORT="$RQG_ARCH_DIR""/""$BLD_NAME_D"".short"
    mv "$TARGET_ARCH"  "$FINAL_ARCH"
    mv "$TARGET_BUILD" "$FINAL_BUILD"
    mv "$TARGET_SHORT" "$FINAL_SHORT"
    set -e
}

function check_1st()
{
    BINDIR=$1
    echo "# Checking if the release in '"$BINDIR"' basically works"         | tee -a "$BLD_PROT"
    set -e
    cd "$BINDIR"
    if [ ! -d mariadb-test ]
    then
        THE_NAME="mysql"
    else
        THE_NAME="mariadb"
    fi
    TEST_DIR="$THE_NAME""-test"
    cd "$TEST_DIR"

    # Assigning a MTR_BUILD_THREAD serves to avoid collisions with RQG (starts at 730).
    perl ./"$TEST_DIR"-run.pl --mtr-build-thread=700 --mem 1st 2>&1    > 1st.prt
    cat 1st.prt                                                             | tee -a "$BLD_PROT"
    rm 1st.prt
    rm -rf var/*
    rm -f var
    set +e
}

function git_info()
{
    cd "$SOURCE_DIR"
    GIT_SHOW=`git show --pretty='format:%D %H %cI' -s 2>&1`
    echo "GIT_SHOW: $GIT_SHOW"                                              | tee -a "$SHORT_PROT"
    echo                                                                    | tee -a "$SHORT_PROT"
    git status --untracked-files=no                                  2>&1   | tee -a "$SHORT_PROT"
    echo                                                                    | tee -a "$SHORT_PROT"
    git diff                                                         2>&1   | tee -a "$SHORT_PROT"
    echo "#--------------------------------------------------------------"  | tee -a "$SHORT_PROT"
    cat "$SHORT_PROT" >> "$BLD_PROT"
}

function install_till_end()
{
    set -e
    echo "#--------------------------------------------------------------"  | tee -a "$BLD_PROT"
    check_1st "$OOS_DIR"

    echo "# Install in '"$INSTALL_PREFIX"' at "`date --rfc-3339=seconds`    | tee -a "$BLD_PROT"
    echo "#=============================================================="  | tee -a "$BLD_PROT"
    # cd "$INSTALL_PREFIX"/mysqltest/ ; ./mtr 1st     will fail later in case we run
    # "make install" when CWD is "$OOS_DIR"/mysql-test
    cd "$OOS_DIR"
    remove_some_tests
    rm -rf "$INSTALL_PREFIX"
    make install                                                     2>&1   | tee -a "$BLD_PROT"

    # Without the following chmod successing builds by other group members will fail during the
    # install because overwriting of some files in $INSTALL_PREFIX/include is not allowed.
    # My guess: rm -rf did not delete everything.
    chmod -R g+w "$INSTALL_PREFIX"
    check_1st "$INSTALL_PREFIX"
    grep 'MariaDB Version' "$BLD_PROT" | sort -u                            | tee -a "$SHORT_PROT"

    archiving
    mv "$BLD_PROT" "$INSTALL_PREFIX"

    echo
    echo "End of build+install process reached"
    echo

    rm -r "$OOS_DIR"
    set +e
}

function patch_for_testing()
{
    # SOURCE_DIR="$GENERAL_SOURCE_DIR""/""$RELEASE"
    cd "$SOURCE_DIR"
    # Try to reduce the amount of fake hangs if rr invoked.
    patch -lp1 < "$RR_HANG_PATCH"
    RC=$?
    set -e
    if [ $RC -gt 0 ]
    then
        echo "ERROR: Applying '$RR_HANG_PATCH' failed."
        exit 4
    fi
    echo "1. '$RR_HANG_PATCH' applied"

    #    Use SIGABRT instead of SIGKILL so that we avoid rotten rr traces.
    patch -lp1 < "$MTR_RR_PATCH"
    RC=$?
    set -e
    if [ $RC -gt 0 ]
    then
        echo "ERROR: Applying '$MTR_RR_PATCH' failed."
        exit 4
    fi
    echo "2. '$MTR_RR_PATCH' applied"

    #    Let mariabackup print its process id to STDOUT.
    patch -lp1 < "$BACKUP_PID_PATCH"
    RC=$?
    set -e
    if [ $RC -gt 0 ]
    then
        echo "ERROR: Applying '$BACKUP_PID_PATCH' failed."
        exit 4
    fi
    echo "3. '$BACKUP_PID_PATCH' applied"

    #    Enable the inclusion of bufferpool content in core files
    BP_IN_CORE_PATCH="$GENERAL_SOURCE_DIR""/RelWithDebInfo_BP_in_core.patch"
    patch -lp1 < "$BP_IN_CORE_PATCH"
    RC=$?
    set -e
    if [ $RC -gt 0 ]
    then
        echo "ERROR: Applying '$BP_IN_CORE_PATCH' failed."
        exit 4
    fi
    echo "4. '$BP_IN_CORE_PATCH' applied"

    # git status       gets printed by other function later

    set +e
}
