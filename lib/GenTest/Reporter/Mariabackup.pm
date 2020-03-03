# Copyright (c) 2018, 2020 MariaDB Corporation Ab.
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

package GenTest::Reporter::Mariabackup;

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
use DBI;
use GenTest;
use GenTest::Constants;
use GenTest::Reporter;
use Data::Dumper;
use IPC::Open2;
use IPC::Open3;
use DBServer::MySQL::MySQLd;

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
#    must contain $msg_snip in order to make easy readable "who says what".
#    All other messages (going first into $reporter_prt) might omit $msg_snip.
# 5. Sorry for throwing STATUS_BACKUP_FAILURE maybe to excessive.
#    Quite often parts of the server or the RQG core could be also guilty.
#

use constant CONNECT_TIMEOUT => 30;

my $first_reporter;
my $client_basedir;

my $script_debug = 1;
my $last_call    = time() - 15;
$|=1;

# tmpdir() has a '/' at end.
my $reporter_prt = tmpdir() . "reporter_tmp.prt";
my $msg_snip     = 'Reporter Mariabackup';

sub monitor {
    my $reporter = shift;

    # In case of several servers, we get called or might be called for any of them.
    # We perform only
    #   backup first server, make a clone based on that backup, check clone and destroy clone
    #

    direct_to_file();

    $first_reporter = $reporter if not defined $first_reporter;
    return STATUS_OK if $reporter ne $first_reporter;

    # The next lines are set to comment because in the current (2019-02) state I prefer an
    # extreme frequent testing.
    # Ensure some minimum distance between two runs of the Reporter Mariabackup should be 15s.
    # return STATUS_OK if $last_call + 15 > time();
    # $last_call = time();

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
        say("ERROR: $msg_snip : Can't determine client_basedir. basedir is '$basedir'. " .
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
    ## Create clone database server directory structure
    foreach my $dir ( $clone_vardir, $clone_datadir, $clone_tmpdir) {
        if (not mkdir($dir)) {
            direct_to_std();
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: $msg_snip : mkdir($dir) failed with : $!. " .
                "Will exit with status " . status2text($status) . "($status)");
            exit $status;
        }
    }

    if ($script_debug and not osWindows()) {
        system("find $clone_vardir -follow") if $script_debug;
    }

    # FIXME: Do we really need all this?
    my $dsn             = $reporter->dsn();
    my $binary          = $reporter->serverInfo('binary');
    my $language        = $reporter->serverVariable('language');
    my $lc_messages_dir = $reporter->serverVariable('lc_messages_dir');
    my $datadir         = $reporter->serverVariable('datadir');
    $datadir =~ s{[\\/]$}{}sgio;
    # 2020-02-27 The start of the server on the backuped data failed because this data
    # goes with a different InnoDB page size than the server default of 16K.
    my $innodb_page_size = $reporter->serverVariable('innodb_page_size');

    # We make a backup of $clone_datadir within $rqg_backup_dir because in case of failure we
    # need these files not modified by mariabackup --prepare.
    my $rqg_backup_dir = $server0->datadir() . '_backup';
    # We let the copy operation create the directory $rqg_backup_dir later.
    my $source_port = $reporter->serverVariable('port');
    # FIXME:
    # This port computation is unsafe. There might be some already running server there.
    my $clone_port    = $source_port + 4;
    my $plugin_dir    = $reporter->serverVariable('plugin_dir');
    my $plugins       = $reporter->serverPlugins();
    my ($version)     = ( $reporter->serverVariable('version') =~ /^(\d+\.\d+)\./ ) ;
    my $backup_binary = "$basedir" . "/extra/mariabackup/mariabackup";
    if (not -e $backup_binary) {
        direct_to_std();
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $msg_snip : Calculated mariabackup binary '$backup_binary' not found. " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }
    $backup_binary = $backup_binary . " --host=127.0.0.1 --user=root --password='' ";

    if (not osWindows()) {
        $backup_binary = $backup_binary . " --innodb-use-native-aio=0 ";
    }

    # For experimenting:
    # $backup_binary = "not_exists ";
    # my $backup_backup_cmd = "$backup_binary --port=$source_port --hickup " .
    my $backup_backup_cmd = "$backup_binary --port=$source_port --backup " .
                            "--datadir=$datadir --target-dir=$clone_datadir";
    say("Executing backup: $backup_backup_cmd");
    system($backup_backup_cmd);
    my $res = $?;
    if ($res != 0) {
        direct_to_std();
        # Let's check first the not unlikely.
        my $dbh = DBI->connect($dsn, undef, undef, {
            mysql_connect_timeout  => CONNECT_TIMEOUT,
            PrintError             => 0,
            RaiseError             => 0,
            AutoCommit             => 0,
            mysql_multi_statements => 0,
            mysql_auto_reconnect   => 0
        });
        if (not defined $dbh) {
            my $status = STATUS_SERVER_CRASHED;
            say("ERROR: $msg_snip : Connect to dsn '" . $dsn . "'" . " failed: " . $DBI::errstr .
                " Will exit with status " . status2text($status) . "($status)");
            exit $status;
        }
        $dbh->disconnect();
        my $status = STATUS_BACKUP_FAILURE;
        say("ERROR: $msg_snip : Backup returned $res. The command output is around end of " .
            "'$reporter_prt'. Will exit with status " . status2text($status) . "($status)");
        sayFile($reporter_prt);
        exit $status;
    }

    # FIXME: Replace by some portable solution located in Auxiliary.pm.
    system("cp -R $clone_datadir $rqg_backup_dir");
    $res = $?;
    if ($res != 0) {
        direct_to_std();
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $msg_snip : 'cp -R $clone_datadir $rqg_backup_dir' returned $res. " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }

    my $backup_prepare_cmd = "$backup_binary --port=$clone_port --prepare " .
                             "--target-dir=$clone_datadir";
    say("Executing first prepare: $backup_prepare_cmd");
    system($backup_prepare_cmd);
    $res = $?;
    if ($res != 0) {
        direct_to_std();
        my $status = STATUS_BACKUP_FAILURE;
        say("ERROR: $msg_snip : First prepare returned $res. The command output is around end of " .
            "'$reporter_prt'. Will exit with status " . status2text($status) . "($status)");
        sayFile($reporter_prt);
        exit $status;
    }
    my $ib_logfile0 = $clone_datadir . "/ib_logfile0";
    my @filestats = stat($ib_logfile0);
    my $filesize  = $filestats[7];
    if (0 != $filesize) {
        direct_to_std();
        my $status = STATUS_BACKUP_FAILURE;
        say("ERROR: $msg_snip : Size of '$ib_logfile0' is $filesize bytes but not 0 like expected. " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }

    $backup_prepare_cmd = "$backup_binary --port=$clone_port --prepare " .
                          "--target-dir=$clone_datadir";
    say("Executing second prepare: $backup_prepare_cmd");
    system($backup_prepare_cmd);
    $res = $?;
    if ($res != 0) {
        direct_to_std();
        my $status = STATUS_BACKUP_FAILURE;
        say("ERROR: $msg_snip : Second prepare returned $res. The command output is around end of " .
            "'$reporter_prt'. Will exit with status " . status2text($status) . "($status)");
        sayFile($reporter_prt);
        exit $status;
    }
    @filestats = stat($ib_logfile0);
    $filesize  = $filestats[7];
    if (0 != $filesize) {
        direct_to_std();
        my $status = STATUS_BACKUP_FAILURE;
        say("ERROR: $msg_snip : Size of '$ib_logfile0' is $filesize bytes but not 0 like expected. " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }

    # Per Marko:
    # Legal operation in case somebody wants to just have a clone of the source DB.
    # See also https://mariadb.com/kb/en/library/mariadb-backup-overview/.
    unlink($ib_logfile0);


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
        '--core-file',
        '--loose-console',
        '--language='.$language,
        '--loose-lc-messages-dir='.$lc_messages_dir,
        '--datadir="'.$clone_datadir.'"',
        '--log-output=file',
        '--general-log',
        '--datadir='.$clone_datadir,
        '--port='.$clone_port,
        '--loose-plugin-dir="'.$plugin_dir.'"',
        '--max-allowed-packet=20M',
        '--innodb',
        '--innodb_page_size="' . $innodb_page_size . '"',
        '--loose_innodb_use_native_aio=0',
        '--sql_mode=NO_ENGINE_SUBSTITUTION',
    );

    foreach my $plugin (@$plugins) {
        push @mysqld_options, '--plugin-load=' . $plugin->[0] . '=' . $plugin->[1];
    };

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
                            server_options     => \@mysqld_options,
                            general_log        => 1,
                            config             => undef,
                            user               => $clone_user);

    my $clone_err = $clone_server->errorlog();

    say("INFO: Attempt to start a DB server on the cloned data.");
    my $status = $clone_server->startServer();
    if ($status != STATUS_OK) {
        direct_to_std();
        $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $msg_snip : Starting a DB server on the cloned data failed.");
        sayFile($clone_err);
        sayFile($reporter_prt);
        say("ERROR: $msg_snip : Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }

    my $clone_dbh;
    foreach my $try (1..120) {
        sleep(1);
        $clone_dbh = DBI->connect("dbi:mysql:user=root:host=127.0.0.1:port=" . $clone_port,
                                  undef, undef, { RaiseError => 0 , PrintError => 0 } );
        next if not defined $clone_dbh;
        last if $clone_dbh->ping();
    }
    if (not defined $clone_dbh) {
        direct_to_std();
        $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $msg_snip : Could not connect to the clone server on port $clone_port. " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }

    say("INFO: The DB server on the cloned data has pid " . $clone_server->serverpid() .
        " and is connectable.");

    # Code taken from lib/GenTest/Reporter/RestartConsistency.pm
    say("INFO: $msg_snip : Testing database consistency");

    my $databases = $clone_dbh->selectcol_arrayref("SHOW DATABASES");
    foreach my $database (@$databases) {
        # next if $database =~ m{^(mysql|information_schema|performance_schema)$}sio;
        # Experimental: Check the SCHEMA mysql too
        next if $database =~ m{^(information_schema|performance_schema)$}sio;
        $clone_dbh->do("USE $database");
        my $tabl_ref = $clone_dbh->selectcol_arrayref("SHOW FULL TABLES", { Columns=>[1,2] });
        my %tables = @$tabl_ref;
        foreach my $table (keys %tables) {
            # Should not do CHECK etc., and especially ALTER, on a view
            next if $tables{$table} eq 'VIEW';
            my $sql = "CHECK TABLE `$database`.`$table` EXTENDED";
            $clone_dbh->do($sql);
            # 1178 is ER_CHECK_NOT_IMPLEMENTED
            # Experimental: Don't ignore error 1178
            # return STATUS_DATABASE_CORRUPTION if $clone_dbh->err() > 0 && $clone_dbh->err() != 1178;
            if (defined $clone_dbh->err() and $clone_dbh->err() > 0) {
                direct_to_std();
                say("ERROR: $msg_snip : '$sql' failed with : " . $clone_dbh->err());
                sayFile($clone_err);
                sayFile($reporter_prt);
                my $status = STATUS_DATABASE_CORRUPTION;
                say("ERROR: $msg_snip : Will exit with status " . status2text($status) . "($status)");
                exit $status;
            }
        }
    }
    say("INFO: $msg_snip : The tables in the schemas (except information_schema, " .
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
        say("ERROR: $msg_snip : Shutdown of DB server on cloned data made trouble.");
        sayFile($clone_err);
        say("ERROR: $msg_snip : Will return status " . status2text($status) . "($status)");
        return $status;
    }
    # The other $clone_* are subdirectories of $clone_vardir.
    foreach my $dir ( $clone_vardir, $rqg_backup_dir) {
        if(not File::Path::rmtree($dir)) {
            direct_to_std();
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: $msg_snip : rmtree($dir) failed with : $!. " .
                "Will exit with status " . status2text($status) . "($status)");
            exit $status;
        }
    }
    direct_to_std();
    unlink ($reporter_prt);
    say("DEBUG: $msg_snip : Pass") if $script_debug;

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
        say("ERROR: $msg_snip : Getting STDOUT failed with '$!' " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }
    if (not open($stderr_save, ">&", STDERR)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $msg_snip : Getting STDERR failed with '$!' " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }
    say("DEBUG: $msg_snip : Redirecting all output to '$reporter_prt'.") if $script_debug;
    unlink ($reporter_prt);
    if (not open(STDOUT, ">>", $reporter_prt)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $msg_snip : Opening STDOUT failed with '$!' " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }
    # Redirect STDERR to the log of the RQG run.
    if (not open(STDERR, ">>", $reporter_prt)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $msg_snip : Opening STDERR failed with '$!' " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }
}

sub direct_to_std {

    # Note(mleich):
    # I hope that in case of error the error messages will end up in $reporter_prt.
    if (not open(STDOUT, ">&" , $stdout_save)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $msg_snip : Opening STDOUT failed with '$!' " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }
    if (not open(STDERR, ">&" , $stderr_save)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $msg_snip : Opening STDERR failed with '$!' " .
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
