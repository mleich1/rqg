# Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
# Copyright (C) 2020-2022 MariaDB Corporation Ab.
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

package GenTest::Validator::RepeatableRead;

require Exporter;
@ISA = qw(GenTest::Validator GenTest);

use strict;

use GenTest;
use GenTest::Comparator;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Validator;

my $who_am_i = "Validator 'RepeatableRead':";

my $debug_here = 1;

#
# We check for database consistency using queries which walk the table in various ways
# We should have also probed each row individually, however this is too CPU intensive
#

# Warning(mleich):
# This validator is not compatible to most grammars.
# Main obstacles:
# - A column `pk` of type *INT must exist.
# - The `pk` value range used within the table needs to be > -16777216.
# - It will fail if the SELECT has no WHERE condition.
# - MDEV-29491 InnoDB: Strange printed result on SELECT DISTINCT col_bit ... ORDER BY col_bit
#   when running SELECT DISTINCT <col of type BIT> ORDER BY <same col of type BIT> + InnoDB.
my @predicates = (
    '/* no additional predicate */',    # Rerun original query (does not cause bugs)
    'AND `pk` > -16777216',             # Index scan on PK
#   'AND `int_key` > -16777216',        # Index scan on key
#   'AND `int_key` > -16777216 ORDER BY `int_key` LIMIT 1000000', # Falcon LIMIT optimization (broken)
);

sub validate {
    my ($validator, $executors, $results) = @_;
    my $executor = $executors->[0];
    my $orig_result = $results->[0];
    my $orig_query = $orig_result->query();

    return STATUS_OK if $orig_query !~ m{^\s*select}io;
    my $err = $orig_result->err();
    return STATUS_OK if defined $err and $err > 0;
    # We could harvest STATUS_SKIP in case the executor gives up because the planned duration
    # of the GenTest phase is exceeded. Unclear if the validator would be called at all.
    if (STATUS_SKIP == $orig_result->status()) {
        say("INFO: $who_am_i was called even though we had STATUS_SKIP.");
        return STATUS_OK;
    }

    foreach my $predicate (@predicates) {
        my $new_query;
        if ($orig_query =~ m{order}io) {
            $new_query = $orig_query =~ s{order}{$predicate ORDER}ri;
            say("DEBUG: orig ->" . $orig_query . "<- new ->" . $new_query . "<-");
        } else {
            $new_query = $orig_query . " " . $predicate;
        }
        my $new_result = $executor->execute($new_query);
        my $err = $new_result->err();
        if (defined $err) {
            say("DEBUG: $who_am_i ->" . $new_query . "<- harvested $err");
            return STATUS_UNKNOWN_ERROR;
        }
        # We could harvest STATUS_SKIP in case ... like above.
        if (STATUS_SKIP == $new_result->status()) {
            return STATUS_OK;
        }

        return STATUS_OK if not defined $new_result->data();

        my $compare_outcome = GenTest::Comparator::compare($orig_result, $new_result);
        if ($compare_outcome > STATUS_OK) {
            say("Query: $orig_query returns different result when executed with additional " .
                "predicate '$predicate' (" . $orig_result->rows() . " vs. " . $new_result->rows() .
                " rows).");
            my $dbh = $executor->dbh();
            my $aux_query = 'SELECT @@tx_isolation /* E_R ' . 'BLUB' . # $executor->role .
                            ' QNO 0 CON_ID unknown */ ';
            # say("DEBUG: $who_am_i Will run ->" . $aux_query . "<-");
            my $row_arrayref = $dbh->selectrow_arrayref($aux_query);
            my $error =        $dbh->err();
            if (defined $error) {
                # Being victim of KILL QUERY/SESSION .... or whatever.
                say("DEBUG: $who_am_i ->" . $aux_query . "<- harvested $error. " .
                    "Will return STATUS_OK.") if $debug_here;
                    return STATUS_OK;
            }
            say("DEBUG: $who_am_i ISO LEVEL IS is ->" . $row_arrayref->[0] . "<-") if $debug_here;
            if ('READ-COMMITTED' eq $row_arrayref->[0] or 'READ-UNCOMMITTED' eq $row_arrayref->[0]) {
                # It cannot be 100% excluded that the result diff is a bug of server and/or
                # storage engine. But its very likely that the diff is caused by wrong handling
                # of the ISO Level.
                return STATUS_OK;
            }

            say(GenTest::Comparator::dumpDiff($orig_result, $new_result));

            say("Full result from the original query: $orig_query");
            print join("\n", sort map { join("\t", @$_) } @{$orig_result->data()}) . "\n";
            say("Full result from the follow-up query: $new_query");
            print join("\n", sort map { join("\t", @$_) } @{$new_result->data()}) . "\n";

            say("Executing the same queries a second time:");

            foreach my $repeat_query ($orig_query, $new_query) {
                my $repeat_result = $executor->execute($repeat_query);
                say("Full result from the repeat of the query: $repeat_query");
                print join("\n", sort map { join("\t", @$_) } @{$repeat_result->data()}) . "\n";
            }

            return $compare_outcome; # - STATUS_SELECT_REDUCTION;
        }
    }

    return STATUS_OK;
}

1;
