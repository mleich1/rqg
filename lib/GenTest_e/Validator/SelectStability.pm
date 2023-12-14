# Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
# Copyright (C) 2022 MariaDB Corporation Ab.
# Copyright (C) 2023 MariaDB plc
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

# The latest changes to this validator belong to
#   TODO-3508 Search for a way to test in RQG that the ANSI SQL Isolation Levels is followed
# The goal is to make the validator so robust against difficult events like
# - STATUS_SKIP
# - whatever timeouts kick in, a deadlock gets detected and resolved
# - kill of the query or the session
# - the current ISOLATION LEVEL is neither REPEATABLE READ nor SERIALIZABLE
# - SELECTs on information_schema or functions like NOW()
# - we run currently with autocommit = 1
# so that the validator can be used for a far way broader range of tests.
# The validator is currently experimental.
# Hence sorry for false alarms.
#
# Ideas and observations
# ======================
# 1. Repeating a statement which
#    - modified data content, the layout of tables, the existence of objects etc.
#    and
#    - passed
#    and than somehow comparing to the first execution does not make
#    much sense because there is a high risk that the second execution fails
#    because of justified reason.
#    Example: INSERT INTO ... SET pk_columns = 1 --> Pass
#             INSERT INTO ... SET pk_columns = 1 --> Duplicate ....
# 2. If hitting a semantic error than a repetition could hit the same error in case
#    - we run DDL
#      Example: ALTER TABLE ... --> Table does not exist
#               ALTER TABLE ... --> Table does not exist
#    - we are in the same transaction
#      Example: SELECT col1 FROM ... --> Column col1 does not exist
#               SELECT col1 FROM ... --> Column col1 does not exist
#    But this could fail in case
#    - there is concurrent DDL which changes the existence of a table or its layout
#      Example: DELETE FROM ... --> Table does not exist
#               DELETE FROM ... --> Table exists          is allowed
#    - we hit a timeout, deadlock, the query or seeion gets killed ...
# 3. DDL gets done or fails and than we have a new transaction.
#    Hence repeating DDLs makes no sense.
#    Observation for ALTER TABLE t4 DROP PRIMARY KEY, ADD PRIMARY KEY ....
#    First execution: 1062:  Duplicate entry '%s' for key '%s'
#    Second execution: 1146: Table '%s' doesn't exist
#    Reason: A concurrent session run RENAME TABLE t4 TO cool_down.t4.
#    Thinkable solution:
#    Let the validator rely on the number of RQG sessions.
#    Problem: This can fail in case EVENTs are active.
# 4. If $compare_outcome > STATUS_OK than check if the ISOLATION LEVEL is
#    READ UNCOMMITTED or READ COMMITTED.
#    If yes than report STATUS_OK because we have not found some obvious error.
#    Hint: Most tests will set nothing and get the default for InnoDB: REPEATABLE READ
#    Q: What happens around SELECTs on informationschema and concurrent ALTER?
# 5. AFAIR there was a case where a DELETE FROM ... without WHERE or LIMIT passed but
#    a later SELECT within the same transaction found rows in that table.
#    Thinkable solution:
#    Run a few seconds after some passing DELETE FROM ... without WHERE or LIMIT
#    some SELECT COUNT(*) and expect 0 if ISO LEVEL SERIALIZABLE.
#    Maybe go with DELETE WHERE ... --> SELECT COUNT(*) same WHERE
# 6. Any second or third query could
#    - get attacked by KILL QUERY or SESSION emitted by some concurrent session
#    - fail because of some timeout like max_statement_time, MDL timeout ...
#    - deadlock ...
#    - be omitted by the Executor because the planned GenTest_e duration is exceeded.
#      Than we get a result with STATUS_SKIP and undef err, data, ...
#    All that must be handled here.
# 7. SET system_variable
#    Better do not repeat that.
#    I fear it could
#    - end a transaction
#    - start something running asynchronous and the repetition gets denied because its
#      already ongoing
#    - get denied because we already have that state/value/...
#    In addition setting a system variable is rather out of scope of the current validator.
# 8. Observed:
#    First CHECK TABLE with no error ($err) and result set says all ok.
#    Second CHECK TABLE with no error ($err) and result set says that the query was interruptet.
#

package GenTest_e::Validator::SelectStability;

require Exporter;
@ISA = qw(GenTest_e::Validator GenTest_e);

use strict;

use GenTest_e;
use GenTest_e::Comparator;
use GenTest_e::Constants;
use GenTest_e::Result;
use GenTest_e::Validator;
use Time::HiRes;

my $who_am_i =   "Validator 'SelectStability':";
my $debug_here = 0;

sub validate {
    my ($validator, $executors, $results) = @_;

    my $executor =    $executors->[0];
    my $orig_result = $results->[0];
    my $orig_query =  $orig_result->query();
    my $orig_err =    $orig_result->err();
    my $orig_data =   $orig_result->data();
    my $orig_status = $orig_result->status();
    my $orig_info =   result_info($orig_result);
    say("DEBUG: $who_am_i " . $orig_info) if $debug_here;

    # We could harvest STATUS_SKIP in case the executor gives up because the planned duration
    # of the GenTest_e phase is exceeded. I am unsure if the validator would be than called at all.
    if (STATUS_SKIP == $orig_status) {
        my $status = STATUS_OK;
        say("DEBUG: $who_am_i STATUS_SKIP got in first query. " .
            Basics::return_status_text($status)) if $debug_here;
        return $status;
    }

    # SET TRANSACTION ISOLATION LEVEL changes the ISOLATION LEVEL for the next transaction A.
    # In case we are than in A its impossible to determine the ISOLATION LEVEL which is than valid.
    # @@tx_isolation shows all time the ISOLATION LEVEL for the session which will be valid after
    # A ended.
    # Solution: Abort the test but do not claim to have met an error.
    if ($orig_query =~ m{SET\s*\n*\r*TRANSACTION\s*\n*\r*ISOLATION}io) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i The query ->$orig_query<- was met.\n" .
            "ERROR: $who_am_i It creates conditions the " . "validator cannot handle.\n" .
            "ERROR: $who_am_i " . Basics::exit_status_text($status));
        exit $status;
    }
    # No repeat for
    # - non DML statements because
    #   - a high fraction of them (DDL, COMMIT,...) end the old transaction and start a new one.
    #     The ISOLATION LEVEL is just not in scope.
    #   - even the repetition of some semantic error is unsure because there might be a session
    #     running concurrent DDL
    # - DML statements which modify data with success because of the risk of
    #   First: Insert with success
    #   Second: duplicate key or .....
    # - DML which failed at all
    #   - temporary condition: deadlock, timeout, max_statement_time, kill by other session ...
    #     First: get killed, no result set
    #     Second: success, get a result set
    #   - semantic error which remains only valid till some DDL statement issued by some
    #     concurrent session changes the object
    #     First: ... unknown column
    #     Second: Get a result set or duplicate key or other unknown column or ...
    #     Checking if some DML harvesting some semantic error repeats the same way in case there
    #     is no concurrent session or EVENT or .... is thinkable. But implementing that would be
    #     expensive and its very unlikely that this catches ever a bug.
    #
    # ==> Repeat only SELECTs which harvested success on the first execution

    if ($orig_query !~ m{^\s*select}io) {
        my $status = STATUS_OK;
        say("DEBUG: $who_am_i No repetition for ->$orig_query<- which is not a SELECT. " .
            Basics::return_status_text($status)) if $debug_here;
        return $status;
    }
    if ($orig_query =~ m{Information_schema}io) {
        my $status = STATUS_OK;
        say("DEBUG: $who_am_i No repetition for ->$orig_query<- which contains " .
            "'Information_schema'. " . Basics::return_status_text($status)) if $debug_here;
        return $status;
    }
    if ($orig_query =~ m{Performance_schema}io) {
        my $status = STATUS_OK;
        say("DEBUG: $who_am_i No repetition for ->$orig_query<- which contains " .
            "'Performance_schema'. " . Basics::return_status_text($status)) if $debug_here;
        return $status;
    }
    # We cannot intercept all dangerous functions. But at least some frequent used.
    if ($orig_query =~ m{now\s*()}io or $orig_query =~ m{UNIX_TIMESTAMP\s*()}io) {
        my $status = STATUS_OK;
        say("DEBUG: $who_am_i No repetition for ->$orig_query<- which contains a " .
            "current time related function. " . Basics::return_status_text($status)) if $debug_here;
        return $status;
    }

    if (defined $orig_err and $orig_err > 0) {
        my $status = STATUS_OK;
        say("DEBUG: $who_am_i No repetition for ->$orig_query<- which harvested $orig_err. " .
            Basics::return_status_text($status)) if $debug_here;
        return $status;
    }

    if (not defined $orig_result->data()) {
        my $status = STATUS_OK;
        # Sample: SELECT .... INTO @user_variable
        say("DEBUG: $who_am_i ->$orig_query<- harvested no error and undef data. " .
            Basics::return_status_text($status)) if $debug_here;
        return $status;
    }

    my $aux_query =  'SELECT @@autocommit /* Validator */';
    my $aux_result = $executor->execute($aux_query);
    my $aux_err =    $aux_result->err();
    my $aux_data =   $aux_result->data();
    my $aux_status = $aux_result->status();
    my $aux_info =   result_info($aux_result);
    say("DEBUG: $who_am_i " . $aux_info) if $debug_here;

    if (STATUS_OK != $aux_status) {
        my $msg_snip = "DEBUG: $who_am_i ->" . $aux_query . "<- harvested status $aux_status. ";
        if      (STATUS_SKIP == $aux_status) {
            my $status = STATUS_OK;
            say($msg_snip . Basics::return_status_text($status)) if $debug_here;
            return $status;
        } elsif (STATUS_SERVER_CRASHED == $aux_status) {
            my $status = STATUS_CRITICAL_FAILURE;
            say($msg_snip . Basics::return_status_text($status)) if $debug_here;
            return $status;
        } else {
            say($msg_snip . "Will return that.");
            return $aux_status;
        }
    }

    # ????
    if (defined $aux_err) {
        # Being victim of
        # - KILL QUERY/SESSION .... or whatever.
        # - server crash
        # makes a difference.
        # Return $aux_status?
        my $status = STATUS_OK;
        say("DEBUG: $who_am_i ->" . $aux_query . "<- harvested $aux_err. " .
            Basics::return_status_text($status)) if $debug_here;
        return $status;
    }

    my $autocommit = $aux_data->[0]->[0];
    if (not defined $autocommit) {
        say("ERROR: $who_am_i \$autocommit is undef.");
        say("DEBUG: $who_am_i Outcome of ->" . $aux_query . "<-");
        say("DEBUG: $who_am_i aux_status $aux_status");
        say("DEBUG: $who_am_i aux_info $aux_info");
        exit STATUS_INTERNAL_ERROR;
    }
    say("DEBUG: $who_am_i autocommit is ->" . $autocommit . "<-") if $debug_here;
    if (1 eq $autocommit ) {
        # We are in a new transaction.
        return STATUS_OK;
    }

    # Left over should be:
    # Statement == SELECT and having success and autocommit=0

    foreach my $delay (0, 0.01, 0.1) {
        Time::HiRes::sleep($delay);
        my $new_result = $executor->execute($orig_query);
        # Some note about SQL tracing
        # ---------------------------
        # The repeated query contains than two marker like
        #     /* E_R Thread3 QNO 3 CON_ID 17 */  /* E_R Thread3 QNO 4 CON_ID 17 */

        # We could harvest STATUS_SKIP (~= query was not executed) in case the executor gives up
        # because the intended duration of the GenTest_e phase is already exceeded.
        # Its a bit unclear if the validator would be than called at all.
        if (STATUS_SKIP == $new_result->status()) {
            my $status = STATUS_OK;
            say("DEBUG: $who_am_i Repeated query ->" . $orig_query . "<- got STATUS_SKIP. " .
                Basics::return_status_text($status)) if $debug_here;
            return $status;
        }

        my $new_err =    $new_result->err();
        my $new_data =   $new_result->data();
        my $new_status = $new_result->status();
        my $new_info =   result_info($new_result);

        say("DEBUG: $who_am_i " . $new_info) if $debug_here;
        if (defined $new_err) {
            if (1317 == $new_err or   # ER_QUERY_INTERRUPTED
                1205 == $new_err or   # ER_LOCK_WAIT_TIMEOUT: Lock wait timeout exceeded
                1213 == $new_err or   # ER_LOCK_DEADLOCK
                2006 == $new_err or   # CR_SERVER_GONE_ERROR
                2013 == $new_err      # CR_SERVER_LOST
                                    ) {
                my $status = STATUS_OK;
                say("DEBUG: $who_am_i Repeated query ->" . $orig_query . "<- harvested $new_err. " .
                    Basics::return_status_text($status)) if $debug_here;
                return $status;
            } else {
                say("ERROR: $who_am_i Repeated query ->" . $orig_query .
                    "<- harvested $new_err instead of undef.");
                kill_server();
            }
        }

        if (not defined $orig_result->data() and defined $new_result->data()) {
            say("ERROR: $who_am_i Repeated query ->" . $orig_query .
                "<- harvested data instead of undef.");
            kill_server();
        } elsif (defined $orig_result->data() and not defined $new_result->data()) {
            say("ERROR: $who_am_i Repeated query ->" . $orig_query .
                "<- harvested undef instead of data.");
            kill_server();
        }

        # no data -> no comparison
        next if not defined $new_result->data();

        my $compare_outcome = GenTest_e::Comparator::compare($orig_result, $new_result);
        if ($compare_outcome > STATUS_OK) {
            # SQL tracing ?
            # say("DEBUG: Experiment: SIGKILL FOR THE SERVER");
            # system("killall -9 mysqld; sleep 1");

            my $aux_query = 'SELECT @@tx_isolation /* Validator */';
            my $aux_result = $executor->execute($aux_query);
            my $aux_err =    $aux_result->err();
            my $aux_data =   $aux_result->data();
            my $aux_status = $aux_result->status();
            my $aux_info =   result_info($aux_result);
            say("DEBUG: $who_am_i " . $aux_info) if $debug_here;

            if (defined $aux_err) {
                # Being victim of
                # - KILL QUERY/SESSION .... or whatever.
                # - server crash
                # makes a difference.
                # Return $aux_status?
                my $status = STATUS_OK;
                say("DEBUG: $who_am_i ->" . $aux_query . "<- harvested $aux_err. " .
                    Basics::return_status_text($status)) if $debug_here;
                return $status;
            }

            my $txiso_level = $aux_data->[0]->[0];
            say("DEBUG: $who_am_i ISO LEVEL IS is ->" . $txiso_level . "<-") if $debug_here;
            if ('READ-COMMITTED' eq $txiso_level or
                'READ-UNCOMMITTED' eq $txiso_level) {
                # It cannot be 100% excluded that the result diff is caused by a bug of server
                # and/or storage engine. But its very likely that the diff is caused by the
                # ISO Level .
                return STATUS_OK;
            }

            say("ERROR: $who_am_i The query ->" . $orig_query . "<- returns a different result " .
                "when executed after a delay of $delay seconds.");
            say(GenTest_e::Comparator::dumpDiff($orig_result, $new_result));
            kill_server();
        }
    }

    return STATUS_OK;
}

sub kill_server {
    my $status = STATUS_DATABASE_CORRUPTION;
    say("ERROR: $who_am_i Will kill the server with SIGABRT and exit with " .
        "STATUS_DATABASE_CORRUPTION");
    system('kill -6 $SERVER_PID1');
    exit $status;
}

sub result_info {
    my ($result) = @_;
    my $query =  $result->query();
    my $err =    $result->err();
    my $data =   $result->data();
    my $status = $result->status();

    my $result_info;
    if (defined $query) {
        $result_info = "Query ->" . $query . "<- ";
    } else {
        $result_info = "Query -><undef><- ";
    }
    if (defined $err) {
        $result_info .= ", err: " . $err;
    } else {
        $result_info .= ", err: <undef>";
    }
    if (defined $data) {
        $result_info .= ", data: <def>";
    } else {
        $result_info .= ", data: <undef>";
    }
    if (defined $status) {
        $result_info .= ", status: " . $status;
    } else {
        $result_info .= ", status: <undef>";
    }
}

1;
