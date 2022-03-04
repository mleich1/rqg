# Copyright (c) 2018, 2022 MariaDB Corporation Ab.
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

# Note about history and future of this script
# --------------------------------------------
# The concept and code here is only in some portions based on
#    util/simplify-grammar.pl
# There we have GNU General Public License version 2 too and
# Copyright (c) 2008, 2011 Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2013, Monty Program Ab.
# Copyright (c) 2018, MariaDB Corporation Ab.
#
# The amount of parameters (call of init by rqg_batch.pl + config file) is in the moment
# not that stable.
#

package Simplifier;

use strict;
use warnings;
use lib 'lib';
use lib '../lib';
use DBI;
use Carp;
use Data::Dumper;
use Getopt::Long;
use Time::HiRes;

use Auxiliary;
use Batch;
use GenTest;
use GenTest::Constants;
use GenTest::Grammar;
use GenTest::Properties;
use GenTest::Simplifier::Grammar_advanced;
use Verdict;

# We work on the copy of the config file to be provided by rqg_batch.pl
# ---------------------------------------------------------------------
use constant CONFIG_COPY_NAME       => 'Simplifier.cfg';

# Simplification phases, mode and the *_success variables
# -------------------------------------------------------
# The actual simplification phase (if maintained correct)
my $phase        = '';
# If switching from one simplification phase to the next is ahead or not
my $phase_switch = 0;

# SIMP_MODE_SOFT
# Attempt to shrink the actual best replaying grammar
# - with avoiding to destroy rules because that could change the semantics of the test.
#   == Never try to replace the last component of a rule by an empty string or similar.
#   Compared to the alternative SIMP_MODE_DESTRUCTIVE
#   - Advantage
#     No risk to change the semantics of the test and than maybe harvesting false positives.
#   - Disadvantage
#     In case of bad effects where this risk does not exist, a typical example are asserts
#     caused by concurrent activitity, some maybe a bit slower simplification speed.
use constant SIMP_MODE_SOFT         => 'simp_mode_soft';

# SIMP_MODE_DESTRUCTIVE
# Attempt to shrink the actual best replaying grammar
# - without avoiding to destroy rules.
#   == Trying to replace the last component of a rule by an empty string is allowed like in
#      the old simplification mechanism. We take the risk to maybe change the semantics of the test.
#   SIMP_MODE_DESTRUCTIVE optimizes this by trying
#   1. <top level rule>: { sleep 1 ; return undef } ;
#      <non top level rule>: ;
#   2. FIXME: Cutting out complete statements of multi statement queries should be also tried.
#   3. - n. Just the simplification attempts generated SIMP_MODE_SOFT too.
use constant SIMP_MODE_DESTRUCTIVE  => 'simp_mode_destructive';
my $simplify_mode;

# Pointer to the assigned chain of simplification phases.
my $simplify_chain;
# The actual chain (== what is left over of the original chain) of simplification phases.
my @simp_chain;
#
#
# About the values of the *_success variables
# -1 -- Running that phase is not planned
#  0 -- We are or were running that phase but had no success so far.
#  1 -- We are or were running that phase and had success.
#
# Any simplification achieved at all if tried at all.
my $simp_success           = -1;
#
# (Most probably) needed because of technical reasons.
use constant PHASE_SIMP_BEGIN       => 'simp_begin';
#
# Attempt to replay with the compactified initial grammar.
use constant PHASE_FIRST_REPLAY     => 'first_replay';
my $first_replay_success   = -1;
#
# Attempt to replay with the actual best replaying grammar and threads = 1,
use constant PHASE_THREAD1_REPLAY   => 'thread1_replay';
my $thread1_replay_success = -1;
#
# Attempt to shrink the amount of reporters, validators, transformers.
use constant PHASE_RVT_SIMP         => 'rvt_simp';
my $rvt_simp_success       = -1;
#
use constant PHASE_GRAMMAR_SIMP     => 'grammar_simp';
#
# Attempt to reduce the amount of threads (useful before 'grammar_clone')
# Try with n in (1, 2, 3, ...) but n < $threads.
# In case one replays than make all orders with more threads invalid and stop corresponding jobs.
# Limit the number of finished attempts.
use constant PHASE_THREAD_REDUCE    => 'thread_reduce';
my $thread_reduce_success  = -1;

# Attempt to clone rules
# - containing more than one alternative/component
# - being used more than once
# within the actual best replaying grammar.
# In case this is not a no op than there should a PHASE_GRAMMAR_SIMP round follow.
use constant PHASE_GRAMMAR_CLONE    => 'grammar_clone';
#
# Replace grammar language builtins like _digit and similar by rules doing the same.
# In case this is not a no op than there must a PHASE_GRAMMAR_SIMP round follow.
use constant PHASE_GRAMMAR_BUILTIN  => 'grammar_builtin';  # Implementation later if ever

# The variable serves for PHASE_GRAMMAR_SIMP, PHASE_GRAMMAR_CLONE,
# PHASE_GRAMMAR_BUILTIN all together.
my $grammar_simp_success   = -1;

# Attempt to reduce the gendata stuff -- NOT YET IMPLEMENTED
# ----------------------------------------------------------
# Raw ideas:
# 1. Run RQG tests based on same setup with   sqltrace=MarkErrors   till getting a replay.
# 2. Extract the SQLs executed with success maybe already in rqg.pl before archiving --> rqg.gds
#    cat rqg.gds rqg.sql > (new) rqg.sql
# 4. Run tests which follow with gendata_sql using (new) rqg.sql only (no other kind of gendata)
# 5. Find a good point of time when to shrink (new) rqg.sql with a parallelized version
#    of the algorithm by Andreas Zeller (simplify_mysqltest goes without parallelization).
use constant PHASE_GENDATA_SIMP     => 'gendata_simp';
# Given the fact that too many tests do not use zz files at all I hesitate to implement a
# simplifier for zz files.

#
# Attempt to replay with the actual best replaying grammar.
use constant PHASE_FINAL_REPLAY     => 'final_replay';
my $final_replay_success   = -1;
#
# (Most probably) needed because of technical reasons.
use constant PHASE_SIMP_END         => 'simp_end';

# This is the list of values which the user is allowed to set.
use constant PHASE_SIMP_ALLOWED_VALUE_LIST => [
      PHASE_FIRST_REPLAY, PHASE_THREAD1_REPLAY, PHASE_RVT_SIMP, PHASE_GRAMMAR_SIMP,
      PHASE_THREAD_REDUCE, PHASE_GRAMMAR_CLONE, PHASE_GRAMMAR_BUILTIN, PHASE_FINAL_REPLAY,
   ];
# FIXME:
# PHASE_THREAD1_REPLAY, PHASE_RVT_SIMP , PHASE_THREAD_REDUCE are capable to cut the replay
# runtime+complexity of test serious down.
# But especially the first two could also suffer from a low likelihood to replay.
my @simp_chain_default = ( # PHASE_SIMP_BEGIN,
                           PHASE_FIRST_REPLAY,
                           PHASE_THREAD1_REPLAY,
                           PHASE_RVT_SIMP,
                           PHASE_GRAMMAR_SIMP,
                           PHASE_THREAD_REDUCE,
                           PHASE_GRAMMAR_CLONE,
                           PHASE_FINAL_REPLAY,
                           # PHASE_SIMP_END,
                         );
my @simp_chain_replay =  ( # PHASE_SIMP_BEGIN,
                           PHASE_FIRST_REPLAY,
                           # PHASE_SIMP_END,
                         );

# To be implemented later if ever
# Attack_mode  --- not to be set from outside
# with (most probably) impact on
# - generate_order
# - validate_order
# - process_result
# - get_job   (deliver cl_snip for rqg.pl)
# Example:
# Lets assume we have some rule X, containing x components/alternatives, which is n times called.
# Hence we would have in the phase PHASE_GRAMMAR_CLONE n variants of it which leads in the worst
# case to ~ n * x simplification orders.
# Therefore it might be useful to have specialized simplification campaigns attacking
# 1. Only rules which would be cloned -- Goal is to make x smaller
# 2. Only the components of rules which use X -- Goal is to make n smaller
# Advantage compared to just running some additional conventional simplification before cloning:
#    We omit the less effective attacks on just once used rules.
#
#
# rqg_batch extracts workdir/vardir/build thread/bwlists
# Simplifier + combinator do not to know that except workdir if at all.
# Simplifier + combinator work with Batch.pm and rqg_batch does not!!

# Grammar simplification algorithms
# ---------------------------------
my $algorithm;
use constant SIMP_ALGO_WEIGHT       => 'weight';
use constant SIMP_ALGO_RANDOM       => 'random';  # not yet implemented
use constant SIMP_ALGO_MASKING      => 'masking'; # not yet implemented
# The algorithms SIMP_ALGO_RANDOM and SIMP_ALGO_MASKING are neither
# - strict required
#   SIMP_ALGO_WEIGHT seems to be matured enough for not having some fall back position.
# nor
# - in average more powerful than SIMP_ALGO_WEIGHT.
#   Per experience with historic implementations:
#   - SIMP_ALGO_RANDOM is all time serious slower than SIMP_ALGO_WEIGHT but serious less complex.
#   - SIMP_ALGO_MASKING is
#     - not serious less complex than SIMP_ALGO_WEIGHT
#     - sometimes roughly as fast as SIMP_ALGO_WEIGHT up till a bit faster
#     - most times serious faster than SIMP_ALGO_RANDOM
#     - sometimes serious slower than SIMP_ALGO_WEIGHT
#     In average over different simplification setups (especially different grammars) the historic
#     SIMP_ALGO_WEIGHT was faster than the historic SIMP_ALGO_MASKING.
#     The current SIMP_ALGO_WEIGHT contains several additional improvements.
#     One of them adds grammar simplifications like SIMP_ALGO_MASKING would do.
# So if SIMP_ALGO_RANDOM and/or SIMP_ALGO_MASKING get ever implemented than for academic and/or
# research purposes only.
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
#
# There are two main reasons why some order management is required:
# 1. The fastest grammar simplification mechanism
#    - works with chunks of orders
#      rule_a has 4 components --> 4 different orders.
#      And its easier to add the complete chunk on the fly than to handle only one order.
#    - repeats frequent the execution of some order because
#      - the order might have not had success on the previous execution but it looks as if repeating
#        that execution is the most promising we could do
#      - the order had success on the previous execution but it was a second "winner", so its
#        simplification could be not applied. But trying again is highly recommended.
#    - tries to get a faster simplification via bookkeeping about efforts invested in orders.
# 2. Independent of the goal of the batch run the batch tool might be forced to stop some ongoing
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
# Number of regular finished RQG runs for some orderid
use constant ORDER_EFFORTS_INVESTED  => 0;

# ORDER_PROPERTY1
# Snip of the command line for the RQG runner which consists of
# - some leading part    used for all simplification phases
# - some trailing part   used for the current simplification phase
use constant ORDER_PROPERTY1         => 1;
#
# ORDER_PROPERTY2 , comb_counter
# For example: Name of the grammar rule to shrink
use constant ORDER_PROPERTY2         => 2;
#
# ORDER_PROPERTY3
# For example: Component (string) to remove from the rule definition.
use constant ORDER_PROPERTY3         => 3;
#
# ORDER_EFFORTS_LEFT_OVER
# (Current) maximum number of allowed left over finished RQG runs with that order id.
# Create order --> ORDER_EFFORTS_LEFT_OVER = $trials
# A RQG run with that order was regular finished != stopped (treatment in following order)
# 1. It was a finished RQG run             --> decrement ORDER_EFFORTS_LEFT_OVER
# 2. In case the RQG run achieved a replay --> increment ORDER_EFFORTS_LEFT_OVER two times
# 3. In case the RQG run achieved no replay and ORDER_EFFORTS_LEFT_OVER <= 0
#    --> Stop all ongoing RQG runs using that order and
#        move the order id into %try_exhausted_hash + remove it from other hashes.
use constant ORDER_EFFORTS_LEFT_OVER => 4;

# Constants serving for more convenient printing of results in table layout
# -------------------------------------------------------------------------
use constant RQG_DERIVATE_TITLE    => 'Derivate used     ';
use constant RQG_PARENT_TITLE      => 'Parent of derivate';
use constant RQG_SPECIALITY_LENGTH => 18;             # Maximum is Title
my $title_line_part =                                                                " | " .
        Auxiliary::rfill(Batch::RQG_NO_TITLE,        Batch::RQG_NO_LENGTH)         . " | " .
        Auxiliary::rfill(Batch::RQG_WNO_TITLE,       Batch::RQG_WNO_LENGTH)        . " | " .
        Auxiliary::rfill(Verdict::RQG_VERDICT_TITLE, Verdict::RQG_VERDICT_LENGTH)  . " | " .
        Auxiliary::rfill(Batch::RQG_LOG_TITLE,       Batch::RQG_LOG_LENGTH)        . " | " .
        Auxiliary::rfill(Batch::RQG_ORDERID_TITLE,   Batch::RQG_ORDERID_LENGTH)    . " | " .
        Auxiliary::rfill(Batch::RQG_RUNTIME_TITLE,   Batch::RQG_RUNTIME_LENGTH)    . " | " .
        Auxiliary::rfill(RQG_DERIVATE_TITLE,         RQG_SPECIALITY_LENGTH)        . " | " .
        Auxiliary::rfill(RQG_PARENT_TITLE,           RQG_SPECIALITY_LENGTH)        . " | " .
        Auxiliary::rfill(Batch::RQG_INFO_TITLE,      Batch::RQG_INFO_LENGTH)       . "\n";

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
# Maximum number of trials in the phase PHASE_GRAMMAR_SIMP
#   The user cannot override that value via command line or config file.
#   Its just a high value for catching obvious "ill" simplification runs.
use constant TRIALS_SIMP            => 99999;

use constant QUERIES_DEFAULT        => 10000000;

# Parameters typical for Simplifier runs
# --------------------------------------

my $threads;
use constant THREADS_DEFAULT        => 10;


# Assembling of the RQG runner call via cl_snip (call line snips)
# ===============================================================
# 1. There is some first snip
#    - held by rqg_batch.pl and/or lib/Batch.pm
#    - containing settings extracted or computed from ARGV etc.
#      These settings serve for making some RQG run with arbitrary purpose like
#      - general bug hunting or replay of specific bug with Combinator/Variator
#      - grammar simplification
#      possible and free of clashes with concurrent RQG runs.
#    Example: --basedir... --vardir=... --mtr-build-thread=... etc.
#    This snip is not "known" to lib/Simplifier.pm.
#
# 2. The second snip which is mostly (*) valid(static) for all Simplification phases.
#    Example: "--gendata...." (But only as long as gendata is not target of a simplification phase.)
#    There are currently two reasons for handling this here:
#    1. Certain option settings are not known to rqg_batch.pl because they are contained
#       within the simplifier config file. And this file is currently read in the Simplifier only.
#       I also do not want to "pollute" other perl files too much with specifics of the Simplifier.
#    2. Also certain options might become in future also target of some simplification phase.
#       Than we need to handle that option here anyway.
my $cl_snip_all   = '';
#
# 3. The third snip is valid(static) for all steps in one Simplification phase
#    Example1: PHASE_THREAD1_REPLAY --> "--threads=1"
#    Example2: PHASE_GRAMMAR_SIMP   --> "--threads=$threads"
my $cl_snip_phase = '';
#
# 4. The forth snip is valid for one simplification step/job within a simplification phase given.
#    Example: PHASE_GRAMMAR_SIMP and job M --> "--grammar=c<n>.yy"
my $cl_snip_step  = '';
#
# The assembling will be like
#    rqg.pl <cl_snip_not_here1> $cl_snip_all $cl_snip_phase $cl_snip_step <cl_snip_not_here2>
#
# (*) In case of options where the last settings overwrites any setting before in call line
#     simplification phases can do temporary or permanent contradicting settings.
#     Example1: $cl_snip_all contains "--threads=10"
#               PHASE_THREAD1_REPLAY sets $cl_snip_phase = "... --threads=1"
#     Example2: Lets assume that PHASE_THREAD1_REPLAY reveals that we can replay with threads=1.
#               Than we could append a " --threads=1" to $cl_snip_all.

my $duration;
use constant DURATION_DEFAULT           => 300;
my $duration_adaption;
use constant DURATION_ADAPTION_NONE     => 'None';
use constant DURATION_ADAPTION_MAX_MID  => 'MaximumMiddle';
use constant DURATION_ADAPTION_MAX      => 'Maximum';
use constant DURATION_ADAPTION_EXP      => 'Experimental';

my $grammar_flags;

my $parent_number         = 0;  # The number of the next parent grammar to be generated.
my $parent_grammar;             # The name (no path) of the last parent grammar generated.
my $parent_grammar_string = ''; # The content of the last valid parent grammar.
my $grammar_string;
#    UNUSED ???  my $grammar_structure;
#
my $child_number  = 0;          # The number of the next last child grammar to be generated.
my $child_grammar;              # The name (no path) of the last child grammar generated.
#
my $best_grammar  = 'best_grammar.yy'; # The best/last of the replaying grammars.
                                       # == It is a grammar which was really tried.

sub get_shrinked_rvt_options;


# Concept for reporter/validator/transformer (RVT_SIMP) and grammar (GRAMMAR_SIMP)
# simplification phase including required variables
# ================================================================================
# Within a simplification phase one or more campaigns are run.
#
# $campaign_number
# ----------------
# Set to 1 in case of switching to phase PHASE_RVT_SIMP or PHASE_GRAMMAR_SIMP.
# Incremented whenever such a campaign ends and a new one gets started.
my $campaign_number  = 0;
#
# $campaign_number_max
# --------------------
# Just for the following case (up till today never seen):
# Caused by some defect within the code of PHASE_RVT_SIMP or PHASE_GRAMMAR_SIMP we get
# roughly endless additional campaigns.
# Per experience:
# - Mid 2019 with sub optimal simplification code 21 campaigns observed.
# - 2020 usually less than 10 campaigns.
my $campaign_number_max = 30;
#
# $campaign_success
# -----------------
# Set to
# - 0 when starting some campaign
# - incremented in case the problem was replayed within the current campaign.
# Used for deciding if to run some next campaign, requires 1 == $campaign_success, or not.
# Example:
# Phase is PHASE_GRAMMAR_SIMP
# In case we had during the last campaign (== Try to remove alternatives from grammar rules)
# success at all and we have tried all possible simplifications at least once than it makes
# sense to repeat such a campaign. This is especially important for concurrency bugs.
my $campaign_success = 0;
#
# $campaign_duds_since_replay
# ---------------------------
# Set to
# - 0 when
#   - starting some campaign
#   - having had a replay even if based on some outdated parent grammar
# - incremented in case the problem was replayed even if based on some outdated parent grammar
# Used for deciding if to abort the current campaign because of too long without further success.
# Example:
# Phase is PHASE_GRAMMAR_SIMP
# - observed
#   The previous campaign had success and so we started a new one.
#   This lasted ~ 1700 (unfortunate config) RQG runs without any replay till it ended.
# - observed and somehow a sibling of the observation above
#   We had during the current campaign some replays but the last one was too long ago.
# So basically we might have reached the smallest grammar with the current simplification approach.
#
#
# Solution:
# Stop the campaign in case $campaign_duds_since_replay >= 2 * Maximum of ($cut_steps , $trials)
# or similar.
my $campaign_duds_since_replay = 0;
#
#
# $out_of_ideas
# -------------
# Some state within a campaign. Rather "out of new ideas".
# Starting at some point all thinkable orders for simplifying some grammar were generated,
# already tried or currently in trial.
# This variable will be than set to 1.
# The variable is also used by lib/Combinator.pm and therefore it is placed in lib/Batch.pm.
# my $Batch::out_of_ideas = 0;
#
# In case we have reached the state "out of ideas" than we could either
# a) wait till all runs are finished and maybe start a new campaign.
#    This implies that all collected "knowlege" about currently valid orders like efforts invested
#    etc. gets lost because a campaign starts generating orders from scratch.
#    We will get for any possible simplification again an order.
#    The possible simplifications will not differ from the current known.
#    Only the order when which simplification should be tried is modified.
#    Possible advantage: That order could be better than extending the current campaign.
#    Disadvantage: At every end of a campaign we have some decreasing amount of active RQG
#                  runs which is less than the box is capable to run = sub optimal use of resources
#                  And there will be definitely more campaigns than in case b).
# or
# b) refill the @try_queue up to n times with the content of other queues/hashes containing
#    orders.
#    Possible advantage: That order is based on current available "knowledge" and could be better
#                        than what we get with a).
#    Possible disadvantage: The order of simplifications which we get by a) might be better.
#    Advantage: We have the decreasing amount of active RQG runs towards campaign end too.
#               But we will have less campaigns than in case a).
#
# Here we use a combination of both.
#
# $refill_number
# --------------
# Set to 0 when a campaign (RVT_SIMP and GRAMMAR_SIMP only) starts.
# During one campaign the @try_queue will get up to n times refilled by content of other queues.
# Hence $refill_number will get incremented per refill.
my $refill_number    = 0;
#
# Rough description of reasons for aborting some campaign
# -------------------------------------------------------
# The order of reasons is according to likelihood descending.
# 1. We have some amount of valid orders/simplification ideas.
#    Every of these orders was already tried more times than $trials without replay.
#    ==~ Any of these ideas were already tried quite often.
#        But this does not imply that every of them removes the capability to replay.
#        Hence in case the current campaign had
#        - some simplification success at all trying them again makes sense.
#          But we should rather do that in some new campaign with new statistics etc.
#        - no simplification success at all than we should switch the simplification phase.
#    Detail:
#    - All ideas/orders get ORDER_EFFORTS_LEFT_OVER precharged with $trials on creation.
#    - There is a decrement ORDER_EFFORTS_LEFT_OVER per RQG run finished.
#    - There are two increment ORDER_EFFORTS_LEFT_OVER per RQG run which replayed based on some
#      outdated parent grammar.
#    - Orders/ideas which replayed based on the actual parent grammar get removed.
# 2. We had nothing else than 2 * trials finished RQG runs without replay since the start of the
#    campaign or the last replay.
#    ==~ The forecast derived from history is so bad that a drastic change of the approach
#        (new campaign starting with differect statistics or switch to next simplification phase)
#        is recommended.
# 3. No further simplification of the grammar is thinkable.
#    artificial and somehow "ill" example:
#    - threads = 1
#    - the grammar contains only
#      thread1: { sleep 1 ; return undef } ;
#      This means there is no
#      - component which could be removed because there is only one component left over
#      - component with a non "dead" query which could be replaced by some "dead" query.
#        "{ sleep 1 ; return undef }" is already a "dead" query.
#    - Imagine the test harvests an assert because some reporter is bad programmed or runs some
#      SQL causing the assert.
#    ==~ There is no (automatic) simplification idea left over.
# 4. We had 9999 RQG runs within that campaign.
#    ==~ Its not unlikely that we suffered from a defect within the simplifier.
#        So extending the current campaign is quite questionable.
#


# Additional parameters maybe being target of simplification
my $rvt_options = '';
my @reporter_array;
my %reporter_hash;
my @transformer_array;
my %transformer_hash;
my @validator_array;
my %validator_hash;

$| = 1;

my $config_file;
my $workdir;

my $stop_on_replay;
sub init {
    ($config_file, $workdir, $stop_on_replay) = @_;
    # Based on the facts that
    # - Combinator/Simplifier init gets called before any Worker is running
    # - this init will be never called again
    # we can run safe_exit($status) and do not need to initiate an emergency_exit.
    #
    my $who_am_i = "Simplifier::init:";
    if (3 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: $who_am_i Three parameters " .
                    "(config_file, workdir, stop_on_replay) are required.");
        safe_exit($status);
    }

    Carp::cluck("# " . isoTimestamp() . " DEBUG: $who_am_i Entering routine with variables " .
                "(config_file, workdir, verdict_setup, basedir_info).\n")
        if Auxiliary::script_debug("S1");

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

    my $verdict_file = $workdir . "/" . Verdict::VERDICT_CONFIG_FILE;
    if (not -f $verdict_file) {
        my $status = STATUS_INTERNAL_ERROR;
        say("INTERNAL ERROR: The verdictfile '$verdict_file' does not exist or is " .
            "not a plain file.");
        Batch::emergency_exit($status);
    }

    my $source_info_file = $workdir . "/" . Auxiliary::SOURCE_INFO_FILE;
    if (not -f $source_info_file) {
        my $status = STATUS_INTERNAL_ERROR;
        say("INTERNAL ERROR: The file '$source_info_file' with information about RQG and Server " .
            "directories and and Git information does not exist or is not a plain file.");
        Batch::emergency_exit($status);
    }

    if (not defined $stop_on_replay) {
        $stop_on_replay = 0;
    }

    my $config_file_copy = $workdir . "/" . CONFIG_COPY_NAME;
    if (not File::Copy::copy($config_file, $config_file_copy)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Copying the config file '$config_file' to '$config_file_copy' failed : $!. " .
            Auxiliary::exit_status_text($status));
        safe_exit($status);
    }

#   if (not defined $verdict_setup or '' eq $verdict_setup) {
#       my $status = STATUS_ENVIRONMENT_FAILURE;
#       say("ERROR: $who_am_i \$verdict_setup is undef or '' " .
#           Auxiliary::exit_status_text($status));
#       safe_exit($status);
#   }
#   if (not defined $basedir_info or '' eq $basedir_info) {
#       my $status = STATUS_ENVIRONMENT_FAILURE;
#       say("ERROR: $who_am_i \$basedir_info is undef or '' " .
#           Auxiliary::exit_status_text($status));
#       safe_exit($status);
#   }


# ---------------------------------------------

    my $queries;

    # This variable is for the initial grammar file. That file will be used in the
    # the current routine only.
    my $grammar_file;

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
        'trials=i'                  ,                           # Handled here (max no of finished trials for certain phases only)
        'duration=i'                ,                           # Handled here
        'max_rqg_runtime=i'         ,                           # Handled here
        'queries=i'                 ,                           # Handled here
#       'seed=s'                    => \$seed,                  # Handled(Ignored!) here
    #   'force'                     => \$force,                 # Swallowed and handled by rqg_batch
#       'no-mask'                   => \$no_mask,               # Handled(Ignored!) here
        'grammar=s'                 => \$grammar_file,          # Handle here. Requirement caused by Simplifier
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
    #   'stop_on_replay:1'          => \$stop_on_replay,        # Swallowed and handled by rqg_batch
    #   'servers=i'                 => \$servers,               # Swallowed and handled by rqg_batch
        'threads=i'                 ,                           # Handled here (placed in cl_snip)  ### FIXME, is that right?
    #   'discard_logs'              => \$discard_logs,          # Swallowed and handled by rqg_batch
    #   'discard-logs'              => \$discard_logs,          # Swallowed and handled by rqg_batch
    #   'script_debug=s'            => \$script_debug,          # Swallowed and handled by rqg_batch
    #   'runid:i'                   => \$runid,                 # No use here
        'simplify_mode:s'           => \$simplify_mode,         # For Simplifier only.
        'simplify_chain:s'          => \$simplify_chain,        # For Simplifier only.
        'algorithm:s'               => \$algorithm,             # For Simplifier only.
                                                       )) {
        # Somehow wrong option.
        # help();
        my $status = STATUS_ENVIRONMENT_FAILURE;
        safe_exit($status);
    };
    my $argv_remain = join(" ", @ARGV);
    if (defined $argv_remain and $argv_remain ne '') {
        say("WARN: The following command line content is left over ==> gets ignored. ->$argv_remain<-");
    }

    # Read the options found in config_file.
    # --------------------------------------
    # We work with the copy only!
    # config_file_copy
    #   'seed=s'                    => \$seed,                  # Handled here

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
                    'max_rqg_runtime',
                    'trials',                                   # Handled
                    'algorithm',
                    'search_var_size',
                    'simplify_chain',
                    'simplify_mode',
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
                    'validators'        => 'None',
                    'grammar_flags'     => undef,
                    'duration_adaption' => DURATION_ADAPTION_MAX,
                    'search_var_size'   => 100000000,
                    'simplify_chain'    => \@simp_chain_default,
                    'simplify_mode'     => SIMP_MODE_DESTRUCTIVE,
        }
    );

    if (defined $config->simplify_mode) {
        $simplify_mode = $config->simplify_mode;
    }
    say("INFO: simplify_mode is '$simplify_mode'.");

    if (defined $simplify_chain) {
        if ($simplify_chain eq '' or lc($simplify_chain) eq 'default' ) {
            say("INFO: simplify_chain is '$simplify_chain' hence loading the default chain.");
            @simp_chain = @simp_chain_default;
        } else {
            $simplify_chain = Auxiliary::input_to_list($simplify_chain);
            if (not defined $simplify_chain) {
                # Auxiliary::input_to_list delivered undef because of trouble (already reported).
                safe_exit(99);
            }
            @simp_chain = @$simplify_chain;
        }
    } else {
        if (defined $config->simplify_chain) {
            @simp_chain = @{$config->simplify_chain};
        }
    }

    say("INFO: simp_chain : '" . join("' ==> '",@simp_chain) . "'");
    if ($stop_on_replay) {
        # Replace the actual @simp_chain because
        # 1. stop_on_replay set on commandline has higher priority than config_file content.
        # 2. Exact PHASE_FIRST_REPLAY is needed but maybe not in @simp_chain.
        @simp_chain = @simp_chain_replay;
        say("INFO: stop_on_replay is set. Hence setting simp_chain : '" .
            join("' ==> '",@simp_chain) . "'");
    }

    foreach my $phase_c (@simp_chain) {
        my $result = Auxiliary::check_value_supported ('simplify_chain',
                                                       PHASE_SIMP_ALLOWED_VALUE_LIST, $phase_c);
        if ($result != STATUS_OK) {
            safe_exit(99);
        }
    }

    @simp_chain = (PHASE_SIMP_BEGIN, @simp_chain);
    push @simp_chain, PHASE_SIMP_END;

    # Note
    # ----
    # $grammar (value taken from ARGV)
    # $config->grammar (value taken from config file top level variables)
    # $config->rqg_options->{grammar} (value taken from config file rqg_options section)
    # get_job returns some command line snip to the caller.
    # Around the end of that snip can be a ' --grammar=<dynamic decided grammar>'.
    # The grammar here is only the initial grammar to be used at begin of simplification process.

    $config->printProps();
    my $rqg_options_begin = $config->genOpt('--', 'rqg_options');

    my $warn1 = "WARN: The grammar file finally used is the one found on highest level (" .
                "command line, config file top level, config file rqg_option section).\n" .
                "WARN: All assignments to redefine/mask/mask_level on any level will get ignored.";
    my $warn2 = '';
    if (defined $grammar_file and $grammar_file ne '') {
        my $info = "Grammar '$grammar_file' was assigned via rqg_batch.pl call.";

        say("DEBUG: $info") if Auxiliary::script_debug("S2");
        $warn1 .= "\nINFO: $info";

        # Only $grammar (and not redefine, mask*) is allowed in config file top level.
        my $other = $config->grammar;
        if (defined $other) {
            $warn2 .= "\nWARN: Removing the grammar assignment in config file top level.";
            $config->unsetProperty('grammar');
        }
        if (exists $config->rqg_options->{'grammar'}) {
            $warn2 .= "\nWARN: Removing the grammar assignment inside of the RQG options section.";
            delete $config->rqg_options->{'grammar'};
        }
    } else {
        $grammar_file = $config->grammar;
        if (defined $grammar_file and $grammar_file ne '') {
            my $info = "Grammar '$grammar_file' was assigned in config file top level.";
            say("DEBUG: $info") if Auxiliary::script_debug("S2");
            $warn1 .= "\nINFO: $info";

            if (exists $config->rqg_options->{'grammar'}) {
                $warn2 .= "\nWARN: Removing the grammar assignment inside of the RQG options section.";
                delete $config->rqg_options->{'grammar'};
            }
        } else {
            $grammar_file = $config->rqg_options->{'grammar'};
            if (defined $grammar_file and $grammar_file ne '') {
                my $info = "Grammar '$grammar_file' was assigned in config file rqg_option section.";
                say("DEBUG: $info") if Auxiliary::script_debug("S2");
                $warn1 .= "\nINFO: $info";
            } else {
                my $status = STATUS_ENVIRONMENT_FAILURE;
                say("ERROR: Grammar neither via command line nor via config file assigned. " .
                Auxiliary::exit_status_text($status));
                safe_exit($status);
            }
        }
    }

    # Any assignments of redefine, mask and mask_level (only possible in RQG options section
    # of config file must get ignored.
    if (exists $config->rqg_options->{'redefine'}) {
        $warn2 .= "\nWARN: Removing the redefine assignment inside of the RQG options section.";
        delete $config->rqg_options->{'redefine'};
    }
    if (exists $config->rqg_options->{'mask'}) {
        $warn2 .= "\nWARN: Removing the mask assignment inside of the RQG options section.";
        delete $config->rqg_options->{'mask'};
    }
    if (exists $config->rqg_options->{'mask_level'}) {
        $warn2 .= "\nWARN: Removing the mask_level assignment inside of the RQG options section.";
        delete $config->rqg_options->{'mask_level'};
    }
    if (exists $config->rqg_options->{'no_mask'}) {
        delete $config->rqg_options->{'no_mask'};
    }

    if ($warn2 ne '') {
        say($warn1 . $warn2);
    }

    # $trials cannot be in the command line snip.
    $trials =        $config->trials;
    my $bad_trials = $config->rqg_options->{'trials'};
    if (defined $bad_trials) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: trials found between 'rqg_options'. The Simplifier does not support that. " .
            "Abort. " . Auxiliary::exit_status_text($status));
        safe_exit($status);
    }

    # $duration could be part of the command line snip.
    # But the value here is only the base for the computation of the
    # ' --duration=<dynamic decided value>' added to the end of that snip.
    $duration = $config->duration;
    if (defined $duration and $duration >= 0) {
        say("DEBUG: duration '$duration' was assigned via rqg_batch.pl call or " .
            "within config file top level.\n" .
            "DEBUG: Wiping all other occurrences of settings for duration.")
            if Auxiliary::script_debug("S2");
        delete $config->rqg_options->{'duration'};
    } else {
        $duration = $config->rqg_options->{'duration'};
        if (defined $duration and $duration >= 0) {
            say("DEBUG: duration '$duration' was assigned in config file rqg_option section. " .
                "Wiping all other occurrences of settings for duration.")
            if Auxiliary::script_debug("S2");
            delete $config->rqg_options->{'duration'};
        } else {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: duration neither via command line nor via config file assigned. " .
            Auxiliary::exit_status_text($status));
            safe_exit($status);
        }
    }
    $cl_snip_all .= " --duration=" . $duration;

    # $duration_adaption cannot be in the command line snip.
    # But it has an impact during computation of the ' --duration=<dynamic decided value>'
    # added to the end of that snip later.
    $duration_adaption = $config->duration_adaption;
    my $bad_duration_adaption = $config->rqg_options->{'duration_adaption'};
    if (defined $bad_duration_adaption) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: duration_adaption found between 'rqg_options'. This is wrong. Abort. " .
            Auxiliary::exit_status_text($status));
        safe_exit($status);
    }

    my $mrr = $config->max_rqg_runtime;
    if (defined $mrr and $mrr >= 0) {
        say("DEBUG: max_rqg_runtime '$mrr' was assigned via rqg_batch.pl call or " .
            "within config file top level.\n" .
            "DEBUG: Wiping all other occurrences of settings for max_rqg_runtime.")
            if Auxiliary::script_debug("S2");
        delete $config->rqg_options->{'max_rqg_runtime'};
    } else {
        $mrr = $config->rqg_options->{'max_rqg_runtime'};
        if (defined $mrr and $mrr >= 0) {
            say("DEBUG: max_rqg_runtime '$mrr' was assigned in config file rqg_option section. " .
                "Wiping all other occurrences of settings for duration.")
            if Auxiliary::script_debug("S2");
            delete $config->rqg_options->{'max_rqg_runtime'};
        } else {
            say("DEBUG: max_rqg_runtime was not assigned. Setting it to the default.")
                if Auxiliary::script_debug("S2");
            $mrr = $duration + 1800;
        }
    }
    say("INFO: max_rqg_runtime in s: $mrr");
    Batch::set_max_rqg_runtime($mrr);

    # $queries can be in the the command line snip.
    $queries = $config->queries;
    if (defined $queries and $queries >= 0) {
        say("DEBUG: queries '$queries' was assigned via rqg_batch.pl call or " .
            "within config file top level.\n" .
            "DEBUG: Wiping all other occurrences of settings for queries.")
            if Auxiliary::script_debug("S2");
        delete $config->rqg_options->{'queries'};
    } else {
        $queries = $config->rqg_options->{'queries'};
        if (defined $queries and $queries >= 0) {
            say("DEBUG: queries '$queries' was assigned in config file rqg_option section. " .
                "Wiping all other occurrences of settings for queries.")
            if Auxiliary::script_debug("S2");
            delete $config->rqg_options->{'queries'};
        } else {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: queries neither via command line nor via config file assigned. " .
            Auxiliary::exit_status_text($status));
            safe_exit($status);
        }
    }
    $cl_snip_all .= " --queries=" . $queries;

    # $threads can be in the command line snip.
    # ' --threads=$threads' added to the end of that snip except ' --threads=1' is
    # added from whatever reason.
    $threads = $config->threads;
    if (defined $threads and $threads >= 0) {
        say("DEBUG: threads '$threads' was assigned via rqg_batch.pl call or " .
            "within config file top level.\n" .
            "DEBUG: Wiping all other occurrences of settings for threads.")
            if Auxiliary::script_debug("S2");
        delete $config->rqg_options->{'threads'};
    } else {
        $threads = $config->rqg_options->{'threads'};
        if (defined $threads and $threads >= 0) {
            say("DEBUG: threads '$threads' was assigned in config file rqg_option section. " .
                "Wiping all other occurrences of settings for threads.")
            if Auxiliary::script_debug("S2");
            delete $config->rqg_options->{'threads'};
        } else {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: threads neither via command line nor via config file assigned. " .
            Auxiliary::exit_status_text($status));
            safe_exit($status);
        }
    }
########    $cl_snip_all .= " --threads=" . $threads;

    # This parameter could be part of the command line snip.
    $algorithm = $config->algorithm;
    my $bad_algorithm = $config->rqg_options->{'algorithm'};
    if (defined $bad_algorithm) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: algorithm found between 'rqg_options'. This is wrong. Abort. " .
            Auxiliary::exit_status_text($status));
        safe_exit($status);
    }

    # Add it in order to be sure that the grammar gets not mangled per mistake.
    $cl_snip_all .= " --no_mask";
    delete $config->rqg_options->{'no_mask'};

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

    # $config->reporters , $config->validators and $config->transformers are all pointers to
    # corresponding arrays.
    my $reporters = $config->reporters;
    if (defined $reporters) {
        if (defined $config->rqg_options->{'reporters'}) {
            say("WARN: Wiping the settings for reporters within the rqg options because other " .
                "(command line or top level in config file) exist and have precedence.")
            if Auxiliary::script_debug("S2");
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
    my $array_ref;
    my $hash_ref;
    ($array_ref, $hash_ref) = Auxiliary::unify_rvt_array($reporters);
    @reporter_array = @{$array_ref};
    %reporter_hash  = %{$hash_ref};
    # say("DEBUG: Reporters : ->" . join("<->", @reporter_array) . "<-") if Auxiliary::script_debug("S2");
    # For experimenting:
    # %reporter_hash  = ();
    say("DEBUG: Reporters : ->" . join("<->",  sort keys %reporter_hash) . "<-")
        if Auxiliary::script_debug("S2");

    my $validators = $config->validators;
    if (defined $validators) {
        if (defined $config->rqg_options->{'validators'}) {
            say("WARN: Wiping the settings for validators within the rqg options because other " .
                "(command line or top level in config file) exist and have precedence.")
            if Auxiliary::script_debug("S2");
            delete $config->rqg_options->{'validators'};
        }
    } else {
        $validators = $config->rqg_options->{'validators'};
        delete $config->rqg_options->{'validators'};
    }
    ($array_ref, $hash_ref) = Auxiliary::unify_rvt_array($validators);
    @validator_array = @{$array_ref};
    %validator_hash  = %{$hash_ref};
    # say("DEBUG: Validators : ->" . join("<->", @validator_array) . "<-") if Auxiliary::script_debug("S2");
    say("DEBUG: Validators : ->" . join("<->",  sort keys %validator_hash) . "<-")
        if Auxiliary::script_debug("S2");

    my $transformers = $config->transformers;
    if (defined $transformers) {
        if (defined $config->rqg_options->{'transformers'}) {
            say("WARN: Wiping the settings for transformers within the rqg options because other " .
                "(command line or top level in config file) exist and have precedence.")
            if Auxiliary::script_debug("S2");
            delete $config->rqg_options->{'transformers'};
        }
    } else {
        $transformers = $config->rqg_options->{'transformers'};
        delete $config->rqg_options->{'transformers'};
    }
    ($array_ref, $hash_ref) = Auxiliary::unify_rvt_array($transformers);
    @transformer_array = @{$array_ref};
    %transformer_hash  = %{$hash_ref};
    # say("DEBUG: Transformers : ->" . join("<->", @transformer_array) . "<-") if Auxiliary::script_debug("S2");
    say("DEBUG: Transformers : ->" . join("<->",  sort keys %transformer_hash) . "<-")
        if Auxiliary::script_debug("S2");

    # say("RVT options : " . get_shrinked_rvt_options); --> abort
    # say("RVT options : " . get_shrinked_rvt_options(undef)); --> abort
    # say("RVT options : " . get_shrinked_rvt_options(undef, 'A')); --> abort
    # say("RVT options : " . get_shrinked_rvt_options(1, undef)); --> abort
    # say("RVT options : " . get_shrinked_rvt_options(undef,undef)); --> get string
    # say("RVT options : " . get_shrinked_rvt_options('omo','omo')); --> abort
    # say("RVT options : " . get_shrinked_rvt_options('reporter','omo')); --> undef
    # say("RVT options : " . get_shrinked_rvt_options('reporter','Backtrace'));
    # say("RVT options : " . get_shrinked_rvt_options('reporter','ErrorLog'));

    my $rqg_options_end = $config->genOpt('--', 'rqg_options');
    if (Auxiliary::script_debug("S5")) {
        say("DEBUG: RQG options before 'mangling' ->$rqg_options_begin<-");
        say("DEBUG: RQG options after  'mangling' ->$rqg_options_end<-");
    }

    if (not defined $grammar_file) {
        say("ERROR: Grammar file is not defined.");
        help_();
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("$0 will exit with exit status " . status2text($status) . "($status)");
        safe_exit($status);
    } else {
        if (! -f $grammar_file) {
            say("ERROR: Grammar file '$grammar_file' does not exist or is not a plain file.");
            help();
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("$0 will exit with exit status " . status2text($status) . "($status)");
            safe_exit($status);
        }
    }
    $grammar_flags = $config->grammar_flags;

    # Actions of GenTest::Simplifier::Grammar_advanced::init
    # ...  load_grammar_from_files($grammar_file);
    # ...  fill_rule_hash();
    # ...  print_rule_hash();
    # ...  set_default_rules_for_threads()
    # ...  fill_rule_hash();
    # ...  analyze_all_rules(); -- Maintains counter except weight and removes unused rules
    # ...  compact_grammar();   -- collapseComponents (unique) and moderate inlining
    $grammar_string = GenTest::Simplifier::Grammar_advanced::init($grammar_file, $threads,
                                                                  20, $grammar_flags);
    if (not defined $grammar_string) {
        say("ERROR: Simplifier::Grammar_advanced::init returned an undef grammar string.");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("$0 will exit with exit status " . status2text($status) . "($status)");
        safe_exit($status);
    }

    # Aborts if
    # - $grammar_string is not defined
    # - creation of parent grammar file fails
    make_parent_from_string ($grammar_string);
    say("Grammar ->$grammar_string<-") if Auxiliary::script_debug("S4");
    my $g_flags;
    if (not defined $grammar_flags) {
        $g_flags = '<undef>';
    } else {
        $g_flags = $grammar_flags;
    }

    my $verdict_setup = Auxiliary::getFileSlice(    $verdict_file, 1000000);
    my $source_info   = Auxiliary::getFileSlice($source_info_file, 1000000);
    my $iso_ts = isoTimestamp();
    $verdict_setup =~ s/^/$iso_ts /gm;
    my $header =
"$iso_ts Simplifier init ================================================================================================\n" .
"$iso_ts workdir                                  : '$workdir'\n"                                                            .
"$iso_ts config_file assigned                     : '$config_file'\n"                                                        .
"$iso_ts config file processed (is copy of above) : '$config_file_copy'\n"                                                   .
"$iso_ts ----------------------------------------------------------------------------------------------------------------\n" .
$source_info                                                                                                                .
"$iso_ts ----------------------------------------------------------------------------------------------------------------\n" .
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
"$iso_ts simplify_mode (used for grammar simplification)         : '$simplify_mode' (Default '" . SIMP_MODE_DESTRUCTIVE . "')\n"      .
"$iso_ts grammar_flags                                           : $g_flags (Default undef)\n"                               .
"$iso_ts ----------------------------------------------------------------------------------------------------------------\n" .
"$iso_ts call line additions : $cl_snip_all\n"                                                                               .
"$iso_ts ----------------------------------------------------------------------------------------------------------------\n" .
"$iso_ts Verdict setup\n"                                                                                                    .
$verdict_setup                                                                                                               .
"$iso_ts ================================================================================================================\n" ;
    Batch::write_result($header);
    Batch::write_setup($header);
    my $header1 =  Auxiliary::rfill(Verdict::RQG_VERDICT_TITLE, Verdict::RQG_VERDICT_LENGTH) . " | " .
                   Auxiliary::rfill(Batch::RQG_INFO_TITLE     , Batch::RQG_INFO_LENGTH)      . " | " .
                   Batch::RQG_CALL_SNIP_TITLE                                                . " | " .
                   Auxiliary::lfill(Batch::RQG_NO_TITLE       , Batch::RQG_NO_LENGTH)        . " | " .
                   Auxiliary::rfill(Batch::RQG_LOG_TITLE      , Batch::RQG_LOG_LENGTH)       . "\n" ;
    Batch::write_setup($header1);

    $cl_snip_all .= " " . $rqg_options_end . " " . $mysql_options ;

    replay_runtime_fifo_init(10, $duration);
    estimate_runtime_fifo_init(20, $duration);

    $phase        = shift @simp_chain;
    $phase_switch = 1;

    say("DEBUG: Leaving 'Simplifier::init") if Auxiliary::script_debug("S6");

} # End sub init


sub get_job {
# 1. If 1 == $phase_switch
#    - bail out if there are left over active RQG runs because a new campaign or phase
#      starts with new statistics. Hence their results will not fit and they should have
#      been already stopped.
#    - run up till 10 phase switch attempts (end either up in running a next campaign
#      or switching really to the next phase) followed by
#      - giving up if $phase eq PHASE_SIMP_END
#      - running 2. otherwise
# 2. If 0 == $phase_switch because having that value from begin on or getting that after
#    running 1
# 2.1 Ask for the id of some order
#     If
#     - one got check if its valid
#       - yes -> prepare the base (grammars, call line snips etc.) for the job and go to 3.
#       - no  -> mark it as invalid and go to 2.1 again
#     - none got try to reactivate old orders taken out of use/focus but not known to be invalid
#       and go to 2.1 again
# 3. If having
#    - no valid order got at all set $phase_switch = 1 and return undef
#    - a valid order return a description of the job
#
    my $who_am_i = "Simplifier::get_job:";

    my $order_id;
    my @job;
# In lib/Batch.pm
# use constant JOB_CL_SNIP    => 0;
# use constant JOB_ORDER_ID   => 1;
# use constant JOB_MEMO1      => 2;  # Child  grammar or Child rvt_snip
# use constant JOB_MEMO2      => 3;  # Parent grammar or Parent rvt_snip
# use constant JOB_MEMO3      => 4;  # Adapted duration

    # Safety measure
    my ($active) = @_;

    say("DEBUG: $who_am_i phase_switch($phase_switch), active($active), phase($phase)")
         if Auxiliary::script_debug("S6");

    # For experimenting:
    # $active = 10;
    if ($phase_switch) {
        if(not defined $active or 0 != $active) {
            my $status = STATUS_INTERNAL_ERROR;
            Carp::cluck("INTERNAL ERROR: Wrong call of Simplifier::getjob : active is not 0.");
            Batch::emergency_exit($status);
        } else {
            # switch_phase();
            my $rounds = 10;
            while ($phase_switch and $rounds) {
                switch_phase();
                # Setting $phase_switch = 0 if at all is made in switch_phase().
                $rounds--;
            }
            if ($phase eq PHASE_SIMP_END) {
                say("DEBUG: $who_am_i phase_switch($phase_switch), active($active), phase($phase)")
                     if Auxiliary::script_debug("S6");
                say("DEBUG: $who_am_i Setting give_up = 2 because phase($phase)")
                     if Auxiliary::script_debug("S4");
                $Batch::give_up = 2;
                return undef;
            }
        }
    }

    while (not defined $order_id) {
        say("DEBUG: $who_am_i Begin of loop for getting an order.") if Auxiliary::script_debug("S6");
        $order_id = Batch::get_order();
        if (defined $order_id) {
            say("DEBUG: $who_am_i Batch::get_order delivered order_id $order_id.")
                if Auxiliary::script_debug("S6");
            my $order_is_valid = 0;
                if (PHASE_FIRST_REPLAY   eq $phase or
                    PHASE_THREAD1_REPLAY eq $phase or
                    PHASE_FINAL_REPLAY   eq $phase   ) {
                    # Any order is valid. The sufficient enough tried were already sorted out above.
                    $order_is_valid = 1;
                    # The grammar to be used is the parent grammar when entering the phase.
                    # FIXME: Shouldn't $cl_snip_phase = " --grammar=" . $workdir . "/" . $child_grammar; ?
                    # FIXME: Shouldn't $cl_snip_step = " --threads=1" for PHASE_THREAD1_REPLAY?
                    $job[Batch::JOB_CL_SNIP]  = $cl_snip_all . $cl_snip_phase .
                                         " --grammar=" . $workdir . "/" . $child_grammar;
                    $job[Batch::JOB_ORDER_ID] = $order_id;
                    $job[Batch::JOB_MEMO1]    = undef;     # undef or Child grammar or
                                                           # Child rvt_snip
                    $job[Batch::JOB_MEMO2]    = undef;     # undef or Parent grammar or
                                                           # Parent rvt_snip
                    $job[Batch::JOB_MEMO3]    = $duration; # We take the full duration!
                } elsif (PHASE_THREAD_REDUCE eq $phase) {
                    # The grammar to be used is the parent grammar when entering the phase.
                    $job[Batch::JOB_CL_SNIP]  = $cl_snip_all . $cl_snip_phase .
                                         " --grammar=" . $workdir . "/" . $child_grammar;
                    $job[Batch::JOB_ORDER_ID] = $order_id;
                    $job[Batch::JOB_MEMO1]    = $order_array[$order_id][ORDER_PROPERTY2];
                                                           # reduced number of threads
                    $job[Batch::JOB_MEMO2]    = undef;     # undef or Parent grammar or
                                                           # Parent rvt_snip
                    $job[Batch::JOB_MEMO3]    = $duration; # We take the full duration!
                    if ($job[Batch::JOB_MEMO1] >= $threads) {
                        say("DEBUG: Order id '$order_id' trying to change threads from $threads " .
                            " to " . $job[Batch::JOB_MEMO1] . " is invalid.")
                            if Auxiliary::script_debug("S4");
                        $order_is_valid = 0;
                        Batch::add_to_try_never($order_id);
                        $order_id = undef;
                    } else {
                        $cl_snip_step   = " --threads=" . $job[Batch::JOB_MEMO1];
                        $job[Batch::JOB_CL_SNIP]  = $cl_snip_all . $cl_snip_phase . $cl_snip_step ;
                        $order_is_valid = 1;
                    }
                } elsif (PHASE_RVT_SIMP eq $phase) {
                    my $option_to_attack = $order_array[$order_id][ORDER_PROPERTY2];
                    my $value_to_remove  = $order_array[$order_id][ORDER_PROPERTY3];
                    my $cl_snip_step     = get_shrinked_rvt_options($option_to_attack,
                                                                    $value_to_remove, 0);
                    if (not defined $cl_snip_step) {
                        say("DEBUG: Order id '$order_id' with option_to_attack " .
                            "'$option_to_attack' value_to_remove '$value_to_remove' is invalid.")
                            if Auxiliary::script_debug("S4");
                        $order_is_valid = 0;
                        Batch::add_to_try_never($order_id);
                        $order_id = undef;
                    } else {
                        my $cl_snip_parent = get_shrinked_rvt_options(undef, undef, 0);
                        $job[Batch::JOB_CL_SNIP]  = $cl_snip_all . $cl_snip_phase . $cl_snip_step .
                                             " --grammar=" . $workdir . "/" . $child_grammar;
                        $job[Batch::JOB_ORDER_ID] = $order_id;
                        $job[Batch::JOB_MEMO1]    = $cl_snip_step;
                        $job[Batch::JOB_MEMO2]    = $cl_snip_parent;
                        $job[Batch::JOB_MEMO3]    = $duration; # We take the full duration!
                    }
                } elsif (PHASE_GRAMMAR_SIMP eq $phase) {

                    # $order_id is the id of the main (bookkeeping is only for that) order.
                    # The main order is picked by upper level routines depending on the history
                    # of the orders.
                    # The maybe added extra order id's serve to accelerate the simplification
                    # process. They are picked random.
                    # The order ids to be used are kept in @oid_list.
                    # Thinkable bad scenario:
                    # We get a replay for the job based on order id 13. But some other job was
                    # faster and caused some new parent grammar. Therefore either
                    # - (not likely) order id 13 becomes invalid or
                    # - (likely) order id 13 gets promoted.
                    # The promotion causes a disadvantage in case one of the random orders
                    # - was the one and only reason for the replay
                    # - caused that order id 13 had no impact on the grammar at all
                    # Countermeasures:
                    # 1. The last redefine in the generated grammar must belong to order id 13.
                    #    Therefore none of the random order id's are able to change the rule
                    #    affected by order id 13.
                    # 2. All random order id's need to be >= 13.
                    #    Assuming that the simplification algorithm RULE_WEIGHT is used
                    #    its unlikely or maybe even impossible that a random order_id
                    #    causes that order id 13 has no impact on the grammar.
                    # I do not care about duplicate orders.
                    # estimate_cut_steps just provides the maximum number of orders in the group.
                    # @oid_list = (random order_id n, ..., random order_id 1, $order_id)
                    #
                    my @oid_list;

                    my $cut_steps = GenTest::Simplifier::Grammar_advanced::estimate_cut_steps();
                    # One per 30 does not seem to be too greedy.
                    my $oids_to_add = abs(int($cut_steps / 30));
                    # Check for obvious errors in estimate_cut_steps().
                    if (not defined $oids_to_add or $oids_to_add > 3000) {
                        my $status = STATUS_INTERNAL_ERROR;
                        Carp::cluck("INTERNAL ERROR: Simplifier::get_job : \$oids_to_add is " .
                                    "undef or > 3000." .
                                    "Will exit with status " . status2text($status) . "($status)");
                        Batch::emergency_exit($status);
                    }
                    say("DEBUG: Simplifier::get_job : \$cut_steps : $cut_steps , " .
                        "\$oids_to_add : $oids_to_add") if Auxiliary::script_debug("S6");
                    while($oids_to_add > 0) {
                        my $extra_order = Batch::get_rand_try_all_id();
                        if      (not defined $extra_order) {
                            last;
                        } elsif ($extra_order > $order_id) {
                            push @oid_list, $extra_order;
                        } else {
                            # Do nothing.
                        }
                        $oids_to_add--;
                    }
                    push @oid_list, $order_id;
                      say("DEBUG: order_id($order_id), \@oid_list ->" . join(" ",@oid_list) . "<-");

                    # Needed later for some debug message only.
                    my $rule_name         = $order_array[$order_id][ORDER_PROPERTY2];
                    my $component_string  = $order_array[$order_id][ORDER_PROPERTY3];

                    # Based on the order id's, their validity and their order within @oid_list
                    # a $redefine_string gets generated.
                    # And this string gets than appended to the child grammar to be tried.
                    my $redefine_string =
                        "################ Generated by grammar simplifier ################\n" .
                        "# Order id list : " . join(" ", @oid_list) . "\n\n";

                    my $is_valid = 0;
                    foreach my $oid ( @oid_list ) {
                        my $curr_rule_name        = $order_array[$oid][ORDER_PROPERTY2];
                        my $curr_component_string = $order_array[$oid][ORDER_PROPERTY3];
                        my $dtd_protection        = 0;
                        say("DEBUG: Simplifier::order_is_valid: oid: $oid, " .
                            "rule_name '$curr_rule_name', component ->" . $curr_component_string .
                            "<-") if Auxiliary::script_debug("S5");
                        my $new_rule_string = GenTest::Simplifier::Grammar_advanced::shrink_grammar(
                                 $curr_rule_name, $curr_component_string, $dtd_protection);
                        if (not defined $new_rule_string) {
                            # say("DEBUG: Order id $oid new_rule_string is undef.");
                            $redefine_string .= "# The order id $oid has already become invalid.\n";
                            Batch::add_to_try_never($oid);
                            next;
                        } else {
                            # Do not print $new_rule_string into the comment because it could
                            # contain line breaks.
                            $is_valid = 1 if $oid == $order_id;
                            $redefine_string .= "# Order id $oid\n" . "# -------------- \n" .
                                                $new_rule_string . "\n\n";
                        }
                    }

                    if ($is_valid > 0) {
                        if (0) {
                            say("DEBUG: Redefinestring ->$redefine_string<-");
                        }
                        $child_grammar = "c" . Auxiliary::lfill0($child_number,5) . ".yy";
                        Batch::make_file($workdir . "/" . $child_grammar, $grammar_string . "\n\n" .
                                         $redefine_string );
                        $child_number++;
                        $order_is_valid           = 1;
                        my $duration_a            = replay_runtime_adapt();
                        $cl_snip_step = " --grammar=" . $workdir . "/" . $child_grammar .
                                        " --duration=$duration_a";
                        $job[Batch::JOB_CL_SNIP]  = $cl_snip_all . $cl_snip_phase . $cl_snip_step;
                        #                    " --grammar=" . $workdir . "/" . $child_grammar .
                        #                    " --duration=$duration_a";
                        $job[Batch::JOB_ORDER_ID] = $order_id;
                        $job[Batch::JOB_MEMO1]    = $child_grammar;
                        $job[Batch::JOB_MEMO2]    = $parent_grammar;
                        $job[Batch::JOB_MEMO3]    = $duration_a;
                    } else {
                        # Usual reasons:
                        # - The rule $rule_name does (no more) exist.
                        # - The rule $rule_name exists but contains no more the component to remove.
                        # - DTD protection is enabled and kicked in :(
                        say("DEBUG: Order id '$order_id' affecting rule '$rule_name' component " .
                            "'$component_string' is invalid.") if Auxiliary::script_debug("S4");
                        $order_is_valid = 0;
                        $order_id = undef;
                    }
                } elsif (PHASE_SIMP_END eq $phase) {
                } else {
                    Carp::cluck("INTERNAL ERROR: Handling for phase '$phase' is missing.");
                    my $status = STATUS_INTERNAL_ERROR;
                    Batch::emergency_exit($status);
                }
        } else {
            # NO ORDER GOT
            say("DEBUG: Batch::get_order delivered an undef order_id.")
                if Auxiliary::script_debug("S5");
            # %try_first_hash and @try_queue were empty and so $order_id is undef.
            if (PHASE_RVT_SIMP eq $phase or PHASE_GRAMMAR_SIMP eq $phase or
                PHASE_THREAD_REDUCE eq $phase) {
                my $max_refills = 5;
                # mleich 2019-12 Observation:
                # Only 5 refills is unfortunate small for PHASE_THREAD_REDUCE.
                $max_refills = 10 if PHASE_THREAD_REDUCE eq $phase;
                if ($max_refills > $refill_number) {
                    $refill_number++;
                    Batch::reactivate_try_replayer;
                    Batch::reactivate_try_over;
                    Batch::reactivate_try_over_bl;
                    Batch::reactivate_till_filled;
                    say("DEBUG: \@try_queue refill : $refill_number")
                        if Auxiliary::script_debug("S3");
                    next;
                } else {
                    say("DEBUG: No \@try_queue refill. Limit of $refill_number already reached.")
                        if Auxiliary::script_debug("S3");
                    last;
                }
            } else {
                Batch::reactivate_till_filled;
                say("DEBUG: \@try_queue refilled.") if Auxiliary::script_debug("S3");
                next;
            }
            # FIXME: Is that right?
            # This implies Batch::get_out_of_ideas() > 0;
            # last;
        }
        say("DEBUG: End of loop for getting an order.") if Auxiliary::script_debug("S6");
    } # End of while (not defined $order_id)

    if (Auxiliary::script_debug("S6")) {
        if (defined $order_id) {
            say("DEBUG: OrderID is $order_id.");
        } else {
            if (0 == Batch::get_out_of_ideas()) {
                say("WARN: OrderID is not defined AND Batch::out_of_ideas is 0.");
            }
        }
    }

    if (not defined $order_id) {
        # %try_first_hash empty , %try_hash empty too and extending obviously impossible
        # because otherwise %try_hash would be not empty.
        # == All possible orders were generated.
        #    Some might be in execution and all other must be in %try_over_hash or
        #    %try_never_hash.
        say("DEBUG: No order got, active : $active, out_of_ideas : " . Batch::get_out_of_ideas())
            if Auxiliary::script_debug("S5");
        Batch::dump_try_hashes() if Auxiliary::script_debug("S6");
        if (not $active and Batch::get_out_of_ideas()) {
            $phase_switch     = 1;
            say("DEBUG: Simplifier::get_job : No valid order found, active : $active, " .
                "out_of_ideas : " . Batch::get_out_of_ideas() . " --> Set phase_switch = 1 " .
                "and return undef") if Auxiliary::script_debug("S5");
        }
        return undef;
    } else {
        if (not defined $order_array[$order_id]) {
            my $status = STATUS_INTERNAL_ERROR;
            Carp::cluck("INTERNAL ERROR: Simplifier::get_job : orderid is not in order_array. " .
                        "Will exit with status " . status2text($status) . "($status)");
            Batch::emergency_exit($status);
        }
        # Prepare the job according to phase
        return @job;
    }

} # End of get_job


sub help() {
print("\n" .
"The information here is only about the parameters/options which\n"                                .
"- can be assigned to rqg_batch.pl at command line and\n"                                          .
"- have an impact on the simplification process.\n\n"                                               .
"Information about other parameters/options which can be assigned within a config file (*.cfg) "   .
"is provided in 'simplify_rqg_template.cfg' as comment.\n\n"                                       .
"trials\n"                                                                                         .
"   Maximum number of trials to replay the desired outcome in certain simplification phases\n"     .
"   Default: " . TRIALS_DEFAULT . "\n"                                                             .
"duration\n"                                                                                       .
"   Maximum YY grammar processing runtime assigned to the call of the RQG runner.\n"               .
"   The simplification phase '" . PHASE_GRAMMAR_SIMP . "' might manipulate that value.\n"          .
"   Default: " . DURATION_DEFAULT . "\n"                                                           .
"threads\n"                                                                                        .
"   Number of connections executing a stream of queries generated by YY grammar processing.\n"     .
"   The simplification phase '" . PHASE_THREAD1_REPLAY . "' might manipulate that value.\n"        .
"   Default: " . THREADS_DEFAULT . "\n"                                                            .
"grammar (mandatory if not set in config file)\n"                                                  .
"   YY grammar file with absolute path or path relative to top level directory of RQG.\n"          .
"   In case the YY grammar gets assigned this way than any grammar maybe assigned in the config"   .
"file will get ignored.\n"                                                                         .
"simplify_chain\n"                                                                                 .
"   Comma separated list of simplification phases.\n"                                              .
"   The simplifier will work in these phases and in the assigned order.\n"                         .
"   Default: '" . join("' ==> '",@simp_chain_default) . "'\n"                                      .
"algorithm\n"                                                                                      .
"   Algorithm to be used for picking a pregenerated job when\n"                                    .
"   - simplifying the YY grammar\n"                                                                .
"   - having no overruling criterion.\n"                                                           .
"   Currently only the per experience most effective algorithm '" . SIMP_ALGO_WEIGHT               .
"' is supported.\n"                                                                                .
"   Default: '" . SIMP_ALGO_WEIGHT . "'\n\n"                                                       .
"rqg_batch.pl passes certain parameters to the Simplifier.\n"                                      .
"Parameter settings which are finally left over and get ignored at all will be reported in a "     .
"line starting with\n"                                                                             .
"     WARNING: The following command line content is left over ...\n\n"                            .
"seed\n"                                                                                           .
"   The simplifier will ignore the assigned value and assign to every RQG run\n"                   .
"       --seed=random\n"                                                                           .
"   instead because this is per experience the most effective setting.\n\n"                        .
"Warning:\n"                                                                                       .
"The file assigned to 'grammar' will get treated as 'effective' grammar.\n"                        .
"This means any assignment of redefine/mask/mask_level will get removed/ignored and cause a "      .
"warning.\n"                                                                                       .
"'--no-mask' will be added to most RQG calls.\n"                                                   .
"\n");

}


sub print_order {

    my ($order_id) = @_;
    Batch::check_order_id($order_id);
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

my $have_rvt_generated           = 0;
my $have_thread_reduce_generated = 0;
sub generate_orders {

    # Hint:
    # One call of generate_orders could add several orders!
    our $generate_calls;
    $generate_calls = 0 if not defined $generate_calls;
    $generate_calls++;
    say("DEBUG: Number of generate_orders calls : $generate_calls")
        if Auxiliary::script_debug("S5");
    Batch::dump_try_hashes() if Auxiliary::script_debug("S5");
    my $success = 0;
    # PHASE_SIMP_BEGIN        should not be relevant but is handled in the else branch
    # PHASE_FIRST_REPLAY      handled
    # PHASE_THREAD1_REPLAY    handled
    # PHASE_RVT_SIMP          handled
    # PHASE_GRAMMAR_SIMP      handled
    # PHASE_THREAD_REDUCE     handled
    # PHASE_GRAMMAR_CLONE     handled
    # PHASE_FINAL_REPLAY      handled
    # PHASE_SIMP_END
    if      (PHASE_FIRST_REPLAY   eq $phase or
             PHASE_THREAD1_REPLAY eq $phase or
             PHASE_FINAL_REPLAY   eq $phase) {
        add_order($cl_snip_all . $cl_snip_phase, 'unused', '_unused_');
        $success = 1;
    } elsif (PHASE_THREAD_REDUCE eq $phase) {
        if ($have_thread_reduce_generated) {
            $success = 0;
        } else {
            my %thread_num_hash;
            my $thread_num = 1;
            # The goal is to have
            # - low order ids for low numbers of threads in order to favour them a bit
            # - a high density (at least 1, 2, 3) for low thread numbers
            # - a decreasing density for high thread numbers
            while ($thread_num < $threads) {
                $thread_num_hash{int($thread_num)} = 1;
                $thread_num = $thread_num * 1.5;
            }
            my @thread_num_list = sort {$a <=> $b} keys %thread_num_hash;
            # 2021-02-02 Observation
            # PHASE_THREAD_REDUCE threads=1 finishes extreme fast with STATUS_OK.
            # We need frequent refills because of that many RQG runners.
            # Finally leftovertrials (~ $trials) reaches zero -> abort campaign even though
            # none of the other orders (all with threads > 1 + capable to replay) had a chance
            # to finish.
            # So I limit the maximum number of trials of some order.
            my $max_efforts = int($trials / (scalar @thread_num_list));
            $max_efforts = 1 if 0 == $max_efforts;
            foreach $thread_num ( @thread_num_list ) {
                add_order($cl_snip_all . $cl_snip_phase, $thread_num, '_unused_', $max_efforts);
                $success = 1;
            }
            dump_orders() if Auxiliary::script_debug("S5");
        }
        $have_thread_reduce_generated = 1;
    } elsif (PHASE_RVT_SIMP eq $phase) {
        # RVT_SIMP:
        # - best     <whatever>              --> 'None' only (except transforme where '' is best)
        # - good     <whatever without None> --> <same whatever>, None
        # - good     <whatever>              --> <same whatever with some element != None removed>
        if (not $have_rvt_generated) {
            $have_rvt_generated = 1;
            sub generate_rvt_orders {
                my ($category) = @_;
                my %hash;
                my $success = 0;
                if (not defined $category) {
                    Carp::cluck("INTERNAL ERROR: category is undef.");
                    my $status = STATUS_INTERNAL_ERROR;
                    Batch::emergency_exit($status);
                } elsif ('reporter' eq $category) {
                    %hash = %reporter_hash;
                } elsif ('validator' eq $category) {
                    %hash = %validator_hash;
                } elsif ('transformer' eq $category) {
                    %hash = %transformer_hash;
                } else {
                    Carp::cluck("INTERNAL ERROR: category '$category' is unknown.");
                    my $status = STATUS_INTERNAL_ERROR;
                    Batch::emergency_exit($status);
                }

                if      (0 == scalar keys %hash) {
                    if ('transformer' ne $category) {
                       add_order($cl_snip_all . $cl_snip_phase, $category, '_add_None');
                       $success++;
                    }
                } elsif (1 == scalar keys %hash) {
                    if ('transformer' ne $category) {
                        if (not exists $hash{'None'}) {
                            add_order($cl_snip_all . $cl_snip_phase, $category, '_all_to_None');
                            $success++;
                            add_order($cl_snip_all . $cl_snip_phase, $category, '_add_None');
                            $success++;
                        } else {
                            # Nothing to do because the one and only value is already 'None'.
                        }
                    }
                } else {
                    if ('transformer' ne $category) {
                        # In minimum one of the elements must be != 'None'.
                        add_order($cl_snip_all . $cl_snip_phase, $category, '_all_to_None');
                        $success++;
                        if (not exists $hash{'None'}) {
                            add_order($cl_snip_all . $cl_snip_phase, $category, '_add_None');
                            $success++;
                        }
                    }
                    foreach my $value_to_remove (keys %hash) {
                        next if $value_to_remove eq 'None';
                        add_order($cl_snip_all . $cl_snip_phase, $category, $value_to_remove);
                        $success++;
                    }
                }
                return $success;
            }
            $success = $success + generate_rvt_orders('reporter');
            $success = $success + generate_rvt_orders('validator');
            $success = $success + generate_rvt_orders('transformer');
        } else {
            $success = 0;
        }
    } elsif (PHASE_GRAMMAR_SIMP eq $phase) {
        my $rule_name = GenTest::Simplifier::Grammar_advanced::next_rule_to_process(
                                RULE_JOBS_GENERATED, RULE_WEIGHT);
        while (defined $rule_name) {
            $success = 0;
            if (SIMP_MODE_DESTRUCTIVE eq $simplify_mode) {
                # Generate the destructive step.
                add_order($cl_snip_all . $cl_snip_phase, $rule_name, "_to_empty_string_only");
                $success++;
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
                # dump_orders;
            } else {
                say("DEBUG: Rule '$rule_name' has only " . (scalar @rule_unique_component_list) .
                    " components.") if Auxiliary::script_debug("S5");
            }
            GenTest::Simplifier::Grammar_advanced::set_rule_jobs_generated($rule_name);
            say("DEBUG: Rule '$rule_name' was decomposed into $success orders.")
                if Auxiliary::script_debug("S5");
            $rule_name = GenTest::Simplifier::Grammar_advanced::next_rule_to_process(
                             RULE_JOBS_GENERATED, RULE_WEIGHT);
        }
    } elsif (PHASE_SIMP_END eq $phase) {
    } else {
        Carp::cluck("INTERNAL ERROR: Handling for phase '$phase' is missing.");
        my $status = STATUS_INTERNAL_ERROR;
        Batch::emergency_exit($status);
    }
    if ($success) {
        if (Auxiliary::script_debug("S5")) {
            dump_orders();
            Batch::dump_try_hashes();
        }
        return 1;
    } else {
        say("DEBUG: All possible orders were already generated. Will return 0.")
            if Auxiliary::script_debug("S4");
        return 0;
    }
} # End of sub generate_orders


sub add_order {

    my ($order_property1, $order_property2, $order_property3, $max_efforts) = @_;

    our $order_id_now;
    $order_id_now = 0 if not defined $order_id_now;

    $order_id_now++;
    $max_efforts = $trials if not defined $max_efforts;

    $order_array[$order_id_now][ORDER_EFFORTS_INVESTED]  = 0;
    $order_array[$order_id_now][ORDER_EFFORTS_LEFT_OVER] = $max_efforts;
    $order_array[$order_id_now][ORDER_PROPERTY1]         = $order_property1;
    $order_array[$order_id_now][ORDER_PROPERTY2]         = $order_property2;
    $order_array[$order_id_now][ORDER_PROPERTY3]         = $order_property3;

    Batch::add_order($order_id_now);
    print_order($order_id_now) if Auxiliary::script_debug("S5");
}


sub register_result {
# Bookkeeping and adjust own behaviour to result and give the caller an order how to go on.
#
# Return Batch::REGISTER_.... (== An order how to proceed) or abort via Batch::emergency_exit.
#
# Warning:
# $left_over_trials > 0 must be checked before returning because otherwise we have no limitation
# for the phases FIRST_REPLAY, THREAD1_REPLAY, FINAL_REPLAY.
#

    our $arrival_number;
    my ($worker_num, $order_id, $verdict, $extra_info, $saved_log_rel, $total_runtime,
        $grammar_used, $grammar_parent, $adapted_duration, $worker_command) = @_;

    if (@_ != 10) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: register_result : 10 Parameters (worker_num, order_id, " .
                    "verdict, extra_info, saved_log_rel, total_runtime, grammar_used, "      .
                    "grammar_parent, adapted_duration, ignore1) are required.");
        Batch::emergency_exit($status);
    }
    if (not defined $worker_num or not defined $order_id or not defined $verdict) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: worker_num or order_id or verdict is undef");
        Batch::emergency_exit($status);
    }
    Carp::cluck("DEBUG: Simplifier::register_result(worker_num, order_id, verdict, extra_info, " .
                "saved_log_rel, total_runtime, grammar_used, grammar_parent, adapted_duration)")
        if Auxiliary::script_debug("S4");

    my $return = 'INIT';

    $arrival_number = 1 if not defined $arrival_number;

    if (defined $adapted_duration and $adapted_duration =~ /^[0-9]+$/) {
        # Do nothing.
    } else {
        say("WARN: No valid adapted duration of the test found. Use duration $duration instead.");
        $adapted_duration = $duration;
    }

    if ($verdict eq Verdict::RQG_VERDICT_REPLAY) {
        # In case of a replay we need to pull information which is not part of the routine
        # parameters but contained around end of the RQG run log.
        my $gentest_runtime;
        # 2019-01-11T18:44:45 [21041] INFO: GenTest: Effective duration in s : 193
        # 2018-11-19T16:16:19 [19309] SUMMARY: RQG GenData runtime in s : 0
        # 2018-11-19T16:16:19 [19309] SUMMARY: RQG GenTest runtime in s : 31
        # 2018-11-19T16:16:19 [19309] SUMMARY: RQG total runtime in s : 34
        ##### 2018-11-19T16:16:19 [19309] SUMMARY: RQG verdict : replay
        my $logfile = $workdir . "/" . $saved_log_rel;
        $gentest_runtime = Batch::get_string_after_pattern($logfile,
                               "INFO: GenTest: Effective duration in s : ");
        if (defined $gentest_runtime and $gentest_runtime =~ /^[0-9]+$/) {
            # Do nothing.
        } else {
            # No valid YY grammar processing runtime found. Use the bigger GenTest runtime instead.
            $gentest_runtime = Batch::get_string_after_pattern($logfile,
                                   "SUMMARY: RQG GenTest runtime in s : ");
            if (defined $gentest_runtime and $gentest_runtime =~ /^[0-9]+$/) {
                # Do nothing.
            } else {
                say("WARN: No valid GenTest runtime found. Use duration $duration instead.");
                $gentest_runtime = $duration;
            }
        }
        replay_runtime_fifo_update($gentest_runtime);
        estimate_runtime_fifo_update($gentest_runtime);
    } elsif ($verdict eq Verdict::RQG_VERDICT_IGNORE_STATUS_OK) {
        # Basically speculate: 1s more might have helped to replay.
        estimate_runtime_fifo_update($adapted_duration + 1);
    } else {
        # Do nothing because runs
        # - hitting an error declared to be 'unwnated'
        # - getting killed because of technical reasons
        # do not count at all.
    }

    $grammar_used     = '<undef>' if not defined $grammar_used;
    $grammar_parent   = '<undef>' if not defined $grammar_parent;

    # 1. Bookkeeping
    my $iso_ts = isoTimestamp();
    my $line   = "$iso_ts | " .
        Auxiliary::lfill($arrival_number, Batch::RQG_NO_LENGTH)        . " | " .
        Auxiliary::lfill($worker_num,     Batch::RQG_WNO_LENGTH)       . " | " .
        Auxiliary::rfill($verdict,        Verdict::RQG_VERDICT_LENGTH) . " | " .
        Auxiliary::lfill($saved_log_rel,  Batch::RQG_LOG_LENGTH)       . " | " .
        Auxiliary::lfill($order_id,       Batch::RQG_ORDERID_LENGTH)   . " | " .
        Auxiliary::lfill($total_runtime,  Batch::RQG_ORDERID_LENGTH)   . " | " .
        Auxiliary::rfill($grammar_used,   RQG_SPECIALITY_LENGTH)       . " | " .
        Auxiliary::rfill($grammar_parent, RQG_SPECIALITY_LENGTH)       . " | " .
        Auxiliary::rfill($extra_info,     Batch::RQG_INFO_LENGTH)      . "\n";
    Batch::write_result($line);
    $line =
        Auxiliary::rfill($verdict,        Verdict::RQG_VERDICT_LENGTH) . " | " .
        Auxiliary::rfill($extra_info,     Batch::RQG_INFO_LENGTH)      . " | " .
        $worker_command                                                . " | " .
        Auxiliary::lfill($arrival_number, Batch::RQG_NO_LENGTH)        . " | " .
        Auxiliary::lfill($saved_log_rel,  Batch::RQG_LOG_LENGTH)       . "\n";
    Batch::write_setup($line);
    $arrival_number++;

    # 2. Update $left_over_trials, ORDER_EFFORTS_INVESTED, ORDER_EFFORTS_LEFT_OVER
    if      ($verdict eq Verdict::RQG_VERDICT_IGNORE           or
             $verdict eq Verdict::RQG_VERDICT_IGNORE_STATUS_OK or
             $verdict eq Verdict::RQG_VERDICT_IGNORE_UNWANTED  or
             $verdict eq Verdict::RQG_VERDICT_INTEREST         or
             $verdict eq Verdict::RQG_VERDICT_REPLAY           or
             $verdict eq Verdict::RQG_VERDICT_INIT       ) {
        $order_array[$order_id][ORDER_EFFORTS_INVESTED]++;
        $order_array[$order_id][ORDER_EFFORTS_LEFT_OVER]--;
        $left_over_trials--;
    } elsif ($verdict eq Verdict::RQG_VERDICT_IGNORE_STOPPED) {
        # Do nothing with the $order_array[$order_id][ORDER_EFFORTS_*].
    } else {
        say("INTERNAL ERROR: Final Verdict '$verdict' is not treated/unknown. " .
            "Will ask for an emergency_exit.");
        my $status = STATUS_INTERNAL_ERROR;
        Batch::emergency_exit($status);
    }
    say("DEBUG: Simplifier::register_result : left_over_trials : $left_over_trials")
        if Auxiliary::script_debug("S4");

    my $target = $workdir . "/" . $best_grammar;
    my $efforts_invested = $order_array[$order_id][ORDER_EFFORTS_INVESTED];

    # 3. React on the verdict and decide about the nearby future of the order.
    if      ($verdict eq Verdict::RQG_VERDICT_IGNORE_STOPPED) {
        # We need to make some additional run with this order as soon as possible.
        Batch::add_to_try_first($order_id);
        $return = Batch::REGISTER_GO_ON;
    } elsif ($verdict eq Verdict::RQG_VERDICT_REPLAY) {
        $campaign_success++;
        if (PHASE_FIRST_REPLAY   eq $phase or
            PHASE_THREAD1_REPLAY eq $phase or
            PHASE_FINAL_REPLAY   eq $phase   ) {
            if($stop_on_replay) {
                # Do not switch from PHASE_FIRST_REPLAY to whatever if $stop_on_replay is > 0.
                $return = Batch::REGISTER_GO_ON;
            } else {
                # The fate of the phase is decided.
                $phase_switch = 1;
                Batch::stop_workers(Batch::STOP_REASON_WORK_FLOW . ' 6');
                # In the current phase we have used all time the same grammar and that is the
                # current $child_grammar.
                Batch::add_to_try_never($order_id);
                $return = Batch::REGISTER_SOME_STOPPED;
            }
            my $source = $workdir . "/" . $child_grammar;
            Batch::copy_file($source, $target);
            if      (PHASE_FIRST_REPLAY eq $phase) {
                $first_replay_success   = 1;
                # Attention:
                # There was a replay but this is not a success in simplification.
                # Hence $simp_success must not be touched.
            } elsif (PHASE_THREAD1_REPLAY eq $phase) {
                say("INFO: We had a replay in phase '$phase'. " .
                    "Will adjust the parent grammar and the number of threads used to 1.");
                $threads = 1;
            #   $cl_snip_all .= " --threads=1";
                reload_grammar($child_grammar);
                $simp_success           = 1;
                $thread1_replay_success = 1;
            } elsif (PHASE_FINAL_REPLAY eq $phase) {
                $final_replay_success   = 1;
            }
        } elsif (PHASE_THREAD_REDUCE eq $phase) {
            # $grammar_used is the number of threads used in that RQG run.
            $campaign_duds_since_replay = 0;
            if ($grammar_used < $threads) {
                # 0. Its a replayer providing progress.
                $threads               = $grammar_used;
                $simp_success          = 1;
                $thread_reduce_success = 1;
                my $iso_ts = isoTimestamp();
                Batch::write_result("$iso_ts          Number of threads reduced to $threads \n");

                # 1. Stop all worker fiddling with the same $order_id except they have reached
                #    'replay' or 'interest'.
                Batch::stop_worker_on_order_except($order_id);
                # 2. Stop all worker fiddling with the same $order_id in case they have reached
                #    a replay because we are already processing a replayer who has finished.
                Batch::stop_worker_on_order_replayer($order_id);

                Batch::add_to_try_never($order_id);

                # 3. The "$threads = $grammar_used;" above makes all jobs/orders going with some
                #    higher number of threads obsolete.
                # Stop all workers having some $order_id fiddling with a higher number of threads.
                my @orders_in_work = Batch::get_orders_in_work;
                say("DEBUG: orders currently in work: " . join(" - ", @orders_in_work))
                    if Auxiliary::script_debug("S5");
                foreach my $order_in_work (@orders_in_work) {
                    # In theory we should not need the next line.
                    next if $order_id == $order_in_work; # IMHO not required here but no harm.
                    my $threads_in_order = $order_array[$order_in_work][ORDER_PROPERTY2];
                    if (not defined $threads_in_order) {
                        say("INTERNAL ERROR: Processing the orders in work threads_in_order is not " .
                            "defined, order_id $order_id. Will ask for an emergency_exit.");
                        my $status = STATUS_INTERNAL_ERROR;
                        Batch::emergency_exit($status);
                    }
                    if ($threads_in_order > $threads) {
                        # That number of threads has now become obsolete.
                        say("DEBUG: Threads reduced to $threads_in_order in order_id " .
                            "$order_in_work is now obsolete but currently in work. " .
                            "Will stop all RQG Workers using that order.")
                            if Auxiliary::script_debug("S5");
                        Batch::stop_worker_on_order_except($order_in_work);
                        # Even some replayer is no more of interest.
                        Batch::stop_worker_on_order_replayer($order_in_work);
                        Batch::add_to_try_never($order_in_work);
                    }
                }
                $return = Batch::REGISTER_GO_ON;
            } else {
                # Its a too late replayer.    $grammar_used >= threads
                $return = Batch::REGISTER_GO_ON;
            }
        } elsif (PHASE_RVT_SIMP eq $phase) {
            # FIXME: Compare stop_worker* use to PHASE_GRAMMAR_SIMP.
            my $rvt_now = get_shrinked_rvt_options(undef, undef, 0);
            if ($grammar_parent eq $rvt_now) {
                # Its a first replayer based on the current parent rvt options.
                my $stop_count = Batch::stop_worker_till_phase(Auxiliary::RQG_PHASE_GENDATA,
                                                               Batch::STOP_REASON_WORK_FLOW . ' 7');
                Batch::stop_worker_on_order_except($order_id);
                my $rvt_options = get_shrinked_rvt_options($order_array[$order_id][ORDER_PROPERTY2],
                                         $order_array[$order_id][ORDER_PROPERTY3], 1);
                if (not defined $rvt_options) {
                    Carp::cluck("INTERNAL ERROR: rvt_options is undef.");
                    my $status = STATUS_INTERNAL_ERROR;
                    Batch::emergency_exit($status);
                }
                # Another replayer with the same order_id is no more needed.
                Batch::stop_worker_on_order_replayer($order_id);
                Batch::add_to_try_never($order_id);
                $simp_success     = 1;
                $rvt_simp_success = 1;
                $return           = Batch::REGISTER_GO_ON;
            } else {
                # Its a too late replayer.
                # But the order was quite good. So try it again.
                $order_array[$order_id][ORDER_EFFORTS_LEFT_OVER]++;
                $order_array[$order_id][ORDER_EFFORTS_LEFT_OVER]++;
                Batch::add_to_try_intensive_again($order_id);
                $return = Batch::REGISTER_GO_ON;
            }
        } elsif (PHASE_GRAMMAR_SIMP eq $phase) {
            $campaign_duds_since_replay = 0;
            if ($grammar_parent eq $parent_grammar) {
                # Its a first replayer == Winner based on the current parent grammar.
                # Its replay was not already detected during RQG worker runtime because than
                # report_replay --> get new parent grammar.

                my $stop_count = Batch::stop_worker_till_phase(Auxiliary::RQG_PHASE_GENDATA,
                                                               Batch::STOP_REASON_WORK_FLOW . ' 8');
                Batch::stop_worker_on_order_except($order_id);
                reload_grammar($grammar_used);
                my $source = $workdir . "/" . $grammar_used;
                Batch::copy_file($source, $target);
                # Other replayer with the same order_id are no more of interest.
                Batch::stop_worker_on_order_replayer($order_id);
                Batch::add_to_try_never($order_id);

                # In case the reload_grammar above lets some rule disappear than we could
                # stop all workers having some $order_id fiddling with the disappeared rule.
                my @orders_in_work = Batch::get_orders_in_work;
                say("DEBUG: orders currently in work: " . join(" - ", @orders_in_work))
                    if Auxiliary::script_debug("S5");
                foreach my $order_in_work (@orders_in_work) {
                    # In theory we should not need the next line.
                    next if $order_id == $order_in_work; # Maybe archiving with verdict interest.
                    my $rule_name = $order_array[$order_in_work][ORDER_PROPERTY2];
                    if (not defined $rule_name) {
                        say("INTERNAL ERROR: Processing the orders in work rule_name is not " .
                            "defined, order_id $order_id. Will ask for an emergency_exit.");
                        my $status = STATUS_INTERNAL_ERROR;
                        Batch::emergency_exit($status);
                    }
                    my $return = GenTest::Simplifier::Grammar_advanced::rule_exists($rule_name);
                    if (not defined $return) {
                        say("INTERNAL ERROR: Unable to figure out if the rule '$rule_name' " .
                            "exists. Will ask for an emergency_exit.");
                        my $status = STATUS_INTERNAL_ERROR;
                        Batch::emergency_exit($status);
                    } elsif ($return) {
                        # That rule is used. Therefore the job in work stays valid.
                    } else {
                        # That rule is not/no more used. Therefore the job is invalid.
                        say("DEBUG: Rule '$rule_name' occuring in order_id $order_in_work does " .
                            "no more exist but is currently under attack. Will stop all RQG " .
                            "Workers using that order.") if Auxiliary::script_debug("S5");
                        Batch::stop_worker_on_order_except($order_in_work);
                        # Even some replayer is no more of interest.
                        Batch::stop_worker_on_order_replayer($order_in_work);
                        Batch::add_to_try_never($order_in_work);
                    }
                }
                $simp_success           = 1;
                $grammar_simp_success   = 1;
                $return = Batch::REGISTER_GO_ON;
            } else {
                # Its a too late replayer.
                # But the order was quite good. So try it again.
                $order_array[$order_id][ORDER_EFFORTS_LEFT_OVER]++;
                $order_array[$order_id][ORDER_EFFORTS_LEFT_OVER]++;
                Batch::add_to_try_intensive_again($order_id);
                $return = Batch::REGISTER_GO_ON;
            }
        } else {
            my $status = STATUS_INTERNAL_ERROR;
            Carp::cluck("INTERNAL ERROR: The phase '$phase' is unknown. " .
                "Will exit with status " . status2text($status) . "($status)");
            Batch::emergency_exit($status);
        }
      # The handling of replayers ends here ----------------------------------
    } elsif ($verdict eq Verdict::RQG_VERDICT_IGNORE            or
             $verdict eq Verdict::RQG_VERDICT_IGNORE_STATUS_OK  or
             $verdict eq Verdict::RQG_VERDICT_IGNORE_UNWANTED   or
             $verdict eq Verdict::RQG_VERDICT_INTEREST          or
             $verdict eq Verdict::RQG_VERDICT_INIT                ) {
        if (0 >= $order_array[$order_id][ORDER_EFFORTS_LEFT_OVER]) {
            # We have already too much invested. Stop using that order.
            say("DEBUG: order_id($order_id), trials($trials), " .
                "efforts_invested($efforts_invested), " .
                "efforts_left_over(" . $order_array[$order_id][ORDER_EFFORTS_LEFT_OVER] .
                ") --> Stop using that order.") if Auxiliary::script_debug("S4");
            Batch::stop_worker_on_order_except($order_id);
            Batch::add_to_try_exhausted($order_id);
            $return = Batch::REGISTER_GO_ON;
        } else {
            if ($verdict eq Verdict::RQG_VERDICT_IGNORE_UNWANTED) {
                Batch::add_to_try_over_bl($order_id);
                $return = Batch::REGISTER_GO_ON;
            } else {
                Batch::add_to_try_over($order_id);
                $return = Batch::REGISTER_GO_ON;
            }
        }
        if (PHASE_GRAMMAR_SIMP eq $phase or
            PHASE_RVT_SIMP     eq $phase   ) {
            $campaign_duds_since_replay++;
            my $max_value;
            if (PHASE_GRAMMAR_SIMP eq $phase) {
                $max_value = GenTest::Simplifier::Grammar_advanced::estimate_cut_steps();
                $max_value = $trials if $max_value < $trials;
            }
            if (PHASE_RVT_SIMP eq $phase) {
                $max_value = rvt_cut_steps();
                $max_value = $trials / 2 if $max_value < $trials / 2;
            }
            if ($campaign_duds_since_replay >= 2 * $max_value) {
                # The current campaign should abort. Depending on the success of the current
                # campaign we should get some additional campaign or a switch to the next
                # simplification phase.
                $phase_switch = 1;
                Batch::stop_workers(Batch::STOP_REASON_WORK_FLOW . ' 9');
                say("DEBUG: Setting phase_switch to $phase_switch because we had " .
                    "$campaign_duds_since_replay finished trials since last " .
                    "replay. Assigned trials : $trials. Giving up with that campaign.")
                    if Auxiliary::script_debug("S3");

                # Never set $left_over_trials to 0 here.

                $return = Batch::REGISTER_SOME_STOPPED;
            }
        }
    } else {
        say("INTERNAL ERROR: Final Verdict '$verdict' is not treated/unknown. " .
            "Will ask for an emergency_exit.");
        my $status = STATUS_INTERNAL_ERROR;
        Batch::emergency_exit($status);
    }

    if (0 == $left_over_trials) {
        $phase_switch = 1;
        Batch::stop_workers(Batch::STOP_REASON_WORK_FLOW . ' 10');
        if (PHASE_GRAMMAR_SIMP  eq $phase or
            PHASE_RVT_SIMP      eq $phase    ) {
            say("WARN: left_over_trials is no more > 0. And that even though we are in phase " .
                "'$phase'. Giving up with the current campaign.");
        } else {
            # In case $phase not in (PHASE_RVT_SIMP, PHASE_GRAMMAR_SIMP) $left_over_trials gets
            # precharged with $trials at begin of campaign.
            # This is a rather moderate value serving for giving up early enough with
            # the current campaign and switch to the next phase.
            say("DEBUG: left_over_trials is no more > 0. Giving up with the current campaign.")
                if Auxiliary::script_debug("S3");
        }
        $return = Batch::REGISTER_SOME_STOPPED;
    }

    return $return;

} # End sub register_result


sub switch_phase {

    say("DEBUG: Simplifier::switch_phase: Enter routine. Current phase is '$phase'.")
        if Auxiliary::script_debug("S4");

    if (PHASE_FIRST_REPLAY eq $phase and 0 == $first_replay_success) {
        say("\n\nSUMMARY: Even the attempt to make a first replay with the full test failed.\n"    .
            "SUMMARY: Hence no other simplification steps were tried.\n"                           .
            "HINT: Maybe the\n"                                                                    .
            "HINT: - replay/unwanted lists (especially the pattern sections) are faulty or\n"      .
            "HINT: - RQG test setup (basedir, grammar etc.) is wrong or\n"                         .
            "HINT: - trials/duration/queries are too small.");
        say("");
        say("");
        $phase        = PHASE_SIMP_END;
        $phase_switch = 0;
        return;
    }

    my $iso_ts = isoTimestamp();

    my $rvt_snip = get_shrinked_rvt_options(undef, undef, 0);
    # ATTENTION:
    # $rvt_snip with that value needs to be added to any phase EXCEPT PHASE_RVT_SIMP.
    if (not defined $rvt_snip) {
        Carp::cluck("INTERNAL ERROR: The rvt_snip computed is undef. " .
            "Will ask for an emergency_exit.");
        my $status = STATUS_INTERNAL_ERROR;
        Batch::emergency_exit($status);
    }

    ####### $cl_snip_phase      = " $rvt_snip --grammar=$target --threads=$threads";

    # Treat phases consisting of maybe repeated campaigns first
    # == The cases where we maybe stay in the current phase and do not shift.
    if ((PHASE_GRAMMAR_SIMP eq $phase) and ($campaign_success)) {
        if ($campaign_number_max > $campaign_number) {
            # We had success within the last simplification campaign and so we run one campaign more.
            $campaign_number++;
            $campaign_duds_since_replay = 0;
            $left_over_trials  = TRIALS_SIMP;
            $cl_snip_phase     = " $rvt_snip                   --threads=$threads";
            Batch::write_result("$iso_ts ---------- $phase campaign $campaign_number ----------\n" .
                                $iso_ts . $title_line_part);

            load_grammar($parent_grammar, 10);
            Batch::init_order_management();
            Batch::init_load_control();
            say("DEBUG: Simplifier::switch_phase: Leaving routine. Current phase is '$phase'.")
                    if Auxiliary::script_debug("S4");
            $campaign_success  = 0;
            $refill_number     = 0;
    #       $out_of_ideas      = 0;
            $phase_switch      = 0;
            # Essential: We are already in PHASE_GRAMMAR_SIMP and will stay there for another campaign.
            return;
        } else {
            say("WARN: Current phase is '$phase' and limit of $campaign_number_max campaigns for " .
                "that phase was reached was reached.");
        }
    }
    if ((PHASE_RVT_SIMP eq $phase) and ($campaign_success)) {
        if ($campaign_number_max > $campaign_number) {
            # We had success within the last simplification campaign and so we run one campaign more.
            $campaign_number++;
            $have_rvt_generated = 0;
            my $target          = $workdir . "/" . $child_grammar;
            $left_over_trials   = TRIALS_SIMP;
            $cl_snip_phase      = "           --grammar=$target --threads=$threads";
            Batch::write_result("$iso_ts ---------- $phase campaign $campaign_number ---------- " .
                                "($child_grammar)\n" .
                                $iso_ts . $title_line_part);
            Batch::init_order_management();
            Batch::init_load_control();
            say("DEBUG: Simplifier::switch_phase: Leaving routine. Current phase is '$phase'.")
                    if Auxiliary::script_debug("S4");
            $campaign_success   = 0;
    #       $out_of_ideas       = 0;
            $phase_switch       = 0;
            return;
        } else {
            say("WARN: Current phase is '$phase' and limit of $campaign_number_max campaigns for " .
                "that phase was reached was reached.");
        }
    }

    $phase = shift @simp_chain;
    say("INFO: Simplification phase switched to '$phase'.");

    if (1 == $threads and
        ((PHASE_THREAD1_REPLAY eq $phase) or
         (PHASE_THREAD_REDUCE  eq $phase)   )) {
        say("INFO: threads is already 1. Omitting phase '" . $phase . "'.");
        $phase = shift @simp_chain;
    }

    if (PHASE_FINAL_REPLAY eq $phase) {
        if (-1 == $simp_success) {
            say("\n\nSUMMARY: No simplification step was tried.\n"                                 .
                "SUMMARY: Hence some simplified test does not exist. Omitting the phase '"         .
                PHASE_FINAL_REPLAY . "'.");
            say("");
            say("");
            $phase        = PHASE_SIMP_END;
            $phase_switch = 0;
            return;
        } elsif (0 == $simp_success) {
            say("\n\nSUMMARY: None of the attempts to simplify the test achieved success.\n"       .
                "SUMMARY: Hence some simplified test does not exist. Omitting the phase '"         .
                PHASE_FINAL_REPLAY . "'.\n"                                                        .
                "HINT: Maybe the\n"                                                                .
                "HINT: - black/white lists (especially the pattern sections) are faulty or\n"      .
                "HINT: - RQG test setup (basedir, grammar etc.) is wrong or\n"                     .
                "HINT: - trials/duration/queries are too small.");
            say("");
            say("");
            $phase        = PHASE_SIMP_END;
            $phase_switch = 0;
            return;
        } else {
            # Do nothing here.
        }
    }

    our $clone_phase;
    if (PHASE_GRAMMAR_CLONE eq $phase ) {
        # FIXME maybe:
        # Find some solution which is more elegant than reloading from file.
        # Why load_grammar and not reload_grammar? Because its comparable to beginning a new campaign?
        load_grammar($parent_grammar, 10);
        my $start_grammar_string = $grammar_string;
        GenTest::Simplifier::Grammar_advanced::print_rule_hash();
        # FIXME:
        # When running in destructive mode cloning of rules with one unique component makes sense!
        if (not defined $clone_phase) {
            $clone_phase = 'using top level rules only';
            $grammar_string = GenTest::Simplifier::Grammar_advanced::use_clones_in_grammar_top;
            if ($start_grammar_string ne $grammar_string) {
                say("DEBUG: Cloning attempt '$clone_phase' changed the grammar.")
                    if Auxiliary::script_debug("S2");
                unshift @simp_chain, PHASE_GRAMMAR_CLONE;
                unshift @simp_chain, PHASE_GRAMMAR_SIMP;
                make_parent_from_string ($grammar_string);
            } else {
                say("INFO: Cloning attempt '$clone_phase' did not change the grammar.")
                    if Auxiliary::script_debug("S2");
                $clone_phase = 'all ordered by rule weight';
                $grammar_string = GenTest::Simplifier::Grammar_advanced::use_clones_in_grammar;
                if ($start_grammar_string ne $grammar_string) {
                    say("DEBUG: Cloning attempt '$clone_phase' changed the grammar.")
                        if Auxiliary::script_debug("S2");
                    unshift @simp_chain, PHASE_GRAMMAR_SIMP;
                    make_parent_from_string ($grammar_string);
                } else {
                    say("INFO: Cloning attempt '$clone_phase' did not change the grammar.");
                    $clone_phase = undef;
                }
            }
        } elsif ($clone_phase eq 'using top level rules only') {
            $clone_phase = 'all ordered by rule weight';
            $grammar_string = GenTest::Simplifier::Grammar_advanced::use_clones_in_grammar;
            if ($start_grammar_string ne $grammar_string) {
                say("DEBUG: Cloning attempt '$clone_phase' changed the grammar.")
                    if Auxiliary::script_debug("S2");
                unshift @simp_chain, PHASE_GRAMMAR_SIMP;
                make_parent_from_string ($grammar_string);
            } else {
                say("INFO: Cloning attempt '$clone_phase' did not change the grammar.");
                $clone_phase = undef;
            }
        } else {
            # Only $clone_phase = 'ordered by rule weight'; should be left over.
            # Is that true?
            say("MLML: In PHASE_GRAMMAR_CLONE unexpected branch reached.");
            $clone_phase = undef;
        }

        $phase = shift @simp_chain;
    }


    # Hint:
    # At least some phases could occur more than one time within @simp_chain. (handling is above)
    # Therefore the    $var = 0 -->if -1 == $var<--   is required because otherwise we
    # might change the value from 1 to 0.
    if      (PHASE_FIRST_REPLAY eq $phase)     {
        $first_replay_success   = 0 if -1 == $first_replay_success;
        $left_over_trials       = $trials;
        make_child_from_parent();
        my $target              = $workdir . "/" . $child_grammar;
        $cl_snip_phase          = " $rvt_snip --grammar=$target --threads=$threads";
        Batch::write_result("$iso_ts ---------- $phase ---------- ($child_grammar)\n" .
                            $iso_ts . $title_line_part);
    } elsif (PHASE_THREAD_REDUCE eq $phase)     {
        $simp_success           = 0 if -1 == $simp_success;
        $thread_reduce_success  = 0 if -1 == $thread_reduce_success;
        # Observation 2019-12 : The only 5 refills limits more than trials.
        $left_over_trials       = $trials;
        make_child_from_parent();
        my $target              = $workdir . "/" . $child_grammar;
        $cl_snip_phase          = " $rvt_snip --grammar=$target                   ";
        Batch::write_result("$iso_ts ---------- $phase ---------- ($child_grammar)\n" .
                            $iso_ts . $title_line_part);
    } elsif (PHASE_RVT_SIMP eq $phase)   {
        $simp_success           = 0 if -1 == $simp_success;
        $rvt_simp_success       = 0 if -1 == $rvt_simp_success;
        $have_rvt_generated     = 0;
        $campaign_number        = 1;
        $left_over_trials       = TRIALS_SIMP;
        make_child_from_parent();
        # $rvt_snip = "";
        my $target              = $workdir . "/" . $child_grammar;
        $cl_snip_phase          = "           --grammar=$target --threads=$threads";
        Batch::write_result("$iso_ts ---------- $phase campaign $campaign_number ---------- ($child_grammar)\n" .
                            $iso_ts . $title_line_part);
    } elsif (PHASE_THREAD1_REPLAY eq $phase)   {
        $simp_success           = 0 if -1 == $simp_success;
        $thread1_replay_success = 0 if -1 == $thread1_replay_success;
        $left_over_trials       = $trials;
        make_child_from_parent();
        my $target              = $workdir . "/" . $child_grammar;
        # Deviation from ....
        $cl_snip_phase          = " $rvt_snip --grammar=$target --threads=1";
        Batch::write_result("$iso_ts ---------- $phase ---------- ($child_grammar)\n" .
                            $iso_ts . $title_line_part);
    } elsif (PHASE_GRAMMAR_SIMP eq $phase) {
        $simp_success           = 0 if -1 == $simp_success;
        $grammar_simp_success   = 0 if -1 == $grammar_simp_success;
        $campaign_number        = 1;
        $campaign_duds_since_replay = 0;
        $left_over_trials       = TRIALS_SIMP;
        $cl_snip_phase          = " $rvt_snip                   --threads=$threads";
        load_grammar($parent_grammar, 10);
        Batch::write_result("$iso_ts ---------- $phase campaign $campaign_number ----------\n" .
                            $iso_ts . $title_line_part);
    } elsif (PHASE_FINAL_REPLAY eq $phase)   {
        $final_replay_success   = 0 if -1 == $final_replay_success;
        $left_over_trials       = $trials;
        make_child_from_parent();
        my $target              = $workdir . "/" . $child_grammar;
        $cl_snip_phase          = " $rvt_snip --grammar=$target --threads=$threads";
        Batch::write_result("$iso_ts ---------- $phase ---------- ($child_grammar)\n" .
                            $iso_ts . $title_line_part);
    } elsif (PHASE_SIMP_END eq $phase)   {
        say("");
        say("");
        if (1 <= $simp_success) {
            say("\n\nSUMMARY: RQG test simplification achieved");
            if (1 <= $thread1_replay_success or 1 <= $thread_reduce_success) {
                say("SUMMARY: simplified number of threads : $threads");
            }
            say("SUMMARY: simplified RVT setting : '" . $rvt_snip . "'") if 1 <= $rvt_simp_success;
            if (1 <= $grammar_simp_success) {
                $grammar_string = GenTest::Simplifier::Grammar_advanced::init(
                                   $workdir . "/" . $parent_grammar, $threads, 200, $grammar_flags);
                Batch::make_file($workdir . "/final.yy", $grammar_string . "\n");
                say("SUMMARY: simplified(tested) RQG Grammar : '" . $workdir . "/$best_grammar'\n" .
                    "SUMMARY: simplified(non tested) RQG Grammar : '" . $workdir . "/final.yy'");
            }
        } else {
            say("SUMMARY: No RQG test simplification achieved.");
        }
        say("");
        say("");
    } else {
        Carp::cluck("INTERNAL ERROR: Handling for phase '$phase' is missing.");
        my $status = STATUS_INTERNAL_ERROR;
        Batch::emergency_exit($status);
    }
    Batch::init_order_management();
    Batch::init_load_control();
    say("DEBUG: Simplifier::switch_phase: Leaving routine. Current phase is '$phase'.")
        if Auxiliary::script_debug("S4");
    $campaign_success = 0;
#   $out_of_ideas     = 0;

    $phase_switch     = 0;

} # End of sub switch_phase


# - The value for duration finally assigned to some RQG run will be all time <= $duration.
# - In case the assigned duration is finally the deciding delimiter than it is expected that
#   the measured gentest runtime is slightly bigger than that assigned duration.
# ------------------------------------------------------------------------------------------
# Keep the runtime of replaying tests
my @replay_runtime_fifo;
#
sub replay_runtime_fifo_init {
    my ($elements) = @_;
    # In order to have simple code and a smooth queue of computed values we precharge with the
    # duration (assigned/calculated during init).
    for my $num (0..($elements - 1)) {
        $replay_runtime_fifo[$num] = $duration;
    }
}
# Keep the manipulated runtime of not replaying tests
my @estimate_runtime_fifo;
#
sub estimate_runtime_fifo_init {
    my ($elements) = @_;
    # In order to have simple code and a smooth queue of computed values we precharge with the
    # duration (assigned/calculated during init).
    for my $num (0..($elements - 1)) {
        $estimate_runtime_fifo[$num] = $duration;
    }
}

sub limit_with_duration {
    my ($value) = @_;
    if ($value <= $duration) {
        return $value;
    } else {
        return $duration;
    }
}

sub replay_runtime_fifo_update {
    my ($value) = @_;

    shift @replay_runtime_fifo;
    $value = limit_with_duration($value);
    push @replay_runtime_fifo, $value;
    say("DEBUG: Update of replay runtime fifo with $value") if Auxiliary::script_debug("S4");
    replay_runtime_fifo_print();
}

sub estimate_runtime_fifo_update {
    my ($value) = @_;

    shift @estimate_runtime_fifo;
    $value = limit_with_duration($value);
    push @estimate_runtime_fifo, $value;
    say("DEBUG: Update of estimate runtime fifo with $value") if Auxiliary::script_debug("S4");
    estimate_runtime_fifo_print();
}

sub replay_runtime_fifo_print {
    say("DEBUG: replay_runtime_fifo : " .
        join(" ", @replay_runtime_fifo)) if Auxiliary::script_debug("S5");
}

sub estimate_runtime_fifo_print {
    say("DEBUG: estimate_runtime_fifo : " .
        join(" ", @estimate_runtime_fifo)) if Auxiliary::script_debug("S5");
}

sub estimation {
    my (@fifo) = @_;

    my $num_samples = scalar @fifo;

    my $single_sum  = 0;
    foreach my $val (@fifo) {
        $single_sum += $val;
    }
    my $mean =            $single_sum / $num_samples;
    my $quadrat_dev_sum = 0;
    foreach my $val (@fifo) {
        my $single_dev = $val - $mean;
        $quadrat_dev_sum += $single_dev * $single_dev;
    }
    my $std_dev    = sqrt($quadrat_dev_sum / ($num_samples - 1));

    # >= 95% of all values should occur within 0 till $mean + $value.
    # With increasing number of fifo elements the factor (2.26 for 10 elements) goes towards 2.
    my $confidence = $std_dev * 2.26 / sqrt($num_samples);
    my $value =      int($mean + $confidence);

    say("DEBUG: num_samples($num_samples), mean($mean), confidence($confidence), " .
        "value($value)") if Auxiliary::script_debug("S4");
    return $mean, $value;
}


sub replay_runtime_adapt {
# Purpose
# -------
# Provide some optimized value for duration.
# The value computed depends on
# - $duration (== value assigned in rqg_batch call and/or config file)
# - $phase
# - $duration_adaption
# - values collected within replay_runtime_fifo during runtime
#
# FIXME maybe:
# Observation 2019-12
# The server crash during shutdown.
# So adapted duration is all time = duration assigned to rqg_batch.pl via command line or config.
# Maybe strangle that a bit?
#
    my $value;

    if      (PHASE_FIRST_REPLAY   eq $phase or
             PHASE_THREAD1_REPLAY eq $phase or
             PHASE_RVT_SIMP       eq $phase or
             PHASE_FINAL_REPLAY   eq $phase   ) {
        return $duration;
    } elsif (PHASE_GRAMMAR_SIMP   eq $phase   ) {
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
            # Lets assume the following:
            # The per config assigned duration is usually 300s.
            # The next derivate of the current parent grammar is either
            # A) capable to replay at all (*): 1 - z
            #    (*) Implies infinite number of attempts and endless runtime.
            # or
            # B) not capable to replay (**):       z
            #    (**) And that applies no matter how often or long we try.
            # 0 <= z <= 1
            # Some more detail to A)
            # The likelihood that we replay with endless duration and attempts is 1 - x.
            # Caused by the fact that the duration used is far way lower including that we have some
            # limited number of attempts we should expect for that
            #     0 <= 1 - y (== What we experience in average) <= 1 - z
            # What we would like to have
            #    Make based on (1 - y) some estimation (1 - x) which is roughly a bit bigger than
            #    (1 - z)
            # runtime properties like an actual average replaying grammar.
            # Ideal would be some calculation leading to some value for adapted duration which
            # would guarantee that >= 95% of all replays are included.
            # Note about the formulas used here
            # ---------------------------------
            # I do NOT claim that the YY grammar processing timespans of attempts which replayed
            # collected in @replay_runtime_fifo must follow some normal distribution!
            # Rationale:
            # Even the runtime X of some absolute deterministic test like easy doable based on MTR
            # varies depending on concurrent load of the testing box.
            # - concurrent test Y could differ from X per code
            # - even if the code of Y and X is the same Y could be started at a different point of
            #   time and be therefore in some different phase like initialize the server or compare
            #   results
            # In case of the Simplifier we have
            # - 1 up till n concurrent RQG runs
            # - these RQG runs have usually differing grammars including differing start times
            #   like run m is in phase YY grammar processing and some arbitrary run r is within
            #   the phase gendata.
            # The math used should be nothing else than a helper for computing some maximum
            # duration. In case that maximum duration is exceeded than it is assumed that either
            # - the grammar is not capable to replay at all
            # - the grammar is capable to replay but we have during the run already reached a state
            #   where a replay has become impossible
            #   Example:
            #   Assert during CREATE TABLE and the DROP TABLE was already shrinked away.
            #   In case the first CREATE had luck and did not hit the assert than the game is over.
            # In both cases limiting the duration would give a speedup.
            # Of course the computed maximum duration could be more or less imperfect.
            # My hope is the following:
            # - As long as the wins by good predictions overcompensate the losses by bad
            #   predictions we have some benefit.
            # - DURATION_ADAPTION_EXP shows compared to DURATION_ADAPTION_MAX
            #   - a more smooth adaptation with less drastic jumps
            #   - some more aggressive adaptation --> in average better speedup
            my ($r_mean, $r_value) = estimation(@replay_runtime_fifo);
            my ($e_mean, $e_value) = estimation(@estimate_runtime_fifo);
            if ($r_value > $duration) {
                $value = $duration;
            } elsif ($r_value > $e_mean) {
                $value = $r_value;
            } else {
                $value = int (($r_value * 2 + $e_mean) / 3);
            }
            replay_runtime_fifo_print();
            estimate_runtime_fifo_print();
            say("DEBUG: Replayer   duration fifo (r_mean, r_value) == ($r_mean, $r_value)\n" .
                "DEBUG: Speculativ duration fifo (e_mean, e_value) == ($e_mean, $e_value)\n" .
                "DEBUG: Adapted duration guessed: $value") if Auxiliary::script_debug("S4");
        } else {
            my $status = STATUS_INTERNAL_ERROR;
            Carp::cluck("INTERNAL ERROR: replay_runtime_adapt : The duration_adaption " .
                "'$duration_adaption' is unknown. Will exit with status " .
                status2text($status) . "($status)");
            Batch::emergency_exit($status);
        }
        # I have doubts if values < 10 are useful.
        if ($value < 10) {
            $value = 10;
        }
        return $value;
    } else {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: replay_runtime_adapt : The phase '$phase' is unknown. " .
            "Will exit with status " . status2text($status) . "($status)");
        Batch::emergency_exit($status);
    }
} # End sub replay_runtime_adapt


sub report_replay {
# Purpose
# -------
# Try to
# - make progress  (like have a better parent grammar as base for new jobs)
# - free resources (stop obsolete concurrent RQG runs)
# as soon as possible.
#
# Please be aware that some RQG Worker which has signalled that he replayed does not need
# to have already finished his work. This means simply stopping all RQG Workers executing a job
# based on the same order_id would probably also hit our "Winner" during final work.
# And that would cause losing all important and valuable collected information like RQG log
# maybe archive and more.
#
# Sample scenario
# ---------------
# t0
#    The RQG Worker 1 detects that he had a replay and signals that.
# t1 = t0 + a bit
#    lib/Batch.pm detects the signal and calls report_replay
# t2 = t1 + time required for archiving (if not disabled) + cleanup
#    The RQG Worker 1 signals that he has finished his task and exits.
# t3 = t2 + a bit
#    lib/Batch.pm detects that and calls register_result.
# Our win is roughly t3 - t1 which could be up to 200s depending on current CPU and IO load.
#

    my ($replay_grammar, $replay_grammar_parent, $order_id) = @_;

    if (@_ != 3) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: report_replay : 3 Parameters (replay_grammar, " .
                    "replay_grammar_parent, order_id) are required.");
        Batch::emergency_exit($status);
    }
    if (not defined $order_id) {
        Carp::cluck("INTERNAL ERROR: The third parameter order_id must be defined.");
        my $status = STATUS_INTERNAL_ERROR;
        Batch::emergency_exit($status);
    }

    my $response = Batch::REGISTER_GO_ON;

    if (PHASE_GRAMMAR_SIMP eq $phase) {
        # The update for $campaign_duds_since_replay (set to 0) comes in register_result.
        my $rgp = $replay_grammar_parent;
        if ($parent_grammar eq $replay_grammar_parent) {
            # Its a replayer based on the current parent grammar == The winner.

            # After reloading the grammar of the winner we get a new parent grammar.
            # Hereby all already running worker do something based on an outdated parent grammar.
            # Stop all where not much efforts were already invested.
            my $stop_count = Batch::stop_worker_till_phase(Auxiliary::RQG_PHASE_GENDATA,
                                                           Batch::STOP_REASON_WORK_FLOW . ' 11');
            # Stop all worker with same order_id except verdict in (interest, replay).
            Batch::stop_worker_on_order_except($order_id);

            my $source = $workdir . "/" . $replay_grammar;
            my $target = $workdir . "/" . $best_grammar;
            Batch::copy_file($source, $target);
            reload_grammar($replay_grammar);
            Batch::add_to_try_never($order_id);
            $grammar_simp_success = 1;
            $simp_success = 1;

            # In case the reload_grammar above lets some rule disappear than we could
            # stop all workers having some $order_id fiddling with the disappeared rule.
            my @orders_in_work = Batch::get_orders_in_work;
            say("DEBUG: orders currently in work: " . join(" - ", @orders_in_work))
                if Auxiliary::script_debug("S5");
            foreach my $order_in_work (@orders_in_work) {
                # The next line is for protecting the replayer we are inspecting.
                # He might be during archiving. And than the stop_worker_on_order_replayer
                # (a few lines lower) would stop him.
                next if $order_id == $order_in_work;
                my $rule_name = $order_array[$order_in_work][ORDER_PROPERTY2];
                if (not defined $rule_name) {
                    say("INTERNAL ERROR: Processing the orders in work rule_name is not " .
                        "defined, order_id $order_id. Will ask for an emergency_exit.");
                    my $status = STATUS_INTERNAL_ERROR;
                    Batch::emergency_exit($status);
                }
                my $return = GenTest::Simplifier::Grammar_advanced::rule_exists($rule_name);
                if (not defined $return) {
                    say("INTERNAL ERROR: Unable to figure out if the rule '$rule_name' " .
                        "exists. Will ask for an emergency_exit.");
                    my $status = STATUS_INTERNAL_ERROR;
                    Batch::emergency_exit($status);
                } elsif ($return) {
                    # That rule is used. Therefore the job in work stays valid.
                } else {
                    # That rule is not/no more used. Therefore the job is invalid.
                    say("DEBUG: Rule '$rule_name' occuring in order_id $order_in_work does " .
                        "no more exist but is currently under attack. Will stop all RQG " .
                        "Workers using that order.") if Auxiliary::script_debug("S5");
                    # Stop all worker with same order_id except verdict in (interest, replay).
                    Batch::stop_worker_on_order_except($order_in_work);
                    # Even some replayer using $order_in_work which is != $order_id is no more
                    # of interest. We run report_replay for a worker with $order_id.
                    # So he is safe.
                    Batch::stop_worker_on_order_replayer($order_in_work);
                    Batch::add_to_try_never($order_in_work);
                }
            }

            Batch::stop_worker_oldest_not_using_parent($replay_grammar_parent);

        } else {
            # Its a replayer with outdated grammar.
            # Hence we can postpone decision+loading to the point of time when the main process
            # of the RQG worker was reaped and the result gets processed.
            # So we do nothing.
        }
    } elsif (PHASE_THREAD_REDUCE eq $phase) {
        # $replay_grammar is the number of threads used in that RQG run.
        if (not defined $replay_grammar) {
            say("INTERNAL ERROR: \$replay_grammar is not defined, order_id $order_id. " .
                "Will ask for an emergency_exit.");
                my $status = STATUS_INTERNAL_ERROR;
                Batch::emergency_exit($status);
        }
        if (not $replay_grammar =~ /^[1-9][0-9]*$/) {
            say("INTERNAL ERROR: ->" . $replay_grammar . "<- is not an int > 0. " .
                "Will ask for an emergency_exit.");
                my $status = STATUS_INTERNAL_ERROR;
                Batch::emergency_exit($status);
        }
        # The update for $campaign_duds_since_replay (set to 0) comes in register_result.
        if ($replay_grammar < $threads) {
            # 0. Its a replayer providing progress.
            $threads               = $replay_grammar;
            $simp_success          = 1;
            $thread_reduce_success = 1;
            my $iso_ts = isoTimestamp();
            Batch::write_result("$iso_ts          Number of threads reduced to $threads \n");

            # 1. Stop all worker fiddling with the same $order_id except they have reached
            #    'replay' or 'interest'.
            Batch::stop_worker_on_order_except($order_id);

            Batch::add_to_try_never($order_id);

            # 2. The "$threads = $grammar_used;" above makes all jobs/orders going with some higher
            #    number of threads obsolete.
            # Stop all workers having some $order_id fiddling with a higher number of threads.
            my @orders_in_work = Batch::get_orders_in_work;
            say("DEBUG: orders currently in work: " . join(" - ", @orders_in_work))
                if Auxiliary::script_debug("S5");
            foreach my $order_in_work (@orders_in_work) {
                # The next line if for protecting the replayer we are inspecting.
                # He might be during archiving. And than the stop_worker_on_order_replayer
                # (a few lines lower) would stop him.
                next if $order_id == $order_in_work;
                my $threads_in_order = $order_array[$order_in_work][ORDER_PROPERTY2];
                if (not defined $threads_in_order) {
                    say("INTERNAL ERROR: Processing the orders in work threads_in_order is not " .
                        "defined, order_id $order_id. Will ask for an emergency_exit.");
                    my $status = STATUS_INTERNAL_ERROR;
                    Batch::emergency_exit($status);
                }
                if ($threads_in_order > $threads) {
                    # That number of threads has now become obsolete.
                    say("DEBUG: Threads reduced to $threads_in_order in order_id " .
                        "$order_in_work is now obsolete but currently in work. " .
                        "Will stop all RQG Workers using that order.")
                        if Auxiliary::script_debug("S5");
                    Batch::stop_worker_on_order_except($order_in_work);
                    # Even some replayer is no more of interest.
                    Batch::stop_worker_on_order_replayer($order_in_work);
                    Batch::add_to_try_never($order_in_work);
                }
            }

            # 3. Never run certain stop routines like PHASE_GRAMMAR_SIMP does
            #    - Batch::stop_worker_till_phase(Auxiliary::RQG_PHASE_GENDATA
            #    - Batch::stop_worker_oldest_not_using_parent
            #    because they
            #    - do not use more threads than the current value $threads
            #    - use more threads than the current value $threads but have reached 'interest'.

        } else {
            # Its a too late replayer or we just inspected him again.
        }
    } elsif (PHASE_RVT_SIMP eq $phase) {
        my $rvt_now = get_shrinked_rvt_options(undef, undef, 0);
        if ($replay_grammar_parent eq $rvt_now) {
            # Its a first winner.
            my $rvt_options = get_shrinked_rvt_options($order_array[$order_id][ORDER_PROPERTY2],
                                     $order_array[$order_id][ORDER_PROPERTY3], 1);
            if (not defined $rvt_options) {
                Carp::cluck("INTERNAL ERROR: rvt_options is undef.");
                my $status = STATUS_INTERNAL_ERROR;
                Batch::emergency_exit($status);
            }
            my $stop_count = Batch::stop_worker_till_phase(Auxiliary::RQG_PHASE_GENDATA,
                                                           Batch::STOP_REASON_WORK_FLOW . ' 12');
            Batch::stop_worker_on_order_except($order_id);
            Batch::add_to_try_never($order_id);
            $rvt_simp_success = 1;
            $simp_success = 1;
        } else {
            # Its a too late winner.
            # So we do nothing.
        }
    } elsif (PHASE_FIRST_REPLAY eq $phase or PHASE_THREAD1_REPLAY eq $phase or
             PHASE_FINAL_REPLAY eq $phase) {
        # Its a phase with end (after register_result) ahead.
        my $stop_count = Batch::stop_worker_till_phase(Auxiliary::RQG_PHASE_GENDATA,
                                                       Batch::STOP_REASON_WORK_FLOW . ' 13');
        Batch::stop_worker_on_order_except($order_id);
        Batch::add_to_try_never($order_id);
    } else {
        Carp::cluck("INTERNAL ERROR: report_replay: Handling for phase '$phase' is missing.");
        my $status = STATUS_INTERNAL_ERROR;
        Batch::emergency_exit($status);
    }
    return $response;
} # End sub report_replay


sub load_grammar {

# In case loading the grammar fails -> $grammar_string is undef
# -> load_step will detect that and abort.

    my ($grammar_file, $max_inline_length) = @_;

    # Actions of GenTest::Simplifier::Grammar_advanced::init
    # ...  Gentest::...Simplifier ....load_grammar($grammar_file);
    # ...  fill_rule_hash();
    # ...  print_rule_hash();
    # ...  analyze_all_rules(); -- Maintains counter except weight and removes unused rules
    # ...  compact_grammar      -- collapseComponents (unique) and inlining
    # Attention: This resets if some rule was already processed.
    $grammar_string = GenTest::Simplifier::Grammar_advanced::init(
             $workdir . "/" . $grammar_file, $threads, $max_inline_length, $grammar_flags);
    load_step($grammar_file);
}

sub reload_grammar {

# In case reloading the grammar fails -> $grammar_string is undef
# -> load_step will detect that and abort.

    my ($grammar_file) = @_;

    # Actions of GenTest::Simplifier::Grammar_advanced::reload_grammar
    # ...  Gentest::...Simplifier ....load_grammar($grammar_file);
    # ...  reset_rule_hash_values();  <-- This preserves the info that jobs for a rule were generated!
    # ...  print_rule_hash();
    # ...  analyze_all_rules(); -- Maintains counter except weight and removes unused rules
    # ...  compact_grammar();   -- collapseComponents (unique) and NO inlining
    # Problem: This seems to reset if some rule was already processed.
    $grammar_string = GenTest::Simplifier::Grammar_advanced::reload_grammar(
                      $workdir . "/" . $grammar_file, $threads, $grammar_flags);
    load_step($grammar_file);
}

sub load_step {

    my ($grammar_file) = @_;

    if (not defined $grammar_string) {
        my $status = STATUS_INTERNAL_ERROR;
        say("INTERNAL ERROR: Loading a grammar file within Simplifier::Grammar_advanced failed. " .
            "Will ask for emergency exit." . Auxiliary::exit_status_text($status));
        Batch::emergency_exit($status);
    }
    my $status = GenTest::Simplifier::Grammar_advanced::calculate_weights();
    if($status) {
        my $status = STATUS_INTERNAL_ERROR;
        say("INTERNAL ERROR: GenTest::Simplifier::Grammar_advanced::calculate_weights failed. " .
            "Will ask for emergency exit." . Auxiliary::exit_status_text($status));
        Batch::emergency_exit($status);
    }
    # Aborts if
    # - $grammar_string is not defined
    # - creation of new parent grammar file makes sense but fails
    if (make_parent_from_string ($grammar_string)) {
        my $iso_ts = isoTimestamp();
        Batch::write_result("$iso_ts          $grammar_file     loaded with threads = $threads " .
                            "==> new parent grammar '$parent_grammar'\n");
    }
}


sub get_shrinked_rvt_options {
    my ($option_to_attack, $value_to_remove, $write_through) = @_;

    if (@_ != 3) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: get_shrinked_rvt_options : 3 Parameters (option_to_attack," .
                    "value_to_remove, $write_through) are required.");
        Batch::emergency_exit($status);
    }
    if (not defined $option_to_attack      or
        $option_to_attack eq 'reporter'    or
        $option_to_attack eq 'validator'   or
        $option_to_attack eq 'transformer'   ) {
        # Do nothing.
    } else {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: get_shrinked_rvt_options : option_to_attack is '" .
                    "$option_to_attack'  but needs to be undef or 'reporter' or 'validator' or " .
                    "'transformer',");
        Batch::emergency_exit($status);
    }
    if (not defined $write_through) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: get_shrinked_rvt_options : write_through is undef.");
        Batch::emergency_exit($status);
    }

    my %reporter_hash_copy    = %reporter_hash;
    my %validator_hash_copy   = %validator_hash;
    my %transformer_hash_copy = %transformer_hash;

    if (defined $option_to_attack) {
        my $shrinked = 0;
        if      ($option_to_attack eq 'reporter') {
            if ("_all_to_None" eq $value_to_remove) {
                if ((1 != scalar keys %reporter_hash_copy)    or
                    (1 == scalar keys %reporter_hash_copy and
                     not exists $reporter_hash_copy{'None'})    ) {
                    # We have either
                    # - more elements than just one (-> in minimum one cannot be 'None')
                    # - one element and that is not 'None'
                    %reporter_hash_copy = ();
                    $reporter_hash_copy{'None'} = 1;
                    $shrinked = 1;
                } else {
                    $shrinked = 0;
                }
            } elsif ("_add_None" eq $value_to_remove) {
                if (not exists $reporter_hash_copy{'None'}) {
                    $reporter_hash_copy{'None'} = 1;
                    $shrinked = 1;
                } else {
                    $shrinked = 0;
                }
            } else {
                # Other value --> We try a removal
                if (exists $reporter_hash_copy{$value_to_remove}) {
                    delete $reporter_hash_copy{$value_to_remove};
                    say("DEBUG: get_shrinked_rvt_options : reporter - $value_to_remove")
                        if Auxiliary::script_debug("S6");
                    $shrinked = 1;
                } else {
                    say("DEBUG: get_shrinked_rvt_options : reporter already without " .
                        "$value_to_remove") if Auxiliary::script_debug("S6");
                    $shrinked = 0;
                }
            }
        } elsif ($option_to_attack eq 'validator') {

            if ("_all_to_None" eq $value_to_remove) {
                if ((1 != scalar keys %validator_hash_copy)    or
                    (1 == scalar keys %validator_hash_copy and
                     not exists $validator_hash_copy{'None'})    ) {
                    # We have either
                    # - more elements than just one (-> in minimum one cannot be 'None')
                    # - one element and that is not 'None'
                    %validator_hash_copy = ();
                    $validator_hash_copy{'None'} = 1;
                    %transformer_hash_copy = ();
                    $shrinked = 1;
                } else {
                    $shrinked = 0;
                }
            } elsif ("_add_None" eq $value_to_remove) {
                if (not exists $validator_hash_copy{'None'}) {
                    $validator_hash_copy{'None'} = 1;
                    $shrinked = 1;
                } else {
                    $shrinked = 0;
                }
            } else {
                # Other value --> We try a removal
                if (exists $validator_hash_copy{$value_to_remove}) {
                    delete $validator_hash_copy{$value_to_remove};
                    say("DEBUG: get_shrinked_rvt_options : validator - $value_to_remove")
                        if Auxiliary::script_debug("S6");
                    $shrinked = 1;
                } else {
                    say("DEBUG: get_shrinked_rvt_options : validator already without " .
                        "$value_to_remove") if Auxiliary::script_debug("S6");
                    $shrinked = 0;
                }
            }

        } elsif ($option_to_attack eq 'transformer') {
            if ("_all_to_None" eq $value_to_remove) {
                if ((1 != scalar keys %transformer_hash_copy)    or
                    (1 == scalar keys %transformer_hash_copy and
                     not exists $transformer_hash_copy{'None'})    ) {
                    # We have either
                    # - more elements than just one (-> in minimum one cannot be 'None')
                    # - one element and that is not 'None'
                    %transformer_hash_copy = ();
                    $transformer_hash_copy{'None'} = 1;
                    $shrinked = 1;
                } else {
                    $shrinked = 0;
                }
            } elsif ("_add_None" eq $value_to_remove) {
                if (not exists $transformer_hash_copy{'None'}) {
                    $transformer_hash_copy{'None'} = 1;
                    $shrinked = 1;
                } else {
                    $shrinked = 0;
                }
            } else {
                # Other value --> We try a removal
                if (exists $transformer_hash_copy{$value_to_remove}) {
                    delete $transformer_hash_copy{$value_to_remove};
                    say("DEBUG: get_shrinked_rvt_options : transformer - $value_to_remove")
                        if Auxiliary::script_debug("S6");
                    $shrinked = 1;
                } else {
                    say("DEBUG: get_shrinked_rvt_options : transformer already without " .
                        "$value_to_remove") if Auxiliary::script_debug("S6");
                    $shrinked = 0;
                }
            }

        }
        if (not $shrinked) {
            say("DEBUG: get_shrinked_rvt_options : The combination option_to_attack " .
                "'$option_to_attack' value_to_remove '$value_to_remove' has become invalid.")
                if Auxiliary::script_debug("S5");
            return undef;
        }
    }

    my $rvt_option_snip = '';
    if (scalar keys %reporter_hash_copy)    {
        $rvt_option_snip .= " --reporters="    . join(",", sort keys %reporter_hash_copy);
    }
    if (scalar keys %validator_hash_copy)   {
        $rvt_option_snip .= " --validators="   . join(",", sort keys %validator_hash_copy);
    }
    if (scalar keys %transformer_hash_copy) {
        $rvt_option_snip .= " --transformers=" . join(",", sort keys %transformer_hash_copy);
    }
    if (defined $rvt_option_snip and 1 == $write_through) {
        %reporter_hash    = %reporter_hash_copy;
        %validator_hash   = %validator_hash_copy;
        %transformer_hash = %transformer_hash_copy;
        say("INFO: Reporter/validator/transformer setting rewrite to ->$rvt_option_snip<-.");
        my $iso_ts = isoTimestamp();
        Batch::write_result("$iso_ts          Reporter/validator/transformer shrinked " .
                        "==> new setting '" . $rvt_option_snip . "'.\n");
    }

    return $rvt_option_snip;
}

sub rvt_cut_steps {
# We just want some rough number for avoiding most probably failing replay attempts.
    # FIXME:
    # Maybe refine more.
    # Only one reporter and that with a name != 'None' could be replaced by 'None etc.
    my $cut_steps = (keys %reporter_hash) + (keys %validator_hash) + (keys %transformer_hash) - 3;
    say("DEBUG: RVT cut steps estimation : $cut_steps") if Auxiliary::script_debug("S5");
    return $cut_steps;
}

sub make_parent_from_string {
# Returns
# 1 -- new (different) parent grammar file generated
# 0 -- no parent grammar file generated because no progress achieved

    my ($grammar_string) = @_;

    if (not defined $grammar_string) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: grammar_string is not defined.");
        Batch::emergency_exit($status);
    }
    if ($parent_grammar_string eq $grammar_string) {
        # In case the old parent equals the potential new parent than don't create a new parent.
        say("DEBUG: Simplifier::make_parent_from_string: No progress achieved. Stick to old " .
            "parent grammar.") if Auxiliary::script_debug("S4");
        return 0;
    } else {
        if (Auxiliary::script_debug("S5")) {
            say("DEBUG: OLD ->$parent_grammar_string<");
            say("DEBUG: NEW ->$grammar_string<");
        }
        $parent_grammar= "p" . Auxiliary::lfill0($parent_number,5) . ".yy";
        Batch::make_file($workdir . "/" . $parent_grammar, $grammar_string . "\n");
        $parent_grammar_string = $grammar_string;
        $parent_number++;
        return 1;
    }
}

sub make_child_from_parent {
    $child_grammar = "c" . Auxiliary::lfill0($child_number,5) . ".yy";
    my $source     = $workdir . "/" . $parent_grammar;
    my $target     = $workdir . "/" . $child_grammar;
    Batch::copy_file($source, $target);
    $child_number++;
}

sub free_memory {
    @order_array           = ();
    @reporter_array        = ();
    %reporter_hash         = ();
    @transformer_array     = ();
    %transformer_hash      = ();
    @validator_array       = ();
    %validator_hash        = ();
    @replay_runtime_fifo   = ();
    @estimate_runtime_fifo = ();
}

1;

