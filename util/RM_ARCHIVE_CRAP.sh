
if [ "$1" != "" ]
then
    MY_DIR=$1
else
    MY_DIR="last_batch_workdir"
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
egrep -l \
    -e 'The RQG run ended with status STATUS_REPLICATION_FAILURE'                                  \
    -e 'The RQG run ended with status STATUS_CRITICAL_FAILURE'                                     \
    -e 'The RQG run ended with status STATUS_ALARM'                                                \
    -e 'The RQG run ended with status STATUS_SERVER_DEADLOCKED'                                    \
    -e "BATCH: Stop the run because of 'rqg_limit'"                                                \
*.log > $MY_TMP0
set +e
sed -e "s/\(1*\)\.log$/\1.tgz/g"    $MY_TMP0 > $MY_TMP1
cat $MY_TMP1
rm `cat $MY_TMP1`
sed -e "s/\(1*\)\.log$/\1.tar.gz/g" $MY_TMP0 > $MY_TMP1
rm `cat $MY_TMP1`
sed -e "s/\(1*\)\.log$/\1.tar.xz/g" $MY_TMP0 > $MY_TMP1
rm `cat $MY_TMP1`
rm resource.txt

rm $MY_TMP0
rm $MY_TMP1

