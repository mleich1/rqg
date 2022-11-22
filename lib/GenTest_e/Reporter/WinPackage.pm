# Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
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

package GenTest_e::Reporter::WinPackage;

require Exporter;
@ISA = qw(GenTest_e::Reporter);

use strict;
use File::Copy;
use GenTest_e;
use GenTest_e::Constants;
use GenTest_e::Reporter;

sub report {
	my $reporter = shift;
	my $bindir = $reporter->serverInfo('bindir');
	my $datadir = $reporter->serverVariable('datadir');
	$datadir =~ s{[\\/]$}{}sgio;

	if (osWindows()) {
		foreach my $file ('mysqld.exe', 'mysqld.pdb') {
			my $old_loc = $bindir.'\\'.$file;
			my $new_loc = $datadir.'\\'.$file;
			say("Copying $old_loc to $new_loc .");
			copy($old_loc, $new_loc);
		}
	}
	
	return STATUS_OK;
}

sub type {
	return REPORTER_TYPE_CRASH | REPORTER_TYPE_DEADLOCK ;
}

1;
