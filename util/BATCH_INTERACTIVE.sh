#!/bin/bash

export LANG=C

# Use case
# --------
# Generate some Shellscript for some RQG batch run taylored to the preferences
# of the user.
#

set -e
rm -f BATCH_tmp.sh

cat << EOF >> BATCH_tmp.sh
#!/bin/bash

# Typical use case
# ----------------
# Run a RQG testing campaign on MariaDB binaries.
#

export LANG=C
CALL_LINE="\$0 \$*"

EOF

if [ ! -e "./util/rqg_lib.sh" ]
then
    echo "ERROR: The curren working directory '$PWD' does not contain some RQG install."
    echo "       The required file './util/rqg_lib.sh' was not found."
    exit 4
fi

cat << EOF >> BATCH_tmp.sh
# set -x

if [ ! -e "./util/rqg_lib.sh" ]
then
    echo "ERROR: The curren working directory '\$PWD' does not contain some RQG install."
    echo "       The required file './util/rqg_lib.sh' was not found."
    exit 4
fi

EOF

set -e
source util/rqg_lib.sh

cat << EOF >> BATCH_tmp.sh
set -e
source util/rqg_lib.sh

set_combinator_usage

# Config file for rqg_batch.pl containing
# - various settings for the RQG+server+InnoDB etc.
# - tests to be executed
# Example: conf/mariadb/InnoDB_standard.cc
CONFIG="\$1"
check_combinator_config

# Path to MariaDB binaries for first server
BASEDIR1="\$2"
check_basedir1
BASEDIR1_NAME=\`basename "\$BASEDIR1"\`

# Path to MariaDB binaries for second server if required
BASEDIR2="\$3"
set_check_basedir2

set +e
# Check if there is already some running MariaDB or MySQL server or test
prevent_conflicts

PROT="batch--""\$CASE""--""\$BASEDIR1_NAME"".prt"

EOF

chmod 755 BATCH_tmp.sh

set -e
NPROC=`nproc`
LOAD_EXTREME=$(($NPROC * 3))
if [ $LOAD_EXTREME -gt 270 ]
then
    LOAD_EXTREME=270
fi
LOAD_MODERATE=$(($NPROC - 2))
if [ $LOAD_MODERATE -gt 270 ]
then
    LOAD_MODERATE=270
fi

set -o errexit

echo "Set up of the limitation of the maximum size of the testing "
echo "============================================================"
echo "The testing campaign will stop and clean up as soon as a limit was reached."
echo
echo "Maximum Runtime of testing campaign"
echo
echo "Type of testing campaign | Maximum runtime in s"
echo "-------------------------+---------------------"
echo "Excessive                | 27000"
echo "Medium                   | 3600"
echo "Short        (default)   | 1800"
echo
echo "Note: Maximum runtimes below 400s are not supported."
echo
echo "Which maximum runtime in seconds do you want? (just Enter -> default)"
echo
read MAX_RUNTIME
if [ "" == "$MAX_RUNTIME" ]
then
    MAX_RUNTIME=1800
fi
# https://unix.stackexchange.com/questions/151654/checking-if-an-input-number-is-an-integer
if ! [[ "$MAX_RUNTIME" =~ ^[0-9]+$ ]]
then
    echo "ERROR: Non integers found"
    exit 4
fi
if [ "$MAX_RUNTIME" -lt 400 ]
then
    echo "ERROR: maximum runtime values < 400 are not supported"
    exit 4
fi
echo "    MAX_RUNTIME in seconds: ->""$MAX_RUNTIME""<-"

echo
echo "Maximum number of regular finished tests"
echo
echo "Type of testing campaign | Maximum number"
echo "-------------------------+---------------"
echo "Huge                     | 10000"
echo "Medium                   | 3000"
echo "Small        (default)   | 1000"
echo
echo "Which maximum number of regular finished tests do you want? (just Enter -> default)"
echo
read TRIALS
if [ "" == "$TRIALS" ]
then
    TRIALS=1000
fi
if ! [[ "$TRIALS" =~ ^[0-9]+$ ]]
then
    echo "ERROR: Non integers found"
    exit 4
fi
if [ "$TRIALS" -lt 1 ]
then
    echo "ERROR: maximum number of regular finished tests < 1 are not supported"
    exit 4
fi
echo "    TRIALS: ->""$TRIALS""<-"

echo
echo "Set up of the maximum number of parallel RQG runs"
echo "    No of processing units of your box: $NPROC"
echo
echo "Load expected at test campaign runtime | MAX_PARALLEL value"
echo "=======================================+==================="
echo "Extreme      (recommended and default) | $LOAD_EXTREME"
echo "---------------------------------------+-------------------"
echo "Moderate                               | $LOAD_MODERATE"
echo "---------------------------------------+-------------------"
echo "User defined value                     | 0 < value <= 270"
echo
echo "Warning:"
echo "Per experience some low load (CPU and/or IO on virtual memory) on the box"
echo "reduces the likelihood (no of replays/no of regular finished test runs)"
echo "to replay some average concurrency bug."
echo
echo "Which maximum number of parallel RQG runs do you want? (just Enter -> default)"
echo
read MAX_PARALLEL
if [ "" == "$MAX_PARALLEL" ]
then
    MAX_PARALLEL=$LOAD_EXTREME
fi
if ! [[ "$MAX_PARALLEL" =~ ^[0-9]+$ ]]
then
    echo "ERROR: Non integers found"
    exit 4
fi
if [[ $MAX_PARALLEL -lt 1 && $MAX_PARALLEL -gt 270 ]]
then
    echo "ERROR: MAX_PARALLEL values < 1 or > 270 are not supported."
    exit 4
fi
echo "    MAX_PARALLEL: ->""$MAX_PARALLEL""<-"

echo
echo "Setup if the test or some fraction of them use DB server running under rr"
echo "========================================================================="
echo
echo "Please be aware that"
echo "- there is some not that small share of bugs which will not be replayed at"
echo "  all in case 'rr' is invoked."
echo "- the likelihood to replay some bug without invoking 'rr' is in average"
echo "  three times higher than with rr."
echo "- there are some incompatibilities between 'rr' and the MariaDB server"
echo "  causing that some tests might fail because of that."
echo
echo "Variant     | Percentage of | Properties and recommendation"
echo "            | tests with rr |"
echo "------------+---------------+-----------------------------------------------"
echo "n (off)     |          0 %  | Advantage: Fastest variant for getting a rough"
echo "            |               | overview about the bugs the server suffers from."
echo "            |               | Disadvantage: No rr tracing at all."
echo "            |               | Recommended for"
echo "            |               | - basic acceptance testing."
echo "            |               | - checking if some bug can be replayed or not."
echo "------------+---------------+-----------------------------------------------"
echo "a (all)     |        100 %  | Advantage: Fastest variant for getting rr traces."
echo "            |               | Disadvantage: Less efficient when needing a"
echo "            |               | rough overview about about the bugs ... fast".
echo "            |               | Recommended for:"
echo "            |               | Need a trace for some specific bug fast."
echo "------------+---------------+-----------------------------------------------"
echo "(default)   | Set nothing and get what the test campaign config file maybe sets."
echo "            | Most config files set 66% with \"rr\" and 33% without."
echo "            | Advantage: Have the chance to get rr traces for new bugs."
echo "            | Disadvantage: Less efficient for getting a rough overview fast."
echo "            | Recommended for:"
echo "            | You have a strong box preferably dedicated for testing only,"
echo "            | do not need to avoid some extreme load or long total runtime"
echo "            | and want to run a huge stress testing campaign."


echo
echo "Which Variant do you want? ("o","a" or just Enter -> default)"
echo
read RR_VARIANT
if [[ "$RR_VARIANT" != '' && "$RR_VARIANT" != 'n' && "$RR_VARIANT" != 'a' ]]
then
    echo "ERROR: The variant value ->""$RR_VARIANT""<- is not supported."
    exit 4
fi
echo "    RR_VARIANT: ->""$RR_VARIANT""<-"
echo
if [[ "$RR_VARIANT" == '' ]]
then
    USE_RR=""
elif [[ $RR_VARIANT == 'n' ]]
then
    USE_RR="--rr=''"
elif [[ $RR_VARIANT == 'a' ]]
then
    USE_RR="--rr='rr record --chaos --wait'"
fi
echo "    USE_RR (calculated based on the RR_VARIANT picked): ->""$USE_RR""<-"
echo

cat << EOF >> BATCH_tmp.sh
# The size of a testing campaign is controlled by many limiters.
# --------------------------------------------------------------
# - the "exit" file   last_batch_workdir/exit
#   This file does not exist after rqg_batch.pl was called.
#   But as soon that file gets created by the user or similar rqg_batch.pl will stop all RQG runs.
# - a function in lib/Batch.pm
#   In order to avoid some significant waisting of resources abort of testing as soon as some quota
#   of failing tests gets exceeded.
#   Typical reasons for such an early abort are:
#   - Bad Combinator config file or tests
#   - exceptional faulty DB server
#   - defect in code of RQG or tools
# - Stop of testing as soon the elapsed runtime of testing campaign exceeds the value assigned to
#   --max_runtime or the default of 432000 (in seconds) = 5 days
#   We set "--max_runtime=\$MAX_RUNTIME" in the current script.
#   Focus: Define the size of a testing campaign by a time related limit.
#          This is important for running 'production' like QA.
#          Per experience: total runtime < MAX_RUNTIME + 10s
# - Stop of testing as soon as the number of RQG runs regular finished exceeds the value assigned
#   to --trials or the default 99999.
#   We set "--trials=\$TRIALS" in the current script.
#   Regular means: Not stopped by rqg_batch.pl because of whatever internal reason.
#   Focus: Bad Combinator config or tests, defect in code of RQG or tools, exceptional bad DB server
#          and experiments
# - Stop of testing as soon as n RQG runs finished with the verdict 'replay'.
#   It is not recommended to set --stop_on_replay at all in the current script because it is
#   for QA production. If needed use REPLAY_BATCH.sh or some derivate of it instead.
#
MAX_RUNTIME=$MAX_RUNTIME
TRIALS=$TRIALS
MAX_PARALLEL=$MAX_PARALLEL

# Take care that we can get core files if running with ASAN
# ---------------------------------------------------------
# There should be at sufficient space for a few fat core files in the filesystem containing the
# VARDIR at any time. The rqg_batch.pl ResourceControl will also prevent a VARDIR full.
# If its not an ASAN build than this environment variable should be harmless anyway.
export ASAN_OPTIONS=abort_on_error=1,disable_coredump=0
echo "Have set "\`env | grep ASAN\`
# Harmless on non-MSAN builds. Disables use-after-dtor poisoning, which is
# reused across the plugin dlopen/dlclose loop and yields false positives.
export MSAN_OPTIONS=poison_in_dtor=0
echo "Have set "\`env | grep MSAN\`

rm -f "\$PROT"

set -o pipefail

# Options (Hint: Please take care that there must be a '\' at line end.)
# ----------------------------------------------------------------------
# 1. Remove the logs of RQG test runs achieving STATUS_OK/verdict 'ignore_*'.
#    Their stuff grammar/datadir was not archived and is already thrown away.
#    So basically:
#    Do not assign '--discard_logs' in case you want to see logs of RQG runs which achieved
#    the verdict 'ignore_*' (blacklist match or STATUS_OK or stopped by rqg_batch.pl).
#    The current scripts sets '--discard_logs'.
# --discard_logs                                                       \\
#
# 2. Per default of rqg_batch.pl the data (data dir of server, core etc.) of some RQG test
#    replaying a problem or being at least of interest gets archived.
#    In case you do not want that archiving than you can disable it.
#    But that is rather suitable for runs of the test simplifier only.
#    Please note that rr tracing enabled requires that archiving is not disabled.
# --noarchiving                                                        \\
#
# 3. Do not abort if hitting Perl errors or STATUS_ENVIRONMENT_FAILURE. IMHO some rather
#    questionable option. I am unsure if that option gets correct handled in rqg_batch.pl.
# --force                                                              \\
#
# 4. Debugging of the rqg_batch.pl tool machinery and rqg.pl
#    Default: Minimal debug output.
#    Assigning '_all_' causes maximum debug output.
#    Warning: Significant more output of especially rqg_batch.pl and partially rqg.pl.
# --script_debug=_all_                                                 \\
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
# --no-mask                                                            \\
#
# 6. rqg_batch.pl prints how it would start RQG Workers and the RQG Worker started "fakes" that
#    it has achieved the verdict assigned. == There all no "real" RQG runs at all.
#    Example:
#    --dryrun=replay --> All RQG Worker started "tell" that they have achieved some replay.
#    Use cases:
#    a) When using the Combinator see which combinations would get generated.
#    b) When using the Simplifier see how it would be tried to shrink the grammar.
#    c) --dryrun=ignore_unwanted  see a) or b) and how TRIALS would be the limiter.
# --dryrun=ignore_unwanted                                             \\
# --dryrun=replay                                                      \\
#
# 7. rqg_batch stops immediate all RQG runner if reaching the assigned number of replays
#    This requires that the combinator config file contains a definition of what is a replay.
#    It is a rare used feature.
#    Stop after the first replay
# --stop_on_replay                                                     \\
#    Stop after the n'th replay
# --stop_on_replay=<n>                                                 \\
#
# 8. Use "rr" (https://github.com/mozilla/rr/wiki/Usage) for tracing DB servers and other
#    programs.
#
#    It is possible to assign within the RQG Combinator config file
#    - if rr should be invoked
#    - which rr_options should be set.
#    Example: conf/mariadb/InnoDB_standard.cc
#    - 67% of all tests invoke "rr", 33% of all tests go without "rr"
#    - 50% of the tests invoking "rr" go with the rr_options='--chaos --wait'
#      50% of the tests invoking "rr" go with the rr_options='--wait'
#    A high fraction of other config files do this too.
#
#    This behaviour can be overridden in the following way:
#
#    Ensure that "rr" will be invoked
# --rr='rr record --chaos --wait'                                      \\
#    Ensure that "rr" will be not invoked
# --rr=''                                                              \\
#    Accept what the RQG Combinator config file maybe dictates.
# \\
#
# 9. SQL tracing within RQG (Client side tracing)
#    Trace SQL's sent to the DB server
# --sqltrace=Simple                                                    \\
#    Trace SQL's sent to the DB server and its response (error code only)
# --sqltrace=MarkErrors                                                \\
#
#
# In case you distrust the rqg_batch.pl mechanics or the config file etc. than going with some
# limited number of concurrent RQG runs and/or trials is often useful.
# TRIALS=1
# PARALLEL=1
# TRIALS=2
# PARALLEL=2
#

EOF

cat << EOF >> BATCH_tmp.sh
nohup perl -w ./rqg_batch.pl                                           \\
--type=Combinator                                                      \\
--parallel=\$MAX_PARALLEL                                               \\
--basedir1="\$BASEDIR1"                                                 \\
--basedir2="\$BASEDIR2"                                                 \\
--config="\$CONFIG"                                                     \\
--max_runtime=\$MAX_RUNTIME                                             \\
--trials=\$TRIALS                                                       \\
EOF
echo "$USE_RR                                                          \\" >> BATCH_tmp.sh
cat << EOF >> BATCH_tmp.sh
--discard_logs                                                         \\
--no-mask                                                              \\
--script_debug=_nix_                                                   \\
> "\$PROT" 2>&1 &

# Avoid that "tail -f ..." starts before the file exists.
wait_for_protocol
tail -n 40 -f "\$PROT"

EOF


echo "A shellscript './BATCH_tmp.sh' containing your settings was generated."
echo "Please"
echo "- change the name of the script to a name describing its purpose"
echo "      Example: BATCH_basic.sh"
echo "  because the next call of $0 will replace it."
echo "- to adjust it further to your needs."
echo
echo "Its usage would than be:"
echo
echo "./BATCH_basic.sh <Config file for testing campaign> <Basedir1 == path to MariaDB binaries> [<Basedir2>]"
echo

exit 0

