# Copyright (c) 2008,2011 Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2018, MariaDB Corporation Ab.
# Copyright (c) 2023 MariaDB plc
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

package GenTest_e::Validator;

@ISA = qw(GenTest_e);

use strict;
use GenTest_e::Result;

use constant VALIDATOR_DBH    => 0;

sub new {
    my $class = shift;
    return $class->SUPER::new({
        dbh => VALIDATOR_DBH
    }, @_);
}

sub init {
    return 1;
}

sub configure {
    return 1;
}

sub prerequisites {
    return undef;
}

sub dbh {
    return $_[0]->[VALIDATOR_DBH];
}

sub setDbh {
    $_[0]->[VALIDATOR_DBH] = $_[1];
}

1;
