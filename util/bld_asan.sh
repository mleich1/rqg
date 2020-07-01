#!/bin/bash

LANG=C

RELEASE=$1
if [ "$RELEASE" = "" ]
then
    echo "You need to assign a release as first parameter."
    exit 16
fi
if [ "$GENERAL_SOURCE_DIR" = "" ]
then
    GENERAL_SOURCE_DIR="/home/mleich/Server"
fi
if [ ! -d "$GENERAL_SOURCE_DIR" ]
then
    echo "The general source directory '$GENERAL_SOURCE_DIR' does not exist or is not a directory."
    exit 16
fi

if [ "$GENERAL_BIN_DIR" = "" ]
then
    GENERAL_BIN_DIR="/home/mleich/Server_bin"
fi
if [ ! -d "$GENERAL_BIN_DIR" ]
then
    echo "The general DB bin directory '$GENERAL_BIN_DIR' does not exist or is not a directory."
    exit 16
fi

if [ "$GENERAL_RQG_WORK_DIR" = "" ]
then
    GENERAL_RQG_WORK_DIR="/home/mleich/RQG/storage"
fi
if [ ! -d "$GENERAL_RQG_WORK_DIR" ]
then
    echo "The general RQG work directory '$GENERAL_RQG_WORK_DIR' does not exist or is not a directory."
    exit 16
fi

SOURCE_DIR="$GENERAL_SOURCE_DIR""/""$RELEASE"
if [ ! -d "$GENERAL_SOURCE_DIR" ]
then
    echo "The source directory '$SOURCE_DIR' does not exist or is not a directory."
    exit 16
fi

INSTALL_PREFIX="$GENERAL_BIN_DIR""/""$RELEASE""_asan"

RQG_ARCH_DIR="$GENERAL_RQG_WORK_DIR""/bin_archs"
if [ ! -d "$RQG_ARCH_DIR" ]
then
    echo "The RQG directory for MariaDB archives '$RQG_ARCH_DIR' does not exist or is not a directory."
    exit 16
fi

# One directory on tmpfs for all kinds of builds.
# Thrown away and recreated for every build.
# We build in 'out of source dir' style.
OOS_DIR="/dev/shm/build_dir"

# Check if its obvious no source tree.
STORAGE_DIR="$SOURCE_DIR""/storage"
if [ ! -d "$STORAGE_DIR" ]
then
    echo "No '$STORAGE_DIR' found. Is the current position '$SOURCE_DIR' really the root of a source tree?"
    exit 16
fi

if [ ! -d "$OOS_DIR" ]
then
    echo "No '$OOS_DIR' found. Will create it"
    mkdir "$OOS_DIR"
else
    echo "OOS_DIR '$OOS_DIR' found. Will drop and recreate it."
    rm -rf "$OOS_DIR"
    mkdir "$OOS_DIR"
fi

set -eu
set -o pipefail
BLD_PROT="$OOS_DIR""/build.prt"
rm -f "$BLD_PROT"
touch "$BLD_PROT"

echo "# Build in '"$OOS_DIR"' at "`date --rfc-3339=seconds`             | tee -a "$BLD_PROT"
echo "#=============================================================="  | tee -a "$BLD_PROT"
cd "$SOURCE_DIR"
git checkout cmake/maintainer.cmake
GIT_SHOW=`git show --pretty='format:%D %H %cI' -s 2>&1`
echo "GIT_SHOW: $GIT_SHOW"                                              | tee -a "$BLD_PROT"
echo                                                                    | tee -a "$BLD_PROT"
git status --untracked-files=no                                  2>&1   | tee -a "$BLD_PROT"
echo                                                                    | tee -a "$BLD_PROT"
git diff                                                         2>&1   | tee -a "$BLD_PROT"
echo "#--------------------------------------------------------------"  | tee -a "$BLD_PROT"

# In case
# - OOS_DIR is be inside of SOURCE_DIR     and
# - there was some previous 'in source' build in SOURCE_DIR
# than wipe it to a significant extend.
# Otherwise settings of that historic 'in source' build will influence our current build.
cd "$SOURCE_DIR"
set +e
make clean
set -e
rm -f CMakeCache.txt

cd "$OOS_DIR"

START_TS=`date '+%s'`
# -DCMAKE_BUILD_TYPE=Debug -DWITH_INNODB_EXTRA_DEBUG:BOOL=ON                                         \
cmake -DCONC_WITH_{UNITTEST,SSL}=OFF -DWITH_EMBEDDED_SERVER=OFF -DWITH_UNIT_TESTS=OFF              \
-DWITH_WSREP=ON                                                                                    \
-DPLUGIN_TOKUDB=NO -DPLUGIN_MROONGA=NO -DPLUGIN_OQGRAPH=NO -DPLUGIN_SPHINX=NO -DPLUGIN_SPIDER=NO   \
-DPLUGIN_ROCKSDB=NO -DPLUGIN_CONNECT=NO -DWITH_SAFEMALLOC=OFF -DWITH_SSL=bundled                   \
-DCMAKE_BUILD_TYPE=Debug                                                                           \
-DWITH_ASAN:BOOL=ON                                                                                \
-DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" "$SOURCE_DIR"    2>&1   | tee -a "$BLD_PROT"
END_TS=`date '+%s'`
RUNTIME=$(($END_TS - $START_TS))
echo -e "\nElapsed time for cmake: $RUNTIME\n\n"                        | tee -a "$BLD_PROT"

rm -f sql/mysqld
rm -f sql/mariadbd

PARALLEL=`nproc`
PARALLEL=$((PARALLEL + PARALLEL / 2))

pwd
echo "PARALLEL = $PARALLEL"
env                                                                     | tee -a "$BLD_PROT"
START_TS=`date '+%s'`
nice -19 make -j $PARALLEL                                       2>&1   | tee -a "$BLD_PROT"
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

echo "#--------------------------------------------------------------"  | tee -a "$BLD_PROT"
cd mysql-test
# Assigning a MTR_BUILD_THREAD serves to avoid collisions with RQG (starts at 730) and
# especially other bld_*.sh running in parallel for the same or other source trees.
perl ./mysql-test-run.pl --mtr-build-thread=702 1st              2>&1   | tee -a "$BLD_PROT"

echo "# Install in '"$INSTALL_PREFIX"' at "`date --rfc-3339=seconds`    | tee -a "$BLD_PROT"
echo "#=============================================================="  | tee -a "$BLD_PROT"
# cd "$INSTALL_PREFIX"/mysqltest/ ; ./mtr 1st     will fail later in case we run
# "make install" when CWD is "$OOS_DIR"/mysql-test
cd "$OOS_DIR"

rm -rf "$INSTALL_PREFIX"
make install                                                     2>&1   | tee -a "$BLD_PROT"

echo "# Check if the release in '"$INSTALL_PREFIX"' basically works"    | tee -a "$BLD_PROT"
cd "$INSTALL_PREFIX"
cd mysql-test
perl ./mysql-test-run.pl --mtr-build-thread=700 --mem 1st        2>&1   | tee -a "$BLD_PROT"
rm -rf var/*
rm -f var

# Maybe delete tokudb and spider tests

echo "# Archiving of the installed release"                             | tee -a "$BLD_PROT"
echo "#=============================================================="  | tee -a "$BLD_PROT"
cd "$INSTALL_PREFIX"
echo "INSTALL_PREFIX=$INSTALL_PREFIX"                                   | tee -a "$BLD_PROT"
TARGET="$RQG_ARCH_DIR""/bin_arch.tgz"
TARGET_PRT="$RQG_ARCH_DIR""/bin_arch.prt"
rm -f "$TARGET" "$TARGET_PRT"
echo "Generating compressed archive with binaries (for RQG)"            | tee -a "$BLD_PROT"
tar czf "$TARGET" .                                              2>&1   | tee -a "$BLD_PROT"
MD5SUM=`md5sum "$TARGET" | cut -f1 -d' '`
echo "MD5SUM of archive: $MD5SUM"                                       | tee -a "$BLD_PROT"
DATE=`date -u +%s`
echo "The archive of the release before renaming"                       | tee -a "$BLD_PROT"
ls -ld "$TARGET"                                                 2>&1   | tee -a "$BLD_PROT"
echo "BASENAME of the archive and protocol: $DATE"                      | tee -a "$BLD_PROT"
cp "$BLD_PROT"   "$INSTALL_PREFIX""/"
cp "$BLD_PROT"   "$TARGET_PRT"

mv "$TARGET_PRT" "$RQG_ARCH_DIR""/""$DATE"".prt"
mv "$TARGET"     "$RQG_ARCH_DIR""/""$DATE"".tgz"

echo
echo "End of build+install process reached"
echo

rm -rf "$OOS_DIR"
