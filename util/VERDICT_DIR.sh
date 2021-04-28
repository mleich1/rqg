#!/bin/bash

LANG=C
RQG_DIR=`pwd`

# set -x
set -e
set -o pipefail

CALL_LINE="$0 $*"


WRK_DIR=$1
if [ "$WRK_DIR" = "" ]
then
   echo "No RQG workdir was assigned."
   echo "The call was ->$CALL_LINE<-"
   echo "Therefore picking the default 'last_batch_workdir'."
#  echo -e "$USAGE"
   WRK_DIR="last_batch_workdir"
fi
if [ ! -d "$WRK_DIR" ]
then
   echo "The directory '$WRK_DIR' does not exist or is not a directory"
   echo "The call was ->$CALL_LINE<-"
#  echo -e "$USAGE"
   exit
fi

set -u

NUM_LOGS=`ls -ld "$WRK_DIR"/*.log | wc -l`
if [ $NUM_LOGS -eq 0 ]
then
   echo "The directory '$WRK_DIR' does not contain files ending with '.log'"
   exit
fi

# 1. Consistency check of verdict_general.cfg
# 2. Generate $RQG_DIR/Verdict_tmp.cfg out of verdict_general.cfg.
perl verdict.pl --batch_config=verdict_general.cfg --workdir=$RQG_DIR > /dev/null

set +e

NUM=`ls -d "$WRK_DIR"/RQG_Simplifier.cfg 2>/dev/null | wc -l`
if [ $NUM -gt 0 ]
then
    echo "The directory '$WRK_DIR' contains a Simplifier run"
    echo "== It is or was a test battery with decreasing complexity."
fi


set -e
for log_file in "$WRK_DIR"/*.log
do
    INFO=`perl verdict.pl --verdict_config=$RQG_DIR/Verdict_tmp.cfg --log="$log_file" 2>&1 \
          | egrep ' Verdict: ' | sed -e 's/^.* Verdict: .*, Extra_info: //g'`
    ARCH="$WRK_DIR""/"` basename $log_file '.log'`
    # echo "->$ARCH<-"
    if [ "$ARCH" != "" ]
    then
        if [ -e "$ARCH"".tar.gz" ]
        then
            ARCH="$ARCH"".tar.gz"
        elif [ -e "$ARCH"".tar.xz" ]
        then
            ARCH="$ARCH"".tar.xz"
        elif [ -e "$ARCH"".tgz" ]
        then
            ARCH="$ARCH"".tgz"
        else
            ARCH=''
        fi
    fi
    if [ "$ARCH" != "" ]
    then
        SIZE=`du -k $ARCH 2>/dev/null | cut -f1`
        ARCH="$ARCH $SIZE""KB"
    fi
    echo "$INFO        $log_file    $ARCH"
done

