#!/bin/bash

# set -x

# Typical use cases
# -----------------
# Have some simplified RQG test revealing some problem.
# Assume that a replay test based on
# - a client-side SQL trace
# - some other tool than RQG
# should be constructed.
#
# A) It looks like you might be able to transform the RQG test into some MTR based test.
#    Reasons and solutions:
#    - The RQG test replays with the setting "--threads=1"
#      --> Transform the client-side SQL trace to some MTR based test.
#          In case it makes sense than maybe simplify it further with the tool
#          "./util/simplify-mysqltest_e.pl".
#    - The RQG test replays with a small number of concurrent threads.
#      -->  Transform the client-side SQL trace to some MTR based test test using the 
#           inofficial tool "mysqltest_background.sh" of Matthias.
#
# B) Transform the client-side SQL trace to a test using pquery of Roel.
#      
# Please see this shell script rather as template how to call rqg_batch.pl even though
# it might be already in its current state sufficient for doing a lot around RQG.
#

export LANG=C
CALL_LINE="$0 $*"

if [ ! -e "./util/rqg_lib.sh" ]
then
    echo "ERROR: The curren working directory '$PWD' does not contain some RQG install."
    echo "       The required file './util/rqg_lib.sh' was not found."
    exit 4
fi

set -e
source util/rqg_lib.sh

set_simplifier_usage

# Config file for rqg_batch.pl containing
# - various settings for the RQG+server+InnoDB etc.
# - a text pattern for the failure to replay
# - the setup of the test to simplify
# Template: simplify_rqg_template.cfg
CONFIG="$1"
check_simplifier_config

# Path to MariaDB binaries for first server
BASEDIR1="$2"
check_basedir1
BASEDIR1_NAME=`basename "$BASEDIR1"`
BASEDIR2="$BASEDIR1"

set +e
# Check if there is already some running MariaDB or MySQL server or test
prevent_conflicts
# Calculate the maximum number of concurrent RQG tests
set_parallel

PROT="sql_replay_simp--""$CASE""--""$BASEDIR1_NAME"".prt"

# The size of a replay campaign is controlled by many limiters.
# -------------------------------------------------------------
# - the "exit" file   last_batch_workdir/exit
#   This file does not exist after rqg_batch.pl was called.
#   But as soon that file gets created by the user or similar rqg_batch.pl will stop all RQG runs.
# - Stop of testing as soon the elapsed runtime of testing campaign exceeds the value assigned to
#   --max_runtime or the default of 432000 (in seconds) = 5 days
#   We set "--max_runtime=$MAX_RUNTIME" in the current script.
#   Focus: Define the size of a testing campaign by a time related limit.
#          This is important for running 'production' like QA.
#          Per experience: total runtime < MAX_RUNTIME + 10s
# - Stop of testing as soon as the number of RQG runs regular finished exceeds the value assigned
#   to --trials or the default 99999.
#   The current script sets "TRIALS=1600" and later "--trials=$TRIALS".
#   Regular means: Not stopped by rqg_batch.pl because of whatever internal reason.
#   Focus: Bad Simplifier config or tests, defect in code of RQG or tools, exceptional bad DB server
#          and experiments
# - Stop of testing as soon as n RQG runs finished with the verdict 'replay' if
#   --stop_on_replay=<n> is set.
#   The current script sets "--stop_on_replay=1" --> n = 1.
#   This is sufficient for the main use cases of the script.
#   The simplifier config file (extension .cfg) to be used here should define which test outcome
#   counts as 'replay'.
#
TRIALS=1600
MAX_RUNTIME=7200

# There should be usually sufficient space in VARDIR for just a few fat core files caused by ASAN.
# Already the RQG runner will take care that everything important inside his VARDIR will be
# saved in his WORKDIR and empty his VARDIR. rqg_batch.pl will empty the VARDIR of this RQG
# runner again. So the space comsumption of a core is only temporary.
# The rqg_batch.pl ResourceControl will also take care to avoid VARDIR full.
# If its not an ASAN build than this environment variable is harmless anyway.
export ASAN_OPTIONS=abort_on_error=1,disable_coredump=0
echo "Have set "`env | grep ASAN`

# If an YY grammar was assigned than check it and offer it for editing
# Optional YY grammar
GRAMMAR="$3"
check_edit_optional_grammar

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
#    Please note that rr tracing enabled requires that archiving is not disabled.
#    The current script does not disable the archiving.
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
#    Stop after the n'th replay
# --stop_on_replay=<n>                                                 \
#    The current script sets
# --stop_on_replay=1                                                   \
#
# 8. Use "rr" (https://github.com/mozilla/rr/wiki/Usage) for tracing DB servers and other
#    programs.
#
#    Preserve the 'rr' traces of the bootstrap, server starts and mariabackup calls.
# --rr                                                                 \
#    RECOMMENDATION:
#    Use RR_REPLAY_SIMP.sh instead.
#
#    Recommended settings (Info taken from rr help)
#    '--chaos' randomize scheduling decisions to try to reproduce bugs
#    '--wait'  Wait for all child processes to exit, not just the initial process.
#    Both settings do not depend on the hardware of the testing box.
# --rr_options='--chaos --wait'                                        \
#    RECOMMENDATION:
#    Use RR_REPLAY_SIMP.sh instead.
#
# 9. SQL tracing within RQG (Client side tracing)
# --sqltrace=Simple                                                    \
#
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
--sqltrace=MarkErrors                                                  \
--type=RQG_Simplifier                                                  \
--parallel=$PARALLEL                                                   \
--basedir1=$BASEDIR1                                                   \
$GRAMMAR_PART                                                          \
--config=$CONFIG                                                       \
--max_runtime=$MAX_RUNTIME                                             \
--trials=$TRIALS                                                       \
--stop_on_replay=1                                                     \
--discard_logs                                                         \
--noarchiving                                                          \
--no-mask                                                              \
--script_debug=_nix_                                                   \
> $PROT 2>&1 &

# Avoid that "tail -f ..." starts before the file exists.
wait_for_protocol
tail -n 40 -f $PROT

