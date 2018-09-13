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

package Combinator;

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
use GenTest;
use GenTest::Random;
use GenTest::Constants;
use Getopt::Long;
use Data::Dumper;

my $script_debug = 1;

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
my @order_array = ();
# EFFORTS_INVESTED
# Number or sum of runtimes of executions which finished regular
use constant ORDER_EFFORTS_INVESTED => 0;
# ORDER_EFFORTS_LEFT
# Number or sum of runtimes of possible executions in future which maybe have finished regular.
# Example: rqg_batch will not pick some order with ORDER_EFFORTS_LEFT <= 0 for execution.
use constant ORDER_EFFORTS_LEFT     => 1;
# ORDER_PROPERTY1
# - The grammar rule to be attacked.
use constant ORDER_PROPERTY1        => 2;
# ORDER_PROPERTY2
# - The simplification like remove "UPDATE ...." which has to be tried.
use constant ORDER_PROPERTY2        => 3;
use constant ORDER_PROPERTY3        => 4;


my $config_file;
my $config_file_copy_rel = "combinations.cc";
my $result_file;
my $start_combination;
our $combinations; # Otherwise the 'eval' in the sub 'init' makes trouble.
my $seed;
my $workdir;
my $noshuffle;
my $trials;
my $exhaustive;
my $stop_on_replay;
my $prng;
my $comb_count;
# Name of the convenience symlink if symlinking supported by OS
my $symlink = "last_batch_workdir";

# FIXME: Are these variables used?
my $next_order_id    = 1;
$| = 1;

1;

sub init {
    ($config_file, $workdir, $seed, $exhaustive, $noshuffle, $start_combination,
     $trials, $stop_on_replay) = @_;
    # Based on the facts that
    # - Combinator/Simplifier init gets called before any Worker is running
    # - this init will be never called again
    # we can run safe_exit($status) and do not need to initiate an emergency_exit.
    # FIXME:
    # Maybe return ($status, $action) like register_result and than we could reinit
    # if useful and do other wild stuff.
    #

    Carp::cluck("DEBUG: Combinator::init : Entering routine with variables " .
                "(config_file, workdir, seed, exhaustive, noshuffle)") if $script_debug;
    # Check the easy stuff first.
    if (not defined $config_file) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNALE ERROR: Combinator::init : config file is undef. " .
                    Auxiliary::exit_status_text($status));
        safe_exit($status);
    }
    if (not -f $config_file) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Combinator::init : The config file '$config_file' does not exist or is not " .
            "a plain file. " . Auxiliary::exit_status_text($status));
        safe_exit($status);
    }

    if (not defined $workdir) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNALE ERROR: Combinator::init : workdir is undef. " .
                    Auxiliary::exit_status_text($status));
        safe_exit($status);
    }
    if (not -d $workdir) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Combinator::init : The workdir '$workdir' does not exist or is not " .
            "a directory. " . Auxiliary::exit_status_text($status));
        safe_exit($status);
    }

    my $config_file_copy = $workdir . "/" . $config_file_copy_rel;
    if (not File::Copy::copy($config_file, $config_file_copy)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Copying the config file '$config_file' to '$config_file_copy' failed : $!. " .
            Auxiliary::exit_status_text($status));
        safe_exit($status);
    }

    # We work with the copy only!
    if (not open (CONF, $config_file_copy)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Combinator::init : Unable to open config file copy '$config_file_copy': $! " .
            Auxiliary::exit_status_text($status));
        safe_exit($status);
    }
    read(CONF, my $config_text, -s $config_file_copy);
    close(CONF);
    # For experiments:
    # $config_text = "Hello";
    eval ($config_text);
    if ($@) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Combinator::init : Unable to load config file copy '$config_file_copy': " .
            $@ . ' ' . Auxiliary::exit_status_text($status));
        safe_exit($status);
    }

    system("find $workdir") if $script_debug;

    # This handling of seed affects mainly the generation of random combinations.
    if (not defined $seed) {
        $seed = 1;
        say("INFO: seed (used for generation of combinations only) is not defined. " .
            "Setting it to the default 1.");
    }
    if ($seed eq 'time') {
        $seed = time();
    }
    say("INFO seed : $seed");
    $prng = GenTest::Random->new(seed => $seed);

    if (not defined $start_combination) {
        say("DEBUG: start-combination was not assigned. Setting it to the default 1.")
            if $script_debug;
        $start_combination = 1;
    }

    $comb_count = $#$combinations + 1;
    my $total      = 1;
    foreach my $comb_id (0..($comb_count - 1)) {
        $total *= $#{$combinations->[$comb_id]} + 1;
    }
    say("INFO: Number of sections to pick an entry from and combine : $comb_count");
    say("INFO: Number of possible combinations                      : $total");

    $result_file  = $workdir . "/result.txt";
    my $iso_ts = isoTimestamp();
    # FIXME: Add printing the Combinator setup (parameters given to current sub)
    my $header = "$iso_ts Combinator init ========================================\n"              .
                 "$iso_ts workdir                     : '$workdir'\n"                              .
                 "$iso_ts config_file (assigned)      : '$config_file'\n"                          .
                 "$iso_ts config file (copy used)     : '$config_file_copy_rel'\n"                 .
                 "$iso_ts seed (compute combinations) : $seed\n"                                   .
                 "$iso_ts exhaustive                  : $exhaustive\n"                             .
                 "$iso_ts noshuffle                   : $noshuffle\n"                              .
                 "$iso_ts start_combination           : $start_combination\n"                      .
                 "$iso_ts trials                      : $trials\n"                                 .
                 "$iso_ts stop_on_replay              : $stop_on_replay\n"                         .
                 "$iso_ts --------------------------------------------------------\n"              .
                 "$iso_ts | " . Batch::RQG_NO_TITLE        . " | " .
                                Verdict::RQG_VERDICT_TITLE . " | " .
                                Batch::RQG_LOG_TITLE       . " | " .
                                Batch::RQG_ORDERID_TITLE   . " | " .
                                "RunTime\n";
    if (STATUS_OK != Auxiliary::append_string_to_file ($result_file, $header)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Combinator::init : Writing into result file '$result_file' failed. " .
            Auxiliary::exit_status_text($status));
        safe_exit($status);
    }

} # End sub init

sub weg1 {

my $comb_start_time = time();


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
    $testname, $xml_output, $report_xml_tt, $report_xml_tt_type, $max_runtime,
    $report_xml_tt_dest, $force, $no_mask, $exhaustive,
    $workers, $servers, $noshuffle, $discard_logs, $help, $runner,
    $script_debug, $runid, $threads);

# my @basedirs    = ('', '');
my @basedirs;
my %results;
my @commands;
my $max_result    = 0;
my $epochcreadir;

$discard_logs  = 0;

my $opt_result = {};
sub help();

# FIXME:
# Should we enforce some rigid standardization like
# testname, xml_output, ... report_xml_tt_dest and similar
# are the task of rqg_batch.pl and not Combinator.pm.

if (not GetOptions(
    $opt_result,
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
           'parallel=i'                => \$workers,
           'runner=s'                  => \$runner,
           'stop_on_replay'            => \$stop_on_replay,
           'servers=i'                 => \$servers,
           'threads=i'                 => \$threads,
           'no-shuffle'                => \$noshuffle,
           'discard_logs'              => \$discard_logs,
           'discard-logs'              => \$discard_logs,
           'script_debug'              => \$script_debug,
           'runid:i'                   => \$runid,
                                                   )) {
    # Somehow wrong option.
    help();
    exit STATUS_ENVIRONMENT_FAILURE;
};

if (defined $help) {
   help();
   exit 0;
}

}

# if (not defined $script_debug) {
#     $script_debug = 0;
# } else {
#     $script_debug = 1;
#     say("DEBUG: script_debug is enabled.");
# }

# my $prng = GenTest::Random->new(seed => $seed);

my $trial_counter = 0;
my $next_comb_id  = 0;


my $trial_num = 1; # This is the number of the next trial if started at all.
                   # That also implies that incrementing must be after getting a valid command.

sub get_job {
    my $order_id;
    my $out_of_ideas;
    my $job;
    while (not defined $order_id) {
        say("DEBUG: Begin of loop for getting an order.");
        $order_id = Batch::get_order();
        if (defined $order_id) {
            say("DEBUG: Batch::get_order delivered order_id $order_id.");
            if (not order_is_valid($order_id)) {
                say("DEBUG: The order $order_id is no more valid.");
                $order_id = undef;
            } else {
                say("DEBUG: The order $order_id is valid.");
            }
        } else {
            say("DEBUG: Batch::get_order delivered an undef order_id.");
            if (not generate_orders()) {
                say("DEBUG: generate_orders delivered nothing.");
                $out_of_ideas = 1;
                say("DEBUG: Jump out of loop for getting an order.");
                last;
            }
        }
        say("DEBUG: End of loop for getting an order.") if $script_debug;
    }
    if ($script_debug) {
        if (defined $order_id) {
            say("DEBUG: OrderID is $order_id.");
        } else {
            if (not defined $out_of_ideas) {
                say("WARN: Neither OrderID nor $out_of_ideas is defined.");
            }
        }
    }

    if (not defined $order_id) {
        # @try_first_queue empty , @try_queue empty too and extending impossible.
        # == All possible orders were generated.
        #    Some might be in execution and all other must be in @try_over_queue.
        say("DEBUG: No order got") if $script_debug;
        return undef;
    } else {
        if (not defined $order_array[$order_id]) {
            my $status = STATUS_INTERNAL_ERROR;
            Carp::cluck("INTERNALE ERROR: Combinator::init : config file is undef. " .
                        "Will exit with status " . status2text($status) . "($status)");
            exit $status;
        }
        my $cl_snip = $order_array[$order_id][ORDER_PROPERTY1];
        return ($order_id, $cl_snip);
    }

} # End of get_job


## ----------------------------------------------------

# What is this trial counter now good for?
# my $trial_counter = 0;

my $trial_counter = 0;

sub doExhaustive {
    my ($level,@idx) = @_;
    if ($level < $comb_count) {
        my @alts;
        foreach my $i (0..$#{$combinations->[$level]}) {
            push @alts, $i;
        }
        $prng->shuffleArray(\@alts) if !$noshuffle;

        foreach my $alt (@alts) {
            push @idx, $alt;
            # doExhaustive($level + 1,@idx) if $trial_counter < $trials;
            doExhaustive($level + 1, @idx) if $next_order_id <= $trials;
            pop @idx;
        }
    } else {
        $trial_counter++;
        my @comb;
        foreach my $i (0 .. $#idx) {
            push @comb, $combinations->[$i]->[$idx[$i]];
        }
        my $comb_str = join(' ', @comb);
        # FIXME: next?
        next if $trial_counter < $start_combination;
        doCombination($trial_counter, $comb_str, "combination");
    }
}

## ----------------------------------------------------

sub doCombination {

    my ($trial_id, $comb_str, $comment) = @_;

    say("trial_id : $trial_id") if $script_debug;

    my $command = "$comb_str ";

    # Remove especially the \n.
    $command =~ s{[\t\r\n]}{ }sgio;

    if ($command ne '') {
        $next_comb_id++;

        # Protect the double quotes
        $command =~ s{"}{\\"}sgio;

        # We had in combinations.pl a remove repeated spaces.
        #   while ($command =~ s/\s\s/ /g) {};
        # But this is capable to destroy the black/whitelist_patterns assigned.
        # Fragments of orders like "--views     --validators=none     --redefine" are
        # ugly and make printouts too long.
        # Even a     $command =~ s{  *--}{ --}sg;   could destroy these patterns.
        # Heading spaces
        $command =~ s{^ *}{}sg;
        # Trailing spaces
        $command =~ s{ *$}{}sg;

        add_order($command, $trial_id, '_unused_');
        say("DEBUG: Order(s) generated.");
        return 1;
        $next_order_id++;
    } else {
        say("ALARM: command is empty.");
        return 0;
    }

}

##------------------------------------------------------

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
   "      rpl_batch.pl might stop (KILL) RQG runs because of technical reasons.\n"                 .
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
   "         Future improvement of rpl_batch.pl will reduce these risks drastic.\n\n"              .
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
   "--script_debug\n"                                                                              .
   "      Print additional detailed information about decisions made by rqg_batch.pl\n"            .
   "      and observations made during runtime.\n"                                                 .
   "      Debug functionality of other RQG parts like the RQG runner will be not switched!\n"      .
   "      Debug functionality of other RQG parts like the RQG runner will be not switched!\n"      .
   "      (Default) No additional information.\n"                                                  .
   "      Hint:\n"                                                                                 .
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
   "rpl_batch.pl will stop all active RQG runners, cleanup and give a summary.\n\n"                .
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
# Up till today nowher implemented stuff end
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

sub order_is_valid {
    my ($order_id) = @_;

    if (not defined $order_id) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNALE ERROR: Combinator::order_is_valid : order_id is undef. " .
                    "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }

    Carp::confess("INTERNAL ERROR: No or undef order_id assigned.") if not defined $order_id;
    say("DEBUG: Begin of loop for getting an order.");
    if ($order_array[$order_id][ORDER_EFFORTS_LEFT] <= 0) {
        return 0;
    } else {
        return 1;
    }
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

my $generate_calls = 0;
sub generate_orders {

    $generate_calls++;
    say("DEBUG: Number of generate_orders calls : $generate_calls") if $script_debug;
    Batch::dump_queues() if $script_debug;

    my $success = 0;
    if ($exhaustive) {
            doExhaustive(0);
    } else {
       # We generate and add exact one order.
       # Previous in : sub doRandom {
       my @comb;
       foreach my $comb_id (0..($comb_count - 1)) {
           my $n = $prng->uint16(0, $#{$combinations->[$comb_id]});
           $comb[$comb_id] = $combinations->[$comb_id]->[$n];
       }
       my $comb_str = join(' ', @comb);
       $success = doCombination($trial_num, $comb_str, "random trial");
    }

    if ($success) {
        dump_orders() if $script_debug;
        Batch::dump_queues() if $script_debug;
        return 1;
    } else {
        say("DEBUG: All possible orders were already generated. Will return 0.");
        return 0;
    }
}


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

    # push @Batch::try_queue, $order_id_now;
    Batch::add_order($order_id_now);
    print_order($order_id_now) if $script_debug;
}

my $arrival_number = 1;
sub register_result {
# order_id
# verdict
# runtime or current routine could extract runtime from log
# log
# Current could extract runtime
#
# Return
# - ~ OK
# - ~ STOP (kill all active RQG Worker), if we have here stop_on_replay?
# - ~ run emergency exit
#

    my ($order_id, $verdict, $saved_log_rel, $total_runtime) = @_;
    say("DEBUG: Combinator::register_result : OrderID : $order_id, Verdict: $verdict, " .
        "RQG log : '$saved_log_rel', total_runtime : $total_runtime");

    if      ($verdict eq Verdict::RQG_VERDICT_IGNORE   or
             $verdict eq Verdict::RQG_VERDICT_INTEREST or
             $verdict eq Verdict::RQG_VERDICT_REPLAY   or
             $verdict eq Verdict::RQG_VERDICT_INIT       ) {
        # Its most likely that any repetition will fail again.
        $order_array[$order_id][ORDER_EFFORTS_INVESTED]++;
        $order_array[$order_id][ORDER_EFFORTS_LEFT]--;
        Batch::add_to_try_over($order_id);
    } elsif ($verdict eq Verdict::RQG_VERDICT_STOPPED) {
        # Do nothing with the $order_array[$order_id][ORDER_EFFORTS_*].
        # We need to repeat this run.
        Batch::add_to_try_first($order_id);
    } else {
        say("INTERNAL ERROR: Final Verdict '$verdict' is not treated/unknown. " .
            "Will ask for an emergency_exit.");
        return (STATUS_INTERNAL_ERROR, Batch::REGISTER_GO_ON);
    }

    my $iso_ts = isoTimestamp();
    my $line   = "$iso_ts | " .
                 Auxiliary::lfill($arrival_number, Batch::RQG_NO_LENGTH) . " | " .
                 Auxiliary::rfill($verdict,Verdict::RQG_VERDICT_LENGTH)  . " | " .
                 Auxiliary::lfill($saved_log_rel, Batch::RQG_LOG_LENGTH) . " | " .
                 Auxiliary::lfill($order_id, Batch::RQG_ORDERID_LENGTH)  . " | " .
                 Auxiliary::lfill($total_runtime, Batch::RQG_ORDERID_LENGTH) . "\n";
    if (STATUS_OK != Auxiliary::append_string_to_file ($result_file, $line)) {
        # FIXME: Replace with return
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Combinator::init : Writing into result file '$result_file' failed. " .
            "Will ask for an emergency_exit.");
        return ($status, undef);
    }

    $arrival_number++;

    if ($stop_on_replay and $verdict eq Verdict::RQG_VERDICT_REPLAY) {
        return (STATUS_OK, Batch::REGISTER_END);
    } else {
        return (STATUS_OK, Batch::REGISTER_GO_ON);
    }

} # End sub register_result


1;
