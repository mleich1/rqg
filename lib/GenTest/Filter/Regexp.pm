# Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
# Copyright (C) 2020 MariaDB Corporation Ab.
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

package GenTest::Filter::Regexp;

require Exporter;
@ISA = qw(GenTest);

use strict;

use GenTest;
use GenTest::Constants;

use constant FILTER_REGEXP_FILE		=> 0;
use constant FILTER_REGEXP_RULES	=> 1;

# FIXME: Place in Constants.pm
use constant STATUS_FAILURE    => 1; # Just the opposite of STATUS_OK


my $total_queries;
my $filtered_queries;

sub new {
    my $class = shift;

	my $filter = $class->SUPER::new({
		file	=> FILTER_REGEXP_FILE,
		rules	=> FILTER_REGEXP_RULES
	}, @_);

    if (defined $filter->[FILTER_REGEXP_FILE]) {
	    if (STATUS_OK != $filter->readFromFile($filter->[FILTER_REGEXP_FILE])) {
            return undef;
        } else {
            return $filter;
        }
    } else {
	    return undef;
    }
}

sub readFromFile {
	my ($filter, $file) = @_;

    my $who_am_i = "GenTest::Filter::Regexp::readFromFile:";

    # For experimenting
    #==================
    # $file = '/tmp/OMO';
    # system("rm $file");          # --> $file is missing, open fails
    #
    # $file = '/tmp/OMO';
    # system("echo '{[' > $file"); # --> Syntax error
    #
    # $file = '/tmp/OMO';
    # system("echo '\$rules = {' >  $file");
    # system("echo '    \'test' => sub { \$_ =~ m{SELECT}s},' >> $file");
    # system("echo '}' >> $file");  --> Filter all SELECTs out

    my $rules;
    if(not open(CONF , $file)) {
        say("ERROR: $who_am_i Unable to open file '$file': $!");
        say("Will return STATUS_FAILURE.");
        return STATUS_FAILURE;
    } else {
        read(CONF, my $regexp_text, -s $file);
        eval ($regexp_text);
        # If there was no error, $@ is set to the empty string.
        if ($@) {
            say("ERROR: $who_am_i Unable to load file '$file': $@");
            say("Will return STATUS_FAILURE.");
            return STATUS_FAILURE;
        } else {
            $filter->[FILTER_REGEXP_RULES] = $rules;
            say("Loaded ".(keys %$rules)." filtering rules from '$file'");
            return STATUS_OK;
        }
    }
}

sub filter {
	my ($filter, $query) = @_;
    # Hint:
    # The content of $query is <the query> <explain output>
	$total_queries++;

	foreach my $rule_name (keys %{$filter->[FILTER_REGEXP_RULES]}) {
		my $rule = $filter->[FILTER_REGEXP_RULES]->{$rule_name};

		if (
			(ref($rule) eq 'Regexp') &&
			($query =~ m{$rule}si)
		) {
			$filtered_queries++;
#			say("Query: $query filtered out by regexp rule $rule_name.");
			return STATUS_SKIP;
		} elsif (
			(ref($rule) eq '') &&
			(lc($query) eq lc($rule))
		) {
			$filtered_queries++;
#			say("Query: $query filtered out by literal rule $rule_name.");
			return STATUS_SKIP;
		} elsif (ref($rule) eq 'CODE') {
			local $_ = $query;
			if ($rule->($query)) {
				$filtered_queries++;
#				say("Query: $query filtered out by code rule $rule_name");
	                        return STATUS_SKIP;
			}
		}
	}

	return STATUS_OK;
}

sub DESTROY {
	print "GenTest::Filter::Regexp: total_queries: $total_queries; filtered_queries: $filtered_queries\n" if rqg_debug() && defined $total_queries;
}

1;
