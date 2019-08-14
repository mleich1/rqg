# Copyright (C) 2013 Monty Program Ab
# Copyright (C) 2019 MariaDB Corporation Ab.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
#
# This module is a derivate of lib/DBServer/MySQL/GaleraMySQLd.pm developed by
# Elena Stepanova in 2013.
# Caused by
# - changes in Galera and MariaDB properties between 2013 and today
# - the needs to
#   - make concurrent RQG tests managed by rqg_batch.pl free of clashes
#   - analysis of unfortunate effects easier
# - my personal preferences regarding
#   - formatting of code
#   - structure and naming of subdirectories used for data of DB servers
#   - notation of DB servers in messages
#     RQG with his own replication, RQG/MTR running MariaDB replication call the first server "1"
#     and not "0" like the index of the corresponding code structure.
# I was forced to make intrusive changes.
# And in order to
# - avoid maybe existing incompatibilities with certain RQG runners (runall*.pl etc.)
# - keep the old code available for reference and as fall back position
# the current package gets provided as 'DBServer::MySQL::GaleraMySQLd1'.
#
# 2019-08 Matthias Leich
#

package DBServer::MySQL::GaleraMySQLd1;

@ISA = qw(DBServer::DBServer);

use DBI;
use DBServer::DBServer;
use DBServer::MySQL::MySQLd;

use strict;

use Carp;

use constant GALERA_MYSQLD_BASEDIR          =>  0;
use constant GALERA_MYSQLD_PARENT_VARDIR    =>  1;
use constant GALERA_MYSQLD_FIRST_PORT       =>  2;
use constant GALERA_MYSQLD_START_DIRTY      =>  3;
use constant GALERA_MYSQLD_SERVER_OPTIONS   =>  4;
use constant GALERA_MYSQLD_VALGRIND         =>  5;
use constant GALERA_MYSQLD_VALGRIND_OPTIONS =>  6;
use constant GALERA_MYSQLD_GENERAL_LOG      =>  7;
use constant GALERA_MYSQLD_DEBUG_SERVER     =>  8;
use constant GALERA_MYSQLD_NODE_COUNT       =>  9;
use constant GALERA_MYSQLD_NODES            => 10;


##########################################
# The module starts a Galera cluster
# with the requested number of nodes
##########################################

my $script_debug = 0;

sub new {
    my $class = shift;
    my $self = $class->SUPER::new({
        'basedir'           => GALERA_MYSQLD_BASEDIR,
        'debug_server'      => GALERA_MYSQLD_DEBUG_SERVER,
        'parent_vardir'     => GALERA_MYSQLD_PARENT_VARDIR,
        'first_port'        => GALERA_MYSQLD_FIRST_PORT,
        'server_options'    => GALERA_MYSQLD_SERVER_OPTIONS,
        'general_log'       => GALERA_MYSQLD_GENERAL_LOG,
        'start_dirty'       => GALERA_MYSQLD_START_DIRTY,
        'valgrind'          => GALERA_MYSQLD_VALGRIND,
        'valgrind_options'  => GALERA_MYSQLD_VALGRIND_OPTIONS,
        'node_count'        => GALERA_MYSQLD_NODE_COUNT,
        'nodes'             => GALERA_MYSQLD_NODES
    },@_);

    unless ($self->[GALERA_MYSQLD_NODE_COUNT]) {
        Carp::cluck("ERROR: GaleraMySQLd1::new: No nodes defined. Will return undef.");
        return undef;
    }

    $self->[GALERA_MYSQLD_NODES] = [];

    # Set mandatory parameters as documented at
    # http://www.codership.com/wiki/doku.php?id=info#configuration_and_monitoring
    # (except for wsrep_provider which has to be set by the user, as we don't know the path).
    # Additionally we will set wsrep_sst_method=rsync as it makes the configuration simpler.
    # It can be overridden from the command line if the user chooses so.
    my @common_options = (
        "--wsrep_on=ON",
        "--wsrep_sst_method=rsync",
        "--innodb_autoinc_lock_mode=2",
        "--default-storage-engine=InnoDB",
        # 2019: Its deprecated
        # "--innodb_locks_unsafe_for_binlog=1",
        "--binlog-format=row"
    );

    # rqg_batch.pl with proper config file calling finally rqg.pl sets
    # $self->[GALERA_MYSQLD_PARENT_VARDIR] to a value like
    # '/dev/shm/vardir/<rqg_batch.pl run id being a timestamp>/<No of RQG runner>'.
    if (not defined $self->[GALERA_MYSQLD_PARENT_VARDIR]) {
        $self->[GALERA_MYSQLD_PARENT_VARDIR] = "mysql-test/var";
    }

    say("DEBUG: GALERA_MYSQLD_FIRST_PORT : " . $self->[GALERA_MYSQLD_FIRST_PORT] .
              " GALERA_MYSQLD_NODE_COUNT : " . $self->[GALERA_MYSQLD_NODE_COUNT]) if $script_debug;
    my $galera_port_first = $self->[GALERA_MYSQLD_FIRST_PORT] + $self->[GALERA_MYSQLD_NODE_COUNT];
    foreach my $i (0..$self->[GALERA_MYSQLD_NODE_COUNT]-1) {

        # From the manual about Galera and Network Ports
        # ----------------------------------------------
        # Galera Cluster needs access to the following ports:
        # Standard MariaDB Port (default: 3306)
        #     For MySQL client connections and State Snapshot Transfers that use the
        #     mysqldump method. This can be changed by setting port.
        # Galera Replication Port (default: 4567)
        #     For Galera Cluster replication traffic, multicast replication uses both UDP
        #     transport and TCP on this port. Can be changed by setting wsrep_node_address.
        # IST Port (default: 4568)
        #     For Incremental State Transfers. Can be changed by setting ist.recv_addr in
        #     wsrep_provider_options.
        # SST Port (default: 4444)
        #     For all State Snapshot Transfer methods other than mysqldump. Can be changed
        #     by setting wsrep_sst_receive_address.
        #
        # Observation (see var/my.cnf, content edited) in MTR test galera.views MTR_BUILD_THREAD=300
        # [mysqld.1]
        # galera_port=16002 ist_port=16003 sst_port=16004
        # wsrep-cluster-address=gcomm://
        # wsrep_provider_options='repl.causal_read_timeout=PT90S;base_port=16002;evs.suspect_timeout=PT10S;evs.inactive_timeout=PT30S;evs.install_timeout=PT15S;gcache.size=10M'
        # wsrep_node_incoming_address=127.0.0.1:16000   wsrep_sst_receive_address='127.0.0.1:16004'
        # port=16000                 ## port[0]
        #
        # [mysqld.2]
        # galera_port=16005  ist_port=16006  sst_port=16007
        # wsrep_cluster_address='gcomm://127.0.0.1:16002'   # port at end = galera_port of mysqld.1
        # wsrep_provider_options='repl.causal_read_timeout=PT90S;base_port=16005;evs.suspect_timeout=PT10S;evs.inactive_timeout=PT30S;evs.install_timeout=PT15S'
        # wsrep_causal_reads=ON
        # wsrep_sync_wait=15
        # wsrep_node_address=127.0.0.1
        # wsrep_node_incoming_address=127.0.0.1:16001   wsrep_sst_receive_address='127.0.0.1:16007'
        # port=16001                 ## port[1] ??
        #
        # [client]     port=16000   socket=/home/mleich/work/10.3/bld_debug/mysql-test/var/tmp/mysqld.1.sock
        #
        # [mysqltest]
        # [client.1]   port=16000   socket=/home/mleich/work/10.3/bld_debug/mysql-test/var/tmp/mysqld.1.sock
        # [client.2]   port=16001   socket=/home/mleich/work/10.3/bld_debug/mysql-test/var/tmp/mysqld.2.sock

        # i == index of node starting with 0 , I == number of nodes
        # port        = f(MTRBT) + i
        # galera_port = f(MTRBT) + I + i * 3 (3 = no of ports needed for galera) = base_port
        # ist_port    = galera_port + 1
        # sst_port    = galera_port + 2
        my $port        = $self->[GALERA_MYSQLD_FIRST_PORT] + $i;
        my $galera_port = $self->[GALERA_MYSQLD_FIRST_PORT] + $self->[GALERA_MYSQLD_NODE_COUNT]
                          + 3 * $i;
        my $base_port   = $galera_port;
        my $ist_port    = $galera_port + 1;
        my $sst_port    = $galera_port + 2;

        # node 0   wsrep_provider_options='...;base_port=16002;...;gcache.size=10M'
        # node 1   wsrep_provider_options='...;base_port=16005;...'
        my $wsrep_provider_options = 'repl.causal_read_timeout=PT90S;evs.suspect_timeout=PT10S' .
                                     ';evs.inactive_timeout=PT30S;evs.install_timeout=PT15S';
        my $galera_cluster_address = "gcomm://";
        if (0 == $i) {
            $wsrep_provider_options .= ';gcache.size=10M';
        } else {
            $galera_cluster_address .= "127.0.0.1:$galera_port_first";
        }

        my @node_options = (
            @common_options,
            "--wsrep_cluster_address=$galera_cluster_address",
            # "--wsrep-provider=$wsrep_provider",
            "--wsrep_node_incoming_address=127.0.0.1:$port",
            "--wsrep_sst_receive_address=127.0.0.1:$sst_port",
            "--wsrep_provider_options='$wsrep_provider_options;base_port=$base_port'",
        );

        if (defined $self->[GALERA_MYSQLD_SERVER_OPTIONS]) {
            push(@node_options, @{$self->[GALERA_MYSQLD_SERVER_OPTIONS]});
        }
        my $wsrep_provider = $ENV{'WSREP_PROVIDER'};
        if (defined $wsrep_provider) {
            my $wsrep_provider_opt = "--wsrep-provider=$wsrep_provider";
            say("INFO: WSREP_PROVIDER found in environment. Appending '$wsrep_provider_opt' " .
                "after all other server options.");
            # If its defined than it overrides any contradicting options set in RQG call line.
            # So append it after the GALERA_MYSQLD_SERVER_OPTIONS.
            push @node_options, $wsrep_provider_opt;
        }

        if ( $self->[GALERA_MYSQLD_NODE_COUNT] > 1 ) {
            # With that node count we need a wsrep_provider.
            # The options are all already splitted.
            # Only "wsrep-provider" is supported. But not "wsrep_provider".
            my $value_found;
            foreach my $some_option ( @node_options ) {
                if ($some_option !~ /--wsrep-provider/) {
                    next;
                } else {
                    $value_found = $some_option;
                }
            }
            if (not defined $value_found) {
                Carp::cluck("ERROR: GaleraMySQLd1::new: wsrep_provider is not set, replication " .
                        "between nodes is not possible. Will return undef.");
            return undef;
            } else {
                # Alternative which would work on     join ',', @node_options
                #     $value_found =~ s{--wsrep-provider=([a-zA-Z0-9_/\\\.]+).*}{$1}g;
                $value_found =~ s{--wsrep-provider=(.*)$}{$1}g;
                if (not -f $value_found) {
                    Carp::cluck("ERROR: GaleraMySQLd1::new: wsrep_provider is set to " .
                                "'$value_found'. But that file does not exist. Will return undef.");
                    return undef;
                } else {
                    say("INFO: wsrep_provider : '$value_found'");
                }
            }
        }

        my $vardir = $self->[GALERA_MYSQLD_PARENT_VARDIR] . "/" . ($i + 1);

        say("DEBUG:  Node_number -  port -  galera_port -  base_port -  ist_port -  sst_port - " .
            "galera_cluster_address\n" .
            "DEBUG: " . ($i + 1) . " - $port - $galera_port - $base_port - $ist_port - $sst_port - " .
            "$galera_cluster_address") if $script_debug;

        # Connect, run query etc. with $port
        $self->nodes->[$i] = DBServer::MySQL::MySQLd->new(
            basedir             => $self->[GALERA_MYSQLD_BASEDIR],
            vardir              => $vardir,
            debug_server        => $self->[GALERA_MYSQLD_DEBUG_SERVER],
            port                => $port,
            server_options      => \@node_options,
            general_log         => $self->[GALERA_MYSQLD_GENERAL_LOG],
            start_dirty         => $self->[GALERA_MYSQLD_START_DIRTY],
            valgrind            => $self->[GALERA_MYSQLD_VALGRIND],
            valgrind_options    => $self->[GALERA_MYSQLD_VALGRIND_OPTIONS]
        );

        if (not defined $self->nodes->[$i]) {
            Carp::cluck("ERROR: GaleraMySQLd1::new: Could not create node " . ($i + 1) .
                        ". Will return undef.");
            return undef;
        }
    }
    return $self;
}

sub nodes {
    return $_[0]->[GALERA_MYSQLD_NODES];
}

sub startServer {
    my ($self) = @_;
    # Path to Galera scripts is needed for SST
    $ENV{PATH} = "$ENV{PATH}:$self->[GALERA_MYSQLD_BASEDIR]/scripts";
    foreach my $i (0..$self->[GALERA_MYSQLD_NODE_COUNT]-1) {
        return DBSTATUS_FAILURE if $self->nodes->[$i]->startServer != DBSTATUS_OK;
        my $node_dbh = $self->nodes->[$i]->dbh;
        if (not defined $node_dbh) {
            say("ERROR: GaleraMySQLd1::startServer: Connect to node " . ($i + 1) . " failed.");
            return DBSTATUS_FAILURE;
        }
        my (undef, $cluster_size) = $node_dbh->selectrow_array("SHOW STATUS LIKE 'wsrep_cluster_size'");
        # FIXME: What if selectrow_array fails?
        say("DEBUG: Cluster size reported by 'SHOW STATUS ...' after starting node " . ($i + 1) .
            ": $cluster_size") if $script_debug;
    }
#   return DBSTATUS_FAILURE if $self->waitForNodeSync != DBSTATUS_OK;
}

sub waitForNodeSync {
    my ($self)        = @_;
    my $wait_timeout  = 60;
    my $desired_value = 'Synced';
    my $got_sync;
    foreach my $i (0..$self->[GALERA_MYSQLD_NODE_COUNT]-1) {
        $got_sync    = 0;
        if (0 == $self->nodes->[$i]->running()) {
            say("ERROR: waitForNodeSync: The server process for node " . ($i + 1) .
                " is already no more running.");
            return DBSTATUS_FAILURE;
        }
        my $node_dbh = $self->nodes->[$i]->dbh;
        if (not defined $node_dbh) {
            say("ERROR: waitForNodeSync: Connect to node $i failed.");
            # FIXME: Report more details if possible.
            return DBSTATUS_FAILURE;
        }
        my $wait_end = time() + $wait_timeout;
        while (time() < $wait_end) {
            my (undef, $local_state) = $node_dbh->selectrow_array(
                                                  "SHOW STATUS LIKE 'wsrep_local_state_comment'");
            say("DEBUG: waitForNodeSync: Node " . ($i + 1) . ": wsrep_local_state_comment is " .
                "'$local_state'.") if $script_debug;
            if ($local_state ne $desired_value) {
                sleep 0.3;
                $got_sync = 0;
                next;
            } else {
                $got_sync = 1;
                last;
            }
        }
        if (0 == $got_sync) {
            say("ERROR: waitForNodeSync: Node " . ($i + 1) . " is not '$desired_value' even " .
                "after $wait_timeout" . "s waiting.");
            return DBSTATUS_FAILURE;
        }
    }
    return DBSTATUS_OK;
}

sub stopServer {
    my ($self) = @_;

    foreach my $i (0..$self->[GALERA_MYSQLD_NODE_COUNT]-1) {
        $self->nodes->[$i]->stopServer;
    }
    return DBSTATUS_OK;
}

1;
