# Copyright (C) 2018, 2019 MariaDB Corporation Ab.
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

package GenTest::Simplifier::Grammar_advanced;

require Exporter;
@ISA = qw(GenTest);

# Note:
# Its currently unclear if routines managing the simplification process
# need acces to all these constants.
# Main reason for having them exported:
# GenTest::Simplifier::Grammar_advanced::<constant> is quite long.
@EXPORT = qw(
    RULE_WEIGHT
    RULE_RECURSIVE
    RULE_REFERENCING
    RULE_REFERENCED
    RULE_JOBS_GENERATED
    RULE_IS_PROCESSED
    RULE_UNIQUE_COMPONENTS
    RULE_IS_TOP_LEVEL
);

use strict;
use Carp;
use lib 'lib';

use GenTest;
use GenTest::Constants;
use GenTest::Grammar;
use GenTest::Grammar::Rule;

my $script_debug = 0;

# sub fill_rule_hash();
# sub print_rule_hash();
# sub analyze_all_rules();

# Constants mayne used in future.
use constant SIMP_GRAMMAR_OBJ     => 0;
use constant SIMP_RULE_HASH       => 1;
use constant SIMP_GRAMMAR_FLAGS   => 2; # Unclear if that will persist
use constant SIMP_THREADS         => 3; # Unclear if that will persist

my $grammar_obj;
my %rule_hash;

my ($threads, $grammar_flags);

sub init {
    (my $grammar_file, $threads, my $max_inline_length, $grammar_flags) = @_;

    Carp::cluck("DEBUG: Grammar_advanced::init (grammar_file, threads, max_inline_length, " .
                "grammar_flags) entered") if $script_debug;

    if (not defined $max_inline_length) {
        Carp::cluck("INTERNAL ERROR: max_inline_length is not defined. Will return undef.");
        return undef;
    }
    if (not defined $threads) {
        Carp::cluck("INTERNAL ERROR: threads is not defined. Will return undef.");
        return undef;
    }

    my $status = load_grammar($grammar_file);
    if (STATUS_OK != $status) {
        return undef;
    }
    # Replace some maybe filled %rule_hash by some new one.
    # --> There might be non reachable rules between!
    # --> This init sets RULE_JOBS_GENERATED to 0 !!!
    fill_rule_hash();
    # print_rule_hash();
    analyze_all_rules();
    print_rule_hash() if $script_debug;
    # Inline anything which has a length <= $max_inline_length.
    compact_grammar($max_inline_length);
    if (not defined $grammar_obj) {
        Carp::confess("grammar_obj is not defined");
    }
    return $grammar_obj->toString();

}

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

    Carp::cluck("DEBUG: Grammar_advanced::reload_grammar (grammar_file, $threads, $grammar_flags)" .
                " entered") if $script_debug;

    if (not defined $threads) {
        say("INTERNAL ERROR: threads is not defined. Will return undef.");
        return undef;
    }
    my $status = load_grammar($grammar_file);
    if (STATUS_OK != $status) {
        return undef;
    }
    reset_rule_hash_values(); # This resets most rule_hash values belonging to a rule
                              # except RULE_JOBS_GENERATED.
    # print_rule_hash();
    analyze_all_rules();
    print_rule_hash() if $script_debug;
    # Do not inline anything because we are inside a grammar simplification campaign.
    my $max_inline_length = -1;
    compact_grammar($max_inline_length);
    if (not defined $grammar_obj) {
        Carp::confess("grammar_obj is not defined");
    }
    return $grammar_obj->toString();

}

sub get_unique_component_list {
# lib/GenTest/Grammar/Rule.pm routine unique_components with code example.
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


# our $grammar_obj;

sub load_grammar {

    my ($grammar_file)= @_;
    my @grammar_files;
    $grammar_files[0] = $grammar_file;

    $grammar_obj = GenTest::Grammar->new(
           'grammar_files'  => \@grammar_files,
           'grammar_flags'  => $grammar_flags
    );
    if (not defined $grammar_obj) {
        # Example: Open the grammar file failed.
        say("ERROR: Filling the grammar_obj failed. Will return undef");
        return STATUS_ENVIRONMENT_FAILURE;
    }
    return STATUS_OK;
}


# our %rule_hash;
# Key is rule_name
#
# Please see the amount of variables as experimental.
# - some might be finally superfluous completely because than maybe functions deliver exact data on
#   the fly and are better than the error prone maintenance
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
# could be used for such a purpose. But if will be later really used for that depends on
# the number of threads assigned.
# Example with $threads=3:
#    A rule 'thread4' will never act for some thread as top level rule.
#    But it could be used in components of other rules.
#    Example: thread2: thread4 | ddl ;
use constant RULE_IS_TOP_LEVEL           => 7;
#


sub print_rule_info {

    my ($rule_name) = @_;

    # GenTest::Simplifier::Grammar_advanced::print_rule_info();
    #   == Nothing assigned --> Error like undef assigned.
    # GenTest::Simplifier::Grammar_advanced::print_rule_info(undef);
    # GenTest::Simplifier::Grammar_advanced::print_rule_info('inknown');
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
    foreach my $rule_name (keys %rule_hash ) {
        say("---------------------");
        print_rule_info ($rule_name);
    }
    say("DEBUG: Print of rule_hash content ========== end")
}

sub fill_rule_hash {
    undef %rule_hash;
    foreach my $rule_name ( keys %{$grammar_obj->rules()} ) {
        $rule_hash{$rule_name}->[RULE_WEIGHT]            =      0;
        $rule_hash{$rule_name}->[RULE_RECURSIVE]         =      0;
        $rule_hash{$rule_name}->[RULE_REFERENCING]       =      0;
        $rule_hash{$rule_name}->[RULE_REFERENCED]        =      0;
        $rule_hash{$rule_name}->[RULE_JOBS_GENERATED]    =      0;
        $rule_hash{$rule_name}->[RULE_IS_PROCESSED]      =      0;
        $rule_hash{$rule_name}->[RULE_UNIQUE_COMPONENTS] =      0;
        $rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL]      =      0;
        say("DEBUG: fill_rule_hash : rule '$rule_name' added.") if $script_debug;
    }
}

sub reset_rule_hash_values {
    foreach my $rule_name ( keys %{$grammar_obj->rules()} ) {
        $rule_hash{$rule_name}->[RULE_WEIGHT]            =      0;
        $rule_hash{$rule_name}->[RULE_RECURSIVE]         =      0;
        $rule_hash{$rule_name}->[RULE_REFERENCING]       =      0;
        $rule_hash{$rule_name}->[RULE_REFERENCED]        =      0;
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
        Carp::confess("INTERNAL ERROR: Cannot survive with grammar_obj to rule_hash inconsistency.");
    }
}


sub analyze_all_rules {

    foreach my $rule_name (keys %rule_hash) {
        $rule_hash{$rule_name}->[RULE_IS_PROCESSED] = 0;
    }

    our $run_all_again = 1;
    while($run_all_again) {
        $run_all_again = 0;
        # Emptying %rule_hash and recreating the required keys is not necessary because the
        # number of rules shrinks during ONE "walk through the grammar round".
        # In case we repeat the loop than most entries need to get reset.
        # A reset of RULE_JOBS_GENERATED must be not done because we would probably
        # create duplicates of jobs being already in queues.
        reset_rule_hash_values();

        grammar_rule_hash_consistency();

        my @top_rule_list = $grammar_obj->top_rule_list();
        foreach my $rule_name (@top_rule_list) {
            # Never do something like the following now
            #     We run with only 8 threads so delete the rule 'thread13'.
            # because 'thread13' might be used in a component of some really used rule.
            # In the current stage we do not know if 'thread13' is referenced.
            $rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL] = 1;
        }

        my $more_to_process = 1;
        while ($more_to_process) {
            $more_to_process = 0;
            foreach my $rule_name (keys %rule_hash) {

                next if 1 == $rule_hash{$rule_name}->[RULE_IS_PROCESSED];
                if (0 == $rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL] and
                    0 == $rule_hash{$rule_name}->[RULE_REFERENCED]      ) {
                    next;
                }
                # Non processed potential top level rules need to get processed anyway because
                # we need for any rule determine RULE_REFERENCED.
                # In case of non top level rules and RULE_REFERENCED == 0 we just do not know if
                # they will be used at all. So process the other rules first.

                my $rule_obj = $grammar_obj->rule($rule_name);
                $rule_hash{$rule_name}->[RULE_UNIQUE_COMPONENTS] = scalar $rule_obj->unique_components;

                # Decompose the rule.
                my $components = $rule_obj->components();

                for (my $component_id = $#$components; $component_id >= 0; $component_id--) {

                    my $component = $components->[$component_id];

                    for (my $part_id = $#{$components->[$component_id]}; $part_id >= 0; $part_id--) {
                        my $component_part = $components->[$component_id]->[$part_id];
                        say("DEBUG: '$rule_name' part_id $part_id component_part ->$component_part<-") if $script_debug;
                        if (exists $rule_hash{$component_part}) {
                            say("DEBUG: '$rule_name' part_id $part_id component_part ->$component_part<- is a rule.") if $script_debug;
                            if ($component_part eq $rule_name) {
                                say("DEBUG: The rule 'rule_name' is recursive because a component of it " .
                                    "contains '$rule_name'.") if $script_debug;
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
                exit STATUS_INTERNAL_ERROR;
            }
            if ($threads < $val) {
                say("DEBUG: threads is $threads and therefore the rule '$rule_name' will be never " .
                    "used as toplevel rule.") if $script_debug;
                if(0 < $rule_hash{$rule_name}->[RULE_REFERENCED]) {
                    say("DEBUG: But the rule '$rule_name' is referenced by other rules. " .
                        "So we need to keep it.") if $script_debug;
                    $rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL] = 0;
                } else {
                    $grammar_obj->deleteRule($rule_name);
                    delete $rule_hash{$rule_name};
                    say("DEBUG: The rule '$rule_name' will be never used and was therefore deleted.") if $script_debug;
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
                        # We cannot delete ithe rule because its used by other rules.
                        $rule_hash{$del_rule_name}->[RULE_IS_TOP_LEVEL] = 0;
                    } else {
                        $grammar_obj->deleteRule($del_rule_name);
                        delete $rule_hash{$del_rule_name};
                        say("DEBUG: We have a 'thread<number>' for any thread. Rule '$del_rule_name' was therefore deleted.") if $script_debug;
                        $run_all_again = 1;
                    }
                }
            }
        }
        # 'query' versus 'thread13'
        alt_rules('query', 'thread', '');
        alt_rules('query', 'thread', '_init');
        alt_rules('query', 'thread', '_connect');
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

}


sub remove_unused_rules {

# Note: Its currently in the routine analyze_all_rules

# Difficult cases to handle right!
# Rules call top level rules like
# thread1:
#    ddl   |
#    query ;
#

}


sub extract_thread_from_rule_name {
# This routine might be unused. Please keep for future use.

    my ($rule_name) = @_;

# Snip of testing code tried:
# Never never try exact here because we get something like endless recursion.
# $rule_name = 'thread99';
# say("$rule_name: " . GenTest::Simplifier::Grammar_advanced::extract_thread_from_rule_name($rule_name));
# -> get 99
# $rule_name = 'omo';
# say("$rule_name: " . GenTest::Simplifier::Grammar_advanced::extract_thread_from_rule_name($rule_name));
# -> Get error
# $rule_name = 'query';
# say("$rule_name: " . GenTest::Simplifier::Grammar_advanced::extract_thread_from_rule_name($rule_name));
# -> Get 0
# $rule_name = 'thread01_connect';
# say("$rule_name: " . GenTest::Simplifier::Grammar_advanced::extract_thread_from_rule_name($rule_name));
# -> Get error
# $rule_name = 'thread13_connect';
# say("$rule_name: " . GenTest::Simplifier::Grammar_advanced::extract_thread_from_rule_name($rule_name));
# -> Get 13
# $rule_name = 'thread01_init';
# say("$rule_name: " . GenTest::Simplifier::Grammar_advanced::extract_thread_from_rule_name($rule_name));
# -> Get error
# $rule_name = 'thread13_init';
# say("$rule_name: " . GenTest::Simplifier::Grammar_advanced::extract_thread_from_rule_name($rule_name));
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

    Carp::confess("INTERNAL ERROR: Unknown toplevel rule '$rule_name'.");
    say("ALARM we must never reach this line.");
}



# sub remove_unused_rules {
# FIXME: Implement!

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
# In case a rule consists of several equal elements only like
#    rule_A: SELECT 13 | SELECT 13 ;
# then collapse it to
#    rule_A: SELECT 13 ;
#
# Usage is Grammar simplifier only. Therefore I hesitate to place that into
# lib/GenTest/Grammar/Rule.pm.
#
    my ($rule_name) = @_;
    my $rule_obj = $grammar_obj->rule($rule_name);
    if (not defined $rule_obj) {
        Carp::cluck("INTERNAL ERROR: Rule '$rule_name' : Undef rule object got.");
       exit STATUS_INTERNAL_ERROR;
    }
    my @unique_components = $rule_obj->unique_components();
    my $components = $rule_obj->components();
    if ((1 <  scalar @$components) and
        (1 == scalar $rule_obj->unique_components())) {
        splice (@$components, 1);
        say("DEBUG: collapseComponents: The components of rule '$rule_name' were collapsed.")
            if $script_debug;
    }
}


sub compact_grammar {

# Purpose
# -------
# Replace rules consisting of one component only (best non rare case: Its an empty string),
# by their content wherever they are used. Run remove_unused_rules after any of such operations.
# Advantage:
#    This makes grammars more handy.
# Minor disadvantage:
#    An inspection of the final grammar will no more show what was shrinked away.
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
        exit STATUS_INTERNAL_ERROR;
    }

    foreach my $rule_name ( keys %{$grammar_obj->rules()} ) {
        # Handle: rule_A: SELECT 13 | SELECT 13 ;
        collapseComponents($rule_name);
        # Important:
        # The number of rule components changes.
        # So if this number is stored in rule_hash than this value is now outdated.
    }

    my $debug_snip = "DEBUG: compact_grammar:";

    # Begin of inlining
    foreach my $rule_name ( keys %{$grammar_obj->rules()} ) {

        if ($rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL]) {
            # Top level rules cannot be inlined.
            next;
        }

        my $snip     = $debug_snip . " Rule '$rule_name':";
        my $rule_obj = $grammar_obj->rule($rule_name);
        if (not defined $rule_obj) {
            Carp::cluck("INTERNAL ERROR: Rule '$rule_name' : Undef rule object got.");
            exit STATUS_INTERNAL_ERROR;
        }
        my $components = $rule_obj->components();
        # Rules with more than component cannot get inlined.
        next if 1 < scalar @$components;

        say("$snip Candidate for inlining. ->" . $rule_obj->toString() . "<-")
            if $script_debug;
        my @the_component          = @{$rule_obj->components->[0]};
        my $the_component_sentence = join('', @the_component );
        say("$snip Component as Sentence ->$the_component_sentence<-") if $script_debug;
        # FIXME: New parameter needed.
        # Q: Should a rule consisting of something like
        #        <very long blabla consisting of several words>
        #    get inlined or not. The latter makes manual work on
        #    simplified grammar far way more convenient.
        #--------------
        if (length($the_component_sentence) > $max_inline_length) {
            say("$snip Omit inlining of rule because the component " .
                "->$the_component_sentence<- is too long.") if $script_debug;
            next;
        }

        foreach my $inspect_rule_name ( keys %{$grammar_obj->rules()} ) {

            # Recursive rules can be inlined into other rules which reference them.
            # But never inlined into themselve.
            next if $rule_name eq $inspect_rule_name;

            my $inspect_rule_obj = $grammar_obj->rule($inspect_rule_name);
            if (not defined $inspect_rule_obj) {
                Carp::cluck("INTERNAL ERROR: Rule '$inspect_rule_name' : Undef rule object got.");
                exit STATUS_INTERNAL_ERROR;
            }
            my $inspect_components = $inspect_rule_obj->components();

            for (my $component_id = $#$inspect_components; $component_id >= 0; $component_id--) {

                my $component = $inspect_components->[$component_id];

                for (my $part_id = $#{$inspect_components->[$component_id]}; $part_id >= 0; $part_id--) {

                    my $component_part = $inspect_components->[$component_id]->[$part_id];
                    say("$snip: CID $component_id, PID $part_id, ->$component_part<-")
                        if $script_debug;

                    # If $component_part ne $rule_name than it can be never a candidate.
                    # There is no reason to check if there is rule with the name $component_part at all.
                    next if ($component_part ne $rule_name);

                    say("$snip Before inlining of other single component rule ->" .
                        $inspect_rule_obj->toString() . "<-") if $script_debug;
                    splice(@{$component}, $part_id, 1, @the_component );

                    say("$snip After inlining of other single component rule ->" .
                        $inspect_rule_obj->toString() . "<-") if $script_debug;
                    # Important:
                    # The number of references to other rules might change.
                    # So if this number is stored in rule_hash than this value is now outdated.

                }
            }
        } # End of inlining
        $grammar_obj->deleteRule($rule_name);
        delete $rule_hash{$rule_name};
        say("$snip The Rule was inlined and therefore deleted.") if $script_debug;
    } # End of search for inline candidates and inlining
    grammar_rule_hash_consistency;
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
# - (simple): 'query' gets a 1, thread<n> 0.3 and the *_connect and *_init less.
# - (sophisticated): Maybe the values dependend on the number of threads finally used.
# Having a value > 0 in some rule  means also that this rule is in use.
# Decompose the top level rule into its component, determine per component the rules which occur
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

    sub inspect_rule_and_charge {
        my ($rule_name) = @_;

        my $rule_obj = $grammar_obj->rule($rule_name);

        # Decompose the rule.
        my $components = $rule_obj->components();

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

    analyze_all_rules();
    foreach my $rule_name (keys %rule_hash) {
        $rule_hash{$rule_name}->[RULE_IS_PROCESSED] = 0;
    }

    # Precharge all existing rules which are
    # - used as top level rules ( 1 == $rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL] )
    # - not thread specific (thread<number>* is thread_specific)
    # Note: We "overcharge" in case some corresponding 'thread<number>' exists.
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
    if(exists $rule_hash{$rule_name} and 1 == $rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL]) {
        say("DEBUG: calculate_weights : Process now rule '$rule_name', weight : " .
            $rule_hash{$rule_name}->[RULE_WEIGHT]) if $script_debug;
        $rule_hash{$rule_name}->[RULE_WEIGHT] = 1 / 100000;
        say("DEBUG: calculate_weights : rule '$rule_name', weight is now : " .
            $rule_hash{$rule_name}->[RULE_WEIGHT]) if $script_debug;
    }
    $rule_name = 'query_connect';
    # There might be several connects/disconnect per RQG run and thread.
    if(exists $rule_hash{$rule_name} and 1 == $rule_hash{$rule_name}->[RULE_IS_TOP_LEVEL]) {
        say("DEBUG: calculate_weights : Process now rule '$rule_name', weight : " .
            $rule_hash{$rule_name}->[RULE_WEIGHT]) if $script_debug;
        $rule_hash{$rule_name}->[RULE_WEIGHT] = 1 / 1000;
        say("DEBUG: calculate_weights : rule '$rule_name', weight is now : " .
            $rule_hash{$rule_name}->[RULE_WEIGHT]) if $script_debug;
    }
    $rule_name = 'thread_connect';
    # There might be several connects/disconnect per RQG run and thread.
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
    # and revert the previous "overcharge".
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
}


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


sub shrink_grammar {

# Return
# - undef if the rule $rule_name (combine with or)
#   - does (no more) exist
#   - exists but has one !unique! component only.
#   - exists but has no more a component leading to $component_string.
#   - exists has more than one !unique! component and one leads to $component_string
#     but the final grammar contains less less DROP/TRUNCATE/DELETE than the parent
#     and $dtd_protection == 1
# - the shrinked ($component_string removed from rule $rule_name) grammar as string.
#   The caller just wants to dump that string afterwards into some yy grammar file.
#

    my ($rule_name, $component_string, $dtd_protection) = @_;

    # INTERNAL ERROR in case a parameter is undef.
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

    # FIXME: Replace by working on grammar?
    if (not exists $rule_hash{$rule_name}) {
        say("DEBUG: shrink_grammar: The rule '$rule_name' does no more exist.") if $script_debug;
        return undef;
    }

    my @reduced_components;
    my $rule_obj          = $grammar_obj->rule($rule_name);
    my @unique_components = $rule_obj->unique_components();

    my $indent = "    ";
    my $reduced_rule_string;
    if ('_to_empty_string_only' ne $component_string) {
        #### Non destructive simplification ####

        # say("DEBUG: no_of_unique_components $no_of_unique_components ->" .
        #     $rule_obj->toString . "<-");
        if      (0 >= scalar @unique_components) {
            Carp::confess("INTERNAL ERROR: Met 0 >= unique components in rule '$rule_name'.");
        } elsif (1 == scalar @unique_components) {
            say("DEBUG: shrink_grammar: The rule '$rule_name' has already only one unique component.") if $script_debug;
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
        @reduced_components = ( '' );
    }

    # Construct something like
    # rule:                      or     rule:
    #      ;                                'A' |
    #                                       'B' ;
    $reduced_rule_string = "$rule_name:\n$indent" .
                           join(" |\n$indent", @reduced_components) . ' ;';
    if ($reduced_rule_string eq $rule_obj->toString()) {
        # Known special case:
        # The last campaign had success and we have caused by that or another campaign
        # <top_level_rule>:
        # <indent> ;
        # In the current campaign '_to_empty_string_only' was proposed for that <top_level_rule>.
        # In case we do not return undef than we get a valueless RQG run harvesting success and
        # therefore some next campaign --> ~ "endless".
        say("DEBUG: shrink_grammar: The rule '$rule_name' cannot be shrinked by applying " .
            "component_string ->$component_string<-") if $script_debug;
        return undef;
    }

    say("DEBUG: Original rule '$rule_name' ->" . $rule_obj->toString() . "<-") if $script_debug;
    say("DEBUG: Reduced  rule '$rule_name' ->" . $reduced_rule_string  . "<-") if $script_debug;

    return $reduced_rule_string;

} # End of sub shrink_grammar


1;
