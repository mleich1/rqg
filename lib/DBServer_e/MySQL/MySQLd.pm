# Copyright (c) 2010, 2012, Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2013, 2022, MariaDB Corporation Ab
# Copyright (c) 2023 MariaDB plc
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

package DBServer_e::MySQL::MySQLd;

@ISA = qw(DBServer_e::DBServer);

use DBI;
use DBServer_e::DBServer;
use Time::HiRes;
use POSIX ":sys_wait_h";
use GenTest_e;
use if osWindows(), Win32::Process;

use strict;

use Carp;
use Data::Dumper;
use File::Basename qw(dirname);
use File::Path qw(mkpath rmtree);
use File::Copy qw(move);
use Auxiliary;
use Runtime;
use GenTest_e::Constants;

use constant MYSQLD_BASEDIR                      => 0;
use constant MYSQLD_VARDIR                       => 1;
use constant MYSQLD_DATADIR                      => 2;
use constant MYSQLD_PORT                         => 3;
use constant MYSQLD_MYSQLD                       => 4;
use constant MYSQLD_LIBMYSQL                     => 5;
use constant MYSQLD_BOOT_SQL                     => 6;
use constant MYSQLD_STDOPTS                      => 7;
use constant MYSQLD_MESSAGES                     => 8;
use constant MYSQLD_CHARSETS                     => 9;
use constant MYSQLD_SERVER_OPTIONS               => 10;
use constant MYSQLD_AUXPID                       => 11;
use constant MYSQLD_SERVERPID                    => 12;
use constant MYSQLD_WINDOWS_PROCESS              => 13;
use constant MYSQLD_DBH                          => 14;
use constant MYSQLD_START_DIRTY                  => 15;
use constant MYSQLD_VALGRIND                     => 16;
use constant MYSQLD_VALGRIND_OPTIONS             => 17;
use constant MYSQLD_VERSION                      => 18;
use constant MYSQLD_DUMPER                       => 19;
use constant MYSQLD_SOURCEDIR                    => 20;
use constant MYSQLD_GENERAL_LOG                  => 21;
use constant MYSQLD_WINDOWS_PROCESS_EXITCODE     => 22;
use constant MYSQLD_SERVER_TYPE                  => 23;
use constant MYSQLD_VALGRIND_SUPPRESSION_FILE    => 24;
use constant MYSQLD_TMPDIR                       => 25;
use constant MYSQLD_CONFIG_CONTENTS              => 26;
use constant MYSQLD_CONFIG_FILE                  => 27;
use constant MYSQLD_USER                         => 28;
use constant MYSQLD_MAJOR_VERSION                => 29;
use constant MYSQLD_CLIENT_BINDIR                => 30;
use constant MYSQLD_SERVER_VARIABLES             => 31;
use constant MYSQLD_SQL_RUNNER                   => 32;
use constant MYSQLD_RR                           => 33;
use constant MYSQLD_RR_OPTIONS                   => 34;
# RQG server id   1 till number of servers.
# It is recommended to
# - set the server variable server_id to the same value
# - have that value of vardir
# in order to reduce confusion.
# But do not write code which relies on that the recommendation is followed.
# Some example of an exception:
#     server[0]->[MYSQLD_SERVER_OPTIONS] describes the setup of the first server.
#         vardir of that server is <some value>/1
#         basedir is $basedir[1] == /Server_bin/10.5
#     ... get it up, GenData, GenTest, Shutdown ...
#     server[1]->[MYSQLD_SERVER_OPTIONS] describes the setup of the to be restarted server.
#         vardir of that server needs to be <some value>/1
#         basedir could be $basedir[2] == /Server_bin/10.5
#         but also maybe $basedir[2] == /Server_bin/10.6
# MYSQLD_SERVER_ID will be most time used for better messages in case we run several
# DB server in parallel.
use constant MYSQLD_SERVER_ID                    => 35;

use constant MYSQLD_PID_FILE                     => "mysql.pid";
use constant MYSQLD_ERRORLOG_FILE                => "mysql.err";
use constant MYSQLD_BOOTSQL_FILE                 => "boot.sql";
use constant MYSQLD_BOOTERR_FILE                 => "boot.err";
use constant MYSQLD_LOG_FILE                     => "mysql.log";
use constant MYSQLD_DEFAULT_PORT                 =>  19300;
use constant MYSQLD_DEFAULT_DATABASE             => "test";
use constant MYSQLD_WINDOWS_PROCESS_STILLALIVE   => 259;

# Timeouts
# -----------------------------------
# All timout values etc. are in seconds.
# in lib/Runtime.pm
# use constant RUNTIME_FACTOR_RR                   => 2;
# use constant RUNTIME_FACTOR_VALGRIND             => 2;
#
use constant DEFAULT_SHUTDOWN_TIMEOUT            => 180;
# Maximum timespan between time of kill TERM for server process and the time the server process
# should have disappeared. Per docu TERM causes the same way of shutdown like mysqladmin shutdown.
# How much gets done depends on the variable innodb_fast_shutdown (default is 1).
use constant DEFAULT_TERM_TIMEOUT                => 120;
# Maximum timespan between time of fork of auxiliary process + acceptable start time of some
# tool (rr etc. if needed at all) and the pid getting printed into the server error log.
use constant DEFAULT_PID_SEEN_TIMEOUT            => 60;
# Maximum timespan between the pid getting printed into the server error log
# and the message about the server being connectable.
use constant DEFAULT_STARTUP_TIMEOUT             => 600;
# Maximum timespan between time of server process disappeared or KILL or similar for server
# the process and the auxiliary process reaped.
# Main task: Give sufficient time for finishing write of rr trace or core file or ...
use constant DEFAULT_AUXPID_GONE_TIMEOUT         => 90;
# Maximum timespan between sending a SIGKILL to the server process and it disappearing
# Maybe the time required for rr writing the rr trace till end is in that timespan.
use constant DEFAULT_SERVER_KILL_TIMEOUT         => 30;
# Maximum timespan between sending a SIGABRT to the server process and it disappearing
# Maybe the time required for rr writing the rr trace till end is in that timespan.
use constant DEFAULT_SERVER_ABRT_TIMEOUT         => 60;


my %aux_pids;

sub new {
    my $class = shift;

    my $self = $class->SUPER::new({
                'basedir'               => MYSQLD_BASEDIR,
                'sourcedir'             => MYSQLD_SOURCEDIR,
                'vardir'                => MYSQLD_VARDIR,
                'port'                  => MYSQLD_PORT,
                'server_options'        => MYSQLD_SERVER_OPTIONS,
                'start_dirty'           => MYSQLD_START_DIRTY,
                'general_log'           => MYSQLD_GENERAL_LOG,
                'valgrind'              => MYSQLD_VALGRIND,
                'valgrind_options'      => MYSQLD_VALGRIND_OPTIONS,
                'config'                => MYSQLD_CONFIG_CONTENTS,
                'user'                  => MYSQLD_USER,
                'rr'                    => MYSQLD_RR,
                'rr_options'            => MYSQLD_RR_OPTIONS,
                'id'                    => MYSQLD_SERVER_ID
    },@_);

    if (osWindows()) {
        ## Use unix-style path's since that's what Perl expects...
        $self->[MYSQLD_BASEDIR] =~ s/\\/\//g;
        $self->[MYSQLD_VARDIR]  =~ s/\\/\//g;
        $self->[MYSQLD_DATADIR] =~ s/\\/\//g;
    }

    # Observation 2021-01
    # _absPath("'/dev/shm/vardir'") returns '' !
    # Of course the value "'/dev/shm/vardir'" is crap and it should have been checked
    # earlier that such a directory exists or can be created.
    # Why the assumption that $self->vardir must be than meant relativ to $self->basedir?
    # <runner>.pl command line help does not say that.
#   if (not $self->_absPath($self->vardir)) {
#       $self->[MYSQLD_VARDIR] = $self->basedir."/".$self->vardir;
#   }

    # Default tmpdir for server.
    $self->[MYSQLD_TMPDIR] =  $self->vardir . "/tmp";

    $self->[MYSQLD_DATADIR] = $self->[MYSQLD_VARDIR] . "/data";

    # If mysqld server is found use it.
    eval {
        $self->[MYSQLD_MYSQLD] = $self->_find([$self->basedir],
                                              osWindows()?["sql/Debug","sql/RelWithDebInfo","sql/Release","bin"]:["sql","libexec","bin","sbin"],
                                              osWindows()?"mysqld.exe":"mysqld");
    };

    $self->serverType($self->[MYSQLD_MYSQLD]);

    if (not defined $self->serverType($self->[MYSQLD_MYSQLD])) {
        say("ERROR: No fitting server binary in '$self->basedir' found.");
        return undef;
    }

    $self->[MYSQLD_BOOT_SQL] = [];

    $self->[MYSQLD_DUMPER] = $self->_find([$self->basedir],
                                          osWindows()?["client/Debug","client/RelWithDebInfo","client/Release","bin"]:["client","bin"],
                                          osWindows()?"mysqldump.exe":"mysqldump");

    $self->[MYSQLD_CLIENT_BINDIR] = dirname($self->[MYSQLD_DUMPER]);

    ## Check for CMakestuff to get hold of source dir:

    if (not defined $self->sourcedir) {
        if (-e $self->basedir."/CMakeCache.txt") {
            open CACHE, $self->basedir."/CMakeCache.txt";
            while (<CACHE>){
                if (m/^MySQL_SOURCE_DIR:STATIC=(.*)$/) {
                    $self->[MYSQLD_SOURCEDIR] = $1;
                    say("Found source directory at ".$self->[MYSQLD_SOURCEDIR]);
                    last;
                }
            }
        }
    }

    ## Use valgrind suppression file available in mysql-test path.
    if ($self->[MYSQLD_VALGRIND]) {
        $self->[MYSQLD_VALGRIND_SUPPRESSION_FILE] = $self->_find(defined $self->sourcedir?[$self->basedir,$self->sourcedir]:[$self->basedir],
                                                             osWindows()?["share/mysql-test","mysql-test"]:["share/mysql-test","mysql-test"],
                                                             "valgrind.supp")
    };

    foreach my $file ("mysql_system_tables.sql",
                      "mysql_performance_tables.sql",
                      "mysql_system_tables_data.sql",
                      "mysql_test_data_timezone.sql",
                      "fill_help_tables.sql") {
        my $script =
             eval { $self->_find(defined $self->sourcedir?[$self->basedir,$self->sourcedir]:[$self->basedir],
                          ["scripts","share/mysql","share"], $file) };
        push(@{$self->[MYSQLD_BOOT_SQL]},$script) if $script;
    }

    $self->[MYSQLD_MESSAGES] =
       $self->_findDir(defined $self->sourcedir?[$self->basedir,$self->sourcedir]:[$self->basedir],
                       ["sql/share","share/mysql","share"], "english/errmsg.sys");

    $self->[MYSQLD_CHARSETS] =
        $self->_findDir(defined $self->sourcedir?[$self->basedir,$self->sourcedir]:[$self->basedir],
                        ["sql/share/charsets","share/mysql/charsets","share/charsets"], "Index.xml");


    #$self->[MYSQLD_LIBMYSQL] =
    #   $self->_findDir([$self->basedir],
    #                   osWindows()?["libmysql/Debug","libmysql/RelWithDebInfo","libmysql/Release","lib","lib/debug","lib/opt","bin"]:["libmysql","libmysql/.libs","lib/mysql","lib"],
    #                   osWindows()?"libmysql.dll":osMac()?"libmysqlclient.dylib":"libmysqlclient.so");

    $self->[MYSQLD_STDOPTS] = ["--basedir=".$self->basedir,
                               $self->_messages,
                               "--character-sets-dir=".$self->[MYSQLD_CHARSETS],
                               "--tmpdir=".$self->[MYSQLD_TMPDIR]];

    if ($self->[MYSQLD_START_DIRTY]) {
        say("Using existing data for MySQL " . $self->version . " at " . $self->datadir);
    } else {
        say("Creating MySQL " . $self->version . " database at " . $self->datadir);
        if ($self->createMysqlBase != STATUS_OK) {
            say("ERROR: Bootstrap failed. Will return undef.");
            return undef;
        }
    }
    return $self;
}

sub basedir {
    return $_[0]->[MYSQLD_BASEDIR];
}

sub clientBindir {
    return $_[0]->[MYSQLD_CLIENT_BINDIR];
}

sub sourcedir {
    return $_[0]->[MYSQLD_SOURCEDIR];
}

sub datadir {
    return $_[0]->[MYSQLD_DATADIR];
}

sub setDatadir {
    $_[0]->[MYSQLD_DATADIR] = $_[1];
}

sub set_rr {
    $_[0]->[MYSQLD_RR] = $_[1];
}

sub set_rr_options {
    $_[0]->[MYSQLD_RR_OPTIONS] = $_[1];
}

sub vardir {
    return $_[0]->[MYSQLD_VARDIR];
}

sub port {
    my ($self) = @_;

    if (defined $self->[MYSQLD_PORT]) {
        return $self->[MYSQLD_PORT];
    } else {
        return MYSQLD_DEFAULT_PORT;
    }
}

sub setPort {
    my ($self, $port) = @_;
    $self->[MYSQLD_PORT]= $port;
}

sub user {
    return $_[0]->[MYSQLD_USER];
}

sub serverpid {
    return $_[0]->[MYSQLD_SERVERPID];
}

sub forkpid {
    return $_[0]->[MYSQLD_AUXPID];
}

sub socketfile {
    my ($self) = @_;
    my $socketFileName = $_[0]->vardir."/mysql.sock";
    if (length($socketFileName) >= 100) {
        $socketFileName = "/tmp/RQGmysql.".$self->port.".sock";
    }
    return $socketFileName;
}

sub pidfile {
    return $_[0]->vardir."/".MYSQLD_PID_FILE;
}

# FIXME:
# This is a duplicate of serverpid. Why does it exist?
sub pid {
    return $_[0]->[MYSQLD_SERVERPID];
}

sub logfile {
    return $_[0]->vardir."/".MYSQLD_LOG_FILE;
}

sub errorlog {
    return $_[0]->vardir."/".MYSQLD_ERRORLOG_FILE;
}

sub setStartDirty {
    $_[0]->[MYSQLD_START_DIRTY] = $_[1];
}

sub valgrind_suppressionfile {
    return $_[0]->[MYSQLD_VALGRIND_SUPPRESSION_FILE] ;
}

#sub libmysqldir {
#    return $_[0]->[MYSQLD_LIBMYSQL];
#}

# Check the type of mysqld server.
sub serverType {
    my ($self, $mysqld) = @_;
    $self->[MYSQLD_SERVER_TYPE] = "Release";

    my $command="$mysqld --version";
    my $result=`$command 2>&1`;

    $self->[MYSQLD_SERVER_TYPE] = "Debug" if ($result =~ /debug/sig);
    return $self->[MYSQLD_SERVER_TYPE];
}

sub generateCommand {
    my ($self, @opts) = @_;

    my $command = '"'.$self->binary.'"';
    foreach my $opt (@opts) {
        $command .= ' '.join(' ',map{'"'.$_.'"'} @$opt);
    }
    $command =~ s/\//\\/g if osWindows();
    return $command;
}

sub addServerOptions {
    my ($self,$opts) = @_;

    push(@{$self->[MYSQLD_SERVER_OPTIONS]}, @$opts);
}

sub getServerOptions {
  my $self= shift;
  return $self->[MYSQLD_SERVER_OPTIONS];
}

sub printServerOptions {
    my $self = shift;
    foreach (@{$self->[MYSQLD_SERVER_OPTIONS]}) {
        say("    $_");
    }
}

sub createMysqlBase  {
    my ($self) = @_;

    my $who_am_i = Basics::who_am_i;

    # Important:
    # rqg.pl calls a routine which
    # - removes existing DB related directories including content if already existing
    # - creates DB related directories
    # per DB server to be used.

    #### Prepare config file if needed
    if ($self->[MYSQLD_CONFIG_CONTENTS] and ref $self->[MYSQLD_CONFIG_CONTENTS] eq 'ARRAY' and
        scalar(@{$self->[MYSQLD_CONFIG_CONTENTS]})) {
        $self->[MYSQLD_CONFIG_FILE] = $self->vardir . "/my.cnf";
        if (not open(CONFIG, ">$self->[MYSQLD_CONFIG_FILE]")) {
            my $status = STATUS_FAILURE;
            say("ERROR: $who_am_i Could not open ->" . $self->[MYSQLD_CONFIG_FILE] .
                "for writing: $!. Will return status STATUS_FAILURE" . "($status)");
            return $status;
        }
        print CONFIG @{$self->[MYSQLD_CONFIG_CONTENTS]};
        close CONFIG;
        say("Config file '" . $self->[MYSQLD_CONFIG_FILE] . "' ----------- begin");
        sayFile($self->[MYSQLD_CONFIG_FILE]);
        say("Config file '" . $self->[MYSQLD_CONFIG_FILE] . "' ----------- end");
    }

    my $defaults = ($self->[MYSQLD_CONFIG_FILE] ? "--defaults-file=$self->[MYSQLD_CONFIG_FILE]" : "--no-defaults");

    #### Create boot file
    my $boot = $self->vardir . "/" . MYSQLD_BOOTSQL_FILE;
    if (not open BOOT, ">$boot") {
        my $status = STATUS_FAILURE;
        say("ERROR: $who_am_i Could not open ->" . $boot .
            " for writing: $!. Will return status STATUS_FAILURE" . "($status)");
        return $status;
    }
    print BOOT "CREATE DATABASE test;\n";

    #### Boot database
    my $boot_options = [$defaults];
    push @$boot_options, @{$self->[MYSQLD_STDOPTS]};
    push @$boot_options, "--datadir=" . $self->datadir; # Could not add to STDOPTS, because datadir could have changed


    if ($self->_olderThan(5,6,3)) {
        push(@$boot_options,"--loose-skip-innodb", "--default-storage-engine=MyISAM") ;
    } else {
        push(@$boot_options, @{$self->[MYSQLD_SERVER_OPTIONS]});
    }
    # 2019-05 mleich
    # Bootstrap with --mysqld=--loose-innodb_force_recovery=5 fails.
    my @cleaned_boot_options;
    # The '.*' is for covering variables like '--loose-innodb_force_recovery'.
    foreach my $boot_option (@$boot_options) {
        if ($boot_option =~ m{.*innodb.force.recovery} or
            $boot_option =~ m{.*innodb.evict.tables.on.commit.debug})   {
            say("DEBUG: -->" . $boot_option . "<-- will be removed from the bootstrap options.");
            next;
        } else {
            push @cleaned_boot_options, $boot_option;
        }
    }
    @$boot_options = @cleaned_boot_options;

    push @$boot_options, "--skip-log-bin";
    push @$boot_options, "--loose-innodb-encrypt-tables=OFF";
    push @$boot_options, "--loose-innodb-encrypt-log=OFF";
    # Workaround for MENT-350
    if ($self->_notOlderThan(10,4,6)) {
        push @$boot_options, "--loose-server-audit-logging=OFF";
    }

    my $command;
    my $command_begin = '';
    my $command_end   = '';
    my $booterr       = $self->vardir . "/" . MYSQLD_BOOTERR_FILE;

    # Running
    #    push @$boot_options, "--log_error=$booterr"
    # like in history would prevent that rr adds his event numbers etc. to that error log.

    if (not $self->_isMySQL or $self->_olderThan(5,7,5)) {
        # Add the whole init db logic to the bootstrap script
        print BOOT "CREATE DATABASE mysql;\n";
        print BOOT "USE mysql;\n";
        foreach my $b (@{$self->[MYSQLD_BOOT_SQL]}) {
            open B,$b;
            while (<B>) { print BOOT $_;}
            close B;
        }

        push(@$boot_options,"--bootstrap") ;
        if (osWindows()) {
            $command_end = " < \"$boot\" ";
        } else {
            $command_begin = "cat \"$boot\" | ";
        }
    } else {
        push @$boot_options, "--initialize-insecure", "--init-file=$boot";
    }

    # For debugging: Cause that the bootstrap fails.
    # push @$boot_options, "--unknown_option";

    $command = $self->generateCommand($boot_options);

    # FIXME: Maybe add the user in a clean way like CREATE USER ... GRANT .... if possible.
    ## Add last strokes to the boot/init file: don't want empty users, but want the test user instead
    print BOOT "USE mysql;\n";
    print BOOT "DELETE FROM user WHERE `User` = '';\n";
    if ($self->user ne 'root') {
        print BOOT "CREATE TABLE tmp_user AS SELECT * FROM user WHERE `User`='root' AND `Host`='localhost';\n";
        print BOOT "UPDATE tmp_user SET `User` = '". $self->user ."';\n";
        print BOOT "INSERT INTO user SELECT * FROM tmp_user;\n";
        print BOOT "DROP TABLE tmp_user;\n";
        print BOOT "CREATE TABLE tmp_proxies AS SELECT * FROM proxies_priv WHERE `User`='root' AND `Host`='localhost';\n";
        print BOOT "UPDATE tmp_proxies SET `User` = '". $self->user . "';\n";
        print BOOT "INSERT INTO proxies_priv SELECT * FROM tmp_proxies;\n";
        print BOOT "DROP TABLE tmp_proxies;\n";
    }
    close BOOT;

    my $rr = Runtime::get_rr();
    if (defined $rr) {
        # Experiments showed that the rr trace directory must exist in advance.
        my $rr_trace_dir = $self->vardir . '/rr';
        if (not -d $rr_trace_dir) {
            if (not mkdir $rr_trace_dir) {
                my $status = STATUS_FAILURE;
                say("ERROR: createMysqlBase: Creating the 'rr' trace directory '$rr_trace_dir' " .
                    "failed : $!. Will return status STATUS_FAILURE" . "($status)");
                return $status;
            }
        }
        $ENV{'_RR_TRACE_DIR'} = $rr_trace_dir;
        my $rr_options = Runtime::get_rr_options();
        $rr_options =    '' if not defined $rr_options;
        # 1. ulimit -c 0
        #    because we do not want to waste space for core files we do not need if using rr.
        # 2. Maybe banal:
        #    Do not place the rr call somewhere at begin of the command sequence or similar.
        #    Either we trace everything starting with the shell or just one of the commands
        #    but not the server. In addition the '--mark-stdio' causes that the output of
        #    commands might be decorated with rr event ids which some consuming command
        #    is unable to understand. Example: cat <bootstrap file> | ....
        $command_begin = "ulimit -c 0; " .  $command_begin .
                         " rr record " . $rr_options . " --mark-stdio ";
        $command .= ' "--log_warnings=4" ' . Local::get_rqg_rr_add();
    }

    # In theory the bootstrap can end up with a freeze.
    # FIXME/DECIDE: How to handle that.
    # a) (exists) rqg_batch.pl observes that the maximum runtime for a RQG test gets exceeded
    #    and stops the test with SIGKILL processgroup
    #    Disadvantages: ~ 1800s elapsed time and incomplete rr trace of bootstrap
    # b) sigaction SIGALRM ... like lib/GenTest_e/Reporter/Deadlock*.pm
    # c) fork and go with timeouts like in startServer etc.
    $command_end .= " > \"$booterr\" 2>&1 ";
    $command =      $command_begin . $command . $command_end;
    # The next line is could be useful/required for the pattern matching.
    say("Bootstrap command: ->" . $command . "<-");
    system($command);
    my $rc = $? >> 8;
    if ($rc != 0) {
        my $status = STATUS_FAILURE;
        say("ERROR: Bootstrap failed");
        # The current code of make_backtrace is focused on server crashes outside of bootstrap.
        # And because of that it insists in inspecting the stderr output in some 'mysql.err'.
        # Hence I copy 'boot.err' to 'mysql.err' first.
        File::Copy::copy($booterr, $self->errorlog);
        $self->make_backtrace();
        sayFile($booterr);
        say("ERROR: Will return STATUS_FAILURE" . "($status)");
        return $status;
    } else {
        return STATUS_OK;
    }
} # End sub createMysqlBase

sub _reportError {
    say(Win32::FormatMessage(Win32::GetLastError()));
}

####################################################################################################
# Caller (rqg.pl...) of startServer expect that startServer makes a cleanup in case of failure.
# They will not call a killServer later.
####################################################################################################
sub startServer {
# FIXME: We need to return all kinds of statuses
    my ($self) = @_;

    my $who_am_i = "DBServer_e::MySQL::MySQLd::startServer:";

    my @defaults = ($self->[MYSQLD_CONFIG_FILE] ? ("--defaults-group-suffix=.runtime",
                   "--defaults-file=$self->[MYSQLD_CONFIG_FILE]") : ("--no-defaults"));


    my ($v1, $v2, @rest) = $self->versionNumbers;
    my $v = $v1 * 1000 + $v2;
    my $command = $self->generateCommand(
                        [@defaults],
                        $self->[MYSQLD_STDOPTS],
                        # Do not add "--core-file" here because it wastes resources in case
                        # rr is invoked.
                        # ["--core-file",
                        [
                         # Not added to STDOPTS, because datadir could have changed.
                         "--datadir="   . $self->datadir,
                         "--max-allowed-packet=128Mb", # Allow loading bigger blobs
                         "--port="      . $self->port,
                         "--socket="    . $self->socketfile,
                         "--pid-file="  . $self->pidfile],
                         $self->_logOptions);
    # Do not set
    #    "--log_error=" . $self->errorlog,
    # because that will prevent that "rr --mark-stdio" writes its
    # [rr 2835125 794114]mysqld: ....
    #             | Eventnumber
    #     | Pid
    # into the server error log.
    if (defined $self->[MYSQLD_SERVER_OPTIONS]) {
        # Original code with the following bad effect seen
        #     A call is given to the shell and many but not all option settings are enclosed
        #     in double quotes. The non enclosed make trouble if looking like
        #     wsrep_provider_options=repl.causal_read_timeout=PT90S;base_port=16002;<whatever>
        # $command = $command." ".join(' ',@{$self->[MYSQLD_SERVER_OPTIONS]});
        $command = $command . ' "' .join('" "', @{$self->[MYSQLD_SERVER_OPTIONS]}) . '"';
    }
    # If we don't remove the existing pidfile, the server will be considered started too early,
    # and further flow can fail. $self->cleanup_dead_server does that and a bit more.
    my $status = $self->cleanup_dead_server;
    if (STATUS_OK != $status) {
        $status = STATUS_FAILURE;
        say("ERROR: $who_am_i The cleanup before DB server start failed. " .
            "Will return status STATUS_FAILURE" . "($status)");
        return $status;
    }
    my $errorlog = $self->errorlog;
    unlink($errorlog);
    if(0) { # Maybe needed in future.
        my $start_marker = "# [RQG] Before initiating a server start.";
        $self->addErrorLogMarker($start_marker);
        # 9 is mtime  last modify time in seconds since the epoch
        # (stat(<not existing file>))[9] delivers undef.
        # (stat(<not existing file>))[9] || 0 delivers 0.
        my $errlog_last_update_time= (stat($errorlog))[9];
        if (not defined $errlog_last_update_time) {
            my $status = STATUS_FAILURE;
            say("ERROR: $who_am_i The server error log '$errorlog' does not exist. " .
                "Will return status STATUS_FAILURE" . "($status)");
            return $status;
        }
        # Sleep a bit in order to guarantee that any modification of $errorlog has a date
        # younger than $errlog_last_update_time.
        sleep(1.1);
        # If searching maybe read forward to the last $start_marker line?
    }

    # In case some extra tool like rr is needed than a process with it has to come up.
    # Dependency on general load on box.
    my $tool_startup        = 0;

    # Timeout for the server to write his pid into the error log after the server startup
    # command has been launched $tool_startup has passed.
    my $pid_seen_timeout    = DEFAULT_PID_SEEN_TIMEOUT * Runtime::get_runtime_factor();

    # Timeout for the server to report that the startup finished (Ready for connections)
    # after the server pid showed up in the server error log.
    # After that the server is considered hanging).
    my $startup_timeout     = DEFAULT_STARTUP_TIMEOUT * Runtime::get_runtime_factor();
    # Variant:
    # 1. No start dirty == First start after Bootstrap --> Should be quite fast
    # 2. start dirty
    # 2.1 Start on data "formed" by some smooth/slow shutdown or a copy of that
    #     or Mariabackup prepare finished --> Should be quite fast
    # 2.2 Start on data "formed" by some rude shutdown or server kill or a copy of that
    #     --> Could be quite slow
    # As long as assigning a specific restart timeout via test setup is not supported by
    # corresponding code here and on other places I assume that the "start dirty" invokes
    # a crash recovery processing of a lengthy part of the log etc.
    if ($self->[MYSQLD_START_DIRTY]) {
        $startup_timeout = $startup_timeout * 5;
    }

    if (osWindows) {
        my $proc;
        my $exe = $self->binary;
        my $vardir = $self->[MYSQLD_VARDIR];
        $exe =~ s/\//\\/g;
        $vardir =~ s/\//\\/g;
        $self->printInfo();
        say("INFO: Starting MySQL " . $self->version . ": $exe as $command on $vardir");
        # FIXME: Inform about error + return undef so that the caller can clean up
        Win32::Process::Create($proc,
                               $exe,
                               $command,
                               0,
                               NORMAL_PRIORITY_CLASS(),
                               ".") || croak _reportError();
        $self->[MYSQLD_WINDOWS_PROCESS]=$proc;
        $self->[MYSQLD_SERVERPID]=$proc->GetProcessID();
        # Gather the exit code and check if server is running.
        $proc->GetExitCode($self->[MYSQLD_WINDOWS_PROCESS_EXITCODE]);
        if ($self->[MYSQLD_WINDOWS_PROCESS_EXITCODE] == MYSQLD_WINDOWS_PROCESS_STILLALIVE) {
            ## Wait for the pid file to have been created
            my $wait_time = 0.5;
            my $waits = 0;
            while (!-f $self->pidfile && $waits < 600) {
                Time::HiRes::sleep($wait_time);
                $waits++;
            }
            if (!-f $self->pidfile) {
                sayFile($errorlog);
                # FIXME: Inform about error + return undef so that the caller can clean up
                croak("Could not start mysql server, waited ".($waits*$wait_time)." seconds for pid file");
            }
        }
    } else {
        # Ideas taken
        # - from https://www.perlmonks.org/?node_id=1047688
        # - lib/GenTest_e/App/GenTest_e.pm
        # The goals:
        # - minimize the amount of zombies at any point of time
        # - we need complete written cores and rr traces
        #   In case we wait till we can reap the auxiliary process than rr or
        #   whatever should have had enough time for finishing writing.
        $SIG{CHLD} = sub {
            local ($?, $!); # Don't change $! or $? outside handler
            # If we are here than an arbitrary child process has finished.
            #
            # The current process manages server start/stop via using the current module
            # and could be
            # - sometimes a reporter like Crashrecovery who just tries the restart
            # - sometimes just a tool which just manages server start/stop and nothing else
            # - frequent the main process of some RQG runner like rqg.pl.
            # Especially the main processes of RQG runners have various additional child
            # processes which inform via their exit statuses about important observations.
            # (See the worker threads or the periodic reporter in lib/GenTest_e/App/GenTest_e.pm.)
            # So we must not reap the exit status of these additional child processes here
            # because the reaping and processing of their statuses is in GenTest_e.pm or similar.
            # ==> We focus on the pids stored in %aux_pids only.
            #     Only startServer adds pids to %aux_pids.
            #
            # The current "reaper" is the one installed in startServer. And he will reap most
            # auxiliary processes serving for DB server starts.
            # But it is to be feared that this is not sufficient for catching all such auxiliary
            # child processes when they have finished their job.
            # https://docstore.mik.ua/orelly/perl/cookbook/ch16_20.htm says
            # Because the kernel keeps track of undelivered signals using a bit vector, one bit
            # per signal, if two children die before your process is scheduled, you will get only
            # a single SIGCHLD.
            # Therefore killServer,crashServer ... call waitForAuxpidGone which tries to reap too.
            #
            # Observation 2020-12
            # Main process of the RQG runner is 5890.
            # The "DEBUG: server pid : 8014 , server_running :" are caused by running the code
            # of the reporter 'ServerDead'.
            # 11:14:52 [5890] DEBUG: server pid : 8014 , server_running : 1
            # 11:14:53 [5890] WARN: Auxpid 7966 exited with exit status 139.
            #          If auxpid is gone than its child "rr" should have been gone too.
            # 11:14:53 [5890] DEBUG: server pid : 8014 , server_running : 1
            # 11:14:54 [5890] DEBUG: server pid : 8014 , server_running : 1
            #          If the server is running shouldn't it be observed by "rr"?
            #          But isn't "rr" already gone?
            # 11:14:55 [5890] DEBUG: server pid : 8014 , server_running : 0
            # 11:14:55 [5890] INFO: Reporter 'ServerDead': The process of the DB server 8014 is
            #                 no more running
            # My guess:
            # The box is so overloaded that even the OS needs significant time for updating
            # its processtable etc. Probably the DB server process already disappeared 11:14:53.

            my $who_am_i = "Auxpid Reaper:";
            # say("DEBUG: $who_am_i Auxpid_list sorted:" . join("-", sort keys %aux_pids));

            foreach my $pid (keys %aux_pids) {
                if ($$ != $aux_pids{$pid}) {
                    # We are not the parent of $pid. Hence delete the entry.
                    delete $aux_pids{$pid};
                    next;
                }
                # Returns of Auxiliary::reapChild
                # -------------------------------
                # $reaped -- 0 (not reaped) or 1 (reaped)
                # $status -- exit status of the process if reaped,
                #            otherwise STATUS_OK or STATUS_INTERNAL_ERROR
                #     0, STATUS_INTERNAL_ERROR -- most probably already reaped
                #                              == Defect in RQG logics
                my ($reaped, $status) = Auxiliary::reapChild($pid, "Auxpid for DB server start");
                if (1 == $reaped) {
                    delete $aux_pids{$pid};
                    if (STATUS_OK == $status) {
                        say("DEBUG: $who_am_i Auxpid $pid exited with exit status STATUS_OK.")
                    } else {
                        say("WARN: $who_am_i Auxpid $pid exited with exit status $status.");
                        # Making a backtrace if STATUS_OK != $status might look attractive but
                        # it will kick even in harmless situations.
                        # system("killall -15 mysqld") leads to auxpid exits with 137.
                        # Impact:
                        # Aside of confusion if its a server error or not we will get all time
                        # a valueless backtrace if rr tracing.
                    }
                }
                if (0 == $reaped and STATUS_OK != $status) {
                    say("ERROR: $who_am_i Attempt to reap Auxpid $pid failed with status $status.");
                }
            }
        };

        if (defined Runtime::get_valgrind()) {
            $tool_startup =        10;
            my $valgrind_options = Runtime::get_valgrind_options();
            $valgrind_options =    '' if not defined $valgrind_options;
            # FIXME: Do we check somewhere that the $self->valgrind_suppressionfile exists?
            $command = "valgrind --time-stamp=yes --leak-check=yes --suppressions=" .
                       $self->valgrind_suppressionfile . " " . $valgrind_options . " " . $command;
            # say("DEBUG ---- 1 ->" . $command . "<-");
        }

        my $rr_trace_dir;
        my $rr = Runtime::get_rr();
        if (defined $rr) {
            # The rqg runner has to check in advance that 'rr' is installed on the current box.
            my $rr_options = Runtime::get_rr_options();
            $rr_options =   '' if not defined $rr_options;
            $tool_startup = 10;
            $rr_trace_dir = $self->vardir . '/rr';
            if (not -d $rr_trace_dir) {
                # Thinkable reason: We go with --start-diry.
                if (not mkdir $rr_trace_dir) {
                    my $status = STATUS_FAILURE;
                    say("ERROR: startserver: Creating the 'rr' trace directory '$rr_trace_dir' " .
                        "failed : $!. Will return status STATUS_FAILURE" . "($status)");
                    return $status;
                }
            }
            # In case of using 'rr' and core file generation enabled in addition
            # - core files do not offer more information than already provided by rr traces
            # - gdb -c <core file> <mysqld binary> gives sometimes rotten output from
            #   whatever unknown reason
            # - cores files consume ~ 1 GB in vardir (often located in tmpfs) temporary
            #   And that is serious bigger than rr traces.
            # So we prevent the writing of core files via ulimit.
            # "--mark-stdio" causes that a "[rr <pid> <event number>] gets prepended to any line
            # in the DB server error log.
            $command = "ulimit -c 0; rr record " . $rr_options . " --mark-stdio $command";
            # say("DEBUG: ---- 1 ->" . $rr_options . "<-");
            # say("DEBUG: ---- 2 ->" . $command . "<-");
        }

        if (exists $ENV{'RUNNING_UNDER_RR'} or defined $rr) {
            # rr tracing is already active ('RQG') or will become active for the calls of
            # certain binaries.
            # Having more events ('rr' point of view) could make debugging faster.
            # We just try that via more dense logging of events in the server.
            # Example:
            # [rr 19150 245575]2020-05-22 11:13:59 139797702706944 [Warning] Aborted connection 78 to db: 'test' user: 'root' host: 'localhost' (CLOSE_CONNECTION)
            # The content like that there was an abort of a connection is most probably
            # of rather low value. But the
            # [rr 19150 <event_number>] <timestamp> might help to find the right region of
            # events where debugging should start.
            $command .= ' "--log_warnings=4" ' . Local::get_rqg_rr_add();
        } else {
            # In case rr is not invoked than we want core files.
            $command .= ' "--core-file"';
        }

        # This is too early. printInfo needs the pid which is currently unknown!
        # $self->printInfo;

        say("INFO: Starting MySQL " . $self->version . ": $command");

        $self->[MYSQLD_AUXPID] = fork();
        if ($self->[MYSQLD_AUXPID]) {

            # We put the pid of the parent as value into %aux_pids.
            # By that any future child like the reporter 'Crashrecovery*' knows that it cannot reap
            # that auxiliary process.
            $aux_pids{$self->[MYSQLD_AUXPID]} = $$;
            # Unfortunately it cannot be guaranteed that this child process will be later
            # the DB server. Two examples:
            # Parent is k, the child is l
            # a) The child runs a shell, this forks a grand child m acting as db server.
            #    After m exits l might check something and than exits too.
            #    The DB server process is m.
            # b) It might look attractive if the child l just runs exec "DB server" because
            #    than l is the DB server.
            #    But this does not help in case we invoke "rr".
            #    l will be the running rr and that forks a process m being the running DB server??
            # Nevertheless observing MYSQLD_AUXPID (l) makes sense because that process will
            # disappear if the db server or rr process is gone.

            # DB Servers print in minimum since MariaDB 10.0 a line
            # [Note] <path>/mysqld (mysqld <version>) starting as process <pid> ...
            #    <version> is like 10.1.45-MariaDB-debug
            # and a bit later
            # Note] <path>/mysqld: ready for connections.

            # The pid file has only some limited value compared to the server error log content
            # If it
            # a) exists and is empty than the system is or at least was around startup
            #    Per observation: An empty file exists first. The pid value gets added later.
            # b) exists and is complete written than there is the pid only
            #    If that process is running or no more running is another story.
            # c) existed and has disappeared than the server made some controlled "give up".
            #    It is extreme unlikely that a server process is running.
            #    There is some short delay between pid file removal and that process disappering
            #    OS processlist.
            # d) just does not exist than the situation is complete unclear.

            my $wait_time      = 0.2;
            my $pid;
            my $pidfile_seen   = 0;

            # say("DEBUG: Start the waiting for the server error log line with the pid.");

            # For experimenting
            # $self->stop_server_for_debug(3, -11, 'mysqld', 10);

            my $start_time = time();
            my $wait_end =   $start_time + $tool_startup + $pid_seen_timeout;
            while (1) {
                Time::HiRes::sleep($wait_time);
                # Style till mid 2023-01
                # [Note] /data/Server_bin/bb-10.6-MDEV-29181C_asan_Og/bin/mysqld (server 10.6.12-MariaDB-debug-log) starting as process 1794271 ...
                # Style since mid 2023-01
                # [Note] Starting MariaDB 10.7.8-MariaDB-debug-log source revision 666149485fef2f51cd5685cc2172f561b2679209 as process 3283580
                $pid = Auxiliary::get_string_after_pattern($errorlog,
                           "Starting MariaDB .{1,300} as process ");
                if (not defined $pid) {
                    # It is not guaranteed that $errorlog exists immediate.
                    if (time() > $start_time + $tool_startup + 5) {
                        my $status = STATUS_ENVIRONMENT_FAILURE;
                        say("ERROR: $who_am_i Trouble with '$errorlog'. " .
                            Auxiliary::build_wrs($status));
                        return $status;
                    }
                } elsif ('' eq $pid) {
                    $pid = Auxiliary::get_string_after_pattern($errorlog,
                           "mysqld .{1,100} starting as process ");
                    if (time() > $start_time + $tool_startup + 5) {
                         if (not defined $pid) {
                             my $status = STATUS_ENVIRONMENT_FAILURE;
                             say("ERROR: $who_am_i Trouble with '$errorlog'. " .
                                 Auxiliary::build_wrs($status));
                             return $status;
                         }
                    }
                }
                $pid = Auxiliary::check_if_reasonable_pid($pid);
                if (defined $pid) {
                    $self->[MYSQLD_SERVERPID] = $pid;
                    say("INFO: $who_am_i Time till server pid $pid detected in s: " .
                        (time() - $start_time));
                    # Auxiliary::print_ps_tree($$);
                    last;
                }

                # Maybe $self->[MYSQLD_AUXPID] has already finished and was reaped.
                if (not kill(0, $self->[MYSQLD_AUXPID])) {
                    my $status = STATUS_SERVER_CRASHED;
                    say("ERROR: $who_am_i The auxiliary process is no more running. " .
                        Auxiliary::build_wrs($status));
                    # The status reported by cleanup_dead_server does not matter.
                    $self->cleanup_dead_server;
                    $self->make_backtrace();
                    return $status;
                }

                if (time() >= $wait_end) {
                    my $status = STATUS_CRITICAL_FAILURE;
                    say("ERROR: $who_am_i The Server has not printed its pid within the last " .
                        ($pid_seen_timeout + $tool_startup) ."s. " . Auxiliary::build_wrs($status));
                    # The status reported by cleanup_dead_server does not matter.
                    # cleanup_dead_server takes care of $self->[MYSQLD_AUXPID].
                    $self->cleanup_dead_server;
                    sayFile($errorlog);
                    return $status;
                }
            }
            # $self->stop_server_for_debug(5, 'mysqld', -11, 5);

            # If reaching this line we have a valid pid in $pid and $self->[MYSQLD_SERVERPID].

            # SIGKILL or SIGABRT sent to the server make no difference for the fate of "rr".
            # "rr" finishes smooth and get reaped by its parent.

            # $self->stop_server_for_debug(5, 'mysqld', -6, 5);
            $start_time = time();
            $wait_end =   $start_time + $startup_timeout;
            while (1) {
                Time::HiRes::sleep($wait_time);
                if (not kill(0, $pid)) {
                    my $status = STATUS_SERVER_CRASHED;
                    say("ERROR: $who_am_i The Server process disappeared after having started " .
                        "with pid $pid. " . Auxiliary::build_wrs($status));
                    # The status reported by cleanup_dead_server does not matter.
                    # cleanup_dead_server takes care of $self->[MYSQLD_AUXPID].
                    $self->cleanup_dead_server;
                    $self->make_backtrace();
                    # sayFile($errorlog);
                    return $status;
                }

                my $found;
                # Several threads are working in parallel on getting the server started.
                # Observation 2021-12-02
                # 1. Start server on backupped data.
                # 2. Poll till the server is connectable and run immediate a bit SQL with success.
                # But the sever error log contains:
                # mysqld: ... Assertion .... failed.
                # [ERROR] mysqld got signal 6 ;
                # Attempting backtrace. You can use the following information to find out
                # [Note] /data/Server_bin/bb-10.6-MDEV-27111_asan/bin/mysqld: ready for connections.
                # And the connect was possible before 'ready for connections' was observed.
                #
                # We search for a line like
                # [ERROR] mysqld got signal <some signal>
                # There seem to be
                # - artificial signals like
                #   1. Write [ERROR] mysqld got signal <some signal>
                #   2. Send <some signal> to the process
                #   like the server sends SEGV to itself
                # - maybe trap some signal from outside
                #   1. Write [ERROR] mysqld got signal <some signal>
                #   2. Do what is to be done for <some signal>
                #
                # Do not search for 'mysqld: ready for connections' in case the outcome is
                # already decided by "[ERROR] mysqld got signal".
                $found = Auxiliary::search_in_file($errorlog,
                                                   "\[ERROR\] mysqld got signal");
                if (not defined $found) {
                    # Technical problems.
                    my $status = STATUS_ENVIRONMENT_FAILURE;
                    say("FATAL ERROR: $who_am_i \$found is undef. Will KILL the server and " .
                        Auxiliary::build_wrs($status));
                    sayFile($errorlog);
                    $self->killServer;
                    # No call of make_backtrace because the problem is around the existence of the
                    # server error log or similar.
                    return $status;
                } elsif ($found) {
                    my $status = STATUS_SERVER_CRASHED;
                    say("INFO: $who_am_i '[ERROR] mysqld got signal ' observed.");
                    $self->make_backtrace();
                    # sayFile($errorlog);
                    return $status;
                } else {
                    # say("DEBUG: $who_am_i Up till now no '[ERROR] mysqld got signal ' observed.");
                }

                # We search for a line like
                # [Note] /home/mleich/Server_bin/10.5_asan_Og/bin/mysqld: ready for connections.
                $found = Auxiliary::search_in_file($errorlog,
                                                   "\[Note\].{1,150}mysqld: ready for connections");
                # For testing:
                # $found = undef;
                if (not defined $found) {
                    # Technical problems!
                    my $status = STATUS_ENVIRONMENT_FAILURE;
                    say("FATAL ERROR: $who_am_i \$found is undef. Will KILL the server and " .
                        Auxiliary::build_wrs($status));
                    sayFile($errorlog);
                    $self->killServer;
                    return $status;
                } elsif ($found) {
                    say("INFO: $who_am_i Time for server startup in s: " . (time() - $start_time));
                    last;
                } else {
                    # say("DEBUG: $who_am_i Waiting for finish of server startup.");
                }
                if (time() >= $wait_end) {
                    my $status = STATUS_CRITICAL_FAILURE;
                    say("ERROR: $who_am_i The Server has not finished its start within the ".
                        "last $startup_timeout" . "s. Will crash the server, make a backtrace and " .
                        Auxiliary::build_wrs($status));
                    $self->crashServer();
                    $self->make_backtrace();
                    sayFile($errorlog);
                    return $status;
                }
            }

            # If reaching this line
            # - we have a valid pid in $pid and $self->[MYSQLD_SERVERPID]
            # - mysqld: ready for connections    was already reported
            # - the server startup is finished

            # $self->stop_server_for_debug(5, 'mysqld', -6, 5);
            # $self->stop_server_for_debug(5, 'mysqld', -15, 5);
            # my $pid_from_file = $self->get_pid_from_pid_file;
            my $pid_from_file = Auxiliary::get_pid_from_file($self->pidfile);
            if (not defined $pid_from_file) {
                if (not kill(0, $pid)) {
                    # Maybe there are some asynchronous tasks
                    # - already running when "mysqld: ready for connections" gets reported
                    # - starting after reporting that
                    # which failed after reporting that and than the server processs disappeared.
                    # Also the $self->pidfile might have existed and deleted.
                    my $status = STATUS_SERVER_CRASHED;
                    say("ERROR: $who_am_i Server process $pid disappeared after having finished " .
                        "the startup. " . Auxiliary::build_wrs($status));
                    # The status returned by cleanup_dead_server does not matter.
                    $self->cleanup_dead_server;
                    $self->make_backtrace();
                    # sayFile($errorlog);
                    return $status;
                } else {
                    say("ERROR: $who_am_i Server startup is finished, process $pid is running, " .
                        "but trouble with pid file.");
                    my $status = STATUS_CRITICAL_FAILURE;
                    say("ERROR: $who_am_i Will kill the server process with ABRT and " .
                        Auxiliary::build_wrs($status));
                    sayFile($errorlog);
                    $self->crashServer;
                    $self->make_backtrace();
                    return $status;
                }
            }
            if ($pid and $pid != $pid_from_file) {
                say("ERROR: $who_am_i pid extracted from the error log ($pid) differs from the " .
                    "pid in the pidfile ($pid_from_file).");
                # Auxiliary::print_ps_tree($$);
                my $status = STATUS_INTERNAL_ERROR;
                say("ERROR: $who_am_i Will kill both processes with KILL and " .
                    Auxiliary::build_wrs($status));
                sayFile($errorlog);
                # There is already a kill routine. But I want to be "double" sure.
                kill 'KILL' => $self->serverpid;
                kill 'KILL' => $pid_from_file;
                $self->killServer();
                return $status;
            }
            $self->printInfo;
        } else {
            # THIS IS THE CHILD with pid MYSQLD_AUXPID who tries soon to start the server.
            # ----------------------------------------------------------------------------
            # Warning: Current pid is != PID found in server error log or pid file because
            # of natural reasons like     bash -> rr -> mysqld
            # say("DEBUG ----: Here is $$ before exec to DB server");
            $ENV{'_RR_TRACE_DIR'} = $rr_trace_dir if defined $rr_trace_dir;
            # say("DEBUG ---- 4 ->" . $command . "<-");
            # Reason for going with $command >> \"$errorlog\" 2>&1 :
            # In case "rr" has problems or similar than it laments about its problems into $errorlog.
            # Maybe add syncing whatever data or should routines consuming that data like the
            # reporter Backtrace take care of that?
            # IDEA:
            # Maybe append a perl program looking for crash and making a backtrace after the start?
            exec("$command >> \"$errorlog\" 2>&1") || Carp::cluck("ERROR: Could not start mysql server");
            #    say("DEBUG ---- 5 !!!!");
        }
    }
    if (not defined $self->dbh) {
        # $self->dbh is a function and tries to make a connect.
        my $status = STATUS_FAILURE;
        say("ERROR: $who_am_i We did not get a connection to the just started server. " .
            "Will return STATUS_FAILURE" . "($status)");
        return STATUS_FAILURE;
    } else {
        # Rare occuring scenario:
        # Start server, have load, shutdown, restart with modified system variables without
        # using the current sub.
        # So reset the hash with server variables now because we want actual data later.
        %{$self->[MYSQLD_SERVER_VARIABLES]} = ();
        $self->serverVariablesDump();
        # What is ensured:
        # The server is running, connectable, SQL pulling variables worked.
        # Hence other SQL with correct syntax should work too.
        return STATUS_OK;
    }
}

### CHECK:
# Any crashServer, killServer, stopServer, Term needs to cleanup pids pidfile etc.
# because they could be called from outside like Reporters etc.
#
# If $silent is defined than do not lament about expected events like undef pids or missing files.
# This makes RQG logs after passing
#    MATCHING: Region end   =====================
# less noisy.
#
sub killServer {
    my ($self, $silent) = @_;

    my $who_am_i = Basics::who_am_i();
    $silent = 0 if not defined $silent;

    my $kill_timeout = DEFAULT_SERVER_KILL_TIMEOUT * Runtime::get_runtime_factor();

    if (osWindows()) {
        if (defined $self->[MYSQLD_WINDOWS_PROCESS]) {
            $self->[MYSQLD_WINDOWS_PROCESS]->Kill(0);
            say("INFO: $who_am_i Killed process ".$self->[MYSQLD_WINDOWS_PROCESS]->GetProcessID());
        }
    } else {
        if (not defined $self->serverpid) {
            # Why not picking the value from server error log?
            $self->[MYSQLD_SERVERPID] = Auxiliary::get_pid_from_file($self->pidfile, $silent);
            if (defined $self->serverpid) {
                say("WARN: $who_am_i serverpid had to be extracted from pidfile.") if not $silent;
            }
        }
        if (defined $self->serverpid) {
            if (not $self->running) {
                say("INFO: $who_am_i The server with process [" . $self->serverpid .
                    "] is already no more running. Will return STATUS_OK.") if not $silent;
                # IMPORTANT:
                # Do NOT return from here because this will break the scenario of the reporter
                # Crashrecovery.
                # In monitor: SIGKILL server_pid, no waiting, just exit
                # In report: Call killServer and wait by that in cleanup_dead_server till rr trace
                #            is complete written.
            } else {
                kill KILL => $self->serverpid;
                # There is no guarantee that the OS has already killed the process when
                # kill KILL returns. This is especially valid for boxes with currently
                # extreme CPU load.
                if ($self->waitForServerToStop($kill_timeout) != STATUS_OK) {
                    say("ERROR: $who_am_i Unable to kill the server process " . $self->serverpid);
                } else {
                    say("INFO: $who_am_i Killed the server process " . $self->serverpid);
                }
            }
        } else {
            say("INFO: $who_am_i Killing the server process impossible because " .
                "no server pid found.") if not defined $silent;
        }
    }
    my $return = $self->running($silent) ? STATUS_FAILURE : STATUS_OK;

    # Clean up when the server is not alive.
    $self->cleanup_dead_server;
    # Is the position after cleanup_dead ... ok?
    return $return;

} # End sub killServer

sub term {
    my ($self) = @_;

    my $res;

    if (not $self->running) {
        say("DEBUG: DBServer_e::MySQL::MySQLd::term: The server with process [" .
            $self->serverpid . "] is already no more running.");
        say("DEBUG: Omitting SIGTERM attempt, clean up and return STATUS_OK.");
        # clean up when server is not alive.
        $self->cleanup_dead_server;
        return STATUS_OK;
    }

    my $term_timeout = DEFAULT_TERM_TIMEOUT * Runtime::get_runtime_factor();

    # For experimenting
    # system("killall -6 mysqld mariadbd; sleep 10");

    if (osWindows()) {
        ### Not for windows
        say("Don't know how to do SIGTERM on Windows");
        $self->killServer;
        $res= STATUS_OK;
    } else {
        if (defined $self->serverpid) {
            kill TERM => $self->serverpid;

            if ($self->waitForServerToStop($term_timeout) != STATUS_OK) {
                say("WARNING: Unable to terminate the server process " . $self->serverpid .
                    ". Trying kill with core.");
                $self->crashServer;
                $self->make_backtrace;
                $res= STATUS_FAILURE;
             } else {
                say("INFO: Terminated the server process " . $self->serverpid);
                $res= STATUS_OK;
             }
        }
    }
    $self->cleanup_dead_server;

    return $res;
} # End sub term

sub crashServer {
# Note:
# In case a backtrace is needed than the caller of "crashServer" has to call "make_backtrace"
# afterwards.
    my ($self, $tolerant) = @_;

    my $who_am_i = Basics::who_am_i();

    my $abrt_timeout = DEFAULT_SERVER_ABRT_TIMEOUT * Runtime::get_runtime_factor();

    if (osWindows()) {
        ## How do i do this?????
        $self->killServer; ## Temporary
        $self->[MYSQLD_WINDOWS_PROCESS] = undef;
    } else {
        if (not defined $self->serverpid) {
            # $self->[MYSQLD_SERVERPID] = $self->get_pid_from_pid_file;
            $self->[MYSQLD_SERVERPID] = Auxiliary::get_pid_from_file($self->pidfile);
            if (defined $self->serverpid) {
                say("WARN: $who_am_i serverpid had to be extracted from pidfile.");
            }
        }
        if (defined $self->serverpid) {
            if (not $self->running) {
                say("INFO: $who_am_i The server with process [" . $self->serverpid .
                    "] is already no more running. Will return STATUS_OK.");
                $self->cleanup_dead_server;
                # FIXME: What to return if the server is already no more running.
                return STATUS_OK;
            }
            # Use ABRT in order to be able to distinct from genuine SEGV's.
            kill 'ABRT' => $self->serverpid;
            say("INFO: $who_am_i Crashed the server process " . $self->serverpid . " with ABRT.");
            # Notebook, low load, one RQG, tmpfs:
            # SIGABRT ~ 4s till rr has finished and the auxiliary process is reaped.
            # SIGKILL ~ 1s till rr has finished and the auxiliary process is reaped.
            if ($self->waitForServerToStop($abrt_timeout) != STATUS_OK) {
                say("ERROR: $who_am_i Crashing the server with core failed. Trying kill. " .
                    "Will return STATUS_FAILURE.");
                Auxiliary::print_ps_tree($$);
                $self->killServer;
                return STATUS_FAILURE;
            } else {
                $self->cleanup_dead_server;
                return STATUS_OK;
            }
        } else {
            $self->cleanup_dead_server;
            if (not defined $tolerant) {
                Carp::cluck("WARN: $who_am_i Crashing the server process impossible because " .
                           "no server pid found.");
                return STATUS_FAILURE;
            } else {
                say("INFO: $who_am_i Crashing the server process impossible because " .
                    "no server pid found.");
                return STATUS_OK;
            }
        }
    }

}

sub corefile {
   my ($self) = @_;

   ## Unix variant
   # FIXME: This is weak. There are boxes where we get 'core' without pid only.
   if (not defined $self->datadir) {
      Carp::cluck("ERROR: self->datadir is not defined.");
   }
   if (not defined $self->serverpid) {
      Carp::cluck("ERROR: self->serverpid is not defined.");
   }
   return $self->datadir."/core.".$self->serverpid;
}

sub upgradeDb {
    my $self= shift;

    my $mysql_upgrade= $self->_find([$self->basedir],
        osWindows()?["client/Debug","client/RelWithDebInfo","client/Release","bin"]:["client","bin"],
        osWindows()?"mysql_upgrade.exe":"mysql_upgrade");
    my $upgrade_command=
        '"' . $mysql_upgrade . '" --host=127.0.0.1 --port=' . $self->port . ' -uroot';
    my $upgrade_log= $self->datadir . '/mysql_upgrade.log';
    say("Running mysql_upgrade:\n  $upgrade_command");
    my $status = STATUS_OK;
    # Experiment begin
    # my $status = system("$upgrade_command > $upgrade_log");
    system("$upgrade_command > $upgrade_log");
    my $rc = $?;
    if ($rc == -1) {
        say("WARNING: upgrade_command failed to execute: $!");
        $status = STATUS_FAILURE;
    } elsif ($rc & 127) {
        say("WARNING: upgrade_command died with signal " . ($rc & 127));
        $status = STATUS_FAILURE;
    } elsif (($rc >> 8) != 0) {
        say("WARNING: upgrade_command exited with value " . ($rc >> 8));
        $status = STATUS_FAILURE;
        return STATUS_INTERNAL_ERROR;
    } else {
        say("DEBUG: upgrade_command exited with value " . ($rc >> 8));
        $status = STATUS_OK;
    }

    if ($status  == STATUS_OK) {
        # mysql_upgrade can return exit code 0 even if user tables are corrupt,
        # so we don't trust the exit code, we should also check the actual output
        if (open(UPGRADE_LOG, "$upgrade_log")) {
           OUTER_READ:
            while (<UPGRADE_LOG>) {
            # For now we will only check 'Repairing tables' section,
            # and if there are any errors, we'll consider it a failure
                next unless /Repairing tables/;
                while (<UPGRADE_LOG>) {
                    if (/^\s*Error/) {
                        $status = STATUS_FAILURE;
                        sayError("Found errors in mysql_upgrade output");
                        sayFile("$upgrade_log");
                        last OUTER_READ;
                    }
                }
            }
            close (UPGRADE_LOG);
        } else {
            sayError("Could not find $upgrade_log");
            $status = STATUS_FAILURE;
        }
    }
    return $status ;
}

sub dumper {
    return $_[0]->[MYSQLD_DUMPER];
}

sub dumpdb {
    my ($self,$database, $file) = @_;
    say("Dumping MySQL server ".$self->version." data on port ".$self->port);
    my $dump_command = '"'.$self->dumper.
                             "\" --hex-blob --skip-triggers --compact ".
                             "--order-by-primary --skip-extended-insert ".
                             "--no-create-info --host=127.0.0.1 ".
                             "--port=".$self->port.
                             " -uroot $database";
    # --no-tablespaces option was introduced in version 5.1.14.
    if ($self->_notOlderThan(5,1,14)) {
        $dump_command = $dump_command . " --no-tablespaces";
    }
    my $dump_result = system("$dump_command | sort > $file");
    return $dump_result;
}

sub dumpSchema {
    my ($self,$database, $file) = @_;
    say("Dumping server ".$self->version." schema on port ".$self->port);
    my $dump_command = '"'.$self->dumper.
                             "\" --hex-blob --compact ".
                             "--order-by-primary --skip-extended-insert ".
                             "--no-data --host=127.0.0.1 ".
                             "--port=".$self->port.
                             " -uroot $database";
    # --no-tablespaces option was introduced in version 5.1.14.
    if ($self->_notOlderThan(5,1,14)) {
        $dump_command = $dump_command . " --no-tablespaces";
    }
    my $dump_result = system("$dump_command > $file");
    return $dump_result;
}

sub dumpSomething {
    my ($self, $options, $file_prefix) = @_;
    say("Dumping MySQL server " . $self->version . " content on port " . $self->port);
    my $dump_command = '"' . $self->dumper . "\" --host=127.0.0.1 --port=" . $self->port .
                             " --user=root $options";
    say("DEBUG: dump_command ->" . $dump_command . "<-");
    my $dump_file =   $file_prefix . ".dump";
    my $err_file =    $file_prefix . ".err";
    my $dump_result = system("$dump_command > $dump_file 2>$err_file");
    if ($dump_result > 0) {
        say("ERROR: dump_command ->" . $dump_command . "<- failed.");
        sayFile($err_file);
    }
    # Command line
    # 1. mysqldump without options -> help text
    #    RC=1
    # 2. mysqldump with wrong option -> Lament about connect failing text
    #    mysqldump: Got error: 2002: "Can't connect .... socket '/tmp/mysql.sock' (2)"
    #    RC=2
    return $dump_result;
}



# There are some known expected differences in dump structure between
# pre-10.2 and 10.2+ versions.
# We need to normalize the dumps to avoid false positives while comparing them.
# For now, we'll re-format to 10.1 style.
# Optionally, we can also remove AUTOINCREMENT=N clauses.
# The old file is stored in <filename_orig>.
sub normalizeDump {
  my ($self, $file, $remove_autoincs)= @_;
  if ($remove_autoincs) {
    say("normalizeDump removes AUTO_INCREMENT clauses from table definitions");
    move($file, $file.'.tmp1');
    open(DUMP1,$file.'.tmp1');
    open(DUMP2,">$file");
    while (<DUMP1>) {
      if (s/AUTO_INCREMENT=\d+//) {};
      print DUMP2 $_;
    }
    close(DUMP1);
    close(DUMP2);
  }
  if ($self->versionNumeric() ge '100201') {
    say("normalizeDump patches DEFAULT clauses for version ".$self->versionNumeric);
    move($file, $file.'.tmp2');
    open(DUMP1,$file.'.tmp2');
    open(DUMP2,">$file");
    while (<DUMP1>) {
      # In 10.2 blobs can have a default clause
      # `col_blob` blob NOT NULL DEFAULT ... => `col_blob` blob NOT NULL.
      s/(\s+(?:blob|text|mediumblob|mediumtext|longblob|longtext|tinyblob|tinytext)(?:\s*NOT\sNULL)?)\s*DEFAULT\s*(?:\d+|NULL|\'[^\']*\')\s*(.*)$/${1}${2}/;
      # `k` int(10) unsigned NOT NULL DEFAULT '0' => `k` int(10) unsigned NOT NULL DEFAULT 0
      s/(DEFAULT\s+)(\d+)(.*)$/${1}\'${2}\'${3}/;
      print DUMP2 $_;
    }
    close(DUMP1);
    close(DUMP2);
  }
  if (-e $file.'.tmp1') {
    move($file.'.tmp1',$file.'.orig');
#    unlink($file.'.tmp2') if -e $file.'.tmp2';
  } elsif (-e $file.'.tmp2') {
    move($file.'.tmp2',$file.'.orig');
  }
}

sub nonSystemDatabases {
  my $self= shift;
  return @{$self->dbh->selectcol_arrayref(
      "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA ".
      "WHERE LOWER(SCHEMA_NAME) NOT IN ('mysql','information_schema','performance_schema','sys')"
    )
  };
}

sub nonSystemDatabases1 {
    my $self= shift;
    my $who_am_i = "DBServer_e::MySQL::MySQLd::nonSystemDatabases1:";
    # The use of (combine with or)
    # a) my $dbh          = $self->dbh
    # b) my $col_arrayref = $self->dbh->selectcol_arrayref(....)
    # causes that it is tried to get some proper connection to the server via "sub dbh".
    # In case that fails than
    # a) (harmless) $dbh is undef and we are able to check that.
    # b) the current process aborts with the perl error
    #    Can't call method "selectcol_arrayref" on an undefined value at ...
    #    which is fatal because we are no more able to bring the servers down.
    # Hence the solution is to use <connection_handle>->selectcol_arrayref(....).
    my $dbh = $self->dbh;
    if (not defined $dbh) {
        say("ERROR: $who_am_i No connection to Server got. Will return undef.");
        return undef;
    } else {
        # Unify somehow like picking code from lib/GenTest_e/Executor/MySQL.pm.
        # For testing:
        # KILL leads to    $col_arrayref is undef, $dbh->err() is defined.
        # system("killall -9 mysqld; killall -9 mariadbd");
        my $col_arrayref = $dbh->selectcol_arrayref(
            "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA " .
            "WHERE LOWER(SCHEMA_NAME) NOT IN " .
            "    ('rqg','mysql','information_schema','performance_schema','sys') " .
            "ORDER BY SCHEMA_NAME");
        my $error = $dbh->err();
        if (defined $error) {
            say("ERROR: $who_am_i Query failed with $error. Will return undef.");
            return undef;
        }
        my @schema_list = @{$col_arrayref};
        return \@schema_list;
    }
}

sub collectAutoincrements {
  my $self= shift;
    my $autoinc_tables= $self->dbh->selectall_arrayref(
      "SELECT CONCAT(ist.TABLE_SCHEMA,'.',ist.TABLE_NAME), ist.AUTO_INCREMENT, isc.COLUMN_NAME, '' ".
      "FROM INFORMATION_SCHEMA.TABLES ist JOIN INFORMATION_SCHEMA.COLUMNS isc " .
      "ON (ist.TABLE_SCHEMA = isc.TABLE_SCHEMA AND ist.TABLE_NAME = isc.TABLE_NAME) ".
      "WHERE ist.TABLE_SCHEMA NOT IN ('rqg','mysql','information_schema','performance_schema','sys') ".
      "AND ist.AUTO_INCREMENT IS NOT NULL ".
      "AND isc.EXTRA LIKE '%auto_increment%' ".
      "ORDER BY ist.TABLE_SCHEMA, ist.TABLE_NAME, isc.COLUMN_NAME"
    );
  foreach my $t (@$autoinc_tables) {
      $t->[3] = $self->dbh->selectrow_arrayref("SELECT IFNULL(MAX($t->[2]),0) FROM $t->[0]")->[0];
  }
  return $autoinc_tables;
}

sub binary {
    return $_[0]->[MYSQLD_MYSQLD];
}

sub stopServer {
    my ($self, $shutdown_timeout) = @_;

    my $who_am_i =    Basics::who_am_i();
    my $server_id =   $self->server_id();
    my $server_name = "server[$server_id]";
    $who_am_i .=      " $server_name:";

    my $innodb_fast_shutdown_factor = 1; # For innodb_fast_shutdown = 1 (default)
    $innodb_fast_shutdown_factor = 4 if 0 == $self->serverVariable('innodb_fast_shutdown');

    $shutdown_timeout =  DEFAULT_SHUTDOWN_TIMEOUT unless defined $shutdown_timeout;
    $shutdown_timeout =  $shutdown_timeout * Runtime::get_runtime_factor()
                         * $innodb_fast_shutdown_factor;
    say("DEBUG: $who_am_i Effective shutdown_timeout: $shutdown_timeout" . "s.");
    my $errorlog =       $self->errorlog;
    my $check_shutdown = 0;
    my $res;

    if (not $self->running) {
        my $message_part = $self->serverpid;
        $message_part =    '<never known or now already unknown pid>' if not defined $message_part;
        say("DEBUG: $who_am_i with process [" . $message_part . "] is already no more running.");
        $self->make_backtrace;
        say("DEBUG: $who_am_i Omitting shutdown attempt. Will clean up and return STATUS_OK.");
        $self->cleanup_dead_server;
        return STATUS_SERVER_CRASHED;
    }

    # Get the actual size of the server error log.
    my $file_to_read     = $errorlog;
    my @filestats        = stat($file_to_read);
    my $file_size_before = $filestats[7];
    # say("DEBUG: $who_am_i Server error log '$errorlog' size before shutdown attempt : " .
    #     "$file_size_before");
    # system("ps -elf | grep mysqld");

    # For experimenting: Simulate a server crash during shutdown
    # system("killall -11 mysqld mariadbd; sleep 10");

    if ($shutdown_timeout and defined $self->[MYSQLD_DBH]) {
        say("INFO: $who_am_i Stopping server on port " . $self->port);
        ## Use dbh routine to ensure reconnect in case connection is
        ## stale (happens i.e. with mdl_stability/valgrind runs)
        my $dbh = $self->dbh();
        # Need to check if $dbh is defined, in case the server has crashed
        if (defined $dbh) {
            my $start_time = time();
            $res = $dbh->func('shutdown','127.0.0.1','root','admin');
            if (!$res) {
                ## If shutdown fails, we want to know why:
                say("ERROR: $who_am_i Shutdown failed due to " . $dbh->err . ": " . $dbh->errstr);
                $res = STATUS_FAILURE;
            } else {
                # FIXME:
                # waitForServerToStop could return STATUS_INTERNAL_ERROR
                # But return STATUS_INTERNAL_ERROR from here would probably not take care
                # that the DB Server gets stopped.
                if ($self->waitForServerToStop($shutdown_timeout) != STATUS_OK) {
                    # The server process has not disappeared.
                    # So try to terminate that process.
                    say("ERROR: $who_am_i Did not shut down properly. Terminate it");
                    sayFile($errorlog);
                    $res = $self->term;
                    # If SIGTERM does not work properly then SIGKILL is used.
                    if ($res == STATUS_OK) {
                        $check_shutdown = 1;
                    }
                } else {
                    say("INFO: $who_am_i Time for shutting down server on port " . $self->port .
                        " in s : " . (time() - $start_time));
                    $check_shutdown = 1;
                    # Observation 2020-12
                    # 18:26:31 [528945] Stopping server(s)...
                    # 18:26:31 [528945] Stopping server on port 25680
                    #                   == RQG has told what he wants to do
                    # 18:26:49 [528945] WARN: Auxpid 530419 exited with exit status 139.
                    #                   == Disappearing Auxpid was observed
                    # 18:26:49 [528945] INFO: Time for shutting down the server on port 25680 in s : 18
                    #                   == return of waitForServerToStops was STATUS_OK
                    # 18:26:49 [528945] Server has been stopped
                    # 18:26:49 [528945] WARN: No regular shutdown achieved. Will return 1 later.
                    # Server error log
                    # 2020-12-13 18:24:36 19 [Note] InnoDB: Deferring DROP TABLE `test`.`FTS_000000000000101e_CONFIG`; renaming to test/#sql-ib4129
                    # 2020-12-13 18:26:31 0 [Note] /Server_bin/bb-10.6-MDEV-21452A_asan_Og/bin/mysqld (initiated by: root[root] @ localhost [127.0.0.1]): Normal shutdown
                    # 2020-12-13 18:26:31 0 [Note] Event Scheduler: Purging the queue. 0 events
                    # 2020-12-13 18:26:33 0 [Note] InnoDB: FTS optimize thread exiting.
                    # 201213 18:26:33 [ERROR] mysqld got signal 11 ;

                    # cleanup_dead_server waits till the auxpid/forkpid is gone.
                    # Even if that fails a cleanup is made and corresponding status is returned.
                    # But that status is not useful here.
                    $self->cleanup_dead_server;
                    $res = STATUS_OK;
                    say("$server_name has been stopped");
                }
            }
        } else {
            # Lets stick to a warning because the state met might be intentional.
            say("WARN: $who_am_i dbh is not defined.");
            $res= $self->term;
            # If SIGTERM does not work properly then SIGKILL is used.
            # The operations ends with setting the pid to undef and removing the pidfile!
            if ($res == STATUS_OK) {
                $check_shutdown = 1;
            }
        }
    } else {
        say("INFO: $who_am_i Shutdown timeout or dbh is not defined, killing the server.");
        $res= $self->killServer;
        # killServer itself runs a waitForServerToStop
    }

    if ($check_shutdown) {
        my @filestats = stat($file_to_read);
        my $file_size_after = $filestats[7];
        # say("DEBUG: Server error log '$errorlog' size after shutdown attempt : $file_size_after");
        if ($file_size_after == $file_size_before) {
            my $offset = 10000;
            say("INFO: $who_am_i The shutdown attempt has not changed the size of " .
                "'$file_to_read'. Therefore looking into the last $offset Bytes.");
            $file_size_before = $file_size_before - $offset;
        }
        # Some server having trouble around shutdown will not have within his error log a last line
        # <Timestamp> 0 [Note] /home/mleich/Server/10.4/bld_debug//sql/mysqld: Shutdown complete
        my $file_handle;
        if (not open ($file_handle, '<', $file_to_read)) {
            $res = STATUS_FAILURE;
            say("ERROR: $who_am_i Open '$file_to_read' failed : $!. Will return $res.");
            return $res;
        }
        my $content_slice;
        seek($file_handle, $file_size_before, 1);
        read($file_handle, $content_slice, 100000);
        # say("DEBUG: $who_am_i Written by shutdown attempt ->" . $content_slice . "<-");
        close ($file_handle);
        my $match   = 0;
        my $pattern = 'mysqld: Shutdown complete';
        $match = $content_slice =~ m{$pattern}s;
        if (not $match) {
            $res = STATUS_FAILURE;
            # Typical text in server error log in case   shutdown/term  fails with crash
            # --------------------------------------------------------------------------
            # <TimeStamp> [ERROR] mysqld got signal <SignalNumber> ;
            # This could be because you hit a bug. It is also possible that this binary
            # ...
            # Thread pointer: ...
            # Attempting backtrace. You can use the following information to find out
            # ...
            # Segmentation fault (core dumped)          if SIGSEGV hit
            #                                           or
            # Aborted (core dumped)                     if Assert hit
            #
            # In case of SIGKILL (might be issued by rqg_batch.pl ingredients or the user)
            # we get only a line
            # Killed
            say("WARN: $who_am_i No regular shutdown achieved. Will return $res later.");
            $pattern = '\[ERROR\] mysqld got signal ';
            $match =   $content_slice =~ m{$pattern}s;
            if ($match) {
                say("INFO: $who_am_i The shutdown finished with server crash.");
                $self->make_backtrace;
            } else {
                sayFile($file_to_read);
            }
        }
    }
    return $res;
} # End of sub stopServer

sub checkDatabaseIntegrity {
# Code uses GenTest_e::Executor.
    my $self = shift;

    my $who_am_i =      Basics::who_am_i();
    my $server_id =     $self->server_id();
    my $server_name =   "server[" . $server_id . "]";
    $who_am_i .=        " $server_name: ";
    my $status =        STATUS_OK;
    my $err;

    my $dsn =      $self->dsn();
    my $executor = GenTest_e::Executor->newFromDSN($dsn);
    $executor->setId($server_id);
    $executor->setRole("checkDatabaseIntegrity");
    # EXECUTOR_TASK_REPORTER ensures that max_statement_time is set to 0 for the current executor.
    # But this is not valid for the connection established by mysqldump!
    $executor->setTask(GenTest_e::Executor::EXECUTOR_TASK_UNKNOWN);
    $status = $executor->init();
    return $status if $status != STATUS_OK;

    # For debugging
    # $self->killServer;
    # SELECT 'test' WHERE 1 IS NULL --> not undef
    # GARBAGE                       --> undef and 1064
    my $aux_query =     "SHOW DATABASES";
    my $res_databases = $executor->execute($aux_query);
    $status = $res_databases->status;
    if (STATUS_OK != $status) {
        $executor->disconnect();
        my $err    = $res_databases->err;
        my $errstr = $res_databases->errstr;
        my $status = STATUS_CRITICAL_FAILURE;
        say("ERROR: $who_am_i Query ->" . $aux_query . "<- failed with $err : $errstr " .
            Auxiliary::build_wrs($status));
        return $status;
    }

    if (0) {
        # Generate some damaged view so that CHECK TABLE reports an error.
        # Do not forget to uncomment the 'next if "VIEW" eq $table_type;' some lines later.
        say("WARN: $who_am_i CREATE a table and a dangling view");
        $executor->execute("CREATE TABLE test.extra_t2 (col1 INT, UNIQUE(KEY ");
        $executor->execute("CREATE TABLE test.extra_t1 (col1 INT)");
        $executor->execute("CREATE VIEW test.extra_v1 AS SELECT * FROM test.extra_t1");
        $executor->execute("DROP TABLE test.extra_t1");
    }

    my $key_ref = $res_databases->data;
    foreach my $val (@$key_ref) {
        my $database = $val->[0];
        # say("DEBUG: database ->" . $database . "<-");
        next if $database =~ m{^(rqg|mysql|information_schema|pbxt|performance_schema)$}sio;
        $aux_query = "USE $database";
        my $res_use = $executor->execute($aux_query);
        $status = $res_use->status;
        if (STATUS_OK != $status) {
            $executor->disconnect();
            $err = $res_use->err;
            say("ERROR: $who_am_i '$aux_query' failed, error: $err");
            return $status;
        }
        $aux_query = "SHOW FULL TABLES";
        my $res_tables = $executor->execute($aux_query);
        $status = $res_tables->status;
        if (STATUS_OK != $status) {
            $executor->disconnect();
            my $err    = $res_tables->err;
            my $errstr = $res_tables->errstr;
            say("ERROR: $who_am_i Query ->" . $aux_query . "<- failed with $err : $errstr " .
                Auxiliary::build_wrs($status));
            return $status;
        }
        my $key_ref1 = $res_tables->data;
        # Tables_in_test  Table_type
        # t2      BASE TABLE
        # v1      VIEW
        foreach my $val1 (@$key_ref1) {
            my $table =      $val1->[0];
            my $table_type = $val1->[1];
            # say("DEBUG: table ->" . $table . "<- table_type ->" . $table_type . "<-");
            next if "VIEW" eq $table_type;
            $aux_query = "CHECK TABLE `$database`.`$table` EXTENDED";
            my $res_check = $executor->execute($aux_query);
            $status = $res_check->status; # Might be STATUS_DATABASE_CORRUPTION
            if (STATUS_OK != $status) {
                my $err    = $res_check->err;
                $err = "<undef>" if not defined $err;
                my $errstr = $res_check->errstr;
                $errstr = "<undef>" if not defined $errstr;
                if (STATUS_SKIP == $status) {
                    say("INFO: $who_am_i Query ->" . $aux_query . "<- failed with $err : $errstr");
                } else {
                    $executor->disconnect();
                    say("ERROR: $who_am_i Query ->" . $aux_query . "<- failed with $err : $errstr " .
                        Auxiliary::build_wrs($status));
                    return $status;
                }
            } else {
                say("INFO: $who_am_i $aux_query : pass");
                # No reason to analyse the result because that was already done by MySQL.pm and
                # we received some corresponding status.
            }
        }
    }
    return $status;
} # End of sub checkDatabaseIntegrity

sub addErrorLogMarker {
   my $self   = shift;
   my $marker = shift;

   # FIXME:
   # 1. Handle that adding the marker fails (file does not exist, write fails).
   # 2. Could the impact of that operation get lost because of concurrent server write?
   # 3. Return something showing success/fail + What should the caller do?
   say("Adding marker '$marker' to the error log " . $self->errorlog);
   if (open(ERRLOG, ">>" . $self->errorlog)) {
      print ERRLOG "$marker\n";
      close (ERRLOG);
   } else {
      say("WARNING: Could not add marker $marker to the error log " . $self->errorlog);
   }
}

sub waitForServerToStop {
# We return either STATUS_OK(0) or STATUS_FAILURE(1);
# 2021-12 Only routines located here (lib/DBServer_e/MySQL/MySQLd.pm) call waitForServerToStop.
    my $self      = shift;
    my $timeout   = shift;   # The caller has already multiplied if using rr or valgrind.
    my $who_am_i = Basics::who_am_i;
    if (not defined $timeout) {
        Carp::cluck("INTERNAL ERROR: $who_am_i \$timeout is undef.");
        return STATUS_INTERNAL_ERROR;
    }
    my $wait_start = Time::HiRes::time() + $timeout;
    my $wait_end  =  $wait_start + $timeout;
    my $wait_unit =  0.3;
    while ($self->running && Time::HiRes::time() < $wait_end) {
        Time::HiRes::sleep($wait_unit);
    }

    # Give some grace period in case there seems to be activity in the DB server.
    # ---------------------------------------------------------------------------
    # Reasons:
    # The elapsed time for some shutdown/a DB server disappearing depends on
    # - how/why the server disappears
    #   shutdown/SIGTERM, SIGABRT, SIGSEGV, SIGKILL
    # - the setting of innodb_fast_shutdown und if 'rr' or 'valgrind' is invoked
    #   We already multiplied $timeout with factors for compensation.
    # - the hardware and the parallel load on the box
    #   There will be frequent extreme load on the box.
    # - The DB Server setup and the test.
    # Observed on shutdown via pstree for the main server process:
    #    n'th call  child processes/threads <A>, <B>
    #    (n + 1)'th call  child processes/threads <A>, <C>, <D>
    #               == Childprocesses/threads exit but new ones can show up
    if ($self->running) {
        say("INFO: $who_am_i Being forced to give a grace period.");
        $wait_end  =        Time::HiRes::time() + 60 * Runtime::get_runtime_factor();
        my $old_ps_tree =   Auxiliary::get_ps_tree($self->pid);
        my $next_ps_check = Time::HiRes::time() + 3;
        while ($self->running && Time::HiRes::time() < $wait_end) {
            if (Time::HiRes::time() > $next_ps_check) {
                my $new_ps_tree = Auxiliary::get_ps_tree($self->pid);
                if ($new_ps_tree eq $old_ps_tree) {
                    say("DEBUG: $who_am_i \$new_ps_tree == \$old_ps_tree == '$new_ps_tree'." .
                        "Aborting the grace period.");
                    last;
                } else {
                    say("DEBUG: $who_am_i Current ps_tree: '$new_ps_tree'.");
                    $next_ps_check = Time::HiRes::time() + 3;
                    $new_ps_tree =   $old_ps_tree;
                }
            }
            Time::HiRes::sleep($wait_unit);
        }
    }
    if ($self->running) {
        say("ERROR: The server process has not disappeared after " . (time() - $wait_start) .
            "s waiting. Will return STATUS_FAILURE later.");
        Auxiliary::print_ps_tree($$);
        return STATUS_FAILURE;
    } else {
        return STATUS_OK;
    }
}

# Currently unused
sub waitForServerToStart {
# We return either STATUS_OK(0) or STATUS_FAILURE(1);
   my $self      = shift;
   my $timeout   = 180;
   my $wait_end  = Time::HiRes::time() + $timeout * Runtime::get_runtime_factor();
   my $wait_unit = 0.5;
   while (!$self->running && Time::HiRes::time() < $wait_end) {
      Time::HiRes::sleep($wait_unit);
   }
   if (not $self->running) {
      say("ERROR: The server process has not come up after " . $timeout . "s waiting.\n" .
          " Will return STATUS_FAILURE.");
      return STATUS_FAILURE;
   } else {
      return STATUS_OK;
   }
}


sub backupDatadir {
  my $self= shift;
  my $backup_name= shift;

  say("Copying datadir... (interrupting the copy operation may cause investigation problems later)");
  if (osWindows()) {
      system('xcopy "'.$self->datadir.'" "'.$backup_name.' /E /I /Q');
  } else {
      system('cp -r '.$self->datadir.' '.$backup_name);
  }
}

# Extract important messages from the error log.
# The check starts from the provided marker or from the beginning of the log

sub checkErrorLogForErrors {
  my ($self, $marker)= @_;

  my @crashes= ();
  my @errors= ();

  open(ERRLOG, $self->errorlog);
  my $found_marker= 0;

  say("Checking server log for important errors starting from " . ($marker ? "marker $marker" : 'the beginning'));

  my $count= 0;
  while (<ERRLOG>)
  {
    next unless !$marker or $found_marker or /^$marker$/;
    $found_marker= 1;
    $_ =~ s{[\r\n]}{}siog;

    # Ignore certain errors
    next if
         $_ =~ /innodb_table_stats/so
      or $_ =~ /InnoDB: Cannot save table statistics for table/so
      or $_ =~ /InnoDB: Deleting persistent statistics for table/so
      or $_ =~ /InnoDB: Unable to rename statistics from/so
      or $_ =~ /ib_buffer_pool' for reading: No such file or directory/so
    ;

    # Crashes
    if (
           $_ =~ /Assertion\W/sio
        or $_ =~ /got signal/sio
        or $_ =~ /segmentation fault/sio
        or $_ =~ /segfault/sio
        or $_ =~ /exception/sio
    ) {
      say("------") unless $count++;
      say($_);
      push @crashes, $_;
    }
    # Other errors
    elsif (
           $_ =~ /\[ERROR\]\s+InnoDB/sio
        or $_ =~ /InnoDB:\s+Error:/sio
        or $_ =~ /registration as a STORAGE ENGINE failed./sio
    ) {
      say("------") unless $count++;
      say($_);
      push @errors, $_;
    }
  }
  say("------") if $count;
  close(ERRLOG);
  return (\@crashes, \@errors);
}

sub serverVariables {
    my $self = shift;
    if (not keys %{$self->[MYSQLD_SERVER_VARIABLES]}) {
       my $dbh = $self->dbh;
       return undef if not defined $dbh;
       my $sth = $dbh->prepare("SHOW VARIABLES");
       $sth->execute();
       # FIXME maybe:
       # This execute can fail.
       my %vars = ();
       while (my $array_ref = $sth->fetchrow_arrayref()) {
          $vars{$array_ref->[0]} = $array_ref->[1];
       }
       $sth->finish();
       $self->[MYSQLD_SERVER_VARIABLES] = \%vars;
       $dbh->disconnect();
    }
    return $self->[MYSQLD_SERVER_VARIABLES];
}

sub serverVariable {
    my ($self, $var) = @_;
    return $self->serverVariables()->{$var};
}

sub serverVariablesDump {
    my $self = shift;
    my $pvar = $self->serverVariables;
    if (not defined $pvar) {
        say("WARNING: No connection to server got or SHOW VARIABLES failed.");
    } else {
        my %vars = %{$pvar};
        foreach my $variable (sort keys %vars) {
            say ("SVAR: $variable : " . $vars{$variable});
        }
    }
    my $dbh = $self->dbh;
    # FIXME: This is a too weak reaction.
    return undef if not defined $dbh;
    my $stmt = "SELECT PLUGIN_NAME, PLUGIN_LIBRARY FROM INFORMATION_SCHEMA.PLUGINS\n" .
               "WHERE PLUGIN_LIBRARY IS NOT NULL ORDER BY PLUGIN_NAME";
    my $sth = $dbh->prepare($stmt);
    $sth->execute();
    # FIXME maybe:
    # This execute can fail.
    my %result = ();
    while (my $array_ref = $sth->fetchrow_arrayref()) {
       $result{$array_ref->[0]} = $array_ref->[1];
    }
    $sth->finish();
    my $result_print;
    foreach my $plugin_name (keys %result) {
        say ("SPLUG: $plugin_name : " . $result{$plugin_name});
    }
    $dbh->disconnect();
}

sub running {
# 1. Check if the server process is running and return
#    0 - Process does not exist
#    1 - Process is running
# 2. In case
#      $self->serverpid is undef or wrong
#      + the server process could be figured out by inspecting $self->pidfile
#      + that server process is running
#    than correct $self->[MYSQLD_SERVERPID] and return 1.
#    Otherwise return 0.
#    Background for that solution is the following frequent seen evil scenario
#        The current process is the RQG runner (parent) just executing lib/GenTest_e/App/GenTest_e.pm.
#        The periodic reporter process (child) has stopped and than restarted the server.
#        Hence the current process knows only some no more valid server pid.
#        And that might cause that lib/GenTest_e/App/GenTest_e.pm is later unable to stop a server.
#
    my $who_am_i = Basics::who_am_i();
    my ($self, $silent) = @_;
    if (osWindows()) {
        ## Need better solution for windows. This is actually the old
        ## non-working solution for unix....
        # The weak assumption is:
        # In case the pidfile exists than the server is running.
        return -f $self->pidfile;
    }

    my $pid = $self->serverpid;
    if (not defined $pid) {
        # $pid = $self->get_pid_from_pid_file;
        $pid = Auxiliary::get_pid_from_file($self->pidfile, $silent);
        if (defined $pid) {
            say("WARN: $who_am_i serverpid had to be extracted from pidfile.");
            $self->[MYSQLD_SERVERPID] = $pid;
        } else {
            say("ALARM: $who_am_i No valid value for pid found in pidfile. " .
                "Will return 0 == not running.") if not defined $silent;
            return 0;
        }
    }
    my $return = kill(0, $self->serverpid);
    if (not defined $return) {
        say("WARN: $who_am_i kill 0 serverpid " . $self->serverpid . " returned undef. " .
            "Will return 0");
        return 0;
    } else {
        return $return;
    }
}

sub _find {
   my($self, $bases, $subdir, @names) = @_;

   foreach my $base (@$bases) {
      foreach my $s (@$subdir) {
         foreach my $n (@names) {
            my $path  = $base . "/" . $s . "/" . $n;
            return $path if -f $path;
         }
      }
   }
   my $paths = "";
   foreach my $base (@$bases) {
      $paths .= join(",", map {"'" . $base . "/" . $_ ."'"} @$subdir) . ",";
   }
   my $names = join(" or ", @names );
   # FIXME: Replace what follows maybe with
   # 1. Carp::cluck(.....)
   # 2. return undef
   # 3. The caller should make a regular abort if undef was returned.
   # At least it must be prevented that the RQG runner aborts without stopping any
   # running servers + cleanup.
   Carp::confess("ERROR: Cannot find '$names' in $paths");
}

sub dsn {
   my ($self,$database) = @_;
   $database = MYSQLD_DEFAULT_DATABASE if not defined $database;

   return "dbi:mysql:host=127.0.0.1:port=" . $self->[MYSQLD_PORT] .
          ":user=" . $self->[MYSQLD_USER]                         .
          ":database=" . $database                                .
          ":mysql_local_infile=1";
}

sub dbh {
   my ($self) = @_;
   if (defined $self->[MYSQLD_DBH]) {
      if (!$self->[MYSQLD_DBH]->ping) {
         say("Stale connection to " . $self->[MYSQLD_PORT] . ". Reconnecting");
         $self->[MYSQLD_DBH] = DBI->connect(
                                    $self->dsn("mysql"),
                                    undef,
                                    undef,
                                    { PrintError            => 0,
                                      RaiseError            => 0,
                                      AutoCommit            => 1,
                                      mysql_connect_timeout => Runtime::get_connect_timeout(),
                                      mysql_auto_reconnect  => 1});
      }
   } else {
      say("Connecting to " . $self->[MYSQLD_PORT]);
      $self->[MYSQLD_DBH] = DBI->connect(
                                    $self->dsn("mysql"),
                                    undef,
                                    undef,
                                    { PrintError            => 0,
                                      RaiseError            => 0,
                                      AutoCommit            => 1,
                                      mysql_connect_timeout => Runtime::get_connect_timeout(),
                                      mysql_auto_reconnect  => 1});
   }
   if(!defined $self->[MYSQLD_DBH]) {
      say("ERROR: (Re)connect to " . $self->[MYSQLD_PORT] . " failed due to " .
               $DBI::err . ": " . $DBI::errstr);
   }
   return $self->[MYSQLD_DBH];
}

sub server_id {
    # A number > 0
    my ($self) = @_;
    # my $server_id = $self->vardir;
    # $server_id =~ s{.*/}{};
    # return $server_id;
    return $self->[MYSQLD_SERVER_ID];
}

sub _findDir {
    my($self, $bases, $subdir, $name) = @_;

    foreach my $base (@$bases) {
        foreach my $s (@$subdir) {
            my $path  = $base."/".$s."/".$name;
            return $base."/".$s if -f $path;
        }
    }
    my $paths = "";
    foreach my $base (@$bases) {
        $paths .= join(",",map {"'".$base."/".$_."'"} @$subdir).",";
    }
    croak "Cannot find '$name' in $paths";
}

# FIXME: I (mleich) have doubts if _absPath works perfect. Test it out.
sub _absPath {
    my ($self, $path) = @_;

    if (osWindows()) {
        return
            $path =~ m/^[A-Z]:[\/\\]/i;
    } else {
        return $path =~ m/^\//;
    }
}

sub version {
    my($self) = @_;

    if (not defined $self->[MYSQLD_VERSION]) {
        my $conf = $self->_find([$self->basedir],
                                ['scripts',
                                 'bin',
                                 'sbin'],
                                'mysql_config.pl', 'mysql_config');
        ## This will not work if there is no perl installation,
        ## but without perl, RQG won't work either :-)
        my $ver = `perl $conf --version`;
        chop($ver);
        $self->[MYSQLD_VERSION] = $ver;
    }
    return $self->[MYSQLD_VERSION];
}

sub majorVersion {
    my($self) = @_;

    if (not defined $self->[MYSQLD_MAJOR_VERSION]) {
        my $ver= $self->version;
        if ($ver =~ /(\d+\.\d+)/) {
            $self->[MYSQLD_MAJOR_VERSION]= $1;
        }
    }
    return $self->[MYSQLD_MAJOR_VERSION];
}

sub printInfo {
    my($self) = @_;

    say("Server version: "  . $self->version);
    say("Binary: "          . $self->binary);
    say("Type: "            . $self->serverType($self->binary));
    say("Datadir: "         . $self->datadir);
    say("Tmpdir: "          . $self->[MYSQLD_TMPDIR]);
    say("Corefile: "        . $self->corefile);
}

sub versionNumbers {
    my($self) = @_;

    $self->version =~ m/([0-9]+)\.([0-9]+)\.([0-9]+)/;

    return (int($1),int($2),int($3));
}

sub versionNumeric {
    my $self = shift;
    $self->version =~ /([0-9]+)\.([0-9]+)\.([0-9]+)/;
    return sprintf("%02d%02d%02d",int($1),int($2),int($3));
}

#############  Version specific stuff

sub _messages {
    my ($self) = @_;

    if ($self->_olderThan(5,5,0)) {
        return "--language=" . $self->[MYSQLD_MESSAGES] . "/english";
    } else {
        return "--lc-messages-dir=" . $self->[MYSQLD_MESSAGES];
    }
}

sub _logOptions {
    my ($self) = @_;

    if ($self->_olderThan(5,1,29)) {
        return ["--log=".$self->logfile];
    } else {
        if ($self->[MYSQLD_GENERAL_LOG]) {
            return ["--general-log", "--general-log-file=" . $self->logfile];
        } else {
            return ["--general-log-file=" . $self->logfile];
        }
    }
}

# For _olderThan and _notOlderThan we will match according to InnoDB versions
# 10.0 to 5.6
# 10.1 to 5.6
# 10.2 to 5.6
# 10.2 to 5.7

sub _olderThan {
    my ($self,$b1,$b2,$b3) = @_;

    my ($v1, $v2, $v3) = $self->versionNumbers;

    if    ($v1 == 10 and $b1 == 5 and ($v2 == 0 or $v2 == 1 or $v2 == 2)) { $v1 = 5; $v2 = 6 }
    elsif ($v1 == 10 and $b1 == 5 and $v2 == 3) { $v1 = 5; $v2 = 7 }
    elsif ($v1 == 5 and $b1 == 10 and ($b2 == 0 or $b2 == 1 or $b2 == 2)) { $b1 = 5; $b2 = 6 }
    elsif ($v1 == 5 and $b1 == 10 and $b2 == 3) { $b1 = 5; $b2 = 7 }

    my $b = $b1*1000 + $b2 * 100 + $b3;
    my $v = $v1*1000 + $v2 * 100 + $v3;

    return $v < $b;
}

sub _isMySQL {
    my $self = shift;
    my ($v1, $v2, $v3) = $self->versionNumbers;
    return ($v1 == 8 or $v1 == 5 and ($v2 == 6 or $v2 == 7));
}

sub _notOlderThan {
    return not _olderThan(@_);
}

sub stop_server_for_debug {
    my ($self, $sleep_before, $stop_signal, $what_to_kill, $sleep_after) = @_;
    my $who_am_i = "stop_server_for_debug:";
    my $check_command = "echo '#' `ls -ld " . $self->pidfile . "`";
    my $stop_command = "killall $stop_signal $what_to_kill";
    say("DEBUG: $who_am_i Experiment with '$stop_command' ================================= Begin");
    say("DEBUG: $who_am_i Waiting " . $sleep_before . "s.");
    sleep $sleep_before;
    # Example:
    # 30345 (perl rqg.pl in startServer parent)
    #     30415 (startServer child == AUXPID) sh -c ulimit -c 0; rr record --mark-stdio
    #         30416 rr record --mark-stdio
    #             30428 /home/mleich/Server_bin/10.5_asan_Og/bin/mysqld --no-defaults
    # Auxiliary::print_ps_tree($$);
    system($check_command);
    say("DEBUG: $who_am_i Before issuing '$stop_command'. ---------------------------------------");
    system($stop_command);
    say("DEBUG: $who_am_i After issuing '$stop_command' waiting " . $sleep_after . "s.");
    sleep $sleep_after;
    # Auxiliary::print_ps_tree($$);
    system($check_command);
    say("DEBUG: $who_am_i Experiment with '$stop_command' =================================== End");
}

sub cleanup_dead_server {
    my $self = shift;
    my $status = STATUS_OK;
    if (defined $self->forkpid) {
        $status = $self->waitForAuxpidGone();
    }
    # Even if waitForAuxpidGone failed the cleanup makes sense.
    unlink $self->socketfile if -e $self->socketfile;
    unlink $self->pidfile    if -e $self->pidfile;
    $self->[MYSQLD_WINDOWS_PROCESS] = undef;
    $self->[MYSQLD_SERVERPID]       = undef;
    return $status;
}


# FIXME: Maybe put the main code into some sub in Auxiliary.pm.
sub waitForAuxpidGone {
# Purpose:
# - Ensure that there is sufficient time for finishing writing core files and "rr" traces.
# - Ensure that we get informed by error messages about not disappearing processes etc.
#   rqg_batch.pl might finally fix the situation by killing the processgroup.
#   Even than we had some wasting of resources over some significant timespan.
#
    my $self =          shift;
    my $who_am_i =      Basics::who_am_i();
    my $wait_timeout =  DEFAULT_AUXPID_GONE_TIMEOUT;
    $wait_timeout =     $wait_timeout * Runtime::get_runtime_factor();
    my $wait_time =     0.5;
    my $start_time =    time();
    my $wait_end =      $start_time + $wait_timeout;
    # For debugging:
    # Auxiliary::print_ps_tree($self->forkpid);
    # Auxiliary::print_ps_tree($$);
    if (not defined $self->forkpid) {
        my $status = STATUS_FAILURE;
        say("INTERNAL ERROR: $who_am_i The auxiliary process is undef/unknown. " .
            "Will return status STATUS_FAILURE($status).");
        return $status;
    }
    # say("DEBUG: Start waiting for aux_pids gone.");
    while (1) {
        Time::HiRes::sleep($wait_time);
        my $pid = $self->forkpid;
        if (exists $aux_pids{$pid} and $$ == $aux_pids{$pid}) {
            # The current process is the parent of the auxiliary process.
            # I fear that the sigalarm in startServer is not sufficient for ensuring that
            # auxiliary processes get reaped. So lets do this here again.
            # Auxiliary::print_ps_tree($pid);
            # Returns of Auxiliary::reapChild
            # -------------------------------
            # $reaped -- 0 (not reaped) or 1 (reaped)
            # $status -- exit status of the process if reaped,
            #            otherwise STATUS_OK or STATUS_INTERNAL_ERROR
            #     0, STATUS_INTERNAL_ERROR -- most probably already reaped
            #                              == Defect in RQG logics
            #     0, STATUS_OK -- either just running or waitpid ... delivered undef
            #                     == Try to reap again after some short sleep.
            my ($reaped, $status) = Auxiliary::reapChild($pid,
                                                         "waitForAuxpidGone");
            my $msg_snip = "after " . (time() - $start_time) . "s waiting.";
            if (1 == $reaped) {
                delete $aux_pids{$pid};
                if (STATUS_OK == $status) {
                    say("DEBUG: $who_am_i The child process auxpid $pid exited with exit status " .
                        "STATUS_OK $msg_snip");
                } else {
                    say("WARN: $who_am_i The child process auxpid $pid exited with exit status " .
                        "$status $msg_snip");
                }
            }
            if (0 == $reaped and STATUS_OK != $status) {
                say("ERROR: $who_am_i The attempt to reap the child process auxpid $pid failed " .
                    "with status $status $msg_snip");
            }
        } else {
            # The current process is not the parent of $pid. Hence delete the entry.
            delete $aux_pids{$pid};
            # Maybe the auxiliary process has already finished and was reaped.
            if (not kill(0, $pid)) {
                my $status = STATUS_OK;
                # say("DEBUG: $who_am_i The non child process auxpid $pid is no more running." .
                #     " Will return status STATUS_OK" . "($status).");
                return $status;
            } else {
                # 1. It is not our child == reaping is done by other process.
                # 2. We need to loop around till the process is gone == the
                #    other process has reaped or we exceed the timeout.
                # This all means we have nothing to do in this branch.
            }
        }
        if (time() >= $wait_end) {
            # For debugging:
            # system("ps -elf | grep " . $pid);
            my $status = STATUS_FAILURE;
            say("ERROR: $who_am_i The auxiliary process has not disappeared within $wait_timeout" .
                "s waiting. Will send SIGKILL and return status STATUS_FAILURE($status) later.");
            kill KILL => $pid;
            # FIXME MAYBE:   Provisoric solution
            sleep 30;
            return $status if not exists $aux_pids{$pid};
            my $reaped;
            ($reaped, $status) = Auxiliary::reapChild($pid,
                                                      "waitForAuxpidGone");
            return $status;
        }
    }
}


sub make_backtrace {
# Important:
# ----------
# In case make_backtrace is called for some non crashing server than make_backtrace will
# crash the server and generate a backtrace from that.
# So in case this is unwanted than the caller needs to take care that its called in the
# right situation via
# a) check if the server process is gone
# b) inspect the server error log for [ERROR] mysqld got signal
# c) a connect attempt harvests 2013 or similar (Warning: This is less reliable.)
# d) have a situation where a SQL failed and some further running of the server is unwanted
#    Example: CHECK TABLE or similar reports corruption
#
# $status == The status from the make_backtrace point of view.
#            Starting point is STATUS_SERVER_CRASHED.
# == The caller needs to transform that to what he thinks like
#    STATUS_RECOVERY_FAILURE and similar.
#
# FIXME:
# Every piece in RQG wanting a backtrace should call the routine from here.
# IMHO it is rather questionable if the current Reporter Backtrace is needed in its current form.
# The reasons:
# The server could die intentional or non intentional
# - during bootstrap
# - during server start
# - during gendata -- GenTest_e initiates backtracing based on the reporter Backtrace
# - during gentest -- GenTest_e initiates backtracing based on the reporter Backtrace
# - during some reporter Reporter initiates a shutdown or TERM server
# - during stopping the servers smooth after GenTest_e failed
# - via SIGABRT/SIGSEGV/SIGKILL sent by some reporter
# Hint: Backtraces of mariabackup are also needed.
#

    my $self = shift;

    # my $server_running = kill (0, serverpid());
    my $who_am_i =  Basics::who_am_i;
    my $server_id = $self->server_id();
    $who_am_i .=    " server[" . $server_id . "] ";
    my $vardir =    $self->vardir();
    my $error_log = $self->errorlog();

    # my $server_pid  = $self->serverpid();

    my $status = STATUS_SERVER_CRASHED;
    # What is with    if (osWindows())
    if ($self->running) {
        say("DEBUG: $who_am_i The server with process [" .
            $self->serverpid . "] is not yet dead.");
        # DEFAULT_TERM_TIMEOUT might be a bit oversized.
        my $timeout = DEFAULT_TERM_TIMEOUT * Runtime::get_runtime_factor();
        if ($self->waitForServerToStop($timeout) != STATUS_OK) {
            say("ALARM: $who_am_i ########## The server process " . $self->serverpid .
                " is not dead. Trying kill with core. ##########");
            $self->crashServer;
            $status = STATUS_CRITICAL_FAILURE;
        } else {
            say("INFO: The server process " . $self->serverpid . " is no more running.");
            $status = STATUS_SERVER_CRASHED;
        }
        # cleanup_dead_server waits till the aux/fork pis is gone.
        # FIXME maybe: cleanup_dead_server could fail (report status of waitForAuxpidGone)
        $self->cleanup_dead_server;
    }
    # cleanup_dead_server waits till the aux/fork pis is gone.
    $self->cleanup_dead_server;

    my $rqg_homedir = Local::get_rqg_home();
    # For testing:
    # $rqg_homedir = undef;
    if (not defined $rqg_homedir) {
        $status = STATUS_INTERNAL_ERROR;
        say("ERROR: $who_am_i The RQG runner has not set RQG_HOME in environment." .
            "Will exit with exit status STATUS_INTERNAL_ERROR.");
        exit $status;
    }
    say("INFO: $who_am_i ------------------------------ Begin");

    # Note:
    # The message within the server error log "Writing a core file..." describes the intention
    # but not if that really happened.
    my $core_dumped_pattern = 'core dumped';
    my $found = Auxiliary::search_in_file($error_log, $core_dumped_pattern);
    if      (not defined $found) {
        $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i Problem when processing '" . $error_log . "'. " .
            Auxiliary::build_wrs($status));
        say("INFO: $who_am_i ------------------------------ End");
        return $status;
    } elsif (1 == $found) {
        # Go on
    } else {
        say("INFO: $who_am_i The pattern '$core_dumped_pattern' was not found in '$error_log'.");
        my $rr = Runtime::get_rr();
        if (defined $rr) {
            # We try to generate a backtrace from the rr trace.
            my $rr_trace_dir    = $vardir . '/rr';
            my $backtrace       = $vardir . '/backtrace.txt';
            my $backtrace_cfg   = $rqg_homedir . "/backtrace-rr.gdb";
            if (not -e $error_log) {
                Carp::cluck("ALARM: $who_am_i A server error log '$error_log' does not exist.");
            }
            if (not -d $rr_trace_dir) {
                Carp::cluck("ALARM: $who_am_i Some rr trace directory '$rr_trace_dir' does not exist.");
            }
            # Note:
            # The rr option --mark-stdio would print STDERR etc. when running 'continue'.
            # But this just shows the content of the server error log which we have anyway.
            my $command = "_RR_TRACE_DIR=$rr_trace_dir rr replay >$backtrace 2>/dev/null " .
                          "< $backtrace_cfg";
            system('bash -c "set -o pipefail; '. $command .'"');
            sayFile($backtrace);
            sayFile($error_log);
        }
        $status = STATUS_SERVER_CRASHED;
        say("INFO: $who_am_i No core file to be expected. " . Auxiliary::build_wrs($status));
        say("INFO: $who_am_i ------------------------------ End");
        return $status;
    }

    # FIXME MAYBE: Is that timeout reasonable?
    my $wait_timeout   = 360 * Runtime::get_runtime_factor();
    my $start_time     = Time::HiRes::time();
    my $max_end_time   = $start_time + $wait_timeout;
    my $datadir        = $self->datadir();
    my $pid            = $self->pid();
    my $core;
    while (not defined $core and Time::HiRes::time() < $max_end_time) {
        sleep 1;
        $core = <$datadir/core*>;
        if (defined $core) {
            # say("DEBUG: The core file name computed is '$core'");
        } else {
            $core = </cores/core.$pid> if $^O eq 'darwin';
            if (defined $core) {
                # say("DEBUG: The core file name computed is '$core'");
            } else {
                $core = <$datadir/vgcore*> if defined Runtime::get_valgrind();
                if (defined $core) {
                    # say("DEBUG: The core file name computed is '$core'");
                } else {
                    # say("DEBUG: The core file name is not defined.");
                }
            }
        }
    }
    if (not defined $core) {
        $status = STATUS_SERVER_CRASHED;
        sayFile($error_log);
        say("INFO: $who_am_i Even after $wait_timeout" . "s waiting no core file with expected " .
            "name found. " . Auxiliary::build_wrs($status));
        say("INFO: $who_am_i ------------------------------ End");
        return $status;
    }
    say("INFO: The core file name computed is '$core'.");
    $core = File::Spec->rel2abs($core);
    # AFAIR:
    # Starting GDB for some not existing core file could waste serious runtime and
    # especially CPU time too.
    if (-f $core) {
        my @filestats = stat($core);
        my $filesize  = $filestats[7] / 1024;
        say("INFO: Core file '$core' size in KB: $filesize");
    } else {
        $status = STATUS_SERVER_CRASHED;
        sayFile($error_log);
        say("ERROR: $who_am_i Core file not found. " . Auxiliary::build_wrs($status));
        say("INFO: $who_am_i ------------------------------ End");
        return $status;
    }

    my @commands;
    my $binary = $self->binary();
    # Experiment:
    my $bindir = dirname($binary);

    if (osWindows()) {
        $bindir =~ s{/}{\\}sgio;
        my $cdb_cmd = "!sym prompts off; !analyze -v; .ecxr; !for_each_frame dv /t;~*k;q";
        push @commands,
            'cdb -i "' . $bindir . '" -y "' . $bindir .
            ';srv*C:\\cdb_symbols*http://msdl.microsoft.com/download/symbols" -z "' . $datadir .
            '\mysqld.dmp" -lines -c "' . $cdb_cmd . '"';
    } elsif (osSolaris()) {
        ## We don't want to run gdb on solaris since it may core-dump
        ## if the executable was generated with SunStudio.

        ## 1) First try to do it with dbx. dbx should work for both
        ## Sunstudio and GNU CC. This is a bit complicated since we
        ## need to first ask dbx which threads we have, and then dump
        ## the stack for each thread.

        ## The code below is "inspired by MTR
        `echo | dbx - $core 2>&1` =~ m/Corefile specified executable: "([^"]+)"/;
        if ($1) {
            ## We do apparently have a working dbx

            # First, identify all threads
            my @threads = `echo threads | dbx $binary $core 2>&1` =~ m/t@\d+/g;

            ## Then we make a command for each thread (It would be
            ## more efficient and get nicer output to have all
            ## commands in one dbx-batch, TODO!)

            my $traces = join("; ", map{"where " . $_} @threads);

            push @commands, "echo \"$traces\" | dbx $binary $core";
        } elsif ($core) {
            ## We'll attempt pstack and c++filt which should allways
            ## work and show all threads. c++filt from SunStudio
            ## should even be able to demangle GNU CC-compiled
            ## executables.
            push @commands, "pstack $core | c++filt";
        } else {
            $status = STATUS_SERVER_CRASHED;
            say ("ERROR: $who_am_i No core available. " . Auxiliary::build_wrs($status));
            say("INFO: $who_am_i ------------------------------ End");
            return $status;
        }
    } else {
        ## Assume all other systems are gdb-"friendly" ;-)
        # We should not expect that our RQG Runner has some current working directory
        # containing the RQG to be used or some RQG at all.
        my $command_part = "gdb --batch --se=$binary --core=$core --command=$rqg_homedir";
        push @commands, "$command_part" . "/backtrace.gdb";
        push @commands, "$command_part" . "/backtrace-all.gdb";
    }

    # 2021-02-15 Observation:
    # Strong box, only one RQG worker is active, "rr" is not used
    # 14:42:53 the last concurrent RQG worker finished.
    # gdb with backtrace-all.gdb is running + consuming CPU
    # Last entry into RQG log is
    # 2021-02-15T14:15:13 [2227401] 74  in abort.c
    #           I sent 15:05:51 a SIGKILL to the processes.
    # result.txt reports a total runtime of 3353s.
    # FIXME:
    # Introduce timeouts for gdb operations.

    foreach my $command (@commands) {
        my $output = `$command`;
        say("$output");
        # Observation 2018-07-12
        # During some grammar simplification run the grammar loses its balance (INSERTS remain,
        # DELETE is gone). Caused by this and some other things we end up in rapid increasing
        # space consumption --> no more space on tmpfs which than causes RQG runs to
        # - fail in bootstrap
        # - storage engine reports error 28 (disk full), the server asserts and gdb tells
        #   BFD: Warning: /dev/shm/vardir/1531326733/23/54/1/data/core is truncated:
        #   expected core file size >= 959647744, found: 55398400.
        # A pattern for that problem is added to the "ignore" section of verdict_general.cfg.
    }

    $status = STATUS_SERVER_CRASHED;
    sayFile($error_log);
    say("ERROR: $who_am_i " . Auxiliary::build_wrs($status));
    say("INFO: $who_am_i ------------------------------ End");
    return $status;

} # End sub make_backtrace

sub server_is_operable {
# 1. Check if the server is running
#    No  --> make_backtrace return STATUS_SERVER_CRASHED
#    Yes --> go on
# 2. Try to connect (Supervised with timeout? But load by sessions should be ~ 0.)
#    Fail    --> kill server with SIGABRT, make_backtrace, return STATUS_SERVER_DEADLOCKED
#    Success --> SHOW PROCESSLIST, print result, disconnect, return STATUS_OK
#
# There must be never more than one process running server_is_operable.
#
# Example of a SHOW PROCESSLIST result set.
# 0   1     2          3     4        5     6      7                 8
# Id  User  Host       db    Command  Time  State  Info              Progress
#  4  root  localhost  test  Query       0   Init  SHOW PROCESSLIST  0.000
use constant PROCESSLIST_PROCESS_ID          => 0;
use constant PROCESSLIST_PROCESS_COMMAND     => 4;
use constant PROCESSLIST_PROCESS_TIME        => 5;
use constant PROCESSLIST_PROCESS_INFO        => 7;

    my $self = shift;

    my $status =        STATUS_OK;
    my $who_am_i =      Basics::who_am_i;
    my $server_id =     $self->server_id();
    my $server_name =   "server[" . $server_id . "]";
    if (not defined $server_id) {
        Carp::cluck("ERROR: server_id is undef");
        $status = STATUS_INTERNAL_ERROR;
        say("ERROR: $who_am_i Will return STATUS_INTERNAL_ERROR" .
            "($status) because of previous error.");
    }
    $who_am_i .=        " $server_name ";

    my $pid = $self->serverpid;
    $pid = "<unknown>" if not defined $pid;
    if (not $self->running) {
        say("ERROR: $who_am_i with process [" . $pid . "] is no more running.");
        $status = $self->make_backtrace();
        say("INFO: $who_am_i make_backtrace reported status $status. Will return that.");
    } else {
        # say("DEBUG: The server[" . $server_id . "] with process [" . $pid . "] is running.");
        # say("DEBUG: port is " . $self->port );
        if (not defined $self->dbh) {
            # $self->dbh is a function which tries to make a connect(with timeout).
            say("ERROR: $who_am_i Getting a connection to the running server[" .
                $server_id . "] failed with " . $DBI::errstr);
            # Experimental code based on the rare observation 2023-01:
            # The server process was running but is around dying. Hence the connect attempt failed.
            # make_backtrace gets called and detects again that the server process is running,
            # kills that process and reports STATUS_SERVER_CRASHED.
            # I want that
            # - make_backtrace does not need to kill
            # - the content of the RQG log makes easier clear what happened
            $status = GenTest_e::Executor::MySQL::errorType($DBI::err);
            if (STATUS_SERVER_CRASHED == $status) {
                say("INFO: $who_am_i Setting the status to STATUS_SERVER_CRASHED.");
                say("INFO: $who_am_i Will poll 30s if the server process finishes before " .
                    "calling 'make_backtrace'.");
                my $end_time = time() + 30;
                while (time() < $end_time) {
                    if (not $self->running) {
                        last;
                    } else {
                        sleep 1;
                    }
                }
                if (not $self->running) {
                    say("ERROR: $who_am_i with process [" . $pid . "] is no more running.");
                    say("DEBUG: $who_am_i Will call 'make_backtrace'");
                } else {
                    say("ERROR: $who_am_i with process [" . $pid . "] stays running.");
                    say("DEBUG: $who_am_i Will call 'make_backtrace' which will kill the server " .
                        "process if running.");
                    $status = STATUS_SERVER_DEADLOCKED;
                }
            } else {
                say("INFO: $who_am_i Will call 'make_backtrace' which will kill the server " .
                    "process if running.");
            }
            my $mbt_status = $self->make_backtrace();
            say("INFO: $who_am_i make_backtrace reported status $mbt_status.");
            say("ERROR: $who_am_i Will stick to status $status and return that because of " .
                "previous errors.");
        } else {
            # FIXME maybe:
            # We need some reasonable timeout for any query like Deadlock already has.
            my $query =       '/*!100108 SET @@max_statement_time = 0 */';
            my $dbh =         $self->dbh;
            $dbh->do($query);
            $query =          "SHOW FULL PROCESSLIST";
            my $processlist = $dbh->selectall_arrayref($query);
            # The query could have failed.
            if (not defined $processlist) {
                if (not $self->running) {
                    $dbh->disconnect;
                    say("ERROR: $who_am_i with process [" . $self->serverpid .
                        "] is no more running.");
                    $status = $self->make_backtrace();
                    say("INFO: $who_am_i make_backtrace reported status $status. " .
                        "Will return that.");
                } else {
                    say("ERROR: $who_am_i The query '$query' failed with " . $DBI::err);
                    my $return = GenTest_e::Executor::MySQL::errorType($DBI::err);
                    if (not defined $return) {
                        say("ERROR: $who_am_i The type of the error got is unknown. " .
                            "Will exit with STATUS_INTERNAL_ERROR");
                        $dbh->disconnect;
                        $status = STATUS_INTERNAL_ERROR;
                        # $status = STATUS_UNKNOWN_ERROR;
                    } else {
                        say("ERROR: $who_am_i Will return status $return" . ".");
                        $dbh->disconnect;
                        $status = $return;
                    }
                }
            } else {
                my $processlist_report = "$who_am_i Content of processlist ---------- begin\n";
                $processlist_report .= "$who_am_i ID -- COMMAND -- TIME -- INFO -- state\n";
                foreach my $process (@$processlist) {
                    my $process_command = $process->[PROCESSLIST_PROCESS_COMMAND];
                    $process_command = "<undef>" if not defined $process_command;
                    # next if $process_command eq 'Daemon';
                    my $process_id   = $process->[PROCESSLIST_PROCESS_ID];
                    my $process_info = $process->[PROCESSLIST_PROCESS_INFO];
                    $process_info    = "<undef>" if not defined $process_info;
                    my $process_time = $process->[PROCESSLIST_PROCESS_TIME];
                    $process_time    = "<undef>" if not defined $process_time;
                    $processlist_report .= "$who_am_i " . $process_id . " -- " . $process_command .
                                " -- " . $process_time . " -- " . $process_info . "\n";
                 }
                 $processlist_report .= "$who_am_i Content of processlist ---------- end";
                 say($processlist_report);
                 $dbh->disconnect;
            }
        }
    }
    say("DEBUG: $who_am_i Will return $status.");
    return $status;
} # End of sub server_is_operable

1;
