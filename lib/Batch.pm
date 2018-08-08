#  Copyright (c) 2018, MariaDB Corporation Ab.
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


use GenTest::Constants;
use GenTest;
use File::Copy;
use Cwd;
use Auxiliary;
use Verdict;

# use constant STATUS_OK       => 0;
use constant STATUS_FAILURE    => 1; # Just the opposite of STATUS_OK

my $script_debug = 0;

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
#                  process and pointing to the workder of the current RQG batch run.
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
                "created.") if $script_debug;
        } else {
            say("ERROR: make_multi_runner_infrastructure : Creating the general workdir " .
                "$snip_all '$general_workdir' failed: $!. Will return undef.");
            return undef;
        }
    }

    my $workdir = $general_workdir . "/" . $run_id;
    # Note: In case there is already a directory '$workdir' than we just fail in mkdir.
    if (mkdir $workdir) {
        say("DEBUG: The workdir $snip_current '$workdir' created.") if $script_debug;
    } else {
        say("ERROR: Creating the workdir $snip_current '$workdir' failed: $!.\n " .
            "This directory must not exist in advance!\n" .
            "Will exit with STATUS_ENVIRONMENT_FAILURE");
        exit STATUS_ENVIRONMENT_FAILURE;
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
            say("DEBUG: The general vardir $snip_all '$general_vardir' created.") if $script_debug;
        } else {
            say("ERROR: make_multi_runner_infrastructure : Creating the general vardir " .
                "$snip_all '$general_vardir' failed: $!. Will return undef.");
            return undef;
        }
    }
    my $vardir = $general_vardir . "/" . $run_id;
    # Note: In case there is already a directory '$vardir' than we just fail in mkdir.
    if (mkdir $vardir) {
        say("DEBUG: The vardir $snip_current '$vardir' created.") if $script_debug;
    } else {
        say("ERROR: Creating the vardir $snip_current '$vardir' failed: $!.\n " .
            "This directory must not exist in advance!\n" .
            "Will exit with STATUS_ENVIRONMENT_FAILURE");
        exit STATUS_ENVIRONMENT_FAILURE;
    }

    # Convenience feature
    # -------------------
    # Make a symlink so that the last workdir used by some tool performing multiple RQG runs like
    #    combinations.pl, bughunt.pl, simplify_grammar.pl
    # is easier found.
    # Creating the symlink might fail on some OS (see perlport) but should not abort our run.
    unlink($symlink_name);
    my $symlink_exists = eval { symlink($workdir, $symlink_name) ; 1 };

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
# EFFORTS_INVESTED
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


# Picking some order for execution means
# - looking into several queues in some deterministic order
# - pick the first element in case there is one, otherwise look into the next queue or similar
# - an element picked gets removed
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
# - combinations
#   Orders where left over efforts <= 0 was reached get appended to @try_over_queue.
#   In case of
#       @try_first_queue and @try_queue empty
#       and all possible combinations were already generated
#       and no other limitation (example: maxruntime) was exceeded
#   the content of @try_over_queue gets sorted, the left over efforts of the orders get increased
#   and all these orders get moved to @try_queue. Direct after that operation @try_over_queue
#   is empty.
# - grammar simplification
#   Not yet decided.
my @try_over_queue;


# Name of the convenience symlink if symlinking supported by OS
my $symlink = "last_batch_workdir";

my $order_id_now = 0;
sub add_order {

    my ($order_property1, $order_property2, $order_property3) = @_;
    # FIXME: Check the input

    $order_id_now++;

    $order_array[$order_id_now][ORDER_EFFORTS_INVESTED] = 0;
    $order_array[$order_id_now][ORDER_EFFORTS_LEFT]     = 1;

    $order_array[$order_id_now][ORDER_PROPERTY1]        = $order_property1;
    $order_array[$order_id_now][ORDER_PROPERTY2]        = $order_property2;
    $order_array[$order_id_now][ORDER_PROPERTY3]        = $order_property3;

    push @try_queue, $order_id_now;
    print_order($order_id_now) if $script_debug;
}


sub print_order {
    my ($order_id) = @_;

    if (not defined $order_id) {
        say("INTERNAL ERROR: print_order was called with some not defined \$order_id.\n");
        # FIXME: Decide how to react.
    }
    my @order = @{$order_array[$order_id]};
    say("$order_id § " . join (' § ', @order));

}

sub dump_orders {
   say("DEBUG: Content of the order array ------------- begin");
   say("id § efforts_invested § efforts_left § property1 § property2 § property3");
   foreach my $order_id (1..$#order_array) {
      print_order($order_id);
   }
   say("DEBUG: Content of the order array ------------- end");
}

sub dump_queues {
    say("DEBUG: \@try_first_queue : " . join (' ', @try_first_queue));
    say("DEBUG: \@try_queue       : " . join (' ', @try_queue));
    say("DEBUG: \@try_later_queue : " . join (' ', @try_later_queue));
    say("DEBUG: \@try_over_queue  : " . join (' ', @try_over_queue));
}






# FIXME: Implement
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





1;

