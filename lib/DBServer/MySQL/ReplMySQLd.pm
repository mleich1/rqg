# Copyright (c) 2010, 2012, Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2013, Monty Program Ab.
# Copyright (c) 2020, 2022 MariaDB Corporation Ab.
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

package DBServer::MySQL::ReplMySQLd;

@ISA = qw(DBServer::DBServer);

use DBI;
use DBServer::DBServer;
use DBServer::MySQL::MySQLd;
use if osWindows(), Win32::Process;
use Time::HiRes;

use strict;

use Carp;
use Data::Dumper;

use constant REPLMYSQLD_MASTER_BASEDIR      =>   0;
use constant REPLMYSQLD_MASTER_VARDIR       =>   1;
use constant REPLMYSQLD_SLAVE_VARDIR        =>   2;
use constant REPLMYSQLD_MASTER_PORT         =>   3;
use constant REPLMYSQLD_SLAVE_PORT          =>   4;
use constant REPLMYSQLD_MODE                =>   5;
use constant REPLMYSQLD_START_DIRTY         =>   6;
use constant REPLMYSQLD_SERVER_OPTIONS      =>   7;
use constant REPLMYSQLD_MASTER              =>   8;
use constant REPLMYSQLD_SLAVE               =>   9;
use constant REPLMYSQLD_VALGRIND            =>  10;
use constant REPLMYSQLD_VALGRIND_OPTIONS    =>  11;
use constant REPLMYSQLD_GENERAL_LOG         =>  12;
use constant REPLMYSQLD_DEBUG_SERVER        =>  13;
use constant REPLMYSQLD_USE_GTID            =>  14;
use constant REPLMYSQLD_SLAVE_BASEDIR       =>  15;
use constant REPLMYSQLD_CONFIG_CONTENTS     =>  16;
use constant REPLMYSQLD_USER                =>  17;
use constant REPLMYSQLD_NOSYNC              =>  18;
use constant REPLMYSQLD_RR                  =>  19;
use constant REPLMYSQLD_RR_OPTIONS          =>  20;

sub new {
    my $class = shift;

    my $who_am_i = Basics::who_am_i();

    my $self = $class->SUPER::new({'master'           => REPLMYSQLD_MASTER,
                                   'slave'            => REPLMYSQLD_SLAVE,
                                   'master_basedir'   => REPLMYSQLD_MASTER_BASEDIR,
                                   'slave_basedir'    => REPLMYSQLD_SLAVE_BASEDIR,
                                   'debug_server'     => REPLMYSQLD_DEBUG_SERVER,
                                   'master_vardir'    => REPLMYSQLD_MASTER_VARDIR,
                                   'master_port'      => REPLMYSQLD_MASTER_PORT,
                                   'slave_vardir'     => REPLMYSQLD_SLAVE_VARDIR,
                                   'slave_port'       => REPLMYSQLD_SLAVE_PORT,
                                   'mode'             => REPLMYSQLD_MODE,
                                   'server_options'   => REPLMYSQLD_SERVER_OPTIONS,
                                   'general_log'      => REPLMYSQLD_GENERAL_LOG,
                                   'start_dirty'      => REPLMYSQLD_START_DIRTY,
                                   'valgrind'         => REPLMYSQLD_VALGRIND,
                                   'valgrind_options' => REPLMYSQLD_VALGRIND_OPTIONS,
                                   'use_gtid'         => REPLMYSQLD_USE_GTID,
                                   'config'           => REPLMYSQLD_CONFIG_CONTENTS,
                                   'rr'               => REPLMYSQLD_RR,
                                   'rr_options'       => REPLMYSQLD_RR_OPTIONS,
                                   'user'             => REPLMYSQLD_USER},@_);

    if (defined $self->[REPLMYSQLD_USE_GTID]
        and  lc($self->[REPLMYSQLD_USE_GTID] ne 'no')
        and  lc($self->[REPLMYSQLD_USE_GTID] ne 'current_pos')
        and  lc($self->[REPLMYSQLD_USE_GTID] ne 'slave_pos')
    ) {
        Carp::cluck("ERROR: $who_am_i Invalid value $self->[REPLMYSQLD_USE_GTID] " .
                    "for use_gtid option. Will return undef.");
        return undef;
    }

    if (defined $self->master || defined $self->slave) {
        ## Repl pair defined from two predefined servers

        if (not (defined $self->master && defined $self->slave)) {
            Carp::cluck("ERROR: $who_am_i Both master and slave must be defined. " .
                        "Will return undef.");
            return undef;
        }
        $self->master->addServerOptions(["--server_id=1",
                                         "--log-bin=mysql-bin",
                                         "--report-host=127.0.0.1",
                                         "--report_port=" . $self->master->port]);
        $self->slave->addServerOptions(["--server_id=2",
                                        "--report-host=127.0.0.1",
                                        "--report_port=" . $self->slave->port]);
    } else {
        ## Repl pair defined from parameters.
        if (not defined $self->[REPLMYSQLD_MASTER_PORT]) {
            # FIXME:
            # How many code files have their own definition/setting of this value?
            # And if several than shouldn't the constant MYSQLD_DEFAULT_PORT be
            # defined at one place only?
            $self->[REPLMYSQLD_MASTER_PORT] = DBServer::MySQL::MySQLd::MYSQLD_DEFAULT_PORT;
        }

        if (not defined $self->[REPLMYSQLD_SLAVE_PORT]) {
            $self->[REPLMYSQLD_SLAVE_PORT] = $self->[REPLMYSQLD_MASTER_PORT] + 2;
        }

        if (not defined $self->[REPLMYSQLD_MODE]) {
            $self->[REPLMYSQLD_MODE] = 'default';
        } elsif ($self->[REPLMYSQLD_MODE] =~ /(\w+)-nosync/i) {
            $self->[REPLMYSQLD_MODE]   = $1;
            $self->[REPLMYSQLD_NOSYNC] = 1;
        }

        # Already done by rqg.pl but maybe not by other RQG runners.
        if (not defined $self->[REPLMYSQLD_SLAVE_BASEDIR]) {
            $self->[REPLMYSQLD_SLAVE_BASEDIR] = $self->[REPLMYSQLD_MASTER_BASEDIR];
        }

        my @master_options;
        push(@master_options,
             "--server_id=1",
             "--log-bin=mysql-bin",
             "--report-host=127.0.0.1",
             "--report_port=" . $self->[REPLMYSQLD_MASTER_PORT]);
        if (defined $self->[REPLMYSQLD_SERVER_OPTIONS]) {
            push(@master_options,
                 @{$self->[REPLMYSQLD_SERVER_OPTIONS]});
        }

        $self->[REPLMYSQLD_MASTER] =
        DBServer::MySQL::MySQLd->new(basedir          => $self->[REPLMYSQLD_MASTER_BASEDIR],
                                     vardir           => $self->[REPLMYSQLD_MASTER_VARDIR],
                                     debug_server     => $self->[REPLMYSQLD_DEBUG_SERVER],
                                     port             => $self->[REPLMYSQLD_MASTER_PORT],
                                     server_options   => \@master_options,
                                     general_log      => $self->[REPLMYSQLD_GENERAL_LOG],
                                     start_dirty      => $self->[REPLMYSQLD_START_DIRTY],
                                     valgrind         => $self->[REPLMYSQLD_VALGRIND],
                                     valgrind_options => $self->[REPLMYSQLD_VALGRIND_OPTIONS],
                                     rr               => $self->[REPLMYSQLD_RR],
                                     rr_options       => $self->[REPLMYSQLD_RR_OPTIONS],
                                     config           => $self->[REPLMYSQLD_CONFIG_CONTENTS],
                                     user             => $self->[REPLMYSQLD_USER]);

        if (not defined $self->master) {
            Carp::cluck("ERROR: $who_am_i Could not create master. Will return undef.");
            return undef;
        }
        # say("DEBUG: $who_am_i Master was created.");

        my @slave_options;
        push(@slave_options,
             "--server_id=2",
             "--report-host=127.0.0.1",
             "--report_port=" . $self->[REPLMYSQLD_SLAVE_PORT]);
        if (defined $self->[REPLMYSQLD_SERVER_OPTIONS]) {
            push(@slave_options,
                 @{$self->[REPLMYSQLD_SERVER_OPTIONS]});
        }


        $self->[REPLMYSQLD_SLAVE] =
        DBServer::MySQL::MySQLd->new(basedir          => $self->[REPLMYSQLD_SLAVE_BASEDIR],
                                     vardir           => $self->[REPLMYSQLD_SLAVE_VARDIR],
                                     debug_server     => $self->[REPLMYSQLD_DEBUG_SERVER],
                                     port             => $self->[REPLMYSQLD_SLAVE_PORT],
                                     server_options   => \@slave_options,
                                     general_log      => $self->[REPLMYSQLD_GENERAL_LOG],
                                     start_dirty      => $self->[REPLMYSQLD_START_DIRTY],
                                     valgrind         => $self->[REPLMYSQLD_VALGRIND],
                                     valgrind_options => $self->[REPLMYSQLD_VALGRIND_OPTIONS],
                                     rr               => $self->[REPLMYSQLD_RR],
                                     rr_options       => $self->[REPLMYSQLD_RR_OPTIONS],
                                     config           => $self->[REPLMYSQLD_CONFIG_CONTENTS],
                                     user             => $self->[REPLMYSQLD_USER]);

        if (not defined $self->slave) {
            $self->master->stopServer;
            Carp::cluck("ERROR: $who_am_i Could not create slave. Will return undef.");
            return undef;
        }
        # say("DEBUG: $who_am_i Slave was created.");
    }

    return $self;
}

sub master {
    return $_[0]->[REPLMYSQLD_MASTER];
}

sub slave {
    return $_[0]->[REPLMYSQLD_SLAVE];
}

sub mode {
    return $_[0]->[REPLMYSQLD_MODE];
}

sub startServer {
    my ($self) = @_;

    my $who_am_i = Basics::who_am_i();

    if ($self->master->startServer != DBSTATUS_OK) {
        return DBSTATUS_FAILURE;
    }
    my $master_dbh = $self->master->dbh;
    if ($self->slave->startServer != DBSTATUS_OK) {
        return DBSTATUS_FAILURE;
    }
    my $slave_dbh = $self->slave->dbh;

    # FIXME: All the SQL which follows could fail!
    my ($foo, $master_version) = $master_dbh->selectrow_array("SHOW VARIABLES LIKE 'version'");

    if (($master_version !~ m{^5\.0}sio) && ($self->mode ne 'default')) {
        # FIXME: This can fail.
        foreach my $server_dbh ($master_dbh , $slave_dbh) {
            $server_dbh->do("SET GLOBAL BINLOG_FORMAT = '" . $self->mode."'");
        }
    }

    $slave_dbh->do("STOP SLAVE");

#   $slave_dbh->do("SET GLOBAL storage_engine = '$engine'") if defined $engine;

    my $master_use_gtid = (
        defined $self->[REPLMYSQLD_USE_GTID]
        ? ', MASTER_USE_GTID = ' . $self->[REPLMYSQLD_USE_GTID]
        : ''
    );

    $slave_dbh->do("CHANGE MASTER TO ".
                   " MASTER_PORT = " . $self->master->port . ",".
                   " MASTER_HOST = '127.0.0.1',".
                   " MASTER_USER = 'root',".
                   " MASTER_CONNECT_RETRY = 1" . $master_use_gtid);

    $slave_dbh->do("START SLAVE");

    return DBSTATUS_OK;
}

sub waitForSlaveSync {
    my ($self) = @_;

    my $who_am_i = Basics::who_am_i();

    if ($self->[REPLMYSQLD_NOSYNC]) {
        say("Replication mode is NOSYNC, slave synchronization will be skipped");
      return DBSTATUS_OK;
    }

    if (! $self->master->dbh) {
        say("ERROR: $who_am_i Could not connect to master. " .
            "Will return DBSTATUS_FAILURE.");
        return DBSTATUS_FAILURE;
    }
    if (! $self->slave->dbh) {
        say("ERROR: $who_am_i Could not connect to slave. " .
            "Will return DBSTATUS_FAILURE.");
        return DBSTATUS_FAILURE;
    }

    # FIXME: All the SQL which follows could fail!
    my ($file, $pos) = $self->master->dbh->selectrow_array("SHOW MASTER STATUS");
    say("Master status $file/$pos. Waiting for slave to catch up...");
    my $wait_result = $self->slave->dbh->selectrow_array("SELECT MASTER_POS_WAIT('$file',$pos)");
    if (not defined $wait_result) {
        if ($self->slave->dbh) {
            my @slave_status = $self->slave->dbh->selectrow_array(
                                      "SHOW SLAVE STATUS /* ReplMySQLd::waitForSlaveSync */");
            say("ERROR: $who_am_i Slave SQL thread has stopped with error: " . $slave_status[37] .
                "Will return DBSTATUS_FAILURE.");
        } else {
            say("ERROR: $who_am_i Lost connection to the slave. " .
                "Will return DBSTATUS_FAILURE.");
        }
        return DBSTATUS_FAILURE;
    } else {
        return DBSTATUS_OK;
    }
}

sub stopServer {
    my ($self, $status) = @_;

    my $who_am_i = Basics::who_am_i();

    my $total_ret = DBSTATUS_OK;
    if ($status == DBSTATUS_OK) {
        if ($self->waitForSlaveSync() != DBSTATUS_OK) {
            say("WARN: $who_am_i Syncing the slave made trouble. " .
                "Will return DBSTATUS_FAILURE.");
            $total_ret = DBSTATUS_FAILURE;
        }
    }
    # FIXME: All the SQL which follows could fail!
    if ($self->slave->dbh) {
        $self->slave->dbh->do("STOP SLAVE");
    }
    if ($self->slave->stopServer != DBSTATUS_OK) {
        say("WARN: $who_am_i Stopping the slave made trouble. " .
            "Will return DBSTATUS_FAILURE.");
        $total_ret = DBSTATUS_FAILURE;
    }
    if ($self->master->stopServer != DBSTATUS_OK) {
        say("WARN: $who_am_i Stopping the master made trouble. " .
            "Will return DBSTATUS_FAILURE.");
        $total_ret = DBSTATUS_FAILURE;
    }
    return $total_ret;
}

sub killServer {
    my ($self) = @_;

    my $who_am_i = Basics::who_am_i();

    my $total_ret = DBSTATUS_OK;
    if ($self->slave->killServer != DBSTATUS_OK) {
        say("WARN: $who_am_i Killing the slave made trouble. " .
            "Will return DBSTATUS_FAILURE.");
        $total_ret = DBSTATUS_FAILURE;
    }
    if ($self->master->killServer != DBSTATUS_OK) {
        say("WARN: $who_am_i Killing the master made trouble. " .
            "Will return DBSTATUS_FAILURE.");
        $total_ret = DBSTATUS_FAILURE;
    }
    return $total_ret;
}

sub crashServer {
    my ($self) = @_;

    my $who_am_i = Basics::who_am_i();

    my $total_ret = DBSTATUS_OK;
    if ($self->slave->crashServer != DBSTATUS_OK) {
        say("WARN: $who_am_i Killing the slave with core made trouble. " .
            "Will return DBSTATUS_FAILURE.");
        $total_ret = DBSTATUS_FAILURE;
    }
    if ($self->master->crashServer != DBSTATUS_OK) {
        say("WARN: $who_am_i Killing the master with core made trouble. " .
            "Will return DBSTATUS_FAILURE.");
        $total_ret = DBSTATUS_FAILURE;
    }
    return $total_ret;
}

1;
