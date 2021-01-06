# Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
# Copyright (C) 2016, 2021 MariaDB Corporation AB.
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

package GenTest::Reporter::ReplicationSlaveStatus;

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use DBI;
use GenTest;
use GenTest::Constants;
use GenTest::Reporter;
#use GenTest::Comparator;
#use Data::Dumper;
#use IPC::Open2;
#use File::Copy;
#use POSIX;

use DBServer::MySQL::MySQLd;

use constant SLAVE_STATUS_LAST_ERROR        => 19;
use constant SLAVE_STATUS_LAST_SQL_ERROR    => 35;
use constant SLAVE_STATUS_LAST_IO_ERROR     => 38;

my $first_reporter;

my $who_am_i = "Reporter 'ReplicationSlaveStatus':";
sub monitor {
    my $reporter = shift;
    status($reporter);
}

sub report {
    my $reporter = shift;
    status($reporter);
}

my $first_connect = 1;
sub status {
    my $reporter = shift;

    alarm(3600);

    $first_reporter = $reporter if not defined $first_reporter;
    return STATUS_OK if $reporter ne $first_reporter;

    if (not defined $reporter->properties->servers->[1]) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("ERROR: $who_am_i reporter->properties->servers->[1] is not defined. " .
                    Auxiliary::build_wrs($status));

    }
    # We connect to the slave DB server!
    my $server = $reporter->properties->servers->[1];
    my $pid =    $server->pid();
    my $dsn = $server->dsn();
    my $executor = GenTest::Executor->newFromDSN($dsn);
    $executor->setId(2);
    $executor->setRole("ReplicationSlaveStatus1");
    $executor->setTask(GenTest::Executor::EXECUTOR_TASK_REPORTER);
    $executor->sqltrace('MarkErrors');
    my $status = $executor->init();
    if ($status != STATUS_OK) {
        $executor->disconnect();
        my $message_part = "ERROR: $who_am_i No connection to server 2 got";
        if ($first_connect) {
            $message_part .= " and never had one before. Assuming INTERNAL ERROR.";
            $status = STATUS_INTERNAL_ERROR;
        } else {
            $message_part .= ". Assuming slave server freeze/crash/dysfunction caused by " .
                             "replication failure.";
            $status = STATUS_REPLICATION_FAILURE;
        }
        say($message_part);
        say("ERROR: $who_am_i " . Auxiliary::build_wrs($status));
        return $status;
    }

    #   system("kill -9 $pid; sleep 5") if not $first_connect;
    my $query = "SHOW SLAVE STATUS";
    my $res = $executor->execute($query);
    $status = $res->status;
    if (STATUS_OK != $status) {
        my $err    = $res->err;
        my $errstr = $res->errstr;
        my $message_part = "ERROR: $who_am_i Query ->" . $query . "<- failed with $err : $errstr";
        if ($first_connect) {
            $message_part .= " when running it first time on slave. Assuming INTERNAL ERROR.";
            $status = STATUS_INTERNAL_ERROR;
        } else {
            $message_part .= ". Assuming slave server freeze/crash/dysfunction caused by " .
                             "replication failure.";
            $status = STATUS_REPLICATION_FAILURE;
        }
        $executor->disconnect();
        say($message_part);
        say("ERROR: $who_am_i " . Auxiliary::build_wrs($status));
        return $status;
    }
    $first_connect = 0;
    my $slave_status = $res->data;

    my @result_row_ref_array = @{$res->data};
    my @status_row = @{$result_row_ref_array[0]};
    my $last_io_error  = $status_row[SLAVE_STATUS_LAST_IO_ERROR];
    my $last_sql_error = $status_row[SLAVE_STATUS_LAST_SQL_ERROR];
    my $last_error     = $status_row[SLAVE_STATUS_LAST_ERROR];
    $executor->disconnect();

    if      (defined $last_io_error and $last_io_error ne '') {
        say("ERROR: $who_am_i Slave IO thread has stopped with error: " . $last_io_error);
        return STATUS_REPLICATION_FAILURE;
    } elsif (defined $last_sql_error and $last_sql_error ne '') {
        say("ERROR: $who_am_i Slave SQL thread has stopped with error: " . $last_sql_error);
        return STATUS_REPLICATION_FAILURE;
    } elsif (defined $last_error and $last_error ne '') {
        say("ERROR: $who_am_i Slave has stopped with error: " . $last_error);
        return STATUS_REPLICATION_FAILURE;
    } else {
        return STATUS_OK;
    }

}

sub type {
    return REPORTER_TYPE_PERIODIC | REPORTER_TYPE_SUCCESS;
}

1;
