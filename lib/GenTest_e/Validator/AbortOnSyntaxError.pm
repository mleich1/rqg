# Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
# # Copyright (c) 2022 MariaDB Corporation Ab.
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

package GenTest_e::Validator::AbortOnSyntaxError;

require Exporter;
@ISA = qw(GenTest_e::Validator GenTest_e);

use strict;

use GenTest_e;
use GenTest_e::Constants;
use GenTest_e::Result;
use GenTest_e::Validator;

1;

sub validate {
    my ($validator, $executors, $results) = @_;
    my $who_am_i = Basics::who_am_i();

    if ($results->[0]->status() == STATUS_SYNTAX_ERROR) {
        say("ERROR: $who_am_i Will kill(SIGKILL) the server and exit with STATUS_SYNTAX_ERROR " .
            "because of syntax error.");
        say("ERROR: $who_am_i RQG will finally report STATUS_SERVER_CRASHED (techn. resasons)");
        system('kill -KILL $SERVER_PID1');
        exit STATUS_SYNTAX_ERROR;
    } else {
        return STATUS_WONT_HANDLE;
    }
}

1;
