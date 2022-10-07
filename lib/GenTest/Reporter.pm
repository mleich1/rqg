# Copyright (c) 2008,2012 Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2018,2022 MariaDB Corporation Ab.
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

package GenTest::Reporter;

require Exporter;
@ISA = qw(GenTest Exporter);
@EXPORT = qw(
    REPORTER_TYPE_PERIODIC
    REPORTER_TYPE_DEADLOCK
    REPORTER_TYPE_CRASH
    REPORTER_TYPE_SUCCESS
    REPORTER_TYPE_SERVER_KILLED
    REPORTER_TYPE_ALWAYS
    REPORTER_TYPE_DATA
    REPORTER_TYPE_END
);

use strict;
use GenTest;
use GenTest::Result;
use GenTest::Random;
use GenTest::Constants;
use DBI;
use File::Find;
use File::Spec;
use Carp;

use constant REPORTER_PRNG                  => 0;
use constant REPORTER_SERVER_DSN            => 1;
use constant REPORTER_SERVER_VARIABLES      => 2;
use constant REPORTER_SERVER_INFO           => 3;
use constant REPORTER_SERVER_PLUGINS        => 4;
use constant REPORTER_TEST_START            => 5;
use constant REPORTER_TEST_END              => 6;
use constant REPORTER_TEST_DURATION         => 7;
use constant REPORTER_PROPERTIES            => 8;
use constant REPORTER_SERVER_DEBUG          => 9;
use constant REPORTER_CUSTOM_ATTRIBUTES     => 10;
# TEST_START is roughly when the YY grammar processing starts.
# TEST_END   is when the YY grammar processing should end.
# REPORTER_START_TIME is when the data has been generated, and reporter was started
# (more or less when the test flow started)
use constant REPORTER_START_TIME            => 11;
use constant REPORTER_NAME                  => 12;

use constant REPORTER_TYPE_PERIODIC         => 2;
use constant REPORTER_TYPE_DEADLOCK         => 4;
use constant REPORTER_TYPE_CRASH            => 8;
use constant REPORTER_TYPE_SUCCESS          => 16;
use constant REPORTER_TYPE_SERVER_KILLED    => 32;
use constant REPORTER_TYPE_ALWAYS           => 64;
use constant REPORTER_TYPE_DATA             => 128;
# New reporter type which can be used at the end of a test.
use constant REPORTER_TYPE_END              => 256;

1;

sub new {
    my $class = shift;

    my $who_am_i = "GenTest::Reporter::new:";

    my $reporter = $class->SUPER::new({
        dsn             => REPORTER_SERVER_DSN,
        test_start      => REPORTER_TEST_START,
        test_end        => REPORTER_TEST_END,
        test_duration   => REPORTER_TEST_DURATION,
        debug_server    => REPORTER_SERVER_DEBUG,
        properties      => REPORTER_PROPERTIES,
        name            => REPORTER_NAME
    }, @_);

    my $dsn = $reporter->dsn();
    # - Errors must be handled (return undef) and not cause perl errors or similar.
    # - Even a SHOW VARIABLES could become the victim of some too short max_statement_time.
    # - SQL tracing should happen if enabled.
    # Hence we use an executor.
    my $executor = GenTest::Executor->newFromDSN($dsn);
    # Set the number to which server we will connect.
    # This number is
    # - used for more detailed messages only
    # - not used for to which server to connect etc. There only the dsn rules.
    # Hint:
    # Server id reported: n ----- dsn(n-1) !
    $executor->setId(1);
    $executor->setRole($reporter->name());
    $executor->setTask(GenTest::Executor::EXECUTOR_TASK_REPORTER);
    my $status = $executor->init();
    # This is exact one connect attempt!
    if ($status != STATUS_OK) {
        $executor->disconnect();
        say("ERROR: $who_am_i No connection for monitoring got. Will return undef.");
        return undef;
    }

    my $query = "SHOW VARIABLES";
    my $res   = $executor->execute($query);
    $status   = $res->status;
    if (STATUS_OK != $status) {
        my $err    = $res->err;
        my $errstr = $res->errstr;
        say("ERROR: $who_am_i ->" . $query . "<- failed with $err : $errstr.");
        # Getting a proper working reporter is essential.
        # Hence any status > 0 has to be treated as fatal for reporters.
        $executor->disconnect();
        say("ERROR: $who_am_i Will return undef.");
        return undef;
    }

    my $key_ref = $res->data;
    foreach my $val (@$key_ref) {
        # variable_name , value
        my $v0 = $val->[0];
        my $v1 = $val->[1];
        # say("DEBUG: $who_am_i Variable_name: $v0 - Value: $v1");
        $reporter->[REPORTER_SERVER_VARIABLES]->{$val->[0]} = $val->[1];
    }

    $query  = "SHOW SLAVE HOSTS";
    $res    = $executor->execute($query);
    $status = $res->status;
    if (STATUS_OK != $status) {
        my $err    = $res->err;
        my $errstr = $res->errstr;
        my $msg_snip = "$who_am_i ->" . $query . "<- failed with $err : $errstr.";
        if (1227 == $err) {
            # Error 1227 ER_SPECIFIC_ACCESS_DENIED_ERROR
            # SHOW SLAVE HOSTS may fail if the user does not have the
            # REPLICATION MASTER ADMIN privilege
            say("WARN: " . $msg_snip);
        } else {
            # Getting a proper working reporter is essential.
            # Hence any status > 0 has to be treated as fatal for reporters.
            $executor->disconnect();
            say("ERROR: " . $msg_snip);
            say("ERROR: $who_am_i Will return undef.");
            return undef;
        }
    }

    my $slave_info = $res->data;
    if (defined $slave_info) {
        $reporter->[REPORTER_SERVER_INFO]->{slave_host} = $slave_info->[1];
        $reporter->[REPORTER_SERVER_INFO]->{slave_port} = $slave_info->[2];
    }

    $query  = "SELECT PLUGIN_NAME, PLUGIN_LIBRARY\n" .
              "FROM INFORMATION_SCHEMA.PLUGINS\n"    .
              "WHERE PLUGIN_LIBRARY IS NOT NULL";
    $res    = $executor->execute($query);
    $status = $res->status;
    if (STATUS_OK != $status) {
        my $err    = $res->err;
        my $errstr = $res->errstr;
        $executor->disconnect();
        say("ERROR: $who_am_i ->" . $query . "<- failed with $err : $errstr.");
        say("ERROR: $who_am_i Will return undef.");
        return undef;
    }
    if ($reporter->serverVariable('version') !~ m{^5\.0}sgio) {
        $reporter->[REPORTER_SERVER_PLUGINS] = $res->data;
        my $plugins = $reporter->[REPORTER_SERVER_PLUGINS];
        # foreach my $plugin (@$plugins) {
        #     say("DEBUG: PLUGINS: --plugin-load=" . $plugin->[0] . '=' . $plugin->[1]);
        # };
    }

    $executor->disconnect();

    $reporter->updatePid();

    my $binary;
    my $bindir;
    my $binname;
    # Use debug server, mysqld_debug.
    if ($reporter->serverDebug){
        $binname = osWindows() ? 'mysqld-debug.exe' : 'mysqld-debug';
        ($bindir,$binary)=$reporter->findMySQLD($binname);
        if ((-e $binary)) {
            $reporter->[REPORTER_SERVER_INFO]->{bindir} = $bindir;
            $reporter->[REPORTER_SERVER_INFO]->{binary} = $binary;
        } else {
            # If mysqld_debug server is not present use mysqld.
            $binname = osWindows() ? 'mysqld.exe' : 'mysqld';
            ($bindir,$binary)=$reporter->findMySQLD($binname);

            # Identify if server is debug.
            my $command = $binary.' --version';
            my $result=`$command 2>&1`;
            undef $binary if ($result !~ /debug/sig);

            if ((-e $binary)) {
                $reporter->[REPORTER_SERVER_INFO]->{bindir} = $bindir;
                $reporter->[REPORTER_SERVER_INFO]->{binary} = $binary;
            }
        }
    } else {
        # Use non-debug serever.
        $binname = osWindows() ? 'mysqld.exe' : 'mysqld';
        ($bindir,$binary)=$reporter->findMySQLD($binname);
        if ((-e $binary)) {
            $reporter->[REPORTER_SERVER_INFO]->{bindir} = $bindir;
            $reporter->[REPORTER_SERVER_INFO]->{binary} = $binary;
        } else {
            # If we dont find non-debug server use debug(mysqld_debug) server.
            $binname = osWindows() ? 'mysqld-debug.exe' : 'mysqld-debug';
            ($bindir,$binary)=$reporter->findMySQLD($binname);
            if ((-e $binary)) {
                $reporter->[REPORTER_SERVER_INFO]->{bindir} = $bindir;
                $reporter->[REPORTER_SERVER_INFO]->{binary} = $binary;
            }
        }
    }

    foreach my $client_path (
        "client/RelWithDebInfo", "client/Debug",
        "client", "../client", "bin", "../bin"
	) {
        if (-e $reporter->serverVariable('basedir') . '/' . $client_path) {
            $reporter->[REPORTER_SERVER_INFO]->{'client_bindir'} =
                                    $reporter->serverVariable('basedir') . '/' . $client_path;
            last;
	    }
    }

    my $errorlog = $reporter->serverVariable('log_error');
    if ($errorlog eq '') {
        # If not set explicite than the default is '' and ....
        # Look for the server error log above the datadir.
        $errorlog = File::Basename::dirname($reporter->serverVariable('datadir')) . "/mysql.err";
    }
    if (-e $errorlog) {
        # Unclear if after some minor cleanup needed
        $reporter->[REPORTER_SERVER_INFO]->{'errorlog'} = $errorlog;
    } else {
        say("ERROR: $who_am_i The server error log '$errorlog' does not exist. Will return undef.");
        return undef;
    }

    my $prng = GenTest::Random->new( seed => 1 );
    $reporter->[REPORTER_PRNG] = $prng;

    # general properties area for sub-classes
    $reporter->[REPORTER_CUSTOM_ATTRIBUTES]={};
    $reporter->[REPORTER_START_TIME]= time();

    return $reporter;
}

sub updatePid {
    my $pid_file = $_[0]->serverVariable('pid_file');

    # Observation: 2019-12
    # --------------------
    # Reporter Deadlock got no connection and reported STATUS_SERVER_CRASHED.
    # Reporter Backtrace fiddled a bit around and harvested
    #     sync: error opening '/dev/shm/vardir/1576241904/19/1/mysql.pid': No such file or directory
    # The server error log shows that shutdown was asked from unknown side.
    # And the error log ends with: [Note] /home/mleich/Server/10.5/bld_debug//sql/mysqld: Shutdown complete
    #
    # So what to do in case the pid_file disappears because of regular shutdown?
    #

    open (PF, $pid_file);
    read (PF, my $pid, -s $pid_file);
    close (PF);

    $pid =~ s{[\r\n]}{}sio;

    $_[0]->[REPORTER_SERVER_INFO]->{pid} = $pid;
}

sub monitor {
    die "Default monitor() called.";
}

sub report {
    die "Default report() called.";
}

sub dsn {
    return $_[0]->[REPORTER_SERVER_DSN];
}

sub serverVariable {
    return $_[0]->[REPORTER_SERVER_VARIABLES]->{$_[1]};
}

sub serverInfo {
    $_[0]->[REPORTER_SERVER_INFO]->{$_[1]};
}

sub serverPlugins {
    return $_[0]->[REPORTER_SERVER_PLUGINS];
}

sub testStart {
    return $_[0]->[REPORTER_TEST_START];
}

sub reporterStartTime {
    return $_[0]->[REPORTER_START_TIME];
}

sub testEnd {
    return $_[0]->[REPORTER_TEST_END];
}

sub prng {
    return $_[0]->[REPORTER_PRNG];
}

sub testDuration {
    return $_[0]->[REPORTER_TEST_DURATION];
}

sub properties {
    return $_[0]->[REPORTER_PROPERTIES];
}

sub serverDebug {
    return $_[0]->[REPORTER_SERVER_DEBUG];
}

sub customAttribute() {
    if (defined $_[2]) {
        $_[0]->[GenTest::Reporter::REPORTER_CUSTOM_ATTRIBUTES]->{$_[1]}=$_[2];
    }
    return $_[0]->[GenTest::Reporter::REPORTER_CUSTOM_ATTRIBUTES]->{$_[1]};
}

sub name {
    return $_[0]->[REPORTER_NAME];
}

sub configure {
    return 1;
}

# Input : For given binary either mysqld/mysqld-debug
# Output: Return bindir and absolute path of the binary file.
sub findMySQLD {
    my ($reporter,$binname)=@_;
    my $bindir;
    # Handling general basedirs and MTRv1 style basedir,
    # but trying not to search the entire universe just for the sake of it
    my @basedirs = ($reporter->serverVariable('basedir'));
    if (! -e File::Spec->catfile($reporter->serverVariable('basedir'),'mysql-test') and
          -e File::Spec->catfile($reporter->serverVariable('basedir'),'t')) {
        # Assuming it's the MTRv1 style basedir
        @basedirs=(File::Spec->catfile($reporter->serverVariable('basedir'),'..'));
    }
    find(sub {
            $bindir=$File::Find::dir if $_ eq $binname;
    }, @basedirs);
    my $binary = File::Spec->catfile($bindir, $binname);
    return ($bindir,$binary);
}

1;
