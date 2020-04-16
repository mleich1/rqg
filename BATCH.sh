#!/bin/bash

# Please see this shell script rather as template how to call rqg_batch.pl even though
# it might be already in its current state sufficient for doing a lot around RQG.
#

export LANG=C

  USAGE="USAGE: $0 <Config file for the RQG test Combinator> <Basedir1 == path to MariaDB binaries> [<Basedir2>] "
EXAMPLE="EXAMPLE: $0 conf/mariadb/InnoDB_standard.cc /work_m/bb-10.2-marko/bld_debug table_stress.yy"
USAGE="\n$USAGE\n\n$EXAMPLE\n"

CALL_LINE="$0 $*"

set -e

# Config file for rqg_batch.pl containing various settings for the RQG+server+InnoDB etc.
# including settings for avoiding open bugs.
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
   echo "BASEDIR1 '$BASEDIR1' does not exist."
   exit
fi
BASEDIR2="$3"
if [ "$BASEDIR2" = "" ]
then
   echo "Setting basedir2 = basedir1"
   BASEDIR2="$BASEDIR1"
fi
if [ ! -d "$BASEDIR2" ]
then
   echo "BASEDIR2 '$BASEDIR2' does not exist."
   exit
fi

CASE0=`basename $CONFIG`
CASE=`basename $CASE0 .cfg`
if [ $CASE = $CASE0 ]
then
   CASE=`basename $CASE0 .cc`
fi

PROT="$CASE"".prt"
rm -f $PROT

# My standard work directory for rqg_batch.pl.
# The workdirs for ongoing RQG runs are in its sub directories.
# The BATCH_WORKDIR is also for permanent storing results and similar.
BATCH_WORKDIR="storage"
if [ ! -d "$BATCH_WORKDIR" ]
then
   mkdir $BATCH_WORKDIR
fi

# My standard var directory on tmpfs (recommended) for rqg_batch.pl.
# The vardirs for ongoing RQG runs are in its sub directories.
# rqg_batch.pl cleans BATCH_VARDIR except it gets killed or dies because of internal error.
BATCH_VARDIR="/dev/shm/vardir"
if [ ! -d "$BATCH_VARDIR" ]
then
   mkdir $BATCH_VARDIR
fi

set +e


# Go with heavy load in case the rqg_batch.pl ResourceControl allows it.
# The rqg_batch.pl ResourceControl should be capable to avoid trouble with resources.
# Per experience:
# More general load on the testing raises the likelihood to find or replay a
# concurrency bug.
PARALLEL=`nproc`
PARALLEL=$(($PARALLEL * 3))


# TRIALS is used as
# - one of two limits (TRIALS and MAX_RUNTIME) for the size of a testing campaign
#   Whenever one of these gets exceeded rqg_batch.pl stops ongoing RQG runs,
#   makes a cleanup, gives a summary and exits.
#   In case of
#   - (mostly) hitting no internal error in the RQG runner ('rqg.pl'), the RQG core (lib/*) and
#     ingredients invoked (reporter, validator, grammar, ...)
#     MAX_RUNTIME is the better limiter
#   - (sometimes) hitting some internal error in ... (see above)
#     TRIALS is here the better limiter because the situation is roughly hopeless and
#     you get an earlier end with less resource consumption.
# - used for limiting certain phases during RQG test simplification if running that at all.
# TRIALS means regular finished (!= stopped by rqg_batch.pl because of whatever reason) RQG runs.
TRIALS=$(($PARALLEL * 10))

# MAX_RUNTIME is a better limit than TRIALS for defining the size of a testing campaign
# when running 'production' == QA.
# Please be aware that the runtime of util/issue_grep.sh is not included.
# RQG batch run elapsed runtime =
#    assigned max_runtime
# +  time for stopping the active RQG Worker (less than 3 seconds)
# +  util/issue_grep.sh elapsed time =
#       no of logs in last_batch_workdir * (1 till 3 seconds depending on log size)
MAX_RUNTIME=3600


# Only one temporary 'God' (rqg_batch.pl vs. concurrent MTR, single RQG or whatever) on testing box
# -------------------------------------------------------------------------------------------------
# in order to avoid "ill" runs where
# - current rqg_batch run ---- other ongoing rqg_batch run
# - current rqg_batch run ---- ongoing MTR run
# clash on the same resources (vardir, ports -> MTR_BUILD_THREAD, maybe even files) or
# suffer from tmpfs full etc.
killall -9 perl ; killall -9 mysqld ; killall -9 mariadbd
rm -rf /dev/shm/var*

# In case the cleanup above is disabled than at least this.
rm -rf $BATCH_VARDIR/*

# There should be usually sufficient space in VARDIR for just a few fat core files caused by ASAN.
# Already the RQG runner will take care that everything important inside his VARDIR will be
# saved in his WORKDIR and empty his VARDIR. rqg_batch.pl will empty the VARDIR of this RQG
# runner again. So the space comsumption of a core is only temporary.
# The rqg_batch.pl ResourceControl will also take care to avoid VARDIR full.
# If its not an ASAN build than this environment variable is harmless anyway.
export ASAN_OPTIONS=abort_on_error=1,disable_coredump=0
echo "Have set "`env | grep ASAN`



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
# --discard_logs                                                      \
#
# 2. Per default the data (data dir of server, core etc.) of some RQG replaying or being at least
#    of interest gets archived.
#    In case you do not want that archiving than you can disable it.
#    But thats is rather suitable for runs of the test simplifier only.
# --noarchiving                                                       \
#
# 3. Do not abort if hitting Perl errors or STATUS_ENVIRONMENT_FAILURE. IMHO some rather
#    questionable option. I am unsure if that option gets correct handled in rqg_batch.pl.
# --force                                                             \
#
# 4. Debugging of the rqg_batch.pl tool machinery and rqg.pl
#    Default: Minimal debug output.
#    Assigning '_all_' causes maximum debug output.
#    Warning: Significant more output of especially rqg_batch.pl and partially rqg.pl.
# --script_debug=_all_                                                \
#
# 5. "--no-mask", old stuff.
#    combinations.pl had the default to apply some masking except ??? assigned some other one.
#    Hence assigning "--no-mask" was required in order to switch any masking off.
#    rqg_batch.pl
#    - does not support "--mask=...", "--mask_level=..." on command line
#    - accepts any "--no-mask" from command line but passes it through to Combinator or Simplifier
#    The Simplifier
#    - ignores any "--no-mask", "--mask=...", "--mask_level=..." got from whereever
#    - assigns all time "--no-mask" to any call of a RQG runner
#    The Combinator
#    - generates a snippet (might contain no-mask, mask, mask-level) of the call of a RQG runner
#    - adds "--no-mask" to the end of that snippet if having got "--no-mask" from somewhere.
# --no-mask                                                            \
#
# 6. rqg_batch.pl prints how it would start RQG Workers and the RQG Worker started "fakes" that
#    it has achieved the verdict assigned. == There all no "real" RQG runs at all.
#    Example:
#    --dryrun=replay --> All RQG Worker started "tell" that they have achieved some replay.
#    Use cases:
#    a) When using the Combinator see which combinations would get generated.
#    b) When using the Simplifier see how it would be tried to shrink the grammar.
#    c) --dryrun=ignore_blacklist see how TRIALS would be the limiter.
# --dryrun=ignore_blacklist                                            \
# --dryrun=replay                                                      \
#
# 7. rqg_batch stops immediate all RQG runner if reaching the assigned number of replays
#    Stop after the first replay
# --stop_on_replay                                                     \
#    Stop after the n'th replay
# --stop_on_replay=<n>                                                 \
#
# Use this grammar in all test variants
# GRAMMAR=conf/mariadb/table_stress.yy
# vi $GRAMMAR
# --grammar=$GRAMMAR                                                  \
#

# In case you distrust the rqg_batch.pl mechanics or the config file etc. than going with some
# limited number of trials is often useful.
# TRIALS=2
# PARALLEL=2
# TRIALS=1
# PARALLEL=1
#

nohup perl -w ./rqg_batch.pl                                           \
--workdir=$BATCH_WORKDIR                                               \
--vardir=$BATCH_VARDIR                                                 \
--parallel=$PARALLEL                                                   \
--basedir1=$BASEDIR1                                                   \
--basedir2=$BASEDIR2                                                   \
--config=$CONFIG                                                       \
--trials=$TRIALS                                                       \
--discard_logs                                                         \
--max_runtime=$MAX_RUNTIME                                             \
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

