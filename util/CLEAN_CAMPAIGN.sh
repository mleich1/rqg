#!/bin/bash
# util/CLEAN_CAMPAIGN.sh
#
# Assumed use case
# ----------------
# A testing campaign stored its remains in a directory assigned as first parameter here.
# All RQG test runs ($MY_DIR/<numbers>) with bad outcome of interest were already
# 1. moved to some save place ($MY_DIR/<single char followed by whatever>
#    Recommendation: <single char followed by whatever> == <error pattern name>
#    Example: mv /data/results/1678887528/000000 /data/results/1678887528/TBR-1901
# 2. checked for basic usability == rr replay or gdb -c <core> <program> works well
# 
# Hence all other RQG test runs with bad outcome either
# - replay some outcome which was already moved to a safe place
# or
# - are not of interest.
if [ "$1" != "" ]
then
    MY_DIR=$1
# else
#   # Picking "last_result_dir" is usual in other scripts.
#   # But there is some signigficant risk that the test campaign is not finished yet
#   # or results of interest are not yet saved.
#   MY_DIR="last_result_dir"
fi
echo "Inspecting ->$MY_DIR<-"
if [ ! -d "$MY_DIR" ]
then
    echo "ERROR: The directory ->$MY_DIR<- does not exist or is not a directory."
    echo "USAGE: util/CLEAN_CAMPAIGN.sh <directory with the remains of a testing campaign>"
    exit 4
fi


set -e
cd $MY_DIR
NUM_SYM_LINK=`find . -maxdepth 1 -type l | wc -l`
if [ $NUM_SYM_LINK -ne 0 ]
then
    echo "INFO: Number of symlinks ne 0"
    find $PWD -maxdepth 1 -type l | xargs ls -ld
    exit
fi
NUM_PRESERVE=`find . -maxdepth 1 -type d | grep "^\.\/[A-Za-z]" | wc -l`
echo "INFO: Number of directories which look like results to keep: ""$NUM_PRESERVE"
if [ $NUM_PRESERVE -eq 0 ]
then
    rm -rf [0-9]*/[1-2]*
    rm [0-9]*/rqg.job
    rm [0-9]*/arch*
    rm basedir*.tar.xz
else
    find . -maxdepth 1 -type d | grep "^\.\/[A-Za-z]"
    rm -rf [0-9]*/[1-2]*
    rm [0-9]*/rqg.job
    rm [0-9]*/arch*
    echo "INFO: Preserved/Leftover"
    find . -maxdepth 1 -type d | grep "^\.\/[A-Za-z]"
    ls -ld basedir*.tar.xz
    # ls -ld basedir*.tar.xz
    # echo "INFO: Nothing to do"
fi

exit
