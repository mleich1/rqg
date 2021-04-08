#!/bin/bash

# HINT:
# This build variant is sometimes used. It is
# - uncomfortable for the analysis of bugs because of the "-O3"
# - good for finding bugs where the likelihood to hit them on other builds types
#   (debug/ASAN/UBSAN/TSAN/valgrind/non debug -- compiler optimizations) is lower
# - quite good for automatic simplification of tests
# - quite good for having nice assert or backtrace patterns like often in test simplifications
#

BUILD_TYPE="_asan_O3"

LANG=C

USAGE="USAGE: $0 <RELEASE == subdirectory of GENERAL_SOURCE_DIR> [ <PARALLEL> ]\n"
USAGE="$USAGE Build with debug+asan, mostly optimization -O3 .\n"
USAGE="$USAGE Environment variables and their defaults if not set.\n"
USAGE="$USAGE GENERAL_SOURCE_DIR    '/Server'\n"
USAGE="$USAGE GENERAL_BIN_DIR       '/Server_bin'\n"
USAGE="$USAGE GENERAL_RQG_WORK_DIR  '/data/Results'\n"

CALL_LINE="$0 $*"

if [ $# -eq 0 ] || [ $# -gt 2 ]
then
    echo "ERROR: Wrong number of arguments"
    echo "The call was ->$CALL_LINE<-"
    echo
    echo -e $USAGE
    exit 16
fi

set -e
source rqg_build_lib.sh
set +e

RELEASE=$1
PARALLEL=$2

if [ "$RELEASE" = "" ]
then
    echo "ERROR: You need to assign a release as first parameter."
    echo "The call was ->$CALL_LINE<-"
    echo
    echo -e $USAGE
    exit 16
fi

set_parallel

set_comp_prog

check_environment

set -eu
set -o pipefail

clean_source_dir

cd "$SOURCE_DIR"
echo "# Build in '"$OOS_DIR"' at "`date --rfc-3339=seconds`             | tee -a "$BLD_PROT"
echo "#=============================================================="  | tee -a "$BLD_PROT"
# Especially debug builds tend to fail with higher optimization because of coding mistakes,
# GCC weaknesses etc. In the current case detecting them is usually of lower value than having
# a build with non standard optimization.
cp cmake/maintainer.cmake maintainer.cmake.tmp
sed -e '/-Werror/d' maintainer.cmake.tmp > cmake/maintainer.cmake

git_info

cd "$OOS_DIR"
START_TS=`date '+%s'`
# Marko:
# Fun finding: The test innodb.alter_foreign_crash which creates 2 tables with 1 row each, then
# kills and restarts the server, takes forever (more than 1 hour) under ./mtr --rr in the
# ... branch. But, once I recompiled with cmake -DPLUGIN_PERFSCHEMA=NO it would complete
# practically instantly. I hope you are normally disabling the performance-loss schema.
# I think that there could have been some mutex acquisition loop, maybe mysql_mutex_trylock or
# whatever, and with PFS there would be a conditional branch on "is PFS enabled at runtime".
# And those are very expensive in rr.
# I can’t attach gdb and rr at the same time, but with sudo perf top -g -p $(pgrep mariadbd) I
# immediately saw some PFS code.
cmake -DCONC_WITH_{UNITTEST,SSL}=OFF -DWITH_EMBEDDED_SERVER=OFF -DWITH_UNIT_TESTS=OFF              \
-DWITH_WSREP=ON                                                                                    \
-DPLUGIN_{ARCHIVE,TOKUDB,MROONGA,OQGRAPH,ROCKSDB,CONNECT,SPIDER,SPHINX,COLUMNSTORE,PERFSCHEMA}=NO  \
-DWITH_SAFEMALLOC=OFF -DWITH_SSL=bundled                                                           \
-DWITH_DBUG_TRACE=OFF                                                                              \
-DCMAKE_BUILD_TYPE=Debug                                                                           \
-DWITH_ASAN=ON                                                                                     \
-DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" "$SOURCE_DIR"    2>&1          | tee -a "$BLD_PROT"

END_TS=`date '+%s'`
RUNTIME=$(($END_TS - $START_TS))
echo -e "\nElapsed time for cmake: $RUNTIME\n\n"                        | tee -a "$BLD_PROT"

# Do not reset something before the make!

# GCC Docu
# To tell GCC to emit extra information for use by a debugger, in almost all cases you need only to
# add -g to your other options.
#
# GCC allows you to use -g with -O. The shortcuts taken by optimized code may occasionally be
# surprising: some variables you declared may not exist at all; flow of control may briefly move
# where you did not expect it; some statements may not be executed because they compute constant
# results or their values are already at hand; some statements may execute in different places
# because they have been moved out of loops.  Nevertheless it is possible to debug optimized
# output. This makes it reasonable to use the optimizer for programs that might have bugs.
#
# Append in order to not mangle the file maybe too much
OTHER_VAL="-O3 -g"
echo -e "\nAppending CMAKE_ASM_FLAGS_DEBUG, CMAKE_CXX_FLAGS_DEBUG, CMAKE_C_FLAGS_DEBUG" \
     "=$OTHER_VAL to CMakeCache.txt\n\n"                                | tee -a "$BLD_PROT"
echo "CMAKE_ASM_FLAGS_DEBUG:STRING=$OTHER_VAL"                          >> CMakeCache.txt
echo "CMAKE_CXX_FLAGS_DEBUG:STRING=$OTHER_VAL"                          >> CMakeCache.txt
echo "CMAKE_C_FLAGS_DEBUG:STRING=$OTHER_VAL"                            >> CMakeCache.txt

cd "$OOS_DIR"

run_make

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

check_1st "$INSTALL_PREFIX"

archiving

echo
echo "End of build+install process reached"
echo

rm -rf "$OOS_DIR"
