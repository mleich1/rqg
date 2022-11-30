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

package GenTest_e::Reporter::ServerDead;

require Exporter;
@ISA = qw(GenTest_e::Reporter);

use strict;
use GenTest_e;
use GenTest_e::Constants;
use GenTest_e::Reporter;
use GenTest_e::CallbackPlugin;

#-----------------------------------------------------------------------
# Some notes (sorry if its for you too banal or obvious):
# 1. ServerDead is not a periodic reporter.
#    So it does not matter if the periodic reporting process is alive.
# 2. ServerDead will be called if ever only around end of GenTest_e.
#
# Typical use case:
# RQG grammar simplification for an assert like
# - whitelist_statuses STATUS_SERVER_CRASHED
# - whitelist_patterns
#   Something which gets printed by the server like
#   mysqld: storage/innobase/row/row0log.cc:...: Assertion `!((new_col->prtype ^ col->prtype) & ~256U)' failed.
#   => 'mysqld: .{1,100}row0log.cc.{1,50}row_log_table_apply_convert_mrec.{1,300} Assertion .{1,200}256U.. failed.'
#   Never something which requires the use of the reporter 'Backtrace'.
# - Reporters used 'ErrorLog,ServerDead'
#
# Comparison of the reporter pairs 'ErrorLog,ServerDead' to 'ErrorLog,Backtrace' if using the same
# whitelist_* setup like above:
# In short:
#   'ErrorLog,ServerDead'
#   - (huge)  Advantage:    increases the grammar simplification speed by ~ 100%
#   - (minor) Disadvantage: does not give the detailed backtrace we would get from 'Backtrace'
#                           So in case we need such a backtrace than we have to make (hopefully)
#                           just one RQG run using the simplified grammar and 'Backtrace'
#                           after RQG test simplification end.
#
# In detail:
#   The running DB server writes the message about the assert into the server error log.
#   --> whitelist_pattern match in both cases.
#   There will be also some rudimentary backtrace written.
#   Worst and also frequent seen case around GenTest_e end:
#      Certain threads detect that the communication to the server is completely broken but
#      do not feel sure enough about the server state.
#      So they set 100 (STATUS_CRITICAL_ERROR) or 110 (STATUS_ALARM) which mostly means that they
#      are unsure and hope that reporters could figure the right state out.
#      Compensating that by setting whitelist_statuses = STATUS_ANY_ERROR is doable but very
#      risky under certain conditions. 
#   So we need some reporter which is capable to detect if the server is 'dead'.
#   'ServerDead' and also 'Backtrace' are capable to figure that out.
#   Both check first if the server process exists (low resource consumption).
#   In case the server process has disappeared (quite likely) than
#   - 'ServerDead' returns immediate STATUS_SERVER_CRASHED
#   - 'Backtrace' searches for the core file (most time found) and generates than some detailed
#     backtrace with a debugger
#     This last operation lasts long (up till ~ 120s) and is extreme resource (CPU+IO) consuming.
#

sub report {
    if (defined $ENV{RQG_CALLBACK}) {
        return callbackReport(@_);
    } else {
        return nativeReport(@_);
    }
}

sub nativeReport {
    my $reporter = shift;

    my $error_log = $reporter->serverInfo('errorlog');
    say("error_log is $error_log");

    my $pid_file = $reporter->serverVariable('pid_file');
    say("pid_file is $pid_file");

    my $pid = $reporter->serverInfo('pid');

    my $server_running    = 1;
    my $wait_timeout      = 180;
    my $start_time        = Time::HiRes::time();
    my $max_end_time      = $start_time + $wait_timeout;
    while ($server_running and (Time::HiRes::time() < $max_end_time)) {
        sleep 1;
        $server_running = kill (0, $pid);
        say("DEBUG: server pid : $pid , server_running : $server_running");
    }
    if ($server_running) {
        say("INFO: Reporter 'ServerDead': The process of the DB server $pid is running. " .
            "Will return STATUS_OK.");
        return STATUS_OK;
    } else {
        say("INFO: Reporter 'ServerDead': The process of the DB server $pid is no more running. " .
            "Will return STATUS_SERVER_CRASHED.");
        return STATUS_SERVER_CRASHED;
    }

}

sub callbackReport {
    my $output = GenTest_e::CallbackPlugin::run("serverdead");
    say("$output");
    ## Need some incident interface here in the output from
    ## the callback
    return STATUS_OK, undef;
}

sub type {
    return REPORTER_TYPE_CRASH | REPORTER_TYPE_DEADLOCK;
}

1;
