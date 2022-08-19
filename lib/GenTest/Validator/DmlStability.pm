# Copyright (C) 2022 MariaDB Corporation Ab
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

# This validator
# - belongs to
#   TODO-3508 Search for a way to test in RQG that the ANSI SQL Isolation Levels is followed
# - is inspired by the validator lib/GenTest/Validator/SelectStability.pm
# - is currently experimental.
# Hence sorry for false alarms.
#
# Ideas in arbitrary order and even maybe conflicting:
# 1. Repeating a statement which
#    - modified data content, the layout of tables, the existence of objects etc.
#    and
#    - passed
#    and than somehow comparing to the first execution does not make
#    much sense because there is a high risk that the second execution fails
#    because of justified reason.
#    Example: INSERT INTO ... SET pk_columns = 1 --> Pass
#             INSERT INTO ... SET pk_columns = 1 --> Duplicate ....
# 2. If hitting a semantic error than a repetition should hit the same error in case
#    - we are in the same transaction
#      Example: DELETE FROM ... --> Table does not exist
#               DELETE FROM ... --> Table does not exist
#    or
#    - we run DDL but there is zero concurrent activity.
#      Example: ALTER TABLE ... --> Table does not exist
#               ALTER TABLE ... --> Table does not exist
#    Q: What if the second query gets attacked by KILL QUERY or SESSION?
#       Is semantic error in first query and getting no access to metadata because of
#       ongoing ALTER or similar possible? And than which error will see the second query?
#
# 3. DDL gets done or fails and than we have a new transaction.
#    Hence repeating DDLs makes no sense.
#    Observation for ALTER TABLE t4 DROP PRIMARY KEY, ADD PRIMARY KEY ....
#    First execution: 1062:  Duplicate entry '%s' for key '%s'
#    Second execution: 1146: Table '%s' doesn't exist
#    Reason: A concurrent session run RENAME TABLE t4 TO cool_down.t4.
#    Thinkable solution:
#    Let the validator rely on the number of RQG sessions.
#    Problem: This can fail in case EVENTs are active.
#
# 4. If $compare_outcome > STATUS_OK than check if the ISOLATION LEVEL is
#    READ UNCOMMITTED or READ COMMITTED.
#    If yes than report STATUS_OK because we have not found some obvious error.
#    Hint: Most tests will set nothing and get the default for InnoDB: REPEATABLE READ
#    Q: What happens around SELECTs on informationschema and concurrent ALTER?
#
# 5. AFAIR there was a case where a DELETE FROM ... without WHERE or LIMIT passed but
#    a later SELECT within the same transaction found rows in that table.
#    Thinkable solution:
#    Run a few seconds after some passing DELETE FROM ... without WHERE or LIMIT
#    some SELECT COUNT(*) and expect 0 if ISO LEVEL SERIALIZABLE.
#    Maybe go with DELETE WHERE ... --> SELECT COUNT(*) same WHERE
#
# Some quarrel with maybe redundant or obsolete information.
# If the first SELECT harvested ER_NO_SUCH_TABLE or similar (missing or already existing
# SCHEMA, TABLE, VIEW).
#
#   ER_NO_SUCH_TABLE (1146): Table 'otto.t1' doesn't exist
#   SELECT * FROM otto . t1;
#   ER_NO_SUCH_TABLE (1146): Table 'test.t1' doesn't exist
#   SELECT * FROM t1;
#
#   ER_BAD_DB_ERROR (1049): Unknown database 'otto'
#   CREATE TABLE otto . t1 (col1 INT);
#
# CREATE TABLE t1 (col1 INT);
#   ER_TABLE_EXISTS_ERROR (1050): Table 't1' already exists
#   CREATE TABLE t1 (col1 INT);
#
#   ER_NO_SUCH_TABLE (1146): Table 'test.t2' doesn't exist
#   CREATE VIEW v2 AS SELECT * FROM t2;
#
#   ER_UNKNOWN_VIEW (4092): Unknown VIEW: 'test.v2'
#   DROP VIEW v2;
#
# CREATE VIEW v1 AS SELECT * FROM t1;
#   ER_TABLE_EXISTS_ERROR (1050): Table 'v1' already exists
#   CREATE VIEW v1 AS SELECT * FROM t1;
#
# ERROR 1846:  ALTER TABLE t3 MODIFY col_int BIGINT, ALGORITHM = INPLACE
# MariaDB error code 1054 (ER_BAD_FIELD_ERROR): Unknown column '%-.192s' in '%-.192s'
#
# DROP TABLE t1;
#   SELECT * FROM v1;
#   ER_VIEW_INVALID (1356): View 'test.v1' references invalid table(s) or column(s) or function(s) or definer/invoker of view lack rights to use them
#    Maybe do this even for INSERT, UPDATE, REPLACE.
#    ER_BAD_DB_ERROR (1049): Unknown database 'otto'
#    Q: What happens around concurrent permission changes?
# 3. Q: How to handle that the second and third statement hits a timeout or gets killed?
#
# KILL QUERY --> 1317 (ER_QUERY_INTERRUPTED) in affected session
# KILL [SESSION] --> 1317(ER_QUERY_INTERRUPTED),1053(ER_SERVER_SHUTDOWN),2006(CR_SERVER_GONE_ERROR),2013(CR_SERVER_LOST) in affected session
#                    1317 only if KILL own_session
#                    1053 is not relevant here
# 1. Never repeat KILL
# 2. A statement harvesting 1317, 1053, 2006 should be not repeated. Just return STATUS_OK.
#    A repeated statement harvesting 1317, 1053, 2006 should lead to returning STATUS_OK.
#
# SET system_variable
# Better do not repeat that.
# I fear it could
# - end a transaction
# - start something running asynchronous and the repetition gets denied because its already ongoing
# - get denied because we already have that state/value/...
# In addition setting a system variable is rather out of scope of the current validator.
#
# Observed:
# First CHECK TABLE with no error ($err) and result set says all ok.
# Second CHECK TABLE with no error ($err) and result set says that the query was interruptet.
#

package GenTest::Validator::DmlStability;

require Exporter;
@ISA = qw(GenTest::Validator GenTest);

use strict;

use GenTest;
use GenTest::Comparator;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Validator;
use Time::HiRes;

my $who_am_i = "Validator 'DmlStability':";

sub validate {
    my ($validator, $executors, $results) = @_;

    my $executor =    $executors->[0];
    my $orig_result = $results->[0];
    my $orig_query =  $orig_result->query();
    my $orig_err =    $orig_result->err();

    # FIXME: Recheck when we could get data undef. Empty result , error ?

    # Repeat DML statements only.
    if ($orig_query !~ m{^\s*select}io  or
        $orig_query !~ m{^\s*update}io  or
        $orig_query !~ m{^\s*delete}io  or
        $orig_query !~ m{^\s*replace}io   ) {
        return STATUS_OK;
    }

    if (not defined $orig_result->data()) {
        if (not defined $orig_err) {
            # Sample: An UPDATE harvesting success.
            say("DEBUG: $who_am_i ->$orig_query<- harvested undef error and undef data. Will return STATUS_OK.");
            return STATUS_OK;
        } else {
            if (
                1008 != $orig_err and   # ER_DB_DROP_EXISTS): Can't drop database '%-.192s'; database doesn't exist
                1048 != $orig_err and   # ER_BAD_NULL_ERROR (1048): Column '%-.192s' cannot be null
                1049 != $orig_err and   # ER_BAD_DB_ERROR (1049): Unknown database 'otto'
                1050 != $orig_err and   # ER_TABLE_EXISTS_ERROR (1050): Table 't1' already exists
                1051 != $orig_err and   # ER_BAD_TABLE_ERROR (1051): Unknown table '%-.100T'
                1054 != $orig_err and   # ER_BAD_FIELD_ERROR (1054): Unknown column
                1060 != $orig_err and   # ER_DUP_FIELDNAME (1060): Duplicate column name '%-.192s'
                1061 != $orig_err and   # ER_DUP_KEYNAME): Duplicate key name '%-.192s'
                1062 != $orig_err and   # ER_DUP_ENTRY (1062): Duplicate entry '%-.192T' for key %d
                1072 != $orig_err and   # ER_KEY_COLUMN_DOES_NOT_EXIST (1072): Key column '%-.192s' doesn't exist in table
                1068 != $orig_err and   # ER_MULTIPLE_PRI_KEY (1068): Multiple primary key defined
                1091 != $orig_err and   # ER_CANT_DROP_FIELD_OR_KEY (1091): Can't DROP %s %`-.192s; check that it exists
                1094 != $orig_err and   # ER_NO_SUCH_THREAD (1094) Unknown thread id: %lu   KILL ...
                1146 != $orig_err and   # ER_NO_SUCH_TABLE (1146): Table 'test.t1' doesn't exist
                1193 != $orig_err and   # ER_UNKNOWN_SYSTEM_VARIABLE): Unknown system variable '%-.*s'
                # 1213 != $orig_err and   # ER_LOCK_DEADLOCK): Deadlock found when trying to get lock; try restarting transaction  ????????????????
                1253 != $orig_err and   # ER_COLLATION_CHARSET_MISMATCH): COLLATION '%s' is not valid for CHARACTER SET '%s'
                # 1317 != $orig_err and   # ER_QUERY_INTERRUPTED): Query execution was interrupted
                1356 != $orig_err and   # ER_VIEW_INVALID (1356): View 'test.v1' references invalid table(s) or column(s) or function(s) or definer/invoker of view lack rights to use them
                1845 != $orig_err and   # ER_ALTER_OPERATION_NOT_SUPPORTED): %s is not supported for this operation. Try %s
                1846 != $orig_err and   # MariaDB error code 1846 (ER_ALTER_OPERATION_NOT_SUPPORTED_REASON): %s is not supported. Reason: %s. Try %s
                1901 != $orig_err and   # ER_GENERATED_COLUMN_FUNCTION_IS_NOT_ALLOWED): Function or expression '%s' cannot be used in the %s clause of %`s
                1907 != $orig_err and   # ER_UNSUPPORTED_ACTION_ON_GENERATED_COLUMN): This is not yet supported for generated columns
                # 1927 != $orig_err and   # ER_CONNECTION_KILLED): Connection was killed    Second execution caught 1094
                # 2006 != $orig_err and   # CR_SERVER_GONE_ERROR
                # 2013 != $orig_err and   # CR_SERVER_LOST
                4092 != $orig_err and   # ER_UNKNOWN_VIEW (4092): Unknown VIEW: 'test.v2'
                4145 != $orig_err and   # ER_BACKUP_LOCK_IS_ACTIVE): Can't execute the command as you have a BACKUP STAGE active ???
                4146 != $orig_err and   # ER_BACKUP_NOT_RUNNING): You must start backup with "BACKUP STAGE START"
                4147 != $orig_err       # ER_BACKUP_WRONG_STAGE): Backup stage '%s' is same or before current backup stage '%s'
               ) {
                say("DEBUG: $who_am_i No repetition for ->$orig_query<- which harvested undef " .
                    "data and $orig_err. Will return STATUS_OK.");
                return STATUS_OK;
            } else {
               say("DEBUG: $who_am_i Repetitions for ->$orig_query<- which harvested undef data i" .
                   "and $orig_err.");
            }
        }
    } else {
        # defined data
        if (defined $orig_err) {
            say("ALARM: $who_am_i ->$orig_query<- harvested $orig_err but data is defined!!");
        }
    }

    # undef data and undef err is filtered out.
    # Example: UPDATE

    # undef data and defined err != semantic error is filtered out. Really all?

    # Left over:
    # Statement == DML and (
    #   (defined data) or (undef data and defined err and err == semantic error)
    # )

    # foreach my $delay (0, 0.01, 0.1) {
    foreach my $delay (0, 0.1, 1.0) {
        Time::HiRes::sleep($delay);
        my $new_result = $executor->execute($orig_query);
        # Some note about SQL tracing
        # ---------------------------
        # The repeated query contains than two marker like
        #     /* E_R Thread3 QNO 3 CON_ID 17 */  /* E_R Thread3 QNO 4 CON_ID 17 */
        my $new_err = $new_result->err();
        if (defined $new_err) {
            if (1317 == $new_err or   # ER_QUERY_INTERRUPTED
                2006 == $new_err or   # CR_SERVER_GONE_ERROR
                2013 == $new_err      # CR_SERVER_LOST
                                    ) {
                say("DEBUG: $who_am_i Repeated query ->" . $orig_query . "<- harvested $new_err. " .
                    "Will return STATUS_OK.");
                return STATUS_OK;
            }

            if (not defined $orig_err) {
                say("ERROR: $who_am_i Repeated query ->" . $orig_query . "<- harvested $new_err instead of undef.");
                kill_server();
            } elsif ($orig_err == $new_err) {
                say("DEBUG: $who_am_i Repeated query ->" . $orig_query . "<- harvested again $new_err.");
                next;
            } else {
                say("ERROR: $who_am_i Repeated query ->" . $orig_query . "<-\n" .
                    "       harvested  $new_err: "  . $new_result->errstr() . "\n" .
                    "       instead of $orig_err: " . $orig_result->errstr());
                kill_server();
            }
        }

        if (not defined $orig_result->data() and defined $new_result->data()) {
            say("ERROR: $who_am_i Repeated query ->" . $orig_query . "<- harvested data instead of undef.");
            kill_server();
        } elsif (defined $orig_result->data() and not defined $new_result->data()) {
            say("ERROR: $who_am_i Repeated query ->" . $orig_query . "<- harvested undef instead of data.");
            kill_server();
        }

        # no data -> no comparison
        next if not defined $new_result->data();

        my $compare_outcome = GenTest::Comparator::compare($orig_result, $new_result);
        if ($compare_outcome > STATUS_OK) {
            # SQL tracing ?
            my $dbh = $executor->dbh();
            my $aux_query = 'SELECT @@tx_isolation /* E_R ' . 'BLUB' . # $executor->role .
                            ' QNO 0 CON_ID unknown */ ';
            # say("DEBUG: $who_am_i Will run ->" . $aux_query . "<-");
            my $row_arrayref = $dbh->selectrow_arrayref($aux_query);
            my $error =        $dbh->err();
            if (defined $error) {
                # Being victim of KILL QUERY/SESSION .... or whatever.
                say("DEBUG: $who_am_i ->" . $aux_query . "<- harvested $error. " .
                    "Will return STATUS_OK.");
                    return STATUS_OK;
            }
            say("DEBUG: ISO LEVEL IS is ->" . $row_arrayref->[0] . "<-");
            if ('READ-COMMITTED' eq $row_arrayref->[0] or 'READ-COMMITTED' eq $row_arrayref->[0]) {
                # It cannot be 100% excluded that the result diff is a bug of server and/or
                # storage engine. But its extreme likely that the diff is caused by the ISO Level.
                return STATUS_OK;
            }

            say("ERROR: $who_am_i The query ->" . $orig_query . "<- returns different result when " .
                "executed after a delay of $delay seconds.");
            say(GenTest::Comparator::dumpDiff($orig_result, $new_result));
            kill_server();
            # say("ERROR: $who_am_i Will kill the server with SIGABRT and return STATUS_DATABASE_CORRUPTION");
            # system('kill -6 $SERVER_PID1');
            # return STATUS_DATABASE_CORRUPTION;
        }
    }

    return STATUS_OK;
}

sub kill_server {
    say("ERROR: $who_am_i Will kill the server with SIGABRT and exit with STATUS_DATABASE_CORRUPTION");
    system('kill -6 $SERVER_PID1');
    exit STATUS_DATABASE_CORRUPTION;
}

1;
