# Copyright (c) 2013, 2017 MariaDB
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


#################
# Goal: Check server behavior on restart after a crash.
# 
# The reporter crashes the server and immediately restarts it.
# The test (runall-new) must be run with --restart-timeout=N to wait
# till the server is up again.
#################

package GenTest_e::Reporter::CrashRestart;

require Exporter;
@ISA = qw(GenTest_e::Reporter);

use strict;
use DBI;
use GenTest_e;
use GenTest_e::Constants;
use GenTest_e::Reporter;
use GenTest_e::Reporter::Restart;

use DBServer_e::MySQL::MySQLd;

my $first_reporter;
my $restart_count= 0;

sub monitor {
  my $self= shift;
  GenTest_e::Reporter::Restart::monitor($self,0);
}

sub type {
	return REPORTER_TYPE_PERIODIC;
}


1;

