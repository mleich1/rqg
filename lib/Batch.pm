#  Copyright (c) 2018, 2022 MariaDB Corporation Ab.
#  Copyright (c) 2023, 2025 MariaDB plc
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
#   lib/GenTest_e.pm, lib/DBServer_e/DBServer.pm, maybe more.
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

use GenTest_e::Constants;
use GenTest_e;
use File::Copy;
use Cwd;
use Auxiliary;
use Local;
use Verdict;
use ResourceControl;
use POSIX qw( WNOHANG );

# Constants serving for more convenient printing of results in table layout
# -------------------------------------------------------------------------
use constant RQG_NO_TITLE        => 'Number';
use constant RQG_NO_LENGTH       => 6;              # Maximum is 999999
use constant RQG_WNO_TITLE       => 'Worker';
use constant RQG_WNO_LENGTH      => 6;              # practical Maximum is 1000

use constant RQG_LOG_TITLE       => 'RQG log   ';   # 999999.log or <deleted>
use constant RQG_LOG_LENGTH      => 10;             # 999999.log or <deleted>

use constant RQG_ORDERID_TITLE   => 'OrderId';
use constant RQG_ORDERID_LENGTH  => 7;              # Maximum is 9999999/Title

use constant RQG_RUNTIME_TITLE   => 'Runtime';
use constant RQG_RUNTIME_LENGTH  => 7;

use constant RQG_INFO_TITLE      => 'RQG Status - Extra information';
use constant RQG_INFO_LENGTH     => 38;
                                 # 'STATUS_ENVIRONMENT_FAILURE--MDEV-22222'
use constant RQG_CALL_SNIP_TITLE => 'Snip of the RQG call run by RQG Worker';

# Maximum number of RQG runs started
use constant MAX_BATCH_STARTS    => 999999;

# get_job
# - implemented in Combinator/Simplifier/...
# - called by rqg_batch.pl
# returns a record with the following structure
use constant JOB_CL_SNIP    => 0;  # Call line snip
use constant JOB_ORDER_ID   => 1;  # Orderid == index from order_array which gets
                                   #             managed by Combinator/Simplifier/...
use constant JOB_MEMO1      => 2;  # undef or Child  grammar or Child  rvt_snip
use constant JOB_MEMO2      => 3;  # undef or Parent grammar or Parent rvt_snip
use constant JOB_MEMO3      => 4;  # undef or Adapted duration

my $max_rqg_runtime = 5400;
sub set_max_rqg_runtime {
    $max_rqg_runtime = @_;
    # FIXME: Check that it is an int > 0.
}

# $give_up == Some general prospect for the future of the rqg_batch.pl run.
# -------------------------------------------------------------------------
our $give_up = 0;
# 0 -- Just go on with work.
# 1 -- Stop all RQG runs, as soon as "silence" reached set $give_up = 0 and ask for next job.
# 2 -- Stop all RQG runs, maybe a bit cleanup, give a short summary and exit.
# 3 -- Stop all RQG runs, no cleanup, no summary and than exit.
# Usage:
# Especially $give_up > 2 means that actions which might fail or last long
# should be avoided.
#

our $workdir;
our $vardir;
my  $result_file;
my  $setup_file;

# Counter for statistics
# ----------------------
our $verdict_init          = 0;
our $verdict_replay        = 0;
our $verdict_interest      = 0;
our $verdict_ignore        = 0;
our $stopped               = 0;
our $verdict_collected     = 0;

# There is per RQG run some verdict and a more or less informative reason for that.
# Examples:
# a) Verdict replay and "TBR-1"
# b) Verdict ignore unwanted and "MDEV-1234"
# c) Verdict ignore_status_ok and "<undef*>"
our %extra_info_hash;
sub update_extra_info_hash {
    my ($extra_info) = @_;
    # say("DEBUG: update_extra_info_hash with '" . $extra_info . "'");
    if (not exists $extra_info_hash{$extra_info}) {
        $extra_info_hash{$extra_info} = 1;
    } else {
        $extra_info_hash{$extra_info}++;
    }
}
sub get_extra_info_hash {
# Call it like
# my $fat_string = get_extra_info_hash("DEBUG:");
# say($fat_string);
# Current use is in the statistics at end of the rqg_batch.pl run.
#
    my ($prefix) = @_;
    my @extra_info_list = sort keys %extra_info_hash;
    my $fat_message =   $prefix . " Frequency -- extra_info\n";
    foreach my $extra_info (@extra_info_list) {
        $fat_message .= $prefix . " " . Basics::lfill($extra_info_hash{$extra_info}, 9) .
                        " -- '" . $extra_info . "'\n";
    }
    return $fat_message;
}


my $discard_logs;
sub check_and_set_discard_logs {
    ($discard_logs) = @_;
    say("INFO: discard_logs set to $discard_logs.");
}
# my $dryrun;
our $dryrun;
sub check_and_set_dryrun {
    ($dryrun) = @_;
    if (defined $dryrun) {
        my $result = Auxiliary::check_value_supported (
                         'dryrun', Verdict::RQG_VERDICT_ALLOWED_VALUE_LIST, $dryrun);
        if ($result != STATUS_OK) {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: 'dryrun': Non supported value assigned or assignment forgotten and some " .
                "wrong value like '--dryrun=13' got. " . Basics::exit_status_text($status));
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
# 2. Make the RQG run (usually rqg.pl) via Perl 'system'.
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
# - not full and even not half static like @order_array content
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
#     + comparison if required + archiving + ...) which should ensure that roughly all simplified
#     grammars which are capable to replay have replayed.
#     So in some sense this runtime defines what some sufficient long run is and the size changes
#     during the simplification process.
use constant WORKER_EXTRA1      =>  3; # child grammar == grammar used if Simplifier
use constant WORKER_EXTRA2      =>  4; # parent grammar if Simplifier
use constant WORKER_EXTRA3      =>  5; # adapted duration if Simplifier
use constant WORKER_END         =>  6;
use constant WORKER_VERDICT     =>  7;
use constant WORKER_LOG         =>  8;
use constant WORKER_STOP_REASON =>  9; # in case the run was stopped than the reason
use constant WORKER_V_INFO      => 10; # Additional info around the verdict
use constant WORKER_COMMAND     => 11; # Essentials of RQG call
# In case a 'stop_worker' had to be performed because of
# - STOP_REASON_WORK_FLOW
#   Simplifier/Combinator has given REGISTER_END
#       == All configured work done.
#   Simplifier has given REGISTER_STOP_ALL
#       == End of actual simplification phase reached.
#   Simplifier has given REGISTER_STOP_YOUNG
#       == Stopping some RQG worker (and start new ones) would give an optimization.
use constant STOP_REASON_WORK_FLOW   => 'work flow';
#
# - STOP_REASON_RESOURCE
#   The resource control reported LOAD_DECREASE.
#       == Stopping a RQG worker is recommended.
use constant STOP_REASON_RESOURCE    => 'resource';
#
# - STOP_REASON_BATCH_LIMIT
#   rqg_batch runtime exceeded or similar
#       == Stopping all RQG worker is recommended.
use constant STOP_REASON_BATCH_LIMIT => 'batch_limit';
#
# - STOP_REASON_RQG_LIMIT
#   max_rqg_runtime was exceeded
#       == Stopping of that RQG worker is recommended.
use constant STOP_REASON_RQG_LIMIT   => 'rqg_limit';
# than WORKER_STOP_REASON will be set and some corresponding entry will be later written
# into the log of the RQG worker. The main reason doing this is to have more information about
# what happened at rqg_batch.pl runtime. And this is required for discovering defects in the
# load control mechanism and further optimization of grammar simplification process.
# Please note that there are two scenarios where WORKER_STOP_REASON will stay undef
# - no stop of that RQG worker at all
# - stop of all RQG workers and abort of the rqg_batch.pl run because too serious trouble ahead.
#   The logics is:
#   If WORKER_STOP_REASON is defined than write an entry into the log of that RQG worker.
#   In case we want finally an abort than this abort has absolute priority.
#   Any delay or fail of abort because of trouble when writing the entry is not acceptable.
#   So WORKER_STOP_REASON needs to be undef.
#

our @free_worker_queue = ();
# @free_worker_queue is run as a FIFO.
# sub worker_reset    - Add number of worker to right end.
#                       Creating the worker management structure and also the final processing
#                       of the result of some worker call worker_reset.
# sub get_free_worker - Shift number of worker from left end.
# Advantage of the FIFO:
# Maximize the delay till some Worker and hereby certain ports get used again.
# The goal is to prevent that a starting DB server meets a port claimed to be in use.
# The latter seems to be caused by
#   too limited number of ports - heavy use of ports per many parallel RQGs -
#   maybe missing disconnects - excessive CPU load - too fast reuse of ports
# 2021-08 The already small fraction of such problems disappeared after implementation.
#

# Whenever lib/Batch.pm calls Combinator/Simplifier::register_result than that routine will
# return a string how to proceed.
# The constants are for that.
use constant REGISTER_GO_ON        => 'register_ok';
     # Expected reaction:
     # Just go on == Ask for the next job when having free resources except status was != STATUS_OK.
     # No remarkable change in the work flow. The next tests are roughly like the previous one.
use constant REGISTER_STOP_ALL     => 'register_stop_all';
     # Expected reaction:
     # Stop all active RQG runs and ask for the next job when having free resources.
     # Use case:
     # The result got made all ongoing RQG runs obsolete and so they should be aborted.
     # Example:
     # Bugreplay where we
     # - need to replay some desired outcome only once
     # - want to go on with free resources and something different as soon as possible.
use constant REGISTER_STOP_YOUNG   => 'register_stop_young';
     # Expected reaction:
     # Stop all active RQG runs which are in phase init , start or gentest.
     # Use case:
     # The result got made all ongoing RQG runs obsolete and so they should be aborted.
use constant REGISTER_SOME_STOPPED => 'register_some_stopped';
use constant REGISTER_END          => 'register_end';


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
use constant BATCH_TYPE_RQG_SIMPLIFIER  => 'RQG_Simplifier';
# Some more simplifier types are at least thinkable but its in the moment unclear if they would
# fit to the general capabilities of rqg_batch.pl.
#
use constant BATCH_TYPE_ALLOWED_VALUE_LIST => [
    # BATCH_TYPE_COMBINATOR, BATCH_TYPE_VARIATOR, BATCH_TYPE_MASKING, BATCH_TYPE_RQG_SIMPLIFIER];
      BATCH_TYPE_COMBINATOR,                                          BATCH_TYPE_RQG_SIMPLIFIER];


our $workers_max;
our $workers_mid;
our $workers_min;
sub set_workers_range {
    # Needed at begin of rqg_batch run
    ($workers_max, my $workers_mid_got, my $workers_min_got) = @_;
    for my $worker_num (1..$workers_max) {
        worker_reset($worker_num);
    }
    $workers_mid = $workers_mid_got;
    $workers_mid = $workers_max if $workers_mid > $workers_max;
    $workers_min = $workers_min_got;
    $workers_min = $workers_max if $workers_min > $workers_max;
    say("INFO: Load range for concurrent RQGs set : workers_max ($workers_max), " .
        "workers_mid ($workers_mid_got -> $workers_mid), " .
        "workers_min ($workers_min_got -> $workers_min)");
}
sub decrease_workers_range {
    # Needed after getting LOAD_DECREASE, reducing the load till all is ok
    $workers_mid = count_active_workers();
    # Experimental: Old value was 0.75
    my $max_min = int(0.85 * $workers_mid);
    if ($workers_min > $max_min) {
        $workers_min = $max_min;
    }
    say("DEBUG: Load range reduction : workers_max ($workers_max), workers_mid ($workers_mid), " .
        "workers_min ($workers_min)") if Auxiliary::script_debug("T6");
}
sub raise_workers_range {
    $workers_mid++ if $workers_mid < $workers_max;
    my $max_min = int(0.75 * $workers_mid);
    if ($workers_min < $max_min) {
        $workers_min = $max_min;
    }
    say("DEBUG: Load range raise : workers_max ($workers_max), workers_mid ($workers_mid), " .
        "workers_min ($workers_min)") if Auxiliary::script_debug("T6");
}

sub worker_reset {
    my ($worker_num) = @_;

    $worker_array[$worker_num][WORKER_PID]         = -1;
    $worker_array[$worker_num][WORKER_START]       = -1;
    $worker_array[$worker_num][WORKER_END]         = -1;
    $worker_array[$worker_num][WORKER_ORDER_ID]    = -1;
    $worker_array[$worker_num][WORKER_EXTRA1]      = undef;
    $worker_array[$worker_num][WORKER_EXTRA2]      = undef;
    $worker_array[$worker_num][WORKER_EXTRA3]      = undef;
    $worker_array[$worker_num][WORKER_VERDICT]     = undef;
    $worker_array[$worker_num][WORKER_LOG]         = undef;
    $worker_array[$worker_num][WORKER_STOP_REASON] = undef;
    $worker_array[$worker_num][WORKER_V_INFO]      = undef;
    $worker_array[$worker_num][WORKER_COMMAND]     = undef;

    push @free_worker_queue, $worker_num;
}

sub get_free_worker {
    my $free_worker = shift @free_worker_queue;
    if (defined $free_worker) {
        say("DEBUG: Worker[$free_worker] picked. \@free_worker_queue: " .
        join("-", @free_worker_queue)) if Auxiliary::script_debug("T6");
        # -1 == $worker_array[$free_worker][WORKER_PID]
        # --> No main process of the RQG worker known in bookkeeping.
        #     Either never in use or already reaped.
        # not defined $worker_array[$worker_num][WORKER_VERDICT] in addition
        # --> The main process of the RQG worker was just reaped
        #     and the processing of the result was already done.
        if (-1 == $worker_array[$free_worker][WORKER_PID] and
            not defined $worker_array[$free_worker][WORKER_VERDICT]) {
            return $free_worker;
        } else {
            say("ERROR: $free_worker was picked from \@free_worker_queue but \@worker_array " .
                "contains pid: " . $worker_array[$free_worker][WORKER_PID] . " verdict: "     .
                $worker_array[$free_worker][WORKER_VERDICT]);
            Carp::cluck("INTERNAL ERROR: Inconsistency betweeen \@free_worker_queue and "     .
                        "\@worker_array. Abort.");
            my $status = STATUS_INTERNAL_ERROR;
            emergency_exit($status);
        }
    } else {
        say("DEBUG: No free worker found.") if Auxiliary::script_debug("T6");
        return $free_worker;
    }
}

sub count_free_workers {
    return scalar @free_worker_queue;
}


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
# reap_workers returns the number of active RQG Workers too but
# - more exact because it is based on some just performed bookkeeping
# - needs significant more runtime
#
    my $active_workers = 0;
    for my $worker_num (1..$workers_max) {
        $active_workers++ if $worker_array[$worker_num][WORKER_PID] != -1;
    }
    return $active_workers;
}

sub count_active_not_stopped_workers {
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
    for my $worker_num (1..$workers_max) {
        # Omit the not started at all.
        next if -1 == $worker_array[$worker_num][WORKER_PID];
        # Omit the started but stopped (SIGKILL might be not yet finished).
        next if defined $worker_array[$worker_num][WORKER_STOP_REASON];
        $active_workers++;
    }
    return $active_workers;
}

sub worker_array_dump {
use constant WORKER_ID_LENGTH    =>  3;
use constant WORKER_PID_LENGTH   =>  6;
use constant WORKER_START_LENGTH => 10;
use constant WORKER_ORDER_LENGTH =>  8;
    my $message = "worker_array_dump begin --------\n" .
                  "id  -- pid    -- job_start  -- job_end    -- order_id -- " .
                  "extra1  -- extra2  -- extra3  -- verdict -- log\n";
    for my $worker_num (1..$workers_max) {
        # Omit inactive workers.
        next if -1 == $worker_array[$worker_num][WORKER_START];
        $message = $message . Basics::lfill($worker_num, WORKER_ID_LENGTH) .
            " -- " . Basics::lfill($worker_array[$worker_num][WORKER_PID],
                                                                 WORKER_PID_LENGTH)   .
            " -- " . Basics::lfill($worker_array[$worker_num][WORKER_START],
                                                                 WORKER_START_LENGTH) .
            " -- " . Basics::lfill($worker_array[$worker_num][WORKER_END],
                                                                 WORKER_START_LENGTH) .
            " -- " . Basics::lfill($worker_array[$worker_num][WORKER_ORDER_ID],
                                                                 WORKER_ORDER_LENGTH) ;
        foreach my $index (WORKER_EXTRA1, WORKER_EXTRA2, WORKER_EXTRA3, WORKER_VERDICT,
                           WORKER_LOG, WORKER_COMMAND) {
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


# stop_worker* routines
# ---------------------
# Important:
# These routines
# - send KILL to the processgroups of the RQG workers picked
# - maybe set $worker_array[$worker_num][WORKER_STOP_REASON]
# but they do NOT wait for any impact!
sub stop_worker {
    my ($worker_num, $stop_reason) = @_;
    my $pid = $worker_array[$worker_num][WORKER_PID];
    if (defined $pid and -1 != $pid) {
        # Per last update of bookkeeping the RQG Worker was alive.
        # We ask to kill the processgroup of the RQG Worker.
        kill '-9', $pid;
        if ($give_up < 3) {
            $worker_array[$worker_num][WORKER_STOP_REASON] = $stop_reason;
            my $order_id = $worker_array[$worker_num][WORKER_ORDER_ID];
            Carp::cluck("DEBUG: Tried to stop RQG worker $worker_num with orderid $order_id because " .
                        "of ->$stop_reason<-.") if Auxiliary::script_debug("T6");
        }
    }
}

sub stop_workers {
    my ($stop_reason) = @_;
    for my $worker_num (1..$workers_max) {
        stop_worker($worker_num, $stop_reason);
    }
}

# Several stop_worker variants used by the simplifier for optimization
#
# report_replay (RQG runner has not yet finished, archive if enabled has not yet arrived)
# 1. Assuming that a winner was found
# 1.1 stop all worker in a phase up till including some assigned early phase
# 1.2 stop all worker with same order_id except verdict in (replay, interest) via
#     stop_worker_on_order_except and mark the corresponding order_id invalid
# 1.3 stop all worker with some order_id affecting some now disappeared rule except
#     verdict in (interest) via stop_worker_on_order_except + stop_worker_on_order_replayer
#     and mark the corresponding order_id invalid
# 2. Something else showed up
#    Do nothing
#
# register_result (RQG runner has finished, archive if enabled has arrived)
# 1. Assuming that a winner was found
# 1.1 stop all worker in a phase up till including some assigned early phase
# 1.2 stop all worker with same order_id except verdict in (interest) via
#     stop_worker_on_order_except + stop_worker_on_order_replayer
#     and mark the corresponding order_id invalid
# 1.3 stop all worker with some order_id affecting some now disappeared rule except
#     verdict in (interest) via stop_worker_on_order_except + stop_worker_on_order_replayer
#     and mark the corresponding order_id invalid
# 2. Assuming that something else showed up
# 2.1 stop all worker with some order_id and actual efforts invested >= $trials
#     except verdict in (replay,interest) via stop_worker_on_order_except
#     and ???drop the order_id???
#
# Use cases
# 1. Register_result detects a first replayer --> grammar reload -> save stuff -> add_to_try_never
#    All workers running a job based on that order_id should be stopped except interest was reached.
#    stop all worker in a phase up till including some assigned phase
# 2. Register_result detects a finished job being not a replayer + actual efforts invested >= $trials
#    All workers running a job based on that order_id should be stopped. ????

sub stop_worker_on_order_except {
    my ($order_id) = @_;

    check_order_id($order_id);
    Carp::cluck("DEBUG: Try to stop nonreplaying RQG worker with orderid $order_id begin.")
        if Auxiliary::script_debug("T6");
    my $stop_count = 0;
    for my $worker_num (1..$workers_max) {
        # Omit not running workers
        next if -1 == $worker_array[$worker_num][WORKER_PID];
        # Omit workers with other order_id
        next if $order_id != $worker_array[$worker_num][WORKER_ORDER_ID];
        # Omit any worker which replayed and is maybe during archiving
        next if defined $worker_array[$worker_num][WORKER_VERDICT] and
                Verdict::RQG_VERDICT_REPLAY eq $worker_array[$worker_num][WORKER_VERDICT];
        # Omit any worker which reached something of interest and is maybe during archiving.
        next if defined $worker_array[$worker_num][WORKER_VERDICT] and
                Verdict::RQG_VERDICT_INTEREST eq $worker_array[$worker_num][WORKER_VERDICT];
        stop_worker($worker_num, STOP_REASON_WORK_FLOW . ' 1');
        $stop_count++;
    }
    say("DEBUG: Batch::stop_worker_on_order_except: $stop_count RQG worker running with orderid " .
        "$order_id stopped.") if Auxiliary::script_debug("T6");
    return $stop_count;
}

sub stop_worker_on_order_replayer {
    # The use is safe (mean no risk to stop some valuable RQG worker) in
    # - Simplifier::register_result all time because there the valuable worker has finished.
    # - Simplifier::report_replay if omitting the order_id of the replayer inspected.
    my ($order_id) = @_;

    check_order_id($order_id);
    Carp::cluck("DEBUG: Try to stop replaying RQG worker with orderid $order_id begin.")
        if Auxiliary::script_debug("T6");
    my $stop_count = 0;
    for my $worker_num (1..$workers_max) {
        # Omit not running workers
        next if -1 == $worker_array[$worker_num][WORKER_PID];
        # Omit workers with other order_id
        next if $order_id != $worker_array[$worker_num][WORKER_ORDER_ID];
        # Omit any worker which did not replay.
        next if defined $worker_array[$worker_num][WORKER_VERDICT] and
                Verdict::RQG_VERDICT_REPLAY ne $worker_array[$worker_num][WORKER_VERDICT];
        stop_worker($worker_num, STOP_REASON_WORK_FLOW . ' 2');
        $stop_count++;
    }
    say("DEBUG: Batch::stop_worker_on_order_replayer: $stop_count replaying RQG worker running " .
        "with orderid $order_id stopped.") if Auxiliary::script_debug("T6");
    return $stop_count;
}

sub stop_worker_oldest_not_using_parent {
    # To be used only in Simplifier::report_replay
    my ($replay_grammar_parent) = @_;

    my $who_am_i = Basics::who_am_i;

    if (not defined $replay_grammar_parent) {
        emergency_exit(STATUS_INTERNAL_ERROR,
                       "ERROR: $who_am_i was called with undef " .
                       "grammar assigned. Will ask for emergency_exit.");
    }
    say("DEBUG: $who_am_i: replay_grammar_parent '$replay_grammar_parent'") if Auxiliary::script_debug("T7");
    my $stop_count            = 0;
    my $oldest_worker_num     = -1;
    my $oldest_worker_runtime = -1;
    my $current_time          = Time::HiRes::time();
    my $emergency_limiter     = 0;
    while(1) {
        $emergency_limiter++;
        my $not_stopped_active_workers = 0;
        for my $worker_num (1..$workers_max) {
            # Omit not running workers
            next if -1 == $worker_array[$worker_num][WORKER_PID];
            # Omit any worker which replayed/interests and is maybe during archiving
            # say("DEBUG 0: " . $worker_num);
            # say("DEBUG 1: " . $worker_array[$worker_num][WORKER_ORDER_ID]);
            # say("DEBUG 2: " . $worker_array[$worker_num][WORKER_VERDICT])
            #     if defined $worker_array[$worker_num][WORKER_VERDICT];
            # say("DEBUG 3: " . $worker_array[$worker_num][WORKER_STOP_REASON])
            #     if defined $worker_array[$worker_num][WORKER_STOP_REASON];
            # say("DEBUG 4: " . $worker_array[$worker_num][WORKER_EXTRA1]);
            # say("DEBUG 5: " . $worker_array[$worker_num][WORKER_EXTRA2])
            #   if defined $worker_array[$worker_num][WORKER_EXTRA2];
            if ((defined $worker_array[$worker_num][WORKER_VERDICT]) and
                ((Verdict::RQG_VERDICT_REPLAY   eq $worker_array[$worker_num][WORKER_VERDICT]) or
                 (Verdict::RQG_VERDICT_INTEREST eq $worker_array[$worker_num][WORKER_VERDICT]))) {
                $not_stopped_active_workers++;
                next;
            }
            # Omit any worker where stopping was already initiated.
            next if defined $worker_array[$worker_num][WORKER_STOP_REASON];

            # Omit any worker using that quite actual parent grammar.
            if ($worker_array[$worker_num][WORKER_EXTRA2] eq $replay_grammar_parent) {
                $not_stopped_active_workers++;
                next;
            }

            # FIXME: In case that warning showed never up than remove the next 3 lines.
            if (-1 == $worker_array[$worker_num][WORKER_START]) {
                say("WARN: $who_am_i: -1 == worker_start seen.");
            }
            my $elapsed_runtime = $current_time - $worker_array[$worker_num][WORKER_START];
            if ($elapsed_runtime > $oldest_worker_runtime) {
                $oldest_worker_runtime = $elapsed_runtime;
                $oldest_worker_num     = $worker_num;
            }
        }
        # FIXME:
        # The criterions need most probably a refinement.
        # - In case the CPU load is already below 95% than stopping a job is questionable.
        # - How evolve the values of active (not stopped) workers, workers_mid and workers_min
        #   over simplification runtime?
        if ($not_stopped_active_workers < $workers_min or
            $oldest_worker_num == -1                  ) {
            say("DEBUG: $who_am_i: $stop_count slightly obsolete RQG worker found and stopped.");
                # if Auxiliary::script_debug("T6");
            return $stop_count;
        }
        # say("DEBUG 0: " . $oldest_worker_num);
        # say("DEBUG 1: " . $worker_array[$oldest_worker_num][WORKER_ORDER_ID]);
        # say("DEBUG 2: " . $worker_array[$oldest_worker_num][WORKER_VERDICT])
        #     if defined $worker_array[$oldest_worker_num][WORKER_VERDICT];
        # say("DEBUG 4: " . $worker_array[$oldest_worker_num][WORKER_EXTRA1]);
        # say("DEBUG 5: " . $worker_array[$oldest_worker_num][WORKER_EXTRA2])
        #     if defined $worker_array[$oldest_worker_num][WORKER_EXTRA2];
        stop_worker($oldest_worker_num, STOP_REASON_WORK_FLOW . ' 3');
        $stop_count++;
        $oldest_worker_num     = -1;
        if ($emergency_limiter >= $workers_max) {
            emergency_exit(STATUS_INTERNAL_ERROR,
                           "ERROR: $who_am_i: Too many loops ($emergency_limiter). " .
                           "Will ask for emergency_exit.");
        }
    }
} # End of sub stop_worker_oldest_not_using_parent


sub stop_worker_till_phase {
# Purpose
# -------
# Used by simplier and others.
# In case some RQG run using a derivate (according to order properties) of the current parent
# grammar replayed the desired outcome than
# - the derivate grammar gets loaded and some new parent grammar gets constructed
# - all other ongoing RQG runs may replay later too but that requires the efforts till these
#   runs are finished.
#   And if they replay than their result(grammar used, shape of order) is regarding the overall
#   simplification progress only like
#      We now know that the grammar used IS capable to replay and the shape of the order MIGHT
#      be capable to replay again. But figuring out the latter requires some new RQG run.
# So we make here the following optimization
#   In case the amount of already invested efforts is sufficient low than we stop that RQG run
#   and restart it with some new grammar which is based on the original order and the latest
#   parent grammar.
#
    my ($phase, $reason) = @_;
    Carp::cluck("DEBUG: Try to stop young RQG workers with phase <= $phase begin.")
        if Auxiliary::script_debug("T6");
    my $stop_count = 0;
    for my $worker_num (1..$workers_max) {
        my $pid = $worker_array[$worker_num][WORKER_PID];
        if (-1 != $pid) {
            # Per last update of bookkeeping the RQG Woorker was alive.
            my $rqg_workdir = $workdir . "/" . $worker_num;
            my $rqg_phase   = Auxiliary::get_rqg_phase($rqg_workdir);
            if      (not defined $rqg_phase) {
                my $status = STATUS_ENVIRONMENT_FAILURE;
                emergency_exit($status, "ERROR: Batch::stop_worker_young : No phase for " .
                               "RQG worker $worker_num got. Will ask for emergency_exit.");
            } else {
                my $allowed_list_ptr = Auxiliary::RQG_PHASE_ALLOWED_VALUE_LIST;
                my @phase_list = @{$allowed_list_ptr};
                # say("DEBUG: phase_list " . join("-", @phase_list));
                my $phase_from_list = shift @phase_list;
                # @phase_list is sorted according to work flow.
                while (defined $phase_from_list) {
                    # DO NOT USE "next" because than the "$phase_from_list = shift @phase_list"
                    # would be missing.
                    if ($phase_from_list eq $rqg_phase) {
                        my $order_id = $worker_array[$worker_num][WORKER_ORDER_ID];
                        stop_worker($worker_num, $reason);
                        $stop_count++;
                        say("DEBUG: Stopped young RQG worker $worker_num using order_id " .
                            "$order_id because being in phase $rqg_phase.") if Auxiliary::script_debug("T6");
                    }
                    if ($phase_from_list eq $phase) {
                        last;
                    }
                    $phase_from_list = shift @phase_list;
                }
            }
        }
    }
    say("DEBUG: Batch::stop_worker_young: $stop_count RQG workers with phase <= '$phase' stopped.")
        if Auxiliary::script_debug("T6");
    return $stop_count;
} # End of sub stop_worker_till_phase

sub emergency_exit {
    my ($status, $reason) = @_;
    if (defined $reason) {
        say($reason);
    }
    # In case we ever do more in stop_workers and that could fail because of
    # mistakes than $give_up == 3 might be used as signal to
    # - do not the risky things or
    # - ignore the fails.
    $give_up = 3;
    stop_workers('emergency_exit');
    safe_exit ($status);
}

my $last_load_decrease;
my $last_load_keep;
my $no_raise_before;
#
# FIXME:
# Rough model to imagine
# $parallel (equal) dices, every dice has for every existing combination a surface with a number
# representing the maximum resource consumption of that RQG test.
# We throw the $parallel dices and add the numbers from the upper surfaces.
# In case that exceeds the resource consumption the box can keep than we remove one dice from
# the game.
# my $too_many_workers;
my $previous_workers;
my $first_load_up;
#
sub check_resources {
# FIXME:
# The routine should return a number which gets than used for computing a delay.
# And only after that delay has passed and if other parameters fit starting some additional
# RQG worker should be allowed.
    my $active_workers = count_active_workers();
    my $load_status    = ResourceControl::report($active_workers);
    my $current_time   = Time::HiRes::time();
    # We might forget to set the right status. Just ensure by initialization to STATUS_FAILURE
    # that we cannot return with a too optimistic status.
    my $return_status  = STATUS_FAILURE;
    if (not defined $no_raise_before) {
        $no_raise_before  = 0;
    }
    if (not defined $previous_workers) {
        $previous_workers = 0;
    }
    my $finished_runs = $verdict_replay + $verdict_interest + ($verdict_ignore - $stopped);
    if ($first_load_up) {
        if ($finished_runs > $workers_mid) {
            $first_load_up =    0;
            say("INFO: Declaring the first_load_up+balance_out phase to be over.");
        }
    }

    if  (ResourceControl::LOAD_INCREASE eq $load_status) {

        # Never exceed $parallel_max because that could be a user or OS limit related border.
        return STATUS_FAILURE if $active_workers + 1 > $workers_max;

        my $current_time = Time::HiRes::time();
        my $divisor;
        if (0 == $workers_mid - $workers_min) {
            $divisor =  1;
            # Most likely caused by $workers_max set to exceptional low value by intention.
            # say("DEBUG: workers_mid - workers_min is 0");
        } else {
            $divisor = $workers_mid - $workers_min;
        }
        my $worker_share1 = ($active_workers + 1 - $workers_min) / $divisor;
        $worker_share1 = 0 if 0 > $worker_share1;
        # 2019-07-02 Observation:
        #    my $worker_share2 = ($active_workers + 1) / $workers_min;
        # generated a division by 0.
        # Reason is currently unknown.
        if (0 == $workers_min) {
            $divisor = 1;
            say("WARNING: workers_min is 0");
        } else {
            $divisor = $workers_min;
        }
        my $worker_share2 = ($active_workers + 1) / $divisor;
        my $delay;
        if ($first_load_up) {
            $delay = $worker_share1 * 60;
            if ($finished_runs > $workers_min) {
                # FIXME maybe
                # Find some better criterion for the point of some first load stabilization.
                $delay += 3;
            } else {
                $delay += $worker_share2 * 3;
            }
        } else {
            $delay = $worker_share1 * $worker_share1 * 10;
        }

        if ($previous_workers + 2 <= $active_workers) {
            # Obvious internal error because "in maximum" we have started one worker after
            # actualization of $previous_workers which happens only in check_resources.
            my $status = STATUS_INTERNAL_ERROR;
            emergency_exit($status,
                "ERROR: previous_workers($previous_workers) + 2 <= active_workers($active_workers)");
        } elsif ($previous_workers + 1 == $active_workers) {
            # One worker was started and none have finished.
            # So starting some additional worker would be a raise in resource consumption.
            if ($no_raise_before > $current_time) {
                # We would raise the amount of workers but had some bad state not long enough ago.
                $return_status   = STATUS_FAILURE;
            } else {
                if ($active_workers + 1 <= $workers_mid) {
                    # This should be non critical.
                    $no_raise_before = $current_time + $delay;
                    $return_status   = STATUS_OK;
                } else {
                    # $active_workers + 1 > $workers_mid
                    # Should we raise $workers_mid by 1?
                    if ($last_load_keep     + 120 / 2 < $current_time and
                        $last_load_decrease + 120     < $current_time)   {
                        raise_workers_range;
                        $no_raise_before = $current_time + 60;
                        $return_status = STATUS_OK;
                    } else {
                        say("DEBUG: workers_mid ($workers_mid) limit prevents start")
                            if Auxiliary::script_debug("T2");
                        $return_status = STATUS_FAILURE;
                    }
                }
            }
        } elsif ($previous_workers == $active_workers) {
            # One worker was started and one has finished   or
            # no was started and no has finished.
            # So starting some additional worker would be a raise in resource consumption.
            if ($no_raise_before > $current_time) {
                # We would raise the amount of workers but had some bad state not long enough ago.
                $return_status   = STATUS_FAILURE;
            } else {
                if ($active_workers + 1 <= $workers_mid) {
                    # This should be non critical.
                    $no_raise_before = $current_time + $delay / 2; # FIXME maybe: Is that good?
                    $return_status   = STATUS_OK;
                } else {
                    # $active_workers + 1 > $workers_mid
                    # Should we raise $workers_mid by 1?
                    if ($last_load_keep     + 60 / 2 < $current_time and
                        $last_load_decrease + 60     < $current_time)   {
                        raise_workers_range;
                        $no_raise_before = $current_time + 30;
                        $return_status = STATUS_OK;
                    } else {
                        say("DEBUG: workers_mid ($workers_mid) limit prevents start")
                            if Auxiliary::script_debug("T2");
                        $return_status = STATUS_FAILURE;
                    }
                }
            }
        } else {
            # One worker was started and more than one have finished    or
            # no worker was started and one or more have finished.
            # This should be non critical.
            $no_raise_before = $current_time + 0; # FIXME maybe: Is that good?
            $return_status   = STATUS_OK;
        }

        $previous_workers = $active_workers;
        # Ensure that we have left the current routine.
        return $return_status;
    }

    if (ResourceControl::LOAD_KEEP eq $load_status) {
        if ($no_raise_before < $current_time + 30) {
            $no_raise_before = $current_time + 30;
        }
        $last_load_keep = $current_time;
        # Ensure that we have left the current routine.
        $previous_workers = $active_workers;
        return $return_status;
    }

    if (ResourceControl::LOAD_DECREASE eq $load_status) {
        my $problem_persists = 1;
        #  LOOP till the problem is fixed
        while ($problem_persists) {
            $last_load_decrease = $current_time;
            if ($no_raise_before < $current_time + 60) {
                $no_raise_before = $current_time + 60;
            }
            if ($active_workers < $workers_mid) {
                decrease_workers_range;
            }
            my $current_active_workers = $active_workers;
            if (0 == stop_worker_till_phase(Auxiliary::RQG_PHASE_PREPARE, STOP_REASON_RESOURCE) ) {
                # stop_worker_till_phase brought nothing.
                # So stop the youngest of the remaining RQG workers.
                my $worker_start  = 0;
                my $worker_number = 0;
                for my $worker_num (1..$workers_max) {
                    next if -1 == $worker_array[$worker_num][WORKER_PID];
                    if ($worker_array[$worker_num][WORKER_START] > $worker_start) {
                        $worker_start = $worker_array[$worker_num][WORKER_START];
                        $worker_number = $worker_num;
                    }
                }
                if (0 == $worker_number) {
                    my $status = STATUS_INTERNAL_ERROR;
                    emergency_exit($status, "ERROR: ResourceControl::report delivered '$load_status' " .
                                   "but no active RQG worker detected.");
                } else {
                    # Kill the processgroup of the RQG worker picked.
                    stop_worker($worker_number, STOP_REASON_RESOURCE);
                }
            }
            # The system is in a critical state because of resource consumption.
            # The freeing of resources is done by reap_workers() only.
            # But reap_workers() requires that the exit status of the process of the RQG worker
            # could be reaped. And that depends on if the kill SIGKILL is finished.
            # But even a kill SIGKILL requires some time especially on some heavy loaded box.
            # So we need to run 'reap_workers' till the number of active workers has decreased.
            # It is intentional to not wait till all stopped workers are reaped.
            my $max_wait = 30;
            my $end_time = time() + $max_wait;
            # FIXME:
            # The activity of the other RQG workers could be also dangerous and 3s or 30s is long.
            while (time() < $end_time and $active_workers >= $current_active_workers) {
                sleep 0.1;
                reap_workers();
                $active_workers = count_active_workers();
            }
            if ($active_workers < $current_active_workers) {
                # Great.
            } else {
                my $status = STATUS_ENVIRONMENT_FAILURE;
                emergency_exit($status, "ERROR: Batch::check_resources: Waited $max_wait s " .
                          "but none of the RQG worker processes could be reaped. " .
                          "Will ask for emergency_exit.");
            }
            $load_status = ResourceControl::report($active_workers);
            if (ResourceControl::LOAD_DECREASE ne $load_status) {
                $problem_persists = 0;
            } else {
                # In case we would not use a sleep than we would stop all jobs because swap
                # space usage drops that slow.
                sleep 1;
            }
        }
        # $problem_persists is now 0, but $load_status is now also != LOAD_DECREASE.
        # Case 1:
        # The current $load_status is less evil than LOAD_DECREASE.
        # The handling for that status is no more reachable (~ 50 lines above) and partially
        # (Example: What if LOAD_INCREASE now?) too optimistic.
        # We simply return later STATUS_FAILURE.
        # Case 2:
        # The current $load_status is more evil than LOAD_DECREASE.
        # We handle that now.
        # Even in case we do that slightly wrong we return at least STATUS_FAILURE later.
        $previous_workers = $active_workers;
        $return_status = STATUS_FAILURE;
    }

    if (ResourceControl::LOAD_GIVE_UP eq $load_status) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        emergency_exit($status, "ERROR: ResourceControl::report delivered '$load_status'. " .
                       "Will ask for emergency_exit.");
    }

    return STATUS_FAILURE;

} # End of sub check_resources


# FIXME: Rename and describe
# 1. It is some
#    - init regarding $first_load_up
#    - reset when called the non first time regarding $last_load_* and $no_raise_before
# 2. Its called
#    - once in lib/Combinator.pm
#    - several times (like per phase and campaign) in lib/Simplifier.pm
#      Reason for reset:
#      The load (no of concurrent RQG Worker) decreases dramatic towards campaign end.
#      There will be a more or less long lasting period at campaign start.
#      The simplifier checks grammars or generates orders in that period.
#      This all together means that we had most probably some longer lasting trouble free period.
#      And that should not encourage to raise the load too fast.
#      FIXME:
#      Does that fit to the implementation?
#         Reset to $last_load_* = $current_time even though $workers_m* have already matured.
#    only and nowhere else.
#
sub init_load_control {
    my $current_time =      Time::HiRes::time();
    if (not defined $first_load_up) {
        $first_load_up =    1;
    } else {
        $first_load_up =    0;
    }
    $last_load_decrease =   $current_time;
    $last_load_keep =       $current_time;
    $no_raise_before =      0;
}


my $archive_warning_emitted =   0;
sub reap_workers {

# 1. Reap finished workers so that processes in zombie state disappear.
# 2. Decide depending on the verdict and certain options what to do with maybe existing remainings
#    of the finished test.
# 3. Clean the workdir and vardir of the RQG run
# 4. Return the number of active workers (process is busy/not reaped).

    # https://perldoc.perl.org/perlipc.html#Deferred-Signals-(Safe-Signals)

    say("DEBUG: Entering reap_workers") if Auxiliary::script_debug("T5");

    my $active_workers = 0;
#   # TEMPORARY
#   if (Auxiliary::script_debug("T3")) {
#       say("worker_array_dump at entering reap_workers");
#       worker_array_dump();
#   }
    for my $worker_num (1..$workers_max) {
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
                kill '-9', $worker_process_group;

                my $rqg_log       = "$rqg_workdir" . "/rqg.log";
                my $rqg_job       = "$rqg_workdir" . "/rqg.job";

                my ($verdict, $extra_info) = Verdict::get_rqg_verdict($rqg_workdir);
                if (not defined $verdict) {
                    Carp::cluck("verdict is undef.");
                    emergency_exit(STATUS_INTERNAL_ERROR, "ERROR: This must not happen.");
                }

                $worker_array[$worker_num][WORKER_END] = time();
                if (-1 == $worker_array[$worker_num][WORKER_START]) {
                    # The parent (rqg_batch.pl) has never detected that the child (rqg.pl) started
                    # to work. Hence WORKER_START is -1. And than in minimum the current RQG
                    # worker had to be stopped because of maximum rqg_batch.pl runtime exceeded.
                    # So we set here WORKER_START = WORKER_END in order to avoid strange total
                    # runtime values like current unix timestamp in "result.txt".
                    $worker_array[$worker_num][WORKER_START] = $worker_array[$worker_num][WORKER_END];
                }
                my $iso_ts = isoTimestamp();
                if (defined $worker_array[$worker_num][WORKER_STOP_REASON]) {
                    # The RQG worker was 'victim' of a stop with SIGKILL.
                    # So write various information into the RQG run log which the RQG worker was
                    # no more able to do.
                    # Its no problem that this appended stuff will be not in the archive because
                    # there is
                    # - most likely no archive at all
                    # - sometimes an archive harmed by the SIGKILL
                    # - extreme unlikely a complete archive
                    # ==> The archive gets thrown away in general.
                    if ($worker_array[$worker_num][WORKER_STOP_REASON] eq STOP_REASON_RQG_LIMIT) {
                        $verdict = Verdict::RQG_VERDICT_INTEREST;
                    } else {
                        $verdict = Verdict::RQG_VERDICT_IGNORE_STOPPED;
                    }
                    append_string_to_file($rqg_log, "# $iso_ts BATCH: Stop the run ".
                        "because of '" . $worker_array[$worker_num][WORKER_STOP_REASON] . "'.\n" .
                                                           "# $iso_ts Verdict: $verdict\n");
                }

                $worker_array[$worker_num][WORKER_VERDICT] = $verdict;
                $worker_array[$worker_num][WORKER_V_INFO]  = $extra_info;
                say("DEBUG: Worker [$worker_num] with (process) exit status " .
                    "'$exit_status' and verdict '$verdict' reaped.") if Auxiliary::script_debug("T4");

                # Prevent that some historic + fixed but evil bug can ever happen again.
                if (not defined $verdict_collected) {
                    Carp::cluck("INTERNAL ERROR: verdict_collected is undef.");
                    emergency_exit(STATUS_INTERNAL_ERROR, "ERROR: This must not happen.");
                }

                my $target_prefix     = $workdir . "/" . Basics::lfill0($verdict_collected,
                                                                           RQG_NO_LENGTH);
                my $saved_log         = $target_prefix     . "/rqg.log";
                $worker_array[$worker_num][WORKER_LOG] = $saved_log;
                my $saved_job         = $target_prefix     . "/rqg.job";

                $iso_ts = isoTimestamp();

                # Note:
                # The next routine is required because the standard failure handling is to make
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
                    $verdict eq Verdict::RQG_VERDICT_IGNORE_UNWANTED    ) {
                    if ($verdict eq Verdict::RQG_VERDICT_IGNORE_STOPPED) {
                        $stopped++;
                        # Do nothing with $order_array[$order_id][ORDER_EFFORTS*]
                        $worker_array[$worker_num][WORKER_LOG] = "<deleted>";
                        drop_directory($rqg_workdir);
                    } else {
                        if ($discard_logs) {
                            $worker_array[$worker_num][WORKER_LOG] = "<deleted>";
                            drop_directory($rqg_workdir);
                        } else {
                            # WARNING: The "move" does not work across filesystems.
                            if (STATUS_OK != Basics::rename_dir($rqg_workdir, $target_prefix)) {
                                emergency_exit(STATUS_ENVIRONMENT_FAILURE,
                                    "ERROR: This must not happen.");
                            }
                        }
                    }
                    $verdict_ignore++;
                } elsif ($verdict eq Verdict::RQG_VERDICT_INTEREST or
                         $verdict eq Verdict::RQG_VERDICT_REPLAY     ) {
                    # WARNING: The "move" does not work across filesystems.
                    if (STATUS_OK != Basics::rename_dir($rqg_workdir, $target_prefix)) {
                        emergency_exit(STATUS_ENVIRONMENT_FAILURE,
                            "ERROR: This must not happen.");
                    }
                    say("DEBUG: '$rqg_workdir' moved to '$target_prefix'");
                    if ($dryrun) {
                        # We fake a RQG run and therefore some archive cannot exist.
                    } else {
                        my $rqg_arc = $target_prefix . "/archive.tar.xz";
                        if (not -e $rqg_arc) {
                            if (not $archive_warning_emitted) {
                                say("WARN: Some archive does not exist. This might be " .
                                    "intentional or a mistake. Further warnings of this kind " .
                                    "will be suppressed.");
                                $archive_warning_emitted = 1;
                            }
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
                    # WARNING: The "move" does not work across filesystems.
                    if (STATUS_OK != Basics::rename_dir($rqg_workdir, $target_prefix)) {
                        emergency_exit(STATUS_ENVIRONMENT_FAILURE,
                            "ERROR: This must not happen.");
                    }
                    $verdict_init++;
                    say("WARN: The final Verdict in '$saved_log' is RQG_VERDICT_INIT.");
                    # Maybe touch ORDER_EFFORTS_INVESTED or ORDER_EFFORTS_LEFT
                } else {
                    emergency_exit(STATUS_CRITICAL_FAILURE,
                        "INTERNAL ERROR: Final Verdict '$verdict' is not treated/unknown. " .
                        "This should not happen.");
                }
                $verdict_collected++;
                foreach my $dir (Local::get_rqg_fast_dir . $rqg_appendix,
                                 Local::get_rqg_slow_dir . $rqg_appendix) {
                    drop_directory($dir);
                }
            } elsif (-1 == $kid) {
                say("ALARM: RQG worker $worker_num was already reaped.");
                worker_reset($worker_num);
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
                if ($batch_type eq BATCH_TYPE_RQG_SIMPLIFIER) {
                    my ($verdict, $extra_info) = Verdict::get_rqg_verdict($rqg_workdir);
                    if ($verdict eq Verdict::RQG_VERDICT_REPLAY) {
                        my $grammar_used   = $worker_array[$worker_num][WORKER_EXTRA1];
                        my $grammar_parent = $worker_array[$worker_num][WORKER_EXTRA2];
                        $worker_array[$worker_num][WORKER_VERDICT] = $verdict;
                        my $response = Simplifier::report_replay($grammar_used, $grammar_parent,
                                                                 $order_id);
                    }
                }
            }
        }
    } # Now all RQG worker are checked.

#   if (Auxiliary::script_debug("T5")) {
#       say("worker_array_dump before leaving reap_workers");
#       worker_array_dump();
#   }
    say("DEBUG: Leave 'reap_workers' and return (active workers found) : " .
        "$active_workers") if Auxiliary::script_debug("T4");
    return $active_workers;

} # End sub reap_workers


sub check_exit_file {
    my ($exit_file) = @_;
    if (-e $exit_file) {
        $give_up = 2;
        say("INFO: Exit file detected. Stopping all RQG Worker.");
        stop_workers(STOP_REASON_BATCH_LIMIT);
    }
}

sub check_runtime_exceeded {
    my ($batch_end_time) = @_;
    if ($batch_end_time  < Time::HiRes::time()) {
        $give_up = 2;
        say("INFO: The maximum total runtime for rqg_batch.pl is exceeded. " .
            "Stopping all RQG Worker.");
        stop_workers(STOP_REASON_BATCH_LIMIT);
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

sub check_rqg_runtime_exceeded {
    my ($max_rqg_runtime) = @_;

    if (not defined $max_rqg_runtime) {
        Carp:cluck("INTERNAL ERROR: \$max_rqg_runtime is not defined.");
        my $status = STATUS_INTERNAL_ERROR;
        emergency_exit($status);
    }
    for my $worker_num (1..$workers_max) {
        # -1 == no main process of that RQG worker running.
        # Maybe there was never one running or the last running finished and was reaped.
        next if -1 == $worker_array[$worker_num][WORKER_PID];
        if (time() > $worker_array[$worker_num][WORKER_START] + $max_rqg_runtime) {
            stop_worker($worker_num, STOP_REASON_RQG_LIMIT);
        }
    }
}



# my $script_debug = 0;

##############################
sub make_infrastructure {
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

    ($workdir) = @_;
    # my ($run_id, $symlink_name) = @_;

    my $snip_all     = "for batches of RQG runs";
    my $snip_current = "for the current batch of RQG runs";

    # Files for bookkeeping of all the RQG runs somehow finished
    # ---------------------------------------------------------
    $result_file = $workdir . "/result.txt";
    if (STATUS_OK != Basics::make_file($result_file, undef)) {
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    } else {
        say("DEBUG: The result (summary) file '$result_file' was created.")
            if Auxiliary::script_debug("B2");
    }
    $setup_file = $workdir . "/setup.txt";
    my $setup_file = $workdir . "/setup.txt";
    if (STATUS_OK != Basics::make_file($setup_file, undef)) {
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    } else {
        say("DEBUG: The setup (summary) file '$setup_file' was created.")
            if Auxiliary::script_debug("B2");
    }

    return STATUS_OK;
}

#---------------------------------------------------------------------------------------------------
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
#          It also adjusts the load dynamic to any hardware and setup of tests met.
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


# The management of orders via queues and hashes
# ==============================================
# Picking some order for generating a job followed by execution means
# - looking into %try_first_hash
# - pick the first element in case there is one, otherwise look into @try_queue
# - an element picked from %try_first_hash or @try_queue gets removed from there
#   In case that order is
#   - is valid (none of the requirements for the test are violated) than some corresponding
#     RQG run gets started.
#   - no more valid (Example: We should remove component x1 from rule X. But X is already removed.)
#     than the order id gets added to %try_never_hash and removed from %try_all_hash
# After finishing some RQG run a decision about the fate of that order is done based on the fate
# of that RQG run.
# a) The run was stopped because of reasons like resource shortage or workflow optimization.
#    Add the order id to @try_first_hash.
# b) Outcome of the run is not the desired one and
#    - unwanted (usually other bug and we do not want to move into his reagion) than add the
#      order id to %try_over_bl_hash
#    or
#    - reaches the current number of maximum trials for some order than add the order id to
#      %try_over_hash.
# c) Outcome of the run is the desired one
#    Combinator: like b)
#    Simplifier:
#    - replay based on current parent grammar
#      Exploit that progress (=> get new parent grammar) and add order id to %try_never_hash
#      and clean other try_*hashes.
#    - replay based on some parent grammar older than the current one
#      Add order id to %try_first_hash.

# @try_queue
# ----------
# Queue (driven as FIFO) containing orders (-> order_id) which should be picked if
# %try_first_hash is empty.
# Reasons of using a FIFO:
# 1. In case of the Simplifier the assumption about the optimal order of test modifications to be
#    tried (called order) changes during the test campaign because of the results achieved.
#    Example:
#    The sub "generate_orders" causes that the heaviest modifications/orders have the smallest
#    order id's. And at this point of work the most promising order is order id asc.
#    But as soon as we have results (replays of desired or other unwanted bad bad effects ...)
#    it seems reasonable to retry certain orders earlier or later. Hence some FIFO is used.
# 2. Duplication of orders in should be supported even though being in the moment not
#    used intentional.
#    ... 13 - 24 - 13 - 17 ...
# In case @try_queue becomes empty than it gets refilled up to a bit more than $workers_max entries
# in order to guarantee some roughly equal size of refill operations.
#             The most promising candidates first.
#        reactivate_try_replayer if $workers_max > scalar @try_queue;
#            After that %try_replayer_hash is empty.
#
#            The medium promising candidates second if needed at all (likely).
#        reactivate_try_over     if $workers_max > scalar @try_queue;
#            After that %try_over_hash is empty.
#
#            The least promising candidates last if needed at all (quite likely).
#        reactivate_try_over_bl  if $workers_max > scalar @try_queue;
#            After that %try_over_bl_hash is empty.
#
#            And in case that is not sufficient (not all time) we fill based on %try_all_hash.
#        while ($workers_max > scalar @try_queue and 0 < scalar (keys %try_all_hash) ) {
#            reactivate_try_all;
#            %try_all_hash will stay filled.
#        }
my @try_queue;

# %try_all_hash
# -------------
# Usage: Combinator and Simplifier + needed for refilling @try_queue
# At the begin of the RQG Batch Tool run the sub "get_order" will meet some empty @try_queue.
# Therefore Simplifier::generate_orders or Combinator::generate_orders will be called.
# That fills @try_queue and %try_all_hash with
# - Simplifier: all possible order id's
# - Combinator: one possible order id
# Depending on test runs for some order and its results order id's could be moved from %try_all_hash
# to %try_never_hash or %try_exhausted_hash.
my %try_all_hash;

# %try_first_hash
# ---------------
# Usage: Simplifier, Combinator
# In case a test run based on some order id <m>
# - replayed the desired result but some concurrent test based on order <n> replayed earlier
#   ... see %try_replayer_hash
#   Purpose:
#   Retry order <m> soon and increase the left over efforts because its a very promising
#   candidate.
# or
# - had to be stopped
#   Purpose:
#   Retry order <m> soon and achieve a more balanced left over efforts consumption
# The sub "get_order" tries
# - pick order with smallest id from %try_first_hash + delete that id from %try_first_hash
# before trying
# - pick first order from @try_queue.
my %try_first_hash;

# %try_replayer_hash
# ------------------
# Usage: Simplifier
# In case a test run based on some order <n> replayed the desired result but some concurrent
# test based on order <m> replayed earlier than the modifications belonging to order <m>
# get applied. The order <m> and maybe certain other orders become obsolete.
# In the case that our order <n> survives we just do not know if the corresponding test with
# <m> and <n> applied is capable to replay at all.
# Its more likely that a test run based on <n> will replay than some average other test.
# The current order id gets added to %try_replayer_hash.
my %try_replayer_hash;

# %try_over_bl_hash
# -----------------
# Usage: Simplifier
# In case a test run based on some order id <m> replayed some other unwanted bad effect than
# the order id gets added to %try_over_bl_hash.
# Its less likely that a test run based on <m> will replay the desired result than some
# average other test.
my %try_over_bl_hash;

# %try_over_hash
# --------------
# Usage: Simplifier
# In case a test run based on some order id <m>
# - did neither replay the desired result nor some other unwanted effect
# and
# - left over efforts <= 0 is now reached
# than the order id gets added to %try_over_hash.
# Its better to try lesss tested orders first.
my %try_over_hash;

# %try_never_hash
# ----------------
# Usage: Simplifier
# In case a test run based on some order id replayed the desired result before any concurrent test
# run than the modifications belonging to that order get applied like use some new parent grammar
# or less threads or ... from now on. Hence that order becomes obsolete.
# In case of grammar simplification even more orders could become obsolete.
# Example: Order 3 which replaces the content of rule "select" by '' was the first replayer.
#          The rule "subquery" is used in the original content of rule "select" and nowhere else.
#          Hence all orders manipulating the rule "subquery" become obsolete.
# The id's of the obsolete orders get removed from %try_all_hash and added to %try_never_hash.
my %try_never_hash;

# %try_exhausted_hash
# -------------------
# Usage: Simplifier
# The id of some order with EFFORTS_INVESTED >= trials gets removed from %try_all_hash and added
# to %try_exhausted_hash.
my %try_exhausted_hash;

our $out_of_ideas;
sub dump_try_hashes {
    my @try_run_queue;
    for my $worker_num (1..$workers_max) {
        my $order_id = $worker_array[$worker_num][WORKER_ORDER_ID];
        push @try_run_queue, $order_id if -1 != $order_id;
    }
    say("DEBUG: Orders in work      : "  . join (' ', sort {$a <=> $b} @try_run_queue));
    say("DEBUG: \%try_first_hash     : " . join (' ', sort {$a <=> $b} keys %try_first_hash));
    say("DEBUG: \@try_queue          : " . join (' ', sort {$a <=> $b} @try_queue ));
    say("DEBUG: \%try_over_bl_hash   : " . join (' ', sort {$a <=> $b} keys %try_over_bl_hash ));
    say("DEBUG: \%try_over_hash      : " . join (' ', sort {$a <=> $b} keys %try_over_hash ));
    say("DEBUG: \%try_all_hash       : " . join (' ', sort {$a <=> $b} keys %try_all_hash ));
    say("DEBUG: \%try_replayer_hash  : " . join (' ', sort {$a <=> $b} keys %try_replayer_hash ));
    say("DEBUG: \%try_exhausted_hash : " . join (' ', sort {$a <=> $b} keys %try_exhausted_hash));
    say("DEBUG: \%try_never_hash     : " . join (' ', sort {$a <=> $b} keys %try_never_hash));
    say("DEBUG: \$out_of_ideas       : " . $out_of_ideas);
}
sub init_order_management {
    $out_of_ideas = 0;
    undef %try_first_hash;
    undef @try_queue;
    undef %try_over_bl_hash;
    undef %try_over_hash;
    undef %try_all_hash;
    undef %try_replayer_hash;
    undef %try_exhausted_hash;
    undef %try_never_hash;
}
sub get_out_of_ideas {
    return $out_of_ideas;
}


sub known_orders_waiting {
# Currently not used but maybe somewhere in future.
# Purpose:
# Detect the following state of grammar simplification.
# 0. All possible orders were generated ($out_of_ideas>=1), which is not checked here.
# 1. None of the orders is
#    - currently in trial/running                  --> count_active_workers()
#    - waiting for trial/running                   --> @try_first_hash, @try_hash
#    Delayed candidates for repetition of the run are ignored!
    return 1 if count_active_workers()           > 0;
    return 1 if scalar (keys %try_first_hash)    > 0;
    return 1 if scalar @try_queue                > 0;
    return 1 if scalar (keys %try_over_hash)     > 0;
    return 1 if scalar (keys %try_over_bl_hash)  > 0;
    say("DEBUG: Batch::known_orders_waiting : None in work nor planned+left_over.")
        if Auxiliary::script_debug("B5");
    return 0;
}


sub get_order {

    my $who_am_i = Basics::who_am_i;
    my $order_id;

    sub is_order_valid {
        my ($order_id) = @_;
        if (not exists $try_exhausted_hash{$order_id} and
            not exists $try_never_hash{$order_id}        ) {
            return $order_id;
        } else {
            return undef;
        }
    }

    my @array;
    # Sort keys of %try_first_hash numerically ascending because in average the orders with the
    # lower id's will remove more if having success at all.
    @array = sort {$a <=> $b} keys %try_first_hash;
    while (0 < scalar @array) {
        $order_id = shift @array;
        if (defined $order_id) {
            say("DEBUG: $who_am_i Order $order_id picked from \%try_first_hash.")
                if Auxiliary::script_debug("B5");
            delete $try_first_hash{$order_id};
            $order_id = is_order_valid($order_id);
            return $order_id if defined $order_id;
        }
    }
    say("DEBUG: $who_am_i \%try_first_hash was or has become empty.")
        if Auxiliary::script_debug("B5");

    # @array = ();

    while (0 < scalar @try_queue) {
        $order_id = shift @try_queue;
        if (defined $order_id) {
            say("DEBUG: $who_am_i Order $order_id picked from \@try_queue. Current length : " .
                scalar @try_queue) if Auxiliary::script_debug("B5");
            $order_id = is_order_valid($order_id);
            return $order_id if defined $order_id;
        }
    }
    say("DEBUG: $who_am_i \@try_queue was or has become empty.")
        if Auxiliary::script_debug("B5");

    # Observation: 2020-04-18
    # rqg_batch.pl exits (phase 'grammar_simp', campaign 1, out_of_ideas = 1, refills : 2) even
    # though queues and/or hashes contain order id's.
    # IMPORTANT:
    # Never enclose the group of lines (no empty line between) with a
    #   if (0 == $out_of_ideas) {
    # Main reason:
    # After the first time where generate_orders does not add entries to @try_queue $out_of_ideas
    # gets set to 1 it is clear that we need either a new campaign for the current phase or a
    # switch to the next simplification phase. And that requires that all active RQG Worker have
    # finished. Hence generate_orders() looks if $out_of_ideas == 1 and active workers == 0
    # and sets than switch_phase = 1.
    # Minor reason:
    # Even though $out_of_ideas == 1 was set it might happen that some job finished and could be
    # recycled.
    # Maybe we have not already generated all orders possible?
    if      ($batch_type eq BATCH_TYPE_RQG_SIMPLIFIER) {
        my $num = Simplifier::generate_orders();
        say("DEBUG: $who_am_i \@try_queue refilled up to " .
            scalar @try_queue . " Elements.") if Auxiliary::script_debug("B3");
    } elsif ($batch_type eq BATCH_TYPE_COMBINATOR) {
        Combinator::generate_orders();
        say("DEBUG: $who_am_i \@try_queue refilled up to " .
            scalar @try_queue . " Elements.") if Auxiliary::script_debug("B3");
    } else {
        Carp::cluck("INTERNAL ERROR: batch_type '$batch_type' is not supported.");
        emergency_exit(STATUS_INTERNAL_ERROR, "ERROR: This must not happen (1).");
    }
    while (0 < scalar @try_queue) {
        $order_id = shift @try_queue;
        if (defined $order_id) {
            say("DEBUG: $who_am_i Order $order_id picked from refilled \@try_queue.")
                if Auxiliary::script_debug("B5");
            $order_id = is_order_valid($order_id);
            return $order_id if defined $order_id;
        }
    }
    say("DEBUG: $who_am_i refilled \@try_queue was or has become empty. Setting " .
        "out_of_ideas = 1.") if Auxiliary::script_debug("B3");
    $out_of_ideas = 1;

    return undef;

} # End sub get_order

sub check_order_id {
    my ($order_id) = @_;
    if (not defined $order_id) {
        Carp::cluck("INTERNAL ERROR: order_id is undef.");
        my $status = STATUS_INTERNAL_ERROR;
        emergency_exit($status);
    }
}
sub check_worker_number {
    my ($worker_number) = @_;
    if (not defined $worker_number) {
        Carp::cluck("INTERNAL ERROR: worker_number is undef.");
        my $status = STATUS_INTERNAL_ERROR;
        emergency_exit($status);
    }
}

sub add_order {
# Simplifier::add_order calls Batch::add_order whenever a new order was generated.
    my ($order_id) = @_;
    check_order_id($order_id);
    push @try_queue, $order_id;
    $try_all_hash{$order_id} = 1;
}

sub add_to_try_over {
    my ($order_id) = @_;
    check_order_id($order_id);
    # FIXME: Bail out if order_id is already known?
    if (not exists $try_never_hash{$order_id} and
        not exists $try_exhausted_hash{$order_id} ) {
        $try_over_hash{$order_id} = 1;
    }
}
sub add_to_try_over_bl {
    my ($order_id) = @_;
    check_order_id($order_id);
    if (not exists $try_never_hash{$order_id} and
        not exists $try_exhausted_hash{$order_id} ) {
        $try_over_bl_hash{$order_id} = 1;
    }
}
sub add_to_try_exhausted {
    my ($order_id) = @_;
    check_order_id($order_id);
    delete $try_first_hash{$order_id};
    delete $try_over_hash{$order_id};
    delete $try_over_bl_hash{$order_id};
    delete $try_replayer_hash{$order_id};
    delete $try_all_hash{$order_id};
    if (not exists $try_never_hash{$order_id}) {
        $try_exhausted_hash{$order_id} = 1;
    }
}
sub add_to_try_never {
    my ($order_id) = @_;
    check_order_id($order_id);
    $try_never_hash{$order_id} = 1;
    delete $try_over_hash{$order_id};
    delete $try_over_bl_hash{$order_id};
    delete $try_first_hash{$order_id};
    delete $try_replayer_hash{$order_id};
    delete $try_exhausted_hash{$order_id};
    delete $try_all_hash{$order_id};
    # The add_to_try_never could happen in the following Simplifier routines
    # - get_job
    #   Have an order picked according ... from one of the queues but detect
    #   that this order is no more valid.
    #   Example: Removing ... from rule X is impossible because rule X does no more exist.
    # - report_replay
    #   Some RQG runner has replayed but maybe not finished his work.
    #   In case its grammar B is based one the current parent grammar Y than its a "Winner" and
    #   all other RQG runner working on the same order (--> using grammar B too or some older
    #   grammar A based on older parent grammar X) get stopped.
    #   Its likely that the replaying runner is just during archiving or similar.
    #   So we must not stop it too.
    # - register_result
    #   Some RQG runner has replayed and finished his work.
    #   In case its grammar B is based one the current parent grammar Y than its a "Winner" and
    #   there was no detection via "report_replay".
    #   Reason: Signal replay + finish was after the last call of "report_replay".
    #   All RQG runner working on the same order could be stopped.
    #   In case its grammar B is not based on the current parent grammar Y than it could have
    #   been a "Winner" already processed by "report_replay" or its a replayer without luck.
    # So it we cannot run a     stop_worker_on_order_...($order_id);    here.
    say("DEBUG: Batch::add_to_try_never: $order_id added to \%try_never_hash.")
        if Auxiliary::script_debug("B5");
    # @try_queue does not get touched.
    # The validation before test start will detect that its invalid.
}
sub add_to_try_first {
    my ($order_id) = @_;
    check_order_id($order_id);
    if (not exists $try_never_hash{$order_id} and
        not exists $try_exhausted_hash{$order_id} ) {
        $try_first_hash{$order_id} = 1;
    }
}
sub add_to_try_intensive_again {
    my ($order_id) = @_;
    check_order_id($order_id);
    if (not exists $try_never_hash{$order_id} and
        not exists $try_exhausted_hash{$order_id} ) {
        $try_first_hash{$order_id} = 1;
        $try_replayer_hash{$order_id} = 1;
    }
}

sub reactivate_try_replayer {
    push @try_queue, sort {$a <=> $b} keys %try_replayer_hash;
}
sub reactivate_try_over {
    push @try_queue, sort {$a <=> $b} keys %try_over_hash;
    undef %try_over_hash;
}
sub reactivate_try_over_bl {
    push @try_queue, sort {$a <=> $b} keys %try_over_bl_hash;
    undef %try_over_bl_hash;
}
sub reactivate_try_all {
    push @try_queue, sort {$a <=> $b} keys %try_all_hash;
}
sub reactivate_till_filled {
    reactivate_try_replayer if $workers_max > scalar @try_queue;
    reactivate_try_over     if $workers_max > scalar @try_queue;
    reactivate_try_over_bl  if $workers_max > scalar @try_queue;
    while ($workers_max > scalar @try_queue and
           0 < scalar (keys %try_all_hash) ) {
        reactivate_try_all;
    }
    say("INFO: Length of \@try_queue after reactivation of orders: " . scalar @try_queue);
# Please note that %try_all_hash is empty could happen.
# Example:
# query: <some select(mean text without rules) crashing the server>;
}

sub get_rand_try_all_id {
    my @try_all_list = sort keys %try_all_hash;
    my $key_count    = scalar @try_all_list;
    return undef if 0 == $key_count;
    my $rand_num     = int(rand($key_count));
    return $try_all_list[$rand_num];
}


# Rename to report_orders_in_work
sub get_orders_in_work {
# Purpose
# -------
# Return all ids of orders being just in execution.
# 1. During the last reap_workers call we could not reap the main process
#    ( $worker_array[$worker_num][WORKER_PID] != -1 ) of the RQG Worker.
#    So the base might be slightly outdated like the process of some RQG Worker has become
#    already a zombie. This is harmless.
# 2. Please be aware of
#    - There might be several RQG Workers executing jobs based on the same order.
#    - Jobs based on the same order can differ regarding RQG grammar and other stuff.
#
    my %orders_in_work;
    for my $worker_num (1..$workers_max) {
        next if -1 == $worker_array[$worker_num][WORKER_PID];
        $orders_in_work{$worker_array[$worker_num][WORKER_ORDER_ID]} = 1;
    }
    # Sorting only because prints look nicer.
    my @orders_in_work = sort {$a <=> $b} keys %orders_in_work;
    say("DEBUG: Batch::get_orders_in_work: " . join(" , ", @orders_in_work))
        if Auxiliary::script_debug("B6");
    return @orders_in_work;
}


sub report_bad_state {
# Purpose (for Combinator only)
# -----------------------------
# In case of meeting some quite "ill" server or RQG the following issues should get prevented
# 1. Serious space consumption of the archives within the filesystem where the rqg_batch
#    workdir is located. The rqg_batch LoadControl will prevent a filesystem full.
#    But many of the archives just show the same bug or siblings of it.
# 2. Serious amount of writes to permanent storage which is quite bad in case of some SSD.
#    A strong box could produce 100 - 200 GB in 0.5h.
# 3. Some amount of wasted elapsed time.
#
# $verdict_replay     -- bad run (counting)
# $verdict_interest   -- bad run (counting)
# $verdict_ignore     -- STATUS_OK or bad run (not counting)
# $verdict_collected  -- roughly finished runs
    my $bad_runs = $verdict_replay + $verdict_interest;
    if      ($verdict_collected >  30 and $bad_runs > 0.7 * $verdict_collected) {
        say("INFO: $verdict_collected RQG tests finished and bad run quota 0.7 exceeded.");
        return 1;
    } elsif ($verdict_collected >  50 and $bad_runs > 0.5 * $verdict_collected) {
        say("INFO: $verdict_collected RQG tests finished and bad run quota 0.5 exceeded.");
        return 1;
    } elsif ($verdict_collected > 100 and $bad_runs > 0.3 * $verdict_collected) {
        say("INFO: $verdict_collected RQG tests finished and bad run quota 0.3 exceeded.");
        return 1;
    } else {
        return 0;
    }
}


sub reactivate_orders {
    push @try_queue, sort {$a <=> $b} keys %try_replayer_hash;
    push @try_queue, sort {$a <=> $b} keys %try_over_hash;     undef %try_over_hash;
    push @try_queue, sort {$a <=> $b} keys %try_over_bl_hash;  undef %try_over_bl_hash;
    say("DEBUG: Batch::reactivate_orders: \@try_queue refilled with finished orders up to " .
        scalar @try_queue . " Elements.") if Auxiliary::script_debug("B3");
}

# Certain routines which are based on routines with the same name and located in Auxiliary.pm.
# --------------------------------------------------------------------------------------------
# The important difference is that we perform an emergency_exit in order to minimize possible
# future trouble on the testing box like
# - space consumed in general vardir (usually tmpfs of small size)
# - further running MariaDB server which consume ressources and block ports etc.
#
sub copy_file {
# Basics::copy_file makes all checks and returns
# STATUS_OK or STATUS_FAILURE

    my ($source_file, $target_file) = @_;
    if (Basics::copy_file($source_file, $target_file)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Copy operation failed. Will ask for emergency exit. " .
            Basics::exit_status_text($status));
        emergency_exit($status);
    }
}

sub rename_file {
# Basics::rename_file makes all checks and returns
# STATUS_OK or STATUS_FAILURE

    my ($source_file, $target_file) = @_;
    if (Basics::rename_file($source_file, $target_file)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Rename operation failed. Will ask for emergency exit. " .
            Basics::exit_status_text($status));
        emergency_exit($status);
    }
}

sub make_file {
# Basics::make_file makes all checks and returns
# STATUS_OK or STATUS_FAILURE

    my ($file_to_create, $string) = @_;
    if (Basics::make_file($file_to_create, $string)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: File create and write operation failed. Will ask for emergency exit. " .
            Basics::exit_status_text($status));
        emergency_exit($status);
    }
}

sub append_string_to_file {
# Basics::append_string_to_file makes all checks and returns
# STATUS_OK or STATUS_FAILURE
# We prepend here aborting all ongoing tests.

    my ($file, $string) = @_;
    if (Basics::append_string_to_file($file, $string)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Write to file operation failed. Will ask for emergency exit. " .
            Basics::exit_status_text($status));
        emergency_exit($status);
    }
}

sub write_result {
    my ($line) = @_;
    if (not defined $line) {
        Carp::cluck("INTERNAL ERROR: line is undef.");
        my $status = STATUS_INTERNAL_ERROR;
        emergency_exit($status);
    }
    if (not defined $result_file) {
        Carp::cluck("INTERNAL ERROR: result_file is undef.");
        my $status = STATUS_INTERNAL_ERROR;
        emergency_exit($status);
    }
    append_string_to_file($result_file, $line);
}

sub write_setup {
    my ($line) = @_;
    if (not defined $line) {
        Carp::cluck("INTERNAL ERROR: line is undef.");
        my $status = STATUS_INTERNAL_ERROR;
        emergency_exit($status);
    }
    if (not defined $setup_file) {
        Carp::cluck("INTERNAL ERROR: setup_file is undef.");
        my $status = STATUS_INTERNAL_ERROR;
        emergency_exit($status);
    }
    append_string_to_file($setup_file, $line);
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
        Carp::cluck("ERROR: Auxiliary::get_string_after_pattern failed.");
        emergency_exit($status);
    } elsif ('' eq $value) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        # There might be cases where the line does not exist and than its on the
        # caller to decide if its a failure or not. But at least warn.
        Carp::cluck("WARN: Auxiliary::get_string_after_pattern returned ''.");
        return '';
    } else {
        return $value;
    }
}


#==========================================================

my $stop_on_replay;
sub check_and_set_stop_on_replay {
    ($stop_on_replay) = @_;
    if (not defined $stop_on_replay) {
        $stop_on_replay = MAX_BATCH_STARTS;
    }
    say("INFO: stop_on_replay = $stop_on_replay");
}

sub process_finished_runs {
    for my $worker_num (1..$workers_max) {
        next if -1 != $worker_array[$worker_num][WORKER_PID];
        my $verdict  = $worker_array[$worker_num][WORKER_VERDICT];
        my $order_id = $worker_array[$worker_num][WORKER_ORDER_ID];
        if (defined $verdict) {
            # FIXME: Isn't that rather WORKER_PID == -1 ?
            # VERDICT_VALUE | State + reaction
            # --------------+-------------------------------------------------------------------
            #     defined   | State: Process of RQG Worker just reaped + verdict + save ...
            #               | Register result, react on result + wipe worker_array entry
            # not defined   | RQG Worker is active or inactive
            #               | Nothing to do
            my ($status,$action);
            my $total_runtime = $worker_array[$worker_num][WORKER_END] -
                                $worker_array[$worker_num][WORKER_START];
            if (-1 == $worker_array[$worker_num][WORKER_START]) {
                # A RQG run died in Phase init -> Verdict will be init too.
                # Real life example:
                # I edited rqg.pl and made there a mistake in perl syntax.
                $total_runtime = 0;
            }
            my $extra_info = $worker_array[$worker_num][WORKER_V_INFO];
            if (defined $worker_array[$worker_num][WORKER_STOP_REASON]) {
                $extra_info = $worker_array[$worker_num][WORKER_STOP_REASON];
                say("DEBUG: order_id $order_id Reporting WORKER_STOP_REASON instead of " .
                    "WORKER_V_INFO.") if Auxiliary::script_debug("B4");
            }
            my @result_record = (
                    $worker_num,
                    $worker_array[$worker_num][WORKER_ORDER_ID],
                    $worker_array[$worker_num][WORKER_VERDICT],
                    $extra_info,
                    $worker_array[$worker_num][WORKER_LOG],
                    $total_runtime,
                    $worker_array[$worker_num][WORKER_EXTRA1],
                    $worker_array[$worker_num][WORKER_EXTRA2],
                    $worker_array[$worker_num][WORKER_EXTRA3],
                    $worker_array[$worker_num][WORKER_COMMAND],
            );
            if      ($batch_type eq BATCH_TYPE_COMBINATOR) {
                $action = Combinator::register_result(@result_record);
                # Maintaining the setup file is done im Combinator::register_result.
            } elsif ($batch_type eq BATCH_TYPE_RQG_SIMPLIFIER) {
                $action = Simplifier::register_result(@result_record);
            } else {
                emergency_exit(STATUS_CRITICAL_FAILURE,
                    "INTERNAL ERROR: The batch type '$batch_type' is unknown. ");
            }
            # For debugging
            # dump_try_hashes();
            update_extra_info_hash($verdict . ' -- ' . $extra_info);
            # FIXME maybe:
            # If Simplifier and we go with archiving and we have already an archive from some
            # previous run which hit the problem than delete that archive (but not its log).
            # For debugging
            if (0) {
                my $fat_string = get_extra_info_hash("DEBUG:");
                say($fat_string);
            }

            if ( not defined $action or $action eq '' ) {
                emergency_exit($status,
                               "ERROR: register_result returned an action in (undef, ''). " .
                               Basics::exit_status_text($status));
            } else {
                # Combinator and Simplifier could tell what to do next.
                if      ($action eq REGISTER_GO_ON)    {
                    # All is ok. Just go on is required.
                } elsif ($action eq REGISTER_SOME_STOPPED) {
                    if (1 > $give_up) {
                        $give_up = 1;
                    }
                } elsif ($action eq REGISTER_END)        {
                    stop_workers(STOP_REASON_WORK_FLOW . ' 4');
                    if (2 > $give_up) {
                        $give_up = 2;
                    }
                } else {
                    $status = STATUS_INTERNAL_ERROR;
                    $give_up = 3;
                    emergency_exit($status,
                                   "INTERNAL ERROR: register_result returned the unknown " .
                                   "action '$action'. " . Basics::exit_status_text($status));
                }
            }
            worker_reset($worker_num);
            if ($stop_on_replay <= $verdict_replay and $verdict eq Verdict::RQG_VERDICT_REPLAY) {
                say("INFO: OrderID $order_id achieved the verdict '$verdict' and stop_on_replay " .
                    "(number of replaying runs) is reached. Giving up.");
                stop_workers(STOP_REASON_WORK_FLOW . ' 5');
                if (2 > $give_up) {
                    $give_up = 2;
                }
            }
        }
    }
} # End of sub process_finished_runs

sub help_archiving {
    print(
    "\nSorry, under construction and partially different or not yet implemented.\n\n"              .
    "Default\n"                                                                                    .
    "      What you get in case you do not assign some corresponding --<parameter>=<value>.\n"     .
    "  will be taken according to their setting with absolute path or relative to the current "    .
    "Description currently missing. Sorry.\n");
}

sub free_memory {
    %extra_info_hash =    ();
    @worker_array =       ();
    @order_array =        ();
    %try_first_hash =     ();
    @try_queue =          ();
    %try_over_bl_hash =   ();
    %try_over_hash =      ();
    %try_replayer_hash =  ();
    %try_all_hash =       ();
    %try_never_hash =     ();
    %try_exhausted_hash = ();
}

my $rqg_log_length;
sub get_rqg_log_length {
    my ($workdir) = @_;

    my $who_am_i = Basics::who_am_i();

    if (not defined $workdir) {
        my $status = STATUS_INTERNAL_ERROR;
        say("INTERNAL ERROR: $who_am_i workdir is undef. " .
            Basics::exit_status_text($status));
        safe_exit($status);
    }
    if (not defined $rqg_log_length) {
        # Example: /data/results/1651169831/000000/rqg.log
        #          <------ $workdir ------> <WNO->
        $rqg_log_length = length($workdir)
                          + 2 # For the slashes
                          + RQG_NO_LENGTH
                          + length('/rqg.log');
    }
    return $rqg_log_length;
}

1;

