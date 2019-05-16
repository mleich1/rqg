# Copyright (C) 2013 Monty Program Ab
# Copyright (C) 2019 MariaDB Corporation Ab.
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
package GenTest::Reporter::CrashRecovery1;

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use DBI;
use GenTest;
use GenTest::Constants;
use GenTest::Reporter;
use GenTest::Comparator;
use Data::Dumper;
use IPC::Open2;
use File::Copy;
use POSIX;

use DBServer::MySQL::MySQLd;

my $first_reporter;

my $who_am_i = "Reporter 'CrashRecovery1':";

sub monitor {
    my $reporter = shift;

    # In case of two servers, we will be called twice.
    # Only kill the first server and ignore the second call.

    $first_reporter = $reporter if not defined $first_reporter;
    return STATUS_OK if $reporter ne $first_reporter;

    my $pid = $reporter->serverInfo('pid');

    if (time() > $reporter->testEnd() - 19) {
    my $kill_msg = "$who_am_i Sending SIGKILL to server with pid $pid in order to force a crash.";
        say("INFO: $kill_msg");
        kill(9, $pid);
        return STATUS_SERVER_KILLED;
    } else {
        return STATUS_OK;
    }
}

sub report {
    my $reporter = shift;

    alarm(3600);

    $first_reporter = $reporter if not defined $first_reporter;
    return STATUS_OK if $reporter ne $first_reporter;

    my $datadir = $reporter->serverVariable('datadir');
    $datadir =~ s{[\\/]$}{}sgio;
    my $orig_datadir = $datadir.'_orig';
    my $pid = $reporter->serverInfo('pid');

    # Docu 2019-05
    # storage_engine
    # Description: See default_storage_engine.
    # Deprecated: MariaDB 5.5
    my $engine = $reporter->serverVariable('storage_engine');

    my $dbh_prev = DBI->connect($reporter->dsn());

    # FIXME
    # 1. Shouldn't be the server already dead caused by calling monitor.
    # 2. What if killing does not work? Probably minpr problem
    # 3. What if the server is already dead because of other reason than calling monitor above?
    if (defined $dbh_prev) {
        # Server is still running, kill it. Again.
        $dbh_prev->disconnect();

        my $kill_msg = "$who_am_i Sending SIGKILL to server with pid $pid in order to force a crash.";
        say("INFO: $kill_msg");
        kill(9, $pid);
        sleep(5);
    }

    my $server = $reporter->properties->servers->[0];
    say("INFO: $who_am_i Copying datadir... (interrupting the copy operation may cause " .
        "investigation problems later)");
    if (osWindows()) {
        system("xcopy \"$datadir\" \"$orig_datadir\" /E /I /Q");
    } else {
        system("cp -r $datadir $orig_datadir");
    }
    move($server->errorlog, $server->errorlog.'_orig');
    unlink("$datadir/core*");    # Remove cores from any previous crash

    say("INFO: $who_am_i Attempting database recovery using the server ...");

    $server->setStartDirty(1);
    my $recovery_status = $server->startServer();
    if ($recovery_status > STATUS_OK) {
        say("ERROR: $who_am_i Status based on server start attempt is $recovery_status");
    }

    # We look into the server error log even if the start attempt failed!
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
            if ($recovery_status == STATUS_OK) {
                say("INFO: $who_am_i Server Recovery was apparently successfull.");
            }
            last;
        } elsif ($_ =~ m{device full error|no space left on device}sio) {
            say("ERROR: $who_am_i Filesystem full");
            $recovery_status = STATUS_ENVIRONMENT_FAILURE;
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
        say("ERROR: $who_am_i Status based on error log checking is $recovery_status");
    }

    # We try to connect independent of the actual history and report everything.
    # In case of rather unlikely events like
    # - start exits with != 0 but server process runs
    # - start exits with 0 but the server error contains a critical string like 'crashed'
    # and similar show up than this means that we have either
    # - a serious new bug in the server
    # or
    # - a serious change of behaviour in the server and the current and other reporters
    #   cannot be trusted any more because probably needing heavy adjustments
    # ...
    my $dbh = DBI->connect($reporter->dsn());
    if (not defined $dbh) {
        say("ERROR: $who_am_i Connect attempt to dsn " . $reporter->dsn() . " after " .
            "restart+recovery failed: " . $DBI::errstr);
    }

    if (not defined $dbh or $recovery_status > STATUS_OK) {
        say("ERROR: $who_am_i Recovery has failed. Will return status STATUS_DATABASE_CORRUPTION");
        return STATUS_DATABASE_CORRUPTION;
    }

    #
    # Phase 2 - server is now running, so we execute various statements in order to verify table consistency
    #

    # FIXME
    # Add more checks like dumping
    # - all object (schema, table, procedure, view ...) definitions
    # - all data in base tables
    # In case the dump operation fails than we have hit a failure in (incomplete list)
    # - corrupt object definitions/permissions(??)
    #   The walk queries might be already capable to detect certain defects around table definitions
    #   but not all. And a defect VIEW/PROCEDURE/permission/... could lead to some disaster too!
    # - mysqldump (extreme rare because there is no parallel load at all)
    # - free space problem in filesystem (rare if using ResourceControl in parallel)
    say("INFO: $who_am_i Testing database consistency");

    my $databases = $dbh->selectcol_arrayref("SHOW DATABASES");
    foreach my $database (@$databases) {
        next if $database =~ m{^(mysql|information_schema|pbxt|performance_schema)$}sio;
        $dbh->do("USE $database");
        my $tabl_ref = $dbh->selectcol_arrayref("SHOW FULL TABLES", { Columns=>[1,2] });
        my %tables   = @$tabl_ref;
        foreach my $table (keys %tables) {
            my $table_to_check = "`$database`.`$table`";
            say("Verifying table: $table_to_check");

            my $stmt     = "SHOW KEYS FROM $table_to_check";
            my $sth_keys = $dbh->prepare($stmt);

            $sth_keys->execute();

            # 2019-05-15 mleich1 Observations with previous version of 'RestartRecovery'
            # DBD::mysql::st execute failed:
            #     Table 'test.r' doesn't exist in engine at ... CrashRecovery.pm line 163.
            # DBD::mysql::st fetchrow_hashref failed:
            #     fetch() without execute() at ... CrashRecovery.pm line 167.
            # SHOW KEYS FROM `test`.`view_table2_innodb_int_autoinc` harvested 1356:
            #     View ... references invalid table(s) or column(s) or function(s) or ...
            my $err    = $sth_keys->err();
            my $errstr = '';
            $errstr    = $sth_keys->errstr() if defined $sth_keys->errstr();
            if (defined $err) {
                if (1356 == $err) {
                    say("INFO: $table_to_check is a damaged VIEW. Omitting the walk_queries");
                    next;
                } else {
                    say("ERROR: $stmt harvested $err: $errstr. " .
                        "Will return status STATUS_RECOVERY_FAILURE");
                    return STATUS_RECOVERY_FAILURE;
                }
            }

            my @walk_queries;

            while (my $key_hashref = $sth_keys->fetchrow_hashref()) {
                my $key_name = $key_hashref->{Key_name};
                my $column_name = $key_hashref->{Column_name};

                foreach my $select_type ('*' , "`$column_name`") {
                    my $main_predicate;
                    if ($column_name =~ m{int}sio) {
                        $main_predicate = "WHERE `$column_name` >= -9223372036854775808";
                    } elsif ($column_name =~ m{char}sio) {
                        $main_predicate = "WHERE `$column_name` = '' OR `$column_name` != ''";
                    } elsif ($column_name =~ m{date}sio) {
                        $main_predicate = "WHERE (`$column_name` >= '1900-01-01' OR " .
                                          "`$column_name` = '0000-00-00') ";
                    } elsif ($column_name =~ m{time}sio) {
                        $main_predicate = "WHERE (`$column_name` >= '-838:59:59' OR " .
                                          "`$column_name` = '00:00:00') ";
                    } else {
                        next;
                    }

                    if ($key_hashref->{Null} eq 'YES') {
                        $main_predicate = $main_predicate . " OR `$column_name` IS NULL" .
                                          " OR `$column_name` IS NOT NULL";
                    }

                    push @walk_queries, "SELECT $select_type FROM $table_to_check " .
                                        "FORCE INDEX (`$key_name`) " . $main_predicate;
                }
            };

            my %rows;
            my %data;

            foreach my $walk_query (@walk_queries) {
                my $sth_rows = $dbh->prepare($walk_query);
                $sth_rows->execute();

                my $err    = $sth_rows->err();
                my $errstr = '';
                $errstr    = $sth_rows->errstr() if defined $sth_rows->errstr();

                if (defined $sth_rows->err()) {
                    say("ERROR: $walk_query harvested $err: $errstr. " .
                        "Will return status STATUS_RECOVERY_FAILURE");
                    return STATUS_RECOVERY_FAILURE;
                }

                my $rows = $sth_rows->rows();
                $sth_rows->finish();

                push @{$rows{$rows}} , $walk_query;
            }

            if (keys %rows > 1) {
                say("ERROR: $who_am_i Table $table_to_check is inconsistent.");
                print Dumper \%rows;

                my @rows_sorted = grep { $_ > 0 } sort keys %rows;

                my $least_sql = $rows{$rows_sorted[0]}->[0];
                my $most_sql  = $rows{$rows_sorted[$#rows_sorted]}->[0];

                say("Query that returned least rows: $least_sql\n");
                say("Query that returned most rows: $most_sql\n");

                my $least_result_obj = GenTest::Result->new(
                    data => $dbh->selectall_arrayref($least_sql)
                );

                my $most_result_obj = GenTest::Result->new(
                    data => $dbh->selectall_arrayref($most_sql)
                );

                say(GenTest::Comparator::dumpDiff($least_result_obj, $most_result_obj));

                $recovery_status = STATUS_DATABASE_CORRUPTION;
            }

            # Should not do CHECK etc., and especially ALTER, on a view
            next if $tables{$table} eq 'VIEW';

            foreach my $sql (
                "CHECK TABLE $table_to_check EXTENDED",
                "ANALYZE TABLE $table_to_check",
                "OPTIMIZE TABLE $table_to_check",
                "REPAIR TABLE $table_to_check EXTENDED",
                # mleich 2019-05
                # $engine is set above to the server default storage engine.
                # Given the fact that
                # - we abort currently in case this ALTER fails
                # - there is a good share of natural reasons why this could fail
                #   Example: Too small page size
                #   ok, we can treat all like the errors 1178, 1969 below
                # I prefer to not make some half arbitrary engine switch which
                # might in unfortunate cases look as if crash recovery failed.
                # I assume that the original intention was to enforce a table rebuild in order
                # to catch inconsistencies between the content of the triple
                #    Server DD - InnoDB DD if the SE has its own DD - data in the table tree
                # and similar.
                # Docu(edited):
                #    In MariaDB 5.5 and before only "ALTER TABLE tab_name ENGINE = <engine>;"
                #    rebuilds a base table.
                #    In MariaDB 10.0 and later "ALTER TABLE tab_name FORCE;" could be used instead.
                # Advantage of the latter:
                # No risk of hitting a fail from natural reason like mentioned above.
                # Slight disadvantage of enforcing a table rebuild at all:
                #    Depending on the SE one of the CHECK/ANALYZE/... might have already done so.
                # "ALTER TABLE $table_to_check ENGINE = $engine"
                "ALTER TABLE $table_to_check FORCE",
            ) {
                say("INFO: $who_am_i Executing $sql.");
                my $sth = $dbh->prepare($sql);
                if (defined $sth) {
                    $sth->execute();

                    # mleich 2019-05-15 Observation
                    # 1. No report of error number or string
                    # 2. STATUS_DATABASE_CORRUPTION thrown for harmless/natural states
                    my $err    = $sth->err();
                    my $errstr = '';
                    $errstr    = $sth->errstr() if defined $sth->errstr();

                    if (defined $err) {
                        if ( 1178 == $err or
                             1969 == $err   ) {
                             # 1178, "The storage engine for the table doesn\'t support ...
                             # 1969, "Query execution was interrupted (max_statement_time exceeded
                            say("DEBUG: $sql harvested harmless $errstr.");
                            next;
                        } else {
                            say("ERROR: $stmt harvested $err: $errstr. " .
                                "Will return STATUS_DATABASE_CORRUPTION");
                            return STATUS_DATABASE_CORRUPTION;
                        }
                    }

                    if ($sth->{NUM_OF_FIELDS} > 0) {
                        my $result = Dumper($sth->fetchall_arrayref());
                        next if $result =~ m{is not BASE TABLE}sio;    # Do not process VIEWs
                        if ($result =~ m{error'|corrupt|repaired|invalid|crashed}sio) {
                            print $result;
                            say("ERROR: Failures found in the output above. " .
                                "Will return STATUS_DATABASE_CORRUPTION");
                            return STATUS_DATABASE_CORRUPTION
                        }
                    };

                    $sth->finish();
                } else {
                    say("ERROR: $who_am_i Prepare failed: " . $dbh->errrstr() .
                        "Will return STATUS_DATABASE_CORRUPTION");
                    return STATUS_DATABASE_CORRUPTION;
                }
            }
        }
    }

    say("INFO: $who_am_i No failures found. Will return STATUS_OK");
    return STATUS_OK;
}

sub type {
    # return REPORTER_TYPE_ALWAYS | REPORTER_TYPE_PERIODIC;
    return REPORTER_TYPE_ALWAYS | REPORTER_TYPE_PERIODIC;
}

1;
