# Copyright (C) 2016, 2021 MariaDB Corporation Ab.
# Copyright (C) 2023 MariaDB plc
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

# The module checks that after the test flow has finished,
# the server is able to restart successfully without losing any data

# It is supposed to be used with the native server startup,
# i.e. with runall-new.pl rather than runall.pl which is MTR-based.

package GenTest_e::Reporter::RestartConsistency;

# 1. Become active only after YY grammar processing and if current status == STATUS_OK.
#    This ensures that concurrent data modifying load will not happen.
# 2. Dump
# 3. Stop server via signal TERM (15)
# 4. Start server based on existing data
# 5. Inspect tables
# 6. Dump
# 7. Compare the dumps which were made before and after restart
# RestartConsistency and CrashRecovery* contain partially quite similar code.
# FIXME: Share the code


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

my $who_am_i = "Reporter 'RestartConsistency':";
my $first_reporter;
my $vardir;
my $errorlog_before;
my $errorlog_after;

sub report {
    my $reporter = shift;

    say("INFO: $who_am_i At begin of report.");

    # In case of two servers, we will be called twice.
    # Only kill the first server and ignore the second call.

    $first_reporter = $reporter if not defined $first_reporter;
    return STATUS_OK if $reporter ne $first_reporter;

    my $dsn = $reporter->dsn();
#   system("killall -9 mysqld");
#   sleep 3;
    my $executor = GenTest_e::Executor->newFromDSN($dsn);
    # Set the number to which server we will connect.
    # This number is
    # - used for more detailed messages only
    # - not used for to which server to connect etc. There only the dsn rules.
    # Hint:
    # Server id reported: n ----- dsn(n-1) !
    $executor->setId(1);
    $executor->setRole("RestartConsistency");
    # EXECUTOR_TASK_REPORTER ensures that max_statement_time is set to 0 for the current executor.
    # But this is not valid for the connection established by mysqldump!
    $executor->setTask(GenTest_e::Executor::EXECUTOR_TASK_REPORTER);
    my $status = $executor->init();
    return $status if $status != STATUS_OK;

    # Caused by whatever reasons we might meet other user sessions within the DB server which
    # - have initiated their disconnect but it is not yet finished
    #   IMHO not that likely, but if yes maybe defect in RQG core.
    # - have not yet initiated their disconnect
    #   Maybe defect in RQG core or caused by server freeze/deadlock.
    #   IMHO more likely, but if yes maybe also defect in RQG core or missing reporter Deadlock.
    # Hence either report + soft kill them here or handle in App/GenTest_e.pm.
    # IMHO unlikely worst case if this is omitted: Active user sessions change data and than dump
    # before and after shutdown+restart could differ --> false alarm.

    # Observation 2020-06:
    # dump_database fails because the limit max_statement_time = 30 kicks in.
    # And than we get finally STATUS_CRITICAL_FAILURE.
    # So given the fact that we are around test end we could manipulate the @global variable.

    # We need to glue $trace_addition to any statement which is not processed with
    # $executor->execute(<query>).
    my $trace_addition = '/* E_R ' . $executor->role . ' QNO 0 CON_ID ' .
                         $executor->connectionId() . ' */ ';

    my $query = '/*!100108 SET @@global.max_statement_time = 0 */';
    my $res = $executor->execute($query);
    $status = $res->status;
    if (STATUS_OK != $status) {
        my $err    = $res->err;
        my $errstr = $res->errstr;
        my $status = STATUS_CRITICAL_FAILURE;
        say("ERROR: $who_am_i Query ->" . $query . "<- failed with $err : $errstr " .
            Basics::return_status_text($status));
        return $status;
    }
    my $dbh = $executor->dbh();

    my $dump_return = dump_database($reporter,$executor,'before');
    if ($dump_return > STATUS_OK) {
        my $status = STATUS_CRITICAL_FAILURE;
        say("ERROR: $who_am_i Dumping the database failed with status $dump_return. " .
             Basics::return_status_text($status));
        return $status;
    }
    my $dump_return_before = $dump_return;
    $executor->disconnect();

    my $server = $reporter->properties->servers->[0];
    if ($server->stopServer != STATUS_OK) {
        my $status = STATUS_CRITICAL_FAILURE;
        say("ERROR: $who_am_i Stopping the DB server failed. " .  Basics::return_status_text($status));
        return $status;
    };

    my $datadir = $reporter->serverVariable('datadir');
    $datadir =~ s{[\\/]$}{}sgio;
    my $orig_datadir = $datadir.'_orig';

    my $engine = $reporter->serverVariable('storage_engine');

    say("INFO: $who_am_i Copying datadir... (interrupting the copy operation may cause investigation problems later)");
    if (osWindows()) {
        system("xcopy \"$datadir\" \"$orig_datadir\" /E /I /Q");
    } else {
        system("cp -r $datadir $orig_datadir");
    }
    $errorlog_before = $server->errorlog.'_orig';
    # move($server->errorlog, $server->errorlog.'_orig');
    move($server->errorlog, $errorlog_before);
    unlink("$datadir/core*");    # Remove cores from any previous crash

    say("INFO: $who_am_i Restarting server ...");

    $server->setStartDirty(1);
    my $recovery_status = $server->startServer();
    $errorlog_after = $server->errorlog;
    open(RECOVERY, $server->errorlog);

    while (<RECOVERY>) {
        $_ =~ s{[\r\n]}{}siog;
        say($_);
        if ($_ =~ m{registration as a STORAGE ENGINE failed.}sio) {
            say("ERROR: $who_am_i Storage engine registration failed");
            $recovery_status = STATUS_DATABASE_CORRUPTION;
        } elsif ($_ =~ m{corrupt|crashed}) {
            say("WARN: $who_am_i Log message '$_' might indicate database corruption");
        } elsif ($_ =~ m{exception}sio) {
            $recovery_status = STATUS_DATABASE_CORRUPTION;
        } elsif ($_ =~ m{ready for connections}sio) {
            say("INFO: $who_am_i Server restart was apparently successfull.")
                if $recovery_status == STATUS_OK ;
            last;
        } elsif ($_ =~ m{device full error|no space left on device}sio) {
            # Give a clear comment explaining on which facts the status STATUS_ENVIRONMENT_FAILURE
            # is based on.
            $recovery_status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: $who_am_i device full error or no space left on device found in server " .
                "error log. " . Basics::return_status_text($recovery_status));
            last;
        } elsif (
            ($_ =~ m{got signal}sio) ||
            ($_ =~ m{segfault}sio) ||
            ($_ =~ m{segmentation fault}sio)
        ) {
            say("ERROR: $who_am_i Recovery has apparently crashed.");
            $recovery_status = STATUS_DATABASE_CORRUPTION;
        }
    }

    close(RECOVERY);

    if ($recovery_status > STATUS_OK) {
        say("ERROR: $who_am_i Restart has failed. " . Basics::return_status_text($recovery_status));
        return $recovery_status;
    }

    $status = $executor->init();
    return $status if $status != STATUS_OK;
    $executor->setId(1);
    $executor->setRole("RestartConsistency");
    $executor->setTask(GenTest_e::Executor::EXECUTOR_TASK_REPORTER);
    $query = '/*!100108 SET @@global.max_statement_time = 0 */';
    $res = $executor->execute($query);
    $status = $res->status;
    if (STATUS_OK != $status) {
        my $err    = $res->err;
        my $errstr = $res->errstr;
        my $status = STATUS_DATABASE_CORRUPTION;
        say("ERROR: $who_am_i Query ->" . $query . "<- failed with $err : $errstr " .
            Basics::return_status_text($recovery_status));
        return $status;
    }

    #
    # Phase 2 - server is now running, so we execute various statements in order to verify table consistency
    #

    say("INFO: $who_am_i Testing database consistency");

    $trace_addition = '/* E_R ' . $executor->role . ' QNO 0 CON_ID ' .
                         $executor->connectionId() . ' */ ';
    $dbh = $executor->dbh;

    $query = "SHOW DATABASES $trace_addition";
    SQLtrace::sqltrace_before_execution($query);
    my $databases = $dbh->selectcol_arrayref($query);
    my $error = $dbh->err();
    SQLtrace::sqltrace_after_execution($error);
    if (defined $error) {
        $executor->disconnect();
        my $status = STATUS_CRITICAL_FAILURE;
        say("ERROR: $who_am_i ->" . $query . "<- failed with $error. " .
            Basics::return_status_text($status));
        return $status;
    }
    foreach my $database (@$databases) {
        next if $database =~ m{^(rqg|mysql|information_schema|pbxt|performance_schema)$}sio;
        $query = "USE $database $trace_addition";
        SQLtrace::sqltrace_before_execution($query);
        $dbh->do($query);
        $error = $dbh->err();
        SQLtrace::sqltrace_after_execution($error);
        if (defined $error) {
            $executor->disconnect();
            my $status = STATUS_CRITICAL_FAILURE;
            say("ERROR: $who_am_i ->" . $query . "<- failed with $error. " .
                Basics::return_status_text($status));
            return $status;
        }

        $query = "SHOW FULL TABLES $trace_addition";
        SQLtrace::sqltrace_before_execution($query);
        my $tabl_ref = $dbh->selectcol_arrayref($query, { Columns=>[1,2] });
        $error = $dbh->err();
        SQLtrace::sqltrace_after_execution($error);
        if (defined $error) {
            $executor->disconnect();
            my $status = STATUS_CRITICAL_FAILURE;
            say("ERROR: $who_am_i ->" . $query . "<- failed with $error. " .
                Basics::return_status_text($status));
            return $status;
        }

        my %tables = @$tabl_ref;
        foreach my $table (keys %tables) {
            # Should not do CHECK etc., and especially ALTER, on a view
            next if $tables{$table} eq 'VIEW';
            my $db_table = "`$database`.`$table`";
            say("INFO: $who_am_i Verifying table: $db_table");
            $query = "CHECK TABLE $db_table EXTENDED $trace_addition";
            SQLtrace::sqltrace_before_execution($query);
            $dbh->do($query);
            $error = $dbh->err();
            SQLtrace::sqltrace_after_execution($error);
            if (defined $error and $error > 0) {
                my $message_part = "$who_am_i ->" . $query . "<- failed with $error.";
                if ($error != 1178) {
                    $executor->disconnect();
                    say("ERROR: " . $message_part);
                    return STATUS_DATABASE_CORRUPTION;
                } else {
                    # 1178 is ER_CHECK_NOT_IMPLEMENTED
                    say("INFO: " . $message_part);
                }
            }
        }
    }
    say("INFO: $who_am_i Schema does not look corrupt");

    #
    # Phase 3 - dump the server again and compare dumps
    #
    $dump_return = dump_database($reporter,$executor,'after');
    if ($dump_return > STATUS_OK) {
        $executor->disconnect();
        my $status = STATUS_CRITICAL_FAILURE;
        say("ERROR: $who_am_i Dumping the database failed with status $dump_return. " .
             Basics::return_status_text($status));
        return $status;
    }
    my $dump_return_after = $dump_return;
    if($dump_return_before != $dump_return_after) {
        $executor->disconnect();
        my $status = STATUS_DATABASE_CORRUPTION;
        say("ERROR: dump_return_before($dump_return_before) and dump_return_after(" .
            "$dump_return_after) differ. " . Basics::return_status_text($status));
        return $status;
    }
    $executor->disconnect();

    return compare_dumps();
}


sub dump_database {
    # Suffix is "before" or "after" (restart)
    my ($reporter, $executor, $suffix) = @_;

    my $port = $reporter->serverVariable('port');
    $vardir = $reporter->properties->servers->[0]->vardir() unless defined $vardir;

    my $trace_addition = '/* E_R ' . $executor->role . ' QNO 0 CON_ID ' .
                         $executor->connectionId() . ' */ ';
    my $query = "SHOW DATABASES $trace_addition";
    SQLtrace::sqltrace_before_execution($query);
    my @all_databases = @{$executor->dbh->selectcol_arrayref($query)};
    my $dbh = $executor->dbh;
    my $error = $dbh->err();
    SQLtrace::sqltrace_after_execution($error);
    if (defined $error) {
        $dbh->disconnect();
        my $status = STATUS_CRITICAL_FAILURE;
        say("ERROR: $who_am_i ->" . $query . "<- failed with $error. " .
            Basics::return_status_text($status));
        return $status;
    }
    my $databases_string = join(' ', grep { $_ !~ m{^(rqg|mysql|information_schema|performance_schema)$}sgio } @all_databases );

    # FIXME: Replace what follows by calling a function located in lib/DBServer_e/MySQL/MySQLd.pm.
    say("INFO: $who_am_i Dumping the server $suffix restart");
    # From the manual https://mariadb.com/kb/en/library/mysqldump
    # -f, --force
    #     Continue even if an SQL error occurs during a table dump like damaged views.
    #     With --force, mysqldump prints the error message, but it also writes an SQL comment
    #     containing the view definition to the dump output and continues executing.
    # --log-error=name
    #     Log warnings and errors by appending them to the named file. The default is to do no logging.
    my $dump_file =     "$vardir/server_$suffix.dump";
    my $dump_err_file = "$vardir/server_$suffix.dump_err";
    my $dump_result = system('"' . $reporter->serverInfo('client_bindir') . "/mysqldump\" "        .
                             "--force --hex-blob --no-tablespaces --compact --order-by-primary "   .
                             "--skip-extended-insert --host=127.0.0.1 --port=$port --user=root "   .
                             "--password='' --skip-ssl-verify-server-cert "                        .
                             "--databases $databases_string > $dump_file 2>$dump_err_file ");
    $dump_result = $dump_result >> 8;
    if (0 < $dump_result) {
        say("ERROR: $who_am_i Dumping the server $suffix restart failed with $dump_result.");
        sayFile($dump_err_file);
        return STATUS_ENVIRONMENT_FAILURE;
    } else {
        return STATUS_OK;
    }
}

sub compare_dumps {
    say("INFO: $who_am_i Comparing SQL dumps between servers before and after restart...");
    # FIXME: Replace what follows by calling a function located in lib/DBServer_e/MySQL/MySQLd.pm.
    # Diff in line  ) ENGINE= ... AUTO_INCREMENT=...
    # but the CREATE TABLE .... <table_name> .... line is not included.
    # - <table_name> would be important for search in server error log.
    # - diff -u leads to 3 lines context only. ~ 50 lines would be better.
    # Its not unlikely that the before restart server error log shows trouble around <table_name>
    # but that server error log does not get printed at all.
    # A print of the server error log after the restart is most probably less important
    # because already checked above but
    # - the checks might have become weak (outdated search patterns)
    # - that error log shouldn't be that long.
    # In general
    # In case we have a failing test than printing up to a few thousand lines more into the
    # RQG log makes the inspection easier.
    # Use a solution like
    # - in Elena's lib/GenTest_e/Reporter/Upgrade.pm
    # or
    # - a routine in lib/Auxiliary which egalizes dump content which differs usually between
    #   master and slave in "full" replication like
    #   - event if enabled or disabled
    #   - the number after AUTO_INCREMENT
    my $dump_before = $vardir . '/server_before.dump';
    my $dump_after  = $vardir . '/server_after.dump';
    my $diff_result = system("diff -U 50 $dump_before $dump_after");
    $diff_result = $diff_result >> 8;

    if ($diff_result == 0) {
		say("INFO: $who_am_i No differences between server contents before and after restart.");
		return STATUS_OK;
    } else {
		say("WARN: $who_am_i Dumps before and after shutdown+restart differ.");
        my $dump_before_egalized = $dump_before . "_e";
        my $dump_after_egalized =  $dump_after  . "_e";
        Auxiliary::egalise_dump ($dump_before, $dump_before_egalized);
        Auxiliary::egalise_dump ($dump_after,  $dump_after_egalized);
	    my $diff_result_egalized = system("diff -U 50 $dump_before_egalized $dump_after_egalized");
	    $diff_result_egalized = $diff_result_egalized >> 8;
        if ($diff_result_egalized == 0) {
            say("INFO: $who_am_i After egalizing: No differences between server contents before and after restart.");
            return STATUS_OK;
        } else {
            say("ERROR: $who_am_i After egalizing: Server content has changed after shutdown+restart.");
		    return STATUS_DATABASE_CORRUPTION;
        }
	}
}

sub type {
    # REPORTER_TYPE_SUCCESS runs only
    # after YY grammar processing and if current status == STATUS_OK.
    return REPORTER_TYPE_SUCCESS ;
}

1;
