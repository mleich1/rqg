# Copyright (c) 2018, 2020 MariaDB Corporation Ab.
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
#   - The immediate judging (based on status + text patterns) was extended to
#     the black/whitelist matching and moved into Verdict.pm.
#     The matching itself gets called by rqg.pl.
#   - The creation of archives + first cleanup are moved into rqg.pl too.
#   - The unification regarding storage places was extended and also moved
#     into rqg.pl.
# - combinations.pl
#   - The parallelization was improved and moved into rqg_batch.pl and other
#     modules.
#   - The combinations mechanism was partially modified and stays here.
# There we have GNU General Public License version 2 too and
# Copyright (c) 2008, 2011 Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2013, Monty Program Ab.
# Copyright (c) 2018, MariaDB Corporation Ab.
#

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
# use lib "$ENV{RQG_HOME}/lib";
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
# index is the id of creation in generate_order
#
# ORDER_EFFORTS_INVESTED
# Number or sum of runtimes of executions which finished regular
use constant ORDER_EFFORTS_INVESTED => 0;
#
# ORDER_EFFORTS_LEFT
# Number or sum of runtimes of possible executions in future which maybe have finished regular.
# Example: rqg_batch will not pick some order with ORDER_EFFORTS_LEFT <= 0 for execution.
use constant ORDER_EFFORTS_LEFT     => 1;
#
# ORDER_PROPERTY1
# Snip of the command line for the RQG runner.
use constant ORDER_PROPERTY1        => 2;
#
# ORDER_PROPERTY2 , comb_counter
# Example: start_combination = 2 , trials = 3
# comb_counter | order_id
#            1 | not stored because < start_combination
#            2 |        1
#            3 |        2
#            4 |        3
#
use constant ORDER_PROPERTY2        => 3;
#
# ORDER_PROPERTY3 , unused
use constant ORDER_PROPERTY3        => 4;


my $config_file;
my $config_file_copy_rel  = "combinations.cc";

# File for bookkeeping + easy overview about results achieved.
my $result_file;

our $combinations; # Otherwise the 'eval' in the sub 'init' makes trouble.
my $workdir;

# Maximum number of regular finished RQG runs (!= stopped)
my $trials;
# Maximum number of left over to be regular finished trials
my $left_over_trials;
use constant TRIALS_DEFAULT         => 99999;


# Parameters typical for Combinations runs
# ----------------------------------------
my $seed;
my $exhaustive;
my $start_combination;
my $noshuffle;

my $no_mask;
my $grammar_file;
my $threads;
my $prng;
my $comb_count;


# A string which should be in mid of the command line options when rqg_batch calls the RQG runner.
my $cl_snip_end = '';


# FIXME: Describe how this variable is used.
my $next_order_id = 1;
$| = 1;

1;

sub unset_variables {
    @order_array       = undef;
}

sub init {
    ($config_file, $workdir, my $verdict_setup) = @_;
    # Based on the facts that
    # - Combinator/Simplifier init gets called before any Worker is running
    # - this init will be never called again
    # we can run safe_exit($status) and do not need to initiate an emergency_exit.
    #
    my $who_am_i = "Combinator::init:";
    if (3 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: $who_am_i Three parameters " .
                    "(config_file, workdir, verdict_setup) are required.");
        safe_exit($status);
    }

    Carp::cluck("# " . isoTimestamp() . " DEBUG: $who_am_i Entering routine with variables " .
                "(config_file, workdir, verdict_setup)") if Auxiliary::script_debug("C1");

    # Check the easy stuff first.
    if (not defined $config_file) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: $who_am_i config file is undef. " .
                    Auxiliary::exit_status_text($status));
        safe_exit($status);
    }
    if (not -f $config_file) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i The config file '$config_file' does not exist or is not " .
            "a plain file. " . Auxiliary::exit_status_text($status));
        safe_exit($status);
    }

    if (not defined $workdir) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: $who_am_i workdir is undef. " .
                    Auxiliary::exit_status_text($status));
        safe_exit($status);
    }
    if (not -d $workdir) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i The workdir '$workdir' does not exist or is not " .
            "a directory. " . Auxiliary::exit_status_text($status));
        safe_exit($status);
    }

    if (not defined $verdict_setup or '' eq $verdict_setup) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i \$verdict_setup is undef or '' " .
            Auxiliary::exit_status_text($status));
        safe_exit($status);
    }


# ---------------------------------------------

    my $duration;

    say("DEBUG: $who_am_i Command line content left over after being processed by rqg_batch.pl : " .
        join(" ", @ARGV)) if Auxiliary::script_debug("S4");

    # Read the command line options which are left over after being processed by rqg_batch.
    # -------------------------------------------------------------------------------------
    # Hints:
    # 1. Code                       | Command line        |  Impact
    #    'variable=s' => \$variable   --variable= --var2     --> $variable is undef
    #    'variable:s' => \$variable   --variable= --var2     --> $variable is defined and ''
    # 2. rqg_batch.pl does not process the config file content.
    my $options = {};
    Getopt::Long::Configure('pass_through');
    if (not GetOptions(
        $options,
    #   'help'                      => \$help,                  # Swallowed and handled by rqg_batch. Only there?
    #   'type=s'                    => \$type,                  # Swallowed and handled by rqg_batch
    #   'config=s'                  => \$config_file,           # Swallowed and checked by rqg_batch. Got here as parameter
####    'basedir=s'                 => \$basedirs[0],
    #   'basedir1=s'                => \$basedirs[1],           # Swallowed and handled by rqg_batch
    #   'basedir2=s'                => \$basedirs[2],           # Swallowed and handled by rqg_batch
    #   'basedir3=s'                => \$basedirs[3],           # Swallowed and handled by rqg_batch
    #   'workdir=s'                 => \$workdir,               # Swallowed and handled by rqg_batch. Got here as parameter
    #   'vardir=s'                  => \$vardir,                # Swallowed and handled by rqg_batch
    #   'build_thread=i'            => \$build_thread,          # Swallowed and handled by rqg_batch
        'trials=i'                  => \$trials,                # Handled here (max no of finished trials)
        'duration=i'                => \$duration,              # Handled here
        'seed=s'                    => \$seed,                  # Handled here
    #   'force'                     => \$force,                 # Swallowed and handled by rqg_batch
        'no-mask'                   => \$no_mask,               # Rather handle here
        'grammar=s'                 => \$grammar_file,          # Handle here. Requirement caused by Simplifier
    #   'gendata=s'                 => \$gendata,               # Rather handle here
    #   'testname=s'                => \$testname,              # Swallowed and handled by rqg_batch
    #   'xml-output=s'              => \$xml_output,            # Swallowed and handled by rqg_batch
    #   'report-xml-tt'             => \$report_xml_tt,         # Swallowed and handled by rqg_batch
    #   'report-xml-tt-type=s'      => \$report_xml_tt_type,    # Swallowed and handled by rqg_batch
    #   'report-xml-tt-dest=s'      => \$report_xml_tt_dest,    # Swallowed and handled by rqg_batch
        'run-all-combinations-once' => \$exhaustive,            # Handled here
        'start-combination=i'       => \$start_combination,     # Handled here
        'no-shuffle'                => \$noshuffle,             # Handled here
    #   'max_runtime=i'             => \$max_runtime,           # Swallowed and handled by rqg_batch
                                                                # Should rqg_batch ask for summary ?
    #   'dryrun=s'                  => \$dryrun,                # Swallowed and handled by rqg_batch
    #   'no-log'                    => \$noLog,                 # Swallowed and handled by rqg_batch
    #   'parallel=i'                => \$workers,               # Swallowed and handled by rqg_batch
    # runner
    # Having a --runner=<value> in a cc file + rqg_batch transforms that finally to a valid call
    # of that RQG runner is thinkable.
    # But why going with that complexity just for allowing to have a crowd of RQG runs with
    # partially differing RQG runners?
    # A user could also distribute these runs over several rqg_batch.pl calls with differing config files.
    #   'runner=s'                  => \$runner,                # Swallowed and handled by rqg_batch
    #   'stop_on_replay'            => \$stop_on_replay,        # Swallowed and handled by rqg_batch
    #   'servers=i'                 => \$servers,               # Swallowed and handled by rqg_batch
        'threads=i'                 => \$threads,               # Handled here (placed in cl_snip)
    #   'discard_logs'              => \$discard_logs,          # Swallowed and handled by rqg_batch
    #   'discard-logs'              => \$discard_logs,          # Swallowed and handled by rqg_batch
    #   'script_debug=s'            => \$script_debug,          # Swallowed and handled by rqg_batch
    #   'runid:i'                   => \$runid,                 # No use here
    #   'algorithm',                                            # For simplifier

                                                       )) {
        # Somehow wrong option.
        help();
        my $status = STATUS_ENVIRONMENT_FAILURE;
        safe_exit($status);
    };
    my $argv_remain = join(" ", @ARGV);
    if (defined $argv_remain and $argv_remain ne '') {
        say("WARN: $who_am_i The following command line content is left over ==> gets ignored. " .
            "->$argv_remain<-");
    }

    # We work with the copy only!
    if (not open (CONF, $config_file)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i Unable to open config file copy '$config_file': $! " .
            Auxiliary::exit_status_text($status));
        safe_exit($status);
    }
    read(CONF, my $config_text, -s $config_file);
    close(CONF);

    # For experiments:
    # $config_text = "Hello";
    eval ($config_text);
    if ($@) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i Unable to load config file copy '$config_file': " .
            $@ . ' ' . Auxiliary::exit_status_text($status));
        safe_exit($status);
    }

    if (defined $grammar_file and $grammar_file ne '') {
        $cl_snip_end .= " --grammar=" . $grammar_file;
    }
    if (defined $duration and $duration != 0) {
        $cl_snip_end .= " --duration=" . $duration;
    }
    if (defined $threads and $threads != 0) {
        $cl_snip_end .= " --threads=" . $threads;
    }
    if (defined $no_mask) {
        $cl_snip_end .= " --no_mask";
    }

    # seed affects mainly the generation of random combinations.
    # Auxiliary::calculate_seed writes a message about
    # - writes a message about assigned and computed setting of seed
    #   and returns the computed value if all is fine
    # - writes a message about the "defect" and some help and returns undef if the value assigned to
    #   seed is not supported
    $seed = Auxiliary::calculate_seed($seed);
    if (not defined $seed) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        safe_exit($status);
    }
    say("INFO: The seed value is used for generation of combinations only.");

    $prng = GenTest::Random->new(seed => $seed);

    if (not defined $start_combination) {
        say("DEBUG: start-combination was not assigned. Setting it to the default 1.")
            if Auxiliary::script_debug("C1");
        $start_combination = 1;
    }

    $comb_count = $#$combinations + 1;
    my $total   = 1;
    foreach my $comb_id (0..($comb_count - 1)) {
        $total *= $#{$combinations->[$comb_id]} + 1;
    }
    say("INFO: Number of sections to pick an entry from and combine : $comb_count");
    say("INFO: Number of possible combinations                      : $total");

    if (not defined $exhaustive) {
        $exhaustive = 0;
        say("DEBUG: exhaustive was not assigned. Setting it to the default $exhaustive.")
            if Auxiliary::script_debug("C1");
    }
    if (not defined $noshuffle) {
        $noshuffle = 0;
        say("DEBUG: noshuffle was not assigned. Setting it to the default $noshuffle.")
            if Auxiliary::script_debug("C1");
    }

    if (not defined $trials) {
        $trials = TRIALS_DEFAULT;
        say("DEBUG: trials was not assigned. Setting it to the default 99999.")
            if Auxiliary::script_debug("C1");
    }
    $left_over_trials = $trials;

    $result_file  = $workdir . "/result.txt";
    my $iso_ts = isoTimestamp();
    $verdict_setup =~ s/^/$iso_ts /gm;
    # FIXME: Add printing the Combinator setup (parameters given to current sub)
    my $header =
"$iso_ts Combinator init ================================================================================================\n" .
"$iso_ts workdir                        : '$workdir'\n"                                                                      .
"$iso_ts config_file (assigned)         : '$config_file'\n"                                                                  .
"$iso_ts config file (copy used)        : '$config_file_copy_rel'\n"                                                         .
"$iso_ts seed (compute combinations)    : $seed\n"                                                                           .
"$iso_ts exhaustive                     : $exhaustive\n"                                                                     .
"$iso_ts noshuffle                      : $noshuffle\n"                                                                      .
"$iso_ts start_combination              : $start_combination\n"                                                              .
"$iso_ts trials                         : $trials (Default " . TRIALS_DEFAULT . ")\n"                                        .
"$iso_ts ----------------------------------------------------------------------------------------------------------------\n" .
"$iso_ts options added to any RQG call  : $cl_snip_end\n"                                                                    .
"$iso_ts ----------------------------------------------------------------------------------------------------------------\n" .
"$iso_ts number of sections to combine  : $comb_count\n"                                                                     .
"$iso_ts max number of combinations     : $total\n"                                                                          .
"$iso_ts ----------------------------------------------------------------------------------------------------------------\n" .
"$iso_ts Verdict setup\n"                                                                                                    .
$verdict_setup                                                                                                               .
"$iso_ts ================================================================================================================\n" .
"$iso_ts | " . Batch::RQG_NO_TITLE        . " | " . Batch::RQG_WNO_TITLE       . " | " . Verdict::RQG_VERDICT_TITLE          .
       " | " . Batch::RQG_LOG_TITLE       .
       " | " . Batch::RQG_ORDERID_TITLE   . " | " . "RunTime"                  . " | " . "Extra info"         .         "\n" ;

    Batch::write_result($header);

    Batch::init_order_management();
    Batch::init_load_control();

    say("DEBUG: Leaving 'Combinator::init") if Auxiliary::script_debug("C6");

} # End sub init


my $trial_counter = 0;
my $next_comb_id  = 0;


my $trial_num = 1; # This is the number of the next trial if started at all.
                   # That also implies that incrementing must be after getting a valid command.

sub get_job {
    my $order_id;
    my $out_of_ideas;
    my $job;
    while (not defined $order_id) {
        say("DEBUG: Begin of loop for getting an order.") if Auxiliary::script_debug("C6");
        $order_id = Batch::get_order();
        if (defined $order_id) {
            say("DEBUG: Batch::get_order delivered order_id $order_id.")
                if Auxiliary::script_debug("C6");
            if (not order_is_valid($order_id)) {
                say("DEBUG: The order $order_id is no more valid.")
                    if Auxiliary::script_debug("C4");
                $order_id = undef;
            } else {
                say("DEBUG: The order $order_id is valid.")
                    if Auxiliary::script_debug("C6");
            }
        } else {
            say("DEBUG: Batch::get_order delivered an undef order_id.")
                if Auxiliary::script_debug("C5");
            if (not generate_orders()) {
                say("DEBUG: generate_orders delivered nothing. Setting out_of_ideas")
                     if Auxiliary::script_debug("C4");
                $out_of_ideas = 1;
                last;
            }
        }
        say("DEBUG: End of loop for getting an order.") if Auxiliary::script_debug("C6");
    }
    if (Auxiliary::script_debug("C6")) {
        if (defined $order_id) {
            say("DEBUG: OrderID is $order_id.");
        } else {
            if (not defined $out_of_ideas) {
                say("WARN: Neither OrderID nor $out_of_ideas is defined.");
            }
        }
    }

    if (not defined $order_id) {
        # %try_first_hash empty , %try_hash empty too and extending impossible.
        # This means all possible orders were generated. Some might be in execution and
        # all other must be in %try_over_hash or %try_over_bl_hash.
        say("DEBUG: No order got") if Auxiliary::script_debug("C5");
        return undef;
    } else {
        if (not defined $order_array[$order_id]) {
            my $status = STATUS_INTERNAL_ERROR;
            Carp::cluck("INTERNAL ERROR: order_id is not defined.");
            Batch::emergency_exit($status);
        }
        my $cl_snip = $order_array[$order_id][ORDER_PROPERTY1];
        return ($cl_snip . $cl_snip_end, $order_id);
    }

} # End of get_job


## ----------------------------------------------------

# What is this trial counter now good for?
# my $trial_counter = 0;

my $comb_counter = 0;

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
        $comb_counter++;
        my @comb;
        foreach my $i (0 .. $#idx) {
            push @comb, $combinations->[$i]->[$idx[$i]];
        }
        my $comb_str = join(' ', @comb);
        # FIXME: next?
        next if $comb_counter < $start_combination;
        doCombination($comb_counter, $comb_str, "combination");
    }
}

## ----------------------------------------------------

sub doCombination {

    my ($comb_counter, $comb_str, $comment) = @_;

#   say("comb_counter : $comb_counter") if $script_debug;

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

        add_order($command, $comb_counter, '_unused_');
        return 1;
        $next_order_id++;
    } else {
        say("ALARM: command is empty.");
        return 0;
    }

}

##------------------------------------------------------

sub help() {
#       'no-mask'                   => \$no_mask,               # Rather handle here
#       'grammar=s'                 => \$grammar_file,          # Handle here. Requirement caused by Simplifier
#       'no-shuffle'                => \$noshuffle,             # Handled here
   print(
   "\nSorry, under construction and partially different or not yet implemented.\n\n"               .
   "Purpose: Perform a batch of RQG runs with massive parallelization according to setup/config\n" .
   "         Be a replacement for combinations.pl, bughunt.pl, runall-trials.pl\n"                 .
   "Terms used:\n"                                                                                 .
   "combination string\n"                                                                          .
   "      A fragment of a RQG call generated by the Combinator (lib/Combinations.pm) based on "    .
   "config file content.\n"                                                                        .
   "      rqg_batch.pl might transform and especially append more settings depending on\n"         .
   "      content in command line and defaults.\n"                                                 .
   "      The final string is later used for calling the RQG runner.\n"                            .
   "Default\n"                                                                                     .
   "      What you get in case you do not assign some corresponding --<parameter>=<value>.\n"      .
   "Regular finished RQG run\n"                                                                    .
   "      A RQG run which ended regular with success or failure (crash, perl error ...).\n"        .
   "      rpl_batch.pl might stop (KILL) RQG runs because of technical reasons.\n"                 .
   "      Such stopped runs will be restarted with the same setup as soon as possible.\n"          .
   "      And they do not count as regular runs.\n"                                                .
   "\n"                                                                                            .
   "--run-all-combinations-once\n"                                                                 .
   "      Generate a deterministic sequence of combinations.\n"                                    .
   "      The number of combinations limits the maximum number of trials!\n"                       .
   "      --start-combination=<m>\n'"                                                              .
   "             Start the execution with the m'th combination.\n"                                 .
   "--trials=<n>\n"                                                                                .
   "      rqg_batch.pl will exit if this number of regular finished trials(RQG runs) is reached.\n".
   "      n = 1 --> Write the output of the RQG runner to screen and do not cleanup at end.\n"     .
   "                Maybe currently not working or in future removed.\n"                           .
   "--seed=...\n"                                                                                  .
   "      Seed value used here for generation of the random combinations only.\n"                  .
   "      Default: 1\n"                                                                            .
   "      The value for seed finally taken by the RQG runner is not in scope of the Combinator.\n" .
   "ALLOWED but IGNORED because of compatibility reasons : --no_mask\n"                            .
   "      This option was supported by combinations.pl which also manipulated the masking\n"       .
   "      under certain conditions. '--no_mask' served mostly for preventing this manipulation.\n" .
   "   Combinator just 'dices' the combination string which than might contain settings for\n"     .
   "   mask/mask_level and passes these settings to the RQG runner.\n\n"                           .
   "FIXME: Comment about --no_shuffle\n"                                                           .
   "-------------------------------------------------------------------------------------------\n" .
   "Group of parameters which get appended to the combination string returned to rqg_batch.pl\n"   .
   "and than placed in the RQG runner call line.\n"                                                .
   "For their meaning please look into the output of '<RQG runner> --help'.\n"                     .
   "--duration=<n>\n"                                                                              .
   "--gendata=...\n"                                                                               .
   "--grammar=...\n"                                                                               .
   "--threads=<n>\n"                                                                               .
   "-------------------------------------------------------------------------------------------\n" .
   "How to see which calls to the RQG runner would be generated?\n"                                .
   "   rqgbatch.pl --dryrun=replay <further settings>\n"                                           .
   "-------------------------------------------------------------------------------------------\n" .
   "How to cause some non-random run with fixed range of combinations covered?\n"                  .
   "Assign\n"                                                                                      .
   "   --run-all-combinations-once --> Generation of a deterministic sequence of combinations\n"   .
   "with optional\n"                                                                               .
   "   --start_combination=<m> --> Omit trying the first <m - 1> combinations.\n"                  .
   "-------------------------------------------------------------------------------------------\n" .
   "How to limit or extend the range of combinations covered?\n"                                   .
   "   Assign some corresponding value to 'trials' and/or max_runtime.\n"                          .
   "   In case none of them is set than the rqg_batch.pl run ends after the RQG run with the \n"   .
   "   last not yet tried combination has finished regular.\n"                                     .
   "-------------------------------------------------------------------------------------------\n" .
   "\n");

# What is set to comment was somewhere in combinations.pl.
# But rqg.pl will handle the number of servers and the required basedirs too and most hopefully
# better.
#  foreach my $s (1..$servers) {
#     $command .= " --basedir" . $s . "=" . $basedirs[$s-1] . " " if $basedirs[$s-1] ne '';
#  }

}

sub order_is_valid {
    my ($order_id) = @_;

    if (not defined $order_id) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: Combinator::order_is_valid : order_id is undef.");
        Batch::emergency_exit($status);
    }
    if ($order_array[$order_id][ORDER_EFFORTS_LEFT] <= 0) {
        say("DEBUG: Order with id $order_id is no more valid.") if Auxiliary::script_debug("C4");
        return 0;
    } else {
        return 1;
    }
}

sub print_order {

    my ($order_id) = @_;

    if (not defined $order_id) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: Combinator::print_order : order_id is undef.");
        Batch::emergency_exit($status);
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
    say("DEBUG: Number of generate_orders calls : $generate_calls")
        if Auxiliary::script_debug("C5");
    Batch::dump_try_hashes() if Auxiliary::script_debug("C5");

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
        dump_orders() if Auxiliary::script_debug("C5");
        Batch::dump_try_hashes() if Auxiliary::script_debug("C5");
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

    Batch::add_order($order_id_now);
    print_order($order_id_now) if Auxiliary::script_debug("C5");
}

my $arrival_number   = 1;
sub register_result {
# order_id
# verdict
# runtime or current routine could extract runtime from log
#
# Return
# - STATUS_OK, Batch::REGISTER_*(== What rqg_batch.pl should do next)
#   Its not yet decided if the return will contain a status in future.
# - ~ run emergency exit
#

    my ($worker_number, $order_id, $verdict, $extra_info, $saved_log_rel, $total_runtime) = @_;
    say("DEBUG: Combinator::register_result : OrderID : $order_id, Verdict: $verdict, " .
        "Extra info: $extra_info, RQG log : '$saved_log_rel', total_runtime : $total_runtime")
        if Auxiliary::script_debug("C4");

    if      ($verdict eq Verdict::RQG_VERDICT_IGNORE           or
             $verdict eq Verdict::RQG_VERDICT_IGNORE_STATUS_OK or
             $verdict eq Verdict::RQG_VERDICT_IGNORE_BLACKLIST or
             $verdict eq Verdict::RQG_VERDICT_INTEREST         or
             $verdict eq Verdict::RQG_VERDICT_REPLAY           or
             $verdict eq Verdict::RQG_VERDICT_INIT               ) {
        # Its most likely that any repetition will fail again.
        $order_array[$order_id][ORDER_EFFORTS_INVESTED]++;
        $order_array[$order_id][ORDER_EFFORTS_LEFT]--;
        Batch::add_to_try_over($order_id);
        $left_over_trials--;
    } elsif ($verdict eq Verdict::RQG_VERDICT_IGNORE_STOPPED) {
        # Do nothing with the $order_array[$order_id][ORDER_EFFORTS_*].
        # We need to repeat this run.
        Batch::add_to_try_first($order_id);
    } else {
        Carp::cluck("INTERNAL ERROR: Final Verdict '$verdict' is not treated/unknown.");
        my $status = STATUS_INTERNAL_ERROR;
        Batch::emergency_exit($status);
    }

    my $iso_ts = isoTimestamp();
    my $line   = "$iso_ts | " .
                 Auxiliary::lfill($arrival_number, Batch::RQG_NO_LENGTH)     . " | " .
                 Auxiliary::lfill($worker_number, Batch::RQG_WNO_LENGTH)     . " | " .
                 Auxiliary::rfill($verdict,Verdict::RQG_VERDICT_LENGTH)      . " | " .
                 Auxiliary::lfill($saved_log_rel, Batch::RQG_LOG_LENGTH)     . " | " .
                 Auxiliary::lfill($order_id, Batch::RQG_ORDERID_LENGTH)      . " | " .
                 Auxiliary::lfill($total_runtime, Batch::RQG_ORDERID_LENGTH) . " | " .
                                  $extra_info                                . "\n";
    Batch::write_result($line);

    $arrival_number++;

    say("DEBUG: Combinator::register_result : left_over_trials : $left_over_trials")
        if Auxiliary::script_debug("C4");
    # Batch::check_try_hashes();
    if ($left_over_trials) {
        return Batch::REGISTER_GO_ON;
    } else {
        return Batch::REGISTER_END;
    }


} # End sub register_result


1;
