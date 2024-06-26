# Copyright (C) 2016, 2022 MariaDB Corporation Ab
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


########################################################################
#
# The module checks that after the test flow has finished,
# upgrade is performed successfully without losing any data.

# It is supposed to be used with the native server startup,
# i.e. with runall-new.pl rather than runall.pl which is MTR-based,
# and with --upgrade-test option, which makes runall-new.pl
# treat server1 and server2 differently -- instead of running
# the flow on both servers, it only starts server1 and runs the test
# flow there, while preserving server2 (the version to upgrade to).
#
# If the module is used without --upgrade-test, it won't work well.
#
# The current module is a derivate of the original Upgrade.pm.
# Modifications:
# 1. Certain modifications so that the reporter works well with rqg.pl.
# 2. Fix some weaknesses
# 3. (sooner or later) refine or derefine code
########################################################################

package GenTest_e::Reporter::Upgrade;

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
my $vardir;
my $version_numeric_old;
my %detected_known_bugs;

my $who_am_i = "Reporter 'Upgrade':";

sub report {
    my $reporter = shift;


    $first_reporter = $reporter if not defined $first_reporter;
    return STATUS_OK if $reporter ne $first_reporter;

    my $upgrade_mode= $reporter->properties->property('upgrade-test');
    if ($upgrade_mode eq 'normal') {
        say("INFO: $who_am_i The test will perform normal server upgrade");
    } elsif ($upgrade_mode eq 'crash') {
        say("INFO: $who_am_i The test will perform server crash-upgrade");
    } elsif ($upgrade_mode eq 'recovery') {
        say("INFO: $who_am_i The test will perform server crash-recovery");
    }
    $who_am_i .= " with mode '$upgrade_mode':";
    say("INFO: $who_am_i basedir before upgrade ->" . $reporter->properties->servers->[0]->basedir() . "<-");
    say("INFO: $who_am_i basedir after upgrade  ->" . $reporter->properties->servers->[1]->basedir() . "<-");

    say("INFO: $who_am_i -------------------- Begin");
    say("-- Old server info: --");
    say($reporter->properties->servers->[0]->version());
    $reporter->properties->servers->[0]->printServerOptions();
    $vardir = $reporter->properties->servers->[0]->vardir();
    say("-- New server info: --");
    say($reporter->properties->servers->[1]->version());
    $reporter->properties->servers->[1]->printServerOptions();
    say("INFO: $who_am_i -------------------- End");

    my $server = $reporter->properties->servers->[0];
    # FIXME:  Add timeouts etc.
    my $dbh = DBI->connect($server->dsn);
    # FIXME: Connect above can fail

    my $major_version_old= $server->majorVersion;
    $version_numeric_old= $server->versionNumeric();
    my $pid= $server->pid();

    my %table_autoinc = ();

    dump_database($reporter,$server,$dbh,'old');
    # FIXME: dump_database returns a status
    $table_autoinc{'old'} = collect_autoincrements($dbh,'old');

    if ($upgrade_mode eq 'normal') {
        say("INFO: $who_am_i Shutting down (send SIGTERM) the old server...");
        if (STATUS_OK != $server->term()) {
            # If SIGTERM has not the expected effect within the $term_timeout timespan
            # than crashServer(SIGABRT) gets called.
            # And if SIGABRT as not the expected effect within the $abrt_timeout timespan
            # than killServer(SIGKILL) gets called.
            return report_and_return(STATUS_CRITICAL_FAILURE);
        }
    } else {
        say("INFO: $who_am_i Killing (send SIGKILL) the old server...");
        # FIXME: If possible replace by calling a routine from MySQLd.pm
        kill(9, $pid);
        my $end_time = time() + 60;
        while (time() < $end_time) {
            last if not kill(0, $pid);
            sleep 1;
        }
    }
    # (mleich): FIXME      Why is there a branch with STATUS_SKIP?
    if (kill(0, $pid)) {
        say("ERROR: $who_am_i Could not shut down/kill the old server with pid $pid; sending SIGABRT to get a stack trace");
        kill('ABRT', $pid);
        if ($upgrade_mode eq 'recovery') {
            return report_and_return(STATUS_SERVER_DEADLOCKED);
        } else { # $upgrade_mode eq 'crash', we'll ignore hang on old server shutdown
            say("INFO: $who_am_i We will set STATUS_SKIP!");
            return report_and_return(STATUS_SKIP);
        }
    } else {
        say("INFO: $who_am_i Old server with pid $pid has been shut down/killed");
    }
    # Example of code which helps when meeting some already locked file.
    # my $maybe_locked_file = $vardir . "/data/aria_log_control";
    # system("lsof $maybe_locked_file");

    my $datadir = $server->datadir;
    $datadir =~ s{[\\/]$}{}sgio;
    my $fbackup_dir = $datadir;
    $fbackup_dir =~ s{\/data$}{\/fbackup};
    if ($datadir eq $fbackup_dir) {
        say("ERROR: $who_am_i fbackup_dir equals datadir '$datadir'.");
        exit STATUS_ENVIRONMENT_FAILURE;
    }

    # FIXME: Replace with routine in lib/Auxiliary.pm
    say("INFO: $who_am_i Copying datadir... (interrupting the copy operation may cause investigation problems later)");
    if (osWindows()) {
        system("xcopy \"$datadir\" \"$fbackup_dir\" /E /I /Q");
    } else {
        system("cp -r --dereference $datadir $fbackup_dir");
    }
    my $errorlog= $server->errorlog;
    move($errorlog, $server->errorlog.'_orig');
    unlink("$datadir/core*");    # Remove cores from any previous crash

    say("INFO: $who_am_i Starting the new server...");

    $server = $reporter->properties->servers->[1];
    $server->setStartDirty(1);
    my $upgrade_status = $server->startServer();

    if ($upgrade_status != STATUS_OK) {
        say("ERROR: $who_am_i New server failed to start");
    }

    # FIXME:
    # 1. Replace with routine in lib/Auxiliary.pm or rather DBServer_e/Mysqld.pm
    # 2. Certain bugs like MDEV-13112 are reported for 10.1 only.
    #    Figure out if they are valid for higher versions.
    # 3. Try to minimize the dependency on error messages which might depend on server version.
    #
    # Check and parse the error log up to this point,
    # even if the server failed to start, we need to see what went wrong
    # to tune the error code

    my ($crashes, $errors)= $server->checkErrorLogForErrors();
    foreach (@$errors, @$crashes) {
      if (m{\[ERROR\] InnoDB: Corruption: Page is marked as compressed but uncompress failed with error}so)
      {
          detected_bug(13112);
          $upgrade_status = STATUS_CUSTOM_OUTCOME if $upgrade_status < STATUS_CUSTOM_OUTCOME;
      }
      elsif (m{void fil_decompress_page.*: Assertion `0' failed}so)
      {
          detected_bug(13103);
          # We will only set the status to CUSTOM_OUTCOME if it was previously set to POSSIBLE_FAILURE
          $upgrade_status = STATUS_CUSTOM_OUTCOME if $upgrade_status == STATUS_POSSIBLE_FAILURE;
          last;
      }
      elsif (m{InnoDB: Corruption: Page is marked as compressed space:}so)
      {
          # Most likely it is an indication of MDEV-13103, but to make sure, we still need to find the assertion failure.
          # If we find it later, we will set result to STATUS_CUSTOM_OUTCOME.
          # If we don't find it later, we will raise it to STATUS_UPGRADE_FAILURE
          $upgrade_status = STATUS_POSSIBLE_FAILURE if $upgrade_status < STATUS_POSSIBLE_FAILURE;
      }
      elsif (m{recv_parse_or_apply_log_rec_body.*Assertion.*offs == .*failed}so)
      {
          detected_bug(13101);
          $upgrade_status = STATUS_CUSTOM_OUTCOME if $upgrade_status < STATUS_CUSTOM_OUTCOME;
          last;
      }
      elsif (m{Failing assertion: \!memcmp\(FIL_PAGE_TYPE \+ page, FIL_PAGE_TYPE \+ page_zip\-\>data, PAGE_HEADER - FIL_PAGE_TYPE\)}so)
      {
          detected_bug(13512);
          $upgrade_status = STATUS_CUSTOM_OUTCOME if $upgrade_status < STATUS_CUSTOM_OUTCOME;
          last;
      }
      elsif (m{InnoDB: Assertion failure in thread \d+ in file page0zip\.cc line \d+})
      {
          # Possibly it's MDEV-13247, it can show up if the old version is between 10.1.2 and 10.1.25.
          # We need to check for "Failing assertion: !page_zip_dir_find(page_zip, page_offset(rec))" later
          $upgrade_status = STATUS_POSSIBLE_FAILURE if $upgrade_status < STATUS_POSSIBLE_FAILURE;
      }
      elsif (m{Failing assertion: \!page_zip_dir_find\(page_zip, page_offset\(rec\)\)}so)
      {
          # Possibly it's MDEV-13247, it can show up if the old version is between 10.1.2 and 10.1.25.
          # If we've also seen Assertion failure .. in file page0zip.cc, we'll consider it related
          detected_bug(13247);
          $upgrade_status = STATUS_CUSTOM_OUTCOME if $upgrade_status == STATUS_POSSIBLE_FAILURE;
          last;
      }
      elsif (m{Assertion \`\!is_user_rec \|\| \!leaf \|\| index-\>is_dummy \|\| dict_index_is_ibuf\(index\) \|\| n == n_fields \|\| \(n \>= index->n_core_fields \&\& n \<= index-\>n_fields\)\' failed}so)
      {
          detected_bug(14022);
          $upgrade_status = STATUS_CUSTOM_OUTCOME if $upgrade_status < STATUS_CUSTOM_OUTCOME;
          last;
      }
      else {
          $upgrade_status = STATUS_UPGRADE_FAILURE if $upgrade_status < STATUS_UPGRADE_FAILURE;
      }
    }

    if ($upgrade_status != STATUS_OK) {
        $upgrade_status = STATUS_UPGRADE_FAILURE if $upgrade_status == STATUS_POSSIBLE_FAILURE;
        say("ERROR: $who_am_i Upgrade has apparently failed");
        sayFile($errorlog);
        return report_and_return($upgrade_status);
    }

    # If we are here, the new server must have started and no critical errors occurred.
    # For a minor upgrade, it should be enough, and the server should be working properly.
    # For the major upgrade, however, having some errors in the error is
    # normal, until we run the upgrade program.

    $dbh = DBI->connect($server->dsn);
    if (not defined $dbh) {
        say("ERROR: $who_am_i Could not connect to the new server after upgrade");
        return report_and_return(STATUS_UPGRADE_FAILURE);
    }

    if ($server->majorVersion eq $major_version_old) {
        say("New server started successfully after the minor upgrade");
    } elsif ($server->serverVariable('innodb_read_only') and (uc($server->serverVariable('innodb_read_only')) eq 'ON' or $server->serverVariable('innodb_read_only') eq '1') ) {
        say("New server is running with innodb_read_only=1, skipping the upgrade program");
    } else {
        my $upgrade_pgm= $server->clientBindir.'/'.(osWindows() ? 'mariadb-upgrade.exe' : 'mariadb-upgrade');
        if (not -e $upgrade_pgm) {
            $upgrade_pgm= $server->clientBindir.'/'.(osWindows() ? 'mysql_upgrade.exe' : 'mysql_upgrade');
        }
        say("New server started successfully after the major upgrade, running the upgrade program now using the command:");
        my $cmd= "\"$upgrade_pgm\" --host=127.0.0.1 --port=".$server->port." --user=root --password=''";
        say($cmd);
        my $res= system("$cmd > $datadir/upgrade.log");
        if ($res == STATUS_OK) {
            # The upgrade program upgrade can return exit code 0 even if user tables are corrupt,
            # so we don't trust the exit code, we should also check the actual output
            if (open(UPGRADE_LOG, "$datadir/upgrade.log")) {
                OUTER_READ:
                while (<UPGRADE_LOG>) {
                    # For now we will only check 'Repairing tables' section,
                    # and if there are any errors, we'll consider it a failure
                    next unless /Repairing tables/;
                    while (<UPGRADE_LOG>) {
                        if (/^\s*Error/) {
                            $res= STATUS_UPGRADE_FAILURE;
                            say("ERROR: $who_am_i Found errors in update program output");
                            sayFile("$datadir/upgrade.log");
                            last OUTER_READ;
                        }
                    }
                }
                close (UPGRADE_LOG);
            } else {
                say("ERROR: $who_am_i Could not find upgrade.log");
                $res= STATUS_UPGRADE_FAILURE;
            }
        }
        if ($res != STATUS_OK) {
            say("ERROR: $who_am_i The upgrade program has failed");
            sayFile($errorlog);
            return report_and_return(STATUS_UPGRADE_FAILURE);
        }
        say("The upgrade program has finished successfully, now the server should be ready to work");
    }

    #
    # Phase 2 - server is now running, so we execute various statements in order to verify table consistency
    #
    # FIXME: mleich
    #        This is again some frequent made test. Hence place it somewhere and call it from there.

    say("Testing database consistency");

    my $databases = $dbh->selectcol_arrayref("SHOW DATABASES");
    foreach my $database (@$databases) {
        next if $database =~ m{^(rqg|mysql|information_schema|pbxt|performance_schema)$}sio;
        $dbh->do("USE $database");
        my $tabl_ref = $dbh->selectcol_arrayref("SHOW FULL TABLES", { Columns=>[1,2] });
        my %tables = @$tabl_ref;
        foreach my $table (keys %tables) {
            # Should not do CHECK etc., and especially ALTER, on a view
            next if $tables{$table} eq 'VIEW';
            say("Verifying table: $table; database: $database");
            $dbh->do("CHECK TABLE `$database`.`$table` EXTENDED");
            # 1178 is ER_CHECK_NOT_IMPLEMENTED
            if (defined $dbh->err() && $dbh->err() > 0 && $dbh->err() != 1178) {
                return report_and_return(STATUS_DATABASE_CORRUPTION);
            }
        }
    }
    say("Schema does not look corrupt");

    #
    # Phase 3 - dump the server again and compare dumps
    #
    dump_database($reporter,$server,$dbh,'new');
    $table_autoinc{'new'} = collect_autoincrements($dbh,'new');

    my $version_numeric_new= $server->versionNumeric();
    normalize_dumps($version_numeric_old,$version_numeric_new);

    my $res= compare_all(\%table_autoinc);
    $res= $upgrade_status if $upgrade_status > $res;

    return report_and_return($res);
}

sub report_and_return {
    my $res= shift;
    my @detected_known_bugs = map { 'MDEV-'. $_ . '('.$detected_known_bugs{$_}.')' } keys %detected_known_bugs;
    say("Detected possible appearance of known bugs: @detected_known_bugs");
    say("INFO: $who_am_i ---------------------- End");
    return $res;
}

sub dump_database {
    # Suffix is "old" or "new" (restart)
    my ($reporter, $server, $dbh, $suffix) = @_;
    $vardir = $server->vardir unless defined $vardir;
    my $port= $server->port;

	my @all_databases = @{$dbh->selectcol_arrayref(
        "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA . SCHEMATA WHERE LOWER(SCHEMA_NAME) NOT IN " .
        "('rqg','mysql','information_schema','performance_schema','sys') ORDER BY SCHEMA_NAME")};
	my $databases_string = join(' ', @all_databases );

    my $dump_file = "$vardir/server_schema_$suffix.dump";
    my $dump_err  = "$vardir/server_schema_$suffix.err";
    my $mysqldump= $server->dumper;

    my $cmd_snip = "\"$mysqldump\" --force --hex-blob --no-tablespaces --compact " .
                   "--order-by-primary --skip-extended-insert --host=127.0.0.1 --port=$port " .
                   "--user=root --password='' ";
    my $cmd;
    # $cmd= "\"$mysqldump\" --force --hex-blob --no-tablespaces --compact --order-by-primary --skip-extended-insert --host=127.0.0.1 --port=$port --user=root --password='' --no-data --databases $databases_string";
    $cmd= $cmd_snip . "--no-data --databases $databases_string";
    say("Dumping $suffix server structures to the dump file $dump_file using the command:");
    say($cmd);
    my $dump_result = system("$cmd > $dump_file 2>$dump_err");

    # temporary: Do not just return STATUS_ENVIRONMENT_FAILURE if $dump_result;
    if ($dump_result) {
        say("WARN: mysqldump failed");
        sayFile($dump_err);
    }


    $dump_file = "$vardir/server_data_$suffix.dump";
    $dump_err  = "$vardir/server_data_$suffix.err";
    # $cmd= "\"$mysqldump\" --force --hex-blob --no-tablespaces --compact --order-by-primary --skip-extended-insert --host=127.0.0.1 --port=$port --user=root --password='' --no-create-info --databases $databases_string";
    $cmd= $cmd_snip . "--no-create-info --databases $databases_string";
    say("Dumping $suffix server data to the dump file $dump_file using the command:");
    say($cmd);
    $dump_result = system("$cmd > $dump_file 2>$dump_err");

    # temporary: Do not just return STATUS_ENVIRONMENT_FAILURE if $dump_result;
    if ($dump_result) {
        say("WARN: mysqldump failed");
        sayFile($dump_err);
    }

    # temporary    return ($dump_result ? STATUS_ENVIRONMENT_FAILURE : STATUS_OK);
    return STATUS_OK;
}

# Table AUTO_INCREMENT can be re-calculated upon restart,
# in which case the dumps will be different. We will ignore possible
# AUTO_INCREMENT differences in the dumps, but instead will check
# separately that the new value is either equal to the old one, or
# has been recalculated as MAX(column)+1.

sub collect_autoincrements {
    my ($dbh, $suffix) = @_;
    say("Storing auto-increment data for the $suffix server...");
	my $autoinc_tables = $dbh->selectall_arrayref("SELECT CONCAT(ist.TABLE_SCHEMA,'.',ist.TABLE_NAME), ist.AUTO_INCREMENT, isc.COLUMN_NAME, '' FROM INFORMATION_SCHEMA.TABLES ist JOIN INFORMATION_SCHEMA.COLUMNS isc ON (ist.TABLE_SCHEMA = isc.TABLE_SCHEMA AND ist.TABLE_NAME = isc.TABLE_NAME) WHERE ist.TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys') AND ist.AUTO_INCREMENT IS NOT NULL AND isc.EXTRA LIKE '%auto_increment%' ORDER BY ist.TABLE_SCHEMA, ist.TABLE_NAME, isc.COLUMN_NAME");

    foreach my $t (@$autoinc_tables) {
        $t->[3] = $dbh->selectrow_arrayref("SELECT IFNULL(MAX($t->[2]),0) FROM $t->[0]")->[0];
    }

    return $autoinc_tables;
}

sub compare_all {
    my $table_autoinc= shift;

    my $status = STATUS_OK;

	say("Comparing SQL schema dump errors between old and new servers...");
	my $diff_result = system("diff -u $vardir/server_schema_old.err $vardir/server_schema_new.err");
	$diff_result = $diff_result >> 8;
	if ($diff_result != 0) {
		say("ERROR: Schema dump errors differ");
		$status= STATUS_SCHEMA_MISMATCH;
	}

	say("Comparing SQL schema dumps between old and new servers...");
	$diff_result = system("diff -u $vardir/server_schema_old.dump $vardir/server_schema_new.dump");
	$diff_result = $diff_result >> 8;
	if ($diff_result != 0) {
		say("ERROR: Server schema has changed");
		$status= STATUS_SCHEMA_MISMATCH;
	}

	say("Comparing Data dump errors between old and new servers...");
	$diff_result = system("diff -u $vardir/server_data_old.err $vardir/server_data_new.err");
	$diff_result = $diff_result >> 8;
	if ($diff_result != 0) {
		say("ERROR: Data dump errors differ");
		$status= STATUS_CONTENT_MISMATCH;
	}

	say("Comparing Data dumps between old and new servers...");
	$diff_result = system("diff -u $vardir/server_data_old.dump $vardir/server_data_new.dump");
	$diff_result = $diff_result >> 8;
	if ($diff_result != 0) {
		say("ERROR: Server data has changed");
		$status= STATUS_CONTENT_MISMATCH;
	}

	say("Comparing auto-increment data between old and new servers...");

    my $old_autoinc= $table_autoinc->{'old'};
    my $new_autoinc= $table_autoinc->{'new'};

    if (not $old_autoinc and not $new_autoinc) {
        say("No auto-inc data for old and new servers, skipping the check");
    }
    elsif ($old_autoinc and ref $old_autoinc eq 'ARRAY' and (not $new_autoinc or ref $new_autoinc ne 'ARRAY')) {
        say("ERROR: Auto-increment data for the new server is not available");
        $status = STATUS_CONTENT_MISMATCH;
    }
    elsif ($new_autoinc and ref $new_autoinc eq 'ARRAY' and (not $old_autoinc or ref $old_autoinc ne 'ARRAY')) {
        say("ERROR: Auto-increment data for the old server is not available");
        $status = STATUS_CONTENT_MISMATCH;
    }
    elsif (scalar @$old_autoinc != scalar @$new_autoinc) {
        say("ERROR: Different number of tables in auto-increment data. Old server: ".scalar(@$old_autoinc)." ; new server: ".scalar(@$new_autoinc));
        $status= STATUS_CONTENT_MISMATCH;
    }
    else {
        foreach my $i (0..$#$old_autoinc) {
            my $to = $old_autoinc->[$i];
            my $tn = $new_autoinc->[$i];
            say("Comparing auto-increment data. Old server: @$to ; new server: @$tn");

            # 0: table name; 1: table auto-inc; 2: column name; 3: max(column)
            if ($to->[0] ne $tn->[0] or $to->[2] ne $tn->[2] or $to->[3] != $tn->[3] or ($tn->[1] != $to->[1] and $tn->[1] != $tn->[3]+1))
            {
                detected_bug(13094);
                say("ERROR: Auto-increment data differs. Old server: @$to ; new server: @$tn");
                $status= STATUS_CUSTOM_OUTCOME if $status < STATUS_CUSTOM_OUTCOME;
            }
        }
    }

	if ($status == STATUS_OK) {
		say("No differences were found between old and new server contents.");
    }
    return $status;
}

sub detected_bug {
    my $bugnum= shift;
    $detected_known_bugs{$bugnum}= (defined $detected_known_bugs{$bugnum} ? $detected_known_bugs{$bugnum}+1 : 1);
}

# There are some known expected differences in dump structure between versions.
# We need to normalize the dumps to avoid false positives
sub normalize_dumps {
    my ($old_ver,$new_ver) = @_;

    move("$vardir/server_schema_old.dump","$vardir/server_schema_old.dump.orig");
    move("$vardir/server_schema_new.dump","$vardir/server_schema_new.dump.orig");

    open(DUMP1,"$vardir/server_schema_old.dump.orig");
    open(DUMP2,">$vardir/server_schema_old.dump");
    while (<DUMP1>) {
        if (s/AUTO_INCREMENT=\d+//) {};
        print DUMP2 $_;
    }
    close(DUMP1);
    close(DUMP2);
    open(DUMP1,"$vardir/server_schema_new.dump.orig");
    open(DUMP2,">$vardir/server_schema_new.dump");
    while (<DUMP1>) {
        if (s/AUTO_INCREMENT=\d+//) {};
        print DUMP2 $_;
    }
    close(DUMP1);
    close(DUMP2);

    # In 10.2 SHOW CREATE TABLE output changed:
    # - blob and text columns got the "DEFAULT" clause;
    # - default numeric values lost single quote marks
    # Let's update pre-10.2 dumps to match it

    if ($old_ver le '100201' and $new_ver ge '100201') {
        move("$vardir/server_schema_old.dump","$vardir/server_schema_old.dump.tmp");
        open(DUMP1,"$vardir/server_schema_old.dump.tmp");
        open(DUMP2,">$vardir/server_schema_old.dump");
        while (<DUMP1>) {
            # `k` int(10) unsigned NOT NULL DEFAULT '0' => `k` int(10) unsigned NOT NULL DEFAULT 0
            s/(DEFAULT\s+)\'(\d+)\'(,?)$/${1}${2}${3}/;

            # `col_blob` blob NOT NULL => `col_blob` blob NOT NULL DEFAULT '',
            # This part is conditional, see MDEV-12006. For upgrade from 10.1, a text column does not get a default value
            if ($old_ver lt '100101') {
                s/(\s+(?:blob|text|mediumblob|mediumtext|longblob|longtext|tinyblob|tinytext)(\s+)NOT\sNULL)(,)?$/${1}${2}DEFAULT${2}\'\'${3}/;
            }
            # `col_blob` text => `col_blob` text DEFAULT NULL,
            s/(\s)(blob|text|mediumblob|mediumtext|longblob|longtext|tinyblob|tinytext)(,)?$/${1}${2}${1}DEFAULT${1}NULL${3}/;
            print DUMP2 $_;
        }
        close(DUMP1);
        close(DUMP2);
    }

    if ($new_ver ge '100702') {
        move("$vardir/server_schema_old.dump","$vardir/server_schema_old.dump.tmp");
        open(DUMP1,"$vardir/server_schema_old.dump.tmp");
        open(DUMP2,">$vardir/server_schema_old.dump");
        while (<DUMP1>) {
            # DEFAULT CHARACTER SET utf8 COLLATE utf8_bin
            s/DEFAULT CHARACTER SET utf8 COLLATE utf8_bin/DEFAULT CHARACTER SET utf8mb3 COLLATE utf8mb3_bin/g;
            # old: `col_varchar_255_utf8_key` varchar(255) CHARACTER SET utf8 DEFAULT NULL,
            # new: `col_varchar_255_utf8_key` varchar(255) CHARACTER SET utf8mb3 DEFAULT NULL,
            s/CHARACTER SET utf8 /CHARACTER SET utf8mb3 /g;
            s/CHARACTER SET utf8,/CHARACTER SET utf8mb3,/g;
            # old: COLLATE utf8_bin
            # new: COLLATE utf8mb3_bin
            s/ COLLATE utf8_bin/ COLLATE utf8mb3_bin/g;
            # old: DEFAULT CHARSET=utf8 `ENCRYPTED`=YES;
            # new: DEFAULT CHARSET=utf8mb3 `ENCRYPTED`=YES;
            s/ CHARSET=utf8 / CHARSET=utf8mb3 /g;
            s/ CHARSET=utf8;/ CHARSET=utf8mb3;/g;
            # old: CREATE DATABASE /*!32312 IF NOT EXISTS*/ `testdb_N` /*!40100 DEFAULT CHARACTER SET utf8 */;
            # new: CREATE DATABASE /*!32312 IF NOT EXISTS*/ `testdb_N` /*!40100 DEFAULT CHARACTER SET utf8mb3 */;
            s/ CHARACTER SET utf8 / CHARACTER SET utf8mb3 /g;
            s/DEFAULT CHARACTER SET utf8 /DEFAULT CHARACTER SET utf8mb3 /g;
            print DUMP2 $_;
        }
        close(DUMP1);
        close(DUMP2);
    }
}

sub type {
    # return REPORTER_TYPE_ALWAYS;
    return REPORTER_TYPE_SUCCESS;
}

1;
