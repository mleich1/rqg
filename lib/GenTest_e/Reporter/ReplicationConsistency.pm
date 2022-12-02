# Copyright (c) 2013, Monty Program Ab.
# Copyright (c) 2020, 2022 MariaDB Corporation Ab.
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

package GenTest_e::Reporter::ReplicationConsistency;

# (mleich1):
# Warning: The code might be biased to 10.11.
# IMHO this reporter should be replaced by some code to be executed by the RQG runner
# after finishing GenTest with success.

require Exporter;
@ISA = qw(GenTest_e::Reporter);

use strict;
use DBI;
use GenTest_e;
use GenTest_e::Constants;
use GenTest_e::Reporter;

my $reporter_called = 0;

$| = 1;

sub report {
	my $reporter = shift;
    my $who_am_i = "Reporter 'ReplicationConsistency':";

	return STATUS_WONT_HANDLE if $reporter_called == 1;
	$reporter_called = 1;

	my $master_dbh = DBI->connect($reporter->dsn(), undef, undef, {
                          mysql_connect_timeout  => Runtime::get_connect_timeout(),
                          PrintError             => 0});
      say("DEBUG: $who_am_i master dsn ->" . $reporter->dsn() . "<-");
    # system('kill -9 $SERVER_PID2; sleep 5');
    if (not defined $master_dbh) {
        my $status = STATUS_CRITICAL_FAILURE;
        say("ERROR: $who_am_i Connect to master failed. " . $DBI::errstr .
            " Will return status " . status2text($status) . " ($status)\n");
        return $status;
    }
	my $master_port = $reporter->serverVariable('port');
	my $slave_port;

    # FIXME: Can't call method "selectrow_arrayref" on an undefined value at lib/GenTest_e/Reporter/ReplicationConsistency.pm line 43, <CONF> line 72
	my $slave_info = $master_dbh->selectrow_arrayref("SHOW SLAVE HOSTS");
    # SHOW SLAVE HOSTS;  MTR example output
    # Server_id   Host    Port    Master_id
    # 3   slave2  SLAVE_PORT  1
    # 2   localhost   SLAVE_PORT  1
	if (defined $slave_info) {
		$slave_port = $slave_info->[2];
	} else {
		$slave_port = $master_port + 2;
        say("DEBUG: $who_am_i \$slave_info was undef. Guessing? slave_port $slave_port");
	}

    #   my $slave_dsn = "dbi:mysql:host=127.0.0.1:port=".$slave_port.":user=root";
    my $slave_dsn = "dbi:mysql:host=127.0.0.1:port=".$slave_port.":user=root:database=test";
      say("DEBUG: $who_am_i slave dsn ->" . $slave_dsn . "<-");
    my $slave_dbh = DBI->connect($slave_dsn, undef, undef, {
                         mysql_connect_timeout  => Runtime::get_connect_timeout(),
                         PrintError             => 1 } );
    if (not defined $slave_dbh) {
        my $status = STATUS_CRITICAL_FAILURE;
        say("ERROR: $who_am_i Connect to slave failed. " . $DBI::errstr .
            " Will return status " . status2text($status) . " ($status)\n");
        return $status;
    }

	$slave_dbh->do("START SLAVE");

	#
	# We call MASTER_POS_WAIT at 100K increments in order to avoid buildbot timeout in case
	# one big MASTER_POS_WAIT would take more than 20 minutes.
	#

	my $sth_binlogs = $master_dbh->prepare("SHOW BINARY LOGS");
	$sth_binlogs->execute();
	while (my ($intermediate_binlog_file, $intermediate_binlog_size) = $sth_binlogs->fetchrow_array()) {
		my $intermediate_binlog_pos = $intermediate_binlog_size < 10000000 ? $intermediate_binlog_size : 10000000;
		do {
            my $query = "SELECT MASTER_POS_WAIT('$intermediate_binlog_file', " .
                        "$intermediate_binlog_pos)";
			say("DEBUG: $who_am_i Executing intermediate $query");
			my $intermediate_wait_result = $slave_dbh->selectrow_array($query);
			if (not defined $intermediate_wait_result) {
				say("ERROR: $who_am_i Intermediate $query failed in slave on port $slave_port. " .
                    $slave_dbh->errstr() . " Slave replication thread not running.");
				return STATUS_REPLICATION_FAILURE;
			}
			$intermediate_binlog_pos += 10000000;
	        } while (  $intermediate_binlog_pos <= $intermediate_binlog_size );
	}

        my ($final_binlog_file, $final_binlog_pos) = $master_dbh->selectrow_array("SHOW MASTER STATUS");

	say("Executing final MASTER_POS_WAIT('$final_binlog_file', $final_binlog_pos.");
	my $final_wait_result = $slave_dbh->selectrow_array("SELECT MASTER_POS_WAIT('$final_binlog_file',$final_binlog_pos)");

	if (not defined $final_wait_result) {
		say("Final MASTER_POS_WAIT('$final_binlog_file', $final_binlog_pos) failed in slave on port $slave_port. Slave replication thread not running.");
		return STATUS_REPLICATION_FAILURE;
	} else {
		say("Final MASTER_POS_WAIT('$final_binlog_file', $final_binlog_pos) complete.");
	}

	my @all_databases = @{$master_dbh->selectcol_arrayref("SHOW DATABASES")};
	my $databases_string = join(' ', grep { $_ !~ m{^(rqg|mysql|information_schema|performance_schema)$}sgio } @all_databases );
	
	my @dump_ports = ($master_port , $slave_port);
	my @dump_files;

	foreach my $i (0..$#dump_ports) {
		say("Dumping server on port $dump_ports[$i]...");
		$dump_files[$i] = tmpdir()."/server_".abs($$)."_".$i.".dump";
		my $dump_result = system('"'.$reporter->serverInfo('client_bindir')."/mysqldump\" --hex-blob --no-tablespaces --skip-triggers --compact --order-by-primary --skip-extended-insert --no-create-info --host=127.0.0.1 --port=$dump_ports[$i] --user=root --password='' --databases $databases_string | sort > $dump_files[$i]");
		return STATUS_ENVIRONMENT_FAILURE if $dump_result > 0;
	}

	say("Comparing SQL dumps between servers on ports $dump_ports[0] and $dump_ports[1] ...");
	my $diff_result = system("diff -u $dump_files[0] $dump_files[1]");
	$diff_result = $diff_result >> 8;

	foreach my $dump_file (@dump_files) {
		unlink($dump_file);
	}

	if ($diff_result == 0) {
		say("No differences were found between servers.");
		return STATUS_OK;
	} else {
		say("Servers have diverged.");
		return STATUS_REPLICATION_FAILURE;
	}
}

sub type {
	return REPORTER_TYPE_SUCCESS;
}

1;
