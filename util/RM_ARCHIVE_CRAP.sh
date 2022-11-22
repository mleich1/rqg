
if [ "$1" != "" ]
then
    MY_DIR=$1
else
    MY_DIR="last_result_dir"
fi
echo "->$MY_DIR<-"
if [ ! -d "$MY_DIR" ]
then
    echo "ERROR: The directory ->$MY_DIR<- does not exist or is not a directory."
    exit 4
fi

set -e
cd $MY_DIR

MY_TMP0="tmp0.$$"
MY_TMP1="tmp1.$$"
#   -e 'The RQG run ended with status STATUS_CRITICAL_FAILURE'                                     \
#   -e 'The RQG run ended with status STATUS_SERVER_DEADLOCKED'                                    \
egrep -l \
    -e 'The RQG run ended with status STATUS_REPLICATION_FAILURE'                                  \
    -e 'The RQG run ended with status STATUS_ALARM'                                                \
    -e "BATCH: Stop the run because of 'rqg_limit'"                                                \
*/rqg.log > $MY_TMP0
set +e
sed -e "s/rqg.log$/archive.tar.xz/g" $MY_TMP0 > $MY_TMP1
rm `cat $MY_TMP1`
rm resource.txt

rm $MY_TMP0
rm $MY_TMP1

