#  Copyright (c) 2018, MariaDB Corporation Ab.
#  Use is subject to license terms.
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; version 2 of the License.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301  USA */
#

package Batch;

# TODO:
# - Structure everything better.
# - Add missing routines
# - Decide about the relationship to the content of
#   lib/GenTest.pm, lib/DBServer/DBServer.pm, maybe more.
#   There are various duplicate routines like sayFile, tmpdir, ....
# - search for string (pid or whatever) after pattern before line end in some file
# - move too MariaDB/MySQL specific properties/settings out
# It looks like Cwd::abs_path "cleans" ugly looking paths with superfluous
# slashes etc.. Check closer and use more often.
#
# Hint:
# All variables which get direct accessed by routines from other packages like
#     push @Batch::try_queue, $order_id_now;
# need to be defined with 'our'.
# Otherwise we get a warning like
#     Name "Batch::try_queue" used only once: possible typo at ./rqg_batch.pl line 1766.
# , NO abort and no modification of the queue defined here.
# Alternative solution:
# Define with 'my' and the routines from other packages call some routine from here which
# does the required manipulation.

use strict;

use GenTest::Constants;
use GenTest;
use File::Copy;
use Cwd;
use Auxiliary;
use Verdict;
use ResourceControl;
use POSIX qw( WNOHANG );

# use constant STATUS_OK       => 0;
use constant STATUS_FAILURE    => 1; # Just the opposite of STATUS_OK


# Constants serving for more convenient printing of results in table layout
# -------------------------------------------------------------------------
use constant RQG_NO_TITLE        => 'Number';
use constant RQG_NO_LENGTH       => 6;              # Maximum is 999999

use constant RQG_LOG_TITLE       => 'RQG log   ';   # 999999.log or <deleted>
use constant RQG_LOG_LENGTH      => 10;             # 999999.log or <deleted>

use constant RQG_ORDERID_TITLE   => 'OrderId';
use constant RQG_ORDERID_LENGTH  => 7;              # Maximum is 9999999/Title

use constant RQG_GRAMMAR_C_TITLE => 'Grammar used';
use constant RQG_GRAMMAR_P_TITLE => 'Parent      ';
use constant RQG_GRAMMAR_LENGTH  => 12;             # Maximum is Title

our $workdir;
our $vardir;
my  $result_file;

# Counter for statistics
# ----------------------
our $runs_stopped          = 0;
our $verdict_init          = 0;
our $verdict_replay        = 0;
our $verdict_interest      = 0;
our $verdict_ignore        = 0;
our $stopped       = 0;
our $verdict_collected     = 0;
our $runs_finished_regular = 0;


my $discard_logs;
sub check_and_set_discard_logs {
    ($discard_logs) = @_;
}
my $dryrun;
sub check_and_set_dryrun {
    ($dryrun) = @_;
    if (defined $dryrun) {
        my $result = Auxiliary::check_value_supported (
                         'dryrun', Verdict::RQG_VERDICT_ALLOWED_VALUE_LIST, $dryrun);
        if ($result != STATUS_OK) {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: 'dryrun': Non supported value assigned or assignment forgotten and some " .
                "wrong value like '--dryrun=13' got. " . Auxiliary::exit_status_text($status));
            safe_exit($status);
        }
        say("INFO: Performing a 'dryrun' == Do not run RQG and fake the verdict to be '$dryrun'.");
    }
}

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
our @worker_array = ();
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
use constant WORKER_VERDICT   => 7;
use constant WORKER_LOG       => 8;
use constant WORKER_WON       => 9;
# In case a 'stop_worker' had to be performed than WORKER_END will be set to the current timestamp
# when issuing the SIGKILL that RQG worker processgroup.
# When 'reap_worker' gets active the following should happen
# if defined WORKER_END
#    make a note within the RQG log of the affected worker that he was stopped
#    set verdict to VERDICT_IGNORE_STOPPED etc.
# else
#    set WORKER_END will be set to the current timestamp
#

# Whenever rqg_batch.pl calls Combinator/Simplifier::register_result than that routine will
# return an array
# first element is the status (the usual like STATUS_ENVIRONMENT_FAILURE etc.)
#     Expected reaction:
#     If STATUS_OK != that status than emergency_exit with that status.
#     Its because Combinator/Simplifier::register_result cannot reach emergency_exit.
#     Btw: action should be set to REGISTER_GO_ON and not undef.
#     Use case:
#     Trouble when processing the result, updating files etc. makes all 'hopeless'.
# second element is string and tells the caller how to proceed
# The constants are for that.
use constant REGISTER_GO_ON      => 'register_ok';
     # Expected reaction:
     # Just go on == Ask for the next job when having free resources except status was != STATUS_OK.
     # No remarkable change in the work flow. The next tests are roughly like the previous one.
use constant REGISTER_STOP_ALL   => 'register_stop_all';
     # Expected reaction:
     # Stop all active RQG runs and ask for the next job when having free resources.
     # Use case:
     # The result got made all ongoing RQG runs obsolete and so they should be aborted.
     # Example:
     # Bugreplay where we
     # - need to replay some desired outcome only once
     # - want to go on with free resources and something different as soon as possible.
use constant REGISTER_STOP_YOUNG => 'register_stop_young';
     # Expected reaction:
     # Stop all active RQG runs which are in phase init , start or gentest.
     # Use case:
     # The result got made all ongoing RQG runs obsolete and so they should be aborted.
     # Example:
     # Bugreplay where we
     # - need to replay some desired outcome only once
     # - want to go on with free resources and something different as soon as possible.
use constant REGISTER_END        => 'register_end';


# The types of batch runs
# -----------------------
our $batch_type;
#
# Run like historic combinations.pl
use constant BATCH_TYPE_COMBINATOR    => 'Combinator';
#
# Run like historic bughunt.pl but extended to
# - vary
#   start with min_val, increment as long as <= max_val
#   start with min_val, double the value as long as <= max_val
#   random value between min_val and max_val
# - parameters like seed or threads
# (not yet implemented)
use constant BATCH_TYPE_VARIATOR      => 'Variator';
#
# Run with applying masking
# - to any top level rule and
# - increasing the value for 'mask' as long we have not reached a cycle and
#   Cycle: The last 10 attempts to get a never tried grammar via masking (md5sum comparison) failed.
# - after having got a cycle increasing 'mask_level' and setting mask to 1 and
# - after having got a mask_level being so high that we get all time the original grammar again
#   switching to the next top level rule
# not yet implemented
use constant BATCH_TYPE_MASKING       => 'Masking';
#
# Run with grammar (--> 'G') simplifier (to be implement next)
use constant BATCH_TYPE_G_SIMPLIFIER  => 'G_Simplifier';
# Some more simplifier types are at least thinkable but its in the moment unclear if they would
# fit to the general capabilities of rqg_batch.pl.
#
use constant BATCH_TYPE_ALLOWED_VALUE_LIST => [
    # BATCH_TYPE_COMBINATOR, BATCH_TYPE_VARIATOR, BATCH_TYPE_MASKING, BATCH_TYPE_G_SIMPLIFIER];
      BATCH_TYPE_COMBINATOR,                                          BATCH_TYPE_G_SIMPLIFIER];

# my $workers;
our $workers;
sub check_and_set_workers {
    ($workers) = @_;
    for my $worker_num (1..$workers) {
        worker_reset($worker_num);
    }
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
    $worker_array[$worker_num][WORKER_VERDICT]  = undef;
    $worker_array[$worker_num][WORKER_LOG]      = undef;
}

sub get_free_worker {
    for my $worker_num (1..$workers) {
        # -1 == $worker_array[$worker_num][WORKER_PID]
        # --> No main process of the RQG worker
        #     Either never in use or already reaped
        # not defined $worker_array[$worker_num][WORKER_VERDICT]
        # --> Its not the state where
        #     The main process of the RQG worker was just reaped
        #     and the processing of the result is missing.
        if (-1 == $worker_array[$worker_num][WORKER_PID] and
            not defined $worker_array[$worker_num][WORKER_VERDICT]) {
            say("DEBUG: RQG worker [$worker_num] is free. Leaving search loop " .
                "for non busy workers.") if Auxiliary::script_debug("T6");
            return $worker_num;
        }
    }
    return undef;
}

# $worker_array[$worker_num][WORKER_PID] != -1
# --> main RQG worker process was running during the last reap_workers call
# defined $worker_array[$worker_num][WORKER_VERDICT]

sub count_active_workers {
# Purpose:
# --------
# Return the number of active (== serious storage space consuming) RQG Workers.
# == During the last reap_workers call we could not reap the main process.
#    --> $worker_array[$worker_num][WORKER_PID] != -1
#    Hence the vardir and the workdir of these processes could be not deleted.
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

sub worker_array_dump {
use constant WORKER_ID_LENGTH  =>  3;
use constant WORKER_PID_LENGTH =>  6;
use constant WORKER_START_LENGTH => 10;
use constant WORKER_ORDER_LENGTH =>  8;
    my $message = "worker_array_dump begin --------\n" .
                  "id  -- pid    -- job_start  -- job_end    -- order_id -- " .
                  "extra1  -- extra2  -- extra3  -- verdict -- log\n";
    for my $worker_num (1..$workers) {
        $message = $message . Auxiliary::lfill($worker_num, WORKER_ID_LENGTH) .
           " -- " . Auxiliary::lfill($worker_array[$worker_num][WORKER_PID],   WORKER_PID_LENGTH)      .
           " -- " . Auxiliary::lfill($worker_array[$worker_num][WORKER_START], WORKER_START_LENGTH)    .
           " -- " . Auxiliary::lfill($worker_array[$worker_num][WORKER_END],   WORKER_START_LENGTH)      .
           " -- " . Auxiliary::lfill($worker_array[$worker_num][WORKER_ORDER_ID], WORKER_ORDER_LENGTH)  ;
        foreach my $index (WORKER_EXTRA1, WORKER_EXTRA2, WORKER_EXTRA3,WORKER_VERDICT,WORKER_LOG) {
            my $val = $worker_array[$worker_num][$index];
            if (not defined $val) {
                $val = "<undef>";
            }
            $message = $message . " -- " . $val;
        }
        $message = $message . "\n";
    }
    say ($message . "worker_array_dump end   --------") if Auxiliary::script_debug("T6");
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

sub stop_worker_young {
    for my $worker_num (1..$workers) {
        my $pid = $worker_array[$worker_num][WORKER_PID];
        if (-1 != $pid) {
            # Per last update of bookkeeping the RQG Woorker was alive.
            my $rqg_workdir = $workdir . "/" . $worker_num;
            my $rqg_phase = Auxiliary::get_rqg_phase($rqg_workdir);
            if      (not defined $rqg_phase) {
                my $status = STATUS_ENVIRONMENT_FAILURE;
                emergency_exit($status, "ERROR: Batch::stop_worker_young : No phase for " .
                               "RQG worker $worker_num got. Will ask for emergency_exit.");
            } elsif (Auxiliary::RQG_PHASE_INIT    eq $rqg_phase or
                     Auxiliary::RQG_PHASE_START   eq $rqg_phase or
                     Auxiliary::RQG_PHASE_PREPARE eq $rqg_phase or
                     Auxiliary::RQG_PHASE_GENDATA eq $rqg_phase   ) {
                     # We ask to kill the processgroup of the RQG Worker.
                     kill '-KILL', $pid;
                     $worker_array[$worker_num][WORKER_END]  = time();
                     say("DEBUG: Stopped young RQG worker $worker_num")
                         if Auxiliary::script_debug("T6");
            }
        }
    }
}

our $give_up = 0;
# 0 -- Just go on with work.
# 1 -- Stop all RQG runs, as soon as "silence" reached ask for next job
# 2 -- Stop all RQG runs, maybe a bit cleanup, give a summary and exit.
# 3 -- Stop all RQG runs, no cleanup, no summary and than exit.
#

sub emergency_exit {

    my ($status, $reason) = @_;
    if (defined $reason) {
        say($reason);
    }
    # In case we ever do more in stop_workers and that could fail because of
    # mistakes than $give_up == 3 might be used as signal to ignore the fails.
    $give_up = 3;
    Batch::stop_workers();
    safe_exit ($status);

}

sub check_resources {
# FIXME:
# The routine should return a number which get than used for computing a delay.
# And only after that delay has passed and if other parameters fit starting some additional
# RQG worker should be allowed.
    my $load_status = ResourceControl::report(count_active_workers());
    if      (ResourceControl::LOAD_INCREASE eq $load_status) {
        return STATUS_OK;
    } elsif (ResourceControl::LOAD_KEEP eq $load_status) {
        return STATUS_FAILURE;
    } elsif (ResourceControl::LOAD_DECREASE eq $load_status) {
        # Stop the youngest RQG worker
        my $worker_start  = 0;
        my $worker_number = 0;
        for my $worker_num (1..$workers) {
            next if -1 == $worker_array[$worker_num][WORKER_PID];
            if ($worker_array[$worker_num][WORKER_START] > $worker_start) {
                $worker_start = $worker_array[$worker_num][WORKER_START];
                $worker_number = $worker_num;
            }
        }
        if (0 == $worker_number) {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            emergency_exit($status, "ERROR: ResourceControl::report delivered '$load_status' " .
                           "but no active RQG worker detected. Will ask for emergency_exit.");
        } else {
            # Kill the processgroup of the RQG worker picked.
            Batch::stop_worker($worker_number);
            # Even a kill SIGKILL requires some time especially on some heavy loaded box.
            # So we need to run 'reap_workers' which will free the resources till the number of
            # active workers has decreased.
            # Special case: What if some other worker "passed" away?
            my $max_wait = 30;
            my $end_time = time() + $max_wait;
            # FIXME:
            # The activity of the other RQG workers could be also dangerous.
            while (time() < $end_time and -1 != $worker_array[$worker_number][WORKER_PID]) {
                reap_workers();
                sleep 0.1;
            }
            my $worker_pid = $worker_array[$worker_number][WORKER_PID];
            if (-1 == $worker_pid) {
                say("DEBUG: RQG worker $worker_number has been stopped.");
            } else {
                my $status = STATUS_ENVIRONMENT_FAILURE;
                emergency_exit($status, "ERROR: Batch::check_resources: Waited $max_wait s " .
                    "but the main process $worker_pid of the RQG worker $worker_number has " .
                    "not disappeared like intended. Will ask for emergency_exit.");
            }
            return STATUS_FAILURE;
        }
    } elsif (ResourceControl::LOAD_GIVE_UP eq $load_status) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        emergency_exit($status, "ERROR: ResourceControl::report delivered '$load_status'. " .
                       "Will ask for emergency_exit.");
    } else {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        emergency_exit($status, "INTERNAL ERROR: ResourceControl::report delivered " .
                       "'$load_status' which we do not handle here. Will ask for emergency_exit.");
    }
}


sub reap_workers {

# 1. Reap finished workers so that processes in zombie state disappear.
# 2. Decide depending on the verdict and certain options what to do with maybe existing remainings
#    of the finished test.
# 3. Clean the workdir and vardir of the RQG run
# 4. Return the number of active workers (process is busy/not reaped).

    # https://perldoc.perl.org/perlipc.html#Deferred-Signals-(Safe-Signals)

    say("DEBUG: Entering reap_workers") if Auxiliary::script_debug("T5");

    my $active_workers = 0;
    # TEMPORARY
    if (Auxiliary::script_debug("T3")) {
        say("worker_array_dump at entering reap_workers");
        Batch::worker_array_dump();
    }
    for my $worker_num (1..$Batch::workers) {
        # -1 == no main process of that RQG worker running.
        # Maybe there was never one running or the last running finished and was reaped.
        next if -1 == $worker_array[$worker_num][WORKER_PID];

        my $rqg_appendix  = "/" . $worker_num;
        my $rqg_workdir   = "$workdir" . $rqg_appendix;

        my $worker_process_group = getpgrp($worker_array[$worker_num][WORKER_PID]);
        my $kid = waitpid($worker_array[$worker_num][WORKER_PID], WNOHANG);
        my $exit_status = $? > 0 ? ($? >> 8) : 0;
        if (not defined $kid) {
            say("ALARM: Got not defined waitpid return for RQG worker $worker_num with pid " .
                $worker_array[$worker_num][WORKER_PID]);
        } else {
            say("DEBUG: Got waitpid return $kid for RQG worker $worker_num with pid " .
                $worker_array[$worker_num][WORKER_PID]) if Auxiliary::script_debug("T4");
            my $order_id = $worker_array[$worker_num][WORKER_ORDER_ID];
            if ($kid == $worker_array[$worker_num][WORKER_PID]) {
                # Show/signal that the (main) process of the RQG worker was reaped.
                $worker_array[$worker_num][WORKER_PID] = -1;

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

                my $rqg_vardir    = "$vardir"  . $rqg_appendix;
                my $rqg_log       = "$rqg_workdir" . "/rqg.log";
                my $rqg_arc       = "$rqg_workdir" . "/archive.tgz";


                my $verdict;
                my $iso_ts = isoTimestamp();
                if (-1 != $worker_array[$worker_num][WORKER_END]) {
                    # The RQG worker was 'victim' of a stop with SIGKILL.
                    # So write various information into the RQG run log which the RQG worker was
                    # no more able to do.
                    # Its no problem that this appended stuff will be not in the archive because
                    # there is
                    # - most likely no archive at all
                    # - sometimes an archive harmed by the SIGKILL
                    # - extreme unlikely a complete archive
                    # ==> The stuff gets thrown away in general.
                    $verdict = Verdict::RQG_VERDICT_IGNORE_STOPPED;
                    Batch::append_string_to_file($rqg_log, "# $iso_ts BATCH: Stop the run.\n" .
                                                           "# $iso_ts Verdict: $verdict\n");
                } else {
                    $worker_array[$worker_num][WORKER_END] = time();
                    $verdict       = Verdict::get_rqg_verdict($rqg_workdir);
                }

                $worker_array[$worker_num][WORKER_VERDICT] = $verdict;
                say("DEBUG: Worker [$worker_num] with (process) exit status " .
                    "'$exit_status' and verdict '$verdict' reaped.") if Auxiliary::script_debug("T4");

                # Prevent that some historic + fixed but evil bug can ever happen again.
                if (not defined $verdict_collected) {
                    Carp::cluck("INTERNAL ERROR: verdict_collected is undef.");
                    emergency_exit(STATUS_INTERNAL_ERROR, "ERROR: This must not happen.");
                }
                my $target_prefix_rel = Auxiliary::lfill0($verdict_collected, RQG_NO_LENGTH);
                my $target_prefix     = $workdir . "/" . $target_prefix_rel;
                my $saved_log_rel     = $target_prefix_rel . ".log";
                $worker_array[$worker_num][WORKER_LOG] = $saved_log_rel;
                my $saved_log         = $target_prefix     . ".log";
                my $saved_arc         = $target_prefix     . ".tgz";

                $iso_ts = isoTimestamp();

                # Note:
                # The next two routines get used because the standard failure handling is to make
                # an emergency_exit and not just some simple exit.
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

                if ($verdict eq Verdict::RQG_VERDICT_IGNORE           or
                    $verdict eq Verdict::RQG_VERDICT_IGNORE_STATUS_OK or
                    $verdict eq Verdict::RQG_VERDICT_IGNORE_STOPPED   or
                    $verdict eq Verdict::RQG_VERDICT_IGNORE_BLACKLIST   ) {
                    if (not $discard_logs) {
                        rename_file($rqg_log, $saved_log);
                    } else {
                        $saved_log_rel = "<deleted>";
                    }
                    $verdict_ignore++;
                    if ($verdict eq Verdict::RQG_VERDICT_IGNORE_STOPPED) {
                        $stopped++;
                        # Do nothing with $order_array[$order_id][ORDER_EFFORTS*]
                    } else {
                        # Do nothing with $order_array[$order_id][ORDER_EFFORTS*]
                    }
                } elsif ($verdict eq Verdict::RQG_VERDICT_INTEREST or
                         $verdict eq Verdict::RQG_VERDICT_REPLAY     ) {
                    rename_file($rqg_log, $saved_log);
                    if ($dryrun) {
                        # We fake a RQG run and therefore some archive cannot exist.
                    } else {
                        if (-e $rqg_arc) {
                            rename_file($rqg_arc, $saved_arc);
                        } else {
                        # FIXME: Do this better.
                            say("WARN: The archive '$rqg_arc' does not exist. I hope thats intentional.");
                        }
                    }
                    if ($verdict eq Verdict::RQG_VERDICT_INTEREST) {
                        $verdict_interest++;
                    } else {
                        $verdict_replay++;
                    }
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
                    rename_file($rqg_log, $saved_log);
                    $verdict_init++;
                    say("WARN: Final Verdict Verdict::RQG_VERDICT_INIT in '$saved_log'.");
                    # Maybe touch ORDER_EFFORTS_INVESTED or ORDER_EFFORTS_LEFT
                } else {
                    emergency_exit(STATUS_CRITICAL_FAILURE,
                        "INTERNAL ERROR: Final Verdict '$verdict' is not treated/unknown. " .
                        "This should not happen.");
                }
                $verdict_collected++;
                drop_directory($rqg_vardir);
                drop_directory($rqg_workdir);

            } elsif (-1 == $kid) {
                say("ALARM: RQG worker $worker_num was already reaped.");
                Batch::worker_reset($worker_num);
            } else {
                say("DEBUG: RQG worker $worker_num with pid " .
                    $worker_array[$worker_num][WORKER_PID] . " is running.")
                    if Auxiliary::script_debug("T4");
                $active_workers++;
                # If making simplification report 'replays' before reaping.
                # In Simplifier:
                #    If parent grammar of that run == current parent grammar than load the grammar
                #    used by that 'replayer' and generate some new parent grammar.
                #    Caused by that we get the new parent grammar about ~ 30 till 120 s earlier
                #    in use. The ~ 30 till 120 s depend on current load, are used for archiving
                #    the remainings of the 'replayer'.
                #
                if ($batch_type eq BATCH_TYPE_G_SIMPLIFIER) {
                    my $verdict = Verdict::get_rqg_verdict($rqg_workdir);
                    if ($verdict eq Verdict::RQG_VERDICT_REPLAY) {
                        my $grammar_used   = $worker_array[$worker_num][WORKER_EXTRA1];
                        my $grammar_parent = $worker_array[$worker_num][WORKER_EXTRA2];
                        my $response = Simplifier::report_replay($grammar_used,$grammar_parent);
                        if ($response eq REGISTER_STOP_YOUNG) {
                            stop_worker_young;
                        }
                    }
                }
            }
        }
    } # Now all RQG worker are checked.

    if (Auxiliary::script_debug("T5")) {
        say("worker_array_dump before leaving reap_workers");
        Batch::worker_array_dump();
    }
    say("DEBUG: Leave 'reap_workers' and return (active workers found) : " .
        "$active_workers") if Auxiliary::script_debug("T4");
    return $active_workers;

} # End sub reap_workers


sub check_exit_file {
    my ($exit_file) = @_;
    if (-e $exit_file) {
        $give_up = 2;
        say("INFO: Exit file detected. Stopping all RQG Worker.");
        stop_workers();
    }
}

sub check_runtime_exceeded {
    my ($batch_end_time) = @_;
    if ($batch_end_time  < Time::HiRes::time()) {
        $give_up = 2;
        say("INFO: The maximum total runtime for rqg_batch.pl is exceeded. " .
            "Stopping all RQG Worker.");
        stop_workers();
    }
}

sub check_and_set_batch_type {
    ($batch_type) = @_;
    if (not defined $batch_type) {
        say("INFO: The type of the batch run was not assigned. Assuming the default '" .
            BATCH_TYPE_COMBINATOR . "'.");
        $batch_type = BATCH_TYPE_COMBINATOR;
    } else {
        my $result = Auxiliary::check_value_supported (
                        'type', BATCH_TYPE_ALLOWED_VALUE_LIST, $batch_type);
        if ($result != STATUS_OK) {
            Carp::cluck("ERROR: The batch type '$batch_type' is not supported. Abort");
            safe_exit(STATUS_ENVIRONMENT_FAILURE);
        }
    }
}



# Name of the convenience symlink if symlinking supported by OS
my $symlink = "last_batch_workdir";


# my $script_debug = 0;

sub make_multi_runner_infrastructure {
#
# Purpose
# -------
# Make the infrastructure required by some RQG tool managing a batch of RQG runs.
# This is
# - the workdir
# - the vardir
# - a symlink pointing to the workdir
# of the current batch of RQG runs.
#
# Input values
# ------------
# $workdir    == The workdir of/for historic, current and future runs of RQG batches.
#                The workdir of the *current* RQG run will be created as subdirectory of this.
#                The name of the subdirectory is derived from $runid.
#                undef assigned: Use <current working directory of the process>/storage
# $vardir     == The vardir of/for historic, current and future runs of RQG batches.
#                The vardir of the *current* RQG run will be created as subdirectory of this.
#                The name of the subdirectory is derived from $runid.
#                Something assigned: Just get that
#                undef assigned: Use <workdir of the current batch run>/vardir
#                batch RQG run.
# $run_id     == value to be used for making the *current* workdir/vardir of the RQG batch run
#                unique in order to avoid clashes with historic, parallel or future runs.
#                undef assigned:
#                   Call Auxiliary::get_run_id and get
#                   Number of seconds since the Epoch, 1970-01-01 00:00:00 +0000 (UTC).
#                   This is recommended for users calling the RQG batch run tool manual or
#                   through home grown scripts.
#                something assigned:
#                   Just get that.
#                   The caller, usully some other RQG tool, has to take care that clashes with
#                   historic, parallel or future runs cannot happen.
# $symlink_name == Name of the symlink to be created within the current working directory of the
#                  process and pointing to the workdir of the current RQG batch run.
#
# Return values
# -------------
# success -- $workdir, $vardir for the *current* RQG batch run
#            Being unable to create the symlink does not get valuated as failure.
# failure -- undef
#

    my ($general_workdir, $general_vardir, $run_id, $symlink_name) = @_;

    my $snip_all     = "for batches of RQG runs";
    my $snip_current = "for the current batch of RQG runs";

    $run_id = Auxiliary::get_run_id() if not defined $run_id;

    if (not defined $general_workdir or $general_workdir eq '') {
        $general_workdir = cwd() . '/rqg_workdirs';
        say("INFO: The general workdir $snip_all was not assigned. " .
            "Will use the default '$general_workdir'.");
    } else {
        $general_workdir = Cwd::abs_path($general_workdir);
    }
    if (not -d $general_workdir) {
        # In case there is a plain file with the name '$general_workdir' than we just fail in mkdir.
        if (mkdir $general_workdir) {
            say("DEBUG: The general workdir $snip_all '$general_workdir' " .
                "created.") if Auxiliary::script_debug("B2");
        } else {
            say("ERROR: make_multi_runner_infrastructure : Creating the general workdir " .
                "$snip_all '$general_workdir' failed: $!. Will return undef.");
            return undef;
        }
    }

    $workdir = $general_workdir . "/" . $run_id;
    # Note: In case there is already a directory '$workdir' than we just fail in mkdir.
    if (mkdir $workdir) {
        say("DEBUG: The workdir $snip_current '$workdir' created.") if Auxiliary::script_debug("B2");
    } else {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Creating the workdir $snip_current '$workdir' failed: $!.\n " .
            "This directory must not exist in advance.\n" .
            Auxiliary::exit_status_text($status));
        safe_exit($status);
    }

    if (not defined $general_vardir or $general_vardir eq '') {
        $general_vardir = cwd() . '/rqg_vardirs';
        say("INFO: The general vardir $snip_all was not assigned. " .
            "Will use the default '$general_vardir'.");
    } else {
        $general_vardir = Cwd::abs_path($general_vardir);
    }
    if (not -d $general_vardir) {
        # In case there is a plain file with the name '$general_vardir' than we just fail in mkdir.
        if (mkdir $general_vardir) {
            say("DEBUG: The general vardir $snip_all '$general_vardir' created.") if Auxiliary::script_debug("B2");
        } else {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: make_multi_runner_infrastructure : Creating the general vardir " .
                "$snip_all '$general_vardir' failed: $!. " .
            Auxiliary::exit_status_text($status));
            safe_exit($status);
        }
    }
    $vardir = $general_vardir . "/" . $run_id;
    # Note: In case there is already a directory '$vardir' than we just fail in mkdir.
    if (mkdir $vardir) {
        say("DEBUG: The vardir $snip_current '$vardir' created.") if Auxiliary::script_debug("B2");
    } else {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Creating the vardir $snip_current '$vardir' failed: $!.\n " .
            "This directory must not exist in advance!\n" .
            Auxiliary::exit_status_text($status));
        safe_exit($status);
    }

    # Convenience feature
    # -------------------
    # Make a symlink so that the last workdir used by some tool performing multiple RQG runs like
    #    combinations.pl, bughunt.pl, simplify_grammar.pl
    # is easier found.
    # Creating the symlink might fail on some OS (see perlport) but should not abort our run.
    unlink($symlink_name);
    my $symlink_exists = eval { symlink($workdir, $symlink_name) ; 1 };


    # File for bookkeeping of all the RQG runs somehow finished
    # ---------------------------------------------------------
    $result_file = $workdir . "/result.txt";
    make_file($result_file, undef);
    say("DEBUG: The result (summary) file '$result_file' was created.") if Auxiliary::script_debug("B2");


    # In case we have a combinations vardir without absolute path than ugly things happen:
    # Real life example:
    # vardir assigned to combinations.pl :
    #    comb_storage/1525794903
    # vardir planned by combinations.pl for the RQG test and created if required
    #    comb_storage/1525794903/current_1
    # vardir1 computed by combinations.pl for the first server + assigned to the RQG run
    #    comb_storage/1525794903/current_1
    # The real vardir used by the first server is finally
    #    /work_m/MariaDB/bld_asan/comb_storage/1525794903/current_1/1
    #
    # The solution is to make the path to the vardir absolute (code taken from MTR).
    unless ( $vardir =~ m,^/, or (osWindows() and $vardir =~ m,^[a-z]:[/\\],i) ) {
        $vardir= cwd() . "/" . $vardir;
    }
    unless ( $workdir =~ m,^/, or (osWindows() and $workdir =~ m,^[a-z]:[/\\],i) ) {
        $workdir= cwd() . "/" . $workdir;
    }
    say("INFO: Final workdir  : '$workdir'\n" .
        "INFO: Final vardir   : '$vardir'");
    return $workdir, $vardir;
}


#---------------------------------------------------------------------------------------------------
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
my @order_array = ();
# ORDER_EFFORTS_INVESTED
# Number or sum of runtimes of executions which finished regular
use constant ORDER_EFFORTS_INVESTED => 0;
# ORDER_EFFORTS_LEFT
# Number or sum of runtimes of possible executions in future which maybe have finished regular.
# Example: rqg_batch will not pick some order with ORDER_EFFORTS_LEFT <= 0 for execution.
use constant ORDER_EFFORTS_LEFT     => 1;
# ORDER_PROPERTY1
# - (combinations): The snippet of the RQG command line call to be used.
# - (grammar simplifier): The grammar rule to be attacked.
use constant ORDER_PROPERTY1        => 2;
# ORDER_PROPERTY2
# (grammar simplifier): The simplification like remove "UPDATE ...." which has to be tried.
use constant ORDER_PROPERTY2        => 3;
use constant ORDER_PROPERTY3        => 4;


# Picking some order for generating a job followed by execution means
# - looking into several queues in some deterministic order
# - pick the first element in case there is one, otherwise look into the next queue or similar
# - an element picked gets removed
#
# @try_run_queue
# --------------
# Queue containing orders (-> order_id) which have in the moment the following state
# They are
# - after being picked from some queue, being valid, a job was generated and given into execution
# - before it was detected that the execution ended etc.
#
# @try_first_queue
# ----------------
# Queue containing orders (-> order_id) which should be executed before any order from some other
# queue is picked.
# Usage:
# - In case the execution of some order Y had to be stopped because of technical reasons than
#   repeating that should be favoured
#   - totally in case we run combinations because we want some dense area of coverage at end.
#     In addition being forced to end could come at any arbitrary point of time or progress.
#     So we need to take care immediate and should not delay that.
#   - partially in case we run grammar simplification because we try the simplification ordered
#     from the in average most efficient steps to the less efficient steps.  ???
# - In case the execution of some order Y (simplification Y applied to good grammar G replayed
#   but was a "too late replayer" than this simplification Y could be not applied.
#   But from the candidates we have in the queues
#       @try_queue, @try_later_queue maybe even @try_over_queue
#   we do not know if they are capable to replay at all and either we
#   - have them already tried with some efforts invested but no replay
#   - have them not tried at all
#   and so the order Y gets appended to @try_first_queue.
#   Note:
#   We pick the first order from @try_first_queue , if there is one, anyway because that is
#   in average even better.
my @try_first_queue;
#
# @try_queue
# ----------
# Queue containing orders (-> order_id) which should be executed if @try_first_queue is empty
# and before any order from some queue like @try_later_queue or @try_over_queue is picked.
# Usage:
# In case orders get generated than they get appended to @try_queue.
my @try_queue;
#
# @try_later_queue
# ----------------
# If ever used than in grammar simplification only.
# Roughly:
# We have already some efforts invested but had no replay.
# There are some efforts to be invested left over.
# It seems to be better to generate more orders and add them to @try_queue than to run the
# orders with left over efforts soon again.
my @try_later_queue;
#
# @try_over_queue
# ---------------
# Usage:
# combinations and grammar simplification
#   Orders where left over efforts <= 0 was reached get appended to @try_over_queue.
#   In case of
#       @try_first_queue and @try_queue empty
#       and all possible combinations/simplifications were already generated
#       and no other limitation (example: maxruntime) was exceeded
#   the content of @try_over_queue gets sorted, the left over efforts of the orders get increased
#   and all these orders get moved to @try_queue. Direct after that operation @try_over_queue
#   is empty.
my @try_over_queue;
#
# @try_never_queue
# ----------------
# Usage:
# - combinations
#   Not yet decided.
# - grammar simplification
#   Place orders which are no more capable to bring any progress here.
#   == Never run a job based on this in future.
my @try_never_queue;
#
# @try_run_queue
# --------------
# The jobs which are in the moment running
my @try_run_queue;

sub dump_queues {
    say("DEBUG: \@try_run_queue   : " . join (' ', @try_run_queue  ));
    say("DEBUG: \@try_first_queue : " . join (' ', @try_first_queue));
    say("DEBUG: \@try_queue       : " . join (' ', @try_queue      ));
    say("DEBUG: \@try_later_queue : " . join (' ', @try_later_queue));
    say("DEBUG: \@try_over_queue  : " . join (' ', @try_over_queue ));
    say("DEBUG: \@try_never_queue : " . join (' ', @try_never_queue));
}
sub init_queues {
    @try_run_queue   = ();
    @try_first_queue = ();
    @try_queue       = ();
    @try_later_queue = ();
    @try_over_queue  = ();
    @try_never_queue = ();
}
sub check_queues {
    my %check_hash;
    for my $order_id (@try_run_queue, @try_first_queue, @try_queue, @try_later_queue,
                @try_over_queue, @try_never_queue)                              {
        if (exists($check_hash{$order_id})) {
            Carp:cluck("INTERNAL ERROR: The Order Id occurs more than once in the queues.");
            dump_queues();
            my $status = STATUS_INTERNAL_ERROR;
            emergency_exit($status);
        } else {
            $check_hash{$order_id} = 1;
        }
    }
    say("DEBUG: The queues are consistent.") if Auxiliary::script_debug("T6");
}
sub add_id_to_run_queue {
    my ($order_id) = @_;
    if (not defined $order_id) {
        Carp::cluck("INTERNAL ERROR: order_id is undef.");
        my $status = STATUS_INTERNAL_ERROR;
        emergency_exit($status);
    }
    push @try_run_queue, $order_id;
}
sub remove_id_from_run_queue {
    my ($order_id) = @_;
    if (not defined $order_id) {
        Carp::cluck("INTERNAL ERROR: order_id is undef.");
        my $status = STATUS_INTERNAL_ERROR;
        emergency_exit($status);
    }
    my @replace_queue = ();
    my $have_removed  = 0;
    foreach my $id (@try_run_queue) {
        if ($order_id != $id) {
           push @replace_queue, $id;
        } else {
            $have_removed = 1;
        }
    }
    if (not $have_removed) {
        Carp::cluck("INTERNAL ERROR: Order id $order_id not found in \@try_run_queue.");
        dump_queues();
        my $status = STATUS_INTERNAL_ERROR;
        emergency_exit($status);
    }
    @try_run_queue = @replace_queue;
}
sub known_orders_waiting {
# Purpose:
# Detect the following state of grammar simplification.
# 0. All possible orders were generated ($out_of_ideas==1), which is not checked here.
# 1. None of the orders is
#    - currently in trial/running                  --> @try_run_queue
#    - waiting for trial/running                   --> @try_first_queue, @try_queue
#    - delayed candidate for repetition of the run --> @try_later_queue
    my @join_array = (@try_run_queue, @try_first_queue, @try_queue, @try_later_queue);
    return scalar @join_array;
}


sub get_order {

    my $order_id;
    # Sort @try_first_queue numerically ascending because in average the orders with the lower
    # id's will remove more if having success at all.
    @try_first_queue = sort {$a <=> $b} @try_first_queue;
    $order_id = shift @try_first_queue;
    if (defined $order_id) {
        say("DEBUG: Order $order_id picked from \@try_first_queue.")
            if Auxiliary::script_debug("B5");
    } else {
        # @try_first_queue was empty.
        $order_id = shift @try_queue;
        if (defined $order_id) {
            say("DEBUG: Order $order_id picked from \@try_queue.")
                if Auxiliary::script_debug("B5");
        } else {
            # @try_queue was empty too.
            say("DEBUG: \@try_first_queue and \@try_queue are empty.")
                if Auxiliary::script_debug("B5");
            return undef;
        }
    }
    return $order_id;
}


sub add_order {

    my ($order_id) = @_;
    # FIXME: Check the input

    push @try_queue, $order_id;
}

sub add_to_try_over {
    my ($order_id) = @_;
    if (not defined $order_id) {
        Carp::cluck("INTERNAL ERROR: order_id is undef.");
        my $status = STATUS_INTERNAL_ERROR;
        emergency_exit($status);
    }

    push @try_over_queue, $order_id;
}
sub add_to_try_never {
    my ($order_id) = @_;
    if (not defined $order_id) {
        Carp::cluck("INTERNAL ERROR: order_id is undef.");
        my $status = STATUS_INTERNAL_ERROR;
        emergency_exit($status);
    }
    push @try_never_queue, $order_id;
}
sub add_to_try_first {
    my ($order_id) = @_;
    if (not defined $order_id) {
        Carp::cluck("INTERNAL ERROR: order_id is undef.");
        my $status = STATUS_INTERNAL_ERROR;
        emergency_exit($status);
    }

    push @try_first_queue, $order_id;
}

# FIXME: Implement rather in Simplifier because nothing else needs it
# Adaptive FIFO
#
# init          no of elements n, value
#               Create list with that number of elements precharged with value
# store_value   value
#               Throw top element of list away, append value.
# get_value     algorithm
#               Return a value providing a >= 85 % percentil according to algorithm.
#               1 -- maximum value from list
#                    Bigger n leads to more save and stable values but is questionable
#                    because of over all longer timespan (between first and last entry).
#               2 -- > 85% percentil with some gauss bell curve assumed
#                    I assume
#                    - in the first phase (when many elements have precharged value)
#                      faster starting to have an impact than 1
#                    - later more stable + smooth than 1
#                    but more complex.
#               It is to be expected and in experiments already revealed that neither
#               - m replay runs with the same effective grammars and settings
#                 --> elapsed RQG runtime
#               - n replay runs with increasing simplified grammars
#                 --> elapsed rqg_batch.pl runtime or rqg.pl runtime of "winner"
#               have a bell curve regarding the elapsed runtime.
#
#

# Certain routines which are based on routines with the same name and located in Auxiliary.pm.
# --------------------------------------------------------------------------------------------
# The important diff is that we perform an emergency_exit in order to minimize possible
# future trouble on the testing box like
# - space consumed in general vardir (usually tmpfs of small size)
# - further running MariaDB server which consume ressources and block ports etc.
#
sub copy_file {
# Auxiliary::copy_file makes all checks and returns
# STATUS_OK or STATUS_FAILURE

    my ($source_file, $target_file) = @_;
    if (Auxiliary::copy_file($source_file, $target_file)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Copy operation failed. Will ask for emergency exit." .
            Auxiliary::exit_status_text($status));
        Batch::emergency_exit($status);
    }
}

sub rename_file {
# Auxiliary::rename_file makes all checks and returns
# STATUS_OK or STATUS_FAILURE

    my ($source_file, $target_file) = @_;
    if (Auxiliary::rename_file($source_file, $target_file)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Rename operation failed. Will ask for emergency exit." .
            Auxiliary::exit_status_text($status));
        Batch::emergency_exit($status);
    }
}

sub make_file {
# Auxiliary::make_file makes all checks and returns
# STATUS_OK or STATUS_FAILURE

    my ($file_to_create, $string) = @_;
    if (Auxiliary::make_file($file_to_create, $string)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: File create and write operation failed. Will ask for emergency exit." .
            Auxiliary::exit_status_text($status));
        Batch::emergency_exit($status);
    }
}

sub append_string_to_file {
# Auxiliary::append_string_to_file makes all checks and returns
# STATUS_OK or STATUS_FAILURE

    my ($file, $string) = @_;
    if (Auxiliary::append_string_to_file($file, $string)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Write to file operation failed. Will ask for emergency exit." .
            Auxiliary::exit_status_text($status));
        Batch::emergency_exit($status);
    }
}

sub write_result {
    my ($line) = @_;
    if (not defined $line) {
        Carp::cluck("INTERNAL ERROR: line is undef.");
        my $status = STATUS_INTERNAL_ERROR;
        Batch::emergency_exit($status);
    }
    if (not defined $result_file) {
        Carp::cluck("INTERNAL ERROR: result_file is undef.");
        my $status = STATUS_INTERNAL_ERROR;
        Batch::emergency_exit($status);
    }
    Batch::append_string_to_file($result_file, $line);
}

sub get_string_after_pattern {
# Auxiliary::get_string_after_pattern makes all checks and returns
# - defined value != '' if string found
# - defined value == '' if string not found
# - undef if file does not exist

    my ($file, $string) = @_;
    my $value = Auxiliary::get_string_after_pattern($file, $string);
    if (not defined $value) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Auxiliary::get_string_after_pattern failed. Will ask for emergency exit." .
            Auxiliary::exit_status_text($status));
        Batch::emergency_exit($status);
    } elsif ('' eq $value) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Auxiliary::get_string_after_pattern returned ''. Will ask for emergency exit." .
            Auxiliary::exit_status_text($status));
        Batch::emergency_exit($status);
    } else {
        return $value;
    }
}


#==========================================================

my $stop_on_replay;
sub check_and_set_stop_on_replay {
    ($stop_on_replay) = @_;
    if (not defined $stop_on_replay) {
        $stop_on_replay = 0;
    } else {
        $stop_on_replay = 1
    }
}

sub process_finished_runs {
    for my $worker_num (1..$workers) {
        my $verdict  = $worker_array[$worker_num][WORKER_VERDICT];
        my $order_id = $worker_array[$worker_num][WORKER_ORDER_ID];
        if (defined $verdict) {
            # VERDICT_VALUE | State + reaction
            # --------------+-------------------------------------------------------------------
            #     defined   | State: Process of RQG Worker just reaped + verdict + save ...
            #               | Register result, react on result + wipe worker_array entry
            # not defined   | RQG Worker is active or inactive
            #               | Nothing to do
            my ($status,$action);
            my @result_record = (
                    $worker_array[$worker_num][WORKER_ORDER_ID],
                    $worker_array[$worker_num][WORKER_VERDICT],
                    $worker_array[$worker_num][WORKER_LOG],
                    $worker_array[$worker_num][WORKER_END]
                        - $worker_array[$worker_num][WORKER_START],
                    $worker_array[$worker_num][WORKER_EXTRA1],
                    $worker_array[$worker_num][WORKER_EXTRA2],
                    $worker_array[$worker_num][WORKER_EXTRA3]
            );
            if      ($batch_type eq BATCH_TYPE_COMBINATOR) {
                ($status,$action) = Combinator::register_result(@result_record);
            } elsif ($batch_type eq BATCH_TYPE_G_SIMPLIFIER) {
                ($status,$action) = Simplifier::register_result(@result_record);
            } else {
                emergency_exit(STATUS_CRITICAL_FAILURE,
                    "INTERNAL ERROR: The batch type '$batch_type' is unknown. ");
            }

            if ($status != STATUS_OK) {
                emergency_exit($status,
                               "ERROR: register_result met a failure and asked to abort. " .
                               Auxiliary::exit_status_text($status));
            } elsif ( not defined $action or $action eq '' ) {
                emergency_exit($status,
                               "ERROR: register_result returned an action in (undef, ''). " .
                               Auxiliary::exit_status_text($status));
            } else {
                # Combinator and Simplifier could tell what to do next.
                if      ($action eq REGISTER_GO_ON)    {
                    # All is ok. Just go on is required.
                } elsif ($action eq REGISTER_STOP_ALL) {
                    stop_workers();
                    if (1 > $give_up) {
                        $give_up = 1;
                    }
                } elsif ($action eq REGISTER_STOP_YOUNG) {
                    stop_worker_young();
                    if (1 > $give_up) {
                        $give_up = 1;
                    }
                } elsif ($action eq REGISTER_END)        {
                    stop_workers();
                    if (2 > $give_up) {
                        $give_up = 2;
                    }
                } else {
                    $status = STATUS_INTERNAL_ERROR;
                    $give_up = 3;
                    emergency_exit($status,
                                   "INTERNAL ERROR: register_result returned the unknown " .
                                   "action '$action'. " . Auxiliary::exit_status_text($status));
                }
            }
            worker_reset($worker_num);
            if ($stop_on_replay and $verdict eq Verdict::RQG_VERDICT_REPLAY) {
                say("INFO: OrderID $order_id achieved the verdict '$verdict' and stop_on_replay " .
                    "is set. Giving up.");
                stop_workers();
                if (2 > $give_up) {
                    $give_up = 2;
                }
            }
        }
    }
}


1;

