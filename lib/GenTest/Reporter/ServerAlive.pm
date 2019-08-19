# Copyright (c) 2019 MariaDB Corporation Ab. All rights reserved.
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

package GenTest::Reporter::ServerAlive;

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use GenTest;
use GenTest::Constants;
use GenTest::Reporter;
use GenTest::Incident;
use GenTest::CallbackPlugin;

#
# Purpose
# -------
# Enhance the RQG log with more details so that its easier to understand what was going on.
#    Report periodic if the processes of the servers are alive.
#    By doing that a timestamp gets written at begin of the message.
#    This helps a bit in case of
#    - meeting some server freeze and not using the reporter 'Deadlock' for detection
#    - sqltrace enabled (does not write timestamps)
#
# It is not the task of 'ServerAlive' to judge about the state of the test.
# Therefore it will return STATUS_OK except an internal error was met.
#
# Amount of messages written: ~ 1 message per 10s
#

my $who_am_i = "Reporter 'ServerAlive':";

sub monitor {
    if (defined $ENV{RQG_CALLBACK}) {
        return callbackStatus(@_);
    } else {
        return nativeStatus(@_);
    }
}

sub nativeStatus {
    my $reporter = shift;

    my $message = "INFO: $who_am_i";
    for (my $i = 0; defined $reporter->properties->servers->[$i] ; $i++) {
        my $pid = $reporter->properties->servers->[$i]->serverpid();
        # For testing:
        # $pid = undef;
        if (not defined $pid) {
            say("ERROR: $who_am_i Pid for Server(" . ($i + 1) . ") is not defined. " .
                "Will return STATUS_INTERNAL_ERROR.");
            return STATUS_INTERNAL_ERROR;
        }
        $message .= " -- Server(" . ($i + 1) . ") process $pid:";
        my $server_running    = kill (0, $pid);
        if ($server_running) {
            $message .= " running";
        } else {
            $message .= " not running";
        }
    }
    say($message);
    return STATUS_OK;

}

sub callbackStatus {
    my $output = GenTest::CallbackPlugin::run("ServerAlive");
    say("$output");
    ## Need some incident interface here in the output from
    ## the callback
    return STATUS_OK, undef;
}

sub type {
    return REPORTER_TYPE_PERIODIC;
}

1;
