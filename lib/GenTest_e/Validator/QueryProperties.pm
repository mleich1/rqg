# Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
# Copyright (C) 2016, 2021 MariaDB Corporation.
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

package GenTest_e::Validator::QueryProperties;

require Exporter;
@ISA = qw(GenTest_e::Validator GenTest_e);

use strict;

use GenTest_e;
use Data::Dumper;
use GenTest_e::Constants;
use GenTest_e::Result;
use GenTest_e::Validator;

my @properties = (
    'RESULTSET_HAS_SAME_DATA_IN_EVERY_ROW',
    'RESULTSET_IS_SINGLE_INTEGER_ONE',
    'RESULTSET_HAS_ZERO_OR_ONE_ROWS',
    'RESULTSET_HAS_ONE_ROW',
    'RESULTSET_HAS_NO_ROW',
    'QUERY_IS_REPLICATION_SAFE'
);

my %properties;
foreach my $property (@properties) {
    $properties{$property} = 1;
};

sub validate {
    my ($validator, $executors, $results) = @_;

    my $query = $results->[0]->query();
    my @query_properties = $query =~ m{((?:QProp\.RESULTSET_|QProp\.ERROR_|QProp\.QUERY_).*?)[^A-Z_0-9]}sog;

    return STATUS_WONT_HANDLE if $#query_properties == -1;

    my $query_status = STATUS_OK;

    foreach my $result (@$results) {
        my @error_codes = ();
        my $property_status;
        foreach my $query_property (@query_properties) {
            $property_status = STATUS_OK;
            if (exists $properties{$query_property}) {
                #
                # This is a named property, call the respective validation procedure
                #
                $property_status = $validator->$query_property($result);
                if ($property_status != STATUS_OK) {
                    say("ERROR: Query: $query does not have the required property: $query_property");
                }
                $query_status = $property_status if $property_status > $query_status;
            } elsif (my ($error) = $query_property =~ m{ERROR_(.*)}so) {
                #
                # This is an error code, check that the query returned one of the given error codes
                #
                if ($error !~ m{^\d*$}) {
                    say("ERROR: Query: $query needs to use a numeric code in in query property $query_property.");
                    return STATUS_ENVIRONMENT_FAILURE;
                }
                push @error_codes, $error;
            }
        }
        my $err = $result->err();
        if ($err and scalar(@error_codes)) {
            $property_status = STATUS_ERROR_MISMATCH;
            foreach (@error_codes) {
                if ($err == $_) {
                    $property_status = STATUS_OK;
                    last;
                }
            }
            if ($property_status != STATUS_OK) {
                say("ERROR: Error code ".$result->err()." for query $query does not match the expected list: @error_codes");
                $query_status = $property_status if $property_status > $query_status;
            }
        }
    }

    if ($query_status != STATUS_OK) {
        print Dumper $results if rqg_debug();
    }

    return $query_status;
}


sub RESULTSET_HAS_SAME_DATA_IN_EVERY_ROW {
    my ($validator, $result) = @_;

    return STATUS_OK if not defined $result->data();
    return STATUS_OK if $result->rows() < 2;

    my %data_hash;
    foreach my $row (@{$result->data()}) {
        my $data_item = join('<field>', @{$row});
        $data_hash{$data_item}++;
    }

    if (keys(%data_hash) > 1) {
        return STATUS_CONTENT_MISMATCH;
    } else {
        return STATUS_OK;
    }
}

sub RESULTSET_HAS_ZERO_OR_ONE_ROWS {
    my ($validator, $result) = @_;

    if ($result->rows() > 1) {
        return STATUS_LENGTH_MISMATCH;
    } else {
        return STATUS_OK;
    }
}

sub RESULTSET_HAS_ONE_ROW {
    my ($validator, $result) = @_;

    if ($result->rows() != 1) {
        return STATUS_LENGTH_MISMATCH;
    } else {
        return STATUS_OK;
    }
}

sub RESULTSET_HAS_NO_ROW {
    my ($validator, $result) = @_;

    if ($result->rows() != 0) {
        return STATUS_LENGTH_MISMATCH;
    } else {
        return STATUS_OK;
    }
}

sub RESULTSET_IS_SINGLE_INTEGER_ONE {
    my ($validator, $result) = @_;

    if (
        (not defined $result->data()) ||
        ($#{$result->data()} != 0) ||
        ($result->rows() != 1) ||
        ($#{$result->data()->[0]} != 0) ||
        ($result->data()->[0]->[0] != 1)
    ) {
        return STATUS_CONTENT_MISMATCH;
    } else {
        return STATUS_OK;
    }
}

sub QUERY_IS_REPLICATION_SAFE {

    my ($validator, $result) = @_;

    my $warnings = $result->warnings();

    if (defined $warnings) {
        foreach my $warning (@$warnings) {
            return STATUS_ENVIRONMENT_FAILURE if $warning->[1] == 1592;
        }
    }
    return STATUS_OK;
}

1;
