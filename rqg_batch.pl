#!/usr/bin/perl

# Copyright (c) 2018, MariaDB Corporation Ab.
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
#use List::Util 'shuffle';
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
# use Simplifier;
use GenTest;
use GenTest::Random;
use GenTest::Constants;
use Getopt::Long;
use Data::Dumper;

# use Filesys::Df;  Needed for some free space check but not working for WIN.
#                   And the portable version is at least not in the Ubuntu packages.
#


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
use constant WORKER_EXTRA1    => 3;
use constant WORKER_EXTRA2    => 4;
use constant WORKER_EXTRA3    => 5;
use constant WORKER_END       => 6;
# In case a 'stop_worker' had to be performed than WORKER_END will be set to the current timestamp
# when issuing the SIGKILL that RQG worker processgroup.
# When 'reap_worker' gets active the following should happen
# if defined WORKER_END
#    make a note within the RQG log of the affected worker that he was stopped
#    set verdict to VERDICT_STOPPED etc.
# else
#    set WORKER_END will be set to the current timestamp
#



# Structure for managing orders
# -----------------------------
# FIXME: Explain better
# The parent inits some routine and configures hereby what the goal of the current rqg_batch run is
# - "free" bug hunting by executing a crowd of jobs generated
#   - from combinations config file
#   - via to be implemented variations of parameters like (seed, mask, etc.)
# - fast replay of some well defined bug based on variations of parameters
#   The main difference to the free bughunting above is that the parent stops all other RQG Worker,
#   cleans up and exits as soon as a RQG worker had the verdict "replay".
# - grammar simplification
# There are two main reasons why some order management is required:
# 1. The fastest grammar simplification mechanism
#    - works with chunks of orders
#      rule_a has 4 components --> 4 different orders.
#      And its easier to add the complete chunk on the fly than to handle only one order.
#    - repeats frequent the execution of some order because
#      - the order might have not had success on the previous execution but it looks as if repeating
#        that execution is the most promising we could do
#      - the order had uccess on the previous execution but it was a second "winner", so its
#        simplification could be not applied. But trying again is highly recommended.
#    - tries to get a faster simplification via bookkeeping about efforts invested in orders.
# 2. Independent of the goal of the batch run the parent might be forced to stop some ongoing
#    RQG worker in order to avoid to run into trouble with resources (free space in vardir etc.).
#    In case of
#    - grammar simplification we would have stopped some of the in theory most promising
#      simplification candidates. The most promising regarding speed of progress are started first.
#    - "free" bughunting based on combinations we have now a coverage gap.
#      m - 1 (executed), m (stopped=not covered), m + 1 (executed), ...
#    So its recommended to execute that job again as soon as possible.
#    Note: Some sophisticated resource control is more than just preventing disasters at runtime.
#          It adusts the load dynamic to any hardware and setup of tests met.
#
# my @order_array = ();
# EFFORTS_INVESTED
# Number or sum of runtimes of executions which finished regular
# use constant ORDER_EFFORTS_INVESTED => 0;
# ORDER_EFFORTS_LEFT
# Number or sum of runtimes of possible executions in future which maybe have finished regular.
# Example: rqg_batch will not pick some order with ORDER_EFFORTS_LEFT <= 0 for execution.
# use constant ORDER_EFFORTS_LEFT     => 1;
# ORDER_PROPERTY1
# - (combinations): The snippet of the RQG command line call to be used.
# - (grammar simplifier): The grammar rule to be attacked.
# use constant ORDER_PROPERTY1        => 2;
# ORDER_PROPERTY2
# (grammar simplifier): The simplification like remove "UPDATE ...." which has to be tried.
# use constant ORDER_PROPERTY2        => 3;
# use constant ORDER_PROPERTY3        => 4;


# FIXME: Are these variables used?
my $next_order_id    = 1;
my $last_combination = 0;


my $give_up = 0;
# 0 -- Just go on with work.
# 1 -- Stop all RQG runs, maybe a bit cleanup, give a summary and exit.
# 2 -- Stop all RQG runs, no cleanup, no a summary and exit.
#

# Name of the convenience symlink if symlinking supported by OS
my $symlink = "last_batch_workdir";

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

# FIXME: It does not look like that this ctrl_c stuff has some remarkable impact at all.
$SIG{INT}  = sub { $ctrl_c = 1 };
$SIG{TERM} = sub { emergency_exit("INFO: SIGTERM or SIGINT received. Will stop all RQG worker " .
                                  "and exit without cleanup.", STATUS_OK) };
$SIG{CHLD} = "IGNORE" if osWindows();

my ($config_file, $basedir, $vardir, $trials, $build_thread, $duration, $grammar, $gendata,
    $seed, $testname, $xml_output, $report_xml_tt, $report_xml_tt_type, $max_runtime,
    $report_xml_tt_dest, $force, $no_mask, $exhaustive, $start_combination, $dryrun, $noLog,
    $workers, $servers, $noshuffle, $workdir, $discard_logs, $help, $runner,
    $stop_on_replay, $script_debug, $runid, $threads);

# my @basedirs    = ('', '');
my @basedirs;
my $combinations;
my %results;
my @commands;
my $max_result    = 0;
my $epochcreadir;

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

if (not GetOptions(
#   $opt_result,
           'help'                      => \$help,
           'config=s'                  => \$config_file,
#          'basedir=s'                 => \$basedirs[0],
           'basedir1=s'                => \$basedirs[1],
           'basedir2=s'                => \$basedirs[2],
           'basedir3=s'                => \$basedirs[3],
           'workdir=s'                 => \$workdir,
           'vardir=s'                  => \$vardir,
           'build_thread=i'            => \$build_thread,
           'trials=i'                  => \$trials,
           'duration=i'                => \$duration,
           'seed=s'                    => \$seed,
           'force'                     => \$force,        # Go on even if STATUS_ENVIRONMENT_FAILURE) || ($result == 255  hit
           'no-mask'                   => \$no_mask,
           'grammar=s'                 => \$grammar,
           'gendata=s'                 => \$gendata,
           'testname=s'                => \$testname,
           'xml-output=s'              => \$xml_output,
           'report-xml-tt'             => \$report_xml_tt,
           'report-xml-tt-type=s'      => \$report_xml_tt_type,
           'report-xml-tt-dest=s'      => \$report_xml_tt_dest,
           'run-all-combinations-once' => \$exhaustive,
           'start-combination=i'       => \$start_combination,
           'max_runtime=i'             => \$max_runtime,
           'dryrun'                    => \$dryrun,             # Dry run
           'no-log'                    => \$noLog,             # Print all to command window
           'parallel=i'                => \$workers,
           'runner=s'                  => \$runner,
           'stop_on_replay'            => \$stop_on_replay,
           'servers=i'                 => \$servers,
           'threads=i'                 => \$threads,
           'no-shuffle'                => \$noshuffle,
           'discard_logs'              => \$discard_logs, # In case if ($result > 0 and not $discard_logs) than archiving
           'discard-logs'              => \$discard_logs,
           'script_debug=s'            => \$script_debug,
           'runid:i'                   => \$runid,
                                                   )) {
    # Somehow wrong option.
    help();
    safe_exit(STATUS_ENVIRONMENT_FAILURE);
};

say("INFO: Command line: " . $command_line);

# Counter for statistics
# ----------------------
my $runs_started          = 0;
my $runs_stopped          = 0;
my $verdict_init          = 0;
my $verdict_replay        = 0;
my $verdict_interest      = 0;
my $verdict_ignore        = 0;
my $verdict_stopped       = 0;
my $verdict_collected     = 0;
my $runs_finished_regular = 0;

if (defined $help) {
   help();
   safe_exit(0);
}

if (not defined $dryrun) {
    $dryrun = 0;
} else {
    $dryrun = 1;
}
if (not defined $script_debug) {
    $script_debug = 0;
} else {
    $script_debug = 1;
    say("DEBUG: script_debug '$script_debug' is enabled.");
}
if (not defined $stop_on_replay) {
    $stop_on_replay = 0;
} else {
    $stop_on_replay = 1
}

# Handle workdir
($workdir, $vardir) = Batch::make_multi_runner_infrastructure ($workdir, $vardir, $runid,
                                                               $symlink);
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

Combinator::init($config_file, $workdir, $seed, $exhaustive, $noshuffle,
                 $start_combination, $trials, $stop_on_replay);

if (not defined $runner) {
    $runner = "rqg.pl";
    say("INFO: The RQG runner was not assigned. Will use the default '$runner'.");
}
if (File::Basename::basename($runner) ne $runner) {
    say("Error: The value for the RQG runner '$runner' needs to be without any path.");
    safe_exit(4);
}
# For experimenting
# $runner = 'mimi';
$runner = $rqg_home . "/" . $runner;
if (defined $runner) {
    if (not -e $runner) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: The RQG runner '$runner' does not exist. " .
            Auxiliary::exit_status_text($status));
        safe_exit($status);
    }
}

$build_thread = Auxiliary::check_and_set_build_thread($build_thread);
if (not defined $build_thread) {
    my $status = STATUS_ENVIRONMENT_FAILURE;
    say("ERROR: The RQG runner '$runner' does not exist. " .
        Auxiliary::exit_status_text($status));
    safe_exit($status);
}

####
my $command_append = cl_adjustment ();
say("DEBUG: Command line options to be appended to the call of the RQG runner: ->" .
    $command_append . "<-") if $script_debug;

# if (not defined $start_combination) {
#    say("DEBUG: start-combination was not assigned. Setting it to the default 1.") if $script_debug;
#    $start_combination = 1;
# }

# my $comb_count = $#$combinations + 1;
# my $total      = 1;
# foreach my $comb_id (0..($comb_count - 1)) {
#     $total *= $#{$combinations->[$comb_id]} + 1;
# }
# say("INFO: Number of sections to pick an entry from and combine : $comb_count");
# say("INFO: Number of possible combinations                      : $total");

# This handling of seed affects mainly the generation of random combinations.
# if (not defined $seed) {
#     $seed = 1;
#     say("INFO: seed (used for generation of combinations only) is not defined. " .
#         "Setting it to the default 1.");
# }
# if ($seed eq 'time') {
#     $seed = time();
# }
# my $prng = GenTest::Random->new(seed => $seed);

my $trial_counter = 0;
# my $next_comb_id  = 0;

if (not defined $max_runtime) {
    $max_runtime = 432000;
    my $max_days = $max_runtime / 24 / 3600;
    say("INFO: Setting the maximum runtime to the default of $max_runtime" . "s ($max_days days).");
}
if (not defined $trials) {
    $trials = 9999;
    say("INFO: Setting the maximum number of trials to the default of $trials trials.");
}
my $batch_end_time = $batch_start_time + $max_runtime;

########## File::Copy::copy($config_file, $workdir . "/combinations.cc");

# system("find $workdir $vardir");

my $logToStd = !osWindows() && !$noLog;

say("DEBUG: logToStd is ->$logToStd<-") if $script_debug;

if (not defined $workers) {
    if (osWindows()) {
       $workers = 1;
    } else {
       my $result = `nproc`;
       if (not defined $result) {
          say("DEBUG: nproc gave undef as result") if $script_debug;
          $workers = 1;
       } else {
          chomp $result; # Remove the '\n'
          $workers = $result;
       }
    }
    say("INFO: The maximum number of parallel RQG runs was not defined. Setting it to ->$workers<-.");
};


my $worker_id;
# Avoid starting superfluous workers because they only cause noise.
if ($trials < $workers) {
    say("DEBUG: Decrease the maximum number of parallel RQG runs($workers) to the number of " .
        "trials($trials).") if $script_debug;
    $workers = $trials;
}

for my $worker_num (1..$workers) {
    worker_reset($worker_num);
}

my $exit_file    = $workdir . "/exit";
my $result_file  = $workdir . "/result.txt";

my $total_status = STATUS_OK;

my $trial_num = 1; # This is the number of the next trial if started at all.
                   # That also implies that incrementing must be after getting a valid command.
while(not $give_up) {
    say("DEBUG: Begin of while(1) loop. Next trial_num is $trial_num.") if $script_debug;
    # First handle all cases for giving up.
    # 1. The user created $exit_file for signalling rqg_batch.pl that it should stop.
    # For experimenting:
    # system("touch $exit_file");
    exit_file_check($exit_file);
    last if $give_up;
    # 2. The assigned max_runtime is exceeded.
    runtime_exceeded($batch_end_time);
    last if $give_up;
    # 3. Number of trials reached.
    if ($trial_num > $trials) {
        say("DEBUG: Number of trials already reached. Leaving while loop") if $script_debug;
        last;
    }
    # If
    # - no trouble on OS is direct ahead
    # - some additional RQG run
    #   - does not lead to estimating trouble on OS soon
    #   - might increase throughput
    #   - would not lead to having more active RQG runners than assigned workers
    # than
    # - pick a job from the queue
    #   If the queue is empty generate one or more new jobs and append them to the queue
    #   and try to pick again. In case there is no open job than just wait for the end
    #   of the ongoing RQG runs, analyze and exit
    # - fork a child process doing the job picked
    my $just_forked = 0;
    my $free_worker = -1;

    # FIXME:
    # Implement some load control mechanism.
    # Basically:
    # Have some value describing a mixup of current state and forecast.
    # In case that value is
    # - below 1 than search for a free RQG Worker + a job + fork.
    # - determine a value describing the current state, add that
    for my $worker_num (1..$workers) {
        if (-1 == $worker_array[$worker_num][WORKER_PID]) {
            $free_worker = $worker_num;
            say("DEBUG: RQG worker [$free_worker] is free. Leaving search loop " .
                "for non busy workers.") if $script_debug;
            last;
        }
    }
    if ($free_worker != -1) {
        # We have a free thread.
        my $out_of_ideas = 0;
        my @job = Combinator::get_job;
        my $order_id = $job[0];
        my $cl_snip  = $job[1];
        if (not defined $order_id) {
            # @try_first_queue empty , @try_queue empty too and extending impossible.
            # == All possible orders were generated.
            #    Some might be in execution and all other must be in @try_over_queue.
            say("DEBUG: No order got") if $script_debug;
            last;
        } else {
            say("Job generated : $order_id § $cl_snip");
            # We have now a free/non busy RQG runner and a job
            say("DEBUG: Valid order $order_id got") if $script_debug;

            my $command = $cl_snip ;

            say("DEBUG: RQG worker [$free_worker] should run order $order_id ->$command<-") if $script_debug;
            $worker_array[$free_worker][WORKER_ORDER_ID] = $order_id;

            # FIXME:
            # There needs to be a routine 'translate_order' which generates some
            # snip for the command line call.

            # Add options which need to be RQG runner specific in order to prevent collisions with
            # other active RQG runners started by rqg_batch.pl too.
            my $rqg_workdir = $workdir . "/" . "$free_worker";
            File::Path::rmtree($rqg_workdir);
            make_path($rqg_workdir);
            Auxiliary::make_rqg_infrastructure($rqg_workdir);
            # system("find $rqg_workdir");
            say("DEBUG: [$free_worker] setting RQG workdir to '$rqg_workdir'.") if $script_debug;
            $command .= " --workdir=$rqg_workdir";

            my $rqg_vardir = $vardir . "/" . "$free_worker";
            File::Path::rmtree($rqg_vardir);
            make_path($rqg_vardir);
            say("DEBUG: [$free_worker] setting RQG vardir  to '$rqg_vardir'.") if $script_debug;
            $command .= " --vardir=$rqg_vardir";
            my $rqg_build_thread = $build_thread + ($free_worker - 1) * 2;
            say("DEBUG: [$free_worker] setting RQG build thread to $rqg_build_thread.") if $script_debug;
            $command .= " --mtr-build-thread=$rqg_build_thread";

            my $tm = time();
            $command =~ s/--seed=time/--seed=$tm/g;

            $command .= $command_append;

            my $rqg_log = $rqg_workdir . "/rqg.log";
            my $rqg_job = $rqg_workdir . "/rqg.job";

            $job[0] = "OrderID: "  . $job[0];
            $job[1] = "ClSnip: "   . $job[1] ;
            my $content = join("\n", @job);
            say("DEBUG: $content") if $script_debug;
            if (not STATUS_OK == Auxiliary::append_string_to_file($rqg_job, $content)) {
                emergency_exit(STATUS_ENVIRONMENT_FAILURE,
                               "Writing to the file '$rqg_job' failed.");
            }

            #  if ($logToStd) {
            #     $command .= " 2>&1 | tee " . $rqg_log;
            #  } else {
                  $command .= " > " . $rqg_log . ' 2>&1' ;
            #  }

            #  With the code above
            #     backtraces are not detailed.
            #
            #  With
            #     $command .= " --logfile=$rqg_log 2>&1" ;
            #  we get a flood of RQG run messages over the screen.
            #  But backtraces are detailed.

            $command = "perl " . ($Carp::Verbose?"-MCarp=verbose ":"") . " $runner $command";
            unless (osWindows())
            {
                $command = 'bash -c "set -o pipefail; ' . $command . '"';
            }

            my $pid = fork();
            if (not defined $pid) {
                emergency_exit(STATUS_CRITICAL_FAILURE,
                               "ERROR: The fork of the process for a RQG Worker failed.\n"     .
                               "       Assume some serious problem. Perform an EMERGENCY exit" .
                               "(try to stop all child processes).");
            }
            $runs_started++;
            if ($pid == 0) {
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
                    $return = Verdict::set_final_rqg_verdict ($rqg_workdir,
                                                                 Verdict::RQG_VERDICT_IGNORE);
                    if (STATUS_OK != $return){
                        my $status = STATUS_ENVIRONMENT_FAILURE;
                        say("ERROR: RQG worker $worker_id : Setting the phase of the RQG run " .
                            "failed.\n" .
                            "That implies that the infrastructure is somehow wrong.\n" .
                            Auxiliary::exit_status_text($status));
                        safe_exit($status);
                    } else {
                        safe_exit(STATUS_OK);
                    }
                } else {
                    if (not exec($command)) {
                        # We are here though we should not.
                        say("ERROR: exec($command) failed: $!");
                        exit(99);
                    }
                }

                # Small quarry with code if switching to "system" instead of "exec".
                # $result = system($command) if not $debug;
                # $result = $result >> 8;
                # my $verdict = Auxiliary::get_rqg_verdict($rqg_workdir);
                # say("DEBUG: RQG Worker [$worker_id] will exit now with status $result")
                #     if $script_debug;
                # safe_exit($result);
                #
                # FIXME(Experiment out and decide)
                # --------------------------------
                # If using "system" instead of "exec" the RQG worker could perform certain
                # operations after the RQG run.
                # Examples:
                # 1. Move the to be saved logs and archives to their final destination.
                #    But this would require that the final name would be known in advance.
                #    Example: <batch_run workdir>/<$worker_id>/rqg.log
                #             --> <batch_run workdir>/<here is the name>.log
                # Advantage:
                # - The parent process does not need to waste time on these operations.
                #   So he can react faster on desired or alarming events.
                # - These operations should not be that dangerous. But if something horrible happens
                #   and the parent process hangs or dies than the testing box or OS might come into
                #   or stay in some bad state. So let the worker do that makes the life of the
                #   parent more safe.
                # Disadvantages:
                # - RQG worker stopped by the parent are "dead" and cannot do these operations.
                #   So at least now the parent needs to do that.
                #   --> We mabe need some code twice.
                # - I guess that the memory foot print will be maybe serious bigger if using
                #   "system".
                #   fork by parent -> child which is a clone of the parent at time of forking.
                #   The parent has maybe (assume we run simplification) a lot memory stuff as
                #   heritage. Non changed memory stuff is maybe shared. But will more or less
                #   heavy change as soon as the parent makes changes in that stuff.
                #   And the sharing between the children is maybe also not that great because they
                #   were all forked at different points of time/simplification progress.
                #   And in case that child starts now the RQG run with "system" than we get a lot
                #   stuff in addition. In case of "exec" we get hopefully only what rqg.pl needs.
                #

            } else {
                ########## Parent ##############################
                my $workerspec = "Worker[$free_worker] with pid $pid for trial $trial_num";
                $worker_array[$free_worker][WORKER_PID] = $pid;
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
                    while(Time::HiRes::time() < $end_waittime and $phase eq Auxiliary::RQG_PHASE_INIT) {
                        Time::HiRes::sleep($waittime_unit);
                        $phase = Auxiliary::get_rqg_phase($rqg_workdir);
                    }
                    if (Time::HiRes::time() > $end_waittime) {
                        $message = "ERROR: Waitet >= $max_waittime" . "s for the just started " .
                                   "$workerspec to start his work. But no success.";
                    }
                }
                if ('' ne $message) {
                    emergency_exit(STATUS_CRITICAL_FAILURE,
                        $message . "\n       Assume some serious problem. Perform an EMERGENCY exit" .
                        "(try to stop all child processes) without any cleanup of vardir and workdir.");
                }
                # No fractions of seconds because its not needed and makes prints too long.
                $worker_array[$free_worker][WORKER_START] = time();
                say("$workerspec forked and worker has taken over.") if $script_debug;
                $trial_num++;
                $just_forked = 1;
                # $free_worker = -1;
                # worker_array_dump() if $script_debug;
                say("DEBUG: After start of RQG worker.") if $script_debug;
            }

#           if ($just_forked) {
#               # Experimental:
#               # Try to reduce the load peak a bit by a small delay before running the next round
#               # which might end with forking the next RQG runner.
#               # FIXME: Refine
#               my $active_workers = active_workers();
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
        say("DEBUG: No free RQG runner found.") if $script_debug;
    }

    # "Wait" as long as
    #   (the number of active workers == maximum number of workers.)
    # Extend later by or load too high for taking the risk to start another worker
    # or
    #   ((load too high for taking the risk to start another worker) and
    #    ($give_up == 0))
    say("DEBUG: Before entering 'wait for free RQG worker'.") if $script_debug;
    while (1) {
        my $active_workers = reap_workers();
        # 1. The user created $exit_file for signalling rqg_batch.pl that it should stop.
        exit_file_check($exit_file);
        last if $give_up;
        # 2. The assigned max_runtime is exceeded.
        runtime_exceeded($batch_end_time);
        last if $give_up;
        # FIXME: Modify later to   last if ($active_workers < $workers and "load not too high")
        last if ($active_workers < $workers);
        sleep 1;
    }
    say("DEBUG: After leaving 'wait for free RQG worker'.") if $script_debug;

    # FIXME: Refine
    sleep 0.3;

} # End of while(1) loop with search for a free RQG runner and a job + starting it.


say("INFO: Phase of search for combination and bring it into execution is over.");
# We start with a moderate sleep time in seconds because
# - not too much load intended ==> value minimum >= 0.2
# - not too long because checks for bad states (partially not yet implemented) of the testing
#   environment need to happen frequent enough ==> maximum <= 1,0
# As soon as the checks require in sum some significant runtime >= 1s the sleep should be removed.
my $poll_time = 1;
# Poll till all tests are gone
while (reap_workers()) {
    say("DEBUG: At begin of loop waiting till all RQG worker have finished.") if $script_debug;
    # First handle all cases for giving up.
    # 1. The user created $exit_file for signalling rqg_batch.pl that it should stop.
    # For experimenting:
    # system("touch $exit_file");
    exit_file_check($exit_file);
    # No  last if $give_up;   because we want the reap_workers() with the cleanup.
    $poll_time = 0.1 if $give_up;
#  free_space_check($vardir);
#  $poll_time = 0.1 if $give_up;
    # 2. The assigned max_runtime is exceeded.
    runtime_exceeded($batch_end_time);
    $poll_time = 0.1 if $give_up;
    sleep $poll_time;
}
Batch::dump_queues();
# dump_orders();

my $summary_cmd = "$rqg_home/util/issue_grep.sh $workdir";
# I do not care if creating or filling the summary files fails because the main
# - work is already done with success
# - share of information given from now on does not require a proper working
#   OS, file system etc.
system($summary_cmd);

say("\n\n"                                                                                         .
    "STATISTICS: Number of RQG runs -- Verdict\n"                                                  .
    "STATISTICS: $verdict_replay -- '" . Verdict::RQG_VERDICT_REPLAY . "'-- "                      .
                 "Replay of desired effect (Whitelist match, no Blacklist match)\n"                .
    "STATISTICS: $verdict_interest -- '" . Verdict::RQG_VERDICT_INTEREST . "'-- "                  .
                 "Otherwise interesting effect (no Whitelist match, no Blacklist match)\n"         .
    "STATISTICS: $verdict_ignore -- '" . Verdict::RQG_VERDICT_IGNORE . "'-- "                      .
                 "Effect is not of interest(Blacklist match or STATUS_OK)\n"                       .
    "STATISTICS: $verdict_stopped -- '" . Verdict::RQG_VERDICT_STOPPED . "'-- "                    .
                 "RQG run stopped by rqg_batch because of whatever reasons\n"                      .
    "STATISTICS: $verdict_init -- '" . Verdict::RQG_VERDICT_INIT . "'-- "                          .
                 "RQG run too incomplete (maybe wrong RQG call)\n"                                 .
    "STATISTICS: $verdict_collected -- Some verdict made.\n")                                      ;
say("STATISTICS: Total runtime in seconds : " . (time() - $batch_start_time))                      ;
say("STATISTICS: RQG runs started         : $runs_started")                                        ;

say("RESULT:     The logs and archives of the RQG runs performed including files with summaries\n" .
    "            are in the workdir of the rqg_batch.pl run\n"                                     .
    "                 $workdir\n")                                                                 ;
say("HINT:       As long as this was the last run of rqg_batch.pl the symlink\n"                   .
    "                 $symlink\n"                                                                  .
    "            will point to this workdir.\n")                                                   ;
say("RESULT:     The highest (process) exit status of some RQG run was : $total_status")           ;
my $best_verdict;
$best_verdict = Verdict::RQG_VERDICT_INIT;
$best_verdict = Verdict::RQG_VERDICT_IGNORE   if 0 < $verdict_ignore;
$best_verdict = Verdict::RQG_VERDICT_INTEREST if 0 < $verdict_interest;
$best_verdict = Verdict::RQG_VERDICT_REPLAY   if 0 < $verdict_replay;
say("RESULT:     The best verdict reached was : '$best_verdict'");
safe_exit(STATUS_OK);


# FIXME:
# - The parent gives around end of the rqg_batch run
#   - some statistics about all statuses got by the childs
#   - some aggregation about interesting bad effects met
# - The parent or some auxiliary child process observes the state of the testing box permanent.
#   The parent decides if to start or even to kill a child(RQG run) depending on the current
#   state of the testing box and the forecast.

# if ($worker_id > 0) {
#  ## Child
#  ##say("[$worker_id] Summary of various interesting strings from the logs:");
#  say("[$worker_id] ". Dumper \%results);
#  #foreach my $string ('text=', 'bugcheck', 'Error: assertion', 'mysqld got signal', 'Received signal', 'exception') {
#  #    system("grep -i '$string' $workdir/trial*log");
#  #}


sub reap_workers {

# 1. Reap finished workers so that processes in zombie state disappear.
# 2. Decide depending on the verdict and certain options what to do with maybe existing remainings
#    of the finished test.
# 3. Clean the workdir and vardir of the RQG run
# 4. Return the number of active workers (process is busy/not reaped).

    # https://perldoc.perl.org/perlipc.html#Deferred-Signals-(Safe-Signals)

    my $active_workers = 0;
    # TEMPORARY
    if ($script_debug) {
        say("worker_array_dump at entering reap_workers");
        worker_array_dump();
    }
    for my $worker_num (1..$workers) {
        next if -1 == $worker_array[$worker_num][WORKER_PID];
        my $worker_process_group = getpgrp($worker_array[$worker_num][WORKER_PID]);
        my $kid = waitpid($worker_array[$worker_num][WORKER_PID], WNOHANG);
        my $exit_status = $? > 0 ? ($? >> 8) : 0;
        if (not defined $kid) {
            say("ALARM: Got not defined waitpid return for RQG worker $worker_num with pid " .
                $worker_array[$worker_num][WORKER_PID]);
        } else {
            say("DEBUG: Got waitpid return $kid for RQG worker $worker_num with pid " .
                $worker_array[$worker_num][WORKER_PID]) if $script_debug;
            my $order_id = $worker_array[$worker_num][WORKER_ORDER_ID];
            if ($kid == $worker_array[$worker_num][WORKER_PID]) {

                # The usual behaviour of batch tools is to
                # - conclude that certain resources like ports are free based on the fact that
                #   some RQG worker process had finished
                # - initiate some next RQG run causing that some database servers get started.
                # Some painful and too frequent made experience is that these servers meet
                # other servers having these resources already in use and that even though the
                # calculation of the ports is correct.
                # The reasons for such problems are that servers of such previous RQG runs were
                # not stopped because of
                # - (too frequent) bad habit of the RQG core to exit with croak instead of
                #   taking care of the child processes first
                # - (rather rare) temporary mistakes which could happen during RQG core and tool
                #   code development leading to Perl gives up because of fatal errors at runtime.
                # - (unknown) trouble with user limits, OS resources etc.
                # Summary:
                # We should rather assume the worst case, child processes are not already dead,
                # and make some radical cleanup.
                kill 'KILL', $worker_process_group;

                my $rqg_appendix  = "/" . $worker_num;
                my $rqg_vardir    = "$vardir"  . $rqg_appendix;
                my $rqg_workdir   = "$workdir" . $rqg_appendix;

                my $verdict       = Verdict::get_rqg_verdict($rqg_workdir);
                $verdict_collected++;
                say("DEBUG: Worker [$worker_num] with (process) exit status " .
                    "'$exit_status' and verdict '$verdict' reaped.") if $script_debug;

                my $rqg_log       = "$rqg_workdir" . "/rqg.log";
                my $rqg_arc       = "$rqg_workdir" . "/archive.tgz";

                my $target_prefix_rel = $verdict_collected;
                my $target_prefix     = $workdir . "/" . $target_prefix_rel;
                my $saved_log_rel     = $target_prefix_rel . ".log";
                my $saved_log         = $target_prefix     . ".log";
                my $saved_arc         = $target_prefix     . ".tgz";

                my $iso_ts = isoTimestamp();

                # Note:
                # The next two routines get used because the standard failure handling is to make
                # an emergency_exit and not just some simple exit.
                sub save_file {
                    # Note: Auxiliary::rename_file runs checks if files exist or not etc.
                    my ($source_file, $target_file) = @_;
                    if (STATUS_OK != Auxiliary::rename_file($source_file, $target_file)) {
                        emergency_exit(STATUS_ENVIRONMENT_FAILURE,
                            "ERROR: This must not happen.");
                    }
                }
                sub drop_directory {
                    my ($directory) = @_;
                    if (-d $directory) {
                        if(not File::Path::rmtree($directory)) {
                            say("ERROR: Removal of the directory '$directory' failed. : $!.");
                            emergency_exit(STATUS_ENVIRONMENT_FAILURE,
                                "ERROR: This must not happen.");
                        }
                    }
                }

                if (-1 != $worker_array[$worker_num][WORKER_END]) {
                    # The RQG worker was 'victim' of a stop with SIGKILL.
                    # So write various information into the RQG run log which the RQG worker was
                    # no more able to do.
                    # Its no problem that this appended stuff will be not in the archive because
                    # there is
                    # - most likely no archive at all
                    # - sometimes an archive harmed by the SIGKILL
                    # - extreme unlikely a complete archive
                    # ==> It get thrown away in general.
                    $verdict = Verdict::RQG_VERDICT_STOPPED;
                    Auxiliary::append_string_to_file($rqg_log, "# $iso_ts BATCH: Stop the run.\n" .
                                                               "# $iso_ts Verdict: $verdict\n");
                } else {
                    $worker_array[$worker_num][WORKER_END] = time();
                }

                if ($verdict eq Verdict::RQG_VERDICT_IGNORE or
                    $verdict eq Verdict::RQG_VERDICT_STOPPED) {
                    if (not $discard_logs) {
                        save_file($rqg_log, $saved_log);
                    } else {
                        $saved_log_rel = "<deleted>";
                    }
                    if ($verdict eq Verdict::RQG_VERDICT_STOPPED) {
                        $verdict_stopped++;
                        # Do nothing with $order_array[$order_id][ORDER_EFFORTS*]
                    } else {
                        $verdict_ignore++;
                        # $order_array[$order_id][ORDER_EFFORTS_INVESTED]++;
                        # $order_array[$order_id][ORDER_EFFORTS_LEFT]--;
                    }
                } elsif ($verdict eq Verdict::RQG_VERDICT_INTEREST or
                         $verdict eq Verdict::RQG_VERDICT_REPLAY) {
                    save_file($rqg_log, $saved_log);
                    save_file($rqg_arc, $saved_arc);
                    if ($verdict eq Verdict::RQG_VERDICT_INTEREST) {
                        $verdict_interest++;
                    } else {
                        $verdict_replay++;
                    }
                    # $order_array[$order_id][ORDER_EFFORTS_INVESTED]++;
                    # $order_array[$order_id][ORDER_EFFORTS_LEFT]--;
                } elsif ($verdict eq Verdict::RQG_VERDICT_INIT) {
                    # The RQG worker was definitely not the 'victim' of a stop_worker because
                    # that gets marked as RQG_VERDICT_STOPPED.
                    # The RQG runner
                    # - took over (->RQG_PHASE_START)
                    # - did something
                    # - disappeared before having reached a verdict
                    # Most likely
                    #   "ill" command line snip (generated by Simplifier/Combinator/...)
                    #   which was not "accepted" by RQG runner (unknown or missing parameter).
                    # Less likely
                    #   Failure in environment (Example: Missing file) wrong (Example: croak)
                    #   handled by RQG core.
                    #   Perl aborts because of heavy failure in RQG core.
                    # We might have a RQG log which maybe explains why the run failed so early.
                    # We do not have an archive of remaining data and its also quite unlikely
                    # that any remaining data would be valuable.
                    # Letting the rqg_batch process generate an archive is a too big danger
                    # (death during archiving or too long busy with just that) for control.
                    save_file($rqg_log, $saved_log);
                    $verdict_init++;
                    say("WARN: Final Verdict Verdict::RQG_VERDICT_INIT in '$saved_log'.");
                    # Maybe touch ORDER_EFFORTS_INVESTED or ORDER_EFFORTS_LEFT
                } else {
                    emergency_exit(STATUS_CRITICAL_FAILURE,
                        "INTERNAL ERROR: Final Verdict '$verdict' is not treated/unknown. " .
                        "This should not happen.");
                }
                drop_directory($rqg_vardir);
                drop_directory($rqg_workdir);
                my $total_runtime =   $worker_array[$worker_num][WORKER_END]
                                    - $worker_array[$worker_num][WORKER_START];
                my ($status,$action) = Combinator::register_result($order_id, $verdict, $saved_log_rel,
                                                                   $total_runtime);
                # Note:
                # Combinator/Simplifier/...
                # - extract whatever they see as useful and
                # - add a line to $workdir/results.txt.
                # - maybe add the $order_id vi Batch.pm in some queue etc.
                say("DEBUG: register_result returned status '$status' and action '$action'.")
                    if $script_debug;
                if ($status != STATUS_OK) {
                    emergency_exit($status,
                                   "ERROR: register_result met a failure and asked to abort. " .
                                   Auxiliary::exit_status_text($status));
                } else {
                    # Combinator and Simplifier could tell what to do next.
                    if      ($action eq Batch::REGISTER_GO_ON)    {
                        # All is ok. Just go on is required.
                    } elsif ($action eq Batch::REGISTER_STOP_ALL) {
                        stop_workers();
                    } elsif ($action eq Batch::REGISTER_END)      {
                        stop_workers();
                        $give_up = 1;
                    } else {
                        $status = STATUS_INTERNAL_ERROR;
                        emergency_exit($status,
                                       "INTERNAL ERROR: register_result returned the unknown " .
                                       "action '$action'." . Auxiliary::exit_status_text($status));
                    }
                }

                worker_reset($worker_num);
                $total_status = $exit_status if $exit_status > $total_status;

            } elsif (-1 == $kid) {
                say("ALARM: RQG worker $worker_num was already reaped.");
                worker_reset($worker_num);
            } else {
                say("DEBUG: RQG worker $worker_num with pid " .
                    $worker_array[$worker_num][WORKER_PID] . " is running") if $script_debug;
                $active_workers++;
            }
        }
    } # Now all RQG worker are checked.

    if ($script_debug) {
        say("worker_array_dump before leaving reap_workers");
        worker_array_dump();
    }
    say("DEBUG: Leave reap_workers and return (active workers found) : " .
        "$active_workers") if $script_debug;
    return $active_workers;
} # End sub reap_workers

sub worker_array_dump {
    my $message = "worker_array_dump begin --------\n" .
                  "worker_num -- pid -- job_start -- job_end -- order_id -- " .
                  "extra1 -- extra2 -- extra3\n";
    for my $worker_num (1..$workers) {
        $message = $message . $worker_num .
                   " -- " . $worker_array[$worker_num][WORKER_PID]      .
                   " -- " . $worker_array[$worker_num][WORKER_START]    .
                   " -- " . $worker_array[$worker_num][WORKER_END]      .
                   " -- " . $worker_array[$worker_num][WORKER_ORDER_ID] ;
        foreach my $index (WORKER_EXTRA1, WORKER_EXTRA2, WORKER_EXTRA3) {
            my $val = $worker_array[$worker_num][$index];
            if (not defined $val) {
                $val = "<undef>";
            }
            $message = $message . " -- " . $val;
        }
        $message = $message . "\n";
        #   if (not defin
        #          " -- " . $worker_array[$worker_num][WORKER_EXTRA1]   .
        #          " -- " . $worker_array[$worker_num][WORKER_EXTRA2]   .
        #          " -- " . $worker_array[$worker_num][WORKER_EXTRA3]   .  "\n";
    }
    say ($message . "worker_array_dump end   --------") if $script_debug;
}

sub worker_reset {
    my ($worker_num) = @_;

    $worker_array[$worker_num][WORKER_PID]      = -1;
    $worker_array[$worker_num][WORKER_START]    = -1;
    $worker_array[$worker_num][WORKER_END]      = -1;
    $worker_array[$worker_num][WORKER_ORDER_ID] = -1;
    $worker_array[$worker_num][WORKER_EXTRA1]   = undef;
    $worker_array[$worker_num][WORKER_EXTRA2]   = undef;
    $worker_array[$worker_num][WORKER_EXTRA3]   = undef;
}

sub stop_worker {
    my ($worker_num) = @_;
    my $pid = $worker_array[$worker_num][WORKER_PID];
    if (-1 != $pid) {
        # Per last update of bookkeeping the RQG Woorker was alive.
        # We ask to kill the processgroup of the RQG Worker.
        kill '-KILL', $pid;
        $worker_array[$worker_num][WORKER_END]  = time();
    }
}

sub stop_workers () {
    for my $worker_num (1..$workers) {
        stop_worker($worker_num);
    }
}

sub exit_file_check {
    my ($exit_file) = @_;
    if (-e $exit_file) {
        $give_up = 1;
        say("INFO: Exit file detected. Stopping all RQG Worker.");
        stop_workers();
    }
}

sub runtime_exceeded {
    my ($batch_end_time) = @_;
    if ($batch_end_time  < Time::HiRes::time()) {
        $give_up = 1;
        say("INFO: The maximum total runtime for rqg_batch.pl is exceeded. " .
            "Stopping all RQG Worker.");
        stop_workers();
    }
}

# sub free_space_check {
#    # This works unfortunately not on WIN.
#
#     my ($workdir) = @_;
#
#    my $ref = df("$workdir");  # Default output is 1K blocks
#
#     if(defined($ref)) {
#         print "Total 1k blocks: $ref->{blocks}\n";
#         print "MLMLML: Total 1k blocks avail to me: $ref->{bavail}\n";
#
#     }
#
# }

sub help() {
   print(
   "\nSorry, under construction and partially different or not yet implemented.\n\n"               .
   "Purpose: Perform a batch of RQG runs with massive parallelization according to setup/config\n" .
   "         Be a replacement for\n"                                                               .
   "         (immediate) combinations.pl, bughunt.pl, runall-trials.pl\n"                          .
   "         (soon)      simplify-grammar.pl\n"                                                    .
   "Terms used:\n"                                                                                 .
   "combination string\n"                                                                          .
   "      A fragment of a RQG call generated by rqg_batch.pl based on config file content.\n"      .
   "      rqg_batch.pl might transform and especially append more settings depending on\n"         .
   "      content in command line and defaults..\n"                                                .
   "      The final string is later used for calling the RQG runner.\n"                            .
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
   "--run-all-combinations-once\n"                                                                 .
   "      Generate a deterministic sequence of combinations.\n"                                    .
   "      The number of combinations limits the maximum number of trials!\n"                       .
   "      --start-combination=<m>\n'"                                                              .
   "             Start the execution with the m'th combination.\n"                                 .
   "--trials=<n>\n"                                                                                .
   "      rqg_batch.pl will exit if this number of regular finished trials(RQG runs) is reached.\n".
   "      n = 1 --> Write the output of the RQG runner to screen and do not cleanup at end.\n"     .
   "                Maybe currently not working or in future removed.                        \n"   .
   "--max_runtime=<n>\n"                                                                           .
   "      Stop ongoing RQG runs if the total runtime in seconds has exceeded this value,\n"        .
   "      give a summary and exit.\n"                                                              .
   "--parallel=<n>\n"                                                                              .
   "      Maximum number of parallel RQG Workers performing RQG runs.\n"                           .
   "      (Default) All OS: If supported <return of OS command nproc> otherwise 1.\n\n"            .
   "      WARNING - WARNING - WARNING -  WARNING - WARNING - WARNING - WARNING - WARNING\n"        .
   "         Please be aware that OS/user/hardware resources are limited.\n"                       .
   "         Extreme resource consumption (high value for <n> and/or fat RQG tests) could result\n".
   "         in some very slow reacting testing box up till OS crashes.\n"                         .
   "         Critical candidates: open files, max user processes, free space in tmpfs\n"           .
   "         Future improvement of rqg_batch.pl will reduce these risks drastic.\n\n"              .
   "Not assignable --queries\n"                                                                    .
   "      But if its not in the combination string than --queries=100000000 will be appended.\n"   .
   "also not passed through to the RQG runner.\n"                                                  .
   "          If neither --no_mask, --mask or --mask-level is in the combination string than "     .
   "a --mask=.... will be appended to it.\n"                                                       .
   "          Impact of the latter in the RQG runner: mask-level=1 and that --mask=...\n"          .
   "--seed=...\n"                                                                                  .
   "      Seed value used here for generation of random combinations. In case the combination \n"  .
   "      does not already assign seed than this will be appended to the string too.\n"            .
   "      (Default) 1 do not append to the combination string.\n"                                  .
   "      --seed=time assigned here or being in combination string will be replaced by\n"          .
   "      --seed=<value returned by some call of time() in perl>.\n"                               .
   "--runner=...\n"                                                                                .
   "      The RQG runner to be used. The value assigned must be without path.\n"                   .
   "      (Default) rqg.pl in RQG_HOME.\n"                                                         .
   "--discard_logs\n"                                                                              .
   "      Remove even the logs of RQG runs with the verdict '" . Verdict::RQG_VERDICT_IGNORE       .
   "'\n"                                                                                           .
   "--stop_on_replay\n"                                                                            .
   "      As soon as the first RQG run achieved the verdict '" . Verdict::RQG_VERDICT_REPLAY       .
   " , stop all active RQG runners, cleanup, give a summary and exit.\n\n"                         .
   "--dryrun\n"                                                                                    .
   "      Run the complete mechanics except that the RQG worker processes forked\n"                .
   "      - print the RQG call which they would run\n"                                             .
   "      - do not start RQG at all but fake a few effects checked by the parent process\n"        .
   "      - exit with STATUS_OK(0).\n"                                                             .
   "      - exit with STATUS_OK(0).\n"                                                             .
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
   "                  --dryrun --script_debug¸\n"                                                  .
   "      is an easy/fast way to check certains aspects of\n"                                      .
   "      - the order and job management in rqg_batch in general\n"                                .
   "      - optimizations (depend on progress) for grammar simplification\n"                       .
   "-------------------------------------------------------------------------------------------\n" .
   "Group of parameters which get appended to the combination string and so passed through to \n"  .
   "the RQG runner. For their meaning please look into the output of '<runner> --help'.       \n"  .
   "--duration=<n>\n"                                                                              .
   "--gendata=...\n"                                                                               .
   "--grammar=...\n"                                                                               .
   "--threads=<n>  (Hint: Set it once to 1. Maybe its not a concurrency bug.)\n"                   .
   "--no_mask      (Assigning --mask or --mask-level on command line is not supported.)\n"         .
   "--testname=...\n"                                                                              .
   "--xml-output=...\n"                                                                            .
   "--report-xml-tt=...\n"                                                                         .
   "--report-xml-tt-type=...\n"                                                                    .
   "--report-xml-tt-dest=...\n"                                                                    .
   "-------------------------------------------------------------------------------------------\n" .
   "rqg_batch will create a symlink '$symlink' pointing to the workdir of his run\n"               .
   "which is <value assigned to workdir>/<runid>.\n"                                               .
   "-------------------------------------------------------------------------------------------\n" .
   "How to cause some rapid stop of the ongoing rqg_batch.pl run without using some dangerous "    .
   "killall SIGKILL <whatever>?\n"                                                                 .
   "    touch $symlink" . "/exit\n"                                                                .
   "rqg_batch.pl will stop all active RQG runners, cleanup and give a summary.\n\n"                .
   "What to do on Linux in the rare case (RQG core or runner broken) that this somehow fails?\n"   .
   "    killall -9 perl ; killall -9 mysqld ; rm -rf /dev/shm/vardir/*\n"                          .
   "-------------------------------------------------------------------------------------------\n" .
   "How to cause some non-random run with fixed range of combinations covered?\n"                  .
   "Assign\n"                                                                                      .
   "   --run-all-combinations-once --> Generation of a deterministic sequence of combinations\n"   .
   "with optional\n"                                                                               .
   "   --start_combination<m> --> Omit trying the first <m - 1> combinations.\n"                   .
   "The range of combinations covered could be limited/extended via trials and/or max_runtime.\n"  .
   "In case none of them is set than the rqg_batch.pl run ends after the RQG run with the last \n" .
   "not yet tried combination has finished regular.\n"                                             .
   "-------------------------------------------------------------------------------------------\n" .
   "Impact of RQG_HOME if found in environment and the current working directory:\n"               .
   "Around its start rqg_batch.pl searches for RQG components in <CWD>/lib and ENV(\$RQG_HOME)/lib\n" .
   "- rqg_batch.pl computes RQG_HOME from its call and sets than some corresponding "              .
   "  environment variable.\n"                                                                     .
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

sub active_workers {

# Purpose:
# --------
# Return the number of active RQG Workers based on the last bookkeeping (when we reaped).
#
# Attention
# ---------
# reap_workers returns logically also the number of active RQG Workers but
# - more exact because based on some just performed bookkeeping
# - needs more runtime
#

    my $active_workers = 0;

    for my $worker_num (1..$workers) {
        $active_workers++ if $worker_array[$worker_num][WORKER_PID] != -1;
    }
    return $active_workers;

}


##### FIXME: Put all order management routines into a separate perl module order_management.pm
# Its mostly in lib/Batch.pm
# my $out_of_ideas = 0;
# sub get_job {
#
#     # ....
#     # Check here or before if we should not give up.
#     my $order_id;
#     while (not defined $order_id and not $out_of_ideas) {
#     #     while (not defined $order_id and $not out_of_ideas) {
#         $order_id = shift @try_first_queue;
#         if (defined $order_id) {
#             say("DEBUG: Order $order_id picked from \@try_first_queue.") if $script_debug;
#             last
#         }
#
#         # In case we are here than @try_first_queue was empty.
#         $order_id = shift @try_queue;
#         if (defined $order_id) {
#             say("DEBUG: Order $order_id picked from \@try_queue.") if $script_debug;
#             last
#         } else {
#             if ( not generate_orders() ) {
#                 $out_of_ideas = 1;
#             }
# Up till today nowher implemented stuff begin
#
#             if (conditions when to bring @try_later_queue again into the game fulfilled) {
#                 push @try_queue, @try_later_queue;
#                 @try_later_queue =();
#                 next;
#             } else {
#                 if (not generate_orders()) {
#                     # Generating additional orders (they get immediate appended to @try_queue)
#                     # was not successful.
#                     $out_of_ideas = 1;
#                 } else {
#                     $order_id = shift @try_queue;
#                     last;
#                 }
#             }
#         }
#
#         if (conditions when to bring @try_later_queue again into the game fulfilled) {
#             push @try_queue, @try_later_queue;
#             @try_later_queue =();
#             next;
#         }
# Up till today nowhere implemented stuff end
#         }
#     }
#     if (not defined $order_id and $out_of_ideas) {
#         return undef;
#     } else {
#         if (order_is_valid($order_id)) {
#             return $order_id;
#         } else {
#             $order_id = undef;
#         }
#     }
# }

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
#

sub cl_adjustment {

# Purpose
# -------
# There is a crowd of command line which could be set. And they should either override settings
# provided by the config file processing or complement it.
# Overriding is done by appending it to the nearly final command.
# In addition its not recommended to store these settings in the order array too because its
# the same for all jobs.
#

    my $command_append = '';

    # The line set to comment from combinations.pl.
    # Advantage:
    #   I prefer using duration or similar as runtime limiter in general.
    #   A big enough number of queries prevents that the number of queries acts finally as limiter.
    #   Of course a small number of queries could be compensated by running more trials.
    #   But going with more trials could suffer to some more or less big extend (depending on the
    #   test setup) from some unfortunate
    #      The efforts for generating the initial stuff, get server(s) up run gendata are constant
    #      and have to be payed for every trial. What if they are big?
    #      What if the likelihood to replay raises with number of queries/runtime?
    # Disadvantage:
    #   Ugly inconsistency to the concept of having one default for queries and that for all tools
    #   because also RQG runner, config file templates and GenTest have defaults for queries.
    # My current opinion:
    # Give sufficient information about advantages/disadvantages in config file templates etc.
    # and set there a default. The user is free to change that value within the file or
    # override it via commandline.
    # $command .= " --queries=100000000"                       if $comb_str !~ /--queries=/;
    #
    # combinations.pl adds here as default masking based on good experiences and/or hopes.
    # This contradicts my experience with concurrency tests and grammar simplifiers within the
    # last eight years. Especially the masking style (affect the top level rules only) was mostly
    # leading to the opposite.
    # My opinion:
    # 1. Never apply something as default that forces than some serious fraction of users
    #    to switch it off via config file or command line.
    # 2. Who thinks that whatever kinds of masking gives him advantages is free to invoke that
    #    via command line.
    # 3. FIXME:
    #    Maybe offer the option to apply automatic masking combined with test running.
    #    - increment mask per every attempt to generate a masked grammar (all same level)
    #    - increment mask level and set mask to 1 whenever the ten last attempts to generate
    #      some masked grammar produced one which we had already tried (md5sum compare).
    #      ten because we can have duplicate/repeated components in rules.
    #    Vague alternative: Use the grammar simplification mechanics for that.
    #      Advantage: Mechanics exists
    #      Disadvantage: Remove more than one unique components
    # combinations.pl used $command .= " --mask=$mask" if $comb_str !~ /-mask/;

    $command_append .= " --duration=$duration"
        if defined $duration and $duration ne '';

    #
    # $command_append .= " --basedir='$basedirs[0]'" if defined $basedirs[0];
    $command_append .= " --basedir1='$basedirs[1]'"
        if defined $basedirs[1];
    $command_append .= " --basedir2='$basedirs[2]'"
        if defined $basedirs[2];
    $command_append .= " --basedir3='$basedirs[3]'"
        if defined $basedirs[3];
    $command_append .= " --gendata=$gendata "
        if defined $gendata;
    $command_append .= " --grammar=$grammar "
        if defined $grammar;
    # In case seed is in the command line than it should rule.
    # combinations.pl used $command_append .= " --seed=$seed " if $comb_str !~ /--seed=/;
    $command_append .= " --seed=$seed "
        if defined $seed;
    $command_append .= " --no-mask "
        if defined $no_mask;
    $command_append .= " --threads=$threads "
        if defined $threads;
    $command_append .= " --testname=$testname "
        if defined $testname and $testname ne '';
    $command_append .= " --xml-output=$xml_output "
        if defined $xml_output and $xml_output ne '';
    $command_append .= " --report-xml-tt"
        if defined $report_xml_tt;
    $command_append .= " --report-xml-tt-type=$report_xml_tt_type "
        if defined $report_xml_tt_type and $report_xml_tt_type ne '';
    $command_append .= " --report-xml-tt-dest=$report_xml_tt_dest "
        if defined $report_xml_tt_dest and $report_xml_tt_dest ne '';

    return $command_append;

}

sub emergency_exit {

    my ($status, $reason) = @_;
    say($reason);
    # In case we ever do more in stop_workers than $give_up = 2 might be of value.
    $give_up = 2;
    stop_workers();
    safe_exit ($status);

}


sub init_job_management {
    # max_runtime
    # trials
    # basedir
    # vardir
}



1;
