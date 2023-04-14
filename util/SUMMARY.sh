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
   WRK_DIR="last_result_dir"
   echo "Therefore picking the directory the symlink '$WRK_DIR' points to."
#  echo -e "$USAGE"
   WRK_DIR=`realpath "$WRK_DIR"`
fi
if [ ! -d "$WRK_DIR" ]
then
   echo "The directory '$WRK_DIR' does not exist or is not a directory"
   echo "The call was ->$CALL_LINE<-"
#  echo -e "$USAGE"
   exit
fi

set -u

# Examples of RQG log name:
#     - old layout    /data/results/1654696701/000001.log
#     - new layout    /data/results/1654696701/000001/rqg.log
#
# Directory names consisting of less than six digits/no zero at begin
# belong to ongoing RQG runs.
# Example: /data/results/1654696701/1
#
set +e
NUM_LOGS=`ls -d "$WRK_DIR"/[0-9][0-9][0-9][0-9][0-9][0-9]/rqg.log \
"$WRK_DIR"/[A-Za-z]*/rqg.log \
"$WRK_DIR"/[0-9][0-9][0-9][0-9][0-9][0-9].log 2> /dev/null | wc -l `
set -e
if [ $NUM_LOGS -eq 0 ]
then
   echo "The directory '$WRK_DIR' does not contain logs of finished RQG runs."
   exit 1
fi

TMP_RESULT="$WRK_DIR""/result.tmp"
rm -f "$TMP_RESULT"
NEW_RESULT="$WRK_DIR""/result.new"
rm -f "$NEW_RESULT"
TMP_SETUP="$WRK_DIR""/setup.tmp"
rm -f "$TMP_RESULT"
NEW_SETUP="$WRK_DIR""/setup.new"
rm -f "$NEW_SETUP"
set -e
touch "$TMP_RESULT"
touch "$TMP_SETUP"
touch "$NEW_RESULT"
touch "$NEW_SETUP"

# 1. Consistency check of verdict_general.cfg
# 2. Generate $RQG_DIR/Verdict_tmp.cfg out of verdict_general.cfg.
perl verdict.pl --batch_config=verdict_general.cfg --workdir=$RQG_DIR > /dev/null

set +e

NUM=`ls -d "$WRK_DIR"/RQG_Simplifier.cfg 2>/dev/null | wc -l`
if [ $NUM -gt 0 ]
then
    MSG1="The directory '$WRK_DIR' contains a Simplifier run\n"
    MSG="$MSG1""== It is or was a test battery with decreasing complexity."
    echo -e "$MSG"                                                               | tee -a "$NEW_RESULT"
fi
echo '--------------------------------------------------------------------------------' \
                                                                                 | tee -a "$NEW_RESULT"
cat "$WRK_DIR"/SourceInfo.txt                                                    | tee -a "$NEW_RESULT"
echo '--------------------------------------------------------------------------------' \
                                                                                 | tee -a "$NEW_RESULT"
echo "INFO: The remainings of RQG runs being not of interest are already deleted."      \
                                                                                 | tee -a "$NEW_RESULT"
cat "$NEW_RESULT"                                                                      >> "$NEW_SETUP"

function process_log()
{
    # echo "Function Processing ->""$LOG_FILE""<-"
    INFO1=`perl verdict.pl --verdict_config=$RQG_DIR/Verdict_tmp.cfg --log="$LOG_FILE" 2>&1 \
          | egrep ' Verdict: '`
    INFO=`echo "$INFO1" | sed -e 's/^.* Verdict: .*, Extra_info: //g'`
    VAL=`echo "$INFO1" | grep 'Verdict: ignore' | wc -l`

    DIR_NAME=`dirname "$LOG_FILE"`

#   ARCH   -- tar archive   In case of old layout maybe with rr trace.
#   OBJECT -- Directory(new layout) or file(oldlayout) to be inspected with "du"
#   SLF    -- Search pattern for finding the righ line in setup.txt

    if   [ "$LOG_FILE" = "$DIR_NAME""/rqg.log" ]
    then
        ARCH="$DIR_NAME""/archive.tar.xz"
        OBJECT="$DIR_NAME"
        SLF="$DIR_NAME"
    else
        ARCH="$WRK_DIR""/"`basename -s log "$LOG_FILE"`"tar.xz"
        OBJECT="$ARCH"
        SLF=`basename "$LOG_FILE"`
    fi
    if [ $VAL -eq 0 ]
    then
        SIZE_ALL=`du -sk "$OBJECT" 2>/dev/null | cut -f1`
        LINE_PART="$ARCH"" ""$SIZE_ALL"" KB"
        if [ ! -e "$ARCH" ]
        then
            LINE_PART="<Archive deleted>"
        fi
        echo "$INFO""        ""$LOG_FILE""    ""$LINE_PART"                      >> "$TMP_RESULT"

        # Example
        #^ignore_blacklist | STATUS_OK | --gendata=conf... --no_mask | 1207 | 001206.log
        SETUP=`grep "$SLF" "$WRK_DIR"/setup.txt | sed -e 's/^.* | S.* | \(--.*\)/| \1/g'`
        echo "$INFO $LOG_FILE $SETUP"                                            >> "$TMP_SETUP"
    fi
    # sleep 1
    # ACTIVE=`ps -elf | grep '/bin/bash ./SUMMARY.sh' | wc -l`
    # echo "processor $RUNNING finished, currently active '/bin/bash ./SUMMARY.sh' : $ACTIVE"
}

function num_children {
    NUM_CHILDREN=`ps -eo ppid | grep -w $$ | wc -l`
    echo $NUM_CHILDREN >> otto
}

NPROC=`nproc`
for LOG_FILE in `ls -d "$WRK_DIR"/[0-9][0-9][0-9][0-9][0-9][0-9]/rqg.log \
"$WRK_DIR"/[A-Za-z]*/rqg.log \
"$WRK_DIR"/[0-9][0-9][0-9][0-9][0-9][0-9].log 2>/dev/null`
do
    num_children
    while [ $NUM_CHILDREN -gt $NPROC ]
    do
        sleep 1
        num_children
    done
    # echo "Processing ->""$LOG_FILE""<-"
    process_log "$LOG_FILE" &
done
wait
sort "$TMP_RESULT"                                                               | tee -a "$NEW_RESULT"
rm -f "$TMP_RESULT"
sort "$TMP_SETUP"                                                                >> "$NEW_SETUP"
rm -f "$TMP_SETUP"

