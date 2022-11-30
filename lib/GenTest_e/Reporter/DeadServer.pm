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

package GenTest_e::Reporter::DeadServer;

require Exporter;
@ISA = qw(GenTest_e::Reporter);

use strict;
use GenTest_e;
use GenTest_e::Constants;
use GenTest_e::Reporter;
use GenTest_e::CallbackPlugin;

#
# Purpose
# -------
# Throw STATUS_CRITICAL_FAILURE as soon as the process of one of the servers has disappeared.
# Amount of messages written: ~ 1 message per 10s
#
# Some use case
# -------------
# Galera Cluster and one node shuts down.
#     An example of a reason for doing this is a message in the server error log like
#     [ERROR] WSREP: Node consistency compromised, aborting...
#     The reporter itself does not search for that message.
#
# This reporter is a clone of lib/GenTest_e/Reporter/ServerAlive.pm
# FIXME: Test this reporter on WIN and especially with callback.
#
#

my $who_am_i = "Reporter 'DeadServer':";

sub monitor {
    if (defined $ENV{RQG_CALLBACK}) {
        return callbackStatus(@_);
    } else {
        return nativeStatus(@_);
    }
}

sub nativeStatus {
    my $reporter = shift;

    my $server_is_dead = 0;

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
            say("ERROR: $who_am_i Server(" . ($i + 1) . ") process $pid is no more running. " .
                "Will return STATUS_CRITICAL_FAILURE later.");
            my $errorlog = $reporter->properties->servers->[$i]->errorlog();
            if (not -f $errorlog ) {
                say("ERROR: $who_am_i The error log of Server(" . ($i + 1) . ") does not exist. " .
                    "Will return STATUS_INTERNAL_ERROR.");
                    return STATUS_INTERNAL_ERROR;
            }
            say("Errorlog '$errorlog' -------------------------- begin");
            sayFile($errorlog);
            say("Errorlog '$errorlog' -------------------------- end");
            $server_is_dead = 1;
        }
    }
    say($message);
    if ($server_is_dead) {
        return STATUS_CRITICAL_FAILURE;
    } else {
        return STATUS_OK;
    }
}

sub callbackStatus {
    my $output = GenTest_e::CallbackPlugin::run("DeadServer");
    say("$output");
    ## Need some incident interface here in the output from
    ## the callback
    return STATUS_OK, undef;
}

sub type {
    return REPORTER_TYPE_PERIODIC;
}

1;
