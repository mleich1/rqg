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
set -e
if [ -e "$VARDIR_FS" ]
then
    echo "INFO: VARDIR_FS '$VARDIR_FS' does exist"
    if [ ! -d "$VARDIR_FS" ]
    then
        echo "ERROR: VARDIR_FS '$VARDIR_FS' is not a directory"
        exit 4
    fi
else
    sudo mkdir "$VARDIR_FS"
    if [ ! -d "$VARDIR_FS" ]
    then
        echo "ERROR: Creation of VARDIR_FS '$VARDIR_FS' failed"
        exit 4
    fi
fi

if [ -e "$CONTAINER" ]
then
    echo "INFO: CONTAINER '$CONTAINER' does exist"
    if [ ! -f "$CONTAINER" ]
    then
        echo "ERROR: CONTAINER '$CONTAINER' is not a plain file"
        exit 4
    else
        sudo rm "$CONTAINER"
    fi
fi

SPACE_AVAIL=`df -vk --output=avail "$BASE_FS" | tail -1`
if [ '' = "$SPACE_AVAIL" ]
then
    echo echo "ERROR: Determine the free space in '$BASE_FS' failed."
    exit 4
fi
SPACE_PLANNED=$(($SPACE_AVAIL / 3))
# 'sdp' reports for /dev/shm a total space of 1,559,937,276 which is
# suspicious high. Given the CPU power etc. we do not need more than 100 GB.
# Formatting more than required wastes elapsed time on 'sdp'.
MAX_SPACE=209715200
if [ $SPACE_PLANNED -gt $MAX_SPACE ]
then
    SPACE_PLANNED=$MAX_SPACE
    echo "Downsizing SPACE_PLANNED to $MAX_SPACE KB"
fi
echo "SPACE_AVAIL ->$SPACE_AVAIL<- SPACE_PLANNED ->$SPACE_PLANNED<- (all in KB)"

# Make the file $CONTAINER big enough for keeping the internal structures of
# a filesystem with the planned size.
sudo fallocate -l "$SPACE_PLANNED""K" "$CONTAINER"
sudo mkfs.ext4 -j "$CONTAINER"

sudo mount "$CONTAINER" "$VARDIR_FS"
sudo chown $USER "$VARDIR_FS" "$CONTAINER"
sudo chmod 775   "$VARDIR_FS"
# df -vk shows that $CONTAINER located in /dev/shm is serious smaller than the planned size.
# $CONTAINER would grow during its use up till the planned size except /dev/shm becomes full.
# The latter happened several times and caused tests failing.
# Therefore ensure that $CONTAINER has the required size.
DUMMY_FILE="$VARDIR_FS""/klops"
set +e
dd if=/dev/zero of="$DUMMY_FILE" bs=1M
set -e
sudo rm "$DUMMY_FILE"
set +e
sudo chgrp dev "$VARDIR_FS"
set -e
ls -ld "$VARDIR_FS" "$CONTAINER"

df -vk
