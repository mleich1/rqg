#!/bin/bash

LANG=C
RQG_DIR=`pwd`

# set -x

set -e

CALL_LINE="$0 $*"

WRK_DIR=$1
if [ "$WRK_DIR" = "" ]
then
   echo "No RQG workdir was assigned."
   echo "The call was ->$CALL_LINE<-"
   WRK_DIR="last_result_dir"
   echo "Therefore picking the directory the symlink '$WRK_DIR' points to."
   WRK_DIR=`realpath "$WRK_DIR"`
fi
if [ ! -d "$WRK_DIR" ]
then
   echo "The directory '$WRK_DIR' does not exist or is not a directory"
   echo "The call was ->$CALL_LINE<-"
   exit
fi

FOUND=`grep " init ===============================================" "$WRK_DIR"/result.txt | \
        sed -e "s/init =*/init/g"`
TITLE="$FOUND\n"`grep -i "Number | Worker | Verdict" "$WRK_DIR"/result.txt`
export TITLE WRK_DIR
watch -n2 'echo "$TITLE"; tail -40 "$WRK_DIR"/result.txt'

