# Copyright (C) 2013 Monty Program Ab
# Copyright (C) 2019, 2022  MariaDB Corporation Ab.
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

    # Wait till the kill is finished + rr traces are written + the auxpid has disappeared.
    my $server = $reporter->properties->servers->[0];
    $server->cleanup_dead_server;

    my $datadir = $reporter->serverVariable('datadir');
    # Cut trailing forward/backward slashes away.
    $datadir =~ s{[\\/]$}{}sgio;
    my $fbackup_dir = $datadir;
    $fbackup_dir =~ s{\/data$}{\/fbackup};
    if ($datadir eq $fbackup_dir) {
        say("ERROR: $who_am_i fbackup_dir equals datadir '$datadir'.");
        exit STATUS_ENVIRONMENT_FAILURE;
    }

    # Docu 2019-05
    # storage_engine
    # Description: See default_storage_engine.
    # Deprecated: MariaDB 5.5
    my $engine = $reporter->serverVariable('storage_engine');

    say("INFO: $who_am_i Copying datadir... (interrupting the copy operation may cause " .
        "investigation problems later)");
    say("INFO: $who_am_i Datadir used by the server all time is: $datadir");
    say("INFO: $who_am_i Copy of that datadir after crash and before restart is in: $fbackup_dir");
    if (osWindows()) {
        system("xcopy \"$datadir\" \"$fbackup_dir\" /E /I /Q");
    } else {
        system("cp -r --dereference $datadir $fbackup_dir");
    }
    # move($server->errorlog, $fbackup_dir . "/" . MYSQLD_ERRORLOG_FILE);
    my $errorlog = $server->errorlog;
    if (STATUS_OK != Basics::copy_file($errorlog, $fbackup_dir . "/" .
                                       File::Basename::basename($errorlog))) {
        exit STATUS_ENVIRONMENT_FAILURE;
    }
    unlink($errorlog);
    unlink("$datadir/core*");    # Remove cores from any previous crash

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
    # 2020-05-05 False alarm
    # One of the walking queries failed because max_statement_time=30 was exceeded.
    # The test setup might go with a short max_statement_time which might
    # cause that queries checking huge tables get aborted. And the code which follows
    # is not prepared for that.
    $server->addServerOptions(['--loose-max-statement-time=0']);

    $server->setStartDirty(1);
    my $recovery_status = $server->startServer();
    # In case $server->startServer failed than it makes a backtrace + cleanup.
    if ($recovery_status > STATUS_OK) {
        if ($recovery_status == STATUS_SERVER_CRASHED) {
            say("DEBUG: $who_am_i The server crashed during restart. Hence setting " .
                "recovery_status STATUS_RECOVERY_FAILURE.");
            $recovery_status = STATUS_RECOVERY_FAILURE;
        }
        say("ERROR: $who_am_i Status based on server start attempt is $recovery_status");
    }

    # Experiment:
    # system("killall -9 mysqld");

    # We look into the server error log even if the start attempt failed.
    # Reason: Filesystem full should not be classified as STATUS_RECOVERY_FAILURE.
    my $errorlog_status = STATUS_OK;
    open(RECOVERY, $server->errorlog);
    while (<RECOVERY>) {
        $_ =~ s{[\r\n]}{}siog;
        # Only for debugging
        # say($_);
        if ($_ =~ m{registration as a STORAGE ENGINE failed.}sio) {
            say("ERROR: $who_am_i Log message '$_' . Assuming recovery failure or " .
                "failure in RQG reporter.");
            my $status = STATUS_RECOVERY_FAILURE;
            $errorlog_status = $status if $status > $errorlog_status;
        } elsif ($_ =~ m{corrupt|crashed}) {
            say("WARN: $who_am_i Log message '$_' might indicate database corruption.");
            my $status = STATUS_RECOVERY_FAILURE;
            $errorlog_status = $status if $status > $errorlog_status;
        } elsif ($_ =~ m{exception}sio) {
            my $status = STATUS_RECOVERY_FAILURE;
            $errorlog_status = $status if $status > $errorlog_status;
        } elsif ($_ =~ m{ready for connections}sio) {
            if ($errorlog_status == STATUS_OK) {
                say("INFO: $who_am_i Log message '$_' found.");
            }
            # Some of the actions belonging to a restart with crash recovery are asynchronous.
            # So it can happen that 'ready for connections' was already printed before one
            # of the asynchronous actions crashes the server.
            # Hence we should no more run here a 'last'.
            # last;
        } elsif ($_ =~ m{device full error|no space left on device}sio) {
            say("ERROR: $who_am_i Log message '$_' indicating environment failure found.");
            my $status = STATUS_ENVIRONMENT_FAILURE;
            $errorlog_status = $status if $status > $errorlog_status;
            last;
        } elsif (
            ($_ =~ m{got signal}sio) ||
            ($_ =~ m{segfault}sio) ||
            ($_ =~ m{segmentation fault}sio)
        ) {
            say("ERROR: $who_am_i Recovery has apparently crashed.");
            # In case $server->startServer failed than it makes a cleanup + backtrace.
            my $status = STATUS_RECOVERY_FAILURE;
            $errorlog_status = $status if $status > $errorlog_status;
        }
    }
    close(RECOVERY);
    if ($recovery_status > STATUS_OK) {
        say("ERROR: $who_am_i Status based on error log checking is $recovery_status");
        if ($errorlog_status > $recovery_status) {
            say("ERROR: $who_am_i Raising the recovery_status from $recovery_status " .
                "to $errorlog_status.");
            $recovery_status = $errorlog_status;
        }
        if ($recovery_status >= STATUS_CRITICAL_FAILURE) {
            sayFile($server->errorlog);
            say("ERROR: $who_am_i Will kill the server and " .
                Auxiliary::build_wrs($recovery_status));
            # $server->killServer an maybe already dead server does not waste ressources.
            $server->killServer;
            return $recovery_status;
        }
    }
    # Left over cases: $recovery_status < STATUS_CRITICAL_FAILURE.

    # Experiment:
    # This is the no more valid (before KILL) pid.
    # my $pid = $reporter->serverInfo('pid');

    my $dbh = DBI->connect($reporter->dsn(), undef, undef, {
            mysql_connect_timeout  => Runtime::get_connect_timeout(),
            PrintError             => 0,
            RaiseError             => 0,
            AutoCommit             => 0,
            mysql_multi_statements => 0,
            mysql_auto_reconnect   => 0
    });
    if (not defined $dbh) {
        say("ERROR: $who_am_i Connect attempt to dsn " . $reporter->dsn() . " after " .
            "restart+recovery failed: " . $DBI::errstr);
            $recovery_status = STATUS_RECOVERY_FAILURE;
            say("INFO: $who_am_i Status changed to $recovery_status.");
            sayFile($server->errorlog);
            say("ERROR: $who_am_i Will kill the server and " .
                Auxiliary::build_wrs($recovery_status));
            $server->killServer;
            return $recovery_status;
    }

    if ($recovery_status > STATUS_OK) {
        $dbh->disconnect() if defined $dbh;
        $recovery_status = STATUS_RECOVERY_FAILURE;
        say("INFO: $who_am_i Status changed to $recovery_status.");
        sayFile($server->errorlog);
        # Doing the kill here might be not necessary. But I prefer to not rely on the cleanup
        # abilities of RQG runners and similar.
        say("INFO: $who_am_i Will kill the server because of previous failure.");
        $server->killServer;
        say("ERROR: $who_am_i Recovery has failed. " . Auxiliary::build_wrs($recovery_status));
        return $recovery_status;
    }

    #
    # Phase 2 - The server is now running, so we execute various statements in order to
    #           verify table consistency.
    #

    # Avoid the
    # 'TBR-604' , 'Table does not support optimize, doing recreate \+ analyze instead.{1,500}' .
    #             'Lock wait timeout exceeded; try restarting transaction'
    # Reason 1 (fixed by SET SESSION *wait_timeout = 300 here):
    #    The walkqueries were already executed and passed.
    #    It looks like the optimize causes the rollback of transactions on some table.
    #    And that is not finished before the * Lock wait timeout kicks in.
    # Reason 2 (not fixed by SET SESSION ... here):
    #    XA is involved
    my $timeout = 240 * Runtime::get_runtime_factor();
    $dbh->do("SET SESSION innodb_lock_wait_timeout = $timeout");
    $dbh->do("SET SESSION lock_wait_timeout = $timeout");


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
    if (not defined $databases) {
        $dbh->disconnect();
        my $status = STATUS_RECOVERY_FAILURE;
        say("ERROR: $who_am_i SHOW DATABASES failed. " . Auxiliary::build_wrs($status));
        return $status;
    }
    my @databases = sort @$databases;
    foreach my $database (sort @databases) {
        next if $database =~ m{^(rqg|mysql|information_schema|pbxt|performance_schema)$}sio;
        $dbh->do("USE $database");
        my $tabl_ref = $dbh->selectcol_arrayref("SHOW FULL TABLES", { Columns=>[1,2] });
        my %tables   = @$tabl_ref;
        foreach my $table (sort keys %tables) {
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
                    say("INFO: $who_am_i $table_to_check is a damaged VIEW. " .
                        "Omitting the walk_queries");
                    next;
                } else {
                    say("ERROR: $who_am_i $stmt harvested $err: $errstr. " .
                        "Will return status STATUS_RECOVERY_FAILURE later.");
                    $dbh->disconnect;
                    sayFile($server->errorlog);
                    return STATUS_RECOVERY_FAILURE;
                }
            }

            my @walk_queries;

            while (my $key_hashref = $sth_keys->fetchrow_hashref()) {
                my $key_name =    $key_hashref->{Key_name};
                my $column_name = $key_hashref->{Column_name};

                # What follows is correct in case the column has really the data type derived from
                # a snip of its name.
                # But its expected to fail like
                #        ERROR: SELECT * FROM `test`.`AA` FORCE INDEX (`col_int_nokey`)
                #               WHERE `col_int_nokey` >= -9223372036854775808
                #        4078: Illegal parameter data types multipolygon and bigint for operation '>='.
                # in case
                # - renaming of columns or alter scrambles that == The grammar/redefines are problematic.
                # - the simplifier in destructive mode could also scramble it like
                #   CREATE TABLE .... (
                #      { $name = 'c1_int ; $type = 'INT' } $name $type ,
                #      <ruleA setting  $name = 'c1_char'> <ruleB setting $type = 'VARCHAR(10)'> $name $type
                #   ...
                #   The simplifier shrinks and we get
                #      ruleB: ;
                #   RQG will generate
                #   CREATE TABLE .... (c1_int INT, c1_char INT)
                #
                # Most if not all grammars do not generate index names containing a backtick.
                # But the automatic grammar simplifier could cause such names when running in
                # destructive mode.
                # CREATE TABLE t5 (
                # col1 int(11) NOT NULL,
                # col_text text DEFAULT NULL,
                # PRIMARY KEY (col1),
                # KEY `idx2``idx2` (col_text(9))
                # ) ENGINE=InnoDB;
                # SHOW CREATE TABLE t5;
                # Table   Create Table
                # t5      CREATE TABLE `t5` (
                # `col1` int(11) NOT NULL,
                # `col_text` text DEFAULT NULL,
                # PRIMARY KEY (`col1`),
                # KEY `idx2``idx2` (`col_text`(9))
                # ) ENGINE=InnoDB DEFAULT CHARSET=latin1
                # SELECT TABLE_NAME, INDEX_NAME, COLUMN_NAME
                # FROM information_schema.statistics WHERE table_name = 't5';
                # TABLE_NAME      INDEX_NAME      COLUMN_NAME
                # t5      PRIMARY col1
                # t5      idx2`idx2       col_text
                # SELECT * FROM t5 FORCE INDEX(`idx2``idx2`);
                # col1    col_text
                # SELECT * FROM t5 FORCE INDEX("idx2`idx2");
                # ERROR 42000: You have an error in your SQL syntax; ..... to use near '"idx2`idx2")' at line 1
                # SELECT * FROM t5 FORCE INDEX("idx2``idx2");
                # ERROR 42000: You have an error in your SQL syntax; ..... to use near '"idx2``idx2")' at line 1
                # SELECT * FROM t5 FORCE INDEX(idx2``idx2);
                # ERROR 42000: You have an error in your SQL syntax; ..... to use near '``idx2)' at line 1

                # say("DEBUG: $who_am_i key_name->" . $key_name . "<- Column_name->" . $column_name . "<-");
                # Protect any backtick from being interpreted as begin or end of the name.
                # Otherwise we could harvest
                #    ERROR: SELECT * FROM `cool_down`.`t1` FORCE INDEX (`Marvão_idx2`Marvão_idx2`) ...
                #    ... the right syntax to use near 'Marvão_idx2`)
                # and assume to have hit some recovery failure.
                # $key_name =~ s§`§``§g;
                $key_name =~ s{`}{``}g;
                # say("DEBUG: $who_am_i key_name transformed->" . $key_name . "<-");
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
                        # $main_predicate stays undef.
                        # Nothing I can do.
                    }

                    # say("DEBUG: $who_am_i main_predicate->" . $main_predicate . "<-");
                    if (defined $main_predicate and $main_predicate ne '') {
                        $main_predicate = $main_predicate . " OR `$column_name` IS NULL" .
                                              " OR `$column_name` IS NOT NULL";
                    } else {
                        $main_predicate = " WHERE `$column_name` IS NULL" .
                                          " OR `$column_name` IS NOT NULL";
                    }
                    my $my_query = "SELECT $select_type FROM $table_to_check " .
                                   "FORCE INDEX (`$key_name`) " . $main_predicate;
                    # say("DEBUG: Walkquery ==>" . $my_query . "<=");
                    push @walk_queries, $my_query;
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
                if (defined $err) {
                    my $msg_snip = "$walk_query harvested $err: $errstr.";
                    if (4078 == $err) {
                        say("WARN: $msg_snip Will tolerate that.");
                        next;
                    }
                    say("ERROR:  $msg_snip " .
                        "Will return status STATUS_RECOVERY_FAILURE later.");
                    $sth_rows->finish();
                    $dbh->disconnect;
                    sayFile($server->errorlog);
                    return STATUS_RECOVERY_FAILURE;
                }

                my $rows = $sth_rows->rows();
                $sth_rows->finish();

                push @{$rows{$rows}} , $walk_query;
            }

            if (keys %rows > 1) {
                say("ERROR: $who_am_i Table $table_to_check is inconsistent. " .
                    "Will return STATUS_RECOVERY_FAILURE later.");
                print Dumper \%rows;

                my @rows_sorted = grep { $_ > 0 } sort keys %rows;

                my $least_sql = $rows{$rows_sorted[0]}->[0];
                my $most_sql  = $rows{$rows_sorted[$#rows_sorted]}->[0];

                say("Query that returned least rows: $least_sql\n");
                say("Query that returned most rows: $most_sql\n");

                my $least_result_obj = GenTest_e::Result->new(
                    data => $dbh->selectall_arrayref($least_sql)
                );

                my $most_result_obj = GenTest_e::Result->new(
                    data => $dbh->selectall_arrayref($most_sql)
                );

                say(GenTest_e::Comparator::dumpDiff($least_result_obj, $most_result_obj));

                $recovery_status = STATUS_RECOVERY_FAILURE;
            }

            # Should not do CHECK etc., and especially ALTER, on a view
            next if $tables{$table} eq 'VIEW';

            foreach my $sql (
                "CHECK TABLE $table_to_check EXTENDED",
                "ANALYZE TABLE $table_to_check",
                "OPTIMIZE TABLE $table_to_check",
                "REPAIR TABLE $table_to_check EXTENDED",
                # In case of InnoDB: OPTIMIZE is not supported and gets translated to recreate + analyze
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
                "ALTER TABLE $table_to_check FORCE",
            ) {
                say("INFO: $who_am_i Executing $sql.");
                my $sth = $dbh->prepare($sql);
                if (defined $sth) {
                    $sth->execute();

                    # mleich 2019-05-15 Observation
                    # 1. No report of error number or string
                    # 2. STATUS_RECOVERY_FAILURE thrown for harmless/natural states
                    my $err    = $sth->err();
                    my $errstr = '';
                    $errstr    = $sth->errstr() if defined $sth->errstr();

                    if (defined $err) {
                        if ( 1178 == $err or
                             1317 == $err or
                             # 4047 == $err or
                             1969 == $err   ) {
                             # 1178, "The storage engine for the table doesn\'t support ...
                             # 1317, "Query execution was interrupted" seen on 10.2 for OPTIMIZE ...
                             #       reason was max_statement_time exceeded
                             # 1969, "Query execution was interrupted (max_statement_time exceeded)
                             # 4047, "InnoDB refuses to write tables with ROW_FORMAT=COMPRESSED or KEY_BLOCK_SIZE"
                             #       Scenario:
                             #       YY grammar flips innodb_read_only_compressed to OFF
                             #       + creates a table using that compression
                             #       We restart here with the default innodb_read_only_compressed=ON
                             #       and get 4047.
                            say("DEBUG: $sql harvested harmless $errstr.");
                            next;
                        } else {
                            say("ERROR: $sql harvested $err: $errstr. " .
                                "Will return STATUS_RECOVERY_FAILURE later.");
                            $dbh->disconnect;
                            sayFile($server->errorlog);
                            return STATUS_RECOVERY_FAILURE;
                        }
                    }

                    if (defined $sth->{NUM_OF_FIELDS} and $sth->{NUM_OF_FIELDS} > 0) {
                        my $result = Dumper($sth->fetchall_arrayref());
                        # Do not process VIEWs
                        next if $result =~ m{is not BASE TABLE}sio;
                        # OPTIMIZE might be not supported and than mapped to something else.
                        # And that could become victim of 'Query execution was interrupted'.
                        # 2019-05 10.2
                        # $err was obviously not defined.
                        # $VAR1 = [
                        # [
                        #   'test.table2_innodb_int_autoinc',
                        #   'optimize',
                        #   'note',
                        #   'Table does not support optimize, doing recreate + analyze instead'
                        # ],
                        # [
                        #   'test.table2_innodb_int_autoinc',
                        #   'optimize',
                        #   'error',
                        #   'Query execution was interrupted'
                        # ],
                        # [
                        #   'test.table2_innodb_int_autoinc',
                        #   'optimize',
                        #   'status',
                        #   'Operation failed'
                        # ]
                        #       ];
                        next if (($result =~ m{error'}sio) and ($result =~ m{Query execution was interrupted}sio));
                        next if (($result =~ m{error'}sio) and ($result =~ m{Not allowed for system-versioned}sio));
                        # [
                        #  'test.table0_innodb_key_pk_parts_2_int_autoinc',
                        #  'check',
                        #  'note',
                        #  'Not supported for non-INTERVAL history partitions'
                        #  ],
                        next if (($result =~ m{note'}sio) and ($result =~ m{Not supported for non-INTERVAL history partitions}sio));
                        # OPTIMIZE might be not supported and than mapped to ....
                        # And that could become victim of 'Row size too large. ...
                        # [
                        #   'test.t3',
                        #   'optimize',
                        #   'note',
                        #   'Table does not support optimize, doing recreate + analyze instead'
                        # ],
                        # [
                        #   'test.t3',
                        #   'optimize',
                        #   'error',
                        #   'Row size too large. The maximum row size for the used table type, not counting BLOBs, is 1982. This includes storage overhead, check the manual. You have to change some columns to TEXT or BLOBs'
                        # ],
                        # [
                        #   'test.t3',
                        #   'optimize',
                        #   'status',
                        #   'Operation failed'
                        # ]
                        # 2019-11 Masses of
                        # Executing REPAIR TABLE `test`.`table1_innodb_key_pk_parts_2_int_autoinc` EXTENDED.
                        # $VAR1 = [
                        # [
                        #   'test.table1_innodb_key_pk_parts_2_int_autoinc',
                        #   'repair',
                        #   'error',
                        #   'Partition p0 returned error'
                        # ],
                        # [
                        #   'test.table1_innodb_key_pk_parts_2_int_autoinc',
                        #   'repair',
                        #   'error',
                        #   'Unknown - internal error 188 during operation'
                        # ]
                        #   ];
                        # and that even though the walk queries and all CHECK/ANALYZE before the
                        # REPAIR passed.
                        # Per Marko: InnoDB does not support REPAIR.
                        next if (($result =~ m{error'}sio) and ($result =~ m{Unknown - internal error 188 during operation}sio));
                        if ($result =~ m{error'|corrupt|repaired|invalid|crashed}sio) {
                            print $result;
                            my $status = STATUS_RECOVERY_FAILURE;
                            $dbh->disconnect();
                            sayFile($server->errorlog);
                            say("ERROR: $who_am_i Failures found in the output above. " . Auxiliary::build_wrs($status));
                            return $status;
                        }
                    };

                    $sth->finish();
                } else {
                    my $status = STATUS_RECOVERY_FAILURE;
                    $dbh->disconnect();
                    say("ERROR: $who_am_i Prepare failed: " . $dbh->errrstr() . " " .  Auxiliary::build_wrs($status));
                    sayFile($server->errorlog);
                    return $status;
                }
            }
        }
    }

    my $status = STATUS_OK;
    $dbh->disconnect();
    say("INFO: $who_am_i No failures found. " . Auxiliary::build_wrs($status));
    return $status;
}

sub type {
    return REPORTER_TYPE_PERIODIC | REPORTER_TYPE_SERVER_KILLED ;
}

1;