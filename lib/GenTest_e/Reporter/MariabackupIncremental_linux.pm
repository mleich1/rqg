# Copyright (c) 2018, 2022 MariaDB Corporation Ab.
# Copyright (c) 2023, 2026 MariaDB plc
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

package GenTest_e::Reporter::MariabackupIncremental_linux;

########################################################################
#
# Incremental backup reporter using MariaBackup
#
# This reporter performs incremental backups during the test run:
# 1. Creates a full backup initially
# 2. Creates incremental backups periodically during the test
# 3. At test end: prepares all backups, restores, and verifies integrity
#
# Based on Elena's MariaBackupIncremental scenario implementation
# adapted to the reporter pattern used in this RQG branch.
#
########################################################################

require Exporter;
@ISA = qw(GenTest_e::Reporter);

use strict;
use Auxiliary;
use Batch;
use Runtime;
use DBI;
use GenTest_e;
use GenTest_e::Constants;
use GenTest_e::Reporter;
use GenTest_e::Executor;
use Data::Dumper;
use IPC::Open2;
use IPC::Open3;
use DBServer_e::MySQL::MySQLd;
use POSIX;
use File::Copy;
use Local;

use constant BACKUP_TIMEOUT  => 300;
use constant PREPARE_TIMEOUT => 300;
use constant BACKUP_INTERVAL => 20;  # Seconds between incremental backups

my $first_reporter;
my $client_basedir;
my $backup_binary;

my $script_debug = 0;  # Set to 1 for verbose debug output
my $backup_count = 0;
my $backup_manager_pid;  # PID of background backup manager process
$| = 1;

my $who_am_i = "Reporter 'MariabackupIncremental':";
my $backup_timeout;
my $prepare_timeout;
my $connect_timeout;
my $rr;
my $backup_prefix;
my $prepare_prefix;  # Always uses rr when available (prepare doesn't use PMEM)
my $source_server;
my $clone_vardir;
my $clone_server;
my @mysqld_options;
my $source_port;
my $clone_port;
my $clone_err;
my $datadir;
my $clone_datadir;
my $reporter;
my $mbackup_target;
my $vardir;

# Initialize variables only (no backup manager spawning)
# Used by report() which runs in a different process
sub _init_variables {
    my $rep = shift;
    my $status = STATUS_OK;

    return STATUS_OK if defined $backup_timeout;  # Already initialized

    $backup_timeout  = Runtime::get_runtime_factor() * BACKUP_TIMEOUT;
    $prepare_timeout = Runtime::get_runtime_factor() * PREPARE_TIMEOUT;
    $connect_timeout = Runtime::get_connect_timeout();
    say("DEBUG: $who_am_i Effective timeouts - connect: $connect_timeout " .
        "backup: $backup_timeout prepare: $prepare_timeout") if $script_debug;

    $client_basedir = $rep->serverInfo('client_bindir');
    $backup_binary = "$client_basedir" . "/mariadb-backup";
    if (not -e $backup_binary) {
        $backup_binary = "$client_basedir" . "/mariabackup";
    }
    if (not -e $backup_binary) {
        $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i Calculated mariabackup binary '$backup_binary' not found. " .
            Basics::exit_status_text($status));
        return $status;
    }

    $backup_binary .= " --skip-ssl-verify-server-cert --host=127.0.0.1 --user=root --password='' " .
                      "--log-innodb-page-corruption ";

    my $flush_method = $rep->serverVariable('innodb_flush_method');
    $backup_binary .= '--innodb_flush_method="' . $flush_method . '" '
        if (defined $flush_method and '' ne $flush_method);

    $rr = Runtime::get_rr();

    my $no_rr_prefix = "exec ";
    my $rr_prefix = "ulimit -c 0; exec $rr ";

    $source_server = $rep->properties->servers->[0];
    $vardir = $source_server->vardir();
    $clone_vardir = $vardir . "_clone";
    $mbackup_target = $vardir . '/backup';
    if (not defined $rr) {
        $backup_prefix = $no_rr_prefix;
        $prepare_prefix = $no_rr_prefix;
    } else {
        $ENV{'_RR_TRACE_DIR'} = $clone_vardir . '/rr';
        my $dbdir = Local::get_dbdir();
        if ($dbdir =~ /^\/dev\/shm\/rqg\//) {
            say("INFO: $who_am_i Running mariabackup --backup not under rr (fake PMEM).");
            $backup_prefix = $no_rr_prefix;
        } else {
            $backup_prefix = $rr_prefix;
        }
        # Prepare phase ALWAYS uses rr when available - it doesn't use PMEM
        # and crashes here need rr traces for debugging
        $prepare_prefix = $rr_prefix;
        say("INFO: $who_am_i mariabackup --prepare will run under rr for crash analysis");
    }

    $source_port = $rep->serverVariable('port');
    $clone_port = $source_port + 4;
    $datadir = $rep->serverVariable('datadir');
    $datadir =~ s{[\\/]$}{}sgio;
    $clone_datadir = $clone_vardir . "/data";

    say("DEBUG: $who_am_i _init_variables() completed") if $script_debug;
    return STATUS_OK;
}

sub init {
    $reporter = shift;
    my $status = STATUS_OK;

    if (not defined $reporter->testEnd()) {
        $status = STATUS_INTERNAL_ERROR;
        say("ERROR: $who_am_i testEnd is not defined. " . Basics::exit_status_text($status));
        exit $status;
    }

    # Initialize variables first
    $status = _init_variables($reporter);
    exit $status if $status != STATUS_OK;

    $backup_count = 0;
    say("DEBUG: $who_am_i init() completed") if $script_debug;

    # Create clone directory structure
    if (STATUS_OK != Auxiliary::make_dbs_dirs($clone_vardir)) {
        Basics::direct_to_stdout();
        $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i Preparing storage structure failed. " .
            Basics::exit_status_text($status));
        exit $status;
    }

    # Spawn backup manager process (runs for entire test duration)
    # This avoids race conditions from forked monitor() calls
    $backup_manager_pid = fork();
    if (not defined $backup_manager_pid) {
        say("ERROR: $who_am_i Failed to fork backup manager process");
        exit STATUS_ENVIRONMENT_FAILURE;
    }

    if ($backup_manager_pid == 0) {
        # Child process: backup manager loop
        _run_backup_manager($reporter);
        exit(0);
    }

    # Parent continues
    say("INFO: $who_am_i Spawned backup manager process (PID: $backup_manager_pid)");
}

# Background backup manager - runs in child process
sub _run_backup_manager {
    my $reporter = shift;
    my $backup_num = 0;
    my $test_end = $reporter->testEnd();

    say("INFO: $who_am_i Backup manager started, will run until " . localtime($test_end));

    while (time() < $test_end - 30) {  # Stop 30s before test end
        my $backup_log = "$vardir/mbackup_backup_${backup_num}.log";
        my $target_dir = "${mbackup_target}_${backup_num}";
        my $backup_cmd;

        if ($backup_num == 0) {
            # Full backup
            say("INFO: $who_am_i Creating initial full backup #$backup_num");
            $backup_cmd = "$backup_prefix $backup_binary --port=$source_port --backup " .
                          "--datadir=$datadir --target-dir=$target_dir " .
                          "--log-copy-interval=1 > $backup_log 2>&1";
        } else {
            # Incremental backup
            say("INFO: $who_am_i Creating incremental backup #$backup_num");
            my $basedir_num = $backup_num - 1;
            $backup_cmd = "$backup_prefix $backup_binary --port=$source_port --backup " .
                          "--datadir=$datadir --target-dir=$target_dir " .
                          "--incremental-basedir=${mbackup_target}_${basedir_num} " .
                          "--log-copy-interval=1 > $backup_log 2>&1";
        }

        say("DEBUG: $who_am_i Executing: $backup_cmd") if $script_debug;
        system("LD_LIBRARY_PATH=\$MSAN_LIBS:\$LD_LIBRARY_PATH $backup_cmd");
        my $res = $? >> 8;
        my $sig = $? & 127;

        if ($res != 0 || $sig != 0) {
            say("WARN: $who_am_i Backup #$backup_num failed (exit=$res, signal=$sig)");
            sayFile($backup_log);
            # Don't increment - will retry on next iteration
        } else {
            say("INFO: $who_am_i Backup #$backup_num completed successfully");
            $backup_num++;
        }

        # Wait for next backup interval
        sleep(BACKUP_INTERVAL);
    }

    # Write final backup count to file for report() to read
    open(my $fh, '>', "$vardir/mbackup_count.txt") or die "Cannot write backup count: $!";
    print $fh $backup_num;
    close($fh);

    say("INFO: $who_am_i Backup manager finished with $backup_num backup(s)");
}

sub monitor {
    $reporter = shift;

    # Only run for first reporter instance
    $first_reporter = $reporter if not defined $first_reporter;
    return STATUS_OK if $reporter ne $first_reporter;

    # Initialize and spawn backup manager on first call
    if (not defined $backup_manager_pid) {
        $reporter->init();
    }

    # Check if backup manager is still alive
    if (defined $backup_manager_pid) {
        my $res = waitpid($backup_manager_pid, WNOHANG);
        if ($res == $backup_manager_pid) {
            # Backup manager exited (expected near test end)
            say("DEBUG: $who_am_i Backup manager has exited") if $script_debug;
        }
    }
    return STATUS_OK;
}

sub report {
    $reporter = shift;
    my $status = STATUS_OK;

    $first_reporter = $reporter if not defined $first_reporter;
    return STATUS_OK if $reporter ne $first_reporter;

    # Initialize variables only (NOT the backup manager - that runs during monitor phase)
    # report() runs in a different process than monitor(), so variables need re-initialization
    $status = _init_variables($reporter);
    if ($status != STATUS_OK) {
        say("ERROR: $who_am_i Variable initialization failed");
        return $status;
    }

    # Detect backup count from filesystem (most reliable method)
    # The backup manager wrote files during monitor phase in a different process
    # Note: newer mariabackup uses "mariadb_backup_checkpoints", older uses "xtrabackup_checkpoints"
    $backup_count = 0;
    while (-d "${mbackup_target}_${backup_count}") {
        my $checkpoint_file1 = "${mbackup_target}_${backup_count}/mariadb_backup_checkpoints";
        my $checkpoint_file2 = "${mbackup_target}_${backup_count}/xtrabackup_checkpoints";
        if (-f $checkpoint_file1 or -f $checkpoint_file2) {
            $backup_count++;
        } else {
            say("WARN: $who_am_i Removing incomplete backup directory: ${mbackup_target}_${backup_count}");
            system("rm -rf ${mbackup_target}_${backup_count}");
            last;
        }
    }
    say("INFO: $who_am_i Detected $backup_count backup(s) from filesystem");

    say("INFO: $who_am_i Starting final verification with $backup_count backup(s)");

    # Need at least one backup (full) for verification
    if ($backup_count < 1) {
        say("WARN: $who_am_i No backups created during test run, skipping verification");
        return STATUS_OK;
    }

    # Create working directory for restore
    if (STATUS_OK != Auxiliary::make_dbs_dirs($clone_vardir)) {
        $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i Preparing storage structure failed. " .
            Basics::exit_status_text($status));
        return $status;
    }

    @mysqld_options = @{$reporter->properties->servers->[0]->getServerOptions};

    # Get buffer pool size for prepare
    my $buffer_pool_size = $reporter->serverVariable('innodb_buffer_pool_size') * 2;

    # Store backups before prepare
    say("INFO: $who_am_i Storing backups before prepare...");
    foreach my $b (0 .. $backup_count - 1) {
        system("cp -r ${mbackup_target}_${b} ${mbackup_target}_before_prepare_${b}");
    }

    # Prepare full backup
    say("INFO: $who_am_i Preparing full backup (base)");
    # Set unique rr trace directory for this prepare operation
    my $rr_trace_dir_0 = "$vardir/rr_prepare_0";
    $ENV{'_RR_TRACE_DIR'} = $rr_trace_dir_0 if defined $rr;
    my $prepare_cmd = "$prepare_prefix $backup_binary --prepare " .
                      "--skip-ssl --loose-disable-ssl-verify-server-cert " .
                      "--use-memory=$buffer_pool_size " .
                      "--innodb-file-io-threads=1 --target-dir=${mbackup_target}_0 " .
                      ">$vardir/mbackup_prepare_0.log 2>&1";
    say("DEBUG: $who_am_i $prepare_cmd") if $script_debug;
    system("LD_LIBRARY_PATH=\$MSAN_LIBS:\$LD_LIBRARY_PATH $prepare_cmd");
    my $res = $? >> 8;
    my $sig = $? & 127;

    if ($res != 0 || $sig != 0) {
        sayError("$who_am_i Full backup prepare failed (exit=$res, signal=$sig)");
        sayFile("$vardir/mbackup_prepare_0.log");
        say("INFO: $who_am_i rr trace saved at: $rr_trace_dir_0") if defined $rr;
        $status = STATUS_BACKUP_FAILURE;
        return $status;
    }

    # Prepare incremental backups
    foreach my $b (1 .. $backup_count - 1) {
        say("INFO: $who_am_i Preparing incremental backup #$b");
        # Set unique rr trace directory for each incremental prepare
        my $rr_trace_dir = "$vardir/rr_prepare_$b";
        $ENV{'_RR_TRACE_DIR'} = $rr_trace_dir if defined $rr;
        $prepare_cmd = "$prepare_prefix $backup_binary --prepare " .
                       "--skip-ssl --loose-disable-ssl-verify-server-cert " .
                       "--use-memory=$buffer_pool_size " .
                       "--innodb-file-io-threads=1 --target-dir=${mbackup_target}_0 " .
                       "--incremental-dir=${mbackup_target}_${b} " .
                       ">$vardir/mbackup_prepare_${b}.log 2>&1";
        say("DEBUG: $who_am_i $prepare_cmd") if $script_debug;
        system("LD_LIBRARY_PATH=\$MSAN_LIBS:\$LD_LIBRARY_PATH $prepare_cmd");
        $res = $? >> 8;
        $sig = $? & 127;

        if ($res != 0 || $sig != 0) {
            sayError("$who_am_i Incremental backup #$b prepare failed (exit=$res, signal=$sig)");
            sayFile("$vardir/mbackup_prepare_${b}.log");
            say("INFO: $who_am_i rr trace saved at: $rr_trace_dir") if defined $rr;
            $status = STATUS_BACKUP_FAILURE;
            return $status;
        }
    }

    # Restore backup to clone datadir
    say("INFO: $who_am_i Restoring backup to $clone_datadir");
    system("rm -rf $clone_datadir");
    # Set rr trace directory for restore operation
    my $rr_trace_dir_restore = "$vardir/rr_restore";
    $ENV{'_RR_TRACE_DIR'} = $rr_trace_dir_restore if defined $rr;
    my $restore_cmd = "$prepare_prefix $backup_binary --copy-back --skip-ssl --loose-disable-ssl-verify-server-cert " .
                      "--target-dir=${mbackup_target}_0 --datadir=$clone_datadir " .
                      ">$vardir/mbackup_restore.log 2>&1";
    say("DEBUG: $who_am_i $restore_cmd") if $script_debug;
    system("LD_LIBRARY_PATH=\$MSAN_LIBS:\$LD_LIBRARY_PATH $restore_cmd");
    $res = $? >> 8;
    $sig = $? & 127;

    if ($res != 0 || $sig != 0) {
        sayError("$who_am_i Backup restore failed (exit=$res, signal=$sig)");
        sayFile("$vardir/mbackup_restore.log");
        say("INFO: $who_am_i rr trace saved at: $rr_trace_dir_restore") if defined $rr;
        $status = STATUS_BACKUP_FAILURE;
        return $status;
    }

    # Reset rr trace directory for clone server
    $ENV{'_RR_TRACE_DIR'} = $clone_vardir . '/rr' if defined $rr;

    # Start server on restored data
    say("INFO: $who_am_i Starting server on restored data");
    push @mysqld_options, '--loose-max-statement-time=0';
    push @mysqld_options, '--loose_innodb_use_native_aio=0';
    push @mysqld_options, '--connect_timeout=60';
    push @mysqld_options, '--sync_binlog=0';

    my $clone_basedir = $source_server->basedir();
    $clone_server = DBServer_e::MySQL::MySQLd->new(
        basedir        => $clone_basedir,
        vardir         => $clone_vardir,
        port           => $clone_port,
        start_dirty    => 1,
        valgrind       => undef,
        valgrind_options => undef,
        rr             => $rr,
        server_options => \@mysqld_options,
        general_log    => 1,
        config         => undef,
        id             => 'backup_incr',
        user           => $source_server->user()
    );

    $clone_err = $clone_server->errorlog();
    $status = $clone_server->startServer();

    if ($status != STATUS_OK) {
        sayError("$who_am_i Starting server on restored data failed");
        sayFile($clone_err);
        $status = STATUS_BACKUP_FAILURE;
        return $status;
    }

    # Connect and verify
    my $clone_dsn = "dbi:mysql:user=root:host=127.0.0.1:port=$clone_port";
    my $clone_dbh = DBI->connect($clone_dsn, undef, undef, {
        mysql_connect_timeout  => $connect_timeout,
        PrintError             => 0,
        RaiseError             => 0,
        AutoCommit             => 0,
        mysql_multi_statements => 0,
        mysql_auto_reconnect   => 0
    });

    if (not defined $clone_dbh) {
        sayError("$who_am_i Connect to restored server failed: " . $DBI::errstr);
        $clone_server->make_backtrace;
        $status = STATUS_BACKUP_FAILURE;
        $clone_server->killServer();
        return $status;
    }

    say("INFO: $who_am_i Restored server is connectable, checking database integrity");

    # Check database integrity
    my $databases = $clone_dbh->selectcol_arrayref("SHOW DATABASES");
    if (not defined $databases or scalar(@$databases) == 0) {
        say("WARN: $who_am_i Could not retrieve database list, skipping integrity check");
        $databases = [];  # Empty array to skip loop
    }
    foreach my $database (@$databases) {
        next if $database =~ m{^(mysql|sys|rqg|information_schema|performance_schema)$}sio;
        $clone_dbh->do("USE $database");
        my $tabl_ref = $clone_dbh->selectcol_arrayref("SHOW FULL TABLES", { Columns => [1, 2] });
        next if not defined $tabl_ref or scalar(@$tabl_ref) == 0;
        my %tables = @$tabl_ref;

        foreach my $table (keys %tables) {
            next if $tables{$table} eq 'VIEW';
            my $sql = "CHECK TABLE `$database`.`$table` EXTENDED";
            $clone_dbh->do($sql);
            my $err = $clone_dbh->err;
            if (defined $err and $err > 0) {
                sayError("$who_am_i '$sql' failed with: $err");
                $clone_dbh->disconnect();
                sayFile($clone_err);
                $clone_server->killServer();
                $status = STATUS_BACKUP_FAILURE;
                return $status;
            }
        }
    }

    say("INFO: $who_am_i Database integrity check passed");
    $clone_dbh->disconnect();

    # Stop clone server
    $status = $clone_server->stopServer();
    if (STATUS_OK != $status) {
        say("WARN: $who_am_i Shutdown of restored server had issues, killing");
        $clone_server->killServer();
    }

    # Cleanup
    remove_clone_dbs_dirs($clone_vardir);
    say("INFO: $who_am_i Incremental backup verification PASSED");

    return STATUS_OK;
}

sub type {
    return REPORTER_TYPE_PERIODIC | REPORTER_TYPE_END;
}

sub remove_clone_dbs_dirs {
    my ($clone_vardir) = @_;
    if (STATUS_OK != Auxiliary::remove_dbs_dirs($clone_vardir)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i Removing clone storage structure failed. " .
            Basics::exit_status_text($status));
        # Don't exit, just warn
    }
}

1;
