#!/bin/bash
LANG=C
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
# rqg_extr | Max used | load   | load_keep      | load_decrease  | Remarks
#    40.0% |      61% |  25544 |   734 K1 2.87% |   266 D1 1.04% | (1), (2)
#    33.3% |      86% |                                          | (1)
#    33.3% |      79% |  22024 |    88 K1 0.4%  |    34 D1 0.15% | (1), (2)
#    33.3% |      66% |   7948 |    72 K1 0.91% |    20 D1 0.25% | (2)
#    33.3% |      65% |  10236 |    30 K1 0.29% |    10 D1 0.10% | (2)
#    33.3% |      66% |   9990 |     2 K1       |     2 D1       | (2)      | 9280s RelWithDebInfo
# (1) with journal and reserved blocks for root
# (2) there seems to be also some impact of the properties (failure quota) of
#     the MariaDB source tree
#     Test fail -> archiving with compression -> longer timespan of storage use

SPACE_PLANNED=$((($SPACE_AVAIL * 3) / 10))
# The box 'sdp' reports for /dev/shm a total space of 1,559,937,276 which is
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
# -m0                 0% reserved blocks for root
# -O ^has_journal     Disable journaling
sudo mkfs.ext4 -m0 -O ^has_journal -j "$CONTAINER"

sudo mount "$CONTAINER" "$VARDIR_FS"
sudo chown $USER "$VARDIR_FS" "$CONTAINER"
sudo chmod 775   "$VARDIR_FS"
# df -vk shows that $CONTAINER located in /dev/shm is serious smaller than the planned size.
# $CONTAINER would grow during its use up till the planned size except /dev/shm becomes full.
# The latter happened several times and caused tests failing.
# Therefore ensure that $CONTAINER has the required size.
DUMMY_FILE="$VARDIR_FS""/klops"
set +e
echo "The message 'No space left on device' is expected."
dd if=/dev/zero of="$DUMMY_FILE" bs=1M
set -e
sudo rm "$DUMMY_FILE"
set +e
sudo chgrp dev "$VARDIR_FS"
set -e
ls -ld "$VARDIR_FS" "$CONTAINER"
OTHER_DIR="/dev/shm/rqg"
if [ ! -e "$OTHER_DIR" ]
then
   mkdir "$OTHER_DIR"
fi

df -vk
