# Copyright (c) 2018, 2022 MariaDB Corporation Ab.
# Copyright (c) 2023, 2024 MariaDB plc
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

package GenTest_e::Reporter::Mariabackup_linux;

# The reporter here is inspired by concepts and partially code found in
# - CloneSlaveXtrabackup.pm
#   Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
#   Copyright (c) 2013, Monty Program Ab.
# - lib/GenTest_e/Reporter/RestartConsistency.pm
#   Copyright (C) 2016 MariaDB Corporation Ab
#


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
use Data::Dumper;
use IPC::Open2;
use IPC::Open3;
use DBServer_e::MySQL::MySQLd;
use POSIX;

# Notes(mleich)
# -------------
# 0. When comparing this reporter to others than please consider the following difference in naming
#    Here      other reporter
#    source_*  master_*
#    clone_*   slave_*
#    which is intentional in order to make the code here better understandable.
#    The server on via mariabackup cloned data is not a replication slave.
# 1. There is a significant chance (observed!) that the first server dies before or during the
#    ... mariabackup --backup. We check if that server is connectable only after the backup
#    backup operation failed. All other operations do not need that this server is connectable.
# 2. The amount of information printed
#    Whereas some not too frequent "Reporter XYZ: All ok" is appreciated because it means
#    "at least at this point of time some sensitive observer did not find issues" we have
#    often serious trouble with the amount of information printed like
#    - from the perspective of the finally positive outcome:
#      In minimum temporary if not days lasting waste of disk space.
#    - in case the outcome is bad and we protocolled
#      - a lot
#        In minimum temporary if not days lasting waste of disk space for steps in the workflow
#        which simply passed. But at least maybe sufficient info for problem analysis.
#      - not much in order to reduce noise and safe disk space
#        Than we even do not know when the last promising result and the first suspicious
#        thing was maybe observable.
#    The experimental solution tried here is:
#    - Let whatever routines (!lib/DBServer_e/MySQL/MySQLd.pm!) write what they want anyway
#      (changing that is currently to intrusive+risky)
#    - Let system(<whatever>) babble to STDOUT/STDERR, do not redirect via command line to files
#      and fiddle than with these files depending on outcome.
#    - Write even "debug RQG quality" information to STDOUT. Example: CHECK TABLE ...
#    But redirect STDOUT/STDERR to a file $reporter_prt.
#    In case the reporter
#    - detects a problem than
#      Switch back to the usual STDOUT/STDERR (--> direct_to_stdout()) so that any additional/
#      decisive error messages become visible in the RQG log.
#      Maybe also print the content of $reporter_prt because
#         Now its valuable and not just noise. And maybe BW list matching will use it.
#      Do not delete $reporter_prt.
#    - has a run with success than
#      Switch back to the usual STDOUT/STDERR because other reporter might need it.
#      Report that success in case these messages will be not too frequent.
#      Delete $reporter_prt and go on.
# 3. Do not hesite to run "exit ..." instead of "return ..." in case the error met is bad enough.
#    The exit of the reporter process does not prevent that some parent process
#    - reaps return codes of child processes
#    - stops DB servers
#    - makes a cleanup in the vardir
# 4. Any message to be squeezed into the RQG protocol (all ERROR: ..., rare INFO: ... success)
#    must contain $who_am_i in order to make easy readable "who says what".
#    All other messages (going first into $reporter_prt) might omit $who_am_i.
# 5. Sorry for throwing STATUS_BACKUP_FAILURE maybe to excessive.
#    Quite often parts of the server or the RQG core could be also guilty.
#

# Warning:
# --------
# There might be frictions with the timeouts used in App/GenTest.pm after the loop OUTER.
use constant BACKUP_TIMEOUT  => 200;
use constant PREPARE_TIMEOUT => 200;

my $first_reporter;
my $client_basedir;

my $script_debug = 0;
my $last_call    = time() - 16;
$|=1;

my $reporter_prt = tmpdir() . "reporter_tmp.prt";
my $who_am_i     = "Reporter 'Mariabackup':";
my $backup_timeout;
my $prepare_timeout;
my $connect_timeout;

sub init {
    my $reporter = shift;
    if (not defined $reporter->testEnd()) {
        my $status = STATUS_INTERNAL_ERROR;
        say("ERROR: $who_am_i testEnd is not defined. " . Basics::exit_status_text($status));
        exit $status;
    }
    $backup_timeout     = Runtime::get_runtime_factor() * BACKUP_TIMEOUT;
    $prepare_timeout    = Runtime::get_runtime_factor() * PREPARE_TIMEOUT;
    $connect_timeout    = Runtime::get_connect_timeout();
    say("DEBUG: $who_am_i Effective timeouts, connect: $connect_timeout" .
        " backup: $backup_timeout prepare: $prepare_timeout") if $script_debug;
}

sub monitor {
    my $reporter = shift;

    my $status = STATUS_OK;

    # In case of several servers, we get called or might be called for any of them.
    # We perform only
    #   backup first server, make a clone based on that backup, check clone and destroy clone
    $first_reporter = $reporter if not defined $first_reporter;
    return STATUS_OK if $reporter ne $first_reporter;
    # This is the index of the first server!
    my $server_id = 0;

    $reporter->init if not defined $prepare_timeout;
    # say("DEBUG: $who_am_i Endtime: " . $reporter->testEnd()) if $script_debug;
    #

    # Ensure some minimum distance between two runs of the Reporter Mariabackup should be 15s.
    return STATUS_OK if $last_call + 15 > time();
    $last_call = time();

    if ($reporter->testEnd() <= time() + 5) {
        $status = STATUS_OK;
        say("INFO: $who_am_i Endtime is nearly exceeded. " . Basics::return_status_text($status));
        return $status;
    }

    my $mariabackup_timeout = $backup_timeout;

    # Access data about the first server
    my $server0 = $reporter->properties->servers->[0];
    my $basedir = $server0->basedir();

    $client_basedir = $reporter->serverInfo('client_bindir');

    unlink($reporter_prt);
    if (STATUS_OK != Basics::make_file($reporter_prt, undef)) {
        $status = STATUS_FAILURE;
        say("ERROR: Will return STATUS_ALARM because of previous failure.");
        return $status;
    }
    Basics::direct_to_file($reporter_prt);

    # Take over the settings for the first server.
    my @mysqld_options = @{$reporter->properties->servers->[0]->getServerOptions};

    if($script_debug) {
        Basics::direct_to_stdout();
        say("DEBUG: (new) mysqld_options\n" . join("\n", @mysqld_options));
        Basics::direct_to_file($reporter_prt);
    }

    # Reuse data for the clone if possible or adjust it.
    my $clone_basedir = $basedir;
    my $clone_user    = $server0->user();
    my $clone_vardir  = $server0->vardir()  . "_clone";
    # Use the standard layout like in MySQLd.pm.
    # FIXME: Standardization without duplicate code would be better.
    my $clone_datadir = $clone_vardir . "/data";
    my $clone_tmpdir  = $clone_vardir . "/tmp";
    my $clone_rrdir   = $clone_vardir . '/rr';

    ## Create clone database server directory structure
    if (STATUS_OK != Auxiliary::make_dbs_dirs($clone_vardir)) {
        Basics::direct_to_stdout();
        $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i Preparing the storage structure for the server '1_clone' failed. " .
            Basics::exit_status_text($status));
        exit $status;
    }

    if ($script_debug) {
        system("find $clone_vardir -follow") if $script_debug;
    }

    # FIXME: Do we really need all this?
    my $dsn             = $reporter->dsn();
#   my $binary          = $reporter->serverInfo('binary');

    my $lc_messages_dir = $reporter->serverVariable('lc_messages_dir');
    my $datadir         = $reporter->serverVariable('datadir');
    my $flush_method    = $reporter->serverVariable('innodb_flush_method');
    # flush_method read that way could be ''.
    # But when assigning that later mariabackup/mariadb abort (10.2).
    $datadir =~ s{[\\/]$}{}sgio;
    # 2020-02-27 The start of the server on the backupped data failed because this data
    # goes with a different InnoDB page size than the server default of 16K.
    my $innodb_page_size        = $reporter->serverVariable('innodb_page_size');
    # Useful because we should not go below the minimal innodb_buffer_pool_size.
    my $innodb_buffer_pool_size = $reporter->serverVariable('innodb_buffer_pool_size');

    # We make a backup of $clone_datadir within $rqg_backup_dir because in case of failure we
    # need these files not modified by mariabackup --prepare.
    my $rqg_backup_dir = $clone_vardir . '/fbackup';
    # We let the copy operation create the directory $rqg_backup_dir later.
    my $source_port    = $reporter->serverVariable('port');
    # FIXME:
    # This port computation is unsafe. There might be some already running server there.
    my $clone_port    =         $source_port + 4;
    my $log_output    =         $reporter->serverVariable('log_output');
    my $plugin_dir    =         $reporter->serverVariable('plugin_dir');
    my $fkm_file      =         $reporter->serverVariable('file_key_management_filename');
    my $innodb_use_native_aio = $reporter->serverVariable('innodb_use_native_aio');
    my $plugins       =         $reporter->serverPlugins();
    my ($version)     =         ($reporter->serverVariable('version') =~ /^(\d+\.\d+)\./);

    # Replace maybe by use of Auxiliary::find_file_at_places like in rqg_batch.pl
    # mariabackup could be in bin too.
    my $backup_binary = "$client_basedir" . "/mariadb-backup";
    if (not -e $backup_binary) {
        $backup_binary = "$client_basedir" . "/mariabackup";
    }
    if (not -e $backup_binary) {
        Basics::direct_to_stdout();
        $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i Calculated mariabackup binary '$backup_binary' not found. " .
            Basics::exit_status_text($status));
        exit $status;
    }
    # $backup_binary = $backup_binary . " --host=127.0.0.1 --user=root --password='' ";
    # --log-innodb-page-corruption
    #       Continue backup if innodb corrupted pages are found. The pages are logged in
    #       innodb_corrupted_pages and backup is finished with error.
    #       --prepare will try to fix corrupted pages. If innodb_corrupted_pages exists after
    #       --prepare in base backup directory, backup still contains corrupted pages and
    #       can not be considered as consistent.
    #       --log-innodb-page-corruption just gives more detailed information.
    $backup_binary .= " --skip-ssl-verify-server-cert --host=127.0.0.1 --user=root --password=''" .
                      " --log-innodb-page-corruption ";

    if (not osWindows()) {
    # Fake PMEM exists since MDEV-14425 in 10.8.
    # Mariabackup --backup with mmap (used on fake PMEM == /dev/shm) and rr cannot work.
    # If needing some rr trace than the following patch will help
    #
    # diff --git a/storage/innobase/log/log0log.cc b/storage/innobase/log/log0log.cc
    # index 69ee386293f..c6ad406f313 100644
    # --- a/storage/innobase/log/log0log.cc
    # +++ b/storage/innobase/log/log0log.cc
    # @@ -219,7 +219,7 @@ void log_t::attach(log_file_t file, os_offset_t size)
    #        my_mmap(0, size_t(size),
    #                srv_read_only_mode ? PROT_READ : PROT_READ | PROT_WRITE,
    #                MAP_SHARED_VALIDATE | MAP_SYNC, log.m_file, 0);
    # -#ifdef __linux__
    # +#ifdef MLEICH1
    #      if (ptr == MAP_FAILED)
    #      {
    #        struct stat st;
    #
    # The patch above is not used in QA "production".
    # In order to be on the safe side we just do not assign the innodb-use-native-aio value which
    # is used by the running server.
    #   $backup_binary .= " --innodb-use-native-aio=$innodb_use_native_aio ";
    }
    $backup_binary .= '--innodb_flush_method="' . $flush_method . '" '
        if (defined $flush_method and '' ne $flush_method);

    my $dbdir =       Local::get_dbdir();

    my $rr =          Runtime::get_rr();
    my $rr_options =  Runtime::get_rr_options();
    if (not defined $rr_options) {
        $rr_options = '';
    }

    my $backup_backup_prefix;
    my $backup_prepare_prefix;
    our $backup_prt =   "$clone_vardir/backup.prt";
    my $no_rr_prefix =  "exec ";
    my $rr_prefix =     "ulimit -c 0; exec rr record --mark-stdio $rr_options ";

    if (not defined $rr) {
        $backup_backup_prefix =     $no_rr_prefix;
        $backup_prepare_prefix =    $no_rr_prefix;
    } else {
        $ENV{'_RR_TRACE_DIR'} = $clone_vardir . '/rr';
        $backup_prepare_prefix =    $rr_prefix;
        if ($dbdir =~ /^\/dev\/shm\/rqg\//) {
            # Per standardlayout "/dev/shm/rqg" is a directory but not a mount point.
            say("INFO: Running mariabackup --backup not under rr because the DB server runs " .
                "on fake PMEM (/dev/shm).");
            $backup_backup_prefix = $no_rr_prefix;
        } else {
            $backup_backup_prefix = $rr_prefix;
        }
    }

# Experiment begin
sub TERM_handler {
    my $status = STATUS_OK;
    Basics::direct_to_stdout();
    say("DEBUG: $who_am_i SIGTERM caught.");
    if(not -e $backup_prt) {
        return $status;
    } else {
        my $mb_pid = Auxiliary::get_string_after_pattern($backup_prt,
                     "Starting Mariabackup as process ");
        if (not defined $mb_pid or '' eq $mb_pid) {
            $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: $who_am_i Unable to determine the pid of mariabackup. " .
                "Maybe the patch backup_pid_print.patch was not applied.");
            say(Basics::exit_status_text($status));
            sayFile($backup_prt);
            exit $status;
        } else {
            say("INFO: $who_am_i Send SIGTERM to pid $mb_pid running mariabackup");
            kill 'TERM' => $mb_pid;
            return $status;
        }
    }
}
# Experiment End

    # For experimenting:
    # $backup_binary = "not_exists ";
    # my $backup_backup_cmd = "$backup_binary --port=$source_port --hickup " .

    # A DB server under high load can write a huge amount of committed changes per time unit.
    # In case that exceeds the read speed of Mariabackup serious than we need to increase the
    # innodb_log_file_size in order to prevent that mariabackup --backup fails.
    # Observation 2022-07:
    # The DB server writes to /dev/shm/<somewhere> and mariabackup --backup reads from there.
    # The PMEM emulation used in the server writes gives the DB server some serious speed advantage.
    # There was a lot trouble.
    #
    # --log-copy-interval defines the copy interval between checks done by the log copying thread.
    # The given value is in milliseconds.

    my $backup_backup_cmd = "$backup_backup_prefix $backup_binary --port=$source_port --backup " .
                            "--datadir=$datadir --target-dir=$clone_datadir " .
                            "--log-copy-interval=1 > $backup_prt 2>&1";

    # Mariabackup could hang.
    my $alarm_msg      = '';
    my $alarm_timeout = 0;



# 1. Observation 2021-12
# mariabackup --backup is running.
# The reporter gets alarmed because a timeout was exceeded and aborts.
# The RQG runner aborts.
# The RQG worker generates a verdict and tries to make some archive.
# tar protests because reporter_prt changed during archiving.
# Reason:
# Output redirection leads to mariabackup writing into reporter_prt.
# And there is some mariabackup process alive though it should not.
#    (Coarse grained) solution:
#    The RQG worker has his own processgroup. He kills his processgroup
#    before finishing.
# 2. Observation 2024-01
#    mariabackup --backup is unable to finish because some innodb log resizing
#    happened. The timeout gets exceeded, the reporter exits and the RQG
#    test finishes. But the mariabackup process remains running.
#    (Fine grained) solution:
#    The reporter determines the id of the process running mariabackup --backup,
#    kills it 

    sigaction SIGALRM, new POSIX::SigAction sub {
        $status = STATUS_BACKUP_FAILURE;
        Basics::direct_to_stdout();
        say("ERROR: $who_am_i $alarm_msg");
        my $mb_pid = Auxiliary::get_string_after_pattern($backup_prt,
                     "Starting Mariabackup as process ");
        if (not defined $mb_pid or '' eq $mb_pid) {
            $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: $who_am_i Unable to determine the pid of mariabackup. " .
                "Maybe the patch backup_pid_print.patch was not applied.");
            say(Basics::exit_status_text($status));
            sayFile($backup_prt);
            exit $status;
        } else {
            say("INFO: $who_am_i Send SIGSEGV to pid $mb_pid running mariabackup");
            kill 'SEGV' => $mb_pid;
            Basics::direct_to_file($reporter_prt);
            # sayFile($backup_prt);
            return $status;
        }
    } or die "ERROR: $who_am_i Error setting SIGALRM handler: $!\n";

    if ($reporter->testEnd() <= time() + 5) {
        $status = STATUS_OK;
        Basics::direct_to_stdout();
        remove_clone_dbs_dirs($clone_vardir);
        say("INFO: $who_am_i Endtime is nearly exceeded. " . Basics::return_status_text($status));
        return $status;
    }

    $alarm_timeout = $backup_timeout;
    say("Executing backup: $backup_backup_cmd");
    $alarm_msg =  "Backup operation did not finish in " . $alarm_timeout . "s.";
    my $res;
    {
        local $SIG{TERM} =  'TERM_handler';
        alarm ($alarm_timeout);
        system("$backup_backup_cmd");
        $res = $?;
        alarm (0);
    }
    sayFile($backup_prt);
    if ($res != 0) {
        Basics::direct_to_stdout();
        if (STATUS_BACKUP_FAILURE == $status) {
            # The alarm kicked in and set a status.
            sayFile($reporter_prt);
            # The "sayFile" prints the content of $reporter_prt into the rqg.log.
            # Hence deleting $reporter_prt is acceptable.
            # remove_clone_dbs_dirs($clone_vardir);
            return $status;
        }
        # mariabackup --backup failing with
        #    [00] FATAL ERROR: 2022-05-20 18:56:44 failed to execute query BACKUP STAGE START:
        #         Deadlock found when trying to get lock; try restarting transaction
        # is a serious weakness but it does not count as bug.
        my $found = Auxiliary::search_in_file($backup_prt,
                        '\[00\] FATAL ERROR: .{1,20} failed to execute query ' .
                        'BACKUP STAGE START: Deadlock found when trying to get lock');
        if (not defined $found) {
            # Technical problems!
            $status = STATUS_ENVIRONMENT_FAILURE;
            say("FATAL ERROR: $who_am_i \$found is undef. " .
                Basics::exit_status_text($status));
            exit $status;
        } elsif ($found) {
            $status = STATUS_OK;
            say("INFO: $who_am_i BACKUP STAGE START failed with Deadlock. No bug. " .
                Basics::return_status_text($status) . " later.");
            sayFile($reporter_prt);
            remove_clone_dbs_dirs($clone_vardir);
            return $status;
        } else {
            # Nothing to do
        }

        # It is quite likely that the source DB server does no more react because of
        # crash, server freeze or similar.
        my $dbh = DBI->connect($dsn, undef, undef, {
            mysql_connect_timeout  => Runtime::get_connect_timeout(),
            PrintError             => 0,
            RaiseError             => 0,
            AutoCommit             => 0,
            mysql_multi_statements => 0,
            mysql_auto_reconnect   => 0
        });
        if (not defined $dbh) {
            $status = STATUS_CRITICAL_FAILURE;
            say("ERROR: $who_am_i Connect to dsn '" . $dsn . "'" . " failed: " . $DBI::errstr .
                Basics::exit_status_text($status));
            exit $status;
        }
        $dbh->disconnect();
        $status = STATUS_BACKUP_FAILURE;
        say("ERROR: $who_am_i Backup returned $res. The command output is around end of " .
            "'$reporter_prt'. " . Basics::exit_status_text($status));
        sayFile($reporter_prt);
        exit $status;
    }

    # Mariabackup --backup could report something like
    # ... | [00] 2021-03-24 17:48:10 Copying ./test/oltp1.ibd to /dev/shm/vardir/1616598218/209/1_clone/data/test/oltp1.new
    # ... | [00] 2021-03-24 17:48:10 Database page corruption detected at page 1, retrying...
    # ....
    # Error: failed to read page after 10 retries. File ./test/oltp1.ibd seems to be corrupted.
    # ...
    # [00] 2021-03-24 17:48:23 completed OK!
    # and give exit code 0.
    # In QA I cannot live with that alone.
    my $found = Auxiliary::search_in_file($reporter_prt,
                                          'Error: failed to read page after 10 retries. ' .
                                          'File .{1,200} seems to be corrupted.');
    if (not defined $found) {
        # Technical problems!
        $status = STATUS_ENVIRONMENT_FAILURE;
        Basics::direct_to_stdout();
        say("FATAL ERROR: $who_am_i \$found is undef. " . Basics::exit_status_text($status));
        exit $status;
    } elsif ($found) {
        Basics::direct_to_stdout();
        $status = STATUS_BACKUP_FAILURE;
        say("INFO: $who_am_i corrupted file detected. " . Basics::exit_status_text($status));
        sayFile($reporter_prt);
        # Wait some time because I fear that rr is just writing the trace.
        sleep 100;
        exit $status;
    } else {
        # Nothing to do
    }

    if (STATUS_OK != Basics::copy_dir_to_newdir($clone_datadir, $rqg_backup_dir . "/data")) {
        Basics::direct_to_stdout();
        $status = STATUS_INTERNAL_ERROR;
        say("ERROR: $who_am_i Copying '$clone_datadir' to '$rqg_backup_dir' failed. " .
            Basics::exit_status_text($status));
        exit $status;
    };
    # say("DEBUG: abspath to FBackup stuff ->" . Cwd::abs_path($rqg_backup_dir . "/data") . "<-");

    if ($reporter->testEnd() <= time() + 5) {
        $status = STATUS_OK;
        Basics::direct_to_stdout();
        remove_clone_dbs_dirs($clone_vardir);
        say("INFO: $who_am_i Endtime is nearly exceeded. " . Basics::exit_status_text($status));
        return $status;
    }

    # system("ls -ld " . $clone_datadir . "/ib_logfile*");
    my $backup_prepare_cmd = $backup_prepare_prefix . " $backup_binary --port=$clone_port " .
                             "--prepare --target-dir=$clone_datadir > $backup_prt 2>&1";
    say("Executing first prepare: $backup_prepare_cmd");
    $alarm_msg =  "Prepare operation 1 did not finish in " . $alarm_timeout . "s.";
    {
        local $SIG{TERM} =  'TERM_handler';
        alarm ($prepare_timeout);
        system("$backup_prepare_cmd");
        $res = $?;
        alarm (0);
    }
    # $SIG{TERM} = sub {say("DEBUG: $who_am_i SIGTERM caught. Will exit with STATUS_OK."); exit(0) };
    sayFile($backup_prt);
    if ($res != 0) {
        Basics::direct_to_stdout();
        $status = STATUS_BACKUP_FAILURE;
        say("ERROR: $who_am_i First prepare returned $res. The command output is around end of " .
            "'$reporter_prt'. " . Basics::exit_status_text($status));
        # Wait some time because I fear that rr ist just writing the trace.
        # sleep 100;
        if (defined Runtime::get_rr()) {
            # We try to generate a backtrace from the rr trace.
            Auxiliary::make_rr_backtrace($clone_vardir);
        }
        sayFile($reporter_prt);
        exit $status;
    }
    unlink($backup_prt);
    # system("ls -ld " . $clone_datadir . "/ib_logfile*");

    if ($reporter->testEnd() <= time() + 15) {
        $status = STATUS_OK;
        Basics::direct_to_stdout();
        remove_clone_dbs_dirs($clone_vardir);
        say("INFO: $who_am_i Endtime is nearly exceeded. " . Basics::return_status_text($status));
        return $status;
    }

    # Probably not needed because the checker might set that too.
    push @mysqld_options, '--loose-max-statement-time=0';
    # Probably not needed but maybe safer
    push @mysqld_options, '--loose_innodb_use_native_aio=0';
    # The main setup could be with some too short timeout.
    push @mysqld_options, '--connect_timeout=60';
    # We do not run Crashrecovery tests on the server running on backupped data.
    # Hence we can pick the fastest setting which is less safe.
    push @mysqld_options, '--sync_binlog=0';

    $|=1;

    # For experimenting:
    # The server start will fail because of unknown parameter.
    # And $clone_server->startServer should generate a backtrace.
    # push @mysqld_options, "--crap";

    # Let routines from lib/DBServer_e/MySQL/MySQLd.pm do as much of the job as possible.
    # I hope that this will work on WIN.
    # Warning:
    # Do not set the names of the server general log or error log like older code did.
    # This cannot work well when using DBServer_e::MySQL::MySQLd because that assumes some
    # standard layout with standard names below $clone_vardir.
    $server_id =  'backup';
    my $clone_server =  DBServer_e::MySQL::MySQLd->new(
                            basedir            => $clone_basedir,
                            vardir             => $clone_vardir,
                            port               => $clone_port,
                            start_dirty        => 1,
                            valgrind           => undef,
                            valgrind_options   => undef,
                            rr                 => $rr,
                            rr_options         => $rr_options,
                            server_options     => \@mysqld_options,
                            general_log        => 1,
                            config             => undef,
                            id                 => $server_id,
                            user               => $server0->user());

    my $server_name =   "server[$server_id]";
    my $clone_err =     $clone_server->errorlog();

    # system("ls -ld " . $clone_datadir . "/ib_logfile*");
    say("INFO: Attempt to start a DB server on the cloned data.");
    say("INFO: Per Marko messages like InnoDB: 1 transaction(s) which must be rolled etc. " .
        "are normal. MB prepare is not allowed to do rollbacks.");
    $status = $clone_server->startServer();
    if ($status != STATUS_OK) {
        Basics::direct_to_stdout();
        # It is intentional to exit with STATUS_BACKUP_FAILURE.
        $status = STATUS_BACKUP_FAILURE;
        say("ERROR: $who_am_i Starting a DB server on the cloned data failed.");
        sayFile($clone_err);
        sayFile($reporter_prt);
        say("ERROR: $who_am_i " . Basics::exit_status_text($status));
        exit $status;
    }

    if ($reporter->testEnd() <= time() + 10) {
        $status = STATUS_OK;
        Basics::direct_to_stdout();
        $clone_server->killServer();
        remove_clone_dbs_dirs($clone_vardir);
        say("INFO: $who_am_i Endtime is nearly exceeded. " . Basics::return_status_text($status));
        return $status;
    }

    Batch::append_string_to_file($reporter_prt, Basics::dash_line(length('')));

    # For experimenting:
    # The server gets killed with SIGABRT. Caused by that the connect attempt will fail.
    # $clone_server->crashServer();

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
        Basics::direct_to_stdout();
        # It is intentional to exit with STATUS_BACKUP_FAILURE.
        $status = STATUS_BACKUP_FAILURE;
        sayFile($clone_err);
        sayFile($reporter_prt);
        say("ERROR: $who_am_i Connect to the clone $server_name on port $clone_port failed. " .
            $DBI::errstr . " " . Basics::exit_status_text($status));
        $clone_server->make_backtrace;
        exit $status;
    }

    say("INFO: The clone $server_name has pid " . $clone_server->serverpid() .
        " and is connectable.");

    if ($reporter->testEnd() <= time() + 5) {
        $clone_dbh->disconnect();
        $status =   STATUS_OK;
        Basics::direct_to_stdout();
        $clone_server->killServer();
        remove_clone_dbs_dirs($clone_vardir);
        say("INFO: $who_am_i Endtime is nearly exceeded. " . Basics::return_status_text($status));
        return $status;
    }

    Batch::append_string_to_file($reporter_prt, Basics::dash_line(length('')));

    # Code taken from lib/GenTest_e/Reporter/RestartConsistency.pm
    say("INFO: $who_am_i Testing database consistency");

    my $databases = $clone_dbh->selectcol_arrayref("SHOW DATABASES");
    foreach my $database (@$databases) {
        if ($reporter->testEnd() <= time() + 5) {
            $clone_dbh->disconnect();
            $status =   STATUS_OK;
            Basics::direct_to_stdout();
            $clone_server->killServer();
            remove_clone_dbs_dirs($clone_vardir);
            say("INFO: $who_am_i Endtime is nearly exceeded. " . Basics::return_status_text($status));
            return $status;
        }
        # next if $database =~ m{^(mysql|information_schema|performance_schema)$}sio;
        # Experimental: Check the SCHEMA mysql too
        next if $database =~ m{^(rqg|information_schema|performance_schema)$}sio;
        $clone_dbh->do("USE $database");
        my $tabl_ref = $clone_dbh->selectcol_arrayref("SHOW FULL TABLES", { Columns=>[1,2] });
        # FIXME: The command above can fail.
        my %tables = @$tabl_ref;
        foreach my $table (keys %tables) {
            # For testing
            # $clone_server->crashServer();

            # Should not do CHECK etc., and especially ALTER, on a view
            next if $tables{$table} eq 'VIEW';
            my $sql = "CHECK TABLE `$database`.`$table` EXTENDED";
            $clone_dbh->do($sql);
            # 1178 is ER_CHECK_NOT_IMPLEMENTED
            # Experimental: Don't ignore error 1178
            # return STATUS_DATABASE_CORRUPTION if $clone_dbh->err() > 0 && $clone_dbh->err() != 1178;
            my $err = $clone_dbh->err;
            if (defined $err and $err > 0) {
                Basics::direct_to_stdout();
                say("ERROR: $who_am_i '$sql' failed with : " . $err);
                $clone_dbh->disconnect();
                sayFile($reporter_prt);
                my $snip = "the server running on cloned data.";
                if ($err == 2013 or $err == 2006) {
                    say("ERROR: $who_am_i Will call make_backtrace for " . $snip);
                    $clone_server->make_backtrace;
                } else {
                    sayFile($clone_err);
                    # It should be possible to replay what happened based on
                    # - the data backup copy and starting+checking
                    # - some rr trace if enabled
                    # Hence running some killServer now will not destroy valuable information or
                    # prevent to generate it later.
                    say("ERROR: $who_am_i Will kill " . $snip);
                    my $throw_away_status = $clone_server->killServer();
                }
                # The damage is some corruption.
                # Based on the fact that this is found in the server running on the backuped data
                # I prefer to return STATUS_BACKUP_FAILURE and not STATUS_DATABASE_CORRUPTION.
                $status =   STATUS_BACKUP_FAILURE;
                say("ERROR: $who_am_i " . Basics::exit_status_text($status));
                exit $status;
            }
        }
    }
    say("INFO: $who_am_i The tables in the schemas (except information_schema, " .
        "performance_schema) of the cloned server did not look corrupt.");
    $clone_dbh->disconnect();

    # FIXME:
    # Add dumping (mysqldump) all object definitions.
    # If that fails
    # - (likely) something with the data content in the cloned server is "ill"
    # - (rare)   mysqldump is ill

    # Going with stopServer (first shutdown attempt, SIGKILL maybe later) is intentional.
    # I can at least imagine that some server on backup data can be started, passes checks
    # but is otherwise somehow damaged. And these damages become maybe visible when having
    # - heavy DML+DDL including some runtime of more than 60s which we do not have here
    # - a "friendly" shutdown
    $status = $clone_server->stopServer();
    if (STATUS_OK != $status) {
        Basics::direct_to_stdout();
        $status = STATUS_BACKUP_FAILURE;
        say("ERROR: $who_am_i Shutdown of DB server on cloned data made trouble. ".
            "Hence trying to kill it and return STATUS_BACKUP_FAILURE later.");
        my $throw_away_status = $clone_server->killServer();
        sayFile($clone_err);
        sayFile($reporter_prt);
        say("ERROR: $who_am_i " . Basics::return_status_text($status));
        return $status;
    }
    remove_clone_dbs_dirs($clone_vardir);
    # system("find $clone_vardir -follow");
    Basics::direct_to_stdout();
    # Even if the backup operation was successful the protocol should be rather not deleted.
    # Maybe it contains warnings or error messages RQG currently does not care about.
    # unlink ($reporter_prt);
    say("INFO: $who_am_i Pass");

    return STATUS_OK;
}

sub type {
    return REPORTER_TYPE_PERIODIC;
}

sub remove_clone_dbs_dirs {
    my ($clone_vardir) = @_;
    if (STATUS_OK != Auxiliary::remove_dbs_dirs($clone_vardir)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i Removing the storage structure for the server '1_clone' failed. " .
            Basics::exit_status_text($status));
        exit $status;
    }
}

1;
