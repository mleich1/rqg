# Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
# Copyright (C) 2016, 2022 MariaDB Corporation AB.
# Copyright (C) 2023 MariaDB plc
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

package GenTest_e::Reporter::ReplicationSlaveStatus;

require Exporter;
@ISA = qw(GenTest_e::Reporter);

use strict;
use DBI;
use GenTest_e;
use GenTest_e::Constants;
use GenTest_e::Reporter;
#use Data::Dumper;
#use IPC::Open2;
#use POSIX;

use DBServer_e::MySQL::MySQLd;

# "SHOW SLAVE STATUS" result set of some slave server in positive state
# Slave_IO_State
# Master_Host       127.0.0.1
# Master_User       root
# Master_Port       16000
# Connect_Retry       1
# Master_Log_File       master-bin.000001       5 (Index starts with 0)
# Read_Master_Log_Pos       1579
# Relay_Log_File       slave-relay-bin.000002
# Relay_Log_Pos       1879
# Relay_Master_Log_File       master-bin.000001
# Slave_IO_Running       No
# Slave_SQL_Running       No
# Replicate_Do_DB
# Replicate_Ignore_DB
# Replicate_Do_Table
# Replicate_Ignore_Table
# Replicate_Wild_Do_Table
# Replicate_Wild_Ignore_Table
# Last_Errno       0
# Last_Error
# Skip_Counter       0
# Exec_Master_Log_Pos       1579
# Relay_Log_Space       2188
# Until_Condition       None
# Until_Log_File
# Until_Log_Pos       0
# Master_SSL_Allowed       No
# Master_SSL_CA_File
# Master_SSL_CA_Path
# Master_SSL_Cert
# Master_SSL_Cipher
# Master_SSL_Key
# Seconds_Behind_Master       NULL
# Master_SSL_Verify_Server_Cert       No
# Last_IO_Errno       0
# Last_IO_Error
# Last_SQL_Errno       0
# Last_SQL_Error
# Replicate_Ignore_Server_Ids
# Master_Server_Id       1
# Master_SSL_Crl
# Master_SSL_Crlpath
# Using_Gtid       No
# Gtid_IO_Pos
# Replicate_Do_Domain_Ids
# Replicate_Ignore_Domain_Ids
# Parallel_Mode       optimistic
# SQL_Delay       0
# SQL_Remaining_Delay       NULL
# Slave_SQL_Running_State
# Slave_DDL_Groups       6
# Slave_Non_Transactional_Groups       1
# Slave_Transactional_Groups       0

use constant MASTER_LOG_FILE                =>  5;
use constant SLAVE_STATUS_LAST_ERRNO        => 19;
use constant SLAVE_STATUS_LAST_ERROR        => 20;
use constant SLAVE_STATUS_LAST_IO_ERRNO     => 34;
use constant SLAVE_STATUS_LAST_IO_ERROR     => 35;
use constant SLAVE_STATUS_LAST_SQL_ERRNO    => 36;
use constant SLAVE_STATUS_LAST_SQL_ERROR    => 37;
use constant MASTER_SERVER_ID               => 39;

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
                    Basics::return_status_text($status));

    }
    # We connect to the slave DB server!
    my $server =   $reporter->properties->servers->[1];
    my $pid =      $server->pid();
    my $dsn =      $server->dsn();
    my $executor = GenTest_e::Executor->newFromDSN($dsn);
    $executor->setId(2);
    $executor->setRole("ReplicationSlaveStatus");
    $executor->setTask(GenTest_e::Executor::EXECUTOR_TASK_REPORTER);
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
        say("ERROR: $who_am_i " . Basics::return_status_text($status));
        return $status;
    }

    # system("kill -9 $pid; sleep 5") if not $first_connect;
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
        say("ERROR: $who_am_i " . Basics::return_status_text($status));
        return $status;
    }
    $first_connect = 0;
    # system("kill -9 $pid; sleep 5") if not $first_connect;
    my $slave_status = $res->data;

    my @result_row_ref_array = @{$res->data};
    # system("kill -9 $pid; sleep 1") if not $first_connect;
    my @status_row = @{$result_row_ref_array[0]};

    my $master_log_file = $status_row[MASTER_LOG_FILE];
    my $last_io_error   = $status_row[SLAVE_STATUS_LAST_IO_ERROR];
    my $last_sql_error  = $status_row[SLAVE_STATUS_LAST_SQL_ERROR];
    my $last_error      = $status_row[SLAVE_STATUS_LAST_ERROR];
    my $master_server_id= $status_row[MASTER_SERVER_ID];
    $executor->disconnect();

#   say("DEBUG: $who_am_i master_log_file ->" . $master_log_file . "<-, last_io_error ->" .
#       $last_io_error . "<-, last_sql_error ->" .  $last_sql_error . "<-, last_error ->" .
#       $last_error . "<-, master_server_id ->" . $master_server_id . "<-");

    # Corrected for
    # 10.11 2022-12 $last_error is a string if defined
    # 10.6 2022-12 $last_error is string if defined and '0' if no error
    if (defined $last_error and $last_error ne '0' and $last_error ne '') {
        if  (defined $last_io_error and $last_io_error ne '0' and $last_io_error ne '') {
            say("ERROR: $who_am_i Slave IO thread has stopped with error: " . $last_io_error);
        }
        if (defined $last_sql_error and $last_sql_error ne '0' and $last_sql_error ne '') {
            say("ERROR: $who_am_i Slave SQL thread has stopped with error: " . $last_sql_error);
        }
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
