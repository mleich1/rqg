# Copyright (C) 2013 Monty Program Ab
# Copyright (C) 2019, 2022 MariaDB Corporation Ab.
# Copyright (C) 2023, 2024 MariaDB plc
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


# The module is based on the traditional Recovery.pm,
# but the new one restarts the server in exactly the same way
# (with the same options) as it was initially running

# It is supposed to be used with the native server startup,
# i.e. with runall-new.pl rather than runall.pl which is MTR-based.

# This is some extended clone of GenTest::Reporter::CrashRecovery
package GenTest_e::Reporter::CrashRecovery;

# It is intentional that most failures are declared to be STATUS_RECOVERY_FAILURE.

require Exporter;
@ISA = qw(GenTest_e::Reporter);

use strict;
use DBI;
use GenTest_e;
use GenTest_e::Constants;
use GenTest_e::Reporter;
use GenTest_e::Comparator;
use Data::Dumper;
use IPC::Open2;
use File::Copy;
use POSIX;

use DBServer_e::MySQL::MySQLd;

my $first_reporter;
my $omit_reporting = 0;

my $who_am_i = "Reporter 'CrashRecovery':";

my $first_monitoring = 1;
sub monitor {
    my $reporter = shift;

    # In case of two servers, we will be called twice.
    # Only kill the first server and ignore the second call.
    $first_reporter = $reporter if not defined $first_reporter;
    return STATUS_OK if $reporter ne $first_reporter;

    my $pid = $reporter->serverInfo('pid');

    if ($first_monitoring) {
        say("INFO: $who_am_i First monitoring");
        $first_monitoring = 0;
    }
    my $server = $reporter->properties->servers->[0];
    # For debugging:
    # system("killall -9 mysqld; sleep 1");
    if (not $reporter->properties->servers->[0]->running()) {
        say("ERROR: $who_am_i The server is not running though it should.");
        exit STATUS_SERVER_CRASHED;
    }
    # Making some connect attempt and only in case of success going on might look attractive.
    # But that attempt might maybe last longer than 19s. And than all worker threads would have
    # disconnected and the crash is maybe too harmless.
    # In addition the reporter "Deadlock" will also try to connect.
    if (time() > $reporter->testEnd() - 19) {
        my $kill_msg = "$who_am_i Sending SIGKILL to server with pid $pid in order to force a crash.";
        say("INFO: $kill_msg");
        # Do not use $server->killServer here because it might cause trouble within the GenTest_e.pm
        # OUTER loop like
        # 1. killServer starts
        # 2. worker threads detect that the server is dead and exit
        # 3. we leave the OUTER loop
        # 4. all worker threads have exited (probably already earlier) and caused that the maximum
        #    status is set to STATUS_CRITICAL_FAILURE
        # 5. killServer and its caller Reporter 'CrashRecovery' have not finished yet.
        # 6. GenTest_e causes that the periodic reporting process == CrashRecovery gets stopped
        #    and somehow the status does not get raised to STATUS_SERVER_KILLED.
        # 7. The Endreporter Backtrace comes and raises the status to some misleading
        #    STATUS_SERVER_CRASHED
        kill(9, $pid);
        # "exit" in order to prevent that worker threads or successing reporters have any chance
        # to change the status.
        exit STATUS_SERVER_KILLED;
    } else {
        return STATUS_OK;
    }
}

sub report {
    my $reporter = shift;

    alarm(3600);

    $first_reporter = $reporter if not defined $first_reporter;
    return STATUS_OK if $reporter ne $first_reporter;

    say("INFO: $who_am_i Reporting ...");
    # Wait till the kill is finished + rr traces are written + the auxpid has disappeared.
    our $server = $reporter->properties->servers->[0];
    my $status = $server->killServer;
    if (STATUS_OK != $status) {
        $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i cleaning up the killed server failed with status $status. " .
            Basics::exit_status_text($status));
        exit $status;
    }

    # Docu 2019-05
    # storage_engine
    # Description: See default_storage_engine.
    # Deprecated: MariaDB 5.5
    my $engine = $reporter->serverVariable('storage_engine');

    my $backup_status = $server->backupDatadir();
    if (STATUS_OK != $backup_status) {
        $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i The file backup failed. " .
            Basics::return_status_text($status));
        return $status;
    }

    say("INFO: $who_am_i Attempting database recovery using the server ...");

    # Using some buffer-pool-size which is smaller than before should work.
    # InnoDB page sizes >= 32K need in minimum a buffer-pool-size >=24M.
    # But going with that is impossible because we could end up with
    # [Warning] InnoDB: Difficult to find free blocks in the buffer pool (21 search iterations)!
    #                   21 failed attempts to flush a page!
    #                   Consider increasing innodb_buffer_pool_size.
    # 2021-01-11T12:33:32 [938407] | 2021-01-11 12:30:46 0 [Note] InnoDB: To recover: 105 pages from log
    # 2021-01-11T12:33:32 [938407] | 2021-01-11 12:31:05 0 [Note] InnoDB: To recover: 104 pages from log
    # 2021-01-11T12:33:32 [938407] | Killed
    # 600s restart_timeout exceeded --> RQG gives up.
    # $server->addServerOptions(['--innodb-buffer-pool-size=24M']);

    $server->setStartDirty(1);
    my $recovery_status = $server->startServer();
    # In case $server->startServer failed than it makes a backtrace + cleanup.
    # The error log will get also checked.
    if ($recovery_status > STATUS_OK) {
        if ($recovery_status == STATUS_SERVER_CRASHED or    # Real crash + backtrace
            $recovery_status == STATUS_CRITICAL_FAILURE) {  # Timeout exceeded, kill + backtrace
            say("DEBUG: $who_am_i Serious trouble during server restart. Hence setting " .
                "recovery_status STATUS_RECOVERY_FAILURE.");
            $recovery_status = STATUS_RECOVERY_FAILURE;
        }
        say("ERROR: $who_am_i Status based on server start attempt is $recovery_status");
    } else {
        $reporter->updatePid();
        say("INFO: $who_am_i " . $$ . " Server pid updated to ". $reporter->serverInfo('pid') . ".");
    }

    # The RQG runner rqg.pl will later run DBServer_e::MySQL::MySQLd::checkDatabaseIntegrity
    # with walkqueries, CHECK TABLE etc.
    # So the final status might be STATUS_SERVER_CORRUPTION even though some imperfect recovery
    # caused that.

    return $status;
}

sub type {
    return REPORTER_TYPE_PERIODIC | REPORTER_TYPE_SERVER_KILLED ;
}

1;
