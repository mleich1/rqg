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

package GenTest_e::Reporter::MemoryUsage;

require Exporter;
@ISA = qw(GenTest_e::Reporter);

use strict;
use GenTest_e;
use GenTest_e::Constants;
use GenTest_e::Result;
use GenTest_e::Reporter;
use GenTest_e::Executor::MySQL;

use DBI;

sub monitor {
	my $reporter = shift;

	system('ps -Ffyl -p '.$reporter->serverInfo('pid'));

	my $dsn = $reporter->dsn();
	my $dbh = DBI->connect($dsn);

	if (defined $dbh) {
		my ($total_rows, $total_data, $total_indexes) = $dbh->selectrow_array("
			SELECT SUM(TABLE_ROWS) , SUM(DATA_LENGTH) , SUM(INDEX_LENGTH)
			FROM INFORMATION_SCHEMA.TABLES
			WHERE TABLE_SCHEMA NOT IN ('information_schema','mysql','performance_schema')
		");

		say("Total_rows: $total_rows; total_data: $total_data; total_indexes: $total_indexes");	
	}

	return STATUS_OK;
}

sub type {
        return REPORTER_TYPE_PERIODIC ;
}

1;
