# Copyright (C) 2018, 2022 MariaDB Corporation Ab.
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

package GenTest_e::Simplifier::Grammar;

require Exporter;
@ISA = qw(GenTest_e);

# Note:
# Its currently unclear if routines managing the simplification process
# need access to all these constants.
# Main reason for having them exported:
# GenTest_e::Simplifier::Grammar::<constant> is quite long.
@EXPORT = qw(
    RULE_WEIGHT
    RULE_RECURSIVE
    RULE_REFERENCING
    RULE_REFERENCED
    RULE_JOBS_GENERATED
    RULE_IS_PROCESSED
    RULE_UNIQUE_COMPONENTS
    RULE_IS_TOP_LEVEL
    SIMP_EMPTY_QUERY
    SIMP_WAIT_EXIT_QUERY
    SIMP_EXIT_QUERY
);

use utf8;
use strict;
use Carp;
use lib 'lib';

use GenTest_e;
use GenTest_e::Constants;
use GenTest_e::Grammar;
use GenTest_e::Grammar::Rule;

my $script_debug = 0;

# sub fill_rule_hash();
# sub print_rule_hash();
# sub analyze_all_rules();

# Constants
use constant SIMP_GRAMMAR_OBJ     => 0;
use constant SIMP_RULE_HASH       => 1;
use constant SIMP_GRAMMAR_FLAGS   => 2;
use constant SIMP_THREADS         => 3;

my $component_indent = GenTest_e::Grammar::Rule::COMPONENT_INDENT;

# Constants used in phases when the YY grammar gets shrinked
# ----------------------------------------------------------
# SIMP_EMPTY_QUERY is for replacing the complete content of a non top level rule.
use constant SIMP_EMPTY_QUERY     => '';
# SIMP_WAIT_QUERY is for replacing the complete content of a top level rule like thread<n> and
# maybe query.
# If using case SIMP_EMPTY_QUERY for such a top level rule we would just waste CPU power.
# Hence we go with a wait which is less costly. A "SELECT SLEEP(1)" would make "SQL noise" without
# value because the really working threads or reporters could detect some not responding or dead
# DB server too. So we use Perl.
# The next line caused a lot trouble. AFAIR something with reporters.
  use constant SIMP_EXIT_QUERY      => '{ exit 0 }';
  use constant SIMP_WAIT_EXIT_QUERY => '{ sleep 30 ; exit 0 }';
# Experiment end

# Structure for keeping the actual grammar
#-----------------------------------------
my $grammar_obj;

my %rule_hash;

my ($threads, $grammar_flags);

sub init {
    (my $grammar_file, $threads, my $max_inline_length, $grammar_flags) = @_;

    my $snip = "GenTest_e::Simplifier::Grammar::init:";
    if (@_ != 4) {
        Carp::cluck("INTERNAL ERROR: $snip 4 Parameters (grammar_file, " .
                    "threads, max_inline_length, grammar_flags) are required.");
        say("INTERNAL ERROR: Grammar::init: Will return undef.");
        return undef;
    }

    Carp::cluck("DEBUG: $snip (grammar_file, threads, max_inline_length, " .
                "grammar_flags) entered") if $script_debug;

    if (not defined $max_inline_length) {
        Carp::cluck("INTERNAL ERROR: max_inline_length is not defined. Will return undef.");
        say("INTERNAL ERROR: Grammar::init: Will return undef.");
        return undef;
    }
    if (not defined $threads) {
        Carp::cluck("INTERNAL ERROR: threads is not defined. Will return undef.");
        say("INTERNAL ERROR: Grammar::init: Will return undef.");
        return undef;
    }

    if (STATUS_OK != load_grammar_from_files($grammar_file)) {
        say("INTERNAL ERROR: $snip load_grammar_from_files failed. Will return undef.");
        return undef;
    }

    # The extension gets placed on top so that any definitions of rules with the same names
    # of the non extended grammar win.
    my $extended_grammar = "thread: "        . SIMP_WAIT_EXIT_QUERY  . " ;\n" .
                           "thread_init: "   . SIMP_EMPTY_QUERY      . " ;\n" .
                           "thread_connect:" . SIMP_EMPTY_QUERY      . " ;\n" .
                           $grammar_obj->toString();
    if (STATUS_OK != load_grammar_from_string($extended_grammar)) {
        say("INTERNAL ERROR: $snip load_grammar_from_string failed. Will return undef.");
        return undef;
    }

    # Replace some maybe filled %rule_hash by some new one.
    # --> There might be non reachable rules between!
    # --> This init sets RULE_JOBS_GENERATED to 0 !!!
    fill_rule_hash();
    # print_rule_hash();
    # print($grammar_obj->toString() . "\n");
    # print("----------------------------------\n");

    if (STATUS_OK != analyze_all_rules()) {
        say("INTERNAL ERROR: $snip analyze_all_rules failed. Will return undef.");
        return undef;
    }
    # print("\n# Grammar after analyze_all_rules ----------\n");
    # print($grammar_obj->toString() . "\n");
    # print("----------------------------------\n");
    print_rule_hash() if $script_debug;

    # Inline anything which has a length <= $max_inline_length.
    if (STATUS_OK != compact_grammar($max_inline_length)) {
        say("INTERNAL ERROR: $snip compact_grammar failed. Will return undef.");
        return undef;
    }
    # print("\n# Grammar after compact_grammar ----------\n");
    # print($grammar_obj->toString() . "\n");
    # print("----------------------------------\n");
    print_rule_hash() if $script_debug;

    if (not defined $grammar_obj) {
        Carp::cluck("grammar_obj is not defined");
        say("INTERNAL ERROR: $snip Will return undef.");
        return undef;
    }

    # FIXME:
    # Lets assume
    # <rule>:
    #    DEF |
    #        |
    #    ABC |
    #        ;
    # Reorder the elements to
    # <rule>:
    #        |
    #        |
    #    DEF |
    #    ABC ;
    # by
    # - grouping equal elements together
    # - having empty elements first
    # - having ALTERs, KILLs, SET servervariables last?
    # so that
    # - the grammar is more comfortable readable
    # - the removal of critical statements is tried first.
    # FIXME: No grouping and decision about order when generating the orders.
    #

    # Some consistency check for grammar
    foreach my $rule_name (sort keys %rule_hash) {
        my @unique_component_list = get_unique_component_list($rule_name);
        if (1 > scalar @unique_component_list) {
            say("INTERNAL ERROR: Rule '$rule_name' less than one unique components. " .
                "Will return undef.");
            return undef;
        } else {
            say("DEBUG: '$rule_name' UCL -->" . join("<-->", @unique_component_list) . "<--")
                if $script_debug;
        }
    }

    my $final_string = $grammar_obj->toString();
    say("DEBUG: $snip End reached. Returning grammar string ==>\n" . $final_string . "\n<==")
        if $script_debug;
    return $final_string;

} # End sub init


sub reload_grammar {
# Purpose
# -------
# Already at begin of grammar simplification we need to load the content of a grammar file into
# corresponding structures. This would be some one time action.
# But in case we run grammar simplification with competing RQG runs using different shrinked
# versions of the last good grammar than we need to know the grammar of the "winner".
# In case we only memorize the name of the grammar file than we need to reload the grammar in
# order to harvest the progress. And that's the most frequent use case of the current routine.
#

    my ($grammar_file, $threads, $grammar_flags) = @_;
    # !!! The caller might have changed the value for threads compared to the previous run !!!

    my $snip = "GenTest_e::Simplifier::Grammar::reload_grammar:";

    if (@_ != 3) {
        Carp::cluck("INTERNAL ERROR: Grammar::reload_grammar: 3 Parameters " .
                    "(grammar_file, threads, grammar_flags) are required.");
        say("INTERNAL ERROR: $snip Will return undef.");
        return undef;
    }

    Carp::cluck("DEBUG: $snip (grammar_file, threads, grammar_flags)" .
                " entered") if $script_debug;

    if (not defined $threads) {
        say("INTERNAL ERROR: $snip threads is not defined. Will return undef.");
        return undef;
    }
    if (STATUS_OK != load_grammar_from_files($grammar_file)) {
        Carp::cluck("INTERNAL ERROR: reload_grammar failed. Will return undef.");
        return undef;
    }
    reset_rule_hash_values(); # This resets most rule_hash values belonging to a rule
                              # except RULE_JOBS_GENERATED.
    # print_rule_hash();
    if (STATUS_OK != analyze_all_rules()) {
        Carp::cluck("INTERNAL ERROR: analyze_all_rules failed. Will return undef.");
        return undef;
    }
    print_rule_hash() if $script_debug;
    # Do not inline anything because we are inside a grammar simplification campaign.
    my $max_inline_length = -1;
    if (STATUS_OK != compact_grammar($max_inline_length)) {
        Carp::cluck("INTERNAL ERROR: compact_grammar failed.");
        say("INTERNAL ERROR: $snip Will return undef.");
        return undef;
    }
    if (not defined $grammar_obj) {
        Carp::cluck("grammar_obj is not defined");
        say("INTERNAL ERROR: $snip Will return undef.");
        return undef;
    }

    return $grammar_obj->toString();

} # End sub reload_grammar


sub get_unique_component_list {
# lib/GenTest_e/Grammar/Rule.pm routine unique_components with code example.
#
# Purpose
# -------
# Return a list with pointer to the unique components of a rule.
# The list has to be sorted according to the direction of removal (left most/last component first).
# ATTENTION: The implementation mentioned above is a list of strings.
#
# How to use that in grammar simplification?
# ------------------------------------------
# When starting to attack a rule
# 1. Get that list
# 2. For element in that list
#       Try with shrinked rule where all occurences of that element are removed.
#
# Advantage:
# No need to go with the grammar_flag GRAMMAR_FLAG_COMPACT_RULES which would eliminate are
# grammar simplification begin all duplicates. And that could change the properties of the test
# at runtime drastic compared to the original non touched grammar.
# Going via 'get_unique_component_list' does not increase the number of simplification steps.
#
# Example
# -------
# rule: a | b | a | d ; ==> unique_component_list: d, a, b ;
#
    my ($rule_name) = @_;

    my $rule_obj = $grammar_obj->rule($rule_name);
    return $rule_obj->unique_components();

}

sub estimate_cut_steps {
# Estimate the number of orders to be generated if going with non destructive simplification.

    my $count = 0;

    foreach my $rule_name (sort keys %rule_hash ) {
        my $rule_obj                   = $grammar_obj->rule($rule_name);
        my @rule_unique_component_list = $rule_obj->unique_components();
        my $count_add                  = scalar @rule_unique_component_list - 1;
        $count += $count_add;
        if (0) {
            say("DEBUG: estimate_cut_steps: rule_name '$rule_name', count_add $count_add, " .
                "count_total $count");
        }
    }
    return $count;
}


sub load_grammar_from_files {

    my ($grammar_file)= @_;
    my @grammar_files;
    $grammar_files[0] = $grammar_file;

    $grammar_obj = GenTest_e::Grammar->new(
           'grammar_files'  => \@grammar_files,
           'grammar_flags'  => $grammar_flags
    );
    if (not defined $grammar_obj) {
        # Example: Open the grammar file failed.
        say("ERROR: GenTest_e::Simplifier::Grammar: Filling the grammar_obj failed. " .
            "Will return STATUS_ENVIRONMENT_FAILURE.");
        return STATUS_ENVIRONMENT_FAILURE;
    }
    return STATUS_OK;
}


sub load_grammar_from_string {

    my ($grammar_string)= @_;

    $grammar_obj = GenTest_e::Grammar->new(
           'grammar_string'  => $grammar_string,
           'grammar_flags'  => $grammar_flags
    );
    if (not defined $grammar_obj) {
        say("ERROR: GenTest_e::Simplifier::Grammar: Filling the grammar_obj failed. " .
            "Will return STATUS_ENVIRONMENT_FAILURE.");
        return STATUS_ENVIRONMENT_FAILURE;
    }
    return STATUS_OK;
}


# %rule_hash for keeping more or less actual properties of grammar rules
# ----------------------------------------------------------------------
# Key is rule_name
#
# Please see the amount of variables as experimental.
# - some might be finally superfluous completely because than maybe functions deliver exact data on
#   the fly and are better than the error prone maintenance of information in %rule_hash
# - some might be maintained but currently unused. Maybe some future improvements of the simplifier
#   can exploit them
# - some might be neither exploited nor maintained
#   see them as "place holder" waiting for either maintenance+exploitation or removal
#
# The weight values computed and assigned to the rules should do nothing else than roughly (*)
# ensure that the following is valid for all rules
#     IF L(rule A) > L(rule B) than W(rule A) > W(rule B) for all rules except rule A = B.
# --> List of rules ordered by likelihood to get used ~ List of rules ordered by their weight.
# (*) roughly because
# - the weight computing algorithm should be not too complex and hereby most probably slow
#   Imagine recursive rules or some rule 'where_cond' used in higher level rules like 'select'
#   and 'update'.
# - we have most probably several top level rules
#      Example:
#      a) query
#         Use after being connected and having query_init and query_connect run.
#         Many times.
#      b) query_init
#         Use after the first connect before query_connect.
#         ==> Once per test run
#      c) query_connect
#         Use after first connect+query_init but also after any reconnect.
#         ==> In minimum once per test run up to not that rare.
#   and all these top level rules might use other rules from the remaining pool of rules
#   up to other top level rules.
#   There is all time the non solvable conflict of objectives
#      A) smallest grammar possible --> Easier "guessing" what might be "guilty".
#      B) grammar with fast replay  --> Faster check of patches etc.
#   in background. Using 'query_init' is extreme rare. But "attacking" is earlier could
#   lead to some serious speed up of the simplification process.
# So a good enough weight computation algorithm is important but nothing more.
#
use constant RULE_WEIGHT                 => 0;
#
# Set to 1 in case the current rule is referenced in some of its components.
# Otherwise 0
# There has to be nothing charged into RULE_REFERENCING or RULE_REFERENCED!
use constant RULE_RECURSIVE              => 1;
#
# How often components of the current rule reference other rules.
# Self referencing leads to RULE_RECURSIVE = 1 but does not get charged into RULE_REFERENCING!
use constant RULE_REFERENCING            => 2;
#
# How often the current rule is referenced by components of other rules.
# In case RULE_REFERENCED is 0 and RULE_IS_TOP_LEVEL is 0 than the rule is no more relevant
# and could be deleted.
# Self referencing leads to RULE_RECURSIVE = 1 but does not get charged into RULE_REFERENCED!
use constant RULE_REFERENCED             => 3;
#
# We work with "walk through the grammar" rounds.
# At begin of such a round
# - are no pregenerated jobs at all
# - all rules have the value JOBS_GENERATED = 0
# As soon as
# - all thinkable jobs for simplifying the current rule were generated this is set to 1.
# - none of the rules has JOBS_GENERATED = 1 than all the rules were obvious processed.
#   And at least the generation of thinkable jobs for the current "Walk through the grammar"
#   round is over. If these thinkable jobs were already executed or have become obsolete
#   or will get executed in nearby future does not matter for that variable.
use constant RULE_JOBS_GENERATED         => 4;
#
# It happens frequent during one "walk through the grammar" round that all rules need to get
# processed like recompute their weight. And that applies even to rules with JOBS_GENERATED = 1.
# Hence we cannot use the JOBS_GENERATED field.
# As soon as
# - a rule was processed than this is set to 1.
# - none of the rules has IS_PROCESSED = 0 than all the rules were obvious processed.
use constant RULE_IS_PROCESSED           => 5;
#
# Number of unique components of the current rule
use constant RULE_UNIQUE_COMPONENTS      => 6;
#
# set to 1 if its a top level rule
# One of the crowd of threads assigned (-> $threads) will use it as entry for generating a
# full query.
# Only the rules following the name patterns
# - query , thread<number>
# - query_init , thread<number>_init
# - query_connect , thread_connect, thread<number>_connect
# could be used for such a purpose. But if they will be later really used for that depends on
# the number of threads assigned.
# Example with $threads=3:
#    A rule 'thread4' will never act for some thread as top level rule except there is a
#        query_*/thread<1 till 3>*: thread4 ;
#    It could be also used in components of other rules like
#        thread2: thread4 | ddl ;
#    and even become top level in case 'ddl' could get shrinked away.
use constant RULE_IS_TOP_LEVEL           => 7;
#


sub print_rule_info {

    my ($rule_name) = @_;

    # GenTest_e::Simplifier::Grammar::print_rule_info();
    #   == Nothing assigned --> Error like undef assigned.
    # GenTest_e::Simplifier::Grammar::print_rule_info(undef);
    # GenTest_e::Simplifier::Grammar::print_rule_info('inknown');
    if (not defined $rule_name) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: print_rule_info was called with " .
                    "some undef rule_name assigned. " . Auxiliary::exit_status_text($status));
        return $status;
    }
    if (not exists $rule_hash{$rule_name}) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: print_rule_info : The rule '$rule_name' is unknown. " .
                    Auxiliary::exit_status_text($status));
        return $status;
    }

    my $rule_info = $rule_hash{$rule_name};
    say("DEBUG: '$rule_name' RULE_WEIGHT : "            . $rule_info->[RULE_WEIGHT]);
    say("DEBUG: '$rule_name' RULE_RECURSIVE : "         . $rule_info->[RULE_RECURSIVE]);
    say("DEBUG: '$rule_name' RULE_REFERENCING : "       . $rule_info->[RULE_REFERENCING]);
    say("DEBUG: '$rule_name' RULE_REFERENCED : "        . $rule_info->[RULE_REFERENCED]);
    say("DEBUG: '$rule_name' RULE_JOBS_GENERATED : "    . $rule_info->[RULE_JOBS_GENERATED]);
    say("DEBUG: '$rule_name' RULE_IS_PROCESSED : "      . $rule_info->[RULE_IS_PROCESSED]);
    say("DEBUG: '$rule_name' RULE_UNIQUE_COMPONENTS : " . $rule_info->[RULE_UNIQUE_COMPONENTS]);
    say("DEBUG: '$rule_name' RULE_IS_TOP_LEVEL : "      . $rule_info->[RULE_IS_TOP_LEVEL]);
}


sub print_rule_hash {
    say("DEBUG: Print of rule_hash content ========== begin");
    foreach my $rule_name (sort keys %rule_hash ) {
        say("---------------------");
        print_rule_info ($rule_name);
    }
    say("DEBUG: Print of rule_hash content ========== end")
}


sub add_rule_to_hash {
    my ($rule_name) = @_;
    # Bail out if  $rule_name is undef or $rule_name exists
    $rule_hash{$rule_name}->[RULE_WEIGHT]            =      0;
    $rule_hash{$rule_name}->[RULE_RECURSIVE]         =      0;
    $rule_hash{$rule_name}->[RULE_REFERENCING]       =      0;
    $rule_hash{$rule_name}->[RULE_REFERENCED]        =      0;
    $rule_hash{$rule_name}->[RULE_JOBS_GENERATED]    =      0;
    $rule_hash{$rule_name}->[RULE_IS_PROCESSED]      =      0;
    $rule_hash{$rule_name}->[RULE_UNIQUE_COMPONENTS] =      0;
    $rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL]      =      0;
    say("DEBUG: add_rule_to_hash : rule '$rule_name' added.") if $script_debug;
}


sub fill_rule_hash {
    undef %rule_hash;
    foreach my $rule_name ( keys %{$grammar_obj->rules()} ) {
        add_rule_to_hash($rule_name);
    }
}

sub reset_rule_hash_values {
    foreach my $rule_name ( keys %{$grammar_obj->rules()} ) {
        $rule_hash{$rule_name}->[RULE_WEIGHT]            =      0;
        $rule_hash{$rule_name}->[RULE_RECURSIVE]         =      0;
        $rule_hash{$rule_name}->[RULE_REFERENCING]       =      0;
        $rule_hash{$rule_name}->[RULE_REFERENCED]        =      0;
        # Keeping the value for RULE_JOBS_GENERATED is essential
        # during grammar simplification campaigns.
        # $rule_hash{$rule_name}->[RULE_JOBS_GENERATED]    =      0;
        $rule_hash{$rule_name}->[RULE_IS_PROCESSED]      =      0;
        $rule_hash{$rule_name}->[RULE_UNIQUE_COMPONENTS] =      0;
        $rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL]      =      0;
    }
}


sub grammar_rule_hash_consistency {
    my $is_inconsistent = 0;
    foreach my $rule_name ( keys %{$grammar_obj->rules()} ) {
        if (not exists $rule_hash{$rule_name}) {
            say("INTERNAL ERROR: '$rule_name' is in grammar_obj but not in rule_hash");
            $is_inconsistent = 1;
        }
    }
    foreach my $rule_name ( keys %rule_hash ) {
        if (not defined $grammar_obj->rule($rule_name)) {
            say("INTERNAL ERROR: '$rule_name' is in rule_hash but not in grammar_obj");
            $is_inconsistent = 1;
        }
    }
    if ($is_inconsistent) {
        Carp::cluck("INTERNAL ERROR: Cannot survive with grammar_obj to rule_hash inconsistency.");
        return STATUS_INTERNAL_ERROR;
    } else {
        return STATUS_OK;
    }
}


sub set_default_rules_for_threads {
# 0. Do that
#    - after phase PHASE_REDUCE_THREADS (if assigned) because otherwise we offer too early too
#      many rules as target for simplification which than maybe leads to inability to reduce
#      the number of threads efficient.
#      Artificial example:
#      Start with $threads = 48, it is not a concurrency problem, phase PHASE_THREAD1_REPLAY is
#      not assigned or had just no luck
#      n simplifications lead to
#      - thread47 = <crashing SQL> and remaining thread*: SIMP_WAIT_EXIT_QUERY ;
#    - before PHASE_GRAMMAR_CLONE (if assigned) because there we try to simplify further like
#      Assume two threads assigned --> if replaying --> thread1: ddl;
#      query: ddl | dml ;                               thread2: dml;
# 1. Do that after
#    1.1 loading the grammar including redefines
#    1.2 filling rule_hash
# 2. Build fat grammar string
    my $grammar_string_addition = '';
    my $rule_name = "ill_rule";
    foreach my $number (1..$threads) {
        $rule_name = 'thread' . $number;
        if (not exists $rule_hash{$rule_name}) {
            my $sentence = '';
            if (exists $rule_hash{'query'}) {
                $sentence = "query";
            }
            if (exists $rule_hash{'thread'}) {
                if ('' eq $sentence) {
                    # Good grammar because "query" does not exist too.
                    $sentence = "thread";
                } else {
                    say("WARN: The grammar contains the rules 'query' and 'thread'. " .
                        "Will pick 'query' as component for '$rule_name'.");
                }
            }
            if ('' eq $sentence) {
                say("WARN: The grammar contains neither the rule 'query' nor 'thread'.");
                $sentence = SIMP_WAIT_EXIT_QUERY;
            }
            my $string_addition = $rule_name . ":\n" . "$component_indent" . $sentence . " ;";
            # Prevent   BOL <no white space><more than one white space>;EOL
            $string_addition =~ s{ +;$}{ ;}img;
            # Prevent wrong formatted last component if empty.
            $string_addition =~ s{^ +;$}{$component_indent ;}img;
            $grammar_string_addition .= "\n\n" . $string_addition;
        } else {
        }
        $rule_name = 'thread' . $number . '_init';
        if (not exists $rule_hash{$rule_name}) {
            my $sentence = '';
            if (exists $rule_hash{'query_init'}) {
                $sentence = "query_init";
            }
            if (exists $rule_hash{'thread_init'}) {
                if ('' eq $sentence) {
                    # Good grammar because "query" does not exist too.
                    $sentence = "thread_init";
                } else {
                    say("WARN: The grammar contains the rules 'query_init' and 'thread_init'. " .
                        "Will pick 'query_init'.");
                }
            }
            # Having no *_init must be allowed.
            my $string_addition = $rule_name . ":\n" . "$component_indent" . $sentence . " ;";
            # Prevent   BOL <no white space><more than one white space>;EOL
            $string_addition =~ s{ +;$}{ ;}img;
            # Prevent wrong formatted last component if empty.
            $string_addition =~ s{^ +;$}{$component_indent ;}img;
            $grammar_string_addition .= "\n\n" . $string_addition;
        } else {
            # say("DEBUG: rule : $rule_name does exist");
        }
        $rule_name = 'thread' . $number . '_connect';
        if (not exists $rule_hash{$rule_name}) {
            # say("DEBUG: rule : $rule_name does not exist");
            my $sentence = '';
            if (exists $rule_hash{'query_connect'}) {
                $sentence = "query_connect";
            }
            if (exists $rule_hash{'thread_connect'}) {
                if ('' eq $sentence) {
                    # Good grammar because "query" does not exist too.
                    $sentence = "thread_connect";
                } else {
                    say("WARN: The grammar contains the rules 'query_connect' and " .
                        "'thread_connect'. Will pick 'query_connect'.");
                }
            }
            # Having no *_init must be allowed.
            my $string_addition = $rule_name . ":\n" . "    " . $sentence . " ;";
            # Prevent   BOL <no white space><more than one white space>;EOL
            $string_addition =~ s{ +;$}{ ;}img;
            # Prevent wrong formatted last component if empty.
            $string_addition =~ s{^ +;$}{$component_indent ;}img;
            $grammar_string_addition .= "\n\n" . $string_addition;
        } else {
        }
    }
    my $grammar_string_extended = $grammar_obj->toString() . $grammar_string_addition ;
    say("DEBUG: Extended grammar ======================== BEGIN\n" .
        $grammar_string_extended . "\n" .
        "DEBUG: Extended grammar ======================== END") if $script_debug;
    $grammar_obj = GenTest_e::Grammar->new(
           'grammar_string'  => $grammar_string_extended,
           'grammar_flags'  => $grammar_flags
    );
    if (not defined $grammar_obj) {
        # Thinkable example: $grammar_string_addition contains garbage.
        say("ERROR: Filling the grammar_obj failed. Will return STATUS_INTERNAL_ERROR later.");
        say("ERROR: Extended grammar ======================== BEGIN" . "\n" .
            $grammar_string_extended                                 . "\n" .
            "ERROR: Extended grammar ======================== END");
        return STATUS_INTERNAL_ERROR;
    }
    # Replace some maybe filled %rule_hash by some new one.
    # --> There might be non reachable rules between!
    # --> This init sets RULE_JOBS_GENERATED to 0 !!!
    fill_rule_hash();
    # print_rule_hash();

    return STATUS_OK;

} # End sub set_default_rules_for_threads


sub analyze_all_rules {

# Purpose/Activity:
# 1. Actualize rule_hash
# 2. Delete unused rules
# Note:
# - RULE_WEIGHT will not get actualized!
# - RULE_JOB_GENERATED does not get touched
# - No inlining of rules
#
# Return a status and never exit.
#

    my $snip = "GenTest_e::Simplifier::Grammar::analyze_all_rules:";

    say("DEBUG: $snip Begin") if $script_debug;
    foreach my $rule_name (keys %rule_hash) {
        $rule_hash{$rule_name}->[RULE_IS_PROCESSED] = 0;
    }

    # Emptying %rule_hash and recreating the required keys is not necessary because the
    # number of rules shrinks during ONE "walk through the grammar round".
    # In case we repeat the loop than most entries need to get reset.
    # A reset of RULE_JOBS_GENERATED must be not done because we would probably
    # create duplicates of jobs being already in queues.
    reset_rule_hash_values();

    our $run_all_again = 1;
    while($run_all_again) {
        $run_all_again = 0;
        reset_rule_hash_values();

        if (STATUS_OK != grammar_rule_hash_consistency()) {
            say("ERROR: $snip grammar_rule_hash_consistency failed. " .
                "Will return STATUS_INTERNAL_ERROR.");
            return STATUS_INTERNAL_ERROR;
        }

        my @top_rule_list = $grammar_obj->top_rule_list();
        if ( 1 > scalar @top_rule_list ) {
            say("ERROR: $snip \@top_rule_list is empty. Will return STATUS_INTERNAL_ERROR.");
            return STATUS_INTERNAL_ERROR;
        }

        foreach my $i (1..$threads) {
            if (not exists $rule_hash{"thread" . $i}) {
                if      (exists $rule_hash{"query"}) {
                    $rule_hash{"query"}->[RULE_IS_TOP_LEVEL] = 1;
                    $rule_hash{"query"}->[RULE_REFERENCED]++;
                } elsif (exists $rule_hash{"thread"}) {
                    $rule_hash{"thread"}->[RULE_IS_TOP_LEVEL] = 1;
                    $rule_hash{"thread"}->[RULE_REFERENCED]++;
                } else {
                    say("WARN: top level rule for (query) thread" . "$i is missing");
                    exit(100);
                }
            } else {
                $rule_hash{"thread" . $i}->[RULE_IS_TOP_LEVEL] = 1;
                $rule_hash{"thread" . $i}->[RULE_REFERENCED]++;
            }
            if (not exists $rule_hash{"thread" . $i . "_init"}) {
                if      (exists $rule_hash{"query_init"}) {
                    $rule_hash{"query_init"}->[RULE_IS_TOP_LEVEL] = 1;
                    $rule_hash{"query_init"}->[RULE_REFERENCED]++;
                } elsif (exists $rule_hash{"thread_init"}) {
                    $rule_hash{"thread_init"}->[RULE_IS_TOP_LEVEL] = 1;
                    $rule_hash{"thread_init"}->[RULE_REFERENCED]++;
                } else {
                    say("WARN: top level rule for (init) thread" . "$i is missing");
                    exit(100);
                }
            } else {
                $rule_hash{"thread" . $i . "_init"}->[RULE_IS_TOP_LEVEL] = 1;
              # $rule_hash{"thread" . $i . "_init"}->[RULE_REFERENCED]++;
            }
            if (not exists $rule_hash{"thread" . $i . "_connect"}) {
                if      (exists $rule_hash{"query_connect"}) {
                    $rule_hash{"query_connect"}->[RULE_IS_TOP_LEVEL] = 1;
                    $rule_hash{"query_connect"}->[RULE_REFERENCED]++;
                } elsif (exists $rule_hash{"thread_connect"}) {
                    $rule_hash{"thread_connect"}->[RULE_IS_TOP_LEVEL] = 1;
                    $rule_hash{"thread_connect"}->[RULE_REFERENCED]++;
                } else {
                    say("WARN: top level rule for (connect) thread" . "$i is missing");
                    exit(100);
                }
            } else {
                $rule_hash{"thread" . $i . "_connect"}->[RULE_IS_TOP_LEVEL] = 1;
                $rule_hash{"thread" . $i . "_connect"}->[RULE_REFERENCED]++;
            }
        }


        my $more_to_process = 1;
        while ($more_to_process) {
            $more_to_process = 0;
            foreach my $rule_name (keys %rule_hash) {
                # say("DEBUG: 1 rule_name --> $rule_name");

                next if 1 == $rule_hash{$rule_name}->[RULE_IS_PROCESSED];
                if (0 == $rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL] and
                    0 == $rule_hash{$rule_name}->[RULE_REFERENCED]      ) {
                    next;
                }
                # say("DEBUG: 2 rule_name --> $rule_name");
                # Non processed potential top level rules need to get processed anyway because
                # we need for any rule to determine RULE_REFERENCED.
                # In case of non top level rules and RULE_REFERENCED == 0 we just do not know if
                # they will be used at all. So process the other rules first.

                my $rule_obj = $grammar_obj->rule($rule_name);
                $rule_hash{$rule_name}->[RULE_UNIQUE_COMPONENTS] =
                                         scalar $rule_obj->unique_components;
                if (1 > scalar $rule_obj->unique_components) {
                    say("INTERNAL ERROR: Rule '$rule_name' : 1 > number of unique components.");
                    return STATUS_INTERNAL_ERROR;
                }
                # say("DEBUG: 3 rule_name --> $rule_name components: " . scalar $rule_obj->unique_components);

                # Decompose the rule.
                my $components = $rule_obj->components();

                for (my $component_id = $#$components; $component_id >= 0; $component_id--) {

                    my $component = $components->[$component_id];

                    for (my $part_id = $#{$components->[$component_id]}; $part_id >= 0; $part_id--) {
                        my $component_part = $components->[$component_id]->[$part_id];
                        say("DEBUG: '$rule_name' part_id $part_id component_part " .
                            "->$component_part<-") if $script_debug;
                        if (exists $rule_hash{$component_part}) {
                            say("DEBUG: '$rule_name' part_id $part_id component_part " .
                                "->$component_part<- is a rule.") if $script_debug;
                            if ($component_part eq $rule_name) {
                                say("DEBUG: The rule 'rule_name' is recursive because a " .
                                    "component of it contains '$rule_name'.") if $script_debug;
                                $rule_hash{$rule_name}->[RULE_RECURSIVE] = 1;
                            } else {
                                $rule_hash{$rule_name}->[RULE_REFERENCING]++;
                                $rule_hash{$component_part}->[RULE_REFERENCED]++;
                                # So some rule with RULE_REFERENCED = 0 might have now 1.
                                # --> Therefore check all rules again.
                                $more_to_process = 1;
                            }
                        }
                    }
                }
                $rule_hash{$rule_name}->[RULE_IS_PROCESSED] = 1;
            }
        }
        # Now %rule_hash is precharged with values per rule.

        # Detect rules with the top level rule name patterns ('query', 'thread<n>_init', ...) which
        # - are used if ever as top level rule only --> Other rules do not reference them.
        #   --> RULE_REFERENCED == 0
        # and
        # - will be not used during statement generation because
        #   - thread<number>* and <number> bigger than number of threads assigned ($threads)
        #   or
        #   - we have thread<number><pattern> with <number> covering the full range 1..$threads
        # Suche rules well be deleted.
        # As consequence the already stored RULE_REFERENCED of other rules might become outdated
        # (too big) and we need to recompute and maybe delete more.
        # Hence whenever we have deleted a rule $run_all_again gets set to 1.

        # Remove unused thread<number>* rules.
        foreach my $rule_name (@top_rule_list) {
            my $val = extract_thread_from_rule_name($rule_name);
            if (not defined $threads) {
                Carp::cluck("threads is undef");
                return STATUS_INTERNAL_ERROR;
            }
            if ($threads < $val) {
                say("DEBUG: threads is $threads and therefore the rule '$rule_name' will be " .
                    "never used as toplevel rule.") if $script_debug;
                if(0 < $rule_hash{$rule_name}->[RULE_REFERENCED]) {
                    say("DEBUG: But the rule '$rule_name' is referenced by other rules. " .
                        "So we need to keep it.") if $script_debug;
                    $rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL] = 0;
                } else {
                    $grammar_obj->deleteRule($rule_name);
                    delete $rule_hash{$rule_name};
                    say("DEBUG: The rule '$rule_name' will be never used and was therefore " .
                        "deleted.") if $script_debug;
                    $run_all_again = 1;
                }
            }
        }

        sub alt_rules {
            my ($del_name_prefix, $alt_name_prefix, $name_suffix)= @_;
            my $del_rule_name = $del_name_prefix . $name_suffix;
            if (exists $rule_hash{$del_rule_name}) {
                # It exists
                my $is_top_level = 0;
                # As soon as we detect that a 'thread<number>' is missing for some thread the rule
                # 'query' needs to be used for it.
                foreach my $num (1..$threads) {
                    my $alt_rule_name = $alt_name_prefix . $num . $name_suffix;
                    if (not exists $rule_hash{$alt_rule_name}) {
                        $is_top_level = 1;
                        last;
                    }
                }
                if ($is_top_level) {
                    $rule_hash{$del_rule_name}->[RULE_IS_TOP_LEVEL] = 1;
                } else {
                    if (0 < $rule_hash{$del_rule_name}->[RULE_REFERENCED]) {
                        # We cannot delete the rule because its used by other rules.
                        $rule_hash{$del_rule_name}->[RULE_IS_TOP_LEVEL] = 0;
                    } else {
                        $grammar_obj->deleteRule($del_rule_name);
                        delete $rule_hash{$del_rule_name};
                        say("DEBUG: We have a 'thread<number>' for any thread. Rule " .
                            "'$del_rule_name' was therefore deleted.") if $script_debug;
                        $run_all_again = 1;
                    }
                }
            }
        }
        # 'query' versus 'thread13'
        alt_rules('query',  'thread', '');
        alt_rules('query',  'thread', '_init');
        alt_rules('query',  'thread', '_connect');
        alt_rules('thread', 'thread', '_connect');

        # Now take care of the remaining rules
        foreach my $rule_name (keys %rule_hash) {
            if (0 == $rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL] and
                0 == $rule_hash{$rule_name}->[RULE_REFERENCED]       ) {
                $grammar_obj->deleteRule($rule_name);
                delete $rule_hash{$rule_name};
                say("DEBUG: Rule '$rule_name' was unused and therefore deleted.") if $script_debug;
                $run_all_again = 1;
            }
        }

        say("DEBUG: Expect to run all again.") if ($run_all_again and $script_debug);
    }
    say("DEBUG: $snip End") if $script_debug;

    return STATUS_OK;

} # End sub analyze_all_rules


sub extract_thread_from_rule_name {
# This routine might be unused. Please keep for future use.

    my ($rule_name) = @_;

# Snip of testing code tried:
# Never never try exact here because we get something like endless recursion.
# $rule_name = 'thread99';
# say("$rule_name: " . GenTest_e::Simplifier::Grammar::extract_thread_from_rule_name($rule_name));
# -> get 99
# $rule_name = 'omo';
# say("$rule_name: " . GenTest_e::Simplifier::Grammar::extract_thread_from_rule_name($rule_name));
# -> Get error
# $rule_name = 'query';
# say("$rule_name: " . GenTest_e::Simplifier::Grammar::extract_thread_from_rule_name($rule_name));
# -> Get 0
# $rule_name = 'thread01_connect';
# say("$rule_name: " . GenTest_e::Simplifier::Grammar::extract_thread_from_rule_name($rule_name));
# -> Get error
# $rule_name = 'thread13_connect';
# say("$rule_name: " . GenTest_e::Simplifier::Grammar::extract_thread_from_rule_name($rule_name));
# -> Get 13
# $rule_name = 'thread01_init';
# say("$rule_name: " . GenTest_e::Simplifier::Grammar::extract_thread_from_rule_name($rule_name));
# -> Get error
# $rule_name = 'thread13_init';
# say("$rule_name: " . GenTest_e::Simplifier::Grammar::extract_thread_from_rule_name($rule_name));
# -> Get 13

    my $message_part = "DEBUG: extracted thread number from '$rule_name' returned:";
    if ($rule_name eq 'query'         or $rule_name eq 'query_init' or
        $rule_name eq 'query_connect' or $rule_name eq 'thread_connect' ) {
        say("$message_part 0") if $script_debug;
        return 0;
    };

    my $prefix = 'thread';
    foreach my $suffix ('_init', '_connect', '') {
        my $string = $rule_name;
        if ($string=~ s|^$prefix([1-9][0-9]*)$suffix$|$1|s) {
            say("$message_part $string") if $script_debug;
            return $string;
        } else {
            say("$message_part 0") if $script_debug;
        }
    }

    # FIXME: Return a status
    Carp::confess("INTERNAL ERROR: Unknown toplevel rule '$rule_name'.");
    say("ALARM we must never reach this line.");
} # End sub extract_thread_from_rule_name


# sub remove_unused_rules {
# Note: Its currently in the routine analyze_all_rules

# Difficult cases to handle right!
# Rules call top level rules like
# thread1:
#    ddl   |
#    query ;
#

# Purpose
# -------
# By removing no more needed grammar rules we prepare the grammar content for further manual
# processing the automatic simplifier is not capable. And having unused rules removed makes
# such grammars more handy.
#
# Note:
# We need more than run through the grammar.
# Example:
# rule_a uses rule_k and rule_n. rule_a is no more used. So remove rule_a first.
# In case it turns after that out that rule_k is no more used than remove that too etc.
#

# }


sub collapseComponents {
# Usage is in Grammar simplifier only. Therefore I hesitate to place that into
# lib/GenTest_e/Grammar/Rule.pm.
#
    my ($rule_name) = @_;
    my $snip = "GenTest_e::Simplifier::Grammar::collapseComponents for rule '$rule_name':";
    my $rule_obj    = $grammar_obj->rule($rule_name);
    if (not defined $rule_obj) {
        Carp::cluck("INTERNAL ERROR: Rule '$rule_name' : Undef rule object got.");
        return STATUS_INTERNAL_ERROR;
    }

    my $rule_before = $rule_obj->toString();
    my $rule_after  = $rule_obj->toString();

    # In case a rule consists of several equal elements only then collapse it to one element.
    # Example:
    #    rule_A: SELECT 13 | SELECT 13 ;   --> rule_A: SELECT 13 ;
    #
    my @unique_components = $rule_obj->unique_components();
    my $components        = $rule_obj->components();
    if ((1 <  scalar @$components) and
        (1 == scalar $rule_obj->unique_components())) {
        while (1 <  scalar @$components) {
            splice (@$components, 1);
        }
        say("DEBUG: $snip Number of unique components : 1 --> collapsing.") if $script_debug;
    }

    # In case we have more than one component and a component sentence is '' than DO NOT remove it.
    # Bad example:
    #    rule_A: | <fat component making a big runtime> ; --> rule_A:  <fat component> ;
    # Because what if <fat component> is not required for what we search at all?
    #

    $rule_after = $rule_obj->toString();
    if (($rule_after ne $rule_before) and $script_debug) {
        say("DEBUG: $snip Before collapsing: ->" . $rule_before . "<-");
        say("DEBUG: $snip After  collapsing: ->" . $rule_after  . "<-");
    }

    return STATUS_OK;

} # End sub collapseComponents


sub compact_grammar {

# Purpose
# -------
# Replace rules consisting of one component only (best non rare case: Its an empty string),
# by their content wherever they are used. Run remove_unused_rules after any of such operations.
# Advantage:
#    This makes grammars most time more handy.
# Minor disadvantage:
#    An inspection of the final grammar will no more show which rule was shrinked away.
#    Example:
#    - non compacted:  dml: ;
#    - compacted: There is no rule 'dml'. But only a comparison with the original grammar will
#                 show that a rule 'dml' (enlighting name) was shrinked away.
#    Well, you need to search for the keywords INSERT/UPDATE/REPLACE/DELETE through the complete
#    grammar in order to figure out what is gone.
# Medium disadvantage:
#    When doing manual simplification later some
#    rule:
#        <a very long sentence> ;
#    expanded into several components of other rules might be quite unconvenient.
#
# Important:
# 1. Any code change by compact_grammar might cause that counters in %rule_hash get outdated!
# 2. Inlining rules changes most probably components of other rules and that makes proposed
#    jobs invalid because the component_sentence of already processed rules gets modified.
#

    my ($max_inline_length) = @_;

    if (not defined $max_inline_length) {
        Carp::cluck("INTERNAL ERROR: max_inline_length is undef.");
        return STATUS_INTERNAL_ERROR;
    }

    foreach my $rule_name ( keys %{$grammar_obj->rules()} ) {
        # Simplify:
        # rule_A: SELECT 13 | SELECT 13 ; => rule_A: SELECT 13;
        if (STATUS_OK != collapseComponents($rule_name) ) {
            return STATUS_INTERNAL_ERROR;
        }
        # Important:
        # The number of rule components changes.
        # So if this number is stored in rule_hash than this value is now outdated.
    }

    my $debug_snip = "DEBUG: compact_grammar:";

    # Begin of inline attempts
    foreach my $rule_name ( sort keys %{$grammar_obj->rules()} ) {

        my $snip = $debug_snip . " Attempt to inline Rule '$rule_name'";

        if ($rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL]) {
            # Top level rules cannot be inlined. ????
            # thread1: ....;
            # thread2: thread1;
            #
            next;
        }

        my $rule_obj = $grammar_obj->rule($rule_name);
        if (not defined $rule_obj) {
            Carp::cluck("INTERNAL ERROR: Rule '$rule_name' : Undef rule object got.");
            return STATUS_INTERNAL_ERROR;
        }
        my $components = $rule_obj->components();

        # Rules with more than one component will not get inlined.
        # FIXME:
        # Inlining in case of
        # - "calling" rule has one component only
        # - rule is called only once
        # would be ok.
        # say("DEBUG: No of components in '$rule_name': " . scalar @$components);
        next if 1 < scalar @$components;

        # Fixme: Abort if having 0 components

        # We have one component in $rule_name.

        if (not defined $rule_obj->components->[0]) {
            Carp::cluck("INTERNAL ERROR: Rule '$rule_name': The first component is undef.");
            return STATUS_INTERNAL_ERROR;
        }
        my @the_component          = @{$rule_obj->components->[0]};
        my $the_component_sentence = join('', @the_component );
        say("$snip Component as Sentence ->$the_component_sentence<-") if $script_debug;

        if (length($the_component_sentence) > $max_inline_length) {
            say("$snip Omit inlining of rule $rule_name' because the component " .
                "->$the_component_sentence<- is too long.") if $script_debug;
            next;
        }

        # FIXME: Rework this. In the moment it is without value.
        if ($the_component_sentence =~ /^ *$/) {
            # Rule with one component == empty string is a candidate for inlining
        } elsif (1 == $rule_hash{$rule_name}->[RULE_REFERENCED]) {
            # The rule is only one time referenced.
        } else {
            # Never use "last" here.
        }

        say("$snip Candidate for inlining. ->" . $rule_obj->toString() . "<-")
            if $script_debug;

        # Check all rules if they have components containing $rule_name.
        foreach my $inspect_rule_name ( sort keys %{$grammar_obj->rules()} ) {

            # Recursive rules can be inlined into other rules which reference them.
            # But never inlined into themselve.
            next if $rule_name eq $inspect_rule_name;

            my $inspect_rule_obj = $grammar_obj->rule($inspect_rule_name);
            if (not defined $inspect_rule_obj) {
                Carp::cluck("INTERNAL ERROR: Rule '$inspect_rule_name' : Undef rule object got.");
                return STATUS_INTERNAL_ERROR;
            }
            my $inspect_components = $inspect_rule_obj->components();

            for (my $component_id = $#$inspect_components; $component_id >= 0; $component_id--) {

                my $component = $inspect_components->[$component_id];

                for (my $part_id = $#{$inspect_components->[$component_id]}; $part_id >= 0; $part_id--) {

                    my $component_part = $inspect_components->[$component_id]->[$part_id];
                    say("$snip: Inspect rule '$inspect_rule_name' CID $component_id, " .
                        "PID $part_id, ->$component_part<-") if $script_debug;

                    next if ($component_part ne $rule_name);

                    say("$snip Rule '$inspect_rule_name' before inline operation ->" .
                        $inspect_rule_obj->toString() . "<-") if $script_debug;
                    splice(@{$component}, $part_id, 1, @the_component );

                    say("$snip Rule '$inspect_rule_name' after inline operation ->" .
                        $inspect_rule_obj->toString() . "<-") if $script_debug;
                    # Important:
                    # The number of references to other rules might change.
                    # So if this number is stored in rule_hash than this value is now outdated.

                }
            }
        } # End of inlining
        $grammar_obj->deleteRule($rule_name);
        delete $rule_hash{$rule_name};
        say("$snip The content of the rule '$rule_name' was inlined and therefore the rule " .
            "was deleted.") if $script_debug;
    } # End of search for inline candidates and inlining

    if (STATUS_OK != grammar_rule_hash_consistency()) {
        say("ERROR: grammar_rule_hash_consistency failed. " .
            "Will return STATUS_INTERNAL_ERROR.");
        return STATUS_INTERNAL_ERROR;
    } else {
        return STATUS_OK;
    }

} # End of sub compact_grammar


sub calculate_weights {

# Purpose
# -------
# Calculate for any grammar rule a value which corresponds to the importance of that rule relative
# to the other rules. Just some ordering based on these values needs to be supported.
# During the simplification process rules are picked along descending order of these values and
# than its tried to remove components/alternatives from them.
# The per my experience in sum best solution (highest simplification speed but also most complex
# code) is the
# Precharge the top level rules with static values:
# - (simple): 'query' gets a 1, thread<n> a bit less and the *_connect and *_init less.
# - (sophisticated): Maybe the values dependend on the number of threads finally used.
# Having a value > 0 in some rule  means also that this rule is in use.
# Decompose the top level rule into its components, determine per component the rules which occur
# and charge than
#    top level rule value / no of components in top level rule
# into the rule. Mark the top level rule as processed. Sort the rules according to their weight,
# pick the rule with the highest value from the not yet processed rules and than decompose that
# and charge into the rules found.
# Recursive rules might require some tricks in order to avoid "overcharging".
#
# Rules like:
# rule_a : update | update ;
# should be no problem because we divide by number of components.
#
# Maybe have a fall back position like just charge a 1 into all rules.
#
# return a status
#

    sub inspect_rule_and_charge {
        my ($rule_name) = @_;

        my $rule_obj = $grammar_obj->rule($rule_name);

        # Decompose the rule.
        my $components = $rule_obj->components();

        my $component_count = scalar @{$components};
        if (1 > $component_count) {
            print_rule_hash();
            Carp::cluck("INTERNAL ERROR: Rule '$rule_name' component_count < 1 detected.");
            return STATUS_INTERNAL_ERROR;
        }

        my $charge_unit = $rule_hash{$rule_name}->[RULE_WEIGHT] / (scalar @{$components});

        for (my $component_id = $#$components; $component_id >= 0; $component_id--) {

            my $component = $components->[$component_id];

            for (my $part_id = $#{$components->[$component_id]}; $part_id >= 0; $part_id--) {
                my $component_part = $components->[$component_id]->[$part_id];
                if (exists $rule_hash{$component_part}) {
                    say("DEBUG: '$rule_name' part_id $part_id component_part ->$component_part<- " .
                        "is a rule.") if $script_debug;
                    if ($component_part eq $rule_name) {
                        # RECURSION, charge nothing
                        # FIXME: Is that reasonable?
                    } else {
                        $rule_hash{$component_part}->[RULE_WEIGHT] += $charge_unit;
                    }
                }
            }
        }
    }

    if (STATUS_OK != analyze_all_rules()) {
        Carp::cluck("ERROR: analyze_all_rules failed. Will return STATUS_INTERNAL_ERROR.");
        return STATUS_INTERNAL_ERROR;
    }

    foreach my $rule_name (keys %rule_hash) {
        $rule_hash{$rule_name}->[RULE_IS_PROCESSED] = 0;
    }

    # Precharge all existing rules which are
    # - used as top level rules ( 1 == $rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL] )
    # - not thread specific (thread<number>* is thread_specific)
    # Note:
    # We "overcharge" temporary 'query*' in case some corresponding 'thread<number>' exists.
    my $rule_name = 'query';
    if(exists $rule_hash{$rule_name} and 1 == $rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL]) {
        say("DEBUG: calculate_weights : Process now rule '$rule_name', weight : " .
            $rule_hash{$rule_name}->[RULE_WEIGHT]) if $script_debug;
        $rule_hash{$rule_name}->[RULE_WEIGHT] = 1;
        say("DEBUG: calculate_weights : rule '$rule_name', weight is now : " .
            $rule_hash{$rule_name}->[RULE_WEIGHT]) if $script_debug;
    }
    $rule_name = 'query_init';
    # Only once per RQG run.
    # The number of queries which will be finally executed does not need to be the value of
    # queries assigned to the RQG run. An addition the latter value is not available here.
    # Its also unknown if the query_init content is unexpected important or not.
    # So the factor 1 / 100000 is just a guess.
    if(exists $rule_hash{$rule_name} and 1 == $rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL]) {
        say("DEBUG: calculate_weights : Process now rule '$rule_name', weight : " .
            $rule_hash{$rule_name}->[RULE_WEIGHT]) if $script_debug;
        $rule_hash{$rule_name}->[RULE_WEIGHT] = 1 / 100000;
        say("DEBUG: calculate_weights : rule '$rule_name', weight is now : " .
            $rule_hash{$rule_name}->[RULE_WEIGHT]) if $script_debug;
    }
    $rule_name = 'query_connect';
    # There might be several connects/disconnect per RQG run and thread.
    # But number of reconnects which will be finally executed is unknown.
    # So the factor 1 / 1000 is just a guess.
    if(exists $rule_hash{$rule_name} and 1 == $rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL]) {
        say("DEBUG: calculate_weights : Process now rule '$rule_name', weight : " .
            $rule_hash{$rule_name}->[RULE_WEIGHT]) if $script_debug;
        $rule_hash{$rule_name}->[RULE_WEIGHT] = 1 / 1000;
        say("DEBUG: calculate_weights : rule '$rule_name', weight is now : " .
            $rule_hash{$rule_name}->[RULE_WEIGHT]) if $script_debug;
    }
    $rule_name = 'thread_connect';
    # 'thread_connect' is a synonym of 'query_connect'.
    if(exists $rule_hash{$rule_name} and 1 == $rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL]) {
        say("DEBUG: calculate_weights : Process now rule '$rule_name', weight : " .
            $rule_hash{$rule_name}->[RULE_WEIGHT]) if $script_debug;
        $rule_hash{$rule_name}->[RULE_WEIGHT] = 1 / 1000;
        say("DEBUG: calculate_weights : rule '$rule_name', weight is now : " .
            $rule_hash{$rule_name}->[RULE_WEIGHT]) if $script_debug;
    }
    # Precharge all existing rules which are
    # - used as top level rules ( 1 == $rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL] )
    # - thread specific (thread<number>* is thread_specific)
    # including applying a factor 1 / $threads.
    # Revert after that the previous "overcharge" of 'query*' rules.
    my @top_rule_list = $grammar_obj->top_rule_list();
    foreach my $rule_name (@top_rule_list) {
        # Lets assume the rule is 'thread13'.
        next if 0 == $rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL];
        # 'thread13' is used as top level rule. $threads must be >= 13.
        if ( $rule_name =~ m{^thread[1-9][0-9]*$} ) {
            # 'thread13' is just the RQG thread 13 specific variant ('query' would be unspecific)
            # of the rule used for generating the mass of queries.
            say("DEBUG: calculate_weights : Process now rule '$rule_name', weight : " .
                $rule_hash{$rule_name}->[RULE_WEIGHT]) if $script_debug;
            $rule_hash{$rule_name}->[RULE_WEIGHT] = 1 / $threads;
            say("DEBUG: calculate_weights : rule '$rule_name', weight is now : " .
                $rule_hash{$rule_name}->[RULE_WEIGHT]) if $script_debug;
            if(exists $rule_hash{'query'} and 1 == $rule_hash{'query'}->[RULE_IS_TOP_LEVEL]) {
                # 'query' exists and is used as top level rule.
                # Hence we have "overcharged" 'query' above and now we revert that.
                $rule_hash{'query'}->[RULE_WEIGHT] -= $rule_hash{$rule_name}->[RULE_WEIGHT];
            }
        }
        if ( $rule_name =~ m{^thread[1-9][0-9]*_init$} ) {
            say("DEBUG: calculate_weights : Process now rule '$rule_name', weight : " .
                $rule_hash{$rule_name}->[RULE_WEIGHT]) if $script_debug;
            $rule_hash{$rule_name}->[RULE_WEIGHT] = 1 / 100000 / $threads;
            say("DEBUG: calculate_weights : rule '$rule_name', weight is now : " .
                $rule_hash{$rule_name}->[RULE_WEIGHT]) if $script_debug;
            if(exists $rule_hash{'query_init'} and 1 == $rule_hash{'query_init'}->[RULE_IS_TOP_LEVEL]) {
                $rule_hash{'query_init'}->[RULE_WEIGHT] -= $rule_hash{$rule_name}->[RULE_WEIGHT];
            }
        }
        if ( $rule_name =~ m{^thread[1-9][0-9]*_connect$} ) {
            say("DEBUG: calculate_weights : Process now rule '$rule_name', weight : " .
                $rule_hash{$rule_name}->[RULE_WEIGHT]) if $script_debug;
            $rule_hash{$rule_name}->[RULE_WEIGHT] = 1 / 10000 / $threads;
            if(exists $rule_hash{'query_connect'} and 1 == $rule_hash{'query_connect'}->[RULE_IS_TOP_LEVEL]) {
                $rule_hash{'query_connect'}->[RULE_WEIGHT] -= $rule_hash{$rule_name}->[RULE_WEIGHT];
            }
            if(exists $rule_hash{'thread_connect'} and 1 == $rule_hash{'thread_connect'}->[RULE_IS_TOP_LEVEL]) {
                $rule_hash{'thread_connect'}->[RULE_WEIGHT] -= $rule_hash{$rule_name}->[RULE_WEIGHT];
            }
        }
    }

    # Now all potential top level rules (name pattern) which really act as top level rules are
    # hopefully reasonable precharged.

    $rule_name = next_rule_to_process(RULE_IS_PROCESSED, RULE_WEIGHT);
    while (defined $rule_name) {
        say("DEBUG: calculate_weights : Process now rule '$rule_name', (precharged) weight : " .
            $rule_hash{$rule_name}->[RULE_WEIGHT]) if $script_debug;
        inspect_rule_and_charge($rule_name);
        $rule_hash{$rule_name}->[RULE_IS_PROCESSED] = 1;
        $rule_name = next_rule_to_process(RULE_IS_PROCESSED,RULE_WEIGHT);
    }

    foreach my $rule_name (keys %rule_hash) {
        $rule_hash{$rule_name}->[RULE_IS_PROCESSED] = 0;
    }

    say("DEBUG: calculate_weights processing round is over. Will return STATUS_OK.") if $script_debug;
    return STATUS_OK;

} # End of sub calculate_weights


sub next_rule_to_process {

# Purpose
# -------
# Return the first rule from the group of not yet processed rules sortet
#    weight descending, rule_name ascending
# for further processing.

    my ($bool_field, $desc_sort_field) = @_;

    # $bool_field      == RULE_IS_PROCESSED or RULE_JOBS_GENERATED from rule_hash
    # $desc_sort_field == RULE_WEIGHT or similar (element of rule_hash record) or
    #                     undef ==> We just take the rules in alphabetical order.

    say("DEBUG: bool_field : $bool_field, desc_sort_field : $desc_sort_field") if $script_debug;
    my $best_rule_name   = undef;
    my $best_rule_weight = undef;
    foreach my $rule_name (sort keys(%rule_hash)) {
        next if 1 == $rule_hash{$rule_name}->[$bool_field];
        # because that rule was already treated in the current whatever round.

        my $rule_weight = $rule_hash{$rule_name}->[$desc_sort_field];
        if ((not defined $best_rule_name) or
            (defined $best_rule_name and $best_rule_weight < $rule_weight)) {
            $best_rule_name   = $rule_name;
            $best_rule_weight = $rule_weight;
        } else {
            # What we already have is better.
        }
    }

    if (not defined $best_rule_name) {
        say("DEBUG: next_rule_to_process : No rule found. Will return undef.") if $script_debug;
    } else {
        say("DEBUG: next_rule_to_process : Will return rule '$best_rule_name'.") if $script_debug;
    }
    return $best_rule_name;

} # End sub next_rule_to_process


sub set_rule_jobs_generated {
    my ($rule_name) = @_;
    if (not defined $rule_name) {
        Carp::Confess("INTERNAL ERROR: rule_name is undef");
    }
    if (not exists $rule_hash{$rule_name}) {
        Carp::Confess("INTERNAL ERROR: rule_name '$rule_name' does not exist in rule_hash");
    }
    $rule_hash{$rule_name}->[RULE_JOBS_GENERATED] = 1;
}


sub rule_exists {
# Return
# undef -- INTERNAL ERROR , stop everything + cleanup is recommended
#     1 -- The rule $rule_name exists/is in use in the current parent grammar.
#     0 -- The rule $rule_name does not exist in the current parent grammar.
#
    my ($rule_name) = @_;
    if (@_ != 1) {
        Carp::cluck("INTERNAL ERROR: 1 Parameter (rule_name) is required.  Will return undef.");
        return undef;
    }

    if (not defined $rule_name) {
        Carp::cluck("INTERNAL ERROR: rule_name is undef. Will return undef.");
        return undef;
    }

    if (exists $rule_hash{$rule_name}) {
        return 1;
    } else {
        return 0;
    }
}


sub shrink_grammar {

# Return
# - undef if the rule $rule_name (combine with or)
#   - does (no more) exist
#   - exists but has one !unique! component only.
#     FIXME: Does this work well in destructive simplification mode too?
#   - exists but has no more a component leading to $component_string.
#   - exists has more than one !unique! component and one leads to $component_string
#     but the final grammar contains less DROP/TRUNCATE/DELETE than the parent
#     and $dtd_protection == 1
# - the shrinked ($component_string removed from rule $rule_name) grammar as string.
#   The caller just wants to append that string afterwards to the current parent grammar.
#

    my ($rule_name, $component_string, $dtd_protection) = @_;

    # INTERNAL ERROR in case a parameter is undef.
    # Carp::confess is rude and ongoing RQG runs will be not stopped.
    # But that should be ok and after extreme short time fixed nearly for ever.
    # Alternative: Carp::cluck + return $status, $rule_string
    if (not defined $rule_name) {
        Carp::confess("INTERNAL ERROR: parameter rule_name is undef.");
    }
    if (not defined $component_string) {
        Carp::confess("INTERNAL ERROR: parameter component_string is undef.");
    }
    if (not defined $dtd_protection) {
        Carp::confess("INTERNAL ERROR: parameter dtd_protection is undef.");
    }

    say("DEBUG: shrink_grammar: rule_name '$rule_name', component_string ->$component_string<-, " .
        "dtd_protection : $dtd_protection") if $script_debug;

    if (not exists $rule_hash{$rule_name}) {
        say("DEBUG: shrink_grammar: The rule '$rule_name' does no more exist.") if $script_debug;
        return undef;
    }

    my @reduced_components;
    my $rule_obj          = $grammar_obj->rule($rule_name);
    my @unique_components = $rule_obj->unique_components();

    my $reduced_rule_string;
    if ('_to_empty_string_only' ne $component_string) {
        #### Non destructive simplification ####

        if (1 == scalar @unique_components) {
            say("DEBUG: shrink_grammar: The rule '$rule_name' has already only one unique " .
                "component.") if $script_debug;
            return undef;
        } else {
            # Nothing to do.
        }

        my $not_found = 1;
        foreach my $existing_component_string ( $rule_obj->unique_components()) {
            if ($component_string eq $existing_component_string) {
                $not_found = 0;
                last;
            }
        }
        if($not_found) {
            say("DEBUG: shrink_grammar: The rule '$rule_name' is no more containing the " .
                "component_string ->$component_string<-") if $script_debug;
            return undef;
        }

        # Avoid simple recursion
        # ----------------------
        # What would happen in case we do not avoid such an evil simplification?
        # a) In the most likely case lib/GenTest_e/Generator/FromGrammar.pm detects during RQG
        #    runtime recursion than it returns undef --> STATUS_ENVIRONMENT_FAILURE.
        #    A simplifier with good setup
        #        unwanted_patterns contain 'Possible endless loop in grammar.'
        #    will than judge ... and not use that grammar.
        #    Overall loss:
        #    The efforts for one or maybe a few (more than one simplify campaign) RQG runs.
        # b) Other case (hit in several simplifier runs)
        #    - very unlikely with many threads using that rule or the rule is rare used
        #    - unlikely but nevertheless too often with especially threads = 1
        #    the grammar replays before recursion was detected at all.
        #    And than quite likely the simplifier will take this grammar as base.
        #    Overall loss:
        #    The efforts for many RQG runs ending with STATUS_ENVIRONMENT_FAILURE because of
        #    recursion. And finally we end up most likely with some grammar which is capable
        #    to replay but needs many attempts.
        # Example grammar
        # query:
        #    SELECT recursive_rule ;
        # recursive_rule:
        #     13                   | <-- harmless
        #     13, recursive_rule   | <-- is dangerous if only dangerous are left over
        #     recursive_rule , 13  | <-- is dangerous if only dangerous are left over
        #     13, Arecursive_rule  | <-- harmless
        #     Arecursive_rule , 13 | <-- harmless
        #     13, recursive_ruleA  | <-- harmless
        #     recursive_ruleA , 13 ; <-- harmless
        my $is_safe = 0;
        foreach my $existing_component_string ( $rule_obj->unique_components()) {
            if ($component_string ne $existing_component_string) {
                # Its not the component/alternative which we are going to remove.
                # == This component will survive and so its content matters.
                my $l_existing_component_string = " " . $existing_component_string . " ";
                my $l_rule_name                 = " " . $rule_name . " ";
                if (not $l_existing_component_string =~ /$l_rule_name/) {
                    $is_safe = 1;
                  # say("DEBUG: IS SAFE $rule_name Inspecting ->$existing_component_string<-");
                    last;
                } else {
                  # say("DEBUG: IS NOT SAFE $rule_name Inspecting ->$existing_component_string<-");
                }
            }
        }
        if (not $is_safe) {
            say("DEBUG: shrink_grammar: Omit rule '$rule_name' because fearing recursion.")
                if $script_debug;
            return undef;
        }

        # All above was tested.
        # So we can at least think about removing that component_string.
        # The rule exists, it contains $component_string and there are more than one unique components.

        my $components = $rule_obj->components();
        foreach my $component (@$components) {
            my $existing_component_string = join('', @$component);
            say("DEBUG: existing_component_string ->$existing_component_string<-") if $script_debug;
            if ($existing_component_string ne $component_string) {
                push @reduced_components, $existing_component_string;
            }
        }
    } else {
        #### Destructive simplification ####
        #
        # Observation mid of 2019
        # -----------------------
        #    One RQG runner only, 32 threads, Notebook i7, 4 Cores, HT = 2 --> OS: 8 CPUs
        #    query:     ==> Generate a thread<n>: ; for every thread.
        #        ;
        # I get temporary 100% CPU load because its a frequent used top level rule.
        # The other *_connect and *_init are top level too but rather rare used.
        #
        if (     (1 == $rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL])
             and (not $rule_name =~ /_init$/)
             and (not $rule_name =~ /_connect$/)) {

            if (1 == scalar @unique_components) {
                my $existing_component_string = shift @unique_components;
                if ($existing_component_string eq SIMP_WAIT_EXIT_QUERY or
                    $existing_component_string eq SIMP_EXIT_QUERY) {
                    say("DEBUG: shrink_grammar: The rule '$rule_name' has already only one unique " .
                        "component and its ->$existing_component_string<-.") if $script_debug;
                    return undef;
                }
            }
            say("DEBUG: shrink_grammar: Trying to replace the content of rule '$rule_name' by '" .
                SIMP_WAIT_EXIT_QUERY . "'.") if $script_debug;
            @reduced_components = ( SIMP_WAIT_EXIT_QUERY );
        } else {
            if (1 == scalar @unique_components) {
                my $existing_component_string = shift @unique_components;
                if ($existing_component_string eq SIMP_EMPTY_QUERY     or
                    $existing_component_string eq SIMP_WAIT_EXIT_QUERY or
                    $existing_component_string eq SIMP_EXIT_QUERY)        {
                    say("DEBUG: shrink_grammar: The rule '$rule_name' has already only one unique " .
                        "component and its ->$existing_component_string<-.") if $script_debug;
                    return undef;
                }
            }
            say("DEBUG: shrink_grammar: Trying to replace the content of rule '$rule_name' by '" .
                SIMP_EMPTY_QUERY . "'.") if $script_debug;
            @reduced_components = ( SIMP_EMPTY_QUERY );
        }

    }

    # We need a white space before the ';' in order to prevent last lines of a rule
    # like "    other_rule;"
    $reduced_rule_string = "$rule_name:\n$component_indent" .
                           join(" |\n$component_indent", @reduced_components) . ' ;';
    # Prevent   BOL <no white space><more than one white space>;EOL
    $reduced_rule_string =~ s{ +;$}{ ;}img;
    $reduced_rule_string =~ s{^ +;$}{$component_indent ;}img;
    # Prevent wrong formatted last component if empty.
    # $string =~ s{^ +;$}{$component_indent ;}img;
    $reduced_rule_string =~ s{ +\|}{ \|}img;
    $reduced_rule_string =~ s{^ *\|}{$component_indent \|}img;

    if ($reduced_rule_string eq $rule_obj->toString()) {
        # Known special case:
        # The last campaign had success and we have caused by that or another campaign
        # <top_level_rule>:
        # <component_indent> ;
        # In the current campaign '_to_empty_string_only' was proposed for that <top_level_rule>.
        # In case we do not return undef than we get a valueless RQG run harvesting success and
        # therefore some next campaign --> ~ "endless".
        say("DEBUG: shrink_grammar: The rule '$rule_name' cannot be shrinked by applying " .
            "component_string ->$component_string<-") if $script_debug;
        return undef;
    }

    say("DEBUG: Original rule ->" . $rule_obj->toString() . "<-") if $script_debug;
    say("DEBUG: Reduced  rule ->" . $reduced_rule_string  . "<-") if $script_debug;

    return $reduced_rule_string;

} # End of sub shrink_grammar


my $clone_number = 0;
my $clone_limit = 100;
sub use_clones_in_rule {
#
# Return values
# undef --> Failure (recommendation for Simplifier is abort)
#
    my ($rule_name) = @_;
    say("DEBUG: use_clones_in_rule('$rule_name') begin") if $script_debug;
    my $rule_obj = $grammar_obj->rule($rule_name);
    $rule_hash{$rule_name}->[RULE_UNIQUE_COMPONENTS] = scalar $rule_obj->unique_components;

    # Decompose the rule.
    my $components = $rule_obj->components();

    for (my $component_id = $#$components; $component_id >= 0; $component_id--) {

        my $component = $components->[$component_id];

        for (my $part_id = $#{$components->[$component_id]}; $part_id >= 0; $part_id--) {
            my $component_part = $components->[$component_id]->[$part_id];
            say("DEBUG: '$rule_name' part_id $part_id component_part ->$component_part<-")
                if $script_debug;
            if (exists $rule_hash{$component_part}) {
                say("DEBUG: '$rule_name' part_id $part_id component_part ->$component_part<- " .
                    "is a rule.") if $script_debug;
                if ($component_part eq $rule_name) {
                    say("DEBUG: The rule 'rule_name' is recursive because a component of it " .
                        "contains '$rule_name'.") if $script_debug;
                    next;
                } else {
                    # FIXME if relevant and sufficient paining:
                    # rule1: dml | dml | ddl ; --> rule1: clone1 | clone2 | ddl ;
                    #                                     ############### is non sense
                    # rule2: dml | abc ;       --> rule2: clone3 | abc ;
                    #
                    if ($rule_hash{$component_part}->[RULE_REFERENCED] > 1 and
                        $rule_hash{$component_part}->[RULE_UNIQUE_COMPONENTS] > 1) {
                        my $clone_name = "__clone__" . ++$clone_number;
                        $components->[$component_id]->[$part_id] = $clone_name;
                        GenTest_e::Grammar::cloneRule($grammar_obj, $component_part, $clone_name);
                        add_rule_to_hash($clone_name);
                        say("DEBUG: use_clones_in_rule for '$rule_name': Rule '$component_part' " .
                            "cloned to '$clone_name'") if $script_debug;
                    } else {
                        # Non sense would be to clone
                        # - an only once used rule (technically just a rename)
                        # - a rule with one component/alternative only.
                        # Even if a rule which has one component only and this component uses
                        # several rules cloning makes no sense. Only inlining might be reasonable.
                    }
                }
            }
        }
    }
    say("DEBUG: use_clones_in_rule('$rule_name') end") if $script_debug;

} # End of sub use_clones_in_rule


sub use_clones_in_grammar_top {
# We just make the cloning along the top level rules.
# In order to avoid multiple processing of rules we mark processed rules by setting
# RULE_JOBS_GENERATED. This field will be not touched when resetting rule_hash.
#
# In case of error return undef.
#

    if (STATUS_OK != set_default_rules_for_threads()) {
        say("INTERNAL ERROR: set_default_rules_for_threads failed. Will return undef.");
        return undef;
    }

    my $clone_start = $clone_number;

    say("DEBUG: use_clones_in_grammar_top begin") if $script_debug;
    my @top_rule_list = $grammar_obj->top_rule_list();
    if (0 == scalar @top_rule_list) {
        Carp::cluck("ERROR: \@top_rule_list is empty. Will return undef.");
        return undef;
    }
    say("DEBUG: top_rule_list found : " . join(" ", @top_rule_list)) if $script_debug;
    foreach my $rule_name (@top_rule_list) {
        if (   $rule_name eq 'query'
            or $rule_name eq 'thread'
            or $rule_name eq 'query_init'
            or $rule_name eq 'thread_init'
            or $rule_name eq 'query_connect'
            or $rule_name eq 'thread_connect' ) {
            next;
        } else {
            use_clones_in_rule($rule_name);
            #    print_rule_hash();
            # Update RULE_REFERENCED and RULE_UNIQUE_COMPONENTS.
            if (STATUS_OK != analyze_all_rules()) {
                Carp::cluck("ERROR: analyze_all_rules failed. Will return undef.");
                return undef;
            }

            # Never call compact_grammar(...) here because it will bring the grammar (grammar_obj)
            # and rule_hash out of sync. And than the consistency check will abort simplification.
            #    print_rule_hash();
            # "calculate_weight" will update RULE_WEIGHT of all rules.
            # This is not required here because we work along @top_rule_list which is static.
            # calculate_weights();
            #    print_rule_hash();
            # Caused by the nature of @top_rule_list we have no risk to process some rule again.
            # $rule_hash{$rule_name}->[RULE_JOBS_GENERATED] = 1;
        }
        if ($clone_number - $clone_start >= $clone_limit) {
            say("DEBUG: clone_limit reached");
            last;
        }
    }

    # Most probably not required but very useful if forgotten later.
    foreach my $rule_name (keys %rule_hash) {
        $rule_hash{$rule_name}->[RULE_IS_PROCESSED] = 0;
    }
    say("DEBUG: use_clones_in_grammar_top end") if $script_debug;
    return $grammar_obj->toString();

} # End of sub use_clones_in_grammar_top


sub use_clones_in_grammar {

# FIXME:
# Add checks for mistakes and test
# Concept:
# We just make the cloning along the queue of rules ordered (dynamic during work) according
# decreasing RULE_WEIGHT. In order to avoid multiple processing of rules we mark processed
# rules by setting RULE_JOBS_GENERATED. This field will be not touched when resetting rule_hash.
#
# return undef in case of failure
#

    # my $clone_limit = 100;
    my $clone_start = $clone_number;

    # Without all RULE_IS_PROCESSED values set to 0 the operation will omit touching certain rules.
    foreach my $rule_name (keys %rule_hash) {
        $rule_hash{$rule_name}->[RULE_IS_PROCESSED] = 0;
    }
    if (STATUS_OK != calculate_weights()) {
        Carp::cluck("ERROR: calculate_weights failed. Will return undef.");
        return undef;
    }
    my $rule_name = next_rule_to_process(RULE_JOBS_GENERATED, RULE_WEIGHT);
    # What if undef (== INTERNAL ERROR) ?
    while (defined $rule_name) {
        #   print_rule_hash();
        use_clones_in_rule($rule_name);
        #   print_rule_hash();
        # Update RULE_REFERENCED and RULE_UNIQUE_COMPONENTS.
        if (STATUS_OK != analyze_all_rules()) {
            Carp::cluck("ERROR: analyze_all_rules failed. Will return undef.");
            return undef;
        }
        # Never call compact_grammar(...) here because it will bring the grammar (grammar_obj)
        # and rule_hash out of sync. And than the consistency check will abort simplification.
        #   print_rule_hash();
        # "calculate_weight" will update RULE_WEIGHT of all rules.
        # This is not strict required but it will cause that "next_rule_to_process" provides on
        # the next call the most important (RULE_WEIGHT) non processed rule.
        if (STATUS_OK != calculate_weights()) {
            Carp::cluck("ERROR: calculate_weights failed. Will return undef.");
            return undef;
        }
        #   print_rule_hash();
        # Prevent that we inspect/process the current rule again.
        $rule_hash{$rule_name}->[RULE_JOBS_GENERATED] = 1;
        if ($clone_number - $clone_start >= $clone_limit) {
            say("DEBUG: clone_limit reached");
            last;
        }
        $rule_name = next_rule_to_process(RULE_JOBS_GENERATED, RULE_WEIGHT);
    }
    # Most probably not required but very useful if forgotten later.
    foreach my $rule_name (keys %rule_hash) {
        $rule_hash{$rule_name}->[RULE_IS_PROCESSED] = 0;
    }
    return $grammar_obj->toString();

} # End sub use_clones_in_grammar

1;