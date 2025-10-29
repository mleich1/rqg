#!/bin/bash

# set -x

# Typical use case
# ----------------
# Run a RQG testing campaign on MariaDB binaries.
#
# Please see this shell script rather as template how to call rqg_batch.pl even though
# it might be already in its current state sufficient for doing a lot around RQG.
#

export LANG=C
CALL_LINE="$0 $*"

set -e
source util/rqg_lib.sh

set_combinator_usage

# Config file for rqg_batch.pl containing
# - various settings for the RQG+server+InnoDB etc.
# - tests to be executed
# Example: conf/mariadb/InnoDB_standard.cc
CONFIG="$1"
check_combinator_config

# Path to MariaDB binaries for first server
BASEDIR1="$2"
check_basedir1
BASEDIR1_NAME=`basename "$BASEDIR1"`

# Path to MariaDB binaries for second server if required
BASEDIR2="$3"
set_check_basedir2

set +e
# Check if there is already some running MariaDB or MySQL server or test
prevent_conflicts
# Calculate the maximum number of concurrent RQG tests
set_parallel

PROT="batch-""$CASE""-""$BASEDIR1_NAME"".prt"

# The size of a testing campaign is controlled by many limiters.
# --------------------------------------------------------------
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

# Options (Hint: Please take care that there must be a '\' at line end.)
# ----------------------------------------------------------------------
# 1. Remove the logs of RQG test runs achieving STATUS_OK/verdict 'ignore_*'.
#    Their stuff grammar/datadir was not archived and is already thrown away.
#    So basically:
#    Do not assign '--discard_logs' in case you want to see logs of RQG runs which achieved
#    the verdict 'ignore_*' (blacklist match or STATUS_OK or stopped by rqg_batch.pl).
#    The current scripts sets '--discard_logs'.
# --discard_logs                                                       \
#
# 2. Per default of rqg_batch.pl the data (data dir of server, core etc.) of some RQG test
#    replaying a problem or being at least of interest gets archived.
#    In case you do not want that archiving than you can disable it.
#    But that is rather suitable for runs of the test simplifier only.
#    Please note that rr tracing enabled requires that archiving is not disabled.
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
# 5. "--no-mask", but neither "--mask" nor "--mask_level", could be assigned to combinations.pl
#    in command line. combinations.pl had also the default to apply some masking except some other
#    one was assigned in the config file.
#    Hence assigning "--no-mask" to combinations.pl was required in order to switch any masking off.
#    rqg_batch.pl
#    - does not support "--mask=...", "--mask_level=..." on command line
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
#    This requires that the combinator config file contains a definition of what is a replay.
#    It is a rare used feature.
#    Stop after the first replay
# --stop_on_replay                                                     \
#    Stop after the n'th replay
# --stop_on_replay=<n>                                                 \
#
# 8. Use "rr" (https://github.com/mozilla/rr/wiki/Usage) for tracing DB servers and other
#    programs.
#    RECOMMENDATION:
#    Assign within the RQG Combinator config file when rr should be invoked including rr options
#    which are independent of the testing box
#      Please be aware that most of such config files already do this.
#    - local.cfg rr options which are dependent of the testing box like
#         Example: --microarch="Intel Skylake"
#
#    Preserve the 'rr' traces of the bootstrap, server starts and mariabackup calls.
# --rr                                                                 \
#
#    Recommended settings (Info taken from rr help)
#    '--chaos' randomize scheduling decisions to try to reproduce bugs
#    '--wait'  Wait for all child processes to exit, not just the initial process.
#    Both settings do not depend on the hardware of the testing box.
# --rr_options='--chaos --wait'                                        \
#
#    rr_options required because of the hardware of the testing box like
# --rr_options='--chaos --wait --microarch=\"Intel Skylake\"'          \
#        Please becareful with the single and double quotes.
#    should be rather set in the file local.cfg.
#
# 9. SQL tracing within RQG (Client side tracing)
# --sqltrace=Simple                                                    \
# --sqltrace=MarkErrors                                                \
#

# perl -w -d:ptkdb ./rqg_batch.pl                                      \
#

# In case you distrust the rqg_batch.pl mechanics or the config file etc. than going with some
# limited number of trials is often useful.
# TRIALS=1
# PARALLEL=1
# TRIALS=2
# PARALLEL=2
# TRIALS=3
# PARALLEL=2
#

nohup perl -w ./rqg_batch.pl                                           \
--type=Combinator                                                      \
--parallel=$PARALLEL                                                   \
--basedir1=$BASEDIR1                                                   \
--basedir2=$BASEDIR2                                                   \
--config=$CONFIG                                                       \
--max_runtime=$MAX_RUNTIME                                             \
--trials=$TRIALS                                                       \
--discard_logs                                                         \
--no-mask                                                              \
--script_debug=_nix_                                                   \
> $PROT 2>&1 &

# Avoid that "tail -f ..." starts before the file exists.
wait_for_protocol
tail -n 40 -f $PROT

