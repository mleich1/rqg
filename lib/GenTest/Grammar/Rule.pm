# Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
# Copyright (c) 2018, 2019 MariaDB Corporation Ab.
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

package GenTest::Grammar::Rule;
use strict;

1;

use constant RULE_NAME          => 0;
use constant RULE_COMPONENTS    => 1;

# When printing a grammar or a rule than all components of a rule should begin with this indent.
use constant COMPONENT_INDENT   => '    ';

my %args = (
    'name'        => RULE_NAME,
    'components'  => RULE_COMPONENTS
);

sub new {
    my $class = shift;
    my $rule  = bless ([], $class);

    my $max_arg = (scalar(@_) / 2) - 1;

    foreach my $i (0..$max_arg) {
        if (exists $args{$_[$i * 2]}) {
            $rule->[$args{$_[$i * 2]}] = $_[$i * 2 + 1];
        } else {
            warn("Unkown argument '$_[$i * 2]' to " . $class . '->new()');
        }
    }
    return $rule;
}

sub name {
    return $_[0]->[RULE_NAME];
}

sub components {
    return $_[0]->[RULE_COMPONENTS];
}

sub setComponents {
    $_[0]->[RULE_COMPONENTS] = $_[1];
}

sub unique_components {

# Return an array of unique components ordered according to the needs of the grammar
# simplifier (from the last to the first component).
# A component is here a string and not an array with elements pointing to strings
# like in the grammar object.
#
# Use cases
# ---------
# - advanced grammar simplifier (to be implemented)
#   We get the same amount of theoretic simplification steps like when using the current
#   default GRAMMAR_FLAG_COMPACT_RULES. But the runtime properties of the grammars will
#   change in average to some smaller extend.
# - unknown
#
# Example of logics
# -----------------
# rule:
#     a | b |
#     a | d ; ==> unique_component_list: d, a, b ;
#
#
# Example code (tested) how to invoke that maybe for a unit test
# --------------------------------------------------------------
# my $grammar_structure = GenTest::Grammar->new(
#           grammar_string  => $initial_grammar,
#           grammar_flags   => undef
# );
#
# $rule_name                      = 'ddl';
# my $rule_obj                    = $grammar_obj->rule($rule_name);
# my @rule_unique_component_list  = $rule_obj->unique_components();
# my $rule_unique_component_count = scalar @rule_unique_component_list;
# if (1 > $rule_unique_component_count) {
#     say("WARN: Rule '$rule_name' : The number of unique components is " .
#         "$rule_unique_component_count.");
# }
# say("DEBUG: Rule '$rule_name' : rule_unique_component_list is ->" .
#     join ('<-->', @rule_unique_component_list) . "<-");
# say("DEBUG: Rule '$rule_name' : The number of unique components is " .
#     "$rule_unique_component_count.");
#
#
# MAYBE FIXME
# -----------
# In order be more orthogonal switch to returning an array of pointers
# to arrays like the routine components.
# But in the simplifier I need finally the strings :-(
#

    my $rule = shift;

    my %rule_component_hash;
    my @rule_unique_component_list;

    my $components = $rule->components();
    foreach my $component (@$components) {
        my $component_string = join('', @$component);
        # print("DEBUG: CS component_string ->$component_string<-\n");
        if (not exists $rule_component_hash{$component_string}) {
            $rule_component_hash{$component_string} = 1;
            push @rule_unique_component_list , $component_string;
        } else {
            # print("Did exist in rule_component_hash: $component_string\n");
        }
    }

    # We have read the rule components lines top down and in the lines left to right.
    # The "agreement" for the grammmar simplifier is to attack the components lines
    # bottom up and in the lines right to left.
    @rule_unique_component_list = reverse @rule_unique_component_list;
    return @rule_unique_component_list;
}

sub toString {
    my $rule = shift;
    my $components = $rule->components();
    my $component_indent = COMPONENT_INDENT;

    # Warning: An element of @$components is an array and not some string.
    my $string =     $rule->name() . ":\n$component_indent" .
                           join(" |\n$component_indent", map { join('', @$_) } @$components) . " ;";
    # Prevent <more than one white space>;EOL
    $string =~ s{ +;$}{ ;}img;
    # Prevent BOL<one white space>;EOL
    $string =~ s{^ *;$}{$component_indent;}img;
    $string =~ s{ +\|}{ \|}img;
    $string =~ s{^ *\|}{$component_indent\|}img;

    # Original
    # return $rule->name() . ":\n    " . join(" |\n    ", map { join('', @$_) } @$components) . ";";
    return $string;
}


1;
