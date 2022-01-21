# Copyright (c) 2018, 2022 MariaDB Corporation Ab.
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

package GenTest::Reporter::Mariabackup_linux;

# The reporter here is inspired by concepts and partially code found in
# - CloneSlaveXtrabackup.pm
#   Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
#   Copyright (c) 2013, Monty Program Ab.
# - lib/GenTest/Reporter/RestartConsistency.pm
#   Copyright (C) 2016 MariaDB Corporation Ab
#


require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use Auxiliary;
use Runtime;
use DBI;
use GenTest;
use GenTest::Constants;
use GenTest::Reporter;
use Data::Dumper;
use IPC::Open2;
use IPC::Open3;
use DBServer::MySQL::MySQLd;
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
#    - Let whatever routines (!lib/DBServer/MySQL/MySQLd.pm!) write what they want anyway
#      (changing that is currently to intrusive+risky)
#    - Let system(<whatever>) babble to STDOUT/STDERR, do not redirect via command line to files
#      and fiddle than with these files depending on outcome.
#    - Write even "debug RQG quality" information to STDOUT. Example: CHECK TABLE ...
#    But redirect STDOUT/STDERR to a file $reporter_prt.
#    In case the reporter
#    - detects a problem than
#      Switch back to the usual STDOUT/STDERR (--> direct_to_std()) so that any additional/
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

use constant BACKUP_TIMEOUT  => 180;
use constant PREPARE_TIMEOUT => 600;

my $first_reporter;
my $client_basedir;

my $script_debug = 1;
my $last_call    = time() - 16;
$|=1;

# tmpdir() has a '/' at end.
my $reporter_prt = tmpdir() . "reporter_tmp.prt";
my $who_am_i     = 'Reporter Mariabackup';
my $backup_timeout;
my $prepare_timeout;
my $connect_timeout;

sub init {
    my $reporter = shift;
    if (not defined $reporter->testEnd()) {
        say("ERROR: $who_am_i testEnd is not defined. Will exit with exit status " .
            "STATUS_INTERNAL_ERROR(" . STATUS_INTERNAL_ERROR . ").");
        exit STATUS_INTERNAL_ERROR;
    }
    $backup_timeout     = Runtime::get_runtime_factor() * BACKUP_TIMEOUT;
    $prepare_timeout    = Runtime::get_runtime_factor() * PREPARE_TIMEOUT;
    $connect_timeout    = Runtime::get_connect_timeout();
    say("DEBUG: $who_am_i Effective timeouts, connect: $connect_timeout" .
        " backup: $backup_timeout prepare: $prepare_timeout") if $script_debug;
}

sub monitor {
    my $reporter = shift;

    $reporter->init if not defined $prepare_timeout;
    # say("DEBUG: $who_am_i : Endtime: " . $reporter->testEnd()) if $script_debug;
    #

    # Ensure some minimum distance between two runs of the Reporter Mariabackup should be 15s.
    return STATUS_OK if $last_call + 15 > time();
    $last_call = time();

    if ($reporter->testEnd() <= time() + 5) {
        my $status = STATUS_OK;
        say("INFO: $who_am_i : Endtime is nearly exceeded. " . Auxiliary::build_wrs($status));
        return $status;
    }

    # In case of several servers, we get called or might be called for any of them.
    # We perform only
    #   backup first server, make a clone based on that backup, check clone and destroy clone
    #

    direct_to_file();

    $first_reporter = $reporter if not defined $first_reporter;
    return STATUS_OK if $reporter ne $first_reporter;

    my $mariabackup_timeout = $backup_timeout;

    # Access data about the first server
    my $server0 = $reporter->properties->servers->[0];
    my $basedir = $server0->basedir();

    # FIXME: Replace by some routine located in Auxiliary.pm
    foreach my $path ("$basedir/../client", "$basedir/../bin",
                      "$basedir/client/RelWithDebInfo", "$basedir/client/Debug",
                      "$basedir/client", "$basedir/bin") {
        if (-e $path) {
            $client_basedir = $path;
            last;
        }
    }
    if (not defined $client_basedir) {
        direct_to_std();
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i : Can't determine client_basedir. basedir is '$basedir'. " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
        # We run this that early because in case of failure the game is over anyway.
        # Based on the facts that
        # - here acts a reporter process which is handled well in RQG core
        # - the failure is heavy and other reporters cannot give valuable additional info
        # exit instead of return is acceptable.
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
    foreach my $dir ( $clone_vardir, $clone_datadir, $clone_tmpdir, $clone_rrdir) {
        if (not mkdir($dir)) {
            direct_to_std();
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: $who_am_i : mkdir($dir) failed with : $!. " .
                "Will exit with status " . status2text($status) . "($status)");
            exit $status;
        }
    }

    if ($script_debug) {
        system("find $clone_vardir -follow") if $script_debug;
    }

    # FIXME: Do we really need all this?
    my $dsn             = $reporter->dsn();
    my $binary          = $reporter->serverInfo('binary');

    my $lc_messages_dir = $reporter->serverVariable('lc_messages_dir');
    my $datadir         = $reporter->serverVariable('datadir');
    my $flush_method    = $reporter->serverVariable('innodb_flush_method');
    # flush_method read that way could be ''.
    # But when assigning that later mariabackup/mariadb abort (10.2).
    $datadir =~ s{[\\/]$}{}sgio;
    # 2020-02-27 The start of the server on the backuped data failed because this data
    # goes with a different InnoDB page size than the server default of 16K.
    my $innodb_page_size = $reporter->serverVariable('innodb_page_size');

    # We make a backup of $clone_datadir within $rqg_backup_dir because in case of failure we
    # need these files not modified by mariabackup --prepare.
    my $rqg_backup_dir = $server0->datadir() . '_backup';
    # We let the copy operation create the directory $rqg_backup_dir later.
    my $source_port    = $reporter->serverVariable('port');
    # FIXME:
    # This port computation is unsafe. There might be some already running server there.
    my $clone_port    = $source_port + 4;
    my $plugin_dir    = $reporter->serverVariable('plugin_dir');
    my $fkm_file      = $reporter->serverVariable('file_key_management_filename');
    my $plugins       = $reporter->serverPlugins();
    my ($version)     = ( $reporter->serverVariable('version') =~ /^(\d+\.\d+)\./ ) ;

    # Replace maybe by use of Auxiliary::find_file_at_places like in rqg_batch.pl
    # mariabackup could be in bin too.
    my $backup_binary = "$client_basedir" . "/mariabackup";
    if (not -e $backup_binary) {
        direct_to_std();
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i : Calculated mariabackup binary '$backup_binary' not found. " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }
    # $backup_binary = $backup_binary . " --host=127.0.0.1 --user=root --password='' ";
    # --log-innodb-page-corruption
    #                   Continue backup if innodb corrupted pages are found. The
    #                   pages are logged in innodb_corrupted_pages and backup is
    #                   finished with error. --prepare will try to fix corrupted
    #                   pages. If innodb_corrupted_pages exists after --prepare
    #                   in base backup directory, backup still contains corrupted
    #                   pages and can not be considered as consistent.
    # --log-innodb-page-corruption just gives more detailed information.
    $backup_binary .= " --host=127.0.0.1 --user=root --password='' --log-innodb-page-corruption ";

    if (not osWindows()) {
        $backup_binary .= " --innodb-use-native-aio=0 ";
    }
    $backup_binary .= '--innodb_flush_method="' . $flush_method . '" '
        if (defined $flush_method and '' ne $flush_method);

    my $rr =          Runtime::get_rr();
    my $rr_options =  Runtime::get_rr_options();
    my $rr_addition = '';
    if (defined $rr and $rr eq Runtime::RR_TYPE_EXTENDED) {
        $rr_options =  '' if not defined $rr_options;
        $ENV{'_RR_TRACE_DIR'} = $clone_rrdir;
        $rr_addition = "ulimit -c 0; rr record --mark-stdio $rr_options";
    }

    # For experimenting:
    # $backup_binary = "not_exists ";
    # my $backup_backup_cmd = "$backup_binary --port=$source_port --hickup " .
    # Mariabackup --backup with mmap and rr cannot work.
    # If needing some rr trace than the following patch will help
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
    my $backup_backup_cmd = " $backup_binary --port=$source_port --backup " .
                            "--datadir=$datadir --target-dir=$clone_datadir";

    # Mariabackup could hang.
    my $exit_msg      = '';
    my $alarm_timeout = 0;

# FIXME:
# Observation 2021-12
# mariabackup --backup is running.
# The reporter gets alarmed because a timeout was exceeded and aborts.
# The RQG runner aborts.
# The RQG worker generates a verdict and tries to make some archive.
# tar protests because reporter_prt changed during archiving.
# Reason:
# Output redirection leads to mariabackup writing into reporter_prt.
# And the some mariabackup process is alive though it should not.

    sigaction SIGALRM, new POSIX::SigAction sub {
        direct_to_std();
        # Concept:
        # Set the error_exit_message before setting the alarm.
        say("ERROR: $who_am_i $exit_msg" .
            " Will exit with STATUS_BACKUP_FAILURE.");
        sayFile($reporter_prt);
        exit STATUS_BACKUP_FAILURE;
    } or die "ERROR: $who_am_i Error setting SIGALRM handler: $!\n";

    if ($reporter->testEnd() <= time() + 5) {
        my $status = STATUS_OK;
        direct_to_std();
        foreach my $dir ( $clone_vardir, $rqg_backup_dir) {
            File::Path::rmtree($dir);
        }
        say("INFO: $who_am_i : Endtime is nearly exceeded. " . Auxiliary::build_wrs($status));
        return $status;
    }

    $alarm_timeout = $backup_timeout;
    say("Executing backup: $backup_backup_cmd");
    $exit_msg      = "Backup operation did not finish in " . $alarm_timeout . "s.";
    alarm ($alarm_timeout);

    system("$backup_backup_cmd");
    my $res = $?;
    alarm (0);
    if ($res != 0) {
        direct_to_std();
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
            my $status = STATUS_CRITICAL_FAILURE;
            say("ERROR: $who_am_i : Connect to dsn '" . $dsn . "'" . " failed: " . $DBI::errstr .
                " Will exit with status " . status2text($status) . "($status)");
            exit $status;
        }
        $dbh->disconnect();
        my $status = STATUS_BACKUP_FAILURE;
        say("ERROR: $who_am_i : Backup returned $res. The command output is around end of " .
            "'$reporter_prt'. Will exit with status " . status2text($status) . "($status)");
        sayFile($reporter_prt);
        exit $status;
    }

    if ($reporter->testEnd() <= time() + 5) {
        my $status = STATUS_OK;
        direct_to_std();
        foreach my $dir ( $clone_vardir, $rqg_backup_dir) {
            File::Path::rmtree($dir);
        }
        say("INFO: $who_am_i : Endtime is nearly exceeded. " . Auxiliary::build_wrs($status));
        return $status;
    }

    # Mariabackup --backup could report something like
    # # 2021-03-24T17:48:38 [3315224] | [00] 2021-03-24 17:48:10 Copying ./test/oltp1.ibd to /dev/shm/vardir/1616598218/209/1_clone/data/test/oltp1.new
    # 2021-03-24T17:48:38 [3315224] | [00] 2021-03-24 17:48:10 Database page corruption detected at page 1, retrying...
    # ....
    # Error: failed to read page after 10 retries. File ./test/oltp1.ibd seems to be corrupted.
    # ...
    # [00] 2021-03-24 17:48:23 completed OK!
    # and give exit code 0.
    # In QA I cannot live with that.
    my $found = Auxiliary::search_in_file($reporter_prt, 'Error: failed to read page after 10 retries. File .{1,200} seems to be corrupted.');
    if (not defined $found) {
        # Technical problems!
        my $status = STATUS_ENVIRONMENT_FAILURE;
        direct_to_std();
        say("FATAL ERROR: $who_am_i \$found is undef. " .
            "Will exit with STATUS_ENVIRONMENT_FAILURE.");
        exit $status;
    } elsif ($found) {
        direct_to_std();
        say("INFO: $who_am_i corrupted file detected. " .
            "Will exit with STATUS_BACKUP_FAILURE.");
        sayFile($reporter_prt);
        # MLML
        sleep 100;
        exit STATUS_BACKUP_FAILURE;
    } else {
        # Nothing to do
    }

    # FIXME: Replace by some portable solution located in Auxiliary.pm.
    system("cp -R $clone_datadir $rqg_backup_dir");
    $res = $?;
    if ($res != 0) {
        direct_to_std();
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i : 'cp -R $clone_datadir $rqg_backup_dir' returned $res. " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }

    if ($reporter->testEnd() <= time() + 5) {
        my $status = STATUS_OK;
        direct_to_std();
        foreach my $dir ( $clone_vardir, $rqg_backup_dir) {
            File::Path::rmtree($dir);
        }
        say("INFO: $who_am_i : Endtime is nearly exceeded. " . Auxiliary::build_wrs($status));
        return $status;
    }

    system("ls -ld " . $clone_datadir . "/ib_logfile*");
    my $backup_prepare_cmd = $rr_addition . " $backup_binary --port=$clone_port --prepare " .
                             "--target-dir=$clone_datadir ";
    say("Executing first prepare: $backup_prepare_cmd");
    $exit_msg      = "Prepare operation 1 did not finish in " . $alarm_timeout . "s.";
    alarm ($prepare_timeout);
    system($backup_prepare_cmd);
    $res = $?;
    alarm (0);
    if ($res != 0) {
        direct_to_std();
        my $status = STATUS_BACKUP_FAILURE;
        say("ERROR: $who_am_i : First prepare returned $res. The command output is around end of " .
            "'$reporter_prt'. Will exit with status " . status2text($status) . "($status)");
        # MLML
        sleep 100;
        sayFile($reporter_prt);
        exit $status;
    }
    system("ls -ld " . $clone_datadir . "/ib_logfile*");
    my $ib_logfile0 = $clone_datadir . "/ib_logfile0";
#   my @filestats = stat($ib_logfile0);
#   my $filesize  = $filestats[7];
#   if (0 != $filesize) {
#       direct_to_std();
#       my $status = STATUS_BACKUP_FAILURE;
#       say("ERROR: $who_am_i : Size of '$ib_logfile0' is $filesize bytes but not 0 like expected. " .
#           "Will exit with status " . status2text($status) . "($status)");
#       exit $status;
#   }

    if ($reporter->testEnd() <= time() + 5) {
        my $status = STATUS_OK;
        direct_to_std();
        foreach my $dir ( $clone_vardir, $rqg_backup_dir) {
            File::Path::rmtree($dir);
        }
        say("INFO: $who_am_i : Endtime is nearly exceeded. " . Auxiliary::build_wrs($status));
        return $status;
    }

    system("ls -ld " . $clone_datadir . "/ib_logfile*");
#   $backup_prepare_cmd = $rr_addition . " $backup_binary --port=$clone_port --prepare " .
#                         "--target-dir=$clone_datadir ";
#   say("Executing second prepare: $backup_prepare_cmd");
#   $exit_msg      = "Prepare operation 2 did not finish in " . $alarm_timeout . "s.";
#   # Less time because its the second prepare.
#   alarm ($backup_timeout);
#   system($backup_prepare_cmd);
#   $res = $?;
#   alarm (0);
#   if ($res != 0) {
#       direct_to_std();
#       my $status = STATUS_BACKUP_FAILURE;
#       say("ERROR: $who_am_i : Second prepare returned $res. The command output is around end of " .
#           "'$reporter_prt'. Will exit with status " . status2text($status) . "($status)");
#       sayFile($reporter_prt);
#       exit $status;
#   }
#   @filestats = stat($ib_logfile0);
#   $filesize  = $filestats[7];
#   if (0 != $filesize) {
#       direct_to_std();
#       my $status = STATUS_BACKUP_FAILURE;
#       say("ERROR: $who_am_i : Size of '$ib_logfile0' is $filesize bytes but not 0 like expected. " .
#           "Will exit with status " . status2text($status) . "($status)");
#       exit $status;
#   }

#   # Per Marko:
#   # Legal operation in case somebody wants to just have a clone of the source DB.
#   # See also https://mariadb.com/kb/en/library/mariadb-backup-overview/.
#   unlink($ib_logfile0);

    if ($reporter->testEnd() <= time() + 5) {
        my $status = STATUS_OK;
        direct_to_std();
        foreach my $dir ( $clone_vardir, $rqg_backup_dir) {
            File::Path::rmtree($dir);
        }
        say("INFO: $who_am_i : Endtime is nearly exceeded. " . Auxiliary::build_wrs($status));
        return $status;
    }

    # Warning:
    # Older and/or similar code was trying to set the server general log and error log files to non
    # standard names.
    #     my $clone_err = $clone_datadir . '/clone.err';
    #     Inside of the @mysqld_options
    #         '--log_error="'.$clone_err.'"',
    #         '--general_log_file="'.$clone_datadir.'/clone.log"',
    # This cannot work well when using DBServer::MySQL::MySQLd because that assumes that the
    # standard names are used.
    my @mysqld_options = (
        '--server-id=3',
        # DBServer::MySQL::MySQLd::startServer will add '--core-file' if it makes sense.
        # '--core-file',
        '--loose-console',
        '--loose-lc-messages-dir="' . $lc_messages_dir . '"',
        '--datadir="' . $clone_datadir . '"',
        '--log-output=file',
        '--general-log',
        '--datadir="' . $clone_datadir . '"',
        '--port='.$clone_port,
        '--loose-plugin-dir="' . $plugin_dir . '"',
        '--max-allowed-packet=20M',
        '--innodb',
        '--loose_innodb_use_native_aio=0',
        '--sql_mode=NO_ENGINE_SUBSTITUTION',
    );

    foreach my $plugin (@$plugins) {
        push @mysqld_options, '--plugin-load=' . $plugin->[0] . '=' . $plugin->[1];
    };
    push @mysqld_options, '--loose-file-key-management-filename="' . $fkm_file . '"'
        if defined $fkm_file;
    push @mysqld_options, '--innodb_page_size="' . $innodb_page_size . '"'
        if defined $innodb_page_size;
    push @mysqld_options, '--innodb_flush_method="' . $flush_method . '"'
        if (defined $flush_method and '' ne $flush_method);

    $|=1;

    # Let routines from lib/DBServer/MySQL/MySQLd.pm do as much of the job as possible.
    # I hope that this will work on WIN.
    my $clone_server = DBServer::MySQL::MySQLd->new(
                            basedir            => $clone_basedir,
                            vardir             => $clone_vardir,
                            debug_server       => undef,
                            port               => $clone_port,
                            start_dirty        => 1,
                            valgrind           => undef,
                            valgrind_options   => undef,
                            rr                 => $rr,
                            rr_options         => $rr_options,
                            server_options     => \@mysqld_options,
                            general_log        => 1,
                            config             => undef,
                            user               => $clone_user);

    my $clone_err = $clone_server->errorlog();

    system("ls -ld " . $clone_datadir . "/ib_logfile*");
    say("INFO: Attempt to start a DB server on the cloned data.");
    say("INFO: Per Marko messages like InnoDB: 1 transaction(s) which must be rolled etc. " .
        "are normal. MB prepare is not allowed to do rollbacks.");
    my $status = $clone_server->startServer();
    if ($status != STATUS_OK) {
        direct_to_std();
        # It is intentional to exit with STATUS_BACKUP_FAILURE.
        $status = STATUS_BACKUP_FAILURE;
        say("ERROR: $who_am_i : Starting a DB server on the cloned data failed.");
        sayFile($clone_err);
        sayFile($reporter_prt);
        say("ERROR: $who_am_i : Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }

    if ($reporter->testEnd() <= time() + 5) {
        my $status = STATUS_OK;
        direct_to_std();
        $clone_server->killServer();
        foreach my $dir ( $clone_vardir, $rqg_backup_dir) {
            File::Path::rmtree($dir);
        }
        say("INFO: $who_am_i : Endtime is nearly exceeded. " . Auxiliary::build_wrs($status));
        return $status;
    }

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
        direct_to_std();
        # It is intentional to exit with STATUS_BACKUP_FAILURE.
        $status = STATUS_BACKUP_FAILURE;
        sayFile($clone_err);
        sayFile($reporter_prt);
        say("ERROR: $who_am_i : Connect to the clone server on port $clone_port failed. " .
            $DBI::errstr . " " . Auxiliary::build_wrs($status));
        exit $status;
    }

    say("INFO: The DB server on the cloned data has pid " . $clone_server->serverpid() .
        " and is connectable.");

    if ($reporter->testEnd() <= time() + 5) {
        $clone_dbh->disconnect();
        my $status = STATUS_OK;
        direct_to_std();
        $clone_server->killServer();
        foreach my $dir ( $clone_vardir, $rqg_backup_dir) {
            File::Path::rmtree($dir);
        }
        say("INFO: $who_am_i : Endtime is nearly exceeded. " . Auxiliary::build_wrs($status));
        return $status;
    }

    # Code taken from lib/GenTest/Reporter/RestartConsistency.pm
    say("INFO: $who_am_i : Testing database consistency");

    my $databases = $clone_dbh->selectcol_arrayref("SHOW DATABASES");
    foreach my $database (@$databases) {
        if ($reporter->testEnd() <= time() + 5) {
            $clone_dbh->disconnect();
            my $status = STATUS_OK;
            direct_to_std();
            $clone_server->killServer();
            foreach my $dir ( $clone_vardir, $rqg_backup_dir) {
                File::Path::rmtree($dir);
            }
            say("INFO: $who_am_i : Endtime is nearly exceeded. " . Auxiliary::build_wrs($status));
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
            # Should not do CHECK etc., and especially ALTER, on a view
            next if $tables{$table} eq 'VIEW';
            my $sql = "CHECK TABLE `$database`.`$table` EXTENDED";
            $clone_dbh->do($sql);
            # 1178 is ER_CHECK_NOT_IMPLEMENTED
            # Experimental: Don't ignore error 1178
            # return STATUS_DATABASE_CORRUPTION if $clone_dbh->err() > 0 && $clone_dbh->err() != 1178;
            my $err = $clone_dbh->err;
            if (defined $err and $err > 0) {
                direct_to_std();
                say("ERROR: $who_am_i : '$sql' failed with : " . $err);
                $clone_dbh->disconnect();
                sayFile($clone_err);
                sayFile($reporter_prt);
                # FIXME:
                # It should be possible to replay what happened based on
                # - the data backup copy and starting+checking
                # - some rr trace if enabled
                # Hence running some killServer now will not destroy valuable information or
                # to generate it later.
                # But reacting on some dying server with killServer
                # - can lead to confusion based on error log content like
                #   Was the server already dying or came the 'mysqld got signal ' from the
                #   killServer?
                # - has an influence how the final death happens and the error log content
                # Provisional solution:
                if ($err == 2013 or $err == 2006) {
                    sleep 30;
                }
                say("ERROR: $who_am_i : Will kill the server running on cloned data");
                my $throw_away_status = $clone_server->killServer();
                # The damage is some corruption.
                # Based on the fact that this is found in the server running on the backuped data
                # I prefer to return STATUS_BACKUP_FAILURE and not STATUS_DATABASE_CORRUPTION.
                my $status = STATUS_BACKUP_FAILURE;
                say("ERROR: $who_am_i : Will exit with status " . status2text($status) . "($status)");
                exit $status;
            }
        }
    }
    say("INFO: $who_am_i : The tables in the schemas (except information_schema, " .
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
#   direct_to_std();
    $status = $clone_server->stopServer();
    if (STATUS_OK != $status) {
        direct_to_std();
        $status = STATUS_BACKUP_FAILURE;
        say("ERROR: $who_am_i : Shutdown of DB server on cloned data made trouble. ".
            "Hence trying to kill it and return STATUS_BACKUP_FAILURE later.");
        my $throw_away_status = $clone_server->killServer();
        sayFile($clone_err);
        sayFile($reporter_prt);
        say("ERROR: $who_am_i : Will return status " . status2text($status) . "($status)");
        return $status;
    }
    # The other $clone_* are subdirectories of $clone_vardir.
    foreach my $dir ( $clone_vardir, $rqg_backup_dir) {
        File::Path::rmtree($dir);
    }
    direct_to_std();
    unlink ($reporter_prt);
    say("DEBUG: $who_am_i : Pass") if $script_debug;

    return STATUS_OK;
}

# https://www.perlmonks.org/bare/?node_id=255129
# https://www.perl.com/article/45/2013/10/27/How-to-redirect-and-restore-STDOUT/
# FIXME: Move these two routines to Auxiliary.pm
my $stdout_save;
my $stderr_save;
sub direct_to_file {

    if (not open($stdout_save, ">&", STDOUT)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i : Getting STDOUT failed with '$!' " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }
    if (not open($stderr_save, ">&", STDERR)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i : Getting STDERR failed with '$!' " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }
    say("DEBUG: $who_am_i : Redirecting all output to '$reporter_prt'.") if $script_debug;
    unlink ($reporter_prt);
    if (not open(STDOUT, ">>", $reporter_prt)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i : Opening STDOUT failed with '$!' " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }
    # Redirect STDERR to the log of the RQG run.
    if (not open(STDERR, ">>", $reporter_prt)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i : Opening STDERR failed with '$!' " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }
}

sub direct_to_std {

    # Note(mleich):
    # I hope that in case of error the error messages will end up in $reporter_prt.
    if (not open(STDOUT, ">&" , $stdout_save)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i : Opening STDOUT failed with '$!' " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }
    if (not open(STDERR, ">&" , $stderr_save)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i : Opening STDERR failed with '$!' " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }
    close($stdout_save);
    close($stderr_save);
}

sub type {
    return REPORTER_TYPE_PERIODIC;
}

1;
