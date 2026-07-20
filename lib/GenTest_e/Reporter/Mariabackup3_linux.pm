# Copyright (c) 2026 MariaDB plc
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

package GenTest_e::Reporter::Mariabackup3_linux;

# The reporter is a derivate of Mariabackup_linux.pm.
# Mariabackup3_linux.pm uses the server-side backup functionality introduced by MDEV-14992.

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

# Warning:
# --------
# There might be frictions with the timeouts used in App/GenTest.pm after the loop OUTER.
use constant BACKUP_TIMEOUT  => 200;
use constant PREPARE_TIMEOUT => 200;

my $first_reporter;
my $client_basedir;
my $backup_binary;

my $script_debug = 0;
my $last_call    = time() - 16;
$|=1;

my $who_am_i =                "Reporter 'Mariabackup3':";
my $reporter_prt =            tmpdir() . "reporter_tmp.prt";
my $backup_timeout;
my $prepare_timeout;
my $connect_timeout;
# my $backup_prt;
my $rr;
my $backup_backup_prefix;
my $backup_prepare_prefix;
my $source_server;
my $clone_vardir;
my $clone_server;
my @mysqld_options;
my $source_port;
my $clone_port;
my $clone_err;
my $backup_backup_cmd;
my $backup_prepare_cmd;

my $datadir;
my $clone_datadir;
my $reporter;


sub init {
    $reporter = shift;
    my $status = STATUS_OK;

    if (not defined $reporter->testEnd()) {
        $status = STATUS_INTERNAL_ERROR;
        say("ERROR: $who_am_i testEnd is not defined. " . Basics::exit_status_text($status));
        exit $status;
    }
    $backup_timeout     = Runtime::get_runtime_factor() * BACKUP_TIMEOUT;
#   $prepare_timeout    = Runtime::get_runtime_factor() * PREPARE_TIMEOUT;
    $connect_timeout    = Runtime::get_connect_timeout();
    say("INFO: $who_am_i Effective timeouts, connect: $connect_timeout" .
        " backup: $backup_timeout");
    # Basics::direct_to_stdout();

    my $dbdir = Local::get_dbdir();

    $rr =       Runtime::get_rr();

    # Access data about the first server
    $source_server = $reporter->properties->servers->[0];

    $clone_vardir  = $source_server->vardir()  . "_clone";

    $source_port =  $reporter->serverVariable('port');
    $clone_port  =  $source_port + 4;
    $datadir =      $reporter->serverVariable('datadir');
    $datadir =~ s{[\\/]$}{}sgio;

    $clone_datadir = $clone_vardir . "/data";

}

sub monitor {
    $reporter = shift;

    my $status = STATUS_OK;

    # Rules of thumb:
    # When meeting a
    # - fatal problem (>= 110)
    #   exit
    # - serious but non fatal problem (< 110)
    #   return
    # - simple problem
    #   write a message to STDOUT and return or exit
    # - complex problem
    #   write message to reporter_tmp.prt
    #   write reporter_tmp.prt to STDOUT and return or exit

    # In case of several servers, we get called or might be called for any of them.
    # We perform only
    #   backup first server, make a clone based on that backup, check clone and destroy clone
    $first_reporter = $reporter if not defined $first_reporter;
    return STATUS_OK if $reporter ne $first_reporter;
    # This is the index of the first server == source server!
    my $server_id = 0;

    $reporter->init if not defined $backup_timeout;
    # say("DEBUG: $who_am_i Endtime: " . $reporter->testEnd()) if $script_debug;
    #

    # Ensure some minimum distance between two runs of the Reporter Mariabackup should be 15s.
    return STATUS_OK if $last_call + 15 > time();
    $last_call = time();

    # mariabckup --backup is ahead
    if ($reporter->testEnd() <= time() + 10) {
        $status = STATUS_OK;
        say("INFO: $who_am_i Endtime is nearly exceeded. " . Basics::return_status_text($status));
        return $status;
    }

    our $dsn =      $reporter->dsn();
    our $executor = GenTest_e::Executor->newFromDSN($dsn);
    $executor->setId(1);
    $executor->setRole("Mariabackup3");
    $executor->setTask(GenTest_e::Executor::EXECUTOR_TASK_REPORTER);
    # This will perform the connect and set max_statement_time = 0.
    $status = $executor->init();
    if (STATUS_OK != $status) {
        Basics::direct_to_stdout();
        say("ERROR: $who_am_i The initialization of the Executor failed with status $status.");
        return $status;
    } else {
        say("INFO: $who_am_i The Executor was initialized.");
    }

    my $basedir = $source_server->basedir();

    unlink($reporter_prt);
    if (STATUS_OK != Basics::make_file($reporter_prt, undef)) {
        $status = STATUS_FAILURE;
        $executor->disconnect();
        say("ERROR: $who_am_i Will return STATUS_ALARM because of previous failure.");
        return $status;
    }
    Basics::direct_to_file($reporter_prt);

    # Take over the settings for the first server and modify them if needed.
    @mysqld_options = @{$reporter->properties->servers->[0]->getServerOptions};
    if($script_debug) {
        Basics::direct_to_stdout();
        say("DEBUG: $who_am_i source server mysqld_options\n" . join("\n", @mysqld_options));
        Basics::direct_to_file($reporter_prt);
    }
    # Reuse data for the clone if possible or adjust it.
    our $clone_basedir =    $basedir;
    my $clone_user =        $source_server->user();
    # Use the standard layout like in MySQLd.pm.
    # FIXME: Standardization without duplicate code would be better.
    my $clone_tmpdir =  $clone_vardir . "/tmp";
    my $clone_rrdir =   $clone_vardir . '/rr';

    ## Create clone database server directory structure
    if (STATUS_OK != Auxiliary::make_dbs_dirs($clone_vardir)) {
        Basics::direct_to_stdout();
        $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i Preparing the storage structure for the server '1_clone' failed. " .
            Basics::exit_status_text($status));
        $executor->disconnect();
        exit $status;
    }
    # make_dbs_dirs generates $clone_datadir ($clone_vardir/data).
    # But "BACKUP SERVER TO '$clone_datadir'" fails if $clone_vardir/data already exists.
    # Hence we remove '$clone_datadir'".
    if (STATUS_OK != Basics::conditional_remove_dir($clone_datadir)) {
        Basics::direct_to_stdout();
        $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i Preparing the storage structure for the server '1_clone' failed. " .
            Basics::exit_status_text($status));
        $executor->disconnect();
        exit $status;
    }

    # FIXME: Do we really need all this?

    my $lc_messages_dir = $reporter->serverVariable('lc_messages_dir');
    # 2020-02-27 The start of the server on the backupped data failed because this data
    # goes with a different InnoDB page size than the server default of 16K.
    my $innodb_page_size        = $reporter->serverVariable('innodb_page_size');
    # Useful because we should not go below the minimal innodb_buffer_pool_size.
    my $innodb_buffer_pool_size = $reporter->serverVariable('innodb_buffer_pool_size');

    # We will make a backup of $clone_datadir within $rqg_backup_dir later because in case
    # of failure we need these files not modified by start attempt.
    our $rqg_backup_dir = $clone_vardir . '/fbackup';
    # We let the copy operation create the directory $rqg_backup_dir later.
    my $source_port    = $reporter->serverVariable('port');
    # FIXME:
    # This port computation is unsafe. There might be some already running server there.
    my $clone_port    =         $source_port + 4;
    # my $log_output    =         $reporter->serverVariable('log_output');
    my $plugin_dir    =         $reporter->serverVariable('plugin_dir');
    my $fkm_file      =         $reporter->serverVariable('file_key_management_filename');
    my $innodb_use_native_aio = $reporter->serverVariable('innodb_use_native_aio');
    my $plugins       =         $reporter->serverPlugins();
    my ($version)     =         ($reporter->serverVariable('version') =~ /^(\d+\.\d+)\./);

    sub TERM_handler {
        sleep 1;
        my $status = STATUS_OK;
        say("INFO: $who_am_i SIGTERM caught. Will return later STATUS_OK.");
        $executor->disconnect() if defined $executor;
        if (defined $clone_server and -e  $clone_server->errorlog) {
            say("INFO: $who_am_i Will kill the server running on backupped data.");
            $clone_server->killServer();
            remove_clone_dbs_dirs($clone_vardir);
        }
        Basics::direct_to_stdout();
        say("INFO: $who_am_i " . Basics::exit_status_text($status));
        exit $status;
    }

    # BACKUP SERVER could hang.
    my $alarm_msg =     '';
    my $alarm_timeout = 0;


    sub get_METADATA_LOCK_INFO {
        my $aux_query =     "SELECT THREAD_ID FROM information_schema.METADATA_LOCK_INFO " .
                            "WHERE LOCK_TYPE = 'Backup lock'";
        my $aux_result =    $executor->execute($aux_query);
        my $aux_status =    $aux_result->status;
        $aux_status = STATUS_CRITICAL_FAILURE if not defined $aux_status;
        if (STATUS_OK != $aux_status) {
            my $aux_err =       $aux_result->err;
            $aux_err    =       "<undef>" if not defined $aux_err;
            my $aux_errstr =    $aux_result->errstr;
            $aux_errstr =       "<undef>" if not defined $aux_errstr;
            $executor->disconnect();
            say("ERROR: $who_am_i Helper Query ->" . $aux_query . "<- failed with " .
                "$aux_err : $aux_errstr . " . Basics::return_status_text($aux_status));
            # Return because the caller should kill the maybe running BACKUP SERVER.
            return $aux_status;
        }
        my $key_aux_ref = $aux_result->data;
        if (not defined $key_aux_ref) {
            my $aux_err =       $aux_result->err;
            $aux_err    =       "<undef>" if not defined $aux_err;
            my $aux_errstr =    $aux_result->errstr;
            $aux_errstr =       "<undef>" if not defined $aux_errstr;
            $executor->disconnect();
            $aux_status = STATUS_CRITICAL_FAILURE;
            say("ERROR: $who_am_i Helper Query ->" . $aux_query . "<- harvested " .
                "$aux_err : $aux_errstr and an undef Arrayref. " . Basics::return_status_text($aux_status));
        } elsif (0 == scalar(@$key_aux_ref)) {
            $executor->disconnect();
            say("ERROR: $who_am_i No MDL locks found.");
            my $aux_result = STATUS_BACKUP_FAILURE;
            say("ERROR: $who_am_i " . Basics::return_status_text($aux_result));
            return $aux_result;
        } else {
            say("DEBUG: $who_am_i METADATA_LOCK_INFO thread_id<->lock_mode<->lock_duration<->lock_type");
            foreach my $lock_check_val (@$key_aux_ref) {
                my $r_thread_id =     $lock_check_val->[0];
                say("INFO: $who_am_i The thread_id $r_thread_id holds a backup lock. " .
                    "Killing soft its connection.");
                $executor->execute("KILL SOFT CONNECTION $r_thread_id");
            }
            return STATUS_OK;
        }
    }

    sigaction SIGALRM, new POSIX::SigAction sub {
        say("INFO: $who_am_i $alarm_msg");
        my $return =    get_METADATA_LOCK_INFO;
        Basics::direct_to_stdout();
        sayFile($reporter_prt);
        $status = STATUS_BACKUP_FAILURE;
        say("INFO: $who_am_i " . Basics::exit_status_text($status));
        exit $status;
    } or die "ERROR: $who_am_i Error setting SIGALRM handler: $!\n";

    if ($reporter->testEnd() <= time() + 5) {
        $status = STATUS_OK;
        Basics::direct_to_stdout();
        remove_clone_dbs_dirs($clone_vardir);
        say("INFO: $who_am_i Endtime is nearly exceeded. " . Basics::return_status_text($status));
        return $status;
    }

    $alarm_timeout = $backup_timeout;
    # my $aux_query =  "BACKUP SERVER TO '$clone_datadir' CONCURRENT 2";
      my $aux_query =  "BACKUP SERVER TO '$clone_datadir'";
    say("$who_am_i Executing backup statement: ->$aux_query<-");
    $alarm_msg =  "Backup operation did not finish in " . $alarm_timeout . "s.";
    {
        my $th_status;
        local $SIG{TERM} =  sub { $th_status = TERM_handler ;
                                  say("DEBUG: $who_am_i TERM_handler th_status : $th_status")};
        alarm ($alarm_timeout);

        # For testing
        # say("INFO: $who_am_i Testing the impact of SIGTERM");
        # system("kill -15 $$");
        # say("INFO: $who_am_i Sent SIGTERM to own process.");
        # sleep 2;

        # For testing
        # say("INFO: $who_am_i Testing the impact of exceeding the alarm timeout");
        # alarm (1);
        # sleep 2;
        # say("INFO: $who_am_i After exceeding the alarm timeout");

        # For testing
        # say("INFO: $who_am_i Testing the impact of no more running source server");
        # my $server = $reporter->properties->servers->[0];
        # $server->crashServer();
        # say("INFO: $who_am_i After SIGKILL the source server");
        # sleep 2;

        my $aux_result =    $executor->execute($aux_query);
        alarm (0);

        # The reporter(manager) was asked to terminate.
        # It is intentional that the protocol of the reporter gets not deleted.
        if (defined $th_status) {
            remove_clone_dbs_dirs($clone_vardir);
            return STATUS_OK;
        }

        my $aux_status =    $aux_result->status;
        $aux_status = STATUS_CRITICAL_FAILURE if not defined $aux_status;
        if (STATUS_OK != $aux_status) {
            my $aux_err =       $aux_result->err;
            $aux_err    =       "<undef>" if not defined $aux_err;
            my $aux_errstr =    $aux_result->errstr;
            $aux_errstr =       "<undef>" if not defined $aux_errstr;
            $executor->disconnect();
            say("ERROR: $who_am_i Helper Query ->" . $aux_query . "<- on source server failed " .
                "with $aux_err : $aux_errstr . status : $aux_status");
            # return $aux_status;
            # Syntax failure (1064) -> $aux_status == 21 which is treated as
            Basics::direct_to_stdout();
            say("INFO: $who_am_i Backup returned a failure. The command output is around end of " .
                "'$reporter_prt'.");
            sayFile($reporter_prt);
            remove_clone_dbs_dirs($clone_vardir);
            if ($aux_status >= STATUS_CRITICAL_FAILURE) {
                say("ERROR: The status is too bad. " . Basics::exit_status_text($aux_status));
                exit $aux_status;
            } else {
                if (1064 == $aux_err) {
                    $aux_status = STATUS_BACKUP_FAILURE;
                    say("ERROR: The error harvested is too bad. " . Basics::exit_status_text($aux_status));
                    exit $aux_status;
                } elsif (1213 == $aux_err) {
                    $aux_status = STATUS_OK;
                    say("INFO: The deadlock harvested has to be tolerated. " . Basics::return_status_text($aux_status));
                    return $aux_status;
                } elsif (1205 == $aux_err) {
                    $aux_status = STATUS_OK;
                    say("INFO: Exceeding the lock wait timeout has to be tolerated. " . Basics::return_status_text($aux_status));
                    return $aux_status;
                } else {
                    $aux_status = STATUS_BACKUP_FAILURE;
                    say("ERROR: The error harvested is too bad. " . Basics::exit_status_text($aux_status));
                    exit $aux_status;
                }
            }
        }
    }

    if (STATUS_OK != Basics::copy_dir_to_newdir($clone_datadir, $rqg_backup_dir . "/data")) {
        Basics::direct_to_stdout();
        $status = STATUS_INTERNAL_ERROR;
        say("ERROR: $who_am_i Copying '$clone_datadir' to '$rqg_backup_dir' failed. " .
            Basics::exit_status_text($status));
        exit $status;
    };
    # say("DEBUG: $who_am_i abspath to FBackup stuff ->" . Cwd::abs_path($rqg_backup_dir . "/data") . "<-");

    # mariabckup --prepare is ahead
    if ($reporter->testEnd() <= time() + 10) {
        $status = STATUS_OK;
        Basics::direct_to_stdout();
        remove_clone_dbs_dirs($clone_vardir);
        say("INFO: $who_am_i Endtime is nearly exceeded. " . Basics::exit_status_text($status));
        return $status;
    }

    # Start on backupped data is ahead
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

    my $th_status;
    local $SIG{TERM} =  sub { $th_status = TERM_handler ; say("DEBUG: TERM_handler th_status : $th_status")};

    # Let routines from lib/DBServer_e/MySQL/MySQLd.pm do as much of the job as possible.
    # I hope that this will work on WIN.
    # Warning:
    # Do not set the names of the server general log or error log like older code did.
    # This cannot work well when using DBServer_e::MySQL::MySQLd because that assumes some
    # standard layout with standard names below $clone_vardir.
    my $name =  'backup';
    $clone_server =  DBServer_e::MySQL::MySQLd->new(
                            basedir            => $clone_basedir,
                            vardir             => $clone_vardir,
                            port               => $clone_port,
                            start_dirty        => 1,
                            valgrind           => undef,
                            valgrind_options   => undef,
                            rr                 => $rr,
                            server_options     => \@mysqld_options,
                            general_log        => 1,
                            config             => undef,
                            id                 => $name,
                            user               => $source_server->user());

    my $server_name =   "server[$name]";
    $clone_err =     $clone_server->errorlog();

    # system("ls -ld " . $clone_datadir . "/ib_logfile*");
    say("INFO: Attempt to start a DB server on the cloned data.");
    $status = $clone_server->startServer();
    if ($status != STATUS_OK) {
        # Experimental
        if (defined $th_status) {
            # defined $th_status == TERM got
            #     $th_status == STATUS_OK --> return STATUS_OK (== $th_status)
            #     $th_status != STATUS_OK --> return $th_status
            Basics::direct_to_stdout();
            say("INFO: $who_am_i SIGTERM received. Will return status $th_status");
            return $th_status;
        } else {
            Basics::direct_to_stdout();
            # It is intentional to exit with STATUS_BACKUP_FAILURE.
            $status = STATUS_BACKUP_FAILURE;
            say("ERROR: $who_am_i Starting a DB server on the cloned data failed.");
            sayFile($clone_err);
            sayFile($reporter_prt);
            say("ERROR: $who_am_i " . Basics::exit_status_text($status));
            exit $status;
        }
    }
    say("INFO: Server start on the cloned data passed.");

    # Certain checks are ahead
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
    # I can at least imagine that some server on backupped data can be started, passes checks
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
    system("find $clone_vardir -follow") if $script_debug;
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
