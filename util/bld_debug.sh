#!/bin/bash

PAR=$1

OOS_DIR=`pwd`"/bld_debug"

STORAGE_DIR=`pwd`"/storage"
if [ ! -d "$STORAGE_DIR" ]
then
    echo "No '$STORAGE_DIR' found. Is the current position '$PWD' really the root of a source tree?"
    exit 4
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

set -e

# In case there was some previous in source build than wipe it to a significant extend.
make clean
rm -f CMakeCache.txt

cd "$OOS_DIR"
BLD_PROT="$OOS_DIR""/build.prt"
rm -f "$BLD_PROT"
echo "# Build in '"`pwd`"' at "`date --rfc-3339=seconds`                | tee -a "$BLD_PROT"
echo "#=============================================================="  | tee -a "$BLD_PROT"
git show --pretty='format:%D %H %cI' -s                          2>&1   | tee -a "$BLD_PROT"
echo                                                             2>&1   | tee -a "$BLD_PROT"
echo "#--------------------------------------------------------------"  | tee -a "$BLD_PROT"

START_TS=`date '+%s'`
cmake -DCONC_WITH_{UNITTEST,SSL}=OFF -DWITH_EMBEDDED_SERVER=OFF -DWITH_UNIT_TESTS=OFF              \
-DWITH_WSREP=ON                                                                                    \
-DPLUGIN_TOKUDB=NO -DPLUGIN_MROONGA=NO -DPLUGIN_OQGRAPH=NO                                         \
-DPLUGIN_ROCKSDB=NO -DPLUGIN_CONNECT=NO -DWITH_SAFEMALLOC=OFF -DWITH_SSL=bundled                   \
-DCMAKE_BUILD_TYPE=Debug -DWITH_INNODB_EXTRA_DEBUG:BOOL=ON                                         \
-DWITH_ASAN:BOOL=OFF ..                                          2>&1   | tee -a "$BLD_PROT"
END_TS=`date '+%s'`
RUNTIME=$(($END_TS - $START_TS))
echo -e "\nElapsed time for cmake: $RUNTIME\n\n"                        | tee -a "$BLD_PROT"

if [ "" != "$PAR" ]
then
   PARALLEL=$PAR
else
   PARALLEL=`nproc`
   PARALLEL=$((PARALLEL + PARALLEL / 2))
fi

START_TS=`date '+%s'`
nice -19 make -j $PARALLEL                                       2>&1   | tee -a "$BLD_PROT"
END_TS=`date '+%s'`
RUNTIME=$(($END_TS - $START_TS))
echo -e "\nElapsed time for nice -19 make -j $PARALLEL: $RUNTIME\n"     | tee -a "$BLD_PROT"
echo "#--------------------------------------------------------------"  | tee -a "$BLD_PROT"

# The server, how he is started by RQG, expects the plugins located in $OOS_DIR/lib/plugin/
# which does not get created at all.
if [ ! -d lib ]
then
    echo "No subdirectory 'lib' found. Will create it"                  | tee -a "$BLD_PROT"
    mkdir lib                                                    2>&1   | tee -a "$BLD_PROT"
fi
if [ ! -d lib/plugin ]
then
    echo "No subdirectory 'lib/plugin' found. Will create it"           | tee -a "$BLD_PROT"
    mkdir lib/plugin                                             2>&1   | tee -a "$BLD_PROT"
fi
echo "Copying plugins"                                                  | tee -a "$BLD_PROT"
cp plugin/*/*.so lib/plugin                                      2>&1   | tee -a "$BLD_PROT"
echo                                                                    | tee -a "$BLD_PROT"
ls -ld lib/plugin/*.so                                           2>&1   | tee -a "$BLD_PROT"

echo "#--------------------------------------------------------------"  | tee -a "$BLD_PROT"
cd mysql-test
perl ./mysql-test-run.pl --mem 1st                               2>&1   | tee -a "$BLD_PROT"

echo
echo "The protocol of the build is:     $BLD_PROT"
echo
