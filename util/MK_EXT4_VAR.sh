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
# Thoughts for a cc file having 50% vardir_fast and 50% vardir_slow
# ------------------------------------------------------------------------------
# 1. Observation:
#    Even if the slowdir rqg_ext4 container occupies 40% of the initial free
#    space in /dev/shm some testing campaign could have tests which fail
#    because of no more space in the rqg_ext4 filesystem.
#    (25% , 30%, 33% and 40% tried)
#    Variant a) The DB server babbles somewhere of no more space.          (*)
#    Variant b) RQG means to have seen some freeze of the DB server because
#               timeouts get exceeded and similar. The reason can be that the
#               DB server waits for free space.
#    Variant c) RQG babbles about some failure when writing, copying, .... (**)
#    (*) Easy to detect and to classify as "no more space" problem.
#    (**) Analysis is frequnet extreme difficult.
# 2. Raising the size of rqg_ext4 over 50% makes no sense because certain stuff
#    (Example: rr traces, file backups, ...) of tests using slowdir gets already
#    stored in /dev/shm. I gues that some raise would led to reducing the
#    overall throughput.
# 3. Some sophisticated solution like
#    - do not prefill rqg_ext4 with dd --> Let it just grow during testing.
#    - tune lib/ResourceControl.pm which observes the free space in fast_dir
#    is thinkable.
#    But it does not help in case of userdefined slowdirs which have already
#    their full size + the tuning will be costly.
# Conclusions:
# - lib/ResourceControl.pm must take care of the space consumption in slowdir
# - The optimal size of the rqg_ext4 vs /dev/shm is reached in case we have
#   maximum throughput ->
#   no or low fraction of tests stopped because of trouble with free space in
#   fast_dir (/dev/shm/rqg) and slow_dir (maybe /dev/shm/rqg_ext4)
SPACE_PLANNED=$(($SPACE_AVAIL / 10 * 4))
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
