# Copyright (C) 2016, 2019 MariaDB Corporation Ab.
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



package GenTest::Reporter::RestartConsistency;

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

my $who_am_i = "Reporter 'RestartConsistency'";
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

    my $dbh = DBI->connect($reporter->dsn());
    # mleich: 2019-03
    # A worker thread "killed" the server via its stream of SQL before the reporter
    # RestartConsistency connected its first time.
    # So the reporter gets
    #     DBI connect('host=127.0.0.1:....) failed: Can't connect to MySQL server ...
    #     at lib/GenTest/Reporter/RestartConsistency.pm line 55.
    # and than
    #     Can't call method "selectcol_arrayref" on an undefined value
    #     at lib/GenTest/Reporter/RestartConsistency.pm line 169.
    # which culminates in rqg.pl aborting without making an archive.
    if (not defined $dbh) {
        # I hesitate to pick a higher value because
        # 1. Its the first connect attempt of RestartConsistency but it happens short
        #    before test end == It is extreme likely that the server was at begin connectable.
        # 2. In case of a real server crash than its quite likely that some other thread or
        #    reporter has already reported STATUS_SERVER_CRASHED or will do that soon.
        #    Throwing STATUS_ENVIRONMENT_FAILURE here would exceed STATUS_SERVER_CRASHED
        #    and cause some misleading final exit status.
        say("ERROR: $who_am_i report: Connect failed. Will return STATUS_CRITICAL_FAILURE");
        return STATUS_CRITICAL_FAILURE;
    }

    my $dump_return = dump_database($reporter,$dbh,'before');
    if ($dump_return > STATUS_OK) {
        say("ERROR: Dumping the database failed with status $dump_return.");
        return $dump_return;
    }

    my $pid = $reporter->serverInfo('pid');
    kill(15, $pid);

    foreach (1..60) {
        last if not kill(0, $pid);
        sleep 1;
    }
    if (kill(0, $pid)) {
        say("ERROR: $who_am_i report: Could not shut down server with pid $pid.");
        return STATUS_SERVER_DEADLOCKED;
    } else {
        say("INFO: $who_am_i report: Server with pid $pid has been shut down");
    }

    my $datadir = $reporter->serverVariable('datadir');
    $datadir =~ s{[\\/]$}{}sgio;
    my $orig_datadir = $datadir.'_orig';
    my $pid = $reporter->serverInfo('pid');

    my $engine = $reporter->serverVariable('storage_engine');

    my $server = $reporter->properties->servers->[0];
    say("INFO: $who_am_i report: Copying datadir... (interrupting the copy operation may cause investigation problems later)");
    if (osWindows()) {
        system("xcopy \"$datadir\" \"$orig_datadir\" /E /I /Q");
    } else { 
        system("cp -r $datadir $orig_datadir");
    }
    $errorlog_before = $server->errorlog.'_orig';
    # move($server->errorlog, $server->errorlog.'_orig');
    move($server->errorlog, $errorlog_before);
    unlink("$datadir/core*");    # Remove cores from any previous crash

    say("INFO: $who_am_i report: Restarting server ...");

    $server->setStartDirty(1);
    my $recovery_status = $server->startServer();
    $errorlog_after = $server->errorlog;
    open(RECOVERY, $server->errorlog);

    while (<RECOVERY>) {
        $_ =~ s{[\r\n]}{}siog;
        say($_);
        if ($_ =~ m{registration as a STORAGE ENGINE failed.}sio) {
            say("Storage engine registration failed");
            $recovery_status = STATUS_DATABASE_CORRUPTION;
        } elsif ($_ =~ m{corrupt|crashed}) {
            say("Log message '$_' might indicate database corruption");
        } elsif ($_ =~ m{exception}sio) {
            $recovery_status = STATUS_DATABASE_CORRUPTION;
        } elsif ($_ =~ m{ready for connections}sio) {
            say("Server Recovery was apparently successfull.") if $recovery_status == STATUS_OK ;
            last;
        } elsif ($_ =~ m{device full error|no space left on device}sio) {
            $recovery_status = STATUS_ENVIRONMENT_FAILURE;
            last;
        } elsif (
            ($_ =~ m{got signal}sio) ||
            ($_ =~ m{segfault}sio) ||
            ($_ =~ m{segmentation fault}sio)
        ) {
            say("Recovery has apparently crashed.");
            $recovery_status = STATUS_DATABASE_CORRUPTION;
        }
    }

    close(RECOVERY);

    $dbh = DBI->connect($reporter->dsn());
    $recovery_status = STATUS_DATABASE_CORRUPTION if not defined $dbh && $recovery_status == STATUS_OK;

    if ($recovery_status > STATUS_OK) {
        say("Restart has failed.");
        return $recovery_status;
    }
    
    # 
    # Phase 2 - server is now running, so we execute various statements in order to verify table consistency
    #

    say("Testing database consistency");

    my $databases = $dbh->selectcol_arrayref("SHOW DATABASES");
    foreach my $database (@$databases) {
        next if $database =~ m{^(mysql|information_schema|pbxt|performance_schema)$}sio;
        $dbh->do("USE $database");
        my $tabl_ref = $dbh->selectcol_arrayref("SHOW FULL TABLES", { Columns=>[1,2] });
        my %tables = @$tabl_ref;
        foreach my $table (keys %tables) {
            # Should not do CHECK etc., and especially ALTER, on a view
            next if $tables{$table} eq 'VIEW';
            say("Verifying table: $table; database: $database");
            $dbh->do("CHECK TABLE `$database`.`$table` EXTENDED");
            # 1178 is ER_CHECK_NOT_IMPLEMENTED
            return STATUS_DATABASE_CORRUPTION if $dbh->err() > 0 && $dbh->err() != 1178;
        }
    }
    say("Schema does not look corrupt");

    # 
    # Phase 3 - dump the server again and compare dumps
    #
    my $dump_return = dump_database($reporter,$dbh,'after');
    if ($dump_return > STATUS_OK) {
        say("ERROR: Dumping the database failed with status $dump_return.");
        return $dump_return;
    }
    return compare_dumps();
}
    
    
sub dump_database {
    # Suffix is "before" or "after" (restart)
    my ($reporter, $dbh, $suffix) = @_;
    my $port = $reporter->serverVariable('port');
    $vardir = $reporter->properties->servers->[0]->vardir() unless defined $vardir;
    
	my @all_databases = @{$dbh->selectcol_arrayref("SHOW DATABASES")};
	my $databases_string = join(' ', grep { $_ !~ m{^(mysql|information_schema|performance_schema)$}sgio } @all_databases );
	
    say("Dumping the server $suffix restart");
    my $dump_file = "$vardir/server_$suffix.dump";
    my $dump_result = system('"'.$reporter->serverInfo('client_bindir')."/mysqldump\" --hex-blob --no-tablespaces --compact --order-by-primary --skip-extended-insert --host=127.0.0.1 --port=$port --user=root --password='' --databases $databases_string > $dump_file");
    return ($dump_result ? STATUS_ENVIRONMENT_FAILURE : STATUS_OK);
}

sub compare_dumps {
	say("Comparing SQL dumps between servers before and after restart...");
    # mleich 2019-03:
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
	my $diff_result = system("diff -U 50 $vardir/server_before.dump $vardir/server_after.dump");
	$diff_result = $diff_result >> 8;

	if ($diff_result == 0) {
		say("No differences were found between server contents before and after restart.");
		return STATUS_OK;
	} else {
		say("ERROR: Server content has changed after shutdown+restart");
        sayFile($errorlog_before);
        sayFile($errorlog_after);
		return STATUS_DATABASE_CORRUPTION;
	}
}

sub type {
    # mleich 2019-03:
    # IMHO in case the server has crashed before than it does not make that much sense
    # to run this reporter now. So we could go with REPORTER_TYPE_SUCCESS too.
    # But since we bail out with STATUS_CRITICAL_FAILURE when not getting a connection
    # the overhead is light weight.
    # On the other hand:
    # REPORTER_TYPE_SUCCESS runs only if current status == STATUS_OK and that would mean
    # we get in case of less evil statuses != STATUS_OK less information than we could.
    # So REPORTER_TYPE_ALWAYS should be acceptable.
    return REPORTER_TYPE_ALWAYS;
}

1;
