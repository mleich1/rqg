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
use GenTest;
use GenTest::Random;
use GenTest::Constants;
use Getopt::Long;
use GenTest::BzrInfo;
use Data::Dumper;

# Structure for managing RQG Worker (child processes)
my @worker_array = ();
use constant WORKER_PID     => 0;
use constant WORKER_START   => 1;
use constant WORKER_CMD     => 2;
use constant WORKER_TRIAL   => 3;

# Name of the convenience symlink if symlink supported by OS
my $symlink = "last_batch_workdir";

my $command_line= "$0 ".join(" ", @ARGV);

$| = 1;

my $script_debug     = 0;
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
    print ("WARNING: The variable RQG_HOME with the value '$rqg_home_env' was found in the " .
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

$SIG{INT}  = sub { $ctrl_c = 1 };
$SIG{TERM} = sub { exit(0) };
$SIG{CHLD} = "IGNORE" if osWindows();

my ($config_file, $basedir, $vardir, $trials, $build_thread, $duration, $grammar, $gendata,
    $seed, $testname, $xml_output, $report_xml_tt, $report_xml_tt_type, $list, $max_runtime,
    $report_xml_tt_dest, $force, $no_mask, $exhaustive, $start_combination, $debug, $noLog,
    $workers, $new, $servers, $noshuffle, $clean, $workdir, $discard_logs, $help, $runner,
    $stop_on_replay, $runid, $threads);

my @basedirs      = ('', '');
my $combinations;
my %results;
my @commands;
my $max_result    = 0;
my $epochcreadir;

my $discard_logs  = 0;

# FIXME:
# Modify these options.
# --debug
# This should rather focus on debugging of the current script.
# "--list" offers printing of the combinations provided by "--debug" in history.
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

if (not GetOptions(
    $opt_result,
           'help'                      => \$help,
           'config=s'                  => \$config_file,
           'basedir=s'                 => \$basedirs[0],
           'basedir1=s'                => \$basedirs[0],
           'basedir2=s'                => \$basedirs[1],
           'workdir=s'                 => \$workdir,
           'vardir=s'                  => \$vardir,
           'build_thread=i'            => \$build_thread,
           'list'                      => \$list,
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
           'debug'                     => \$debug,             # Dry run
           'no-log'                    => \$noLog,             # Print all to command window
           'parallel=i'                => \$workers,
           'runner=s'                  => \$runner,
           'stop_on_replay'            => \$stop_on_replay,
           'servers=i'                 => \$servers,
           'threads=i'                 => \$threads,
           'no-shuffle'                => \$noshuffle,
           'clean'                     => \$clean,        # clean + STATUS_OK -> Throw log away but not RQG run workdir/vardir
                                                          # clean + != STATUS_OK -> Archive RQG run workdir/vardir and throw them away
                                                          # clean according to verdict given by the RQG runner but what if STATUS_OK logs wanted
           'discard_logs'              => \$discard_logs, # In case if ($result > 0 and not $discard_logs) than archiving
           'discard-logs'              => \$discard_logs,
           'script_debug'              => \$script_debug,
           'runid:i'                   => \$runid,
                                                   )) {
    # Somehow wrong option.
    help();
    exit STATUS_ENVIRONMENT_FAILURE;
};

say("INFO: Command line: " . $command_line);

# debug
# list (default)
# dryrun
# script

# trials=0 --> Dry run

# Counter for statistics
# ------------------------
my $verdict_init      = 0;
my $verdict_replay    = 0;
my $verdict_interest  = 0;
my $verdict_ignore    = 0;
my $verdict_collected = 0;
my $runs_started      = 0;

if (defined $help) {
   help();
   exit 0;
}

if (not defined $config_file) {
    say("ERROR: The mandatory config file is not defined.");
    exit STATUS_ENVIRONMENT_FAILURE;
}
if (not -e $config_file) {
    say("ERROR: The config file '$config_file' does not exist or is not a plain file.");
    exit STATUS_ENVIRONMENT_FAILURE;
}
open(CONF, $config_file) or croak "unable to open config file '$config_file': $!";
read(CONF, my $config_text, -s $config_file);
close(CONF);
# For experiments:
# $config_text = "Hello";
eval ($config_text);
if ($@) {
    say("ERROR: Unable to load '$config_file': " . $@ .
        "Will exit with STATUS_ENVIRONMENT_FAILURE");
    exit STATUS_ENVIRONMENT_FAILURE;
}

if (not defined $runner) {
    $runner = "rqg.pl";
    say("INFO: The RQG runner was not assigned. Will use the default '$runner'.");
}
if (File::Basename::basename($runner) ne $runner) {
    say("Error: The value for the RQG runner '$runner' needs to be without any path.");
}
$runner = $rqg_home . "/" . $runner;
if (defined $runner) {
    if (not -e $runner) {
        say("ERROR: The RQG runner '$runner' does not exist. " .
            "Will exit with STATUS_ENVIRONMENT_FAILURE");
        exit STATUS_ENVIRONMENT_FAILURE;
    }
}

$build_thread = Auxiliary::check_and_set_build_thread($build_thread);
if (not defined $build_thread) {
    my $status = STATUS_ENVIRONMENT_FAILURE;
    say("$0 will exit with exit status " . status2text($status) . "($status)");
    safe_exit($status);
}

my $comb_count = $#$combinations + 1;
my $total      = 1;
foreach my $comb_id (0..($comb_count - 1)) {
    $total *= $#{$combinations->[$comb_id]} + 1;
}
if ($exhaustive) {
    if (defined $trials) {
        if ($trials < $total) {
            say("WARN: You specified --run-all-combinations-once, which gives $total combinations, " .
                "but then limited the same with --trials=$trials");
        } else {
            $trials = $total;
        }
    } else {
        $trials = $total;
    }
}
say("INFO: Number of sections to pick an entry from and combine : $comb_count");
say("INFO: Number of trials required for running all possible combinations once : $total");


# This handling of seed affects mainly the generation of random combinations.
if (not defined $seed) {
    $seed = 1;
    say("INFO: seed is not defined. Setting it to the default 1.");
}
if ($seed eq 'time') {
    $seed = time();
}
my $prng = GenTest::Random->new(seed => $seed);
my $trial_counter = 0;

my $trial_num = 1; # This is the number of the next trial if started at all.
                   # That also implies that incrementing must be after getting a valid command.
if ($list) {
    say("INFO: List of RQG calls which would be generated ====== Begin");
    say("INFO: Combinations+RQG run and OS specific settings are omitted");
    while(1) {
        if ($trial_num > $trials) {
            say("DEBUG: Number of trials already reached. Leaving while loop") if $script_debug;
            last;
        }
        my $command;
        if ($exhaustive) {
            $command = doExhaustive(0);
        } else {
            $command = doRandom();
        }
        if ($command ne '') {
            print("# $command\n");
            $trial_num++;
        } else {
            say("DEBUG: Number of combinations is exhausted.") if $script_debug;
            last;
        }
    }
    exit;
}

if (not defined $max_runtime) {
    $max_runtime = 432000;
    my $max_days = 432000 / 24 / 3600;
    say("INFO: Setting the maximum runtime to the default of $max_runtime" . "s ($max_days days).");
}
my $batch_end_time = $batch_start_time + $max_runtime;
my ($workdir, $vardir) = Auxiliary::make_multi_runner_infrastructure ($workdir, $vardir, $runid,
                                                                      $symlink);
# Note: In case of hitting an error make_multi_runner_infrastructure exits.
# Note: File::Copy::copy works only file to file. And so we might extract the name.
#       But using uniform file names isn't that bad.
File::Copy::copy($config_file, $workdir . "/combinations.cc");

# system("find $workdir $vardir");

# FIXME: Why that fiddling with basedirs and servers
#        Doesn't that all come through the cc file?
#        Or at least the cc file could set that.
if (!defined $servers) {
    $servers = 1;
    $servers = 2 if $basedirs[1] ne '';
}
croak "--servers may only be 1 or 2" if !($servers == 1 or $servers == 2);


my $logToStd = !osWindows() && !$noLog;

# say("DEBUG: logToStd is ->$logToStd<-");

if (not defined $workers) {
    $workers = 1;
} else {
    if ((not defined $trials) and (not defined $exhaustive)) {
        croak("ERROR: When using --parallel, also add either or both of these options:\n" .
              "       --run-all-combinations-once (exhaustive run) \n" .
              "       and/or\n" .
              "       --trials=x (random run).\n" .
              "       (Both options combined gives a non-random exhaustive run, yet limited by " .
              "the number of trials.)");
    }
    $logToStd = 0;
}

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

# Main purpose of $intentional_stop is:
# Some RQG run having ended (process is gone) with verdict 'init' and status != 'complete'
# is suspicious. This lets fear that whatever especially internal error has caused some
# evil outcome. Therefore this should be usually reported.
# But some RQG run being stopped (SIGKILL) intentional has a good chance to show the same
# suspicious properties but from known harmless reason.
# So no message about fearing an internal error if $intentional_stop == 0.
my $intentional_stop = 0;

my $exit_file    = $workdir . "/exit";
my $result_file  = $workdir . "/result.txt";
if (STATUS_OK != Auxiliary::make_file($result_file)) {
    say("ERROR: Creating the result file '$result_file') failed. " .
        "Will exit with STATUS_ENVIRONMENT_FAILURE");
    exit STATUS_ENVIRONMENT_FAILURE;
}

my $total_status = STATUS_OK;

my $trial_num = 1; # This is the number of the next trial if started at all.
                   # That also implies that incrementing must be after getting a valid command.
while(1) {
    # First handle all cases for giving up.
    # 1. The user created $exit_file for signalling rqg_batch.pl that it should stop.
    # For experimenting:
    # system("touch $exit_file");
    exit_file_check($exit_file);
    last if $intentional_stop;
    # 2. The assigned max_runtime is exceeded.
    runtime_exceeded($batch_end_time);
    last if $intentional_stop;
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
            say("DEBUG: thread [$free_worker] is free. Leaving search loop for non busy workers.")
                if $script_debug;
            last;
        }
    }
    if ($free_worker != -1) {
        # We have a free thread.
        my $command;
        if ($exhaustive) {
            $command = doExhaustive(0);
            say("DEBUG: doExhaustive(0) delivered ->$command'.") if $script_debug;
        } else {
            $command = doRandom();
            say("DEBUG: doRandom() delivered ->$command'.") if $script_debug;
        }
        if ($command ne '') {
            say("DEBUG: Thread [$free_worker] should run 'trial_$trial_num' " .
                "->$command<-") if $script_debug;
            # We have now a free/non busy RQG runner and a job
            $worker_array[$free_worker][WORKER_CMD] = $command;

            # Add options which need to be RQG runner specific in order to prevent collisions with
            # other active RQG runners started by rqg_batch.pl too.
            my $rqg_workdir = $workdir . "/" . "$free_worker";
            File::Path::rmtree($rqg_workdir);
            make_path($rqg_workdir);
            Auxiliary::make_rqg_infrastructure($rqg_workdir);
            say("DEBUG: [$free_worker] setting RQG workdir  to '$rqg_workdir'.") if $script_debug;
            $command .= " --workdir=$rqg_workdir";

            my $rqg_vardir = $vardir . "/" . "$free_worker";
            File::Path::rmtree($rqg_vardir);
            make_path($rqg_vardir);
            say("DEBUG: [$free_worker] setting RQG vardir  to '$rqg_vardir'.") if $script_debug;
            $command .= " --vardir=$rqg_vardir";
            $command .= " --mtr-build-thread=" . ($build_thread + ($free_worker - 1) * 2);

            my $rqg_log = $rqg_workdir . "/rqg.log";

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
                say("ERROR: The fork of the process for a RQG Worker failed.\n" .
                    "       Assume some serious problem. Perform an EMERGENCY exit" .
                    "(try to stop all child processes).");
                stop_workers();
                exit STATUS_CRITICAL_FAILURE;
            }
            $runs_started++;
            if ($pid == 0) {
                ########## Child
                $worker_id = $free_worker;
                # make_path($workdir); All already done by the parent
                my $result = 0;
                # For experimenting
                # system ("/work_m/RQG_mleich1/killer.sh &");
                setpgrp(0,0);
			    say("DEBUG: (Child) Final command for RQG run: ===>$command<===") if $script_debug;
                $result = system($command) if not $debug;

                $result = $result >> 8;

                my $verdict = Auxiliary::get_rqg_verdict($rqg_workdir);

                # FIXME/DECIDE
                # ------------
                # The RQG worker could also move the to be saved logs and archives.
                # Advantage:
                # - The parent process does not need to waste time on these operations.
                #   So he can react faster on desired or alarming events.
                # - These operations should not be that dangerous. But if something horrible happens
                #   and the parent process hangs or dies than the testing box or OS might come in
                #   some bad state. So let the worker do that makes the life of the parent more safe.
                # Disadvantage:
                # RQG worker stopped by the parent are "dead" and cannot do these operations.
                # So at least now the parent needs to do that. --> We need the code twice.

#               my $save_arc_cmd = "mv $rqg_workdir" . "/archive.tgz $target_prefix" . ".tgz";
#               my $clean_cmd    = "rm -rf $rqg_vardir";
#
#               # Make that all more finegrained but without too many extra options.
#               # Use Perl functions.
#
#               if ($verdict eq Auxiliary::RQG_VERDICT_IGNORE) {
#                  if (not $discard_logs) {
#                     system($save_log_cmd);
#                  }
#           } elsif ($verdict eq Auxiliary::RQG_VERDICT_INTEREST or
#                    $verdict eq Auxiliary::RQG_VERDICT_REPLAY) {
#              system($save_log_cmd);
#              system($save_arc_cmd);
#           } elsif ($verdict eq Auxiliary::RQG_VERDICT_INIT) {
#              # Should usually never happen. The RQG run died already at begin.
#              say("INTERNAL ERROR: Final Verdict is Auxiliary::RQG_VERDICT_INIT which should not happen.");
#           } else {
#              say("INTERNAL ERROR: Final Verdict '$verdict' is not treated/unknown. This should not happen.");
#           }
#           system($clean_cmd);

                say("DEBUG: Thread [$worker_id] will exit now with status $result") if $script_debug;

                exit $result;
            } else {
                ########## Parent
                $worker_array[$free_worker][WORKER_TRIAL] = $trial_num;
                $worker_array[$free_worker][WORKER_PID]   = $pid;
                my $workerspec = "Worker[$free_worker] with pid $pid for trial $trial_num";
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
                my $max_waittime  = 10;
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
                    say($message . "\n       Assume some serious problem. Perform an EMERGENCY exit" .
                        "(try to stop all child processes) without any cleanup of vardir and workdir.");
                    stop_workers();
                    exit STATUS_CRITICAL_FAILURE;
                }
                $worker_array[$free_worker][WORKER_START] = Time::HiRes::time();
                say("$workerspec forked and worker has taken over.");
                $trial_num++;
                $just_forked = 1;
                # $free_worker = -1;
                worker_array_dump() if $script_debug;
            }

            if ($just_forked) {
                # Experimental:
                # Try to reduce the load peak a bit by a small delay before running the next round
                # which might end with forking the next RQG runner.
                # FIXME: Refine
                my $active_workers = active_workers();
                if      (($workers / 4) >= $active_workers) {
                    # Do not wait
                } elsif (($workers / 2) >= $active_workers) {
                    sleep 1;
                } else {
                    sleep 3;
                }
            }

        } else {
           say("INFO: Number of combinations is exhausted.") if $script_debug;
           last;
        }
    } else {
        say("DEBUG: No free RQG runner found.") if $script_debug;
    }

    my $return = reap_workers();
    if ($intentional_stop == 1) {
        # This is most probably result of verdict 'replay' got and stop_on_replay is set.
        last;
    }
    # FIXME: Refine
    sleep 0.3;

} # End of while(1) loop with search for a free RQG runner and a job + starting it.


say("INFO: Phase of search for combination and bring it into execution is over.");
# We start with a moderate poll time in seconds because
# - not too much load intended ==> value minimum >= 0.2
# - not too long because other checks for bad states (not yet implemented) of the testing
#   environment will be added  ==> maximum <= 1,0
my $poll_time = 1;
# Poll till all tests are gone
while (reap_workers()) {
   # First handle all cases for giving up.
   # 1. The user created $exit_file for signalling rqg_batch.pl that it should stop.
   # For experimenting:
   # system("touch $exit_file");
   exit_file_check($exit_file);
   # No  last if $intentional_stop;   because we want the reap_workers() with the cleanup.
   $poll_time = 0.1 if $intentional_stop;
   # 2. The assigned max_runtime is exceeded.
   runtime_exceeded($batch_end_time);
   $poll_time = 0.1 if $intentional_stop;
   exit_file_check($exit_file);
   sleep $poll_time;
}

say("\n\n"                                                                                         .
    "STATISTICS: Number of RQG runs -- Verdict\n"                                                  .
    "STATISTICS: $verdict_replay -- '" . Auxiliary::RQG_VERDICT_REPLAY . "'-- "                    .
                 "Replay of desired effect (Whitelist match, no Blacklist match)\n"                .
    "STATISTICS: $verdict_interest -- '" . Auxiliary::RQG_VERDICT_INTEREST . "'-- "                .
                 "Otherwise interesting effect (no Whitelist match, no Blacklist match)\n"         .
    "STATISTICS: $verdict_ignore -- '" . Auxiliary::RQG_VERDICT_IGNORE . "'-- "                    .
                 "Effect is not of interest(Blacklist match or STATUS_OK)\n"                       .
    "STATISTICS: $verdict_init -- '" . Auxiliary::RQG_VERDICT_INIT . "'-- "                        .
                 "RQG run too incomplete (maybe stopped)\n"                                        .
    "STATISTICS: $verdict_collected -- Some verdict made.\n")                                      ;
say("STATISTICS: Total runtime in seconds : " . (time() - $batch_start_time))                      ;
say("STATISTICS: RQG runs started         : $runs_started")                                        ;

say("RESULT:     The logs and archives of the RQG runs performed are in the workdir of the "       .
                 "rqg_batch.pl run\n"                                                              .
    "                 $workdir\n")                                                                 ;
say("HINT:       As long as this was the last run of rqg_batch.pl the symlink\n"                   .
    "                 $symlink\n"                                                                  .
    "            will point to this workdir.\n")                                                   ;
say("RESULT:     The highest exit status of some RQG run was : $total_status")                     ;
my $best_verdict = Auxiliary::RQG_VERDICT_INIT;
$best_verdict = Auxiliary::RQG_VERDICT_IGNORE   if 0 < $verdict_ignore;
$best_verdict = Auxiliary::RQG_VERDICT_INTEREST if 0 < $verdict_interest;
$best_verdict = Auxiliary::RQG_VERDICT_REPLAY   if 0 < $verdict_replay;
say("RESULT:     The best verdict reached was : '$best_verdict'");
exit STATUS_OK;

exit;

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


## ----------------------------------------------------

# What is this trial counter now good for?
my $trial_counter = 0;

sub doExhaustive {
   my ($level, @idx) = @_;
   if ($level < $comb_count) {
      my @alts;
      foreach my $i (0..$#{$combinations->[$level]}) {
         push @alts, $i;
      }
      $prng->shuffleArray(\@alts) if !$noshuffle;

      foreach my $alt (@alts) {
         push @idx, $alt;
         return doExhaustive($level + 1, @idx) if $trial_counter < $trials;
         pop @idx;
      }
   } else {
      $trial_counter++;
      my @comb;
      foreach my $i (0 .. $#idx) {
         push @comb, $combinations->[$i]->[$idx[$i]];
      }
      my $comb_str = join(' ', @comb);
      next if $trial_counter < $start_combination;
      return doCombination($trial_counter, $comb_str, "combination");
   }
}

## ----------------------------------------------------

sub doRandom {
    my @comb;
    foreach my $comb_id (0..($comb_count - 1)) {
        my $n = $prng->uint16(0, $#{$combinations->[$comb_id]});
        $comb[$comb_id] = $combinations->[$comb_id]->[$n];
    }
    my $comb_str = join(' ', @comb);
    return doCombination($trial_num, $comb_str, "random trial");
}

## ----------------------------------------------------
sub doCombination {

   my ($trial_id,$comb_str,$comment) = @_;

   # No default masking!!
   my $command = "$comb_str ";

   $command .= " --queries=100000000"                       if $comb_str !~ /--queries=/;
#  $command .= " --mask=$mask"                              if $comb_str !~ /-mask/;

   $command .= " --duration=$duration"                      if $duration ne '';
   foreach my $s (1..$servers) {
      $command .= " --basedir" . $s . "=" . $basedirs[$s-1] . " " if $basedirs[$s-1] ne '';
   }
   $command .= " --gendata=$gendata "                       if $gendata ne '';
   $command .= " --grammar=$grammar "                       if $grammar ne '';
   $command .= " --seed=$seed "                             if $comb_str !~ /--seed=/;
   $command .= " --no-mask "                                if defined $no_mask;
   $command .= " --threads=$threads "                       if defined $threads;
   $command .= " --testname=$testname "                     if $testname ne '';
   $command .= " --xml-output=$xml_output "                 if $xml_output ne '';
   $command .= " --report-xml-tt"                           if defined $report_xml_tt;
   $command .= " --report-xml-tt-type=$report_xml_tt_type " if $report_xml_tt_type ne '';
   $command .= " --report-xml-tt-dest=$report_xml_tt_dest " if $report_xml_tt_dest ne '';

   my $tm = time();
   $command =~ s/--seed=time/--seed=$tm/g;

   $command =~ s{[\t\r\n]}{ }sgio;

   $commands[$trial_id] = $command;

   $command =~ s{"}{\\"}sgio;

#  # '_epoch' time directory creator extension (only activated if '_epoch' is used anywhere in the command line)
#  if ($command =~ m/_epoch/) {
#     my $epoch = `date -u '+%s%N' | tr -d '\n'`;
#     my $epochdir = defined $ENV{EPOCH_DIR}?$ENV{EPOCH_DIR}:'/tmp';
#     $epochcreadir = $epochdir . '/' . $epoch;
#     mkdir $epochcreadir or croak "unable to create directory '$epochcreadir': $!";
#     say ("[$worker_id] '_epoch' detected in command line. Created directory: $epochcreadir and substituted '_epoch' to it.");
#     $command =~ s/_epoch/$epochcreadir/sgo;
#  }

   while ($command =~ s/\s\s/ /g) {};
   $command =~ s/^\s*//;
#  say("[$worker_id] in doCombinations $command\n");

   return $command;


}

##------------------------------------------------------

sub reap_workers {

# 1. Reap finished workers so that processes in zombie state disappear.
# 2. Decide depending on the verdict and certain options what to do with maybe existing remainings
#    of the finished test.
# 3. Clean the workdir and vardir of the RQG run
# 4. Return the number of actice workers (process is busy/not reaped).

   # https://perldoc.perl.org/perlipc.html#Deferred-Signals-(Safe-Signals)

   my $active_workers = 0;
   for my $worker_num (1..$workers) {
      next if -1 == $worker_array[$worker_num][WORKER_PID];
      my $kid = waitpid($worker_array[$worker_num][WORKER_PID], WNOHANG);
      my $exit_status = $? > 0 ? ($? >> 8) : 0;
      if (not defined $kid) {
         say("ALARM: Got not defined waitpid return for thread $worker_num with pid " .
             $worker_array[$worker_num][WORKER_PID]);
      } else {
         say("DEBUG: Got waitpid return $kid for thread $worker_num with pid " .
             $worker_array[$worker_num][WORKER_PID]) if $script_debug;
         if ($kid == $worker_array[$worker_num][WORKER_PID]) {

            my $verdict = Auxiliary::get_rqg_verdict($workdir . "/" . $worker_num);
            say("INFO: Worker [$worker_num] with (process) exit status " .
                "'$exit_status' and verdict '$verdict' reaped.");

            my $rqg_workdir   = "$workdir" . "/" . $worker_num;
            my $rqg_log       = "$rqg_workdir" . "/rqg.log";
            my $rqg_vardir    = "$vardir" . "/" . $worker_num;

            my $target_prefix = $workdir . "/trial" . $worker_array[$worker_num][WORKER_TRIAL];
            my $save_log_cmd  = "mv $rqg_log  $target_prefix" . ".log";
            my $save_arc_cmd  = "mv $rqg_workdir" . "/archive.tgz $target_prefix" . ".tgz";
            my $clean_cmd     = "rm -rf $rqg_vardir $rqg_workdir";

#           # Make that all more finegrained but without too many extra options.
#           # Use Perl functions.

            if ($verdict eq Auxiliary::RQG_VERDICT_IGNORE) {
               if (not $discard_logs) {
                  system($save_log_cmd);
               }
               $verdict_ignore++;
               $verdict_collected++;
            } elsif ($verdict eq Auxiliary::RQG_VERDICT_INTEREST or
                     $verdict eq Auxiliary::RQG_VERDICT_REPLAY) {
               system($save_log_cmd);
               system($save_arc_cmd);
               if ($verdict eq Auxiliary::RQG_VERDICT_INTEREST) {
                  $verdict_interest++;
                  $verdict_collected++;
               } else {
                  $verdict_replay++;
                  $verdict_collected++;
               }
            } elsif ($verdict eq Auxiliary::RQG_VERDICT_INIT) {
               if ($intentional_stop) {
                  # The RQG worker was most probably stopped with SIGKILL.
                  # So threat the result as harmless.
                  $verdict_init++;
                  $verdict_collected++;
               } else {
                  # The RQG run died already at begin.
                  # This should usually never happen and is than most probably systematic.
                  say("INTERNAL ERROR: Final Verdict is Auxiliary::RQG_VERDICT_INIT which " .
                      "should not happen.");
                  system($save_log_cmd);
                  system($save_arc_cmd);
               }
            } else {
               say("INTERNAL ERROR: Final Verdict '$verdict' is not treated/unknown. " .
                   "This should not happen.");
               system($save_log_cmd);
               system($save_arc_cmd);
            }
            system($clean_cmd);
            my $command = $worker_array[$worker_num][WORKER_CMD];

            say("Verdict: $verdict -- $command") if $script_debug;
            my $my_string = "$worker_array[$worker_num][WORKER_TRIAL] # $verdict # $command\n";
            if (STATUS_OK != Auxiliary::append_string_to_file($result_file, $my_string)) {
               say("ERROR: Appending a string to the result file '$result_file' failed. " .
                   "       Assume some serious problem. Perform an EMERGENCY exit" .
                        "(try to stop all child processes).");
               stop_workers();
               exit STATUS_CRITICAL_FAILURE;
            }

            worker_reset($worker_num);
            $total_status = $exit_status if $exit_status > $total_status;
            if (defined $stop_on_replay and Auxiliary::RQG_VERDICT_REPLAY eq $verdict) {
                $intentional_stop = 1;
                say("INFO: We had '$verdict' and should stop on replay. Stopping all RQG Worker.");
                stop_workers();
            }
         } elsif (-1 == $kid) {
            say("ALARM: Thread $worker_num was already reaped.");
            worker_reset($worker_num);
         } else {
            say("DEBUG: Thread $worker_num with pid " . $worker_array[$worker_num][WORKER_PID] .
                " is running") if $script_debug;
            $active_workers++;
         }
      }
   }
   worker_array_dump() if $script_debug;
   say("DEBUG: Leave reap_workers and return (active workers found) : " .
       "$active_workers") if $script_debug;
   return $active_workers;
}

sub worker_array_dump {
   my $message = "worker_array_dump begin --------\n" .
                 "worker_num -- trial -- pid --start -- command\n";
   for my $worker_num (1..$workers) {
      $message = $message . $worker_num .
                 " -- " . $worker_array[$worker_num][WORKER_TRIAL] .
                 " -- " . $worker_array[$worker_num][WORKER_PID]   .
                 " -- " . $worker_array[$worker_num][WORKER_START] .
                 " -- " . $worker_array[$worker_num][WORKER_CMD]   . "\n";
   }
   say ($message . "worker_array_dump end   --------") if $script_debug;
}

sub worker_reset {
   my ($worker_num) = @_;
   $worker_array[$worker_num][WORKER_TRIAL] = -1;
   $worker_array[$worker_num][WORKER_PID]   = -1;
   $worker_array[$worker_num][WORKER_START] = -1;
   $worker_array[$worker_num][WORKER_CMD]   = undef;
}

sub stop_worker {
   my ($worker_num) = @_;
   my $pid = $worker_array[$worker_num][WORKER_PID];
   if (-1 != $pid) {
      # Per last update of bookkeeping the RQG Woorker was alive.
      # We ask to kill the processgroup of the RQG Worker.
      kill '-KILL', $pid;
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
      $intentional_stop = 1;
      say("INFO: Exit file detected. Stopping all RQG Worker.");
      stop_workers();
   }
}

sub runtime_exceeded {
   my ($batch_end_time) = @_;
   if ($batch_end_time  < Time::HiRes::time()) {
      $intentional_stop = 1;
      say("INFO: The maximum total runtime is exceeded. Stopping all RQG Worker.");
      stop_workers();
   }
}

sub help() {
   print(
   "\nSorry, under construction and partially different or not yet implemented.\n\n"               .
   "Purpose: Perform a batch of RQG runs with massive parallelization according to setup/config\n" .
   "         Be a replacement for\n"                                                               .
   "         (immediate) combinations.pl, bughunt.pl, runall-trials.pl\n"                          .
   "         (soon)      simplify-grammar.pl\n"                                                    .
   "Terms used:\n"                                                                    .
   "combination string\n"                                                                    .
   "      A fragment of a RQG call generated by rqg_batch.pl based on config file content.\n"      .
   "      rqg_batch.pl might transform and especially append more settings.\n"                     .
   "      The final string is later used for calling the RQG runner.\n"                            .
   "Default\n"                                                                               .
   "      What you get in case you do not assign some corresponding --<parameter>=<value>.\n"      .
   "RQG Worker\n"                                                                               .
   "      A child process which runs prepare play ground, perform RQG run, clean up and exit.\n"   .
   "--trials=<n>\n"                                                                                .
   "      rqg_batch.pl will exit if this number of trials(RQG runs) is reached.\n"              .
   "      n = 1 --> Write the output of the RQG runner to screen and do not cleanup at end.\n"     .
   "                Maybe currently not working.                                             \n"   .
   "--max_runtime=<n>\n"                                                                           .
   "      Stop ongoing RQG runs if the total runtime in seconds has exceeded this value,\n"        .
   "      give a summary and exit.\n"                                                              .
   "--parallel=<n>\n"                                                                              .
   "      Maximum number of parallel RQG Workers performing RQG runs.\n"                           .
   "      (Default) All OS: If supported <return of nproc - 1> otherwise 1.\n\n"                   .
   "      WARNING - WARNING - WARNING -  WARNING - WARNING - WARNING - WARNING - WARNING\n"        .
   "          Please be aware that OS/user/hardware resources are limited.\n"                      .
   "         Extreme resource consumption (high value for <n> and/or fat RQG tests) could result\n".
   "          in some very slow reacting testing box up till OS crashes.\n"                        .
   "         Critical candidates: open files, max user processes, free space in tmpfs\n\n"         .
   "Not assignable --queries\n"                                                                   .
   "       But if its not in the combination string than --queries=100000000 will be appended.\n"  .
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
   "      Remove even the logs of RQG runs with the verdict '" . Auxiliary::RQG_VERDICT_IGNORE     .
   "'\n"                                                                                           .
   "--stop_on_replay\n"                                                                             .
   "      As soon as the first RQG run achieved the verdict '" . Auxiliary::RQG_VERDICT_REPLAY     .
   " , stop all active RQG runners, cleanup, give a summary and exit.\n\n"                         .
   "--script_debug\n"                                                                              .
   "      Print additional detailed information about decisions made by rqg_batch.pl\n"            .
   "      and observations made during runtime.\n"                                                 .
   "      Debug functionality of other RQG parts like the RQG runner will be not touched!\n"       .
   "      (Default) No additional information.\n"                                                  .
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
   "rpl_batch.pl will stop all active RQG runners, cleanup and give a summary.\n\n"                .
   "What to do on Linux in the rare case (RQG core or runner broken) that this somehow fails?\n"   .
   "    killall -9 perl ; killall -9 mysqld ; rm -rf /dev/shm/vardir/*\n"                          .
   "-------------------------------------------------------------------------------------------\n" .
   "How to cause some rapid (*) stop of the ongoing rqg_batch.pl run without using killall ...?\n" .
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

#  foreach my $s (1..$servers) {
#     $command .= " --basedir" . $s . "=" . $basedirs[$s-1] . " " if $basedirs[$s-1] ne '';
#  }

}

sub active_workers {

# Purpose:
# --------
# Return the number of active RQG Workers based on the last bookkeeping (when we reaped).

   my $active_workers = 0;

   for my $worker_num (1..$workers) {
      $active_workers++ if $worker_array[$worker_num][WORKER_PID] != -1;
   }
   return $active_workers;

}


1;
