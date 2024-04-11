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

# Examples:
# ---------
# RQG runs finished and of interest
# - old style    /data/results/1654696701/<number_0>.log
#                /data/results/1654696701/TBR-1219.log
# - new style    /data/results/1654696701/<number_0>/rqg.log
#                /data/results/1654696701/TBR-1219/rqg.log
# <number_0> : 6 digits, first digit is 0
#
# RQG runs ongoing and not yet finished
# - old style    /data/results/1654696701/<number_1>.log
# - new style    /data/results/1654696701/<number_1>/rqg.log
# <number_1> : less than 6 digits(*), first digit is > 0
# (*) We would need >= 100000 concurrent RQG runs for reaching 6 digits.
#     <number_1> is usually <= 270.
#
# The old style is no more supported.
#
set +e
NUM_LOGS=`ls -d "$WRK_DIR"/[0-9][0-9][0-9][0-9][0-9][0-9]/rqg.log \
"$WRK_DIR"/[A-Za-z]*/rqg.log 2> /dev/null | wc -l `
set -e
if [ $NUM_LOGS -eq 0 ]
then
   echo "The directory '$WRK_DIR' does not contain logs of finished RQG runs."
   exit 0
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
    TMP_RESULT="$DIR_NAME""/result.rqg"
    TMP_SETUP="$DIR_NAME""/setup.rqg"
    rm -f "$TMP_RESULT"
    rm -f "$TMP_SETUP"
    ARCH="$DIR_NAME""/archive.tar.xz"
    if [ $VAL -eq 0 ]
    then
        SIZE_ALL=`du -sk "$DIR_NAME" 2>/dev/null | cut -f1`
        LINE_PART="$ARCH"" ""$SIZE_ALL"" KB"
        if [ ! -e "$ARCH" ]
        then
            LINE_PART="<Archive deleted>"
        fi
        echo "$INFO""        ""$LOG_FILE""    ""$LINE_PART"                      >> "$TMP_RESULT"

        SLF="/"`basename "$DIR_NAME"`"/"
        # Example
        #^ignore_blacklist | STATUS_OK | --gendata=conf... --no_mask | 1207 | 001206.log
        SETUP=`grep "$SLF" "$WRK_DIR"/setup.txt | sed -e 's/^.* | S.* | \(--.*\)/| \1/g'`
        echo "$INFO""        ""$SETUP"" | ""$LOG_FILE"                           >> "$TMP_SETUP"
    else
        rm -f "$LOG_FILE" "$ARCH"
    fi
    # sleep 1
    # ACTIVE=`ps -elf | grep '/bin/bash ./SUMMARY.sh' | wc -l`
    # echo "processor $RUNNING finished, currently active '/bin/bash ./SUMMARY.sh' : $ACTIVE"
}

function num_children {
    NUM_CHILDREN=`ps -eo ppid | grep -w $$ | wc -l`
    # echo $NUM_CHILDREN >> otto
}

NPROC=`nproc`
# Do not use "$WRK_DIR"/* because that would include the not yet finished runs located in
# "$WRK_DIR"/<less than 6 digits and not starting with 0>.
for LOG_FILE in `ls -d "$WRK_DIR"/[0-9][0-9][0-9][0-9][0-9][0-9]/rqg.log \
"$WRK_DIR"/[A-Za-z]*/rqg.log 2>/dev/null`
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

cat "$WRK_DIR"/[0-9][0-9][0-9][0-9][0-9][0-9]/result.rqg  \
"$WRK_DIR"/[A-Za-z]*/result.rqg | sort | tee -a "$NEW_RESULT"
cat "$WRK_DIR"/[0-9][0-9][0-9][0-9][0-9][0-9]/setup.rqg  \
"$WRK_DIR"/[A-Za-z]*/setup.rqg | sort >> "$NEW_SETUP"
rm -f "$WRK_DIR"/[0-9][0-9][0-9][0-9][0-9][0-9]/*.rqg \
"$WRK_DIR"/[A-Za-z]*/*.rqg
exit

