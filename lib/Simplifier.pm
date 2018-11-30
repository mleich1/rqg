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
#

package Simplifier;

# Note about history and future of this script
# --------------------------------------------
# The concept and code here is only in some portions based on
#    util/simplify-grammar.pl
# There we have GNU General Public License version 2 too and
# Copyright (c) 2008, 2011 Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2013, Monty Program Ab.
# Copyright (c) 2018, MariaDB Corporation Ab.
#
# The amount of parameters (call line + config file) is in the moment
# not that stable.
# On the long run the script rql_batch.pl will be extended and replace
# the current script.
#

use strict;
use warnings;
use lib 'lib';
use lib '../lib';
use DBI;
use Carp;
use Getopt::Long;
use Data::Dumper;

use GenTest;
use GenTest::Constants;
use GenTest::Grammar;
use Batch;
use Auxiliary;
use Verdict;
use GenTest::Properties;
use GenTest::Simplifier::Grammar_advanced; # We use the correct working simplifier only.
use Time::HiRes;

my $phase        = '';
my $phase_switch = 0;
# (Most probably) needed because of technical reasons.
use constant PHASE_SIMP_BEGIN       => 'simp_begin';
#
# Attempt to replay with the compactified initial grammar.
use constant PHASE_FIRST_REPLAY     => 'first_replay';
#
# Attempt to replay with the actual best replaying grammar and threads = 1,
use constant PHASE_THREAD1_REPLAY   => 'thread1_replay';
#
# Attempt to shrink the amount of transformers.
use constant PHASE_TRANSFORMER_SIMP => 'transformer_simp'; # Implementation later
#
# Attempt to shrink the amount of reporters.
use constant PHASE_REPORTER_SIMP    => 'reporter_simp';    # Implementation later
#
# Attempt to shrink the amount of validators.
use constant PHASE_VALIDATOR_SIMP   => 'validator_simp';   # Implementation later
#
# Attempt to shrink the actual best replaying grammar.
use constant PHASE_GRAMMAR_SIMP     => 'grammar_simp';
#
# Attempt to clone rules
# - containing more than one alternative/component
# - being used more than once
# within the actual best replaying grammar.
# In case this is not a no op than there must a PHASE_GRAMMAR_SIMP round follow.
use constant PHASE_GRAMMAR_CLONE    => 'grammar_clone';    # Implementation later
#
# Replace grammar language builtins like _digit and similar by rules doing the same.
# In case this is not a no op than there must a PHASE_GRAMMAR_SIMP round follow.
use constant PHASE_GRAMMAR_BUILTIN  => 'grammar_builtin';  # Implementation later
#
# Attempt to replay with the actual best replaying grammar.
use constant PHASE_FINAL_REPLAY     => 'final_replay';
#
# (Most probably) needed because of technical reasons.
use constant PHASE_SIMP_END         => 'simp_end';

# Attack_mode     --- not to be set from outside
# with (most probably) impact on
# - generate_order
# - validate_order
# - process_result
# - get_job   (deliver cl_snip for rqg.pl)
#
# rqg_batch extracts workdir/vardir/build thread/bwlists
# Simplifier + combinator do not to know that except workdir if at all.
# Simplifier + combinator work with Batch.pm and rqg_batch does not!!

# Grammar simplification algorithms
# ---------------------------------
my $algorithm;
use constant SIMP_ALGO_WEIGHT     => 'weight';
use constant SIMP_ALGO_RANDOM     => 'random';  # not yet implemented
use constant SIMP_ALGO_MASKING    => 'masking'; # not yet implemented

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
# EFFORTS_INVESTED
# Number of RQG runs for that orderid or sum of their runtimes
use constant ORDER_EFFORTS_INVESTED => 0;

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

my $workdir;

my $config_file;
my $config_file_copy_rel = "simplifier.cfg";

# File for bookkeeping + easy overview about results achieved.
my $result_file;

my $title_line_part =
       " | " . Batch::RQG_NO_TITLE        . " | " . Verdict::RQG_VERDICT_TITLE . " | " . Batch::RQG_LOG_TITLE                .
       " | " . Batch::RQG_ORDERID_TITLE   . " | " . "RunTime"                  . " | " . Batch::RQG_GRAMMAR_C_TITLE          .
       " | " . Batch::RQG_GRAMMAR_P_TITLE . "\n";

# Whatever trials
# ---------------
# Variable for assigning the maximum number of regular finished RQG runs (!= stopped)
# before giving up in case no replay was achieved.
# To be applied to certain phases like PHASE_*_REPLAY only.
my $trials;
# Default for maximum number of trials in these phases.
# Just to be used in case the user has not assigned a value via command line or config file.
use constant TRIALS_DEFAULT         => 30;
#
# Maximum number of left over to be regular finished trials.
# The value gets set when switching the phase.
my $left_over_trials;
#
# Maximum number of trials in the phase PHASE_GRAMMAR_SIMP.
#   The user cannot override that value via command line or config file.
#   Its just a high value for catching obvious "ill" simplification runs.
use constant TRIALS_SIMP            => 99999;

use constant QUERIES_DEFAULT        => 1000000;

# Parameters typical for Simplifier runs
# --------------------------------------
my $seed;

# my $no_mask;
my $grammar_file;

my $threads;
use constant THREADS_DEFAULT        => 10;

# Name of the convenience symlink if symlinking supported by OS
my $symlink = "last_batch_workdir";

# A string which should be in mid of the command line options when rqg_batch calls the RQG runner.
# 1. What is valid for all Simplification phases
my $cl_snip_all   = '';
# 2. What depends on the Simplification phases
my $cl_snip_phase = '';

my $duration;
use constant DURATION_DEFAULT           => 300;
my $duration_adaption;
use constant DURATION_ADAPTION_NONE     => 'None';
use constant DURATION_ADAPTION_MAX_MID  => 'MaximumMiddle';
use constant DURATION_ADAPTION_MAX      => 'Maximum';
use constant DURATION_ADAPTION_EXP      => 'Experimental';

my $grammar_flags;

my $parent_number = 0; # Contains the number of the next parent grammar to be generated.
my $parent_grammar;    # Contains the name (no path) of the last parent grammar generated.
my $grammar_string;
my $grammar_structure;
#
my $child_number  = 0;  # Contains the number of the next last child grammar to be generated.
my $child_grammar;      # Contains the name (no path) of the last child grammar generated.
#
my $best_grammar  = 'best_grammar.yy'; # The best of the replaying grammars.


# $ever_success
# -------------
# Set to 1 in case the problem was replayed.
# Used for deciding if to run certain phases of simplification at all or not.
# (at least in the moment theoretical) Example:
# In case we had no replay in the phase PHASE_FIRST_REPLAY than switching to certain other
# phases makes no sense.
# Up till now its unsure if the variable is really required.
my $ever_success = 0;


# Campaigns within the phase PHASE_GRAMMAR_SIMP and required variables
# ====================================================================
# $out_of_ideas
# -------------
# Some state within a grammar simplification campaign.
# Starting at some point all thinkable orders for simplifying some grammar were generated and
# this variable will be than set to 1.
my $out_of_ideas = 0;
#
# $campaign_success
# -----------------
# Set to
# - 0 when starting some campaign
# - incremented in case the problem was replayed within the current campaign.
# Used for deciding if to run some next campaign or not.
# Example:
# Phase is PHASE_GRAMMAR_SIMP
# In case we had during the last campaign (== Try to remove alternatives from grammar rules)
# success at all and we have tried all possible simplifications at least once tjan it makes
# sense to repeat such a campaign. This is especially important for concurrency bugs.
my $campaign_success = 0;
#
# $campaign_number
# ----------------
# Incremented whenever such a campaign gets started.
my $campaign_number  = 0;


# Additional parameters maybe being target of simplification
my @reporter_array;
my @transformer_array;
my @validator_array;


# Replay Runtime fifo
# Replay duration fifo


$| = 1;


sub init {
    ($config_file, $workdir) = @_;
    # Based on the facts that
    # - Combinator/Simplifier init gets called before any Worker is running
    # - this init will be never called again
    # we can run safe_exit($status) and do not need to initiate an emergency_exit.
    # FIXME:
    # Maybe return ($status, $action) like register_result and than we could reinit
    # if useful and do other wild stuff.
    #
    if (2 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: Simplifier::init : Two parameters " .
                    "(config_file, workdir) are required.");
        safe_exit($status);
    }

    Carp::cluck("# " . isoTimestamp() . " DEBUG: Simplifier::init : Entering routine with " .
                "variables (config_file, workdir).\n") if Auxiliary::script_debug("S1");

    # Check the easy stuff first.
    if (not defined $config_file) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNALE ERROR: Simplifier::init : config file is undef. " .
                    Auxiliary::exit_status_text($status));
        safe_exit($status);
    }
    if (not -f $config_file) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Simplifier::init : The config file '$config_file' does not exist or is not " .
            "a plain file. " . Auxiliary::exit_status_text($status));
        safe_exit($status);
    }

    if (not defined $workdir) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNALE ERROR: Simplifier::init : workdir is undef. " .
                    Auxiliary::exit_status_text($status));
        safe_exit($status);
    }
    if (not -d $workdir) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Simplifier::init : The workdir '$workdir' does not exist or is not " .
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

# ---------------------------------------------

    my $queries;

    say("DEBUG: Command line content left over after being processed by rqg_batch.pl : " .
        join(" ", @ARGV)) if Auxiliary::script_debug("S4");

    # Read the command line options which are left over after being processed by rqg_batch.
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
        'trials=i'                  ,                           # Handled here (max no of finished trials for certain phases only)
        'duration=i'                ,                           # Handled here
        'queries=i'                 ,                           # Handled here
#       'seed=s'                    => \$seed,                  # Handled(Ignored!) here
    #   'force'                     => \$force,                 # Swallowed and handled by rqg_batch
#         'no-mask'                   => \$no_mask,               # Rather handle here
        'grammar=s'                 ,                           # Handle here. Requirement caused by Simplifier
    #   'gendata=s'                 => \$gendata,               # Rather handle here
    #   'testname=s'                => \$testname,              # Swallowed and handled by rqg_batch
    #   'xml-output=s'              => \$xml_output,            # Swallowed and handled by rqg_batch
    #   'report-xml-tt'             => \$report_xml_tt,         # Swallowed and handled by rqg_batch
    #   'report-xml-tt-type=s'      => \$report_xml_tt_type,    # Swallowed and handled by rqg_batch
    #   'report-xml-tt-dest=s'      => \$report_xml_tt_dest,    # Swallowed and handled by rqg_batch
    #   'run-all-combinations-once' => \$exhaustive,            # For Combinator only
    #   'start-combination=i'       => \$start_combination,     # For Combinator only
    #   'no-shuffle'                => \$noshuffle,             # For Combinator only
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
        'threads=i'                 ,                           # Handled here (placed in cl_snip)
    #   'discard_logs'              => \$discard_logs,          # Swallowed and handled by rqg_batch
    #   'discard-logs'              => \$discard_logs,          # Swallowed and handled by rqg_batch
    #   'script_debug=s'            => \$script_debug,          # Swallowed and handled by rqg_batch
    #   'runid:i'                   => \$runid,                 # No use here
        'algorithm'                 ,                           # For grammar simplifier only
                                                       )) {
        # Somehow wrong option.
        # help_simplifier();
        my $status = STATUS_ENVIRONMENT_FAILURE;
        safe_exit($status);
    };
    my $argv_remain = join(" ", @ARGV);
    if (defined $argv_remain and $argv_remain ne '') {
        say("WARNING: The following command line content is left over ==> gets ignored. ->$argv_remain<-");
    }


    # Read the options found in config_file.
    # We work with the copy only!
    # config_file_copy
    #   'seed=s'                    => \$seed,                  # Handled here
    #   'no-mask'                   => \$no_mask,               # Rather handle here
    $options->{'config'} = $config_file_copy;
    my $config = GenTest::Properties->new(
        options     => $options,
        legal       => [
                    'grammar',                                  # Handled
#                   'redefine',
                    'grammar_flags',
#                   'gendata',
#                   'gendata_sql',
                    'rqg_options',
                    'validators',
                    'reporters',
                    'transformers',
                    'workdir',
                    'threads',                                  # Handled
                    'queries',                                  # Handled
                    'duration',                                 # Handled
                    'duration_adaption',                        # Handled
                    'trials',                                   # Handled
                    'algorithm',
                    'search_var_size',
                    'whitelist_statuses',
                    'whitelist_patterns',
                    'blacklist_statuses',
                    'blacklist_patterns',
        ],
        required    => [
                    'rqg_options',
        ],
        defaults    => {
                    'algorithm'         => SIMP_ALGO_WEIGHT,
                    'trials'            => TRIALS_DEFAULT,
                    'duration'          => DURATION_DEFAULT,
                    'queries'           => QUERIES_DEFAULT,
                    'threads'           => THREADS_DEFAULT,
                    'validators'        => 'none',
                    'grammar_flags'     => undef,
                    'duration_adaption' => DURATION_ADAPTION_MAX,
                    'search_var_size'   => 100000000,
        }
    );

    # $grammar (value taken from ARGV)
    # $config->grammar (value taken from config file top level variables)
    # $config->rqg_options->{grammar} (value taken from config file rqg_options section)

    $config->printProps();

    my $rqg_options_begin = $config->genOpt('--', 'rqg_options');
    $grammar_file = $config->grammar;
    if (defined $grammar_file and $grammar_file ne '') {
        say("DEBUG: Grammar '$grammar_file' was assigned via rqg_batch.pl call or " .
            "within config file top level. \n" .
            "DEBUG: Wiping all other occurrences of settings for grammar/redefine.");
        delete $config->rqg_options->{'grammar'};
        delete $config->rqg_options->{'redefine'};
    } else {
        $grammar_file = $config->rqg_options->{'grammar'};
        if (defined $grammar_file and $grammar_file ne '') {
            say("DEBUG: Grammar '$grammar_file' was assigned in config file rqg_option section. " .
                "Wiping all other occurrences of settings for grammar/redefine.");
            delete $config->rqg_options->{'grammar'};
            delete $config->rqg_options->{'redefine'};
        } else {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: Grammar neither via command line nor via config file assigned. " .
            Auxiliary::exit_status_text($status));
            safe_exit($status);
        }
    }
    # Note:
    # get_job returns some command line snip to the caller.
    # Around the end of that snip can be a ' --grammar=<dynamic decided grammar>'.
    # The grammar here is only the initial grammar at begin of simplification process.

    # $config->printProps();

    $trials = $config->trials;
    my $bad_trials = $config->rqg_options->{'trials'};
    if (defined $bad_trials) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: trials found between 'rqg_options'. This is wrong. Abort. " .
            Auxiliary::exit_status_text($status));
        safe_exit($status);
    }
    # Note:
    # This parameter is not part of the command line snip.

    $duration = $config->duration;
    if (defined $duration and $duration >= 0) {
        say("DEBUG: duration '$duration' was assigned via rqg_batch.pl call or " .
            "within config file top level. \n" .
            "DEBUG: Wiping all other occurrences of settings for duration.");
        delete $config->rqg_options->{'duration'};
    } else {
        $duration = $config->rqg_options->{'duration'};
        if (defined $duration and $duration >= 0) {
            say("DEBUG: duration '$duration' was assigned in config file rqg_option section. " .
                "Wiping all other occurrences of settings for duration.");
            delete $config->rqg_options->{'duration'};
        } else {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: duration neither via command line nor via config file assigned. " .
            Auxiliary::exit_status_text($status));
            safe_exit($status);
        }
    }
    $cl_snip_all .= " --duration=" . $duration;
    # Note:
    # This parameter itself is part of the command line snip.
    # But the value here is only the base for the computation of the
    # ' --duration=<dynamic decided value>' added to the end of that snip.

    $duration_adaption = $config->duration_adaption;
    my $bad_duration_adaption = $config->rqg_options->{'duration_adaption'};
    if (defined $bad_duration_adaption) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: duration_adaption found between 'rqg_options'. This is wrong. Abort. " .
            Auxiliary::exit_status_text($status));
        safe_exit($status);
    }
    # Note:
    # This parameter itself is not part of the command line snip.
    # But it has an impact during computation of the ' --duration=<dynamic decided value>'
    # added to the end of that snip.

    $queries = $config->queries;
    if (defined $queries and $queries >= 0) {
        say("DEBUG: queries '$queries' was assigned via rqg_batch.pl call or " .
            "within config file top level. \n" .
            "DEBUG: Wiping all other occurrences of settings for queries.");
        delete $config->rqg_options->{'queries'};
    } else {
        $queries = $config->rqg_options->{'queries'};
        if (defined $queries and $queries >= 0) {
            say("DEBUG: queries '$queries' was assigned in config file rqg_option section. " .
                "Wiping all other occurrences of settings for queries.");
            delete $config->rqg_options->{'queries'};
        } else {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: queries neither via command line nor via config file assigned. " .
            Auxiliary::exit_status_text($status));
            safe_exit($status);
        }
    }
    $cl_snip_all .= " --queries=" . $queries;
    # Note:
    # This parameter is part of the command line snip.

    $threads = $config->threads;
    if (defined $threads and $threads >= 0) {
        say("DEBUG: threads '$threads' was assigned via rqg_batch.pl call or " .
            "within config file top level. \n" .
            "DEBUG: Wiping all other occurrences of settings for threads.");
        delete $config->rqg_options->{'threads'};
    } else {
        $threads = $config->rqg_options->{'threads'};
        if (defined $threads and $threads >= 0) {
            say("DEBUG: threads '$threads' was assigned in config file rqg_option section. " .
                "Wiping all other occurrences of settings for threads.");
            delete $config->rqg_options->{'threads'};
        } else {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: threads neither via command line nor via config file assigned. " .
            Auxiliary::exit_status_text($status));
            safe_exit($status);
        }
    }
    $cl_snip_all .= " --threads=" . $threads;
    # Note:
    # This parameter is part of the command line snip.
    # ' --threads=$threads' added to the end of that snip except ' --threads=1' is
    # added from whatever reason.

    $algorithm = $config->algorithm;
    my $bad_algorithm = $config->rqg_options->{'algorithm'};
    if (defined $bad_algorithm) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: algorithm found between 'rqg_options'. This is wrong. Abort. " .
            Auxiliary::exit_status_text($status));
        safe_exit($status);
    }
    # Note:
    # This parameter itself is not part of the command line snip.

    # Add it in order to be sure that the grammar gets not mangled per mistake.
    $cl_snip_all .= " --no_mask";
    delete $config->rqg_options->{'no_mask'};
    delete $config->rqg_options->{'mask'};
    delete $config->rqg_options->{'mask_level'};

    # Add it in order to be sure that we work with maximum randomness.
    # This is especially important for PHASE_THREAD1_REPLAY where we go with thread=1.
    # Per experience there is also some smaller but not negligible impact if going with significant
    # higher number of threads.
    $cl_snip_all .= " --seed=random";
    delete $config->rqg_options->{'seed'};

    ###
    my $mysql_options = '';
    foreach my $val ('', '1', '2', '3', '4', '5') {
        my $section = "mysqld" . $val;
        if(exists $config->rqg_options->{$section}) {
            say("DEBUG: A '$section' section exists.") if Auxiliary::script_debug("S5");
            $mysql_options .= $config->genOpt("--$section=--", $config->rqg_options->{$section});
            delete $config->rqg_options->{$section};
        }
    }
    say("DEBUG: mysql_options ->$mysql_options<-") if Auxiliary::script_debug("S4");

    ### FIXME: Treat these targets of simplification in detail
    ### validators , transformers ,
    my @validators = $config->validators;
    if ($#validators == 0 and $validators[0] =~ m/,/) {
        @validators = split(/,/,$validators[0]);
    }

    # $config->reporters is a pointer to an array
    my $reporters = $config->reporters;
    if (defined $reporters) {
        if (defined $config->rqg_options->{'reporters'}) {
            say("WARN: Wiping the settings for reporters within the rqg options because other " .
                "(command line or top level in config file) exist and have precedence.");
            delete $config->rqg_options->{'reporters'};
        }
    } else {
        $reporters = $config->rqg_options->{'reporters'};
        delete $config->rqg_options->{'reporters'};
        if (not defined $reporters) {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: Reporters neither via command line nor via config file reporters " .
                "assigned. But the Simplifier should not guess what the RQG runner will do." .
            Auxiliary::exit_status_text($status));
            safe_exit($status);
        }
    }
    @reporter_array = @$reporters;
    # Aside of the what is finally valid regulation above we treat the reporter assignement
    # like the RQG runner.
    if ($#reporter_array == 0 and $reporter_array[0] =~ m/,/) {
        @reporter_array = split(/,/,$reporter_array[0]);
    }
    say("DEBUG: Reporters '" . join(",", @reporter_array) . "'") if Auxiliary::script_debug("S2");
    # As long as the simplifier does not attack the amount of reporters we add the
    # reportersetting to $cl_snip_all.
    $cl_snip_all .= " --reporters=" . join(",", @$reporters);


    # $config->transformers is a pointer to an array
    my $transformers = $config->transformers;
    if (defined $transformers) {
        if (defined $config->rqg_options->{'transformers'}) {
            say("WARN: Wiping the settings for transformers within the rqg options because other " .
                "(command line or top level in config file) exist and have precedence.");
            delete $config->rqg_options->{'transformers'};
        }
    } else {
        $transformers = $config->rqg_options->{'transformers'};
        delete $config->rqg_options->{'transformers'};
    }
    if (defined $transformers) {
        @transformer_array = @$transformers;
        # Aside of the what is finally valid regulation above we treat the reporter assignement
        # like the RQG runner.
        if ($#transformer_array == 0 and $transformer_array[0] =~ m/,/) {
            @transformer_array = split(/,/,$transformer_array[0]);
        }
        say("DEBUG: Transformers '" . join(",", @transformer_array) . "'") if Auxiliary::script_debug("S2");
        # As long as the simplifier does not attack the amount of transformers we add the
        # transformer setting to $cl_snip_all.
        $cl_snip_all .= " --transformers=" . join(",", @$transformers);
    }


    # $config->validators is a pointer to an array
    my $validators = $config->validators;
    if (defined $validators) {
        if (defined $config->rqg_options->{'validators'}) {
            say("WARN: Wiping the settings for validators within the rqg options because other " .
                "(command line or top level in config file) exist and have precedence.");
            delete $config->rqg_options->{'validators'};
        }
    } else {
        $validators = $config->rqg_options->{'validators'};
        delete $config->rqg_options->{'validators'};
    }
    if (defined $validators) {
        @validator_array = @$validators;
        # Aside of the what is finally valid regulation above we treat the reporter assignement
        # like the RQG runner.
        if ($#validator_array == 0 and $validator_array[0] =~ m/,/) {
            @validator_array = split(/,/,$validator_array[0]);
        }
        say("DEBUG: Validators '" . join(",", @validator_array) . "'") if Auxiliary::script_debug("S2");
        # As long as the simplifier does not attack the amount of validators we add the
        # transformer setting to $cl_snip_all.
        $cl_snip_all .= " --validators=" . join(",", @$validators);
    }


    my $rqg_options_end = $config->genOpt('--', 'rqg_options');
    if (Auxiliary::script_debug("S5")) {
        say("DEBUG: RQG options before 'mangling' ->$rqg_options_begin<-");
        say("DEBUG: RQG options after  'mangling' ->$rqg_options_end<-");
    }

    if (STATUS_OK != Verdict::check_normalize_set_black_white_lists (
                    ' The RQG run ended with status ', # $status_prefix,
                    $config->blacklist_statuses, $config->blacklist_patterns,
                    $config->whitelist_statuses, $config->whitelist_patterns)) {
        say("ERROR: Setting the values for blacklist and whitelist search failed.");
        # my $status = STATUS_CONFIG_ERROR;
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("$0 will exit with exit status " . status2text($status) . "($status)");
        safe_exit($status);
    }

    if (not defined $grammar_file) {
        say("ERROR: Grammar file is not defined.");
        help_simplifier();
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("$0 will exit with exit status " . status2text($status) . "($status)");
        safe_exit($status);
    } else {
        if (! -f $grammar_file) {
            say("ERROR: Grammar file '$grammar_file' does not exist or is not a plain file.");
            help_simplifier();
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("$0 will exit with exit status " . status2text($status) . "($status)");
            safe_exit($status);
        }
    }
    $grammar_flags = $config->grammar_flags;
#   my $first_grammar_file = Auxiliary::unify_grammar($grammar_file, $redefine_ref, $workdir,
#                                     $skip_recursive_rules, $mask, $mask_level);
#   my @redefine ;
#   my $first_grammar_file = Auxiliary::unify_grammar($grammar_file, \@redefine, $workdir,
#                                     $grammar_flags, 0, 0);

    # Actions of GenTest::Simplifier::Grammar_advanced::init
    # ...  load_grammar($grammar_file);
    # ...  fill_rule_hash();
    # ...  print_rule_hash();
    # ...  analyze_all_rules(); -- Maintains counter except weight and removes unused rules
    # ...  compact_grammar();   -- collapseComponents (unique) and moderate inlining
    $grammar_string = GenTest::Simplifier::Grammar_advanced::init($grammar_file, $threads, $grammar_flags);
    say("Grammar ->$grammar_string<-");
    # Dump this parent grammar
    $parent_grammar= "p" . Auxiliary::lfill0($parent_number,5) . ".yy";
    Batch::make_file($workdir . "/" . $parent_grammar, $grammar_string . "\n");
    $parent_number++;

    $result_file  = $workdir . "/result.txt";
    my $iso_ts = isoTimestamp();
    my $header =
"$iso_ts Simplifier init ================================================================================================\n" .
"$iso_ts workdir                                         : '$workdir'\n"                                                     .
"$iso_ts config_file (assigned)                          : '$config_file'\n"                                                 .
"$iso_ts config file (processed + is copy of above)      : '$config_file_copy_rel'\n"                                        .
"$iso_ts duration (maybe adjusted during simplification) : $duration seconds (Default " . DURATION_DEFAULT . ")\n"           .
"$iso_ts queries                                         : $queries (Default " . QUERIES_DEFAULT . ")\n"                     .
"$iso_ts threads                                         : $threads (Default " . THREADS_DEFAULT . ")\n"                     .
"$iso_ts initial grammar file                            : '$grammar_file'\n"                                                .
"$iso_ts reporters                                       : " . join(",", @reporter_array) . "\n"                             .
"$iso_ts validators                                      : " . join(",", @validator_array) . "\n"                            .
"$iso_ts transformers                                    : " . join(",", @transformer_array) . "\n"                          .
"$iso_ts ----------------------------------------------------------------------------------------------------------------\n" .
"$iso_ts trials (used for certain phases only)                   : $trials (Default " . TRIALS_DEFAULT . ")\n"               .
"$iso_ts duration_adaption (vary duration according to progress) : $duration_adaption (Default 1)\n"                         .
"$iso_ts algorithm (used for grammar simplification)             : '$algorithm' (Default '" . SIMP_ALGO_WEIGHT . "')\n"      .
"$iso_ts grammar_flags                                           : $grammar_flags (Default undef)\n"                         .
"$iso_ts ----------------------------------------------------------------------------------------------------------------\n" .
"$iso_ts call line additions (bwlist excluded) : $cl_snip_all\n"                                                             .
"$iso_ts ----------------------------------------------------------------------------------------------------------------\n" .
"$iso_ts whitelist_statuses : " . join(',',@{$config->whitelist_statuses}) . "\n"                                            .
"$iso_ts whitelist_patterns : " . join(',',@{$config->whitelist_patterns}) . "\n"                                            .
"$iso_ts blacklist_statuses : " . join(',',@{$config->blacklist_statuses}) . "\n"                                            .
"$iso_ts blacklist_patterns : " . join(',',@{$config->blacklist_patterns}) . "\n"                                            .
"$iso_ts ----------------------------------------------------------------------------------------------------------------\n" ;
    Batch::write_result($header);

    $cl_snip_all .= " " . $rqg_options_end . " " . $mysql_options .
                    Verdict::black_white_lists_to_config_snip('cl');

    replay_runtime_fifo_init(10, $duration);

    $phase        = PHASE_SIMP_BEGIN;
    $phase_switch = 1;

    say("DEBUG: Leaving 'Simplifier::init") if Auxiliary::script_debug("S6");


} # End sub init

sub get_job {
    my $order_id;
    my $job;

    # Safety measure
    my ($active) = @_;

    # For experimenting:
    # $active = 10;
    if ($phase_switch) {
        if(not defined $active or 0 != $active) {
            my $status = STATUS_INTERNAL_ERROR;
            Carp::cluck("INTERNAL ERROR: Wrong call of Simplifier::getjob : active is not 0.");
            Batch::emergency_exit($status);
        } else {
            switch_phase();
            # Setting $phase_switch = 0 is made in switch_phase().
        }
    }

    while (not defined $order_id) {
        say("DEBUG: Begin of loop for getting an order.") if Auxiliary::script_debug("S6");
        $order_id = Batch::get_order();
        if (defined $order_id) {
            say("DEBUG: Batch::get_order delivered order_id $order_id.")
                if Auxiliary::script_debug("S6");
            if (not order_is_valid($order_id)) {
                say("DEBUG: The order $order_id is no more valid.")
                    if Auxiliary::script_debug("S4");
                Batch::add_to_try_never($order_id);
                $order_id = undef;
            } else {
                say("DEBUG: The order $order_id is valid.")
                    if Auxiliary::script_debug("S6");
            }
        } else {
            # @try_first_queue and @try_queue were empty.
            say("DEBUG: Batch::get_order delivered an undef order_id.")
                if Auxiliary::script_debug("S5");
            if (not $out_of_ideas) {
                # We do not already know if generating a new order is impossible.
                # So we need to try it.
                if (not generate_orders()) {
                    say("DEBUG: generate_orders delivered nothing. Setting out_of_ideas")
                         if Auxiliary::script_debug("S4");
                    $out_of_ideas = 1;
                    last;
                } else {
                    # There must be now one or more new orders in @try_queue.
                    # So let them get found by Batch::get_order() and checked if valid.
                    next;
                }
            } else {
                last;
            }
            # FIXME:
            # Depending on phase orders from @try_over_queue could get "reactivated".
        }
        say("DEBUG: End of loop for getting an order.") if Auxiliary::script_debug("S6");
    }
    if (Auxiliary::script_debug("S6")) {
        if (defined $order_id) {
            say("DEBUG: OrderID is $order_id.");
        } else {
            if (not $out_of_ideas) {
                say("WARN: OrderID is not defined AND out_of_ideas is 0.");
            }
        }
    }

    if (not defined $order_id) {
        # @try_first_queue empty , @try_queue empty too and extending obviously impossible
        # because otherwise @try_queue would be not empty.
        # == All possible orders were generated.
        #    Some might be in execution and all other must be in @try_over_queue or
        #    @try_never_queue.
        say("DEBUG: No order got, active : $active, out_of_ideas : $out_of_ideas")
            if Auxiliary::script_debug("S5");
        Batch::dump_queues();
        if (not $active and $out_of_ideas) {
            $phase_switch     = 1;
            say("DEBUG: Simplifier::get_job : No valid order found, active : $active, " ,
                "out_of_ideas : $out_of_ideas --> Set phase_switch = 1 and return undef")
                if Auxiliary::script_debug("S5");
        }
        return undef;
    } else {
        if (not defined $order_array[$order_id]) {
            my $status = STATUS_INTERNAL_ERROR;
            Carp::cluck("INTERNALE ERROR: Simplifier::get_job : orderid is not in order_array. " .
                        "Will exit with status " . status2text($status) . "($status)");
            Batch::emergency_exit($status);
        }
        # Prepare the job according to phase
        Batch::add_id_to_run_queue($order_id);
        return ($order_id, $cl_snip_all . $cl_snip_phase, $child_grammar, $parent_grammar,
                replay_runtime_adapt());
    }

} # End of get_job


##------------------------------------------------------

sub help_simplifier() {
#    print(
#    "\nSorry, under construction and partially different or not yet implemented.\n\n"               .
#    "Purpose: Perform a batch of RQG runs with massive parallelization according to setup/config\n" .
#    "         Be a replacement for\n"                                                               .
#    "         (immediate) combinations.pl, bughunt.pl, runall-trials.pl\n"                          .
#    "         (soon)      simplify-grammar.pl\n"                                                    .
#    "Terms used:\n"                                                                                 .
#    "combination string\n"                                                                          .
#    "      A fragment of a RQG call generated by rqg_batch.pl based on config file content.\n"      .
#    "      rqg_batch.pl might transform and especially append more settings depending on\n"         .
#    "      content in command line and defaults..\n"                                                .
#    "      The final string is later used for calling the RQG runner.\n"                            .
#    "Default\n"                                                                                     .
#    "      What you get in case you do not assign some corresponding --<parameter>=<value>.\n"      .
#    "RQG Worker\n"                                                                                  .
#    "      A child process which\n"                                                                 .
#    "      1. Runs an extreme small 'prepare play ground'\n"                                        .
#    "      2. Switches via Perl 'exec' to running RQG\n"                                            .
#    "Regular finished RQG run\n"                                                                    .
#    "      A RQG run which ended regular with success or failure (crash, perl error ...).\n"        .
#    "      rpl_batch.pl might stop (KILL) RQG runs because of technical reasons.\n"                 .
#    "      Such stopped runs will be restarted with the same setup as soon as possible.\n"          .
#    "      And they do not count as regular runs.\n"                                                .
#    "\n"                                                                                            .
#    "--run-all-combinations-once\n"                                                                 .
#    "      Generate a deterministic sequence of combinations.\n"                                    .
#    "      The number of combinations limits the maximum number of trials!\n"                       .
#    "      --start-combination=<m>\n'"                                                              .
#    "             Start the execution with the m'th combination.\n"                                 .
#    "--trials=<n>\n"                                                                                .
#    "      rqg_batch.pl will exit if this number of regular finished trials(RQG runs) is reached.\n".
#    "      n = 1 --> Write the output of the RQG runner to screen and do not cleanup at end.\n"     .
#    "                Maybe currently not working or in future removed.                        \n"   .
#    "--max_runtime=<n>\n"                                                                           .
#    "      Stop ongoing RQG runs if the total runtime in seconds has exceeded this value,\n"        .
#    "      give a summary and exit.\n"                                                              .
#    "--parallel=<n>\n"                                                                              .
#    "      Maximum number of parallel RQG Workers performing RQG runs.\n"                           .
#    "      (Default) All OS: If supported <return of OS command nproc> otherwise 1.\n\n"            .
#    "      WARNING - WARNING - WARNING -  WARNING - WARNING - WARNING - WARNING - WARNING\n"        .
#    "         Please be aware that OS/user/hardware resources are limited.\n"                       .
#    "         Extreme resource consumption (high value for <n> and/or fat RQG tests) could result\n".
#    "         in some very slow reacting testing box up till OS crashes.\n"                         .
#    "         Critical candidates: open files, max user processes, free space in tmpfs\n"           .
#    "         Future improvement of rpl_batch.pl will reduce these risks drastic.\n\n"              .
#    "Not assignable --queries\n"                                                                    .
#    "      But if its not in the combination string than --queries=100000000 will be appended.\n"   .
#    "also not passed through to the RQG runner.\n"                                                  .
#    "          If neither --no_mask, --mask or --mask-level is in the combination string than "     .
#    "a --mask=.... will be appended to it.\n"                                                       .
#    "          Impact of the latter in the RQG runner: mask-level=1 and that --mask=...\n"          .
#    "--seed=...\n"                                                                                  .
#    "      Seed value used here for generation of random combinations. In case the combination \n"  .
#    "      does not already assign seed than this will be appended to the string too.\n"            .
#    "      (Default) 1 do not append to the combination string.\n"                                  .
#    "      --seed=time assigned here or being in combination string will be replaced by\n"          .
#    "      --seed=<value returned by some call of time() in perl>.\n"                               .
#    "--runner=...\n"                                                                                .
#    "      The RQG runner to be used. The value assigned must be without path.\n"                   .
#    "      (Default) rqg.pl in RQG_HOME.\n"                                                         .
#    "--script_debug\n"                                                                              .
#    "      Print additional detailed information about decisions made by rqg_batch.pl\n"            .
#    "      and observations made during runtime.\n"                                                 .
#    "      Debug functionality of other RQG parts like the RQG runner will be not switched!\n"      .
#    "      Debug functionality of other RQG parts like the RQG runner will be not switched!\n"      .
#    "      (Default) No additional information.\n"                                                  .
#    "      Hint:\n"                                                                                 .
#    "      The combination\n"                                                                       .
#    "                  --dryrun --script_debug¸\n"                                                  .
#    "      is an easy/fast way to check certains aspects of\n"                                      .
#    "      - the order and job management in rqg_batch in general\n"                                .
#    "      - optimizations (depend on progress) for grammar simplification\n"                       .
#    "-------------------------------------------------------------------------------------------\n" .
#    "Group of parameters which get appended to the combination string and so passed through to \n"  .
#    "the RQG runner. For their meaning please look into the output of '<runner> --help'.       \n"  .
#    "--duration=<n>\n"                                                                              .
#    "--gendata=...\n"                                                                               .
#    "--grammar=...\n"                                                                               .
#    "--threads=<n>  (Hint: Set it once to 1. Maybe its not a concurrency bug.)\n"                   .
#    "--no_mask      (Assigning --mask or --mask-level on command line is not supported.)\n"         .
#    "-------------------------------------------------------------------------------------------\n" .
#    "rqg_batch will create a symlink '$symlink' pointing to the workdir of his run\n"               .
#    "which is <value assigned to workdir>/<runid>.\n"                                               .
#    "-------------------------------------------------------------------------------------------\n" .
#    "How to cause some rapid stop of the ongoing rqg_batch.pl run without using some dangerous "    .
#    "killall SIGKILL <whatever>?\n"                                                                 .
#    "    touch $symlink" . "/exit\n"                                                                .
#    "rpl_batch.pl will stop all active RQG runners, cleanup and give a summary.\n\n"                .
#    "What to do on Linux in the rare case (RQG core or runner broken) that this somehow fails?\n"   .
#    "    killall -9 perl ; killall -9 mysqld ; rm -rf /dev/shm/vardir/*\n"                          .
#    "-------------------------------------------------------------------------------------------\n" .
#    "How to cause some non-random run with fixed range of combinations covered?\n"                  .
#    "Assign\n"                                                                                      .
#    "   --run-all-combinations-once --> Generation of a deterministic sequence of combinations\n"   .
#    "with optional\n"                                                                               .
#    "   --start_combination<m> --> Omit trying the first <m - 1> combinations.\n"                   .
#    "The range of combinations covered could be limited/extended via trials and/or max_runtime.\n"  .
#    "In case none of them is set than the rqg_batch.pl run ends after the RQG run with the last \n" .
#    "not yet tried combination has finished regular.\n"                                             .
#    "-------------------------------------------------------------------------------------------\n" .
#    "Impact of RQG_HOME if found in environment and the current working directory:\n"               .
#    "Around its start rqg_batch.pl searches for RQG components in <CWD>/lib and ENV(\$RQG_HOME)/lib\n" .
#    "- rqg_batch.pl computes RQG_HOME from its call and sets than some corresponding "              .
#    "  environment variable.\n"                                                                     .
#    "  All required RQG components (runner/reporter/validator/...) will be taken from this \n"      .
#    "  RQG_HOME 'Universe' in order to ensure consistency between these components.\n"              .
#    "- All other ingredients with relationship to some filesystem like\n"                           .
#    "     grammars, config files, workdir, vardir, ...\n"                                           .
#    "  will be taken according to their setting with absolute path or relative to the current "     .
#    "working directory.\n");
}


sub order_is_valid {
    my ($order_id) = @_;

    if (not defined $order_id) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNALE ERROR: No or undef order_id assigned. " .
                    "Will exit with status " . status2text($status) . "($status)");
        Batch::emergency_exit($status);
    }

    if ($order_array[$order_id][ORDER_EFFORTS_LEFT] <= 0) {
        say("DEBUG: Order with id $order_id is no more valid.") if Auxiliary::script_debug("S4");
        return 0;
    }

    # PHASE_SIMP_BEGIN
    # PHASE_FIRST_REPLAY      handled
    # PHASE_THREAD1_REPLAY    handled
    # PHASE_TRANSFORMER_SIMP
    # PHASE_REPORTER_SIMP
    # PHASE_VALIDATOR_SIMP
    # PHASE_GRAMMAR_SIMP      handled
    # PHASE_FINAL_REPLAY      handled
    # PHASE_SIMP_END          not relevant

    if (PHASE_FIRST_REPLAY   eq $phase or
        PHASE_THREAD1_REPLAY eq $phase or
        PHASE_FINAL_REPLAY   eq $phase   ) {
        # Any order is valid. The sufficient enough tried were already sorted out above.
        return 1;
    } elsif (PHASE_GRAMMAR_SIMP eq $phase) {
        my $rule_name        = $order_array[$order_id][ORDER_PROPERTY2];
        my $component_string = $order_array[$order_id][ORDER_PROPERTY3];
        say("DEBUG: Simplifier::order_is_valid : rule_name '$rule_name', component ->" .
            $component_string . "<-") if Auxiliary::script_debug("S5");
        my $new_rule_string = GenTest::Simplifier::Grammar_advanced::shrink_grammar(
                                  $rule_name, $component_string, 0);
        if (defined $new_rule_string) {
            $child_grammar = "c" . Auxiliary::lfill0($child_number,5) . ".yy";
            Batch::make_file($workdir . "/" . $child_grammar, $grammar_string .
                             "\n\n# Generated by grammar simplifier\n" . $new_rule_string . "\n");
            $child_number++;
            return 1;
        } else {
            say("DEBUG: Order id '$order_id' affecting rule '$rule_name' component " .
                "'$component_string' is invalid.") if Auxiliary::script_debug("S4");
            return 0;
        }
    } else {
        say("INTERNAL ERROR: Handling for phase '$phase' is missing.");
        my $status = STATUS_INTERNAL_ERROR;
        Batch::emergency_exit($status);
    }
}


sub print_order {

    my ($order_id) = @_;

    if (not defined $order_id) {
        say("INTERNAL ERROR: print_order was called with some not defined \$order_id.\n");
        my $status = STATUS_INTERNAL_ERROR;
        Batch::emergency_exit($status);
    }
    my @order = @{$order_array[$order_id]};
    say("$order_id § " . join (' § ', @order));

}
#
sub dump_orders {
    say("DEBUG: Content of the order array ------------- begin");
    say("id § efforts_invested § efforts_left § property1 § property2 § property3");
    foreach my $order_id (1..$#order_array) {
        print_order($order_id);
    }
    say("DEBUG: Content of the order array ------------- end");
}

# Hint:
# One generate_call could lead to several orders added!
my $generate_calls = 0;
sub generate_orders {

    $generate_calls++;
    say("DEBUG: Number of generate_orders calls : $generate_calls")
        if Auxiliary::script_debug("S5");
    Batch::dump_queues() if Auxiliary::script_debug("S5");
    my $success = 0;
    # PHASE_SIMP_BEGIN        should not be relevant but is handled in the else branch
    # PHASE_FIRST_REPLAY      handled
    # PHASE_THREAD1_REPLAY    handled
    # PHASE_TRANSFORMER_SIMP
    # PHASE_REPORTER_SIMP
    # PHASE_VALIDATOR_SIMP
    # PHASE_GRAMMAR_SIMP      handled
    # PHASE_FINAL_REPLAY      handled
    # PHASE_SIMP_END
    if      (PHASE_FIRST_REPLAY   eq $phase or
             PHASE_THREAD1_REPLAY eq $phase or
             PHASE_FINAL_REPLAY   eq $phase) {
        add_order($cl_snip_all . $cl_snip_phase, 'unused', '_unused_');
        $success = 1;
    } elsif (PHASE_GRAMMAR_SIMP eq $phase) {
        my $none_found = 1;
        while ($none_found) {
            my $rule_name = GenTest::Simplifier::Grammar_advanced::next_rule_to_process(
                                RULE_JOBS_GENERATED, RULE_WEIGHT);
            if (not defined $rule_name) {
                say("DEBUG: next_rule_to_process delivered undef.")
                    if Auxiliary::script_debug("S5");
                last;
            }
            my @rule_unique_component_list =
                    GenTest::Simplifier::Grammar_advanced::get_unique_component_list($rule_name);
            say("DEBUG: unique components of rule '$rule_name' " .
                join(" § ", @rule_unique_component_list)) if Auxiliary::script_debug("S5");
            if (1 < scalar @rule_unique_component_list) {
                foreach my $component (@rule_unique_component_list) {
                    add_order($cl_snip_all . $cl_snip_phase, $rule_name, $component);
                    $success++;
                }
                say("DEBUG: Rule '$rule_name' was decomposed into $success orders.")
                    if Auxiliary::script_debug("S5");
                # We decompose one rule only.
                $none_found = 0;
            } else {
                say("DEBUG: Rule '$rule_name' has only " . (scalar @rule_unique_component_list) .
                    " components.") if Auxiliary::script_debug("S5");
            }
            GenTest::Simplifier::Grammar_advanced::set_rule_jobs_generated($rule_name);
        }
    } else {
        say("INTERNAL ERROR: Handling for phase '$phase' is missing.");
        my $status = STATUS_INTERNAL_ERROR;
        Batch::emergency_exit($status);
    }
    if ($success) {
        if (Auxiliary::script_debug("S5")) {
            dump_orders();
            Batch::dump_queues();
        }
        return 1;
    } else {
        say("DEBUG: All possible orders were already generated. Will return 0.");
        return 0;
    }
} # End of sub generate_orders


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
    print_order($order_id_now) if Auxiliary::script_debug("S5");
}

my $arrival_number   = 1;
sub register_result {
# # order_id
# # verdict
# # runtime or current routine could extract runtime from log
# # log
# # Current could extract runtime
# #
# # Return
# # - ~ OK
# # - ~ run emergency exit
# #
#
# rqg_batch.pl delivers
#     WORKER_EXTRA1 child_grammar
#     WORKER_EXTRA2 parent_grammar
#     WORKER_EXTRA3 adapted duration
# bekommt vorher (get_job)
#     @job = Simplifier::get_job
#     $job[0] -- order_id         --> $worker_array[$free_worker][WORKER_ORDER_ID]
#     $job[1] -- cl_snip (Simp memorizes that because static in phase, without child_grammar!)
#                                     rqg_batch puts that in mid of cl
#     $job[2] -- child_grammar    --> $worker_array[$free_worker][WORKER_EXTRA1]
#                                     If defined than glue in rqg_batch to cl
#     $job[3] -- parent_grammar   --> $worker_array[$free_worker][WORKER_EXTRA2]
#     $job[4] -- adapted duration --> $worker_array[$free_worker][WORKER_EXTRA3]
#                                     If defined than glue in rqg_batch to cl
#
#
    my ($order_id, $verdict, $saved_log_rel, $total_runtime,
        $grammar_used, $grammar_parent, $adapted_duration) = @_;
    say("DEBUG: Simplifier::register_result : OrderID : $order_id, Verdict: $verdict, " .
        "RQG log : '$saved_log_rel', total_runtime : $total_runtime, " .
        "Grammar used: $grammar_used, Parent: $grammar_parent")
        if Auxiliary::script_debug("S4");

    # -1. Remove the order_id from the queue of just executed orders.
    Batch::remove_id_from_run_queue($order_id);

    # 0. In case of a replay we need to pull information which is not part of the routine
    #    parameters but contained around end of the RQG run log.
    my $gentest_runtime;
    if ($verdict eq Verdict::RQG_VERDICT_REPLAY) {
        # 2018-11-19T16:16:19 [19309] SUMMARY: RQG GenData runtime in s : 0
        # 2018-11-19T16:16:19 [19309] SUMMARY: RQG GenTest runtime in s : 31
        # 2018-11-19T16:16:19 [19309] SUMMARY: RQG total runtime in s : 34
        ##### 2018-11-19T16:16:19 [19309] SUMMARY: RQG verdict : replay
        my $logfile = $workdir . "/" . $saved_log_rel;
        $gentest_runtime = Batch::get_string_after_pattern($logfile,
                               "SUMMARY: RQG GenTest runtime in s : ");
        replay_runtime_fifo_update($gentest_runtime);
        say("DEBUG: Replayer with orderid : $order_id needed gentest_runtime : $gentest_runtime")
            if Auxiliary::script_debug("S5");
    }

    # 1. Bookkeeping
    my $iso_ts = isoTimestamp();
    my $line   = "$iso_ts | " .
        Auxiliary::lfill($arrival_number, Batch::RQG_NO_LENGTH)     . " | " .
        Auxiliary::rfill($verdict,Verdict::RQG_VERDICT_LENGTH)      . " | " .
        Auxiliary::lfill($saved_log_rel, Batch::RQG_LOG_LENGTH)     . " | " .
        Auxiliary::lfill($order_id, Batch::RQG_ORDERID_LENGTH)      . " | " .
        Auxiliary::lfill($total_runtime, Batch::RQG_ORDERID_LENGTH) . " | " .
        Auxiliary::lfill($grammar_used, Batch::RQG_GRAMMAR_LENGTH)  . " | " .
        Auxiliary::lfill($grammar_parent, Batch::RQG_GRAMMAR_LENGTH). "\n";
    Batch::append_string_to_file ($result_file, $line);
    $arrival_number++;

    # 2. Update $left_over_trials, ORDER_EFFORTS_INVESTED and ORDER_EFFORTS_LEFT
    if      ($verdict eq Verdict::RQG_VERDICT_IGNORE           or
             $verdict eq Verdict::RQG_VERDICT_IGNORE_STATUS_OK or
             $verdict eq Verdict::RQG_VERDICT_IGNORE_BLACKLIST or
             $verdict eq Verdict::RQG_VERDICT_INTEREST         or
             $verdict eq Verdict::RQG_VERDICT_REPLAY           or
             $verdict eq Verdict::RQG_VERDICT_INIT       ) {
        $order_array[$order_id][ORDER_EFFORTS_INVESTED]++;
        $order_array[$order_id][ORDER_EFFORTS_LEFT]--;
        $left_over_trials--;
    } elsif ($verdict eq Verdict::RQG_VERDICT_IGNORE_STOPPED) {
        # Do nothing with the $order_array[$order_id][ORDER_EFFORTS_*].
    } else {
        say("INTERNAL ERROR: Final Verdict '$verdict' is not treated/unknown. " .
            "Will ask for an emergency_exit.");
        my $status = STATUS_INTERNAL_ERROR;
        Batch::emergency_exit($status);
        return (STATUS_INTERNAL_ERROR, Batch::REGISTER_GO_ON);
    }
    say("DEBUG: Simplifier::register_result : left_over_trials : $left_over_trials")
        if Auxiliary::script_debug("S4");

    my $source = $workdir . "/" . $grammar_used;
    my $target = $workdir . "/" . $best_grammar;

    # 3. React on the verdict and decide about the nearby future of the order.
    if      ($verdict eq Verdict::RQG_VERDICT_IGNORE_STOPPED) {
        # We need to make some additional run with this order as soon as possible.
        Batch::add_to_try_first($order_id);
    } elsif ($verdict eq Verdict::RQG_VERDICT_REPLAY) {
        $campaign_success++;
        if (PHASE_FIRST_REPLAY   eq $phase or
            PHASE_THREAD1_REPLAY eq $phase or
            PHASE_FINAL_REPLAY   eq $phase   ) {
            # The fate of the phase is decided.
            $phase_switch = 1;
            Batch::copy_file($source,$target);
            if (PHASE_THREAD1_REPLAY eq $phase) {
                say("We had a replay in phase '$phase'. " .
                    "Will adjust the parent grammar and the number of threads used to 1.");
                $threads = 1;
                $cl_snip_all .= " --threads=1";
                # We will get a switching of the phase to PHASE_GRAMMAR_SIMP and that will
                # load the actual parent grammar. And there the setting of $threads = 1 above
                # might have an impact on grammar shape.
            } elsif (PHASE_FINAL_REPLAY eq $phase) {
                return (STATUS_OK, Batch::REGISTER_END);
            }
            Batch::add_to_try_never($order_id);
            return (STATUS_OK, Batch::REGISTER_STOP_ALL);
        } elsif (PHASE_GRAMMAR_SIMP eq $phase) {
            if ($grammar_parent eq $parent_grammar) {
                reload_grammar($grammar_used);
                Batch::add_to_try_never($order_id);
            } else {
                # Its a second winner. But the order was quite good. So try it again.
                Batch::add_to_try_first($order_id);
                # Increase ORDER_EFFORTS_LEFT because if its <= 0 we will get no repetition.
                # Increase by 2 because it a thta promising candidate.
                $order_array[$order_id][ORDER_EFFORTS_LEFT]++;
                $order_array[$order_id][ORDER_EFFORTS_LEFT]++;
            }
        }
    } elsif ($verdict eq Verdict::RQG_VERDICT_IGNORE            or
             $verdict eq Verdict::RQG_VERDICT_IGNORE_STATUS_OK  or
             $verdict eq Verdict::RQG_VERDICT_IGNORE_BLACKLIST  or
             $verdict eq Verdict::RQG_VERDICT_INTEREST          or
             $verdict eq Verdict::RQG_VERDICT_INIT                ) {
        Batch::add_to_try_over($order_id);
    } else {
        say("INTERNAL ERROR: Final Verdict '$verdict' is not treated/unknown. " .
            "Will ask for an emergency_exit.");
        my $status = STATUS_INTERNAL_ERROR;
        Batch::emergency_exit($status);
    }

    Batch::dump_queues;
    # Check consistency of the queues.
    Batch::check_queues();

    if ($left_over_trials) {
        # FIXME:
        # If Grammar_simp and $out_of_ideas and scalar (try_first , try_run) empty
        # than the current campaign is over.
        if(PHASE_GRAMMAR_SIMP eq $phase and
           $out_of_ideas                and
           0 == Batch::known_orders_waiting ) {
           say("DEBUG: The current campaign has reached the end after $campaign_success replays.");
           Batch::dump_queues;
           $phase_switch = 1;
           return (STATUS_OK, Batch::REGISTER_GO_ON);
        }
        return (STATUS_OK, Batch::REGISTER_GO_ON);
    } else {
        if (PHASE_FIRST_REPLAY   eq $phase) {
            say("No replay with the initial grammar. Giving up.");
            return (STATUS_OK, Batch::REGISTER_END);
        } elsif (PHASE_THREAD1_REPLAY eq $phase) {
            say("No replay with threads=1.");
            $phase_switch = 1;
            return (STATUS_OK, Batch::REGISTER_STOP_ALL);
        } else {
            return (STATUS_OK, Batch::REGISTER_END);
        }
    }

} # End sub register_result


sub switch_phase {

    say("DEBUG: Simplifier::switch_phase: Enter routine. Current phase is '$phase'.")
        if Auxiliary::script_debug("S4");
    Batch::dump_queues;
    my $iso_ts = isoTimestamp();

    if      (PHASE_SIMP_BEGIN eq $phase)     {
        $phase             = PHASE_FIRST_REPLAY;
        $left_over_trials  = $trials;
        $child_grammar= "c" . Auxiliary::lfill0($child_number,5) . ".yy";
        my $source = $workdir . "/" . $parent_grammar;
        my $target = $workdir . "/" . $child_grammar;
        Batch::copy_file($source, $target);
        $child_number++;
        $cl_snip_phase     = " --grammar=" . $target;
        Batch::write_result("$iso_ts ---------- $phase ----------\n" .
                            $iso_ts . $title_line_part);
    } elsif (PHASE_FIRST_REPLAY eq $phase)   {
        $phase            = PHASE_THREAD1_REPLAY;
        $left_over_trials = $trials;
        $child_grammar= "c" . Auxiliary::lfill0($child_number,5) . ".yy";
        my $source = $workdir . "/" . $parent_grammar;
        my $target = $workdir . "/" . $child_grammar;
        Batch::copy_file($source, $target);
        $child_number++;
        $cl_snip_phase      = " --grammar=" . $target . " --threads=1";
        Batch::write_result("$iso_ts ---------- $phase ----------\n" .
                            $iso_ts . $title_line_part);
    } elsif (PHASE_THREAD1_REPLAY eq $phase) {
        $phase            = PHASE_GRAMMAR_SIMP;
        $left_over_trials = TRIALS_SIMP;
        $campaign_number++;
        $cl_snip_phase     = "";
        load_grammar($parent_grammar);
        Batch::write_result("$iso_ts ---------- $phase campaign $campaign_number ----------\n" .
                            $iso_ts . $title_line_part);
    } elsif (PHASE_GRAMMAR_SIMP eq $phase)   {
        if ($campaign_success or 1 == $campaign_number) {
            # We had either success in the last campaign and therefore we repeat it or just
            # one campaign which is frequent too short.
            # Some alternative would be
            #    Move all members of the @try_over_queue into @try_queue == reactivate them.
            #    But I expect that the following will happen:
            #    1. Some share of these old orders will be invalid. The check is cheap.
            #    2. The remaining share should be the same amount like with statrting an
            #       additional campaign. So its not per se bad.
            #    3. The remaining share should be sorted order_id ascending.
            #       Slight disadvantage: An additional campaign gives some improved order
            #                            because of fresh recalculated weights.
            $phase = PHASE_GRAMMAR_SIMP;
            $left_over_trials = TRIALS_SIMP;
            $campaign_number++;
            $cl_snip_phase     = "";
            Batch::write_result("$iso_ts ---------- $phase campaign $campaign_number ----------\n" .
                                $iso_ts . $title_line_part);
            # Q1: How looks $grammar_string like? Last parent grammar?
            # Q2:

            load_grammar($parent_grammar);
        } else {
            $phase            = PHASE_FINAL_REPLAY;
            $left_over_trials = $trials;
            $child_grammar= "c" . Auxiliary::lfill0($child_number,5) . ".yy";
            my $source = $workdir . "/" . $parent_grammar;
            my $target = $workdir . "/" . $child_grammar;
            Batch::copy_file($source, $target);
            $child_number++;
            $cl_snip_phase     = " --grammar=" . $target;
            Batch::write_result("$iso_ts ---------- $phase ----------\n" .
                                $iso_ts . $title_line_part);
        }
    } elsif (PHASE_FINAL_REPLAY eq $phase)   {
        say("Simplifier::switch_phase : Give a summary + signal rqg_batch to finish.");
    } else {
        say("INTERNAL ERROR: Handling for phase '$phase' is missing.");
        my $status = STATUS_INTERNAL_ERROR;
        Batch::emergency_exit($status);
    }
    Batch::init_queues;
    say("DEBUG: Simplifier::switch_phase: Leaving routine. Current phase is '$phase'.")
        if Auxiliary::script_debug("S4");
    $campaign_success = 0;
    $out_of_ideas     = 0;

    $phase_switch     = 0;
} # End of sub switch_phase


my @replay_runtime_fifo;
# - The value for duration finally assigned to some RQG run will be all time <= $duration.
# - In case the assigned duration is finally the deciding delimiter than it is expected that
#   the measured gentest runtime is slightly bigger than that assigned duration.
sub replay_runtime_fifo_init {

    my ($elements) = @_;
    # In order to have simple code and a smooth queue of computed values we precharge with the
    # duration (assigned/calculated during init).

    for my $num (0..($elements - 1)) {
        $replay_runtime_fifo[$num] = $duration;
    }

}

sub replay_runtime_fifo_update {

    my ($value) = @_;

    shift @replay_runtime_fifo;
    if ($value <= $duration) {
        push @replay_runtime_fifo, $value;
    } else {
        push @replay_runtime_fifo, $duration;
    }
    replay_runtime_fifo_print();
}

sub replay_runtime_fifo_print {

    my $adapted_duration = replay_runtime_adapt();
    say("DEBUG: Adapted duration : $adapted_duration , replay_runtime_fifo : " .
        join(" ", @replay_runtime_fifo));
}

sub replay_runtime_adapt {

    my $value;

    if      (PHASE_FIRST_REPLAY   eq $phase or
             PHASE_THREAD1_REPLAY eq $phase or
             PHASE_FINAL_REPLAY   eq $phase   ) {
        return $duration;
    }

    if      (DURATION_ADAPTION_NONE eq $duration_adaption) {
        $value = $duration;
    } elsif (DURATION_ADAPTION_MAX_MID eq $duration_adaption) {
        my @desc_fifo = sort { $b <=> $a } @replay_runtime_fifo;
        $value = shift @desc_fifo;
        $value = int(($value + $duration) / 2);
    } elsif (DURATION_ADAPTION_MAX eq $duration_adaption) {
        my @desc_fifo = sort { $b <=> $a } @replay_runtime_fifo;
        $value = shift @desc_fifo;
    } elsif (DURATION_ADAPTION_EXP eq $duration_adaption) {
        my $quadrat_sum = 0;
        foreach my $val (@replay_runtime_fifo) {
            $quadrat_sum += $val * $val;
        }
        say("MLML: quadrat_sum : $quadrat_sum");
        $value = int(sqrt($quadrat_sum / scalar @replay_runtime_fifo));
    } else {
        my $status = STATUS_INTERNAL_ERROR;
        say("INTERNAL ERROR: The duration_adaption '$duration_adaption' is unknown. " .
            "Will exit with status " . status2text($status) . "($status)");
        Batch::emergency_exit($status);
    }
    return $value;
}

sub report_replay {
# Try to make progress (have a better parent grammar as base) as soon as possible.
# This applies to the phase PHASE_GRAMMAR_SIMP only.

    my ($replay_grammar, $replay_grammar_parent) = @_;

    my $response = Batch::REGISTER_GO_ON;

    if (PHASE_GRAMMAR_SIMP ne $phase) {
        # Its a simplification phase where we do not try different competing grammars
        # in parallel. Hence we can postpone decision+loading to the point of time
        # when the main process of the RQG worker was reaped and the result gets processed.
        # So we do nothing.
    } else {
        if ($parent_grammar eq $replay_grammar_parent) {
            # The grammar used is a child of the current parent grammar and that means
            # its a first winner (!= a winner with outdated grammar).
            my $source = $workdir . "/" . $replay_grammar;
            my $target = $workdir . "/" . $best_grammar;
            Batch::copy_file($source,$target);
            # This means the child grammar used should become the base of the next
            # parent grammar.
            reload_grammar($replay_grammar);
            # Adding to @try_never_queue would be correct but we cannot do this because
            # the run has not ended yet (main process is active).
            # The ugly sideeffect would otherwise be
            # - added to @try_never_queue     -- fine
            # - removed from @try_run_queue   -- fine
            # - added to from @try_over_queue -- bad
            # Batch::add_to_try_never($order_id);
            # FIXME:
            # In case we know the total RQG runtime required for some lets say 85 till 95%
            # percentil (runtime_90) than we could stop all RQG workers with
            # - outdated parent grammar and
            # - being in a phase before gendata or
            #   being in a phase gendata or later and a time - start_time < 0.1 * runtime_90.
            $response = Batch::REGISTER_STOP_YOUNG;
        } else {
            # Its a replayer with outdated grammar.
            # Hence we can postpone decision+loading to the point of time when the main process
            # of the RQG worker was reaped and the result gets processed.
            # So we do nothing.
        }
    }
    return $response;
}

sub load_grammar {

    my ($grammar_file) = @_;

    # Actions of GenTest::Simplifier::Grammar_advanced::init
    # ...  Gentest::...Simplifier ....load_grammar($grammar_file);
    # ...  fill_rule_hash();
    # ...  print_rule_hash();
    # ...  analyze_all_rules(); -- Maintains counter except weight and removes unused rules
    # ...  compact_grammar();   -- collapseComponents (unique) and moderate inlining
    # Problem: This seems to reset if some rule was already processed.
    # $grammar_string = GenTest::Simplifier::Grammar_advanced::init(
    $grammar_string = GenTest::Simplifier::Grammar_advanced::init(
             $workdir . "/" . $grammar_file, $threads, $grammar_flags);
    my $iso_ts = isoTimestamp();
    load_step();
    Batch::write_result("$iso_ts          $grammar_file     loaded with threads = $threads " .
                        "==> new parent grammar '$parent_grammar'\n");
}

sub reload_grammar {

    my ($grammar_file) = @_;

    # Actions of GenTest::Simplifier::Grammar_advanced::reload_grammar
    # ...  Gentest::...Simplifier ....load_grammar($grammar_file);
    # ...  reset_rule_hash_values();  <-- This preserves the info that jobs for a rule were generated!
    # ...  print_rule_hash();
    # ...  analyze_all_rules(); -- Maintains counter except weight and removes unused rules
    # ...  compact_grammar();   -- collapseComponents (unique) and moderate inlining
    # Problem: This seems to reset if some rule was already processed.
    $grammar_string = GenTest::Simplifier::Grammar_advanced::reload_grammar(
             $workdir . "/" . $grammar_file, $threads, $grammar_flags);
    my $iso_ts = isoTimestamp();
    load_step();
    Batch::write_result("$iso_ts          $grammar_file     loaded with threads = $threads " .
                        "==> new parent grammar '$parent_grammar'\n");
}

sub load_step {

    if (not defined $grammar_string) {
        my $status = STATUS_INTERNAL_ERROR;
        say("ERROR: Loading a grammar file within Simplifier::Grammar_advanced failed. " .
            "Will ask for emergency exit." .
        Auxiliary::exit_status_text($status));
        Batch::emergency_exit($status);
    }
    my $status = GenTest::Simplifier::Grammar_advanced::calculate_weights();
    if($status) {
        my $status = STATUS_INTERNAL_ERROR;
        say("ERROR: GenTest::Simplifier::Grammar_advanced::calculate_weights failed. " .
            "Will ask for emergency exit." .
        Auxiliary::exit_status_text($status));
        Batch::emergency_exit($status);
    }
    # Dump this as new parent grammar
    $parent_grammar= "p" . Auxiliary::lfill0($parent_number,5) . ".yy";
    Batch::make_file($workdir . "/" . $parent_grammar, $grammar_string . "\n");
    $parent_number++;
}

1;

