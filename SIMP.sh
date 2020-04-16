#!/bin/bash

# Please see this shell script rather as template how to call rqg_batch.pl even though
# it might be already in its current state sufficient for doing a lot around RQG.
#

export LANG=C

  USAGE="USAGE:   $0 <Config file for the RQG test Simplifier> <Basedir == path to MariaDB binaries> [<YY grammar>]"
EXAMPLE="EXAMPLE: $0 simp_1.cfg /work_m/bb-10.2-marko/bld_debug table_stress.yy"
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

TRIALS=64

CASE=`basename $CONFIG .cfg`
PROT="$CASE"".prt"

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

# If an YY grammar was assigned than offer it for editing
if [ "$GRAMMAR" != "" ]
then
   vi "$GRAMMAR"
fi


set -o pipefail
# Remove the logs of RQG runs achieving STATUS_OK/verdict 'ignore_*'.
# Their stuff grammar/datadir was not archived and is already thrown away.
# So basically:
# Remove the --discard_logs in case you want to see logs of RQG runs which achieved
# the verdict 'ignore_*' (blacklist match or STATUS_OK or stopped by rqg_batch.pl)
# --discard_logs                                                         \
#
# Do not abort if hitting Perl errors or STATUS_ENVIRONMENT_FAILURE. IMHO rather questionable
# --force
#
# Old stuff. In history required.
# --no-mask  Unclear if ./rqg_batch.pl and rqg.pl will mask at all.
#
# rqg_batch.pl prints how it would start RQG Workers and the RQG Worker started "fakes" that
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
# rqg_batch stops immediate if hitting a 'replay'
# --stop_on_replay                                                     \
#
#
# perl -w -d:ptkdb ./rqg_batch.pl                                      \

# In case you distrust the rqg_batch.pl mechanics or the config file etc. than going with some
# limited number of trials is often useful.
# TRIALS=2
# PARALLEL=2
# TRIALS=1
# PARALLEL=1

nohup perl -w ./rqg_batch.pl                                           \
--workdir=$BATCH_WORKDIR                                               \
--vardir=$BATCH_VARDIR                                                 \
--parallel=$PARALLEL                                                   \
--basedir1=$BASEDIR1                                                   \
$GRAMMAR_PART                                                          \
--config=$CONFIG                                                       \
  --trials=$TRIALS                                                     \
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

