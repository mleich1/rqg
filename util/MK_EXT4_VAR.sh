set -x
BASE_FS="/dev/shm"
if [ ! -d $BASE_FS ]
then
    echo "ERROR: BASE_FS '$BASE_FS' does not exist or is not a directory"
    exit 4
fi
CONTAINER="$BASE_FS""/container"
VARDIR_FS="$BASE_FS""/rqg_ext4"

sudo umount "$CONTAINER"
sudo umount "$VARDIR_FS"
if [ ! -e $CONTAINER ]
then
    echo "INFO: CONTAINER '$CONTAINER' does not exist"
else
    rm -f "$CONTAINER"
    touch $CONTAINER
    if [ ! -f $CONTAINER ]
    then
        echo "ERROR: Creation of CONTAINER '$CONTAINER' failed"
        exit 4
    fi
fi


set -e
if [ -e $VARDIR_FS ]
then
    echo "INFO: VARDIR_FS '$VARDIR_FS' does exist"
    if [ ! -d $VARDIR_FS ]
    then
        echo "ERROR: VARDIR_FS '$VARDIR_FS' is not a directory"
        exit 4
    fi
else
    mkdir $VARDIR_FS
    if [ ! -d $VARDIR_FS ]
    then
        echo "ERROR: Creation of VARDIR_FS '$VARDIR_FS' failed"
        exit 4
    fi
fi
   
SPACE_AVAIL=`df -vk --output=avail "$BASE_FS" | tail -1`
if [ '' = "$SPACE_AVAIL" ]
then
    echo echo "ERROR: Determine the free space in '$BASE_FS' failed."
    exit 4
fi
SPACE_PLANNED=$(($SPACE_AVAIL / 3))"K"
echo "SPACE_AVAIL ->$SPACE_AVAIL<- SPACE_PLANNED ->$SPACE_PLANNED<- (all in KB)"

fallocate -l $SPACE_PLANNED "$CONTAINER"
mkfs.ext4 -j "$CONTAINER"

sudo mount "$CONTAINER" "$VARDIR_FS"
sudo chown mleich "$VARDIR_FS"
sudo chgrp dev    "$VARDIR_FS"
sudo chmod 775    "$VARDIR_FS"

df -vk
