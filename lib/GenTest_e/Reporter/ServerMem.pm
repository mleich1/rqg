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

package GenTest_e::Reporter::ServerMem;


# Linux only

require Exporter;
@ISA = qw(GenTest_e::Reporter);

use strict;
use GenTest_e;
use GenTest_e::Constants;
use GenTest_e::Result;
use GenTest_e::Reporter;
use GenTest_e::Executor::MySQL;

use DBI;

my $who_am_i = "Reporter 'ServerMem':";
my $start_rss;

sub monitor {
	my $reporter = shift;

    my $server_pid = $reporter->serverInfo('pid');
    my $command    = "ps -p $server_pid -o rss | tail -1";

	my $current_rss = `$command`;
    if (not defined $current_rss) {
        say("ERROR: $who_am_i: Measuring the DB Server process RSS failed.");
        exit STATUS_INTERNAL_ERROR;
    } else {
        say("$who_am_i DB Server process RSS : $current_rss");
        if (not defined $start_rss) {
            $start_rss = $current_rss ;
        } else {
            if ( $current_rss > 2 * $start_rss ) {
                say("ERROR: $who_am_i: DB Server process RSS has doubled.");
                kill '-KILL', $server_pid;
                say("INFO: $who_am_i: SIGKILL of DB Server process initiated.");
                exit STATUS_RSS_DOUBLED;
            }
        }
    }

	return STATUS_OK;
}

sub type {
    return REPORTER_TYPE_PERIODIC ;
}

1;
