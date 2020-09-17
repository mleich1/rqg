#!/bin/bash

# Please see this shell script rather as template how to call rqg_batch.pl even though
# it might be already in its current state sufficient for doing a lot around RQG.
#

export LANG=C

  USAGE="USAGE:   $0 <Config file for the RQG test Simplifier> <Basedir == path to MariaDB binaries> [<YY grammar>]"
EXAMPLE="EXAMPLE: $0 simp_1.cfg /Server_bin/bb-10.2-marko_asan_Og table_stress.yy"
USAGE="\n$USAGE\n\n$EXAMPLE\n"
CALL_LINE="$0 $*"

# Config file for rqg_batch.pl containing various settings for the RQG+server+InnoDB etc.
# including settings for avoiding open bugs.
# The template is: simplify_rqg_template.cfg
CONFIG=$1
if [ "$CONFIG" = "" ]
then
   echo "You need to assign a config file for the RQG test Simplifier as first parameter."
   echo "The call was ->$CALL_LINE<-"
   echo -e "$USAGE"
   exit
fi
if [ ! -e "$CONFIG" ]
then
   echo "The config file for the RQG test Simplifier '$CONFIG' does not exist."
   echo "The call was ->$CALL_LINE<-"
   echo -e "$USAGE"
   exit
fi

CASE=`basename $CONFIG .cfg`


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
BASEDIR1_NAME=`basename "$BASEDIR1"`
BASEDIR2="$BASEDIR1"

# Optional YY grammar
GRAMMAR="$3"
if [ "$GRAMMAR" != "" ]
then
   if [ ! -f "$GRAMMAR" ]
   then
      echo "The RQG grammar '$GRAMMAR' does not exist."
      echo "The call was ->$CALL_LINE<-"
      echo -e "$USAGE"
      exit
   else
      GRAMMAR_PART="--grammar=$GRAMMAR"
   fi
else
   GRAMMAR_PART=""
fi

PROT="$CASE""-""$BASEDIR1_NAME"".prt"

set -e
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
# If $PARALLEL > ~250 than we get trouble on Ubuntu 18 Server.
if [ $PARALLEL -gt 250 ]
then
   PARALLEL=250
fi

TRIALS=64

# MAX_RUNTIME is a limit for defining the size of a simplification campaign.
# Please be aware that the runtime of util/issue_grep.sh is not included.
# RQG batch run elapsed runtime =
#    assigned max_runtime
# +  time for stopping the active RQG Workers (usually less than 3 seconds)
# +  util/issue_grep.sh elapsed time =
#       no of logs in last_batch_workdir * (1 till 3 seconds depending on log size)
MAX_RUNTIME=72000

# Only one temporary 'God' (rqg_batch.pl vs. concurrent MTR, single RQG or whatever) on testing box
# -------------------------------------------------------------------------------------------------
# in order to avoid "ill" runs where
# - current rqg_batch run ---- other ongoing rqg_batch run
# - current rqg_batch run ---- ongoing MTR run
# clash on the same resources (vardir, ports -> MTR_BUILD_THREAD, maybe even files) or
# suffer from tmpfs full etc.
killall -9 perl ; killall -9 mysqld mariadbd
rm -rf /dev/shm/var*

############################################################
if [ "$PWD" = "$BATCH_VARDIR" ]
then
   echo "ERROR: Current working directory equals BATCH_VARDIR '$BATCH_VARDIR'."
   echo "The call was ->$CALL_LINE<-"
   exit
fi
if [ "$BASEDIR1" = "$BATCH_VARDIR" ]
then
   echo "ERROR: BASEDIR1 equals BATCH_VARDIR '$BATCH_VARDIR'."
   echo "The call was ->$CALL_LINE<-"
   exit
fi
if [ "$BATCH_WORKDIR" = "$BATCH_VARDIR" ]
then
   echo "ERROR: BASEDIR1 equals BATCH_VARDIR '$BATCH_VARDIR'."
   echo "The call was ->$CALL_LINE<-"
   exit
fi
#############################################################

# In case the cleanup above is disabled than at least this.
rm -rf $BATCH_VARDIR/1*

# There should be usually sufficient space in VARDIR for just a few fat core files caused by ASAN.
# Already the RQG runner will take care that everything important inside his VARDIR will be
# saved in his WORKDIR and empty his VARDIR. rqg_batch.pl will empty the VARDIR of this RQG
# runner again. So the space comsumption of a core is only temporary.
# The rqg_batch.pl ResourceControl will also take care to avoid VARDIR full.
# If its not an ASAN build than this environment variable is harmless anyway.
export ASAN_OPTIONS=abort_on_error=1,disable_coredump=0
echo "Have set "`env | grep ASAN`

# If an YY grammar was assigned than offer it for editing
if [ "$GRAMMAR" != "" ]
then
   vi "$GRAMMAR"
fi

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
# --discard_logs                                                         \
#
# 2. Per default the data (data dir of server, core etc.) of some RQG replaying or being at least
#    of interest gets archived.
#    In case you do not want that archiving than you can disable it.
#    But thats is rather suitable for runs of the test simplifier only.
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
# 5. "--no-mask", "--mask", "--mask_level"
#    rqg_batch.pl
#    - does not support "--mask=...", "--mask_level=..." on command line
#    - accepts any "--no-mask" from command line but passes it through to Combinator or Simplifier
#    The Simplifier
#    - ignores any "--no-mask", "--mask=...", "--mask_level=..." got from whereever
#    - assigns all time "--no-mask" to any call of a RQG runner
#
# 6. rqg_batch.pl prints how it would start RQG Workers and the RQG Worker started "fakes" that
# it has achieved the verdict assigned. == There all no "real" RQG runs at all.
# Example:
# --dryrun=replay --> All RQG Worker started "tell" that they have achieved some replay.
# Use cases:
# a) When using the Combinator see which combinations would get generated.
# b) When using the Simplifier see how it would be tried to shrink the grammar.
# c) --dryrun=ignore_blacklist see how TRIALS would be the limiter.
# --dryrun=ignore_blacklist                                            \
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
#
#    Get the default which is 'Server'
# --rr                                                                 \
#
#    Preserve the 'rr' traces of all servers started
#        lib/DBServer/MySQL/MySQLd.pm    sub startServer
# --rr=Server                                                          \
#
#    Preserve the 'rr' traces of the bootstrap or server or soon mariabackup ... prepare ... started
# --rr=Extended                                                        \
#
#    Make a 'rr' trace of the complete RQG run like even of the perl code of the RQG runner.
#    This leads to a huge space consumption (example: 2.6 GB for traces + datadir) during the
#    RQG test runtime but
#    - gives a better overview of the interdependence of component activities
#    - traces also the activities of MariaDB replication or Galera
# --rr=RQG                                                             \
#
#    "rr" checks which CPU is used in your box.
#    In case your version of "rr" is too old or your CPU is too new than the check might fail
#    and cause that the call of 'rr' fails.
#    Example:
#    Box having "Intel Skylake" CPU's, "rr" version 4 contains the string "Intel Skylake" but
#    claims to have met some unknown CPU.
#    Please becareful with the single and double quotes.
# --rr_options="\'--microarch='Intel Kabylake'\'"                     \
#
#    One rr option which seems to be recommended anywhere
# --rr_options="--chaos"                                              \
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
$GRAMMAR_PART                                                          \
--config=$CONFIG                                                       \
  --trials=$TRIALS                                                     \
  --noarchiving                                                        \
  --discard_logs                                                       \
--type=RQG_Simplifier                                                  \
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

