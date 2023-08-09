#!/bin/bash

# Please see this shell script rather as template how to call rqg_batch.pl even though
# it might be already in its current state sufficient for doing a lot around RQG.
#

export LANG=C

  USAGE="USAGE: $0 <Config file for the RQG test Combinator> <Basedir1 == path to MariaDB binaries> [<Basedir2>] "
EXAMPLE="EXAMPLE: $0 conf/mariadb/InnoDB_standard.cc /Server_bin/bb-10.2-marko_asan_Og "
USAGE="\n$USAGE\n\n$EXAMPLE\n"
CALL_LINE="$0 $*"

# Config file for rqg_batch.pl containing various settings for the RQG+server+InnoDB etc.
# including settings for avoiding open bugs.
# Example: conf/mariadb/InnoDB_standard.cc
CONFIG=$1
if [ "$CONFIG" = "" ]
then
   echo "You need to assign a config file for the RQG test Combinator as first parameter."
   echo "The call was ->$CALL_LINE<-"
   echo -e "$USAGE"
   exit
fi
if [ ! -e "$CONFIG" ]
then
   echo "The config file for the RQG test Combinator '$CONFIG' does not exist."
   echo "The call was ->$CALL_LINE<-"
   echo -e "$USAGE"
   exit
fi

CASE0=`basename $CONFIG`
CASE=`basename $CASE0 .cc`
if [ $CASE = $CASE0 ]
then
   echo "You need to assign a Combinator config file (extension .cc)."
   echo "The call was ->$CALL_LINE<-"
   echo -e "$USAGE"
   exit
fi


# Path to MariaDB binaries
BASEDIR1="$2"
if [ "$BASEDIR1" = "" ]
then
   echo "You need to assign a basedir (path to MariaDB binaries) as second parameter."
   echo "The call was ->$CALL_LINE<-"
   echo -e "$USAGE"
   exit
fi
if [ ! -d "$BASEDIR1" ]
then
   echo "BASEDIR1 '$BASEDIR1' does not exist or is not a directory."
   exit
fi
BASEDIR1_NAME=`basename "$BASEDIR1"`
BASEDIR2="$3"
if [ "$BASEDIR2" = "" ]
then
   echo "Setting basedir2 = basedir1"
   BASEDIR2="$BASEDIR1"
fi
if [ ! -d "$BASEDIR2" ]
then
   echo "BASEDIR2 '$BASEDIR2' does not exist or is not a directory."
   exit
fi

PROT="batch-""$CASE""-""$BASEDIR1_NAME"".prt"

# Go with heavy load in case the rqg_batch.pl ResourceControl allows it.
# The rqg_batch.pl ResourceControl should be capable to avoid trouble with resources.
# Per experience:
# More general load on the testing raises the likelihood to find or replay a
# concurrency bug.
NPROC=`nproc`
GUEST_ON_BOX=`who | egrep -v "$USER|root" | wc -l`
echo "Number of guests logged into the box: $GUEST_ON_BOX"
# GUEST_ON_BOX=0
if [ $GUEST_ON_BOX -gt 0 ]
then
   # Colleagues are on the box and most probably running rr replay.
   # So do not raise the load too much.
   PARALLEL=$((8 * $NPROC / 10))
else
   PARALLEL=$(($NPROC * 3))
fi
# If $PARALLEL > ~270 than we get trouble with some resources.
if [ $PARALLEL -gt 270 ]
then
   PARALLEL=270
fi
set +e

# The size of a testing campaign is controlled by up to five limiters.
# --------------------------------------------------------------------
# - the "exit" file   last_batch_workdir/exit
#   This file does not exist after rqg_batch.pl was called.
#   But as soon that file gets created by the user or similar rqg_batch.pl will stop all RQG runs.
# - a function in lib/Batch.pm
#   Abort of testing as soon as some quota of failing tests gets exceeded.
#   Focus: Bad Combinator config or tests, defect in code of RQG or tools, exceptional bad DB server
# - Stop of testing as soon the elapsed runtime of testing campaign exceeds the value assigned to
#   --max_runtime or the default of 432000 (in seconds) = 5 days
#   We set "--max_runtime=$MAX_RUNTIME" in the current script.
#   Focus: Define the size of a testing campaign by a time related limit.
#          This is important for running 'production' like QA.
#          Per experience: total runtime < MAX_RUNTIME + 10s
# - Stop of testing as soon as the number of RQG runs regular finished exceeds the value assigned
#   to --trials or the default 99999.
#   We set "--trials=$TRIALS" in the current script.
#   Regular means: Not stopped by rqg_batch.pl because of whatever internal reason.
#   Focus: Bad Combinator config or tests, defect in code of RQG or tools, exceptional bad DB server
#          and experiments
# - Stop of testing as soon as n RQG runs finished with the verdict 'replay'.
#   It is not recommended to set --stop_on_replay at all in the current script because BATCH.sh is
#   used for QA production. Use REPLAY_BATCH.sh instead.
#
TRIALS=10000
MAX_RUNTIME=27000


# Only one temporary 'God' (rqg_batch.pl vs. concurrent MTR, single RQG or whatever) on testing box
# -------------------------------------------------------------------------------------------------
# in order to avoid "ill" runs where
# - current rqg_batch run ---- other ongoing rqg_batch run
# - current rqg_batch run ---- ongoing MTR run
# clash on the same resources (vardir, ports -> MTR_BUILD_THREAD, maybe even files) or
# suffer from tmpfs full etc.
# Testing tool | Programs            | Standard locations
# -------------+---------------------+---------------------------
# rqg_batch.pl | perl, mysqld,   rr  | /dev/shm/rqg*/* /data/rqg/*
# MTR          | perl, mariadbd, rr  | /dev/shm/var*
killall -9 perl mysqld mariadbd rr
rm -rf /dev/shm/rqg*/* /dev/shm/var* /data/rqg/*

# There should be usually sufficient space in VARDIR for just a few fat core files caused by ASAN.
# Already the RQG runner will take care that everything important inside his VARDIR will be
# saved in his WORKDIR and empty his VARDIR. rqg_batch.pl will empty the VARDIR of this RQG
# runner again. So the space comsumption of a core is only temporary.
# The rqg_batch.pl ResourceControl will also take care to avoid VARDIR full.
# If its not an ASAN build than this environment variable is harmless anyway.
export ASAN_OPTIONS=abort_on_error=1,disable_coredump=0
echo "Have set "`env | grep ASAN`

rm -f $PROT

set -o pipefail
# Options
# -------
# 0. Please take care that there must be a '\' at line end.
#
# 1. Remove the logs of RQG runs achieving STATUS_OK/verdict 'ignore_*'.
#    Their stuff grammar/datadir was not archived and is already thrown away.
#    So basically:
#    Do not assign '--discard_logs' in case you want to see logs of RQG runs which achieved
#    the verdict 'ignore_*' (blacklist match or STATUS_OK or stopped by rqg_batch.pl)
# --discard_logs                                                       \
#
# 2. Per default the data (data dir of server, core etc.) of some RQG replaying or being at least
#    of interest gets archived.
#    In case you do not want that archiving than you can disable it.
#    But thats is rather suitable for runs of the test simplifier only.
#    rr tracing enabled requires that archiving is not disabled.
# --noarchiving                                                        \
#
# 3. Do not abort if hitting Perl errors or STATUS_ENVIRONMENT_FAILURE. IMHO some rather
#    questionable option. I am unsure if that option gets correct handled in rqg_batch.pl.
# --force                                                              \
#
# 4. Debugging of the rqg_batch.pl tool machinery and rqg.pl
#    Default: Minimal debug output.
#    Assigning '_all_' causes maximum debug output.
#    Warning: Significant more output of especially rqg_batch.pl and partially rqg.pl.
# --script_debug=_all_                                                 \
#
# 5. "--no-mask", but not "--mask" or "--mask_level", could be assigned to combinations.pl
#    in command line. combinations.pl had also the default to apply some masking except some other
#    one was assigned in the config file.
#    Hence assigning "--no-mask" to combinations.pl was required in order to switch any masking off.
#    rqg_batch.pl
#    - also does not support "--mask=...", "--mask_level=..." on command line
#    - accepts any "--no-mask" from command line but passes it through to Combinator or Simplifier
#    The Combinator
#    - generates a snippet (might contain no-mask, mask, mask-level) of the call of a RQG runner
#      based on the config file
#    - adds "--no-mask" to the end of that snippet if having got "--no-mask" in the command line.
# --no-mask                                                            \
#
# 6. rqg_batch.pl prints how it would start RQG Workers and the RQG Worker started "fakes" that
#    it has achieved the verdict assigned. == There all no "real" RQG runs at all.
#    Example:
#    --dryrun=replay --> All RQG Worker started "tell" that they have achieved some replay.
#    Use cases:
#    a) When using the Combinator see which combinations would get generated.
#    b) When using the Simplifier see how it would be tried to shrink the grammar.
#    c) --dryrun=ignore_unwanted  see a) or b) and how TRIALS would be the limiter.
# --dryrun=ignore_unwanted                                             \
# --dryrun=replay                                                      \
#
# 7. rqg_batch stops immediate all RQG runner if reaching the assigned number of replays
#    Stop after the first replay
# --stop_on_replay                                                     \
#    Stop after the n'th replay
# --stop_on_replay=<n>                                                 \
#
# 8. Use "rr" (https://github.com/mozilla/rr/wiki/Usage) for tracing DB servers and other
#    programs.
#    RECOMMENDATION:
#    Assign within
#    - the RQG Batch config file when rr should be invoked including rr options which
#      are independent of the testing box
#      Please be aware that some increasing number of such config files already do this.
#    - rr options which are dependent of the testing box
#         Example: --microarch="Intel Skylake"
#      in local.cfg
#
# --rr                                                                 \
#    Preserve the 'rr' traces of the bootstrap, server starts and mariabackup calls.
#
#    Recommended settings (Info taken from rr help)
#    '--chaos' randomize scheduling decisions to try to reproduce bugs
#    '--wait'  Wait for all child processes to exit, not just the initial process.
# --rr_options='--chaos --wait'                                        \
#
#    "rr" checks which CPU is used in your box.
#    In case your version of "rr" is too old or your CPU is too new than the check might fail
#    and cause that the call of 'rr' fails.
#    Example:
#    Box having "Intel Skylake" CPU's, "rr" version 4 contains the string "Intel Skylake" but
#    claims to have met some unknown CPU.
#    Please becareful with the single and double quotes.
# --rr_options='--chaos --wait --microarch=\"Intel Skylake\"'          \
#
# 9. SQL tracing within RQG (Client side tracing)
# --sqltrace=Simple                                                    \
#
#

# perl -w -d:ptkdb ./rqg_batch.pl                                      \
#

# In case you distrust the rqg_batch.pl mechanics or the config file etc. than going with some
# limited number of trials is often useful.
# TRIALS=3
# PARALLEL=2
# TRIALS=2
# PARALLEL=2
# TRIALS=1
# PARALLEL=1
#

nohup perl -w ./rqg_batch.pl                                           \
--parallel=$PARALLEL                                                   \
--basedir1=$BASEDIR1                                                   \
--basedir2=$BASEDIR2                                                   \
--type=Combinator                                                      \
--config=$CONFIG                                                       \
--max_runtime=$MAX_RUNTIME                                             \
--trials=$TRIALS                                                       \
--discard_logs                                                         \
--no-mask                                                              \
--script_debug=_nix_                                                   \
> $PROT 2>&1 &

# Avoid that "tail -f ..." starts before the file exists.
STATE=2
NUM=0
while [ $STATE -eq 2 ]
do
   sleep 0.1
   NUM=$(($NUM + 1))
   if [ $NUM -gt 20 ]
   then
      STATE=1
   fi
   if [ -f $PROT ]
   then
      STATE=0
   fi
done

if [ $STATE -eq 1 ]
then
   echo "ERROR: Most probably in RQG mechanics or setup."
   echo "ERROR: The (expected) protocol file '$PROT' did not show up"
   exit 4
fi

tail -n 40 -f $PROT

