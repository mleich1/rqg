# Copyright (c) 2008,2011 Oracle and/or its affiliates. All rights reserved.
# Copyright (C) 2021 MariaDB Corporation Ab
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

package GenTest::Reporter::QueryTimeout1;

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use DBI;
use GenTest;
use GenTest::Constants;
use GenTest::Reporter;
use GenTest::Executor::MySQL;

use constant PROCESSLIST_CONNECTION_ID          => 0;
use constant PROCESSLIST_PROCESS_TIME           => 5;
use constant PROCESSLIST_PROCESS_STATE          => 6;
use constant PROCESSLIST_PROCESS_INFO           => 7;

# Default minimum lifetime for a query before it is killed
use constant DEFAULT_QUERY_LIFETIME_THRESHOLD   => 30;    # Seconds

# The query lifetime threshold is configurable via properties.
# We check this once and store the value (or the default) in this variable.
my $q_l_t;

my $who_am_i = "Reporter 'QueryTimeout':";

my $executor;

sub monitor {
    my $reporter = shift;

    my $status = STATUS_OK;
    my $dsn    = $reporter->dsn();

    if (not defined $q_l_t) {
        # We only check the querytimeout option the first time the reporter runs
        $q_l_t = DEFAULT_QUERY_LIFETIME_THRESHOLD;
        $q_l_t = $reporter->properties->querytimeout
            if defined $reporter->properties->querytimeout;
        my $factor      = Runtime::get_runtime_factor();
        my $final_q_l_t = int($q_l_t * $factor);
        say("INFO: $who_am_i Will use query timeout threshold of " . $q_l_t .
            "s * $factor --> " . $final_q_l_t . "s.");
        $q_l_t = $final_q_l_t;
    }

    if (not defined $executor) {
        $executor = GenTest::Executor->newFromDSN($dsn);
        # Set the number to which server we will connect.
        # This number is
        # - used for more detailed messages only
        # - not used for to which server to connect etc. There only the dsn rules.
        # Hint:
        # Server id reported: n ----- dsn(n-1) !
        $executor->setId(1);
        $executor->setRole("QueryTimeout2");
        $executor->setTask(GenTest::Executor::EXECUTOR_TASK_REPORTER);
        $status = $executor->init();
        return $status if $status != STATUS_OK;
    }

    # Going with an executor and $executor->execute($query) should ensure that we
    # - are protected against low values of max-statement-time
    # - get trace additions like /* E_R QueryTimeout2 QNO 188 CON_ID 52 */ for any statement
    # - get sql tracing if enabled
    # - get connect timeouts * factor (rr/valgrind)

    # system("killall -9 mysqld");
    my $query = "SHOW FULL PROCESSLIST";
    my $res   = $executor->execute($query);
    $status   = $res->status;
    if (STATUS_OK != $status) {
        my $err    = $res->err;
        my $errstr = $res->errstr;
        # I have doubts if the status from $res is that useful.
        $status = STATUS_CRITICAL_FAILURE;
        say("ERROR: $who_am_i Query ->" . $query . "<- failed with $err : $errstr " .
            Auxiliary::build_wrs($status));
        return $status;
    }

    # It must be ensured that the KILL does not attack
    # - non worker threads like Reporter
    # - worker threads before finishing *_init or *_connect (not yet implemented)
    # This means the comment inside of the statement needs to look like
    #    '/* E_R Thread<number> QNO <number> CON_ID <number> */'
    my $processlist = $res->data;
    foreach my $process (@$processlist) {
        $status = STATUS_OK;
        # PROCESSLIST_PROCESS_INFO could be NULL and the value here is than undef.
        my $process_info = $process->[PROCESSLIST_PROCESS_INFO];
        if (defined $process_info and $process_info ne '') {
            # say("DEBUG: PROCESSLIST_PROCESS_INFO ->" . $process_info . "<-");

            # Omit sessions which are not a worker thread.
            next if not $process_info =~ m{ E_R Thread\d+ QNO };
            # Omit sessions which are in a too early phase of work.
            next if $process_info =~ m{ E_R Thread\d+ QNO 0 };

            my $process_time   = $process->[PROCESSLIST_PROCESS_TIME];
            my $process_con_id = $process->[PROCESSLIST_CONNECTION_ID];
            if ($process_time > $q_l_t + 100) {
                # Query survived QUERY_LIFETIME + 100 seconds.
                # If QUERY_LIFETIME_THRESHOLD is 20, and reporter interval is
                # 10 seconds, this means query survived more than 120 seconds and
                # 10 attempted KILL QUERY attempts. This looks like a mysqld issue.
                # Hence, we now try killing the whole thread instead.
                say("$who_am_i Query: ->" . $process_info . "<- took more than " .
                    ($q_l_t + 100) . " seconds ($q_l_t + 100). Killing thread.");

                # system("killall -9 mysqld");
                $query = "KILL /*! SOFT */ " . $process_con_id;
                $res = $executor->execute("$query");
                $status = $res->status;
                if (STATUS_OK != $status) {
                    my $err    = $res->err;
                    if (1094 == $err) {
                        # Observation 2020-12 post execution sqltrace, certain entries deleted
                        # [1113] KILL /*! SOFT */ QUERY 49 /* E_R QueryTimeout2 QNO 46 CON_ID 52 */ ;
                        # ... SHOW FULL PROCESSLIST ...
                        # [1113] KILL /*! SOFT */ QUERY 49 /* E_R QueryTimeout2 QNO 81 CON_ID 52 */ ;
                        # ....
                        # [1113] SHOW FULL PROCESSLIST /* E_R QueryTimeout2 QNO 179 CON_ID 52 */ ;
                        # [1113] [sqltrace] ERROR 1094: KILL /*! SOFT */ QUERY 49 /* E_R QueryTimeout2 QNO 188 CON_ID 52 */ ;
                        # ER_NO_SUCH_THREAD 1094
                        # == The first kill attempt QNO 46 showed its impact just between the
                        #    last SHOW FULL PROCESSLIST and now.
                        next;
                    } else {
                        my $errstr = $res->errstr;
                        $status    = STATUS_CRITICAL_FAILURE;
                        say("ERROR: $who_am_i Query ->" . $query . "<- failed with $err : $errstr " .
                            Auxiliary::build_wrs($status));
                        return $status;
                    }
                }
            } elsif ($process_time > $q_l_t) {
                say("$who_am_i Query: ->" . $process_info . "<- took more than " .
                    ($q_l_t) . " seconds. Killing query.");

                $query = "KILL /*! SOFT */ QUERY " . $process_con_id;
                $res    = $executor->execute("$query");
                $status = $res->status;
                if (STATUS_OK != $status) {
                    my $err    = $res->err;
                    if (1094 == $err) {
                        # See above
                        next;
                    } else {
                       my $errstr = $res->errstr;
                       $status = STATUS_CRITICAL_FAILURE;
                       say("ERROR: $who_am_i Query ->" . $query . "<- failed with $err : $errstr " .
                           Auxiliary::build_wrs($status));
                       return $status;
                    }
                }
            }
        }
    }

    return STATUS_OK;
}

sub type {
    return REPORTER_TYPE_PERIODIC;
}

1;
