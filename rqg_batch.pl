#!/usr/bin/perl

# Copyright (c) 2018, 2019 MariaDB Corporation Ab.
# Use is subject to license terms.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301
# USA
#

# Note about history and future of this script:
# ---------------------------------------------
# The concept and code here is only in small portions based on
# - util/bughunt.pl
#   - Per just finished RQG run immediate judging based on status + text patterns
#     and creation of archives + first cleanup (all moved to rqg.pl)
#   - unification regarding storage places
# - combinations.pl
#   Parallelization + combinations mechanism
# There we have GNU General Public License version 2 too and
# Copyright (c) 2008, 2011 Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2013, Monty Program Ab.
# Copyright (c) 2018, MariaDB Corporation Ab.
#
# The amount of parameters (call line + config file) is in the moment
# not that stable.
# On the long run the current script should replace
# - util/bughunt.pl
# - combinations.pl
# - util/simplify-grammar.pl
#   and even util/new-simplify-grammar.pl
#

use strict;
use Carp;
use Cwd;
use Time::HiRes;
use POSIX ":sys_wait_h"; # for nonblocking read
use File::Basename;
use File::Path qw(make_path);
use File::Copy;
use lib 'lib';
use lib "$ENV{RQG_HOME}/lib";
use Auxiliary;
use Verdict;
use Batch;
use Combinator;
use Simplifier;
use GenTest;
use GenTest::Random;
use GenTest::Constants;
use Getopt::Long;
use Data::Dumper;

use ResourceControl;

# Structure for managing RQG Worker (child processes)
# ---------------------------------------------------
# RQG Worker 'life'
# 0. Get forked by the parent (rqg_batch.pl) process and "know" already at begin of life detailed
#    which RQG run to initiate later.
# 1. Make some basic preparations of the "play ground".
# 2. Switch to the RQG runner (usually rqg.pl) via Perl 'exec'.
# -- What follows is some brief description what this RQG runner does --
# 3. Analyze the parameters/options provided via command line. In future maybe also config files.
# 4. Compute all values which distinct him from other RQG workers (workdir, vardir, build thread)
#    but will be the same when he makes his next RQG run.
# 3. Append these values to the RQG call.
# 4. Start the RQG run with system.
# 5. Make some analysis of the result and report the verdict.
# 6. Perform archiving if needed, cleanup, signal that the work is finished and exit.
# The parent has to perform some bookkeeping about the actual state of the RQG workers in order to
# - avoid double use of such a worker (Two RQG tests would meet on the same vardirs, ports etc.!)
# - be capable to stop active RQG worker whenever it is recommended up till required.
#   Typical reasons: Regular test end, resource trouble ahead, tricks for faster replay etc.
#
my @worker_array = ();
# The pid got. Used for checking if that RQG worker is active/alive, maybe stopping him, avoiding
# to get zombie processes et.
use constant WORKER_PID       => 0;
# Point of time after the process of the RQG worker was forked and has taken over his job.
# Maybe used in future for
# - limiting the runtime of a RQG worker
# - computing the total runtime of a RQG worker in case the corresponding information cannot be
#   found in the log of the RQG worker.
use constant WORKER_START     => 1;
# The id of the order (--> @order_array) which was used to construct the RQG call of the RQG worker.
# This is used for bookkeeping in order to
# - (combinations or variations): achieve maximum/required functional coverage by
#   - minimizing holes in the first range of orders executed
#     Example:
#     - Order 1 till 10 executed with regular finish is better than
#       Order 1 till 15 executed with regular finish except 2 4 7 and 12
#   - not repeating the execution of orders which already had some execution with regular finish
#     as long as other orders were never tried and are not already in execution.
# - (grammar simplifier): Bookkeeping in order to optimize the grammar simplification process.
use constant WORKER_ORDER_ID  => 2;
# Three variables for stuff being
# - not full and even not  half static like @order_array content
# - full dynamic (calculated/decided) direct before the fork of the RQG Worker. And we need to
#   memorize that value when the worker finished for valuating his result.
#   Example for to be developed advanced grammar simplification:
#   Orders like for example
#      Try to remove the component/alternative "UPDATE ...." from the rule "dml" could be
#      executed depending on the outcome of its last execution and the results of competing runs
#      more than once. And the final grammar used is the current best grammar known with
#      that removal applied if doable.
#   So we need to memorize which current best grammar was used for such a run.
#   Another example is the maximum runtime allowed to this run because this runtime will be
#   adapted during the progressing grammar simplification.
#   - CL_snippet (gendata etc. but not grammar) which is the same for any RQG run serving
#     grammar simplification
#   - grammar to be used <m>.yy for the replay attempt
#     Attention: The RQG runner will later work with his personal copy named rqg.yy.
#   - parent grammar b<n>.yy which was used for constructing the grammar <m>.yy by applying
#     the simplification (*) WORKER_ORDER_ID is pointing to.
#     The parent grammar is the best known grammar (b<n>.yy with highest <n>) at the time of
#     generation of <m>.yy.
#     (*) Something like "remove the component 'DROP TABLE t1' from the rule 'query'".
#   - grammar to be used <m>.yy
#     Attention: The RQG runner will later work with his personal copy named rqg.yy.
#   - maximum runtime for the RQG run assigned
#     Only relevant in case we go with adaptive runtimes.
#     This is some extrapolated timespan for the complete RQG run (gendata + duration(gentest)
#     + comparison if required + archiving + ...) which should ensure that >= 85% of all simplified
#     grammars which are capable to replay have replayed.
#     So in some sense this runtime defines what some sufficient long run is and the size changes
#     during the simplification process.
use constant WORKER_EXTRA1    => 3; # child grammar == grammar used if Simplifier
use constant WORKER_EXTRA2    => 4; # parent grammar if Simplifier
use constant WORKER_EXTRA3    => 5; # adapted duration if Simplifier
use constant WORKER_END       => 6;
# In case a 'stop_worker' had to be performed than WORKER_END will be set to the current timestamp
# when issuing the SIGKILL that RQG worker processgroup.
# When 'reap_worker' gets active the following should happen
# if defined WORKER_END
#    make a note within the RQG log of the affected worker that he was stopped
#    set verdict to VERDICT_IGNORE_STOPPED etc.
# else
#    set WORKER_END will be set to the current timestamp
#

# Name of the convenience symlink if symlinking supported by OS
use constant BATCH_WORKDIR_SYMLINK    => 'last_batch_workdir';

# FIXME: Are these variables used?
my $next_order_id    = 1;

my $command_line= "$0 ".join(" ", @ARGV);

$| = 1;

my $batch_start_time = time();


#---------------------
my $rqg_home;
my $rqg_home_call = Cwd::abs_path(File::Basename::dirname($0));
my $rqg_home_env  = $ENV{'RQG_HOME'};
my $start_cwd     = Cwd::getcwd();
#---------------------

# FIXME: Harden that
# rqg_batch.pl and RQG_HOME if assigned must be from the same universe
if (defined $rqg_home_env) {
    print("WARNING: The variable RQG_HOME with the value '$rqg_home_env' was found in the " .
          "environment.\n");
    if (osWindows()) {
        $ENV{RQG_HOME} = $ENV{RQG_HOME}.'\\';
    } else {
        $ENV{RQG_HOME} = $ENV{RQG_HOME}.'/';
    }
} else {
    $ENV{RQG_HOME} = dirname(Cwd::abs_path($0));
}
$rqg_home = $rqg_home_call;

if ( osWindows() )
{
    require Win32::API;
    my $errfunc = Win32::API->new('kernel32', 'SetErrorMode', 'I', 'I');
    my $initial_mode = $errfunc->Call(2);
    $errfunc->Call($initial_mode | 2);
};

my $logger;
eval
{
    require Log::Log4perl;
    Log::Log4perl->import();
    $logger = Log::Log4perl->get_logger('randgen.gentest');
};

$| = 1;
my $ctrl_c = 0;

# FIXME: Discover Which impact has the value within $ctrl_c?
#
# SIGINT should NOT lead to some abort of the rqg_batch.pl run.
# A
#     $SIG{INT}  = sub { Batch::emergency_exit("INFO: SIGTERM or SIGINT received. " .
#                               "Will stop all RQG worker and exit without cleanup.", STATUS_OK) };
# would cause exact some abort with cleanup but without summary.
$SIG{INT}  = sub { $ctrl_c = 1 };
# SIGTERM should lead to some abort with cleanup but without summary.
$SIG{TERM} = sub { Batch::emergency_exit("INFO: SIGTERM or SIGINT received. Will stop all RQG worker " .
                                         "and exit without cleanup.", STATUS_OK) };
$SIG{CHLD} = "IGNORE" if osWindows();

my ($config_file, $basedir, $vardir, $trials, $build_thread, $duration, $grammar, $gendata,
    $seed, $testname, $xml_output, $report_xml_tt, $report_xml_tt_type, $max_runtime,
    $report_xml_tt_dest, $force, $no_mask, $exhaustive, $start_combination, $dryrun, $noLog,
    $workers, $servers, $noshuffle, $workdir, $discard_logs,
    $help, $help_simplifier, $help_combinator, $help_verdict, $runner,
    $stop_on_replay, $script_debug, $runid, $threads, $type, $algorithm);

# my @basedirs    = ('', '');
my @basedirs;


$discard_logs  = 0;

# FIXME:
# Modify these options.
# --debug
# This should rather focus on debugging of the current script.
# ------------
# --no-log
# Figure out what is does.
# Printing the output of comninations.pl and also the output of the RQG runners to
# sceen makes no sense. Too much too mixed content.
# ------------
# --force how it works here is quite questionable in several aspects
# 1. In case of not that good setups, grammars and/or certain trouble in server
#    likely STATUS_ENVIRONMENT_FAILURE
#    not likely perl errors could happen.
#    So some fault tolerance makes at least a bit sense.
# 2. On the other hand:
#    Its questionable if too lazy programming/setups/comb config files should get
#    that much comfort.
# 3. MTR makes that better though also not perfect.
# 4. Default should be:
#    In case the first chunk of tests (10 or 20) dies early
#    (loading of grammars/validators, maybe bootstrap and similar) than the run
#    should be aborted.
#    Lets say: In case the early failing tests are
#              >= 50% of all tests executed and their number is alreay >= 10.
#    Some reduced use of STATUS_ENVIRONMENT_FAILURE and distinct more different
#    bad statuses seem to be required.
#    For the moment: Do not change the current semantics.
# 5. no-mask
#    Applying masking everywhere might be good for optimizer tests but is poison
#    for concurrency tests.
#    1. Flip the default masking off!
#    2. Preserve the no-mask (-> override the setting from config file)
#

# Take the options assigned in command line and
# - fill them into the variables allowed in command line
# - abort in case of meeting some not supported options
my $opt_result = {};
sub help();

# Read certain command line options
# =================================
# - Read all options (GetOptions removes all options found from @ARGV) which do not need to
#    be passed to any module in the list Combinator, Simplifier, Variator, Replayer
# - 'pass_through' causes that we do not abort in case meeting some option which is not listed here.
# Example:
# 'threads'
# 1. In case the value is assigned on command line than
# 1.1 rqg_batch could
#     memorize it, not pass it through to Combinator, Variator, Replayer and glue it to every RQG call.
# 1.2 if the Simplifier is used rqg_batch needs to pass that value through to Simplifier because
#     that value is used for optimizing the simplification
#     Example: If thread = 3 than any thread_< n>3 >_* becomes never used.
# 2. In case the value is not assigned on command line but can be assigned in config file than
#    the config file reader (Combinator, Simplifier, Variator, Replayer) will read the value and
#    needs to pass it somehow back to rqg_batch.
# Problem with 'pass_through'
#    rqg.pl call was with
#    --dryrun     \   <== mandatory value is missing!!
#    --parallel=2 \
#    --threads=2
# Later $dryrun contained '--parallel=2' and $parallel was undef.
Getopt::Long::Configure('pass_through');
if (not GetOptions(
#   $opt_result,
           'help'                      => \$help,
           'help_simplifier'           => \$help_simplifier,
           'help_combinator'           => \$help_combinator,
           'help_verdict'              => \$help_verdict,
           ### type == Which type of campaign to run
           # pass_through: no
           'type=s'                    => \$type,        # Swallowed and handled by rqg_batch
           ### config == Details of campaign setup
           # Check existence of file here. pass_through as parameter
           'config=s'                  => \$config_file, # Check+set here but pass as parameter to Combinator etc.
           ### basedir<n>
           # Check here if assigned basedir<n> exists.
           # Do not pass_through. Glue to end of rqg.pl call.
####       'basedir=s'                 => \$basedirs[0],
           'basedir1=s'                => \$basedirs[1], # Swallowed and handled by rqg_batch
           'basedir2=s'                => \$basedirs[2], # Swallowed and handled by rqg_batch
           'basedir3=s'                => \$basedirs[3], # Swallowed and handled by rqg_batch
           'workdir=s'                 => \$workdir,     # Check+set here but pass as parameter to Combinator etc.
           'vardir=s'                  => \$vardir,      # Swallowed and handled by rqg_batch
           'build_thread=i'            => \$build_thread, # Swallowed and handled by rqg_batch
#          'trials=i'                  => \$trials,      # Pass through (@ARGV) to Combinator ...
#          'duration=i'                => \$duration,    # Pass through (@ARGV) to Combinator ...
#          'seed=s'                    => \$seed,        # Pass through (@ARGV) to Combinator ...
           'force'                     => \$force,                  # Swallowed and handled by rqg_batch
#          'no-mask'                   => \$no_mask,     # Pass through (@ARGV) to Combinator ...
#          'grammar=s'                 => \$grammar,     # Pass through (@ARGV) to Combinator ...
           'gendata=s'                 => \$gendata,                # Currently handle here
           'testname=s'                => \$testname,               # Swallowed and handled by rqg_batch
           'xml-output=s'              => \$xml_output,             # Swallowed and handled by rqg_batch
           'report-xml-tt'             => \$report_xml_tt,          # Swallowed and handled by rqg_batch
           'report-xml-tt-type=s'      => \$report_xml_tt_type,     # Swallowed and handled by rqg_batch
           'report-xml-tt-dest=s'      => \$report_xml_tt_dest,     # Swallowed and handled by rqg_batch
#          'run-all-combinations-once' => \$exhaustive,             # Pass through (@ARGV). Combinator maybe needs that
#          'start-combination=i'       => \$start_combination,      # Pass through (@ARGV). Combinator maybe needs that
#          'no-shuffle'                => \$noshuffle,              # Pass through (@ARGV). Combinator maybe needs that
           'max_runtime=i'             => \$max_runtime,            # Swallowed and handled by rqg_batch
           'dryrun=s'                  => \$dryrun,                 # Swallowed and handled by rqg_batch
           'no-log'                    => \$noLog,                  # Swallowed and handled by rqg_batch
           'parallel=i'                => \$workers,                # Swallowed and handled by rqg_batch
           # runner
           # If
           # - defined than
           #   - check existence etc.
           #   - wipe out any runner if in call line snip returned by module
           # - not defined or '' than
           #   If runner in call line snip returned by module than use that.
           #   If no runner in call line snip than use 'rqg.pl'.
           'runner=s'                  => \$runner,                 # Swallowed and handled by rqg_batch
           'stop_on_replay'            => \$stop_on_replay,         # Swallowed and handled by rqg_batch
           'servers=i'                 => \$servers,                # Swallowed and handled by rqg_batch
#          'threads=i'                 => \$threads,                # Pass through (@ARGV).
           'discard_logs'              => \$discard_logs,           # Swallowed and handled by rqg_batch
           'discard-logs'              => \$discard_logs,
           'script_debug=s'            => \$script_debug,           # Swallowed and handled by rqg_batch
           'runid:i'                   => \$runid,                  # Swallowed and handled by rqg_batch
                                                   )) {
    # Somehow wrong option.
    help();
    safe_exit(STATUS_ENVIRONMENT_FAILURE);
};

# Support script debugging as soon as possible.
#
if (not defined $script_debug) {
    $script_debug = '';
}
Auxiliary::script_debug_init($script_debug);

# Do not fiddle with other stuff when only help is requested.
if (defined $help) {
    help();
    safe_exit(0);
} elsif (defined $help_combinator) {
    Combinator::help();
    safe_exit(0);
} elsif (defined $help_simplifier) {
    Simplifier::help();
    safe_exit(0);
} elsif (defined $help_verdict) {
    Verdict::help();
    safe_exit(0);
}


# For testing
# $type='omo';
Batch::check_and_set_batch_type($type);

check_and_set_config_file();


# Variable for stuff to be glued at the end of the rqg.pl call.
my $cl_end = ' ';

# For testing:
# $basedirs[1] = '/weg';
foreach my $i (1..3) {
    next if not defined $basedirs[$i];
    next if $basedirs[$i] eq '';
    if (-d $basedirs[$i]) {
        $cl_end .= "--basedir" . "$i" . "=" . $basedirs[$i] . " ";
    } else {
        say("ERROR: basedir" . $i . " is set to '" . $basedirs[$i] .
            "' but does not exist or is not a directory.");
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }
}
# say("cl_end ->$cl_end<-");

# $workdir, $vardir are the "general" work/var directories of rqg_batch.pl run.
# The corresponding directories of the RQG runs get later calculated on the fly and than glued
# to the RQG call.
($workdir, $vardir) = Batch::make_multi_runner_infrastructure ($workdir, $vardir, $runid,
                                                               BATCH_WORKDIR_SYMLINK);
my $load_status;
($load_status, $workers) = ResourceControl::init($workdir, $vardir, $workers, 1);
Batch::check_and_set_workers($workers);
if($load_status ne ResourceControl::LOAD_INCREASE) {
    my $status = STATUS_ENVIRONMENT_FAILURE;
    say("ERROR: ResourceControl reported the load status '$load_status' but around begin the " .
        "status '" . ResourceControl::LOAD_INCREASE . "' must be valid.");
    safe_exit($status);
}
$workers = undef;

# $build_thread is valid for the rqg_batch.pl run.
# The corresponding build_thread of the single RQG runs get calculated on the fly and than glued
# to the RQG call.
$build_thread = Auxiliary::check_and_set_build_thread($build_thread);
if (not defined $build_thread) {
    my $status = STATUS_ENVIRONMENT_FAILURE;
    say("ERROR: check_and_set_build_thread failed. " . Auxiliary::exit_status_text($status));
    safe_exit($status);
}

if (defined $gendata) {
    $cl_end .= "--gendata=$gendata ";
    if ($gendata ne '' and not -f $gendata) {
        say("ERROR: gendata is set to '" . $gendata .
            "' but does not exist or is not a plain file.");
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }
}

$cl_end .= "--testname=$testname " if defined $testname and $testname ne '';
$cl_end .= " --xml-output=$xml_output "
    if defined $xml_output and $xml_output ne '';
$cl_end .= " --report-xml-tt" if defined $report_xml_tt;
$cl_end .= " --report-xml-tt-type=$report_xml_tt_type "
    if defined $report_xml_tt_type and $report_xml_tt_type ne '';
$cl_end .= " --report-xml-tt-dest=$report_xml_tt_dest "
    if defined $report_xml_tt_dest and $report_xml_tt_dest ne '';
$cl_end .= "--script_debug=$script_debug " if defined $script_debug and $script_debug ne '';

if (defined $runner) {
    if (File::Basename::basename($runner) ne $runner) {
        say("Error: The value for the RQG runner '$runner' needs to be without any path.");
        safe_exit(4);
    }
    # For experimenting
    # $runner = 'mimi';
    $runner = $rqg_home . "/" . $runner;
    if (not -e $runner) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: The RQG runner '$runner' does not exist. " .
            Auxiliary::exit_status_text($status));
        safe_exit($status);
    }
}

Batch::check_and_set_dryrun($dryrun);
Batch::check_and_set_stop_on_replay($stop_on_replay);

Batch::check_and_set_discard_logs($discard_logs);


# Counter for statistics
# ----------------------
my $runs_started          = 0;
my $runs_stopped          = 0;

say("DEBUG: rqg_batch.pl : Leftover after the ARGV processing : ->" . join(" ", @ARGV) . "<-")
    if Auxiliary::script_debug("T2");
say("cl_end ->$cl_end<-") if Auxiliary::script_debug("T4");


if      ($Batch::batch_type eq Batch::BATCH_TYPE_COMBINATOR) {
    Combinator::init($config_file, $workdir);
} elsif ($Batch::batch_type eq Batch::BATCH_TYPE_RQG_SIMPLIFIER) {
    Simplifier::init($config_file, $workdir);
} else {
    say("INTERNAL ERROR: The batch type '$Batch::batch_type' is unknown. Abort");
    safe_exit(4);
}

# if (not defined $runner) {
#     $runner = "rqg.pl";
#     say("INFO: The RQG runner was not assigned. Will use the default '$runner'.");
# }

####
say("DEBUG: Command line options to be appended to the call of the RQG runner: ->" .
    $cl_end . "<-") if Auxiliary::script_debug("T1");


if (not defined $max_runtime) {
    $max_runtime = 432000;
    my $max_days = $max_runtime / 24 / 3600;
    say("INFO: rqg_batch.pl : Setting the maximum runtime to the default of $max_runtime" .
        "s ($max_days days).");
}
my $batch_end_time = $batch_start_time + $max_runtime;

# system("find $workdir $vardir");

my $logToStd = !osWindows() && !$noLog;

say("DEBUG: logToStd is ->$logToStd<-") if Auxiliary::script_debug("T1");


# FIXME: Rather wrong place for define
my $worker_id;


my $exit_file    = $workdir . "/exit";
my $result_file  = $workdir . "/result.txt";

my $total_status = STATUS_OK;

my $trial_num = 1; # This is the number of the next trial if started at all.
                   # That also implies that incrementing must be after getting a valid command.

while($Batch::give_up <= 1) {
    say("DEBUG: Begin of while(...) loop. Next trial_num is $trial_num.")
        if Auxiliary::script_debug("T6");
    # First handle all cases for giving up.
    # 1. The user created $exit_file for signalling rqg_batch.pl that it should stop.
    # For experimenting:
    # system("touch $exit_file");
    Batch::check_exit_file($exit_file);
    last if $Batch::give_up > 1;
    # 2. The assigned max_runtime is exceeded.
    Batch::check_runtime_exceeded($batch_end_time);
    last if $Batch::give_up > 1;
    # 3. Resource problem is ahead.
    my $delay_start = Batch::check_resources();
    last if $Batch::give_up > 1;

    my $just_forked = 0;

    my $free_worker = Batch::get_free_worker;
    if (defined $free_worker        # We have a free (inactive) RQG worker.
        and 0 == $Batch::give_up    # We do not need to bring the current phase of work to an end.
        and not $delay_start    ) { # We have no resource problem.
        # We count per bookkeeping active RQG workers and hand it to ...::get_job.
        # This allows get_job to judge if an ordered switch_phase (--> Simplifier only) is called
        # in the right situation.
        my $active_workers = Batch::count_active_workers();

        my @job;
        if      ($Batch::batch_type eq Batch::BATCH_TYPE_COMBINATOR) {
            # ($order_id, $cl_snip)
            @job = Combinator::get_job($active_workers);
        } elsif ($Batch::batch_type eq Batch::BATCH_TYPE_RQG_SIMPLIFIER) {
            # ...REPLAY
            # ($order_id, $cl_snip, grammar      , undef)
            # ...GRAMMAR_SIMP
            # ($order_id, $cl_snip, child grammar, parent_grammar, adapted_duration)
            @job = Simplifier::get_job($active_workers);
            # use constant JOB_CL_SNIP    => 0;
            # use constant JOB_ORDER_ID   => 1;
            # use constant JOB_MEMO1      => 2;  # Child  grammar or Child rvt_snip
            # use constant JOB_MEMO2      => 3;  # Parent grammar or Parent rvt_snip
            # use constant JOB_MEMO3
        } else {
            # In case we ever land here than its before any worker was started.
            # So exiting should not make trouble later.
            say("INTERNAL ERROR: The batch type '$Batch::batch_type' is unknown. Abort");
            safe_exit(4);
        }

        my $order_id = $job[Batch::JOB_ORDER_ID];
        if (not defined $order_id) {
            # ...::get_job did not found an order
            # == @try_first_queue and @try_queue were empty and ...::generate_orders gave nothing.
            # == All possible orders were generated.
            #    Some might be in execution and all other must be in @try_over_queue.
            say("DEBUG: No order got") if Auxiliary::script_debug("T6");
        } else {
            # We have now a free/non busy RQG runner and a job
            say("DEBUG: Preparing command for RQG worker [$free_worker] based on valid " .
                "order $order_id.") if Auxiliary::script_debug("T6");
            my $cl_snip = $job[Batch::JOB_CL_SNIP];

            say("DEBUG: cl_snip returned by Module is =>" . $cl_snip . "<=")
                if Auxiliary::script_debug("T6");
            if (not defined $cl_snip) {
                Carp::cluck("INTERNAL ERROR: job[Batch::JOB_CL_SNIP] is undef. Abort.");
                my $status = STATUS_INTERNAL_ERROR;
                Batch::emergency_exit($status);
            }

            if (defined $runner and $runner ne '') {
                $cl_snip = "$runner $cl_snip";
            } else {
                # Take the default RQG runner
                $cl_snip = "rqg.pl $cl_snip";
            }

            say("Job generated : $order_id § $cl_snip") if Auxiliary::script_debug("T5");

            # OPEN
            # ----
            # - append RQG Worker specific stuff
            # - append $cl_end
            # - glue "perl .... $rqg_home/" to the begin.
            # - enclose on non WIN with bash .....

            my $command = $cl_snip;

            $Batch::worker_array[$free_worker][Batch::WORKER_ORDER_ID] = $order_id;
            $Batch::worker_array[$free_worker][Batch::WORKER_EXTRA1]   = $job[Batch::JOB_MEMO1];
            $Batch::worker_array[$free_worker][Batch::WORKER_EXTRA2]   = $job[Batch::JOB_MEMO2];
            $Batch::worker_array[$free_worker][Batch::WORKER_EXTRA3]   = $job[Batch::JOB_MEMO3];

            say("COMMAND ->$command<-") if Auxiliary::script_debug("T5");

            # Add options which need to be RQG runner specific in order to prevent collisions with
            # other active RQG runners started by rqg_batch.pl too.
            my $rqg_workdir = $workdir . "/" . "$free_worker";
            File::Path::rmtree($rqg_workdir);
            make_path($rqg_workdir);
            Auxiliary::make_rqg_infrastructure($rqg_workdir);
            # system("find $rqg_workdir");
            say("DEBUG: [$free_worker] setting RQG workdir to '$rqg_workdir'.")
                if Auxiliary::script_debug("T6");
            $command .= " --workdir=$rqg_workdir";

            my $rqg_vardir = $vardir . "/" . "$free_worker";
            File::Path::rmtree($rqg_vardir);
            make_path($rqg_vardir);
            say("DEBUG: [$free_worker] setting RQG vardir  to '$rqg_vardir'.")
                if Auxiliary::script_debug("T6");
            $command .= " --vardir=$rqg_vardir";
            my $rqg_build_thread = $build_thread + ($free_worker - 1) * 2;
            say("DEBUG: [$free_worker] setting RQG build thread to $rqg_build_thread.")
                if Auxiliary::script_debug("T6");
            $command .= " --mtr-build-thread=$rqg_build_thread";

            my $tm = time();
            $command =~ s/--seed=time/--seed=$tm/g;

            $command .= " " . $cl_end;

            my $rqg_log = $rqg_workdir . "/rqg.log";
            my $rqg_job = $rqg_workdir . "/rqg.job";

            # defined $value ? $value : "NULL";
            my $content =
                "OrderID: "  . $job[Batch::JOB_ORDER_ID] . "\n" .
                "Memo1:   "  . (defined $job[Batch::JOB_MEMO1] ? $job[Batch::JOB_MEMO1] : '<undef>') . "\n" .
                "Memo2:   "  . (defined $job[Batch::JOB_MEMO2] ? $job[Batch::JOB_MEMO2] : '<undef>') . "\n" .
                "Memo3:   "  . (defined $job[Batch::JOB_MEMO3] ? $job[Batch::JOB_MEMO3] : '<undef>') . "\n" .
                "Cl_Snip: "  . $job[Batch::JOB_CL_SNIP]  . "\n" ;
            Batch::append_string_to_file($rqg_job, $content);

            #  if ($logToStd) {
            #     $command .= " 2>&1 | tee " . $rqg_log;
            #  } else {
                  $command .= " >> " . $rqg_log . ' 2>&1' ;
            #  }
            #  ---------------------------------------------
            #  With the code above
            #     backtraces are not detailed.
            #  With
            #     $command .= " --logfile=$rqg_log 2>&1" ;
            #  we get a flood of RQG run messages over the screen.
            #  But backtraces are detailed.

            $command = "perl " . ($Carp::Verbose?"-MCarp=verbose ":"") . " $rqg_home" .
                       "/" . $command;
            unless (osWindows())
            {
                # $command = 'bash -c \'set -o pipefail; ' . $command . '\'';
                $command = 'bash -c "set -o pipefail; ' . $command . '"';
            }
            say("DEBUG: command ==>" . $command . "<==") if Auxiliary::script_debug("T5");

            my $pid = fork();
            if (not defined $pid) {
                Batch::emergency_exit(STATUS_CRITICAL_FAILURE,
                               "ERROR: The fork of the process for a RQG Worker failed.\n"     .
                               "       Assume some serious problem. Perform an EMERGENCY exit" .
                               "(try to stop all child processes).");
            }
            $runs_started++;
            if ($pid == 0) {
                undef @worker_array;
                if      ($Batch::batch_type eq Batch::BATCH_TYPE_COMBINATOR) {
                    undef @Combinator::order_array;
                } elsif ($Batch::batch_type eq Batch::BATCH_TYPE_RQG_SIMPLIFIER) {
                    undef @Simplifier::order_array;
                } else {
                    say("INTERNAL ERROR: The batch type '$Batch::batch_type' is unknown. Abort");
                    safe_exit(4);
                }
                ########## Child ##############################
                $worker_id = $free_worker;
                # make_path($workdir); All already done by the parent
                my $result = 0;
                # If using "system" later maybe set certain memory structures inherited from the
                # parent to undef.
                # Reason:
                # We hopefully reduce the memory foot print a bit.
                # In case I memorize correct than the perl process will not hand back the freed
                # memory to the OS. But it will maybe use the freed memory for
                # - (I am very unsure) stuff called with "system" like rqg.pl
                # - (more sure) anything else
                # The Batch queues: @try_queue, @try_first_queue, @try_later_queue, @try_over_queue
                # The Combinator/simplifier structure: @order_array
                #
                # For experimenting get some delayed death of server.
                # system ("/work_m/RQG_mleich1/killer.sh &");
                setpgrp(0,0);
                # For experimenting : Call some not existing command.
                # $command = "/";

                # For experimenting:
                # In case we exit here than the parent will detect that the RQG worker has not
                # taken over and perform an emergency_exit.
                # safe_exit(0);

                if ($dryrun) {
                    say("LIST: ==>$command<==");
                    # The parent waits for the take over of the RQG worker (rqg.pl) which is visible
                    # per setting the phase to Auxiliary::RQG_PHASE_START.
                    # So we fake that here.
                    Batch::append_string_to_file($rqg_log,
                                                 "LIST: ==>$command<==\n");
                    my $return = Auxiliary::set_rqg_phase($rqg_workdir, Auxiliary::RQG_PHASE_START);
                    if (STATUS_OK != $return){
                        my $status = STATUS_ENVIRONMENT_FAILURE;
                        say("ERROR: RQG worker $worker_id : Setting the phase of the RQG run " .
                            "failed.\n" .
                            "That implies that the infrastructure is somehow wrong.\n" .
                            Auxiliary::exit_status_text($status));
                        safe_exit($status);
                        # We do not need to signal the parent anything because the parent will
                        # detect that the shift to Auxiliary::RQG_PHASE_START did not happened
                        # and perform an emergency_exit.
                    }
                    $return = Verdict::set_final_rqg_verdict ($rqg_workdir, $dryrun);
                    if (STATUS_OK != $return){
                        my $status = STATUS_ENVIRONMENT_FAILURE;
                        say("ERROR: RQG worker $worker_id : Setting the phase of the RQG run " .
                            "failed.\n" .
                            "That implies that the infrastructure is somehow wrong.\n" .
                            Auxiliary::exit_status_text($status));
                        safe_exit($status);
                    }
                    Batch::append_string_to_file($rqg_log,
                                                 "SUMMARY: RQG GenTest runtime in s : 60\n");
                    safe_exit(STATUS_OK);
                } else {
                    # say("DEBUG =>" . $command . "<=");
                    if (not exec($command)) {
                        # We are here though we should not.
                        say("ERROR: exec($command) failed: $!");
                        exit(99);
                    }
                }

            } else {
                ########## Parent ##############################
                my $workerspec = "Worker[$free_worker] with pid $pid for trial $trial_num";
                # FIXME: Set the complete worker_array_entry here
                $Batch::worker_array[$free_worker][Batch::WORKER_PID] = $pid;
                say("DEBUG: $workerspec forked.") if $script_debug;
                # Poll till the RQG Worker has taken over.
                # This has happened when
                # 1. the worker has run setpgrp(0,0) which is not available for WIN.
                # and
                # 2. Set a tiny bit later work phase != init.
                # The first is essential for Unix/Linux in order to make the stop_worker* routines
                # work well. It is currently not known how good these routines work on WIN.
                # Caused by the possible presence of WIN we cannot poll for a change of the
                # processgroup of the RQG worker. We just focus on 2. instead.
                # Observation: 2018-08 10s were not sufficient on some box.
                my $max_waittime  = 20;
                my $waittime_unit = 0.2;
                my $end_waittime  = Time::HiRes::time() + $max_waittime;
                my $phase         = Auxiliary::get_rqg_phase($rqg_workdir);
                my $message       = '';
                if (not defined $phase) {
                    # Most likely: Rotten infrastructure/Internal error
                    $message = "ERROR: Problem to determine the work phase of " .
                               "the just started $workerspec.";
                } else {
                    while(Time::HiRes::time() < $end_waittime and
                          $phase eq Auxiliary::RQG_PHASE_INIT)   {
                        Time::HiRes::sleep($waittime_unit);
                        $phase = Auxiliary::get_rqg_phase($rqg_workdir);
                    }
                    if (Time::HiRes::time() > $end_waittime) {
                        $message = "ERROR: Waitet >= $max_waittime" . "s for the just started " .
                                   "$workerspec to start his work. But no success.";
                    }
                }
                if ('' ne $message) {
                    Batch::emergency_exit(STATUS_CRITICAL_FAILURE,
                        $message . "\n       Assume some serious problem. Perform an EMERGENCY exit" .
                        "(try to stop all child processes) without any cleanup of vardir and workdir.");
                }
                # No fractions of seconds because its not needed and makes prints too long.
                $Batch::worker_array[$free_worker][Batch::WORKER_START] = time();
                say("$workerspec forked and worker has taken over.") if Auxiliary::script_debug("T6");
                $trial_num++;
                $just_forked = 1;
                # $free_worker = -1;
            }


#           if ($just_forked) {
#               # Experimental:
#               # Try to reduce the load peak a bit by a small delay before running the next round
#               # which might end with forking the next RQG runner.
#               # FIXME: Refine
#               my $active_workers = Batch::count_active_workers();
#               if      (($workers / 4) >= $active_workers) {
#                   # Do not wait
#               } elsif (($workers / 2) >= $active_workers) {
#                   sleep 1;
#               } else {
#                   sleep 3;
#               }
#           }

        }
    } else {
        # Either
        # - there was no free RQG worker at all etc.
        # or
        # - the previous loop round harvested a few lines lower give_up == 1 which means
        #   stop the current campaign.
    }

    # Phase or campaign end with stop all workers.
    if (1 == $Batch::give_up) {
        say("DEBUG: give_up is 1 --> loop waiting till all RQG worker have finished.")
            if Auxiliary::script_debug("T5");
        my $poll_time = 0.1;
        while (Batch::reap_workers()) {
            Batch::process_finished_runs();
            last if $Batch::give_up > 1;
            # First handle all cases for giving up.
            # 1. The user created $exit_file for signalling rqg_batch.pl that it should stop.
            # For experimenting:
            # system("touch $exit_file");
            Batch::check_exit_file($exit_file);
            last if $Batch::give_up > 1;
            my $delay_start = Batch::check_resources();
            last if $Batch::give_up > 1;
            Batch::check_runtime_exceeded($batch_end_time);
            last if $Batch::give_up > 1;
            sleep $poll_time;
        }
        # Reaping with final result of having 0 active Workers leads to

        say("DEBUG: After get all worker inactive loop, active workers : ",
            Batch::count_active_workers()) if Auxiliary::script_debug("T6");
        last if $Batch::give_up > 1;
        $Batch::give_up = 0
    }

    # All with $Batch::give_up > 1 have already left our main loop
    say("DEBUG: Waiting for a free RQG worker.") if Auxiliary::script_debug("T6");
    # "Wait" as long as
    #   (the number of active workers == maximum number of workers.)
    # Extend later by or load too high for taking the risk to start another worker
    # or
    #   ((load too high for taking the risk to start another worker) and
    #    ($Batch::give_up == 0))

    my $active_workers = Batch::reap_workers();
    Batch::process_finished_runs();
    last if $Batch::give_up > 1;

    next if defined $dryrun;

    # ResourceControl should take care that reasonable big delays between starts are made.
    # This is completely handled in Batch::check_resources.
    # So the 0.3 here serves only for preventing a too busy rqg_batch.
      sleep 0.3;

} # End of while($Batch::give_up <= 1) loop with search for a free RQG runner and a job + starting it.

say("INFO: Phase of job generation and bring it into execution is over. give_up is $Batch::give_up ");

# We start with a moderate sleep time in seconds because
# - not too much load intended ==> value minimum >= 0.2
# - not too long because checks for bad states (partially not yet implemented) of the testing
#   environment need to happen frequent enough ==> maximum <= 1,0
# As soon as the checks require in sum some significant runtime >= 1s the sleep should be removed.
my $poll_time = 1;
# Poll till none of the RQG workers is active
while (Batch::reap_workers()) {
    Batch::process_finished_runs();
    say("DEBUG: At begin of loop waiting till all RQG worker have finished.")
        if Auxiliary::script_debug("T5");
    # First handle all cases for giving up.
    # 1. The user created $exit_file for signalling rqg_batch.pl that it should stop.
    # For experimenting:
    # system("touch $exit_file");
    Batch::check_exit_file($exit_file);
    # No  last if $Batch::give_up;   because we want the Batch::reap_workers() with the cleanup.
    $poll_time = 0.1 if $Batch::give_up > 1;
    my $delay_start = Batch::check_resources();
    last if $Batch::give_up > 1;
    # 2. The assigned max_runtime is exceeded.
    Batch::check_runtime_exceeded($batch_end_time);
    $poll_time = 0.1 if $Batch::give_up > 1;
    sleep $poll_time;
}
# WARNING:
# The loop begin above will cause all time that Batch::reap_workers gets executed.
# But in case this returns 0 than we will not run the loop body and so Batch::process_finished_runs
# would be not called.  So we must do that here again.
Batch::process_finished_runs();
Batch::dump_queues() if Auxiliary::script_debug("T3");
# dump_orders();

if ($Batch::give_up < 2) {
    my $summary_cmd = "$rqg_home/util/issue_grep.sh $workdir";
    # I do not care if creating or filling the summary files fails because the main
    # - work is already done with success
    # - share of information given from now on does not require a proper working
    #   OS, file system etc.
    system($summary_cmd);
}

my $pl = Verdict::RQG_VERDICT_LENGTH + 2;
say("\n\n"                                                                                         .
"STATISTICS: RQG runs -- Verdict\n"                                                                .
"STATISTICS: " . Auxiliary::lfill($Batch::verdict_replay, 8)    . " -- "                           .
                 Auxiliary::rfill("'" . Verdict::RQG_VERDICT_REPLAY   . "'",$pl)                   .
             " -- Replay of desired effect (Whitelist match, no Blacklist match)\n"                .
"STATISTICS: " . Auxiliary::lfill($Batch::verdict_interest, 8)  . " -- "                           .
                 Auxiliary::rfill("'" . Verdict::RQG_VERDICT_INTEREST . "'",$pl)                   .
             " -- Otherwise interesting effect (no Whitelist match, no Blacklist match)\n"         .
"STATISTICS: " . Auxiliary::lfill($Batch::verdict_ignore, 8)    . " -- "                           .
                 Auxiliary::rfill("'" . Verdict::RQG_VERDICT_IGNORE   . "_*'",$pl)                 .
             " -- Effect is not of interest(Blacklist match or STATUS_OK or stopped)\n"            .
"STATISTICS: " . Auxiliary::lfill($Batch::stopped, 8)   . " -- "                                   .
                 Auxiliary::rfill("'" . Verdict::RQG_VERDICT_IGNORE_STOPPED . "'",$pl)             .
             " -- RQG run stopped by rqg_batch because of whatever reasons\n"                      .
"STATISTICS: " . Auxiliary::lfill($Batch::verdict_init, 8)      . " -- "                           .
                 Auxiliary::rfill("'" . Verdict::RQG_VERDICT_INIT     . "'",$pl)                   .
             " -- RQG run too incomplete (maybe wrong RQG call)\n"                                 .
"STATISTICS: " . Auxiliary::lfill($Batch::verdict_collected, 8) . " -- Some verdict made.\n")      ;
say("STATISTICS: Total runtime in seconds : " . (time() - $batch_start_time))                      ;
say("STATISTICS: RQG runs started         : $runs_started")                                        ;

say("RESULT:     The logs and archives of the RQG runs performed including files with summaries\n" .
    "            are in the workdir of the rqg_batch.pl run\n"                                     .
    "                 $workdir\n")                                                                 ;
say("HINT:       As long as this was the last run of rqg_batch.pl the symlink\n"                   .
    "                 " . BATCH_WORKDIR_SYMLINK . "\n"                                             .
    "            will point to this workdir.\n")                                                   ;
say("RESULT:     The highest (process) exit status of some RQG run was : $total_status")           ;
my $best_verdict;
$best_verdict = Verdict::RQG_VERDICT_INIT;
$best_verdict = Verdict::RQG_VERDICT_IGNORE   if 0 < $Batch::verdict_ignore;
$best_verdict = Verdict::RQG_VERDICT_INTEREST if 0 < $Batch::verdict_interest;
$best_verdict = Verdict::RQG_VERDICT_REPLAY   if 0 < $Batch::verdict_replay;
say("RESULT:     The best verdict reached was : '$best_verdict'");
safe_exit(STATUS_OK);


sub help() {
   print(
   "\nSorry, under construction and partially different or not yet implemented.\n\n"               .
   "Purpose: Perform a batch of RQG runs with massive parallelization according to setup/config\n" .
   "         Be a replacement for\n"                                                               .
   "         combinations.pl, bughunt.pl, runall-trials.pl, simplify-grammar.pl\n"                 .
   "Terms used:\n"                                                                                 .
   "Default\n"                                                                                     .
   "      What you get in case you do not assign some corresponding --<parameter>=<value>.\n"      .
   "RQG Worker\n"                                                                                  .
   "      A child process which\n"                                                                 .
   "      1. Runs an extreme small 'prepare play ground'\n"                                        .
   "      2. Switches via Perl 'exec' to running RQG\n"                                            .
   "Regular finished RQG run\n"                                                                    .
   "      A RQG run which ended regular with success or failure (crash, perl error ...).\n"        .
   "      rqg_batch.pl might stop (KILL) RQG runs because of technical reasons.\n"                 .
   "      Such stopped runs will be restarted with the same setup as soon as possible.\n"          .
   "\n"                                                                                            .
   "--help\n"                                                                                      .
   "      Some general help about rqg_batch.pl and its command line parameters/options which \n"   .
   "      are not handled by the Combinator or the Simplifier.\n"                                  .
   "--help_combinator\n"                                                                           .
   "      Information about the rqg_batch.pl command line parameters/options which are handled "   .
   "by the Combinator.\n"                                                                          .
   "      Purpose: Plain bug hunting.\n"                                                           .
   "--help_simplifier\n"                                                                           .
   "      Information about the rqg_batch.pl command line parameters/options which are handled "   .
   "by the Simplifier.\n"                                                                          .
   "      Purpose: Reduce the complexity (setup+grammar) of a test replaying some problem.\n"      .
   "--help_verdict\n"                                                                              .
   "      Information about how to setup the black and whitelist parameters which are used for\n"  .
   "      defining desired and to be ignored test outcomes.\n"                                     .
   "\n"                                                                                            .
   "--type=<Which type of work ('Combinator' or 'Simplifier') to do?>\n"                           .
   "--config=<config file with path absolute or path relative to top directory of RQG install>\n"  .
   "      Assigning this file is mandatory.\n"                                                     .
   "--max_runtime=<n>\n"                                                                           .
   "      Stop ongoing RQG runs if the total runtime in seconds has exceeded this value, give "    .
   "a summary and exit.\n"                                                                         .
   "--parallel=<n>\n"                                                                              .
   "      Maximum number of parallel RQG Workers performing RQG runs.\n"                           .
   "      (Default) All OS: If supported <return of OS command nproc> otherwise 1.\n\n"            .
   "      WARNING - WARNING - WARNING -  WARNING - WARNING - WARNING - WARNING - WARNING\n"        .
   "         Please be aware that OS/user/hardware resources are limited.\n"                       .
   "         Extreme resource consumption (high value for <n> and/or fat RQG tests) could result\n".
   "         in some very slow reacting testing box up till OS crashes.\n"                         .
   "         Critical candidates: open files, max user processes, free space in tmpfs\n"           .
   "         Future improvement of rqg_batch.pl will reduce these risks drastic.\n\n"              .
   "also not passed through to the RQG runner.\n"                                                  .
   "          If neither --no_mask, --mask or --mask-level is in the combination string than "     .
   "a --mask=.... will be appended to it.\n"                                                       .
   "          Impact of the latter in the RQG runner: mask-level=1 and that --mask=...\n"          .
   "--runner=...\n"                                                                                .
   "      The RQG runner to be used. The value assigned must be without path.\n"                   .
   "      (Default) rqg.pl in RQG_HOME.\n"                                                         .
   "--discard_logs\n"                                                                              .
   "      Remove even the logs of RQG runs with the verdict '" . Verdict::RQG_VERDICT_IGNORE       .
   "'\n"                                                                                           .
   "--stop_on_replay\n"                                                                            .
   "      As soon as the first RQG run achieved the verdict '" . Verdict::RQG_VERDICT_REPLAY       .
   " , stop all active RQG runners, cleanup, give a summary and exit.\n\n"                         .
   "--dryrun=<verdict_value>\n"                                                                    .
   "      Run the complete mechanics except that the RQG worker processes forked\n"                .
   "      - print the RQG call which they would run\n"                                             .
   "      - do not start a RQG run at all but fake a few effects checked by the parent process\n"  .
   "      Debug functionality of other RQG parts like the RQG runner will be not touched!\n"       .
   "      (Default) No additional information.\n"                                                  .
   "--script_debug=...       FIXME: Only rudimentary and different implemented\n"                  .
   "      Print additional detailed information about decisions made by the tool components\n"     .
   "      assigned and observations made during runtime.\n"                                        .
   "      B - Batch.pm and rqg_batch.pl\n"                                                         .
   "      C - Combinator.pm\n"                                                                     .
   "      S - Simplifier.pm\n"                                                                     .
   "      V - Auxiliary.pm\n"                                                                      .
   "      (Default) No additional debug information.\n"                                            .
   "      Hints:\n"                                                                                .
   "          '--script_debug=SB' == Debug Simplifier and Batch ...\n"                             .
   "      The combination\n"                                                                       .
   "                  --dryrun=ignore  --script_debug¸\n"                                          .
   "      is an easy/fast way to check certains aspects of\n"                                      .
   "      - the order and job management in rqg_batch in general\n"                                .
   "      - optimizations (depend on progress) for grammar simplification\n"                       .
   "-------------------------------------------------------------------------------------------\n" .
   "Group of parameters which get either passed through to the Simplifier or appended to the\n"    .
   "final command line of the RQG runner. Both things cause that certain settings within the\n"    .
   "the Combinator or Simplifier config files get overridden or deleted.\n"                        .
   "For their meaning please look into the output of '<runner> --help'.\n"                         .
   "--duration=<n>\n"                                                                              .
   "--gendata=...\n"                                                                               .
   "--grammar=...\n"                                                                               .
   "  Combinator: Override only the grammar maybe assigned in config file.\n"                      .
   "  Simplifier: Ignore any grammar and redefine file maybe assigned in config file.\n"           .
   "--threads=<n>\n"                                                                               .
   "--no_mask      (Assigning --mask or --mask-level on command line is not supported anyway.)\n"  .
   "--testname=...\n"                                                                              .
   "--xml-output=...\n"                                                                            .
   "--report-xml-tt=...\n"                                                                         .
   "--report-xml-tt-type=...\n"                                                                    .
   "--report-xml-tt-dest=...\n"                                                                    .
   "-------------------------------------------------------------------------------------------\n" .
   "rqg_batch will create a symlink '" . BATCH_WORKDIR_SYMLINK . "' pointing to the workdir of "   .
   "his run\n which is <value assigned to workdir>/<runid>.\n"                                     .
   "-------------------------------------------------------------------------------------------\n" .
   "How to cause some rapid stop of the ongoing rqg_batch.pl run without using some dangerous "    .
   "killall SIGKILL <whatever>?\n"                                                                 .
   "    touch " . BATCH_WORKDIR_SYMLINK . "/exit\n"                                                .
   "rqg_batch.pl will stop all active RQG runners, cleanup and give a summary.\n\n"                .
   "What to do on Linux in the rare case (RQG core or runner broken) that this somehow fails?\n"   .
   "    killall -9 perl ; killall -9 mysqld ; rm -rf /dev/shm/vardir/*\n"                          .
   "-------------------------------------------------------------------------------------------\n" .
   "Impact of RQG_HOME if found in environment and the current working directory:\n"               .
   "Around its start rqg_batch.pl searches for RQG components in <CWD>/lib and ENV(\$RQG_HOME)/lib\n" .
   "- rqg_batch.pl computes than a RQG_HOME based on its call and sets than some corresponding "   .
   "  environment variable or aborts.\n"                                                           .
   "  All required RQG components (runner/reporter/validator/...) will be taken from this \n"      .
   "  RQG_HOME 'Universe' in order to ensure consistency between these components.\n"              .
   "- All other ingredients with relationship to some filesystem like\n"                           .
   "     grammars, config files, workdir, vardir, ...\n"                                           .
   "  will be taken according to their setting with absolute path or relative to the current "     .
   "working directory.\n");

# What is set to comment was somewhere in combinations.pl.
# But rqg.pl will handle the number of servers and the required basedirs too and most hopefully
# better.
#  foreach my $s (1..$servers) {
#     $command .= " --basedir" . $s . "=" . $basedirs[$s-1] . " " if $basedirs[$s-1] ne '';
#  }

}

# Routines to be provided by the packages like Combinator.pl
#
# sub init
#
# sub order_is_valid
#     my ($order_id) = @_;
#
# sub print_order
#     my ($order_id) = @_;
#
# sub dump_orders {
#    no parameters
#
# sub get job
#
# sub register_result
#

sub check_and_set_config_file {
    if (not defined $config_file) {
        say("ERROR: The mandatory config file is not defined.");
        help();
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }
    if (not -f $config_file) {
        say("ERROR: The config file '$config_file' does not exits or is not a plain file.");
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }
    $config_file = Cwd::abs_path($config_file);
    my ($throw_away1, $throw_away2, $suffix) = fileparse($config_file, qr/\.[^.]*/);
    say("DEBUG: Config file '$config_file', suffix '$suffix'.");
}

1;
