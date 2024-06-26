# Copyright (c) 2008,2010 Oracle and/or its affiliates. All rights reserved.
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

package GenTest_e::Validator::DrizzleTransformer;

require Exporter;
@ISA = qw(GenTest_e::Validator GenTest_e);

use strict;

use GenTest_e;
use GenTest_e::Constants;
use GenTest_e::Comparator;
#use GenTest_e::Simplifier::SQL;
#use GenTest_e::Simplifier::Test;
use GenTest_e::Translator;
use GenTest_e::Translator::Mysqldump2ANSI;
use GenTest_e::Translator::Mysqldump2javadb;
use GenTest_e::Translator::MysqlDML2ANSI;

my @transformer_names;
my @transformers;
my $database_created = 0;

sub BEGIN {
	@transformer_names = (
		'DrizzleExecuteString',
                'DrizzleExecuteVariable'
	);

	say("Transformer Validator will use the following Transformers: ".join(', ', @transformer_names));

	foreach my $transformer_name (@transformer_names) {
		eval ("require GenTest_e::Transform::'".$transformer_name) or die $@;
		my $transformer = ('GenTest_e::Transform::'.$transformer_name)->new();
		push @transformers, $transformer;
	}
}

sub validate {
	my ($validator, $executors, $results) = @_;

	my $executor = $executors->[0];
	my $original_result = $results->[0];
	my $original_query = $original_result->query();

	if ($database_created == 0) {
		$executor->dbh()->do("CREATE DATABASE IF NOT EXISTS transforms");
		$database_created = 1;
	}

	return STATUS_WONT_HANDLE if $original_query !~ m{^\s*SELECT}sio;
	return STATUS_WONT_HANDLE if defined $results->[0]->warnings();
	return STATUS_WONT_HANDLE if $results->[0]->status() != STATUS_OK;

	my $max_transformer_status; 
	foreach my $transformer (@transformers) {
		my $transformer_status = $validator->transform($transformer, $executor, $results);
		$transformer_status = STATUS_OK if ($transformer_status == STATUS_CONTENT_MISMATCH) && ($original_query =~ m{LIMIT}sio);
		return $transformer_status if $transformer_status > STATUS_CRITICAL_FAILURE;
		$max_transformer_status = $transformer_status if $transformer_status > $max_transformer_status;
	}

	return $max_transformer_status > STATUS_SELECT_REDUCTION ? $max_transformer_status - STATUS_SELECT_REDUCTION : $max_transformer_status;
}

sub transform {
	my ($validator, $transformer, $executor, $results) = @_;

	my $original_result = $results->[0];
	my $original_query = $original_result->query();

	my ($transform_outcome, $transformed_queries, $transformed_results) = $transformer->transformExecuteValidate($original_query, $original_result, $executor);
	return $transform_outcome if ($transform_outcome > STATUS_CRITICAL_FAILURE) || ($transform_outcome eq STATUS_OK);

	say("Original query: $original_query failed transformation with Transformer ".$transformer->name());
	say("Transformed query: ".join('; ', @$transformed_queries));

	say(GenTest_e::Comparator::dumpDiff($original_result, $transformed_results->[0]));

	# NOTE:  Removed Simplification code from here

	return $transform_outcome;
}

sub DESTROY {
	@transformers = ();
}

1;
