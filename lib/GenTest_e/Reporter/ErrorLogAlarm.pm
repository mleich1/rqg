# Copyright (c) 2011,2012 Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2025 MariaDB plc
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

package GenTest_e::Reporter::ErrorLogAlarm;

require Exporter;
@ISA = qw(GenTest_e::Reporter);

use strict;
use GenTest_e;
use GenTest_e::Reporter;
use GenTest_e::Constants;
use DBServer_e::MySQL::MySQLd;

my $who_am_i =  "Reporter 'ErrorLogAlarm':";

# Path to error log. Is assigned first time monitor() is called.
# Note: We cannot do the same for $basedir because some upgrade could happen.
my $errorlog;

sub monitor {
    my $reporter = shift;

    if (not defined $errorlog) {
        $errorlog = $reporter->serverInfo('errorlog');
        if ($errorlog eq '') {
            # Error log was not found. Report the issue and continue.
            say("WARN: $who_am_i Error log not found! ErrorLogAlarm Reporter does not work as intended!");
            return STATUS_OK;
        } else {
            say("INFO: $who_am_i will monitor the log file '" . $errorlog . "'.");
        }
    }

    my $basedir =   $reporter->serverVariable('basedir');
    my $status =    DBServer_e::MySQL::MySQLd::checkErrorLogBase($errorlog, $basedir, undef);
    # (2025-11) Statuses which could be returned: STATUS_INTERNAL_ERROR, STATUS_ENVIRONMENT_FAILURE,
    #           STATUS_DATABASE_CORRUPTION, STATUS_CRITICAL_FAILURE, STATUS_OK
    if ( $status >= STATUS_CRITICAL_FAILURE ) {
        say("ERROR: $who_am_i " . Basics::exit_status_text($status));
        exit $status;
    } elsif ( $status > STATUS_OK ) {
        say("ERROR: $who_am_i " . Basics::return_status_text($status));
        return $status;
    } else {
        say("INFO: $who_am_i " . Basics::return_status_text($status));
        return $status;
    }
}

# sub report {
# This gets called after the periodic reporting process is gone and GenTest is around the end.
# But the RQG runner will make some big and thorough integrity check anyway soon.
# Hence a sub "report" is not needed at all.
#   return STATUS_OK;
# }


sub type {
    return REPORTER_TYPE_PERIODIC ;
}

1;
