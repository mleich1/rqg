# Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
# Copyright (C) 2018 MariaDB Corporation Ab.
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

# The grammar simplifier here is based on the code of the original grammar simplifier
# lib/GenTest/Simplifier/Grammar.pm.
# The main modifications are
# 1. Never do "illegal" simplifications which could harm the semantics of the RQG test.
#    Neither try to
#    - remove the last component/alternative of some rule
#    nor
#    - remove a part of some alternative like the 13 of a "SELECT 13".
# 2. Go with some dynamic number of "walk through the grammar" rounds.
#
# The original simplifier (lib/GenTest/Simplifier/Grammar.pm) was not replaced with
# the one here in order to have
# - some working simplifier as fall back position
# - a simplifier which does not hesitate to "cripple" grammars which is acceptable in case
#   of simplifying crashes/asserts
# - being able to measure the impact of different simplier algorithms/concepts
#
# util/new-simplify-grammar.pl uses the simplifier implemented here.
#


package GenTest::Simplifier::Grammar1;

require Exporter;
@ISA = qw(GenTest);

use strict;
use Carp;
use lib 'lib';

use GenTest;
use GenTest::Constants;
use GenTest::Grammar;
use GenTest::Grammar::Rule;

use constant SIMPLIFIER_ORACLE          => 0;
use constant SIMPLIFIER_CACHE           => 1;
use constant SIMPLIFIER_GRAMMAR_OBJ     => 2;
use constant SIMPLIFIER_RULES_VISITED   => 3;
use constant SIMPLIFIER_GRAMMAR_FLAGS   => 4;

1;

my $debug = 0;

sub new {
    my $class = shift;

    my $simplifier = $class->SUPER::new({
        'oracle'        => SIMPLIFIER_ORACLE,
        'grammar_flags' => SIMPLIFIER_GRAMMAR_FLAGS
    }, @_);

    return $simplifier;
}

# Set this variable to one whenever having a replay with some simplification.
my $round_with_success = 0;

sub simplify {
    my ($simplifier, $initial_grammar_string) = @_;

    if ($simplifier->oracle($initial_grammar_string) == ORACLE_ISSUE_NO_LONGER_REPEATABLE) {
        carp("Error: Initial grammar failed to reproduce the same issue.
        This may be a configuration issue or a non-repeatability issue.
        Configuration issue: check the run output log above; it may highlight a problem.
        If the configuration is correct, then check these suggestions for non-repeatability:
        * Increase the duration of the run ('duration')
        * Increase the number of trials ('trials'): this helps for sporadic issues
        * Double check the seed and mask values ('seed' and 'mask')
        * Vary the seed value ('seed')
        Various config (simplifier setup, grammar, ...) and non-repeatability issues may result in this error.
        ");
        return undef;
    }

    my $grammar_string = $initial_grammar_string;

    # Trying to simplify an existing and used grammar rule is done by performing a descend() for
    # all existing top level rules (they are used with guarantee except the number of threads is
    # too small). After that operation we remove all rules which were never visited becasue they
    # are unused.
    # Some older comment says:
    # We perform the descend() several times, in order to compensate for our imperfect tree walking
    # algorithm combined with the probability of loops in the grammar files.
    # I can add my observations over years:
    # We have frequent grammars which are capable to replay but their likelihood to do this is low.
    # There is also frequent the observation:
    #    Full grammar with component x of rule X removed does not replay with n attempts.
    #    Partial shrinked grammar with component x of rule X removed replays with clear less
    #    than n attempts.
    # So we repeat the walk through the grammar rounds as long as
    # - number of round <= 5
    # and
    # - the last round had in minimum one simplification with success.
    #

    $round_with_success = 1;
    my $round = 1;
    while (1 == $round_with_success and $round <= 5) {
        $round_with_success = 0;
        $simplifier->[SIMPLIFIER_GRAMMAR_OBJ] = GenTest::Grammar->new(
            grammar_string  => $grammar_string,
            grammar_flags   => $simplifier->[SIMPLIFIER_GRAMMAR_FLAGS]
        );

        return undef if not defined $simplifier->[SIMPLIFIER_GRAMMAR_OBJ];

        my @top_rule_list = $simplifier->[SIMPLIFIER_GRAMMAR_OBJ]->top_rule_list();
        if (0 == scalar @top_rule_list) {
            say("ERROR: We had trouble. Will return undef.");
            return undef;
        } else {
            say("DEBUG: The top rule list is " .
                join (', ', $simplifier->[SIMPLIFIER_GRAMMAR_OBJ]->top_rule_list())) if $debug;
        }

        $simplifier->[SIMPLIFIER_RULES_VISITED] = {};
        foreach my $top_rule (@top_rule_list) {
            say("DEBUG: simplify: Descend to top level rule '$top_rule'.") if $debug;
            $simplifier->descend($top_rule);
        }

        foreach my $rule (keys %{$simplifier->[SIMPLIFIER_GRAMMAR_OBJ]->rules()}) {
            if (not exists $simplifier->[SIMPLIFIER_RULES_VISITED]->{$rule}) {
                say("DEBUG: simplify: Rule '$rule' is not referenced any more. Removing " .
                    "from grammar.") if $debug;
                $simplifier->[SIMPLIFIER_GRAMMAR_OBJ]->deleteRule($rule);
            }
        }

        $grammar_string = $simplifier->[SIMPLIFIER_GRAMMAR_OBJ]->toString();
        if (not $round_with_success) {
            say("DEBUG: No success in the just finished simplify the (complete) grammar round.");
        } else {
            say("DEBUG: Success in the just finished simplify the (complete) grammar round.");
            $round++;
        }
    }

    if ($simplifier->oracle($grammar_string) == ORACLE_ISSUE_NO_LONGER_REPEATABLE) {
        carp("Final grammar failed to reproduce the same issue.");
        return undef;
    } else {
        return $grammar_string;
    }
}

sub descend {
    my ($simplifier, $rule) = @_;

    my $grammar_obj = $simplifier->[SIMPLIFIER_GRAMMAR_OBJ];

    my $rule_obj = $grammar_obj->rule($rule);
    return $rule if not defined $rule_obj;

    return $rule_obj if exists $simplifier->[SIMPLIFIER_RULES_VISITED]->{$rule};
    $simplifier->[SIMPLIFIER_RULES_VISITED]->{$rule}++;

    my $orig_components = $rule_obj->components();

    for (my $component_id = $#$orig_components; $component_id >= 0; $component_id--) {

        my $orig_component = $orig_components->[$component_id];

        if ($#$orig_components > 0) {
            say("DEBUG: simplify: The rule '$rule' has currently more than one " .
                "component.") if $debug;

            # Remove one component and call the oracle to check if the issue is still repeatable
            say("Attempting to remove component ".join(' ', @$orig_component)." ...");

            splice (@$orig_components, $component_id, 1);

            if ($simplifier->oracle($grammar_obj->toString()) != ORACLE_ISSUE_NO_LONGER_REPEATABLE) {
                say("Outcome still repeatable after removing " .
                    join(' ', @$orig_component).". Deleting component.");
                $round_with_success = 1;
                next;
            } else {
                say("Outcome no longer repeatable after removing " .
                    join(' ', @$orig_component).". Keeping component.");
                # Undo the change.
                splice (@$orig_components, $component_id, 0, $orig_component);
            }
        }

        # We had either
        # - only one remaining component (removal forbidden)   or
        # - the attempt to remove the component did not replay
        # In case of attempt with replay than we would not be here because that runs "next".
        # So lets dig deeper, into the parts of the current rule component.

        for (my $part_id = $#{$orig_components->[$component_id]}; $part_id >= 0; $part_id--) {

            my $component_part = $orig_components->[$component_id]->[$part_id];

            my %ml_rule_hash = %{$simplifier->[SIMPLIFIER_GRAMMAR_OBJ]->rules()};
            if (not exists $ml_rule_hash{$component_part} ) {
                say("DEBUG: simplify: component_part ->$component_part<- is not a rule. " .
                    "Hence no descend.") if $debug;
                next;
            };

            say("DEBUG: simplify: Descend to rule '$component_part'.") if $debug;
            my $child = $simplifier->descend($component_part);

            # If the outcome of the descend() is sufficiently simple, in-line it.

            if (ref($child) eq 'GenTest::Grammar::Rule') {
                my $child_name = $child->name();
                if ($#{$child->components()} == -1) {
                    say("DEBUG: simplify: Child $child_name is empty. Removing " .
                        "altogether.") if $debug;
                    splice(@{$orig_components->[$component_id]}, $part_id, 1);
                } elsif ($#{$child->components()} == 0) {
                    say("DEBUG: simplify: Child $child_name has a single component. " .
                        "In-lining.") if $debug;
                    splice(@{$orig_components->[$component_id]}, $part_id, 1,
                           @{$child->components()->[0]});
                }
            } else {
                say("Got a string literal. In-lining.") if $debug;
                splice(@{$orig_components->[$component_id]}, $part_id, 1, $child);
            }
        }
    }

    return $rule_obj;
}

sub oracle {
    my ($simplifier, $grammar) = @_;

    my $cache = $simplifier->[SIMPLIFIER_CACHE];
    my $oracle = $simplifier->[SIMPLIFIER_ORACLE];

    $cache->{$grammar} = $oracle->($grammar) if not exists $cache->{$grammar};
    return $cache->{$grammar};
}

1;
