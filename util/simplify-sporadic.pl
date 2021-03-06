#!/usr/bin/perl

# Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
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

use strict;
use DBI;
use lib 'lib';
use lib '../lib';

$| = 1;
require GenTest::Simplifier::SQL;

# Overview
# ========
# This script demonstrates the simplification of queries that fail sporadically.
# In order to account for the sporadicity, we define an "oracle" function that runs
# every query 5000 times, and reports that the problem is gone only if all 5000 
# instances returned the same number of rows. Otherwise, it reports that the problem
# remains, and the Simplifier will use this information to further guide the 
# simplification process.
#
# More information
# ================
# https://github.com/RQG/RQG-Documentation/wiki/RandomQueryGeneratorSimplification

my $query = " SELECT * FROM A ";
my $trials = 1000;

my $dsn = 'dbi:mysql:host=127.0.0.1:port=19306:user=root:database=test';
my $dbh = DBI->connect($dsn, undef, undef, { mysql_multi_statements => 1, RaiseError => 1 });

my $simplifier = GenTest::Simplifier::SQL->new(
	oracle => sub {
		my $query = shift;
		print "testing $query\n";
		my %outcomes;
		foreach my $trial (1..$trials) {
			my $sth = $dbh->prepare($query);
			$sth->execute();
			return 0 if $sth->err() > 0;
			$outcomes{$sth->rows()}++;
			print "*";
			return 1 if scalar(keys %outcomes) > 1;
		}
		return 0;
	}
);
my $simplified = $simplifier->simplify($query);

print "Simplified query:\n$simplified;\n";
