# Copyright (c) 2008,2012 Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2013 Monty Program Ab
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

package GenTest_e::Reporter::Shutdown;

require Exporter;
@ISA = qw(GenTest_e::Reporter);

use strict;
use DBI;
use GenTest_e;
use GenTest_e::Constants;
use GenTest_e::Reporter;
use Data::Dumper;
use IPC::Open2;
use IPC::Open3;

use DBServer_e::MySQL::MySQLd;

sub report {
    if (defined $ENV{RQG_CALLBACK}) {
        say "Shutdown reporter should not be used in callback environments (E.g. JET)";
        return STATUS_OK;
    }
    my $reporter = shift;

    my $primary_port = $reporter->serverVariable('port');

    my $mysqladmin_path =
         DBServer_e::MySQL::MySQLd->_find([$reporter->serverVariable('basedir')],
                                        ['client','bin','client/debug','client/relwithdebinfo'],
                                        'mysqladmin','mysqladmin.exe');

    for (my $port = $primary_port + 9; $port >= $primary_port; $port--) {
        my $dsn = "dbi:mysql:host=127.0.0.1:port=".$port.":user=root";
        my $dbh = DBI->connect($dsn, undef, undef, { PrintError => 0 } );
        my $mysqladmin_shutdown = "$mysqladmin_path -uroot --port=$port --protocol=tcp --silent shutdown";

        my $pid;
        if ($port == $primary_port) {
            $pid = $reporter->serverInfo('pid');
        } elsif (defined $dbh) {
            my ($pid_file) = $dbh->selectrow_array('SELECT @@pid_file');
            if (open (PF, $pid_file)) {
                read (PF, $pid, -s $pid_file);
                close (PF);
                $pid =~ s{[\r\n]}{}sio;
            } else {
                say("Unable to obtain pid: $!");
            }
        }

        if (defined $dbh) {
            say("Shutting down server on port $port via DBI...");
            $dbh->func('shutdown', 'admin');
        }

        if (defined $dbh) {
            say("Also trying mysqladmin: $mysqladmin_shutdown");
            system("$mysqladmin_shutdown");
        }

        if (defined $pid) {
            say("Shutting down server with pid $pid with SIGTERM...");
            kill(15, $pid);

            if (!osWindows()) {
                say("Waiting for mysqld with pid $pid to terminate...");
                foreach my $i (1..60) {
                    if (! -e "/proc/$pid") {
                        print "\n";
                        last;
                    }
                    sleep(1);
                    print "+";
                }
                say("... waiting complete. Just in case, killing server with pid $pid with SIGKILL ...");
                kill(9, $pid);
            }
        }
    }
    return STATUS_OK;
}

sub type {
    return REPORTER_TYPE_ALWAYS;
}

1;
