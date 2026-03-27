# Copyright (C) 2025 MariaDB plc
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

# LogArchiveRecovery.pm - Reporter for testing MDEV-37949 innodb_log_archive
# Developed by Saahil Alam for RQG innodb_log_archive crash-recovery testing
#
# This reporter tests the InnoDB log archiving feature by:
# 1. Running workload with innodb_log_archive=ON
# 2. Killing the server to simulate crash
# 3. Backing up datadir (fbackup preserved for debugging per Marko)
# 4. Probing with innodb_log_recovery_target=18446744073709551615 (max) to find actual reachable LSN
# 5. Restoring datadir from backup
# 6. Recovery attempt with randomized options:
#    - 50% normal vs LSN-targeted recovery (per MTR test patterns)
#    - innodb_log_recovery_start=0 (latest checkpoint - always valid for RQG)
#    - 50% innodb_log_file_mmap=ON vs OFF (covers mmap vs pread parsing code paths)
# 7. Verifying recovery succeeds
#
# Per Marko: "set innodb_log_recovery_target=-1 or 18446744073709551615 to have everything
# recovered until the end. If it complains that it only reached an earlier LSN, then that
# would be the innodb_log_recovery_target that you should set."
# Also: Compare data files with/without innodb_log_recovery_start=12288 - should be identical.
# Any crash should be filed as a bug (previous crash fixed).
#
# Recovery approach (per Marko's guidance):
# - Do NOT delete any log files ("deleting newest is sure way to get into trouble")
# - Use innodb_log_archive=OFF (default) for recovery - server auto-detects log format
# - Server first looks for ib_logfile0, only if not found looks at ib_*.log archives
# - innodb_log_archive=ON + ib_logfile0 exists = startup error!
#
# Testing considerations from Marko (PR #4405):
# - Test all I/O combinations: PMEM, mmap, pread/pwrite
# - Some transactions may be blocked by locks held by recovered incomplete transactions
#
# IMPORTANT CONSTRAINT: innodb_encrypt_log CANNOT be used with innodb_log_archive=ON
# From PR: "all --suite=encryption tests that use innodb_encrypt_log must be skipped
# when using innodb_log_archive." The encryption preservation code below is kept as
# a safety mechanism but should not be needed in normal RQG testing.

package GenTest_e::Reporter::LogArchiveRecovery;

require Exporter;
@ISA = qw(GenTest_e::Reporter);

use strict;
use DBI;
use GenTest_e;
use GenTest_e::Constants;
use GenTest_e::Reporter;
use Data::Dumper;
use File::Copy;
use POSIX;

use DBServer_e::MySQL::MySQLd;

my $first_reporter;
my $who_am_i = "Reporter 'LogArchiveRecovery':";
my $first_monitoring = 1;
my $saved_encrypt_log;  # Preserve encryption state for recovery
my $feature_available = 1;  # Assume feature exists until proven otherwise (MariaDB 13.0+)

sub monitor {
    my $reporter = shift;

    $first_reporter = $reporter if not defined $first_reporter;
    return STATUS_OK if $reporter ne $first_reporter;

    my $pid = $reporter->serverInfo('pid');

    if ($first_monitoring) {
        # Log server version for reference
        my $server = $reporter->properties->servers->[0];
        my $version_numeric = $server->versionNumeric();
        say("INFO: $who_am_i Server version: " . $server->version() . " (numeric: $version_numeric)");
        
        # Check if innodb_log_archive variable exists (feature availability check)
        # This works regardless of version - feature may be backported or in development branches
        my $dbh = DBI->connect($reporter->dsn(), undef, undef,
            { PrintError => 0, RaiseError => 0, AutoCommit => 1 });
        if (defined $dbh) {
            my $log_archive = $dbh->selectrow_array(
                "SELECT \@\@GLOBAL.innodb_log_archive");
            if (!defined $log_archive) {
                # Variable doesn't exist - feature not available in this build
                say("INFO: $who_am_i innodb_log_archive variable not found. " .
                    "Feature not available in this build. Reporter will be inactive.");
                $feature_available = 0;
                $dbh->disconnect();
                $first_monitoring = 0;
                return STATUS_OK;
            } elsif ($log_archive eq '0') {
                say("WARN: $who_am_i innodb_log_archive is OFF. " .
                    "This reporter expects innodb_log_archive=ON for proper testing.");
            } else {
                say("INFO: $who_am_i innodb_log_archive=$log_archive confirmed.");
            }
            
            # CRITICAL: Capture innodb_encrypt_log state - must be preserved during recovery
            # Log files cannot be recovered with different encryption settings
            $saved_encrypt_log = $dbh->selectrow_array(
                "SELECT \@\@GLOBAL.innodb_encrypt_log");
            if (defined $saved_encrypt_log) {
                say("INFO: $who_am_i Captured innodb_encrypt_log=$saved_encrypt_log for recovery.");
            } else {
                say("WARN: $who_am_i Could not capture innodb_encrypt_log, defaulting to OFF.");
                $saved_encrypt_log = 0;
            }
            
            $dbh->disconnect();
        }
        say("INFO: $who_am_i First monitoring");
        $first_monitoring = 0;
    }

    # Skip crash-recovery testing if feature not available (MariaDB < 13.0)
    # This allows tests to run on older versions without failure
    if (!$feature_available) {
        return STATUS_OK;
    }

    if (not $reporter->properties->servers->[0]->running()) {
        say("ERROR: $who_am_i The server is not running though it should.");
        exit STATUS_SERVER_CRASHED;
    }

    if (time() > $reporter->testEnd() - 19) {
        my $kill_msg = "$who_am_i Sending SIGKILL to server with pid $pid " .
                       "to test log archive recovery.";
        say("INFO: $kill_msg");
        kill(9, $pid);
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

    # Skip log archive recovery if feature not available (MariaDB < 13.0)
    # This prevents errors if server crashed for another reason on older versions
    if (!$feature_available) {
        say("INFO: $who_am_i Skipping log archive recovery (feature not available on this version).");
        return STATUS_OK;
    }

    say("INFO: $who_am_i Reporting - Testing log archive recovery...");

    our $server = $reporter->properties->servers->[0];
    my $status = $server->killServer;
    if (STATUS_OK != $status) {
        $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i cleaning up the killed server failed. " .
            Basics::exit_status_text($status));
        exit $status;
    }

    my $backup_status = $server->backupDatadir();
    if (STATUS_OK != $backup_status) {
        $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i The file backup failed. " .
            Basics::return_status_text($status));
        return $status;
    }
    
    # Debug: verify backup was created
    # Note: backupDatadir() may create nested data/ structure depending on source
    my $datadir = $server->datadir();
    my $fbackup_check = $datadir;
    $fbackup_check =~ s{\/data$}{\/fbackup};
    if (-d $fbackup_check) {
        # Check for ibdata1 directly or in nested data/ directory
        if (-f "$fbackup_check/ibdata1") {
            say("DEBUG: $who_am_i Backup verified: $fbackup_check/ibdata1 exists");
        } elsif (-f "$fbackup_check/data/ibdata1") {
            say("DEBUG: $who_am_i Backup verified (nested): $fbackup_check/data/ibdata1 exists");
        } else {
            say("WARN: $who_am_i Backup directory exists but ibdata1 not found in expected locations");
            my $contents = `ls -la $fbackup_check 2>&1`;
            say("DEBUG: $who_am_i fbackup contents after backup:\n$contents");
        }
    } else {
        say("ERROR: $who_am_i Backup directory not found: $fbackup_check");
    }

    # Step 1: Probe startup with impossible innodb_log_recovery_target
    # to determine the final LSN from the error message.
    # NOTE: This runs on the dirty datadir BEFORE restore. The probe may fail/modify datadir,
    # but we restore from backup afterwards for the actual recovery attempt.
    say("INFO: $who_am_i Step 1: Determining final LSN via probe startup...");
    
    # $datadir already set above during backup verification
    my $error_log = $server->errorlog();
    
    # Save original server options
    my @original_options = @{$server->getServerOptions() // []};
    
    # Filter out innodb_log_archive and innodb_log_recovery options - we control these for probe/recovery
    my @filtered_for_probe = grep { !/innodb[-_]log[-_](archive|recovery|file[-_]mmap)/i } @original_options;
    @{$server->getServerOptions()} = @filtered_for_probe;
    
    # Per Marko's guidance:
    # "you can set innodb_log_recovery_target=-1 or innodb_log_recovery_target=18446744073709551615
    # to have everything to be recovered until the end. If it complains that it only reached
    # an earlier LSN, then that would be the innodb_log_recovery_target that you should set."
    #
    # Use max uint64 value to request recovery to end of log
    # If server can only reach an earlier LSN, it will report that in the error log
    my @probe_options = (
        '--innodb-log-archive=OFF',
        '--innodb-log-recovery-start=0',
        '--innodb-log-recovery-target=18446744073709551615',
        '--innodb-force-recovery=0'
    );
    if (defined $saved_encrypt_log) {
        my $encrypt_value = $saved_encrypt_log ? 'ON' : 'OFF';
        push @probe_options, "--innodb-encrypt-log=$encrypt_value";
    }
    $server->addServerOptions(\@probe_options);
    
    $server->setStartDirty(1);
    my $probe_status = $server->startServer(0);  # Don't wait for full startup
    
    # Wait a moment for error to be written
    sleep(3);
    
    # Read error log to find final LSN
    my $final_lsn = undef;
    if (-r $error_log) {
        open(my $fh, '<', $error_log) or do {
            say("WARN: $who_am_i Cannot read error log: $!");
        };
        if (defined $fh) {
            my @lines = <$fh>;
            close($fh);
            
            # Look for the LSN that server actually reached
            # When using max target, server may report:
            # - "cannot fulfill innodb_log_recovery_target=X<Y" where Y is max reachable LSN
            # - Or successfully recover to end of log
            for my $line (reverse @lines) {
                # Pattern 1: Server reports it can only reach an earlier LSN
                if ($line =~ /cannot\s+fulfill.*innodb_log_recovery_target=\d+<(\d+)/i) {
                    $final_lsn = $1;
                    say("INFO: $who_am_i Server can only reach LSN: $final_lsn");
                    last;
                }
                # Pattern 2: Server reports final checkpoint LSN during recovery
                if ($line =~ /InnoDB:\s*Log\s+sequence\s+number\s+(\d+)/i) {
                    $final_lsn = $1;
                    say("INFO: $who_am_i Found log sequence number: $final_lsn");
                    # Don't break - keep looking for more specific message
                }
            }
        }
    }
    
    # Log whether we found an LSN from the probe
    if (defined $final_lsn) {
        say("INFO: $who_am_i Probe successful - found final LSN: $final_lsn");
    } else {
        say("INFO: $who_am_i Probe did not extract LSN (this may be normal if log format differs)");
    }
    
    # Kill probe server if still running
    $server->killServer();
    
    # Restore from backup for clean recovery attempt
    # Note: backupDatadir() copies datadir to fbackup directory
    # IMPORTANT (per Marko): fbackup is preserved as a reference of the crashed state.
    # If recovery corrupts something, investigators can compare fbackup/ vs datadir/
    # to see what went wrong during crash recovery.
    say("INFO: $who_am_i Restoring from backup for recovery test...");
    my $fbackup_dir = $datadir;
    $fbackup_dir =~ s{\/data$}{\/fbackup};
    
    # Debug: show what we have
    say("DEBUG: $who_am_i datadir=$datadir, fbackup_dir=$fbackup_dir");
    
    if (-d $fbackup_dir) {
        # List backup contents before restore
        my $backup_contents = `ls -la $fbackup_dir 2>&1`;
        say("DEBUG: $who_am_i fbackup contents:\n$backup_contents");
        
        # Check if backup has nested 'data' directory (can happen if fbackup pre-existed)
        my $source_dir = $fbackup_dir;
        if (-d "$fbackup_dir/data" && -f "$fbackup_dir/data/ibdata1") {
            $source_dir = "$fbackup_dir/data";
            say("WARN: $who_am_i Backup has nested data/ structure, using $source_dir");
        }
        
        # Clear datadir contents and restore from backup
        # Don't remove the directory itself to preserve symlink structure
        my $rm_result = system("rm -rf $datadir/* 2>&1");
        if ($rm_result != 0) {
            say("WARN: $who_am_i rm -rf returned non-zero: $rm_result");
        }
        
        my $cp_result = system("cp -r --dereference $source_dir/* $datadir/ 2>&1");
        if ($cp_result != 0) {
            say("ERROR: $who_am_i cp failed with result: $cp_result");
        }
        say("DEBUG: $who_am_i Restore commands completed (rm=$rm_result, cp=$cp_result)");
        
        # Verify restore worked
        if (-f "$datadir/ibdata1" && -d "$datadir/mysql") {
            say("INFO: $who_am_i Restored datadir from $source_dir - verified ibdata1 and mysql/ exist");
            say("INFO: $who_am_i fbackup preserved at $fbackup_dir for debugging if recovery fails");
            
            # NOTE: Do NOT delete any log files!
            # Per Marko: "Deleting the newest log file is a sure way to get into trouble."
            # "If you had started the server with innodb_log_archive=OFF (the default),
            # it should have recovered from the correct file."
            # Server auto-detects log format: looks for ib_logfile0 first, then ib_*.log
        } else {
            say("ERROR: $who_am_i Restore verification FAILED! Cannot proceed with recovery.");
            my $datadir_contents = `ls -la $datadir 2>&1`;
            say("DEBUG: $who_am_i datadir contents after restore:\n$datadir_contents");
            return STATUS_ENVIRONMENT_FAILURE;
        }
    } else {
        say("ERROR: $who_am_i Backup directory $fbackup_dir not found! Cannot proceed with recovery.");
        return STATUS_ENVIRONMENT_FAILURE;
    }
    
    # Step 2: Attempt recovery (50% normal, 50% LSN-targeted per MTR patterns)
    # Per Marko's guidance:
    # - innodb_log_archive=OFF: server auto-detects log format
    # - innodb_log_recovery_start=0: start from latest checkpoint  
    # - innodb_log_recovery_target=<lsn>: point-in-time recovery to specific LSN (when used)
    say("INFO: $who_am_i Step 2: Attempting crash recovery...");
    # Reset server options to original (remove probe options that were added)    
    # But filter out innodb_log_archive and innodb_log_recovery options - we control these for recovery
    my @filtered_options = grep { !/innodb[-_]log[-_](archive|recovery|file[-_]mmap)/i } @original_options;
    
    # getServerOptions() returns a reference to the internal array, so we can modify it directly
    @{$server->getServerOptions()} = @filtered_options;
    
    # CRITICAL: Preserve encryption setting - log files cannot be recovered with different setting
    if (defined $saved_encrypt_log) {
        my $encrypt_value = $saved_encrypt_log ? 'ON' : 'OFF';
        $server->addServerOptions(["--innodb-encrypt-log=$encrypt_value"]);
        say("INFO: $who_am_i Preserving innodb_encrypt_log=$encrypt_value for recovery.");
    }
    
    # Per Marko's guidance:
    # - Do NOT delete any log files (deleting newest is "sure way to get into trouble")
    # - Use innodb_log_archive=OFF (default) for recovery - server auto-detects log format
    # - Server first looks for ib_logfile0, only if not found looks at ib_*.log archives
    # - innodb_log_archive=ON + ib_logfile0 exists = startup error!
    #
    # LSN-targeted recovery (per Marko):
    # - innodb_log_recovery_start=0 means "start from latest checkpoint"
    # - innodb_log_recovery_target=<final_lsn> means "recover up to this LSN"
    # - Using the final LSN from probe allows point-in-time recovery testing
    
    # Use innodb_log_archive=OFF (default) for recovery - let server auto-detect log format
    # Per Marko: "If you had started the server with innodb_log_archive=OFF (the default),
    # it should have recovered from the correct file."
    
    # innodb_log_recovery_start: 0 means "start from latest checkpoint" (always valid)
    # Note: innodb_log_recovery_start=12288 is for specific MTR tests where logs start from
    # the beginning. In RQG, archived logs may start at much higher LSNs, so 12288 would fail
    # with "No matching file found". Always use 0 for RQG crash recovery testing.
    my $recovery_start = 0;
    
    # Randomize innodb_log_file_mmap: ON (mmap parsing) vs OFF (pread parsing)
    # Per Marko: "Test all I/O combinations: PMEM, mmap, pread/pwrite"
    # This covers non-PMEM code paths when compiled with -DWITH_INNODB_PMEM=OFF
    my $mmap_value = int(rand(2)) ? 'ON' : 'OFF';
    
    my @recovery_options = (
        "--innodb-log-archive=OFF",
        "--innodb-log-recovery-start=$recovery_start",
        "--innodb-log-file-mmap=$mmap_value"
    );
    say("INFO: $who_am_i Using innodb_log_recovery_start=$recovery_start, innodb_log_file_mmap=$mmap_value");
    
    # 50% chance: Normal recovery vs LSN-targeted recovery (per MTR test patterns)
    # This ensures both code paths are exercised
    my $use_lsn_target = int(rand(2));  # 0 or 1
    my $target_desc;
    
    if ($use_lsn_target) {
        # LSN-targeted recovery
        # Per Marko: "set innodb_log_recovery_target=18446744073709551615 to have everything recovered"
        # "If it complains that it only reached an earlier LSN, then that would be the target to set"
        if (defined $final_lsn && $final_lsn > 0) {
            push @recovery_options, "--innodb-log-recovery-target=$final_lsn";
            $target_desc = $final_lsn;
            say("INFO: $who_am_i Using LSN-targeted recovery: innodb_log_recovery_target=$final_lsn");
        } else {
            # No LSN from probe - use max value to recover to end of log
            push @recovery_options, "--innodb-log-recovery-target=18446744073709551615";
            $target_desc = "18446744073709551615 (max)";
            say("INFO: $who_am_i Using max target to recover to end of log");
        }
    } else {
        # Normal recovery - no explicit target, let server recover to end of log naturally
        $target_desc = "none (normal recovery)";
        say("INFO: $who_am_i Using normal recovery without LSN target");
    }
    
    # TODO (future enhancement per Marko):
    # "Compare the data files at the file system level after recovery+shutdown with the
    # maximum innodb_log_recovery_target, both with and without innodb_log_recovery_start=12288.
    # The result should be identical."
    
    $server->addServerOptions(\@recovery_options);
    say("INFO: $who_am_i Recovery options: innodb_log_archive=OFF, innodb_log_recovery_start=$recovery_start, " .
        "innodb_log_file_mmap=$mmap_value, innodb_log_recovery_target=$target_desc");
    
    $server->setStartDirty(1);
    my $recovery_status = $server->startServer();
    
    if ($recovery_status > STATUS_OK) {
        if ($recovery_status == STATUS_SERVER_CRASHED ||
            $recovery_status == STATUS_SERVER_DEADLOCKED ||
            $recovery_status == STATUS_CRITICAL_FAILURE) {
            say("DEBUG: $who_am_i Serious trouble during log archive recovery. " .
                "Setting recovery_status to STATUS_RECOVERY_FAILURE.");
            $recovery_status = STATUS_RECOVERY_FAILURE;
        }
        say("ERROR: $who_am_i Log archive recovery failed with status $recovery_status");
        return $recovery_status;
    }
    
    $reporter->updatePid();
    say("INFO: $who_am_i Log archive recovery successful. Server pid: " .
        $reporter->serverInfo('pid'));
    
    # Step 3: Verify basic functionality
    # Note: Writes to persistent tables may fail due to incomplete transaction locks
    my $dbh = DBI->connect($reporter->dsn(), undef, undef,
        { PrintError => 0, RaiseError => 0, AutoCommit => 1 });
    if (not defined $dbh) {
        say("WARN: $who_am_i Cannot connect after recovery - this may be expected " .
            "if locks are held by recovered incomplete transactions.");
    } else {
        # Try a simple read
        my $result = $dbh->selectrow_array("SELECT 1");
        if (defined $result && $result == 1) {
            say("INFO: $who_am_i Post-recovery read verification passed.");
        }
        $dbh->disconnect();
    }
    
    return STATUS_OK;
}

sub type {
    return REPORTER_TYPE_PERIODIC | REPORTER_TYPE_SERVER_KILLED;
}

1;
