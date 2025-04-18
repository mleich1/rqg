# Copyright (c) 2008, 2012 Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2013 Monty Program Ab.
# Copyright (c) 2018, 2022 MariaDB Corporation Ab.
# Copyright (c) 2023, 2025 MariaDB plc
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

package GenTest_e::Executor::MySQL;

require Exporter;

@ISA = qw(GenTest_e::Executor);

# (mleich) Explanations found in web
# Our strings written to STDOUT are sequences of multibyte characters (->utf8) and
# NOT single byte characters. So we need to set utf8 in order to prevent whatever
# wrong interpretations by Perl.
use utf8;
# If not setting this the Perl IO layer expects to get single-byte character and writes
# the warning "Wide character in print at ..." when meeting a wide character (>255).
binmode STDOUT, ':utf8';


my $debug_here = 0;

use strict;
use Carp;
use DBI;
use GenTest_e;
use GenTest_e::Constants;
use GenTest_e::Result;
use GenTest_e::Executor;
use GenTest_e::QueryPerformance;
use SQLtrace;
use Time::HiRes;
use Digest::MD5;

use constant RARE_QUERY_THRESHOLD  => 5;
use constant MAX_ROWS_THRESHOLD    => 7000000;

my %reported_errors;

my @errors = (
    "The target table .*? of the .*? is",
    "Duplicate entry '.*?' for key '.*?'",
    "Can't DROP '.*?'",
    "Duplicate key name '.*?'",
    "Duplicate column name '.*?'",
    "Record has changed since last read in table '.*?'",
    "savepoint does not exist",
    "'.*?' doesn't exist",
    " .*? does not exist",
    "'.*?' already exists",
    "Unknown database '.*?'",
    "Unknown table '.*?'",
    "Unknown column '.*?'",
    "Unknown event '.*?'",
    "Column '.*?' specified twice",
    "Column '.*?' cannot be null",
    "Column '.*?' in .*? clause is ambiguous",
    "Duplicate partition name .*?",
    "Tablespace '.*?' not empty",
    "Tablespace '.*?' already exists",
    "Tablespace data file '.*?' already exists",
    "Can't find file: '.*?'",
    "Table '.*?' already exists",
    "You can't specify target table '.*?' for update",
    "Illegal mix of collations .*?, .*?, .*? for operation '.*?'",
    "Illegal mix of collations .*? and .*? for operation '.*?'",
    "Invalid .*? character string: '.*?'",
    "This version of MySQL doesn't yet support '.*?'",
    "PROCEDURE .*? already exists",
    "FUNCTION .*? already exists",
    "'.*?' isn't in GROUP BY",
    "non-grouping field '.*?' is used in HAVING clause",
    "Table has no partition for value .*?",
    "Unknown prepared statement handler (.*?) given to EXECUTE",
    "Unknown prepared statement handler (.*?) given to DEALLOCATE PREPARE",
    "Can't execute the query because you have a conflicting read lock",
    "Can't execute the given command because you have active locked tables or an active transaction",
    "Not unique table/alias: '.*?'",
    "View .* references invalid table(s) or column(s) or function(s) or definer/invoker of view lack rights to use them",
    "Unknown thread id: .*?" ,
    "Unknown table '.*?' in .*?",
    "Table '.*?' is read only",
    "Duplicate condition: .*?",
    "Duplicate condition information item '.*?'",
    "Undefined CONDITION: .*?",
    "Incorrect .*? value '.*?'",
    # Perl warns
    # Unrecognized escape \d passed through at lib/GenTest_e/Executor/MySQL.pm ...
    # "Recursive limit \d+ (as set by the max_sp_recursion_depth variable) was exceeded for routine .*?",
    "Recursive limit \\d+ (as set by the max_sp_recursion_depth variable) was exceeded for routine .*?",
        "There is no such grant defined for user '.*?' on host '.*?' on table '.*?'",
    "There is no such grant defined for user '.*?' on host '.*?'",
    "'.*?' is not a .*?",
    "Incorrect usage of .*? and .*?",
    "Can't reopen table: '.*?'",
    "Trigger's '.*?' is view or temporary table",
    "Column '.*?' is not updatable"
);

my @patterns = map { qr{$_}i } @errors;

use constant EXECUTOR_MYSQL_AUTOCOMMIT => 20;

#
# Column positions for SHOW SLAVES
#

use constant SLAVE_INFO_HOST => 1;
use constant SLAVE_INFO_PORT => 2;

#                                                                        # Either the pattern of the message printed
# Error codes                                                            # or the comment in some version of Elena Stepanova
#                                                                        # or ...

use constant  ER_OUTOFMEMORY2                                   => 5;    # returned by some storage engines
use constant  ER_CRASHED1                                       => 126;  # Index is corrupted
use constant  ER_CRASHED2                                       => 145;  # Table was marked as crashed and should be repaired
use constant  ER_AUTOINCREMENT                                  => 167;  # Failed to set row auto increment value
use constant  ER_INCOMPATIBLE_FRM                               => 190;  # Incompatible key or row definition between the MariaDB .frm file and the information in the storage engine

use constant  ER_CANT_CREATE_TABLE                              => 1005; # Can't create table %`s.%`s (errno: %M)
use constant  ER_CANT_CREATE_DB                                 => 1006; # Can't create database '%-.192s' (errno: %M)
use constant  ER_DB_CREATE_EXISTS                               => 1007; # Can't create database '%-.192s'; database exists
use constant  ER_DB_DROP_EXISTS                                 => 1008; # Can't drop database '%-.192s'; database doesn't exist
use constant  ER_CANT_LOCK                                      => 1015; # Can't lock file (errno: %M)
use constant  ER_FILE_NOT_FOUND                                 => 1017; # Can't find file: '%-.200s' (errno: %M)
use constant  ER_CHECKREAD                                      => 1020; # Record has changed since last read in table '%-.192s'
use constant  ER_DISK_FULL                                      => 1021; # Disk full (%s); waiting for someone to free some space... (errno: %M)
use constant  ER_DUP_KEY                                        => 1022; # Can't write; duplicate key in table '%-.192s'
use constant  ER_ERROR_ON_CLOSE                                 => 1023; # Error on close of '%-.192s' (errno: %M)
use constant  ER_ERROR_ON_READ                                  => 1024; # Error reading file '%-.200s' (errno: %M)
use constant  ER_ERROR_ON_RENAME                                => 1025; # Error on rename of '%-.210s' to '%-.210s' (errno: %M)
use constant  ER_ERROR_ON_WRITE                                 => 1026; # Error writing file '%-.200s' (errno: %M)
use constant  ER_FILSORT_ABORT                                  => 1028; # Sort aborted
use constant  ER_GET_ERRNO                                      => 1030; # Got error %M from storage engine %s
use constant  ER_ILLEGAL_HA                                     => 1031; # Storage engine %s of the table %`s.%`s doesn't have this option
use constant  ER_KEY_NOT_FOUND                                  => 1032; # Can't find record in '%-.192s'
use constant  ER_NOT_FORM_FILE                                  => 1033; # Incorrect information in file: '%-.200s'
use constant  ER_NOT_KEYFILE                                    => 1034; # Index for table '%-.200s' is corrupt; try to repair it
use constant  ER_OPEN_AS_READONLY                               => 1036; # Table '%-.192s' is read only
use constant  ER_OUTOFMEMORY                                    => 1037; # Out of memory; restart server and try again (needed %d bytes)
use constant  ER_UNEXPECTED_EOF                                 => 1039; # Unexpected EOF found when reading file '%-.192s' (errno: %M)
use constant  ER_CON_COUNT_ERROR                                => 1040; # Too many connections
use constant  ER_OUT_OF_RESOURCES                               => 1041; # Out of memory.
use constant  ER_DBACCESS_DENIED_ERROR                          => 1044; # Access denied for user '%s'@'%s' to database '%-.192s'
use constant  ER_NO_DB_ERROR                                    => 1046; # No database selected
use constant  ER_BAD_NULL_ERROR                                 => 1048; # Column '%-.192s' cannot be null
use constant  ER_BAD_DB_ERROR                                   => 1049; # Unknown database '%-.192s'
use constant  ER_TABLE_EXISTS_ERROR                             => 1050; # Table '%-.192s' already exists
use constant  ER_BAD_TABLE_ERROR                                => 1051; # Unknown table '%-.100T'
use constant  ER_NON_UNIQ_ERROR                                 => 1052; # Column '%-.192s' in %-.192s is ambiguous
use constant  ER_SERVER_SHUTDOWN                                => 1053; # Server shutdown in progress
use constant  ER_BAD_FIELD_ERROR                                => 1054; # Unknown column '%-.192s' in '%-.192s'
use constant  ER_WRONG_FIELD_WITH_GROUP                         => 1055; # '%-.192s' isn't in GROUP BY
use constant  ER_WRONG_GROUP_FIELD                              => 1056; # Can't group on '%-.192s'
use constant  ER_DUP_FIELDNAME                                  => 1060; # Duplicate column name '%-.192s'
use constant  ER_DUP_KEYNAME                                    => 1061; # Duplicate key name '%-.192s'
use constant  ER_DUP_ENTRY                                      => 1062; # Duplicate entry '%-.192T' for key %d
use constant  ER_WRONG_FIELD_SPEC                               => 1063; # Incorrect column specifier for column '%-.192s'
use constant  ER_PARSE_ERROR                                    => 1064; # %s near '%-.80T' at line %d
use constant  ER_NONUNIQ_TABLE                                  => 1066; # Not unique table/alias: '%-.192s'
use constant  ER_INVALID_DEFAULT                                => 1067; # Invalid default value for '%-.192s'
use constant  ER_MULTIPLE_PRI_KEY                               => 1068; # Multiple primary key defined
use constant  ER_TOO_MANY_KEYS                                  => 1069; # Too many keys specified; max %d keys allowed
use constant  ER_TOO_LONG_KEY                                   => 1071; # Specified key was too long; max key length is %d bytes
use constant  ER_KEY_COLUMN_DOES_NOT_EXIST                      => 1072; # Key column '%-.192s' doesn't exist in table
use constant  ER_TOO_BIG_FIELDLENGTH                            => 1074; # Column length too big for column '%-.192s' (max = %lu); use BLOB or TEXT instea
use constant  ER_WRONG_AUTO_KEY                                 => 1075; # Incorrect table definition; there can be only one auto column and it must be defined as a key
use constant  ER_FILE_EXISTS_ERROR                              => 1086; # File '%-.200s' already exists
use constant  ER_WRONG_SUB_KEY                                  => 1089; # Incorrect prefix key; the used key part isn't a string, the used length is longer <...>
use constant  ER_CANT_REMOVE_ALL_FIELDS                         => 1090; # You can't delete all columns with ALTER TABLE; use DROP TABLE instead
use constant  ER_CANT_DROP_FIELD_OR_KEY                         => 1091; # Can't DROP %s %`-.192s; check that it exists
use constant  ER_UPDATE_TABLE_USED                              => 1093; # Table '%-.192s' is specified twice, both as a target for '%s' and as a separate source for data
use constant  ER_NO_SUCH_THREAD                                 => 1094; # Unknown thread id: %lu
use constant  ER_TABLE_NOT_LOCKED_FOR_WRITE                     => 1099; # Table '%-.192s' was locked with a READ lock and can't be updated
use constant  ER_TABLE_NOT_LOCKED                               => 1100; # Table '%-.192s' was not locked with LOCK TABLES
use constant  ER_TOO_BIG_SELECT                                 => 1104; # The SELECT would examine more than MAX_JOIN_SIZE rows <...>
use constant  ER_UNKNOWN_TABLE                                  => 1109; # Unknown table '%-.192s' in %-.32s
use constant  ER_FIELD_SPECIFIED_TWICE                          => 1110; # Column '%-.192s' specified twice
use constant  ER_INVALID_GROUP_FUNC_USE                         => 1111; # Invalid use of group function
use constant  ER_TABLE_MUST_HAVE_COLUMNS                        => 1113; # A table must have at least 1 column
use constant  ER_RECORD_FILE_FULL                               => 1114; # The table '%-.192s' is full
use constant  ER_TOO_BIG_ROWSIZE                                => 1118; # Row size too large. The maximum row size for the used table type, <...>
use constant  ER_STACK_OVERRUN                                  => 1119; # Thread stack overrun:  Used: %ld of a %ld stack.  Use 'mariadbd --thread_stack=#' to specify a bigger stack if needed
use constant  ER_PASSWORD_NO_MATCH                              => 1133; # Can't find any matching row in the user table
use constant  ER_CANT_CREATE_THREAD                             => 1135; # Can't create a new thread (errno %M); if you are not out of available memory, <...>
use constant  ER_WRONG_VALUE_COUNT_ON_ROW                       => 1136; # Column count doesn't match value count at row %lu
use constant  ER_CANT_REOPEN_TABLE                              => 1137; # Can't reopen table: '%-.192s'
use constant  ER_MIX_OF_GROUP_FUNC_AND_FIELDS                   => 1140; # Mixing of GROUP columns <...> with no GROUP columns is illegal if there is no GROUP BY clause
use constant  ER_NONEXISTING_GRANT                              => 1141; # There is no such grant defined for user '%-.48s' on host '%-.64s'
use constant  ER_NO_SUCH_TABLE                                  => 1146; # Table '%-.192s.%-.192s' doesn't exist
use constant  ER_NONEXISTING_TABLE_GRANT                        => 1147; # There is no such grant defined for user '%-.48s' on host '%-.64s' on table '%-.192s'
use constant  ER_SYNTAX_ERROR                                   => 1149; # You have an error in your SQL syntax
use constant  ER_TABLE_CANT_HANDLE_BLOB                         => 1163; # Storage engine %s doesn't support BLOB/TEXT columns
use constant  ER_WRONG_MRG_TABLE                                => 1168; # Unable to open underlying table which is differently defined or of non-MyISAM type or doesn't exist
use constant  ER_BLOB_KEY_WITHOUT_LENGTH                        => 1170; # BLOB/TEXT column '%-.192s' used in key specification without a key length
use constant  ER_TOO_MANY_ROWS                                  => 1172; # Result consisted of more than one row
use constant  ER_KEY_DOES_NOT_EXITS                             => 1176; # Key '%-.192s' doesn't exist in table '%-.192s'
use constant  ER_CHECK_NOT_IMPLEMENTED                          => 1178; # The storage engine for the table doesn't support %s
use constant  ER_FLUSH_MASTER_BINLOG_CLOSED                     => 1186; # Binlog closed, cannot RESET MASTER
use constant  ER_FT_MATCHING_KEY_NOT_FOUND                      => 1191; # Can't find FULLTEXT index matching the column list
use constant  ER_LOCK_OR_ACTIVE_TRANSACTION                     => 1192; # Can't execute the given command because you have active locked tables or an active transaction
use constant  ER_UNKNOWN_SYSTEM_VARIABLE                        => 1193; # Unknown system variable '%-.*s'
use constant  ER_CRASHED_ON_USAGE                               => 1194; # Table '%-.192s' is marked as crashed and should be repaired
use constant  ER_CRASHED_ON_REPAIR                              => 1195; # In minimum Aria
use constant  ER_TRANS_CACHE_FULL                               => 1197;
use constant  ER_LOCK_WAIT_TIMEOUT                              => 1205; # Lock wait timeout exceeded;
use constant  ER_WRONG_ARGUMENTS                                => 1210; # Incorrect arguments to %s
use constant  ER_LOCK_DEADLOCK                                  => 1213; # Deadlock found when trying to get lock; try restarting transaction
use constant  ER_TABLE_CANT_HANDLE_FT                           => 1214; # The storage engine %s doesn't support FULLTEXT indexes
use constant  ER_ROW_IS_REFERENCED                              => 1217; # Cannot delete or update a parent row: a foreign key constraint fails
use constant  ER_WRONG_USAGE                                    => 1221; # Incorrect usage of %s and %s
use constant  ER_CANT_UPDATE_WITH_READLOCK                      => 1223; # Can't execute the query because you have a conflicting read lock
use constant  ER_DUP_ARGUMENT                                   => 1225; # Option '%s' used twice in statement
# No privilege. Just for information because we connect as user root all time.
use constant  ER_SPECIFIC_ACCESS_DENIED_ERROR                   => 1227; # Access denied; you need (at least one of) the %-.128s privilege(s) for this operation
use constant  ER_WRONG_VALUE_FOR_VAR                            => 1231; # Variable '%-.64s' can't be set to the value of '%-.200T'
use constant  ER_VAR_CANT_BE_READ                               => 1233; # Variable '%-.64s' can only be set, not read
use constant  ER_CANT_USE_OPTION_HERE                           => 1234; # Incorrect usage/placement of '%s'
use constant  ER_NOT_SUPPORTED_YET                              => 1235; # This version of MariaDB doesn't yet support '%s'
use constant  ER_WRONG_FK_DEF                                   => 1239; # Incorrect foreign key definition for '%-.192s': %s
use constant  ER_OPERAND_COLUMNS                                => 1241; # Operand should contain %d column(s)
use constant  ER_UNKNOWN_STMT_HANDLER                           => 1243; # Unknown prepared statement handler (%.*s) given to %s
use constant  ER_ILLEGAL_REFERENCE                              => 1247; # Reference '%-.64s' not supported (%s)
use constant  ER_SPATIAL_CANT_HAVE_NULL                         => 1252; # All parts of a SPATIAL index must be NOT NULL
use constant  ER_COLLATION_CHARSET_MISMATCH                     => 1253; # COLLATION '%s' is not valid for CHARACTER SET '%s'
use constant  ER_WARN_TOO_FEW_RECORDS                           => 1261; # Row %lu doesn't contain data for all columns
use constant  ER_WARN_TOO_MANY_RECORDS                          => 1262; # Row %lu was truncated; it contained more data than there were input columns
use constant  ER_WARN_DATA_OUT_OF_RANGE                         => 1264; # Out of range value for column '%s' at row %lu
use constant  WARN_DATA_TRUNCATED                               => 1265; # Data truncated for column '%s' at row %lu
use constant  ER_CANT_AGGREGATE_2COLLATIONS                     => 1267; # Illegal mix of collations (%s,%s) and (%s,%s) for operation '%s'
use constant  ER_CANT_AGGREGATE_3COLLATIONS                     => 1270; # Illegal mix of collations (%s,%s), (%s,%s), (%s,%s) for operation '%s'
use constant  ER_CANT_AGGREGATE_NCOLLATIONS                     => 1271; # Illegal mix of collations for operation '%s'
use constant  ER_BAD_FT_COLUMN                                  => 1283; # Column '%-.192s' cannot be part of FULLTEXT index
use constant  ER_UNKNOWN_KEY_CACHE                              => 1284; # Unknown key cache '%-.100s'
use constant  ER_UNKNOWN_STORAGE_ENGINE                         => 1286; # Unknown storage engine '%s'
use constant  ER_NON_UPDATABLE_TABLE                            => 1288; # The target table %-.100s of the %s is not updatable
use constant  ER_FEATURE_DISABLED                               => 1289; # The '%s' feature is disabled; you need MariaDB built with '%s' to have it working
use constant  ER_OPTION_PREVENTS_STATEMENT                      => 1290; # The MariaDB server is running with the %s option so it cannot execute this statement
use constant  ER_TRUNCATED_WRONG_VALUE                          => 1292; # Truncated incorrect %-.32T value: '%-.128T'
use constant  ER_UNSUPPORTED_PS                                 => 1295; # This command is not supported in the prepared statement protocol yet
use constant  ER_INVALID_CHARACTER_STRING                       => 1300; # Invalid %s character string: '%.64T'
use constant  ER_SP_NO_RECURSIVE_CREATE                         => 1303; # Can't create a %s from within another stored routine
use constant  ER_SP_ALREADY_EXISTS                              => 1304; # %s %s already exists
use constant  ER_SP_DOES_NOT_EXIST                              => 1305; # %s %s does not exist
use constant  ER_SP_BADSTATEMENT                                => 1314; # %s is not allowed in stored procedures
use constant  ER_QUERY_INTERRUPTED                              => 1317; # Query execution was interrupted
use constant  ER_SP_COND_MISMATCH                               => 1319; # Undefined CONDITION: %s
use constant  ER_SP_NORETURNEND                                 => 1321; # FUNCTION %s ended without RETURN
use constant  ER_SP_DUP_PARAM                                   => 1330; # Duplicate parameter: %s
use constant  ER_SP_DUP_COND                                    => 1332; # Duplicate condition: %s
use constant  ER_STMT_NOT_ALLOWED_IN_SF_OR_TRG                  => 1336; # %s is not allowed in stored function or trigger
use constant  ER_WRONG_OBJECT                                   => 1347; # '%-.192s.%-.192s' is not of type '%s'
use constant  ER_NONUPDATEABLE_COLUMN                           => 1348; # Column '%-.192s' is not updatable
use constant  ER_VIEW_SELECT_DERIVED                            => 1349; # View's SELECT contains a subquery in the FROM clause
use constant  ER_VIEW_SELECT_TMPTABLE                           => 1352; # View's SELECT refers to a temporary table '%-.192s'
use constant  ER_VIEW_INVALID                                   => 1356; # View '%-.192s.%-.192s' references invalid table(s) or column(s) or function(s)
use constant  ER_SP_NO_DROP_SP                                  => 1357; # Can't drop or alter a %s from within another stored routine
use constant  ER_TRG_ALREADY_EXISTS                             => 1359; # Trigger '%s' already exists
use constant  ER_TRG_DOES_NOT_EXIST                             => 1360; # Trigger does not exist
use constant  ER_TRG_ON_VIEW_OR_TEMP_TABLE                      => 1361; # Trigger's '%-.192s' is a view, temporary table or sequence
use constant  ER_NO_DEFAULT_FOR_FIELD                           => 1364; # Field '%-.192s' doesn't have a default value
use constant  ER_TRUNCATED_WRONG_VALUE_FOR_FIELD                => 1366; # Incorrect %-.32s value: '%-.128T' for column `%.192s`.`%.192s`.`%.192s` at row %lu
use constant  ER_NO_BINARY_LOGGING                              => 1381; # You are not using binary logging
use constant  ER_CANNOT_USER                                    => 1396; # Operation %s failed for %.256s
use constant  ER_XAER_NOTA                                      => 1397; # Unknown XID
use constant  ER_XAER_RMFAIL                                    => 1399; # The command cannot be executed when global transaction is in the  %.64s state
use constant  ER_XAER_OUTSIDE                                   => 1400; # Some work is done outside global transaction
use constant  ER_XA_RBROLLBACK                                  => 1402; # XA_RBROLLBACK: Transaction branch was rolled back
use constant  ER_NONEXISTING_PROC_GRANT                         => 1403; # There is no such grant defined for user '%-.48s' on host '%-.64s' on routine '%-.192s'
use constant  ER_DATA_TOO_LONG                                  => 1406; # Data too long for column '%s' at row %lu
use constant  ER_SP_DUP_HANDLER                                 => 1413; # Duplicate handler declared in the same block
use constant  ER_SP_NO_RETSET                                   => 1415;
use constant  ER_CANT_CREATE_GEOMETRY_OBJECT                    => 1416;
use constant  ER_BINLOG_UNSAFE_ROUTINE                          => 1418;
use constant  ER_COMMIT_NOT_ALLOWED_IN_SF_OR_TRG                => 1422; # Explicit or implicit commit is not allowed in stored function or trigger
use constant  ER_NO_DEFAULT_FOR_VIEW_FIELD                      => 1423; # Field of view '%-.192s.%-.192s' underlying table doesn't have a default value
use constant  ER_SP_NO_RECURSION                                => 1424;
use constant  ER_TOO_BIG_SCALE                                  => 1425;
use constant  ER_XAER_DUPID                                     => 1440; # The XID already exists
use constant  ER_CANT_UPDATE_USED_TABLE_IN_SF_OR_TRG            => 1442;
use constant  ER_MALFORMED_DEFINER                              => 1446;
use constant  ER_ROW_IS_REFERENCED_2                            => 1451;
use constant  ER_NO_REFERENCED_ROW_2                            => 1452;
use constant  ER_SP_RECURSION_LIMIT                             => 1456; # Recursive limit %d (as set by the max_sp_recursion_depth variable) was exceeded for routine %.192s
use constant  ER_SP_PROC_TABLE_CORRUPT                          => 1457;
use constant  ER_VIEW_RECURSIVE                                 => 1462; # `test`.`view_1` contains view recursion
use constant  ER_NON_GROUPING_FIELD_USED                        => 1463; # Non-grouping field '%-.192s' is used in %-.64s clause
use constant  ER_TABLE_CANT_HANDLE_SPKEYS                       => 1464; # The storage engine %s doesn't support SPATIAL indexes
use constant  ER_NO_TRIGGERS_ON_SYSTEM_SCHEMA                   => 1465; # Triggers can not be created on system tables
use constant  ER_WRONG_STRING_LENGTH                            => 1470; # String '%-.70T' is too long
use constant  ER_NON_INSERTABLE_TABLE                           => 1471; # The target table %-.100s of the %s is not insertable-into
use constant  ER_ILLEGAL_HA_CREATE_OPTION                       => 1478; # Table storage engine '%-.64s' does not support the create option '%.64s'
use constant  ER_PARTITION_WRONG_VALUES_ERROR                   => 1480; # Only %-.64s PARTITIONING can use VALUES %-.64s in partition definition
use constant  ER_PARTITION_MAXVALUE_ERROR                       => 1481; # MAXVALUE can only be used in last partition definition
use constant  ER_FIELD_NOT_FOUND_PART_ERROR                     => 1488; # Field in list of fields for partition function not found in table
use constant  ER_MIX_HANDLER_ERROR                              => 1497;
use constant  ER_BLOB_FIELD_IN_PART_FUNC_ERROR                  => 1502;
use constant  ER_UNIQUE_KEY_NEED_ALL_FIELDS_IN_PF               => 1503;
use constant  ER_NO_PARTS_ERROR                                 => 1504; # Number of %-.64s = 0 is not an allowed value
use constant  ER_PARTITION_MGMT_ON_NONPARTITIONED               => 1505; # Partition management on a not partitioned table is not possible
use constant  ER_FOREIGN_KEY_ON_PARTITIONED                     => 1506; # Partitioned tables do not support %s
use constant  ER_DROP_PARTITION_NON_EXISTENT                    => 1507; # Wrong partition name or partition list
use constant  ER_DROP_LAST_PARTITION                            => 1508; # Cannot remove all partitions, use DROP TABLE instead
use constant  ER_COALESCE_ONLY_ON_HASH_PARTITION                => 1509; # COALESCE PARTITION can only be used on HASH/KEY partitions
use constant  ER_REORG_HASH_ONLY_ON_SAME_NO                     => 1510; # REORGANIZE PARTITION can only be used to reorganize partitions not to change their numbers
use constant  ER_REORG_NO_PARAM_ERROR                           => 1511; # REORGANIZE PARTITION without parameters can only be used on auto-partitioned tables using HASH PARTITIONs
use constant  ER_ONLY_ON_RANGE_LIST_PARTITION                   => 1512; # %-.64s PARTITION can only be used on RANGE/LIST partitions
use constant  ER_SAME_NAME_PARTITION                            => 1517; # Duplicate partition name %-.192s
use constant  ER_CONSECUTIVE_REORG_PARTITIONS                   => 1519; # When reorganizing a set of partitions they must be in consecutive order
use constant  ER_PLUGIN_IS_NOT_LOADED                           => 1524; # Plugin '%-.192s' is not loaded
use constant  ER_WRONG_VALUE                                    => 1525; # Incorrect %-.32s value: '%-.128T'
use constant  ER_NO_PARTITION_FOR_GIVEN_VALUE                   => 1526; # Table has no partition for value %-.64s
use constant  ER_EVENT_ALREADY_EXISTS                           => 1537; # Event '%-.192s' already exists
use constant  ER_EVENT_DOES_NOT_EXIST                           => 1539;
use constant  ER_EVENT_INTERVAL_NOT_POSITIVE_OR_TOO_BIG         => 1542;
use constant  ER_STORED_FUNCTION_PREVENTS_SWITCH_BINLOG_FORMAT  => 1560;
use constant  ER_PARTITION_NO_TEMPORARY                         => 1562; # Cannot create temporary table with partitions
use constant  ER_WRONG_PARTITION_NAME                           => 1567;
use constant  ER_CANT_CHANGE_TX_ISOLATION                       => 1568;
use constant  ER_EVENTS_DB_ERROR                                => 1577;
use constant  ER_XA_RBDEADLOCK                                  => 1614; # XA_RBDEADLOCK: Transaction branch was rolled back: deadlock was detected
use constant  ER_NEED_REPREPARE                                 => 1615; # Prepared statement needs to be re-prepared
use constant  ER_DUP_SIGNAL_SET                                 => 1641; # Duplicate condition information item '%s'
use constant  ER_SIGNAL_EXCEPTION                               => 1644; # Unhandled user-defined exception condition
use constant  ER_RESIGNAL_WITHOUT_ACTIVE_HANDLER                => 1645; # RESIGNAL when handler not active
use constant  ER_SIGNAL_BAD_CONDITION_TYPE                      => 1646; # SIGNAL/RESIGNAL can only use a CONDITION defined with SQLSTATE
use constant  ER_BACKUP_RUNNING                                 => 1651;
use constant  ER_FIELD_TYPE_NOT_ALLOWED_AS_PARTITION_FIELD      => 1659;
use constant  ER_BINLOG_STMT_MODE_AND_ROW_ENGINE                => 1665;
use constant  ER_BACKUP_SEND_DATA1                              => 1670;
use constant  ER_INSIDE_TRANSACTION_PREVENTS_SWITCH_BINLOG_FORMAT => 1679;
use constant  ER_TABLESPACE_EXIST                               => 1683;
use constant  ER_NO_SUCH_TABLESPACE                             => 1684;
use constant  ER_BACKUP_SEND_DATA2                              => 1687;
use constant  ER_DATA_OUT_OF_RANGE                              => 1690;
use constant  ER_BACKUP_PROGRESS_TABLES                         => 1691;
use constant  ER_FAILED_READ_FROM_PAR_FILE                      => 1696; # Failed to read from the .par file
use constant  ER_SET_PASSWORD_AUTH_PLUGIN                       => 1699;
use constant  ER_TRUNCATE_ILLEGAL_FK                            => 1701; # Cannot truncate a table referenced in a foreign key constraint (%.192s)
use constant  ER_MULTI_UPDATE_KEY_CONFLICT                      => 1706; # Primary key/partition key update is not allowed since the table is updated both as '%-.192s' and '%-.192s'
use constant  ER_INDEX_COLUMN_TOO_LONG                          => 1709; # Index column size too large. The maximum column size is %lu bytes
use constant  ER_INDEX_CORRUPT                                  => 1712; # Index %s is corrupted
use constant  ER_TABLESPACE_NOT_EMPTY                           => 1721;
use constant  ER_TABLESPACE_DATAFILE_EXIST                      => 1726;
use constant  ER_PARTITION_EXCHANGE_PART_TABLE                  => 1732; # Table to exchange with partition is partitioned: '%-.64s'
use constant  ER_PARTITION_INSTEAD_OF_SUBPARTITION              => 1734; # Subpartitioned table, use subpartition instead of partition
use constant  ER_UNKNOWN_PARTITION                              => 1735; # Unknown partition '%-.64s' in table '%-.64s'
use constant  ER_PARTITION_CLAUSE_ON_NONPARTITIONED             => 1747;
use constant  ER_ROW_DOES_NOT_MATCH_GIVEN_PARTITION_SET         => 1748;
use constant  ER_FOREIGN_DUPLICATE_KEY_WITH_CHILD_INFO          => 1761;
use constant  ER_FOREIGN_DUPLICATE_KEY_WITHOUT_CHILD_INFO       => 1762;
use constant  ER_BACKUP_NOT_ENABLED                             => 1789;
use constant  ER_CANT_EXECUTE_IN_READ_ONLY_TRANSACTION          => 1792;
use constant  ER_INNODB_NO_FT_TEMP_TABLE                        => 1796; # Cannot create FULLTEXT index on temporary InnoDB table
use constant  ER_INNODB_INDEX_CORRUPT                           => 1817; # Index corrupt: %s
use constant  ER_DUP_CONSTRAINT_NAME                            => 1826; # Duplicate %s constraint name '%s'
use constant  ER_FK_COLUMN_CANNOT_DROP                          => 1828; # Cannot drop column 'c7': needed in a foreign key constraint 'table200_innodb_int_autoinc_ibfk_1'
use constant  ER_FK_COLUMN_NOT_NULL                             => 1830; # Column '%-.192s' cannot be NOT NULL: needed in a foreign key constraint '%-.192s' SET NULL
use constant  ER_ALTER_OPERATION_NOT_SUPPORTED                  => 1845;
use constant  ER_ALTER_OPERATION_NOT_SUPPORTED_REASON           => 1846;
use constant  ER_INNODB_FT_AUX_NOT_HEX_ID                       => 1879; # Upgrade index name failed, please use create index(alter table) algorithm copy to ...
use constant  ER_VIRTUAL_COLUMN_FUNCTION_IS_NOT_ALLOWED         => 1901;
use constant  ER_KEY_BASED_ON_GENERATED_VIRTUAL_COLUMN          => 1904;
use constant  ER_WARNING_NON_DEFAULT_VALUE_FOR_GENERATED_COLUMN => 1906;
use constant  ER_UNSUPPORTED_ACTION_ON_GENERATED_COLUMN         => 1907;
use constant  ER_CONST_EXPR_IN_VCOL                             => 1908;
use constant  ER_UNKNOWN_OPTION                                 => 1911; # Unknown option '%-.64s'
use constant  ER_BAD_OPTION_VALUE                               => 1912; # Incorrect value '%-.64T' for option '%-.64s'
use constant  ER_CANT_DO_ONLINE                                 => 1915;
use constant  ER_CONNECTION_KILLED                              => 1927; # Connection was killed
use constant  ER_NO_SUCH_TABLE_IN_ENGINE                        => 1932; # Table '%-.192s.%-.192s' doesn't exist in engine
use constant  ER_TARGET_NOT_EXPLAINABLE                         => 1933; # Target is not running an EXPLAINable command
use constant  ER_INVALID_ROLE                                   => 1959; # Invalid role specification %`s
use constant  ER_INVALID_CURRENT_USER                           => 1960; # The current user is invalid
use constant  ER_IT_IS_A_VIEW                                   => 1965; # '%-.192s' is a view
use constant  ER_STATEMENT_TIMEOUT                              => 1969; # Query execution was interrupted (max_statement_time exceeded)

use constant  ER_CONNECTION_ERROR                               => 2002;
use constant  ER_CONN_HOST_ERROR                                => 2003;


use constant  ER_SERVER_GONE_ERROR                              => 2006;
# ER_SERVER_GONE_ERROR not found in 10.3. There is a CR_SERVER_GONE_ERROR only.
use constant  CR_SERVER_GONE_ERROR                              => 2006;

use constant  ER_SERVER_LOST                                    => 2013;
# ER_SERVER_LOST not found in 10.3. There is a CR_SERVER_LOST only.
use constant  CR_SERVER_LOST                                    => 2013;


use constant  CR_COMMANDS_OUT_OF_SYNC                           => 2014;  # Caused by old DBD::mysql
use constant  ER_SERVER_LOST_EXTENDED                           => 2055;

#--- MySQL 5.7 ---

use constant  ER_FIELD_IN_ORDER_NOT_SELECT                      => 3065;

#--- MySQL 5.7 JSON-related errors ---

use constant  ER_INVALID_JSON_TEXT                              => 3140;
use constant  ER_INVALID_JSON_TEXT_IN_PARAM                     => 3141;
use constant  ER_INVALID_JSON_BINARY_DATA                       => 3142;
use constant  ER_INVALID_JSON_PATH                              => 3143;
use constant  ER_INVALID_JSON_CHARSET                           => 3144;
use constant  ER_INVALID_JSON_CHARSET_IN_FUNCTION               => 3145;
use constant  ER_INVALID_TYPE_FOR_JSON                          => 3146;
use constant  ER_INVALID_CAST_TO_JSON                           => 3147;
use constant  ER_INVALID_JSON_PATH_CHARSET                      => 3148;
use constant  ER_INVALID_JSON_PATH_WILDCARD                     => 3149;
use constant  ER_JSON_VALUE_TOO_BIG                             => 3150;
use constant  ER_JSON_KEY_TOO_BIG                               => 3151;
use constant  ER_JSON_USED_AS_KEY                               => 3152;
use constant  ER_JSON_VACUOUS_PATH                              => 3153;
use constant  ER_JSON_BAD_ONE_OR_ALL_ARG                        => 3154;
use constant  ER_NUMERIC_JSON_VALUE_OUT_OF_RANGE                => 3155;
use constant  ER_INVALID_JSON_VALUE_FOR_CAST                    => 3156;
use constant  ER_JSON_DOCUMENT_TOO_DEEP                         => 3157;
use constant  ER_JSON_DOCUMENT_NULL_KEY                         => 3158;

#--- end of MySQL 5.7 JSON errors ---

use constant  ER_CONSTRAINT_FAILED                              => 4025;
use constant  ER_EXPRESSION_REFERS_TO_UNINIT_FIELD              => 4026;
use constant  ER_REFERENCED_TRG_DOES_NOT_EXIST                  => 4031; # Referenced trigger '%s' for the given action time and event type does not exist
use constant  ER_UNSUPPORT_COMPRESSED_TEMPORARY_TABLE           => 4047; # InnoDB refuses to write tables with ROW_FORMAT=COMPRESSED or KEY_BLOCK_SIZE
use constant  ER_ISOLATION_MODE_NOT_SUPPORTED                   => 4057;
use constant  ER_MYROCKS_CANT_NOPAD_COLLATION                   => 4077;

#--- end of 10.2 errors ---

use constant  ER_ILLEGAL_PARAMETER_DATA_TYPES2_FOR_OPERATION    => 4078;
use constant  ER_SEQUENCE_RUN_OUT                               => 4084;
use constant  ER_SEQUENCE_INVALID_DATA                          => 4085;
use constant  ER_SEQUENCE_INVALID_TABLE_STRUCTURE               => 4086;
use constant  ER_NOT_SEQUENCE                                   => 4089;
use constant  ER_UNKNOWN_SEQUENCES                              => 4091;
use constant  ER_UNKNOWN_VIEW                                   => 4092; # Unknown VIEW: '%-.300s'
use constant  ER_COMPRESSED_COLUMN_USED_AS_KEY                  => 4097; # Compressed column '%-.192s'
use constant  ER_VERSIONING_REQUIRED                            => 4106; # Aggregate specific instruction(FETCH GROUP NEXT ROW) missing from the aggregate function
use constant  ER_INVISIBLE_NOT_NULL_WITHOUT_DEFAULT             => 4108; # Invisible column %`s must have a default value
use constant  ER_UPDATE_INFO_WITH_SYSTEM_VERSIONING             => 4109;
use constant  ER_VERS_FIELD_WRONG_TYPE                          => 4110; # %`s must be of type %s for system-versioned table %`s
use constant  ER_VERS_ENGINE_UNSUPPORTED                        => 4111; # Transaction-precise system versioning for %`s is not supported
# use constant  ER_VERS_ALTER_NOT_ALLOWED                         => 4118;
use constant  ER_VERS_ALTER_NOT_ALLOWED                         => 4119;
use constant  ER_VERS_ALTER_ENGINE_PROHIBITED                   => 4120;
use constant  ER_VERS_NOT_VERSIONED                             => 4124;
use constant  ER_MISSING                                        => 4125; # Missing "with system versioning"
use constant  ER_VERS_PERIOD_COLUMNS                            => 4126;
use constant  ER_VERS_WRONG_PARTS                               => 4128;
use constant  ER_VERS_NO_TRX_ID                                 => 4129;
use constant  ER_VERS_ALTER_SYSTEM_FIELD                        => 4130;
use constant  ER_VERS_DUPLICATE_ROW_START_END                   => 4134;
use constant  ER_VERS_ALREADY_VERSIONED                         => 4135;
use constant  ER_VERS_TEMPORARY                                 => 4137;
use constant  ER_BACKUP_LOCK_IS_ACTIVE                          => 4145;
use constant  ER_BACKUP_NOT_RUNNING                             => 4146;
use constant  ER_BACKUP_WRONG_STAGE                             => 4147;

#--- end of 10.3 errors ---

#--- the codes below can still change---

use constant  ER_PERIOD_TEMPORARY_NOT_ALLOWED                   => 4152;
use constant  ER_PERIOD_TYPES_MISMATCH                          => 4153;
use constant  ER_MORE_THAN_ONE_PERIOD                           => 4154;
use constant  ER_PERIOD_FIELD_WRONG_ATTRIBUTES                  => 4155;
use constant  ER_PERIOD_NOT_FOUND                               => 4156;
use constant  ER_PERIOD_COLUMNS_UPDATED                         => 4157;
use constant  ER_PERIOD_CONSTRAINT_DROP                         => 4158;

my %err2type = (

    CR_COMMANDS_OUT_OF_SYNC()                           => STATUS_ENVIRONMENT_FAILURE,

    ER_ALTER_OPERATION_NOT_SUPPORTED()                  => STATUS_UNSUPPORTED,
    ER_ALTER_OPERATION_NOT_SUPPORTED_REASON()           => STATUS_UNSUPPORTED,
    ER_AUTOINCREMENT()                                  => STATUS_SEMANTIC_ERROR,
    ER_BACKUP_LOCK_IS_ACTIVE()                          => STATUS_SEMANTIC_ERROR,
    ER_BACKUP_NOT_ENABLED()                             => STATUS_ENVIRONMENT_FAILURE,
    ER_BACKUP_NOT_RUNNING()                             => STATUS_SEMANTIC_ERROR,
    ER_BACKUP_PROGRESS_TABLES()                         => STATUS_BACKUP_FAILURE,
    ER_BACKUP_RUNNING()                                 => STATUS_SEMANTIC_ERROR,
    ER_BACKUP_SEND_DATA1()                              => STATUS_BACKUP_FAILURE,
    ER_BACKUP_SEND_DATA2()                              => STATUS_BACKUP_FAILURE,
    ER_BACKUP_WRONG_STAGE()                             => STATUS_SEMANTIC_ERROR,
    ER_BAD_DB_ERROR()                                   => STATUS_SEMANTIC_ERROR,
    ER_BAD_FIELD_ERROR()                                => STATUS_SEMANTIC_ERROR,
    ER_BAD_FT_COLUMN()                                  => STATUS_SEMANTIC_ERROR,
    ER_BAD_NULL_ERROR()                                 => STATUS_SEMANTIC_ERROR,
    # Don't want to suppress it
    # ER_BAD_OPTION_VALUE()                               => STATUS_SEMANTIC_ERROR,
    ER_BAD_TABLE_ERROR()                                => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_STMT_MODE_AND_ROW_ENGINE()                => STATUS_SEMANTIC_ERROR,
    ER_BINLOG_UNSAFE_ROUTINE()                          => STATUS_SEMANTIC_ERROR,
    ER_BLOB_FIELD_IN_PART_FUNC_ERROR()                  => STATUS_SEMANTIC_ERROR,
    ER_BLOB_KEY_WITHOUT_LENGTH()                        => STATUS_SEMANTIC_ERROR,
    ER_CANNOT_USER()                                    => STATUS_SEMANTIC_ERROR,
    ER_CANT_AGGREGATE_2COLLATIONS()                     => STATUS_SEMANTIC_ERROR,
    ER_CANT_AGGREGATE_3COLLATIONS()                     => STATUS_SEMANTIC_ERROR,
    ER_CANT_AGGREGATE_NCOLLATIONS()                     => STATUS_SEMANTIC_ERROR,
    ER_CANT_CHANGE_TX_ISOLATION()                       => STATUS_SEMANTIC_ERROR,
    ER_CANT_CREATE_GEOMETRY_OBJECT()                    => STATUS_SEMANTIC_ERROR,
    ER_CANT_CREATE_DB()                                 => STATUS_SEMANTIC_ERROR,
    ER_CANT_CREATE_TABLE()                              => STATUS_SEMANTIC_ERROR,
    ER_CANT_CREATE_THREAD()                             => STATUS_ENVIRONMENT_FAILURE,
    ER_CANT_DO_ONLINE()                                 => STATUS_SEMANTIC_ERROR,
    ER_CANT_DROP_FIELD_OR_KEY()                         => STATUS_SEMANTIC_ERROR,
    ER_CANT_EXECUTE_IN_READ_ONLY_TRANSACTION()          => STATUS_SEMANTIC_ERROR,
    ER_CANT_LOCK()                                      => STATUS_SEMANTIC_ERROR,
    ER_CANT_REMOVE_ALL_FIELDS()                         => STATUS_SEMANTIC_ERROR,
    ER_CANT_REOPEN_TABLE()                              => STATUS_SEMANTIC_ERROR,
    ER_CANT_UPDATE_USED_TABLE_IN_SF_OR_TRG()            => STATUS_SEMANTIC_ERROR,
    ER_CANT_UPDATE_WITH_READLOCK()                      => STATUS_SEMANTIC_ERROR,
    ER_CANT_USE_OPTION_HERE()                           => STATUS_SEMANTIC_ERROR,
    ER_CHECKREAD()                                      => STATUS_TRANSACTION_ERROR,
    ER_CHECK_NOT_IMPLEMENTED()                          => STATUS_SEMANTIC_ERROR,
    ER_COALESCE_ONLY_ON_HASH_PARTITION()                => STATUS_SEMANTIC_ERROR,
    ER_COLLATION_CHARSET_MISMATCH()                     => STATUS_SEMANTIC_ERROR,
    ER_TOO_BIG_FIELDLENGTH()                            => STATUS_SEMANTIC_ERROR,
    ER_COMMIT_NOT_ALLOWED_IN_SF_OR_TRG()                => STATUS_SEMANTIC_ERROR,
    ER_COMPRESSED_COLUMN_USED_AS_KEY()                  => STATUS_SEMANTIC_ERROR,
    ER_CONNECTION_ERROR()                               => STATUS_SERVER_CRASHED,
    ER_CONNECTION_KILLED()                              => STATUS_SEMANTIC_ERROR,
    ER_CONN_HOST_ERROR()                                => STATUS_SERVER_CRASHED,
    ER_CONSTRAINT_FAILED()                              => STATUS_SEMANTIC_ERROR,
    ER_CONST_EXPR_IN_VCOL()                             => STATUS_SEMANTIC_ERROR,
    ER_CON_COUNT_ERROR()                                => STATUS_ENVIRONMENT_FAILURE,
    ER_CRASHED1()                                       => STATUS_DATABASE_CORRUPTION,
    ER_CRASHED2()                                       => STATUS_DATABASE_CORRUPTION,
    ER_CRASHED_ON_USAGE()                               => STATUS_DATABASE_CORRUPTION,
    ER_CRASHED_ON_REPAIR()                              => STATUS_DATABASE_CORRUPTION,
    ER_DATA_OUT_OF_RANGE()                              => STATUS_SEMANTIC_ERROR,
    ER_DATA_TOO_LONG()                                  => STATUS_SEMANTIC_ERROR,
    ER_DBACCESS_DENIED_ERROR()                          => STATUS_SEMANTIC_ERROR,
    ER_DB_CREATE_EXISTS()                               => STATUS_SEMANTIC_ERROR,
    ER_DB_DROP_EXISTS()                                 => STATUS_SEMANTIC_ERROR,
    ER_DISK_FULL()                                      => STATUS_ENVIRONMENT_FAILURE,
    ER_DROP_LAST_PARTITION()                            => STATUS_SEMANTIC_ERROR,
    ER_DROP_PARTITION_NON_EXISTENT()                    => STATUS_SEMANTIC_ERROR,
    ER_DUP_ARGUMENT()                                   => STATUS_SEMANTIC_ERROR,
    ER_DUP_CONSTRAINT_NAME()                            => STATUS_SEMANTIC_ERROR,
    ER_DUP_ENTRY()                                      => STATUS_TRANSACTION_ERROR,
    ER_DUP_FIELDNAME()                                  => STATUS_SEMANTIC_ERROR,
    ER_DUP_KEY()                                        => STATUS_TRANSACTION_ERROR,
    ER_DUP_KEYNAME()                                    => STATUS_SEMANTIC_ERROR,
    ER_DUP_SIGNAL_SET()                                 => STATUS_SEMANTIC_ERROR,
    ER_ERROR_ON_CLOSE()                                 => STATUS_ENVIRONMENT_FAILURE,
    ER_ERROR_ON_READ()                                  => STATUS_ENVIRONMENT_FAILURE,
    ER_ERROR_ON_RENAME()                                => STATUS_SEMANTIC_ERROR,
    ER_ERROR_ON_WRITE()                                 => STATUS_ENVIRONMENT_FAILURE,
    ER_EVENT_ALREADY_EXISTS()                           => STATUS_SEMANTIC_ERROR,
    ER_EVENT_DOES_NOT_EXIST()                           => STATUS_SEMANTIC_ERROR,
    ER_EVENT_INTERVAL_NOT_POSITIVE_OR_TOO_BIG()         => STATUS_SEMANTIC_ERROR,
    ER_EVENTS_DB_ERROR()                                => STATUS_DATABASE_CORRUPTION,
    ER_EXPRESSION_REFERS_TO_UNINIT_FIELD()              => STATUS_SEMANTIC_ERROR,
    ER_FEATURE_DISABLED()                               => STATUS_SEMANTIC_ERROR,
    ER_FIELD_IN_ORDER_NOT_SELECT()                      => STATUS_SEMANTIC_ERROR,
    ER_FIELD_NOT_FOUND_PART_ERROR()                     => STATUS_SEMANTIC_ERROR,
    ER_FIELD_TYPE_NOT_ALLOWED_AS_PARTITION_FIELD()      => STATUS_SEMANTIC_ERROR,
    ER_FIELD_SPECIFIED_TWICE()                          => STATUS_SEMANTIC_ERROR,
    ER_FILE_EXISTS_ERROR()                              => STATUS_SEMANTIC_ERROR,
    ER_FILE_NOT_FOUND()                                 => STATUS_SEMANTIC_ERROR,
    ER_FILSORT_ABORT()                                  => STATUS_SKIP,
    ER_FK_COLUMN_CANNOT_DROP()                          => STATUS_SEMANTIC_ERROR,
    ER_FK_COLUMN_NOT_NULL()                             => STATUS_SEMANTIC_ERROR,
    ER_FLUSH_MASTER_BINLOG_CLOSED()                     => STATUS_SEMANTIC_ERROR,
    ER_FOREIGN_KEY_ON_PARTITIONED()                     => STATUS_SEMANTIC_ERROR,
    ER_FOREIGN_DUPLICATE_KEY_WITH_CHILD_INFO()          => STATUS_SEMANTIC_ERROR,
    ER_FOREIGN_DUPLICATE_KEY_WITHOUT_CHILD_INFO()       => STATUS_SEMANTIC_ERROR,
    ER_FT_MATCHING_KEY_NOT_FOUND()                      => STATUS_SEMANTIC_ERROR,
    ER_GET_ERRNO()                                      => STATUS_SEMANTIC_ERROR,
    ER_ILLEGAL_HA()                                     => STATUS_SEMANTIC_ERROR,
    ER_ILLEGAL_HA_CREATE_OPTION()                       => STATUS_UNSUPPORTED,
    ER_ILLEGAL_PARAMETER_DATA_TYPES2_FOR_OPERATION()    => STATUS_SEMANTIC_ERROR,
    ER_ILLEGAL_REFERENCE()                              => STATUS_SEMANTIC_ERROR,
    ER_INCOMPATIBLE_FRM()                               => STATUS_DATABASE_CORRUPTION,
    ER_INDEX_COLUMN_TOO_LONG()                          => STATUS_SEMANTIC_ERROR,
    ER_INDEX_CORRUPT()                                  => STATUS_DATABASE_CORRUPTION,
    ER_INNODB_INDEX_CORRUPT()                           => STATUS_DATABASE_CORRUPTION,
    ER_INNODB_FT_AUX_NOT_HEX_ID()                       => STATUS_SEMANTIC_ERROR,
    ER_INNODB_NO_FT_TEMP_TABLE()                        => STATUS_SEMANTIC_ERROR,
    ER_INSIDE_TRANSACTION_PREVENTS_SWITCH_BINLOG_FORMAT() => STATUS_SEMANTIC_ERROR,
    ER_INVALID_CAST_TO_JSON()                           => STATUS_SEMANTIC_ERROR,
    ER_INVALID_CHARACTER_STRING()                       => STATUS_SEMANTIC_ERROR,
    ER_INVALID_CURRENT_USER()                           => STATUS_SEMANTIC_ERROR, # switch to something critical after MDEV-17943 is fixed
    ER_INVALID_DEFAULT()                                => STATUS_SEMANTIC_ERROR,
    ER_INVALID_GROUP_FUNC_USE()                         => STATUS_SEMANTIC_ERROR,
    ER_INVALID_JSON_BINARY_DATA()                       => STATUS_SEMANTIC_ERROR,
    ER_INVALID_JSON_CHARSET()                           => STATUS_SEMANTIC_ERROR,
    ER_INVALID_JSON_CHARSET_IN_FUNCTION()               => STATUS_SEMANTIC_ERROR,
    ER_INVALID_JSON_PATH()                              => STATUS_SEMANTIC_ERROR,
    ER_INVALID_JSON_PATH_CHARSET()                      => STATUS_SEMANTIC_ERROR,
    ER_INVALID_JSON_PATH_WILDCARD()                     => STATUS_SEMANTIC_ERROR,
    ER_INVALID_JSON_TEXT()                              => STATUS_SEMANTIC_ERROR,
    ER_INVALID_JSON_TEXT_IN_PARAM()                     => STATUS_SEMANTIC_ERROR,
    ER_INVALID_JSON_VALUE_FOR_CAST()                    => STATUS_SEMANTIC_ERROR,
    ER_INVALID_ROLE()                                   => STATUS_SEMANTIC_ERROR,
    ER_INVALID_TYPE_FOR_JSON()                          => STATUS_SEMANTIC_ERROR,
    ER_INVISIBLE_NOT_NULL_WITHOUT_DEFAULT()             => STATUS_SEMANTIC_ERROR,
    ER_ISOLATION_MODE_NOT_SUPPORTED()                   => STATUS_UNSUPPORTED,
    ER_JSON_BAD_ONE_OR_ALL_ARG()                        => STATUS_SEMANTIC_ERROR,
    ER_JSON_DOCUMENT_NULL_KEY()                         => STATUS_SEMANTIC_ERROR,
    ER_JSON_DOCUMENT_TOO_DEEP()                         => STATUS_SEMANTIC_ERROR,
    ER_JSON_KEY_TOO_BIG()                               => STATUS_SEMANTIC_ERROR,
    ER_JSON_VALUE_TOO_BIG()                             => STATUS_SEMANTIC_ERROR,
    ER_JSON_USED_AS_KEY()                               => STATUS_SEMANTIC_ERROR,
    ER_JSON_VACUOUS_PATH()                              => STATUS_SEMANTIC_ERROR,
    ER_IT_IS_A_VIEW()                                   => STATUS_SEMANTIC_ERROR,
    ER_KEY_BASED_ON_GENERATED_VIRTUAL_COLUMN()          => STATUS_SEMANTIC_ERROR,
    ER_KEY_COLUMN_DOES_NOT_EXIST()                      => STATUS_SEMANTIC_ERROR,
    ER_KEY_DOES_NOT_EXITS()                             => STATUS_SEMANTIC_ERROR,
    ER_KEY_NOT_FOUND()                                  => STATUS_DATABASE_CORRUPTION,
    ER_LOCK_DEADLOCK()                                  => STATUS_TRANSACTION_ERROR,
    ER_LOCK_OR_ACTIVE_TRANSACTION()                     => STATUS_SEMANTIC_ERROR,
    ER_LOCK_WAIT_TIMEOUT()                              => STATUS_TRANSACTION_ERROR,
    ER_MALFORMED_DEFINER()                              => STATUS_SEMANTIC_ERROR,
    ER_MISSING()                                        => STATUS_SYNTAX_ERROR,
    ER_MIX_HANDLER_ERROR()                              => STATUS_SEMANTIC_ERROR,
    ER_MIX_OF_GROUP_FUNC_AND_FIELDS()                   => STATUS_SEMANTIC_ERROR,
    ER_MORE_THAN_ONE_PERIOD()                           => STATUS_SEMANTIC_ERROR,
    ER_MULTIPLE_PRI_KEY()                               => STATUS_SEMANTIC_ERROR,
    ER_MULTI_UPDATE_KEY_CONFLICT()                      => STATUS_SEMANTIC_ERROR,
    ER_TRUNCATE_ILLEGAL_FK()                            => STATUS_SEMANTIC_ERROR,
    ER_MYROCKS_CANT_NOPAD_COLLATION()                   => STATUS_SEMANTIC_ERROR,
    ER_NEED_REPREPARE()                                 => STATUS_SEMANTIC_ERROR,
    ER_NONEXISTING_GRANT()                              => STATUS_SEMANTIC_ERROR,
    ER_NONEXISTING_PROC_GRANT()                         => STATUS_SEMANTIC_ERROR,
    ER_NONEXISTING_TABLE_GRANT()                        => STATUS_SEMANTIC_ERROR,
    ER_NONUNIQ_TABLE()                                  => STATUS_SEMANTIC_ERROR,
    ER_NONUPDATEABLE_COLUMN()                           => STATUS_SEMANTIC_ERROR,
    ER_NON_GROUPING_FIELD_USED()                        => STATUS_SEMANTIC_ERROR,
    ER_NON_INSERTABLE_TABLE()                           => STATUS_SEMANTIC_ERROR,
    ER_NON_UNIQ_ERROR()                                 => STATUS_SEMANTIC_ERROR,
    ER_NON_UPDATABLE_TABLE()                            => STATUS_SEMANTIC_ERROR,
    ER_NOT_FORM_FILE()                                  => STATUS_DATABASE_CORRUPTION,
    ER_NOT_KEYFILE()                                    => STATUS_DATABASE_CORRUPTION,
    ER_NOT_SEQUENCE()                                   => STATUS_SEMANTIC_ERROR,
    ER_NOT_SUPPORTED_YET()                              => STATUS_UNSUPPORTED,
    ER_NO_BINARY_LOGGING()                              => STATUS_SEMANTIC_ERROR,
    ER_NO_DB_ERROR()                                    => STATUS_SEMANTIC_ERROR,
    ER_NO_DEFAULT_FOR_FIELD()                           => STATUS_SEMANTIC_ERROR,
    ER_NO_DEFAULT_FOR_VIEW_FIELD()                      => STATUS_SEMANTIC_ERROR,
    ER_NO_PARTITION_FOR_GIVEN_VALUE()                   => STATUS_SEMANTIC_ERROR,
    ER_NO_PARTS_ERROR()                                 => STATUS_SEMANTIC_ERROR,
    ER_NO_REFERENCED_ROW_2()                            => STATUS_SEMANTIC_ERROR,
    ER_NO_SUCH_TABLE()                                  => STATUS_SEMANTIC_ERROR,
    ER_NO_SUCH_TABLE_IN_ENGINE()                        => STATUS_DATABASE_CORRUPTION,
    ER_NO_SUCH_TABLESPACE()                             => STATUS_SEMANTIC_ERROR,
    ER_NO_SUCH_THREAD()                                 => STATUS_SEMANTIC_ERROR,
    ER_NO_TRIGGERS_ON_SYSTEM_SCHEMA()                   => STATUS_SEMANTIC_ERROR,
    ER_NUMERIC_JSON_VALUE_OUT_OF_RANGE()                => STATUS_SEMANTIC_ERROR,
    ER_ONLY_ON_RANGE_LIST_PARTITION()                   => STATUS_SEMANTIC_ERROR,
    ER_OPEN_AS_READONLY()                               => STATUS_SEMANTIC_ERROR,
    ER_OPERAND_COLUMNS()                                => STATUS_SEMANTIC_ERROR,
    ER_OPTION_PREVENTS_STATEMENT()                      => STATUS_SEMANTIC_ERROR,
    ER_OUTOFMEMORY()                                    => STATUS_ENVIRONMENT_FAILURE,
    ER_OUTOFMEMORY2()                                   => STATUS_ENVIRONMENT_FAILURE,
    ER_OUT_OF_RESOURCES()                               => STATUS_ENVIRONMENT_FAILURE,
    ER_PARSE_ERROR()                                    => STATUS_SYNTAX_ERROR, # Don't mask syntax errors, fix them instead
# Impact: We get STATUS_UNKNOWN_ERROR(2) instead.
    ER_PARTITION_CLAUSE_ON_NONPARTITIONED()             => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_EXCHANGE_PART_TABLE()                  => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_INSTEAD_OF_SUBPARTITION()              => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_MAXVALUE_ERROR()                       => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_MGMT_ON_NONPARTITIONED()               => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_NO_TEMPORARY()                         => STATUS_SEMANTIC_ERROR,
    ER_PARTITION_WRONG_VALUES_ERROR()                   => STATUS_SEMANTIC_ERROR,
    ER_PASSWORD_NO_MATCH()                              => STATUS_SEMANTIC_ERROR,
    ER_PERIOD_COLUMNS_UPDATED()                         => STATUS_SEMANTIC_ERROR,
    ER_PERIOD_FIELD_WRONG_ATTRIBUTES()                  => STATUS_SEMANTIC_ERROR,
    ER_PERIOD_NOT_FOUND()                               => STATUS_SEMANTIC_ERROR,
    ER_PERIOD_TEMPORARY_NOT_ALLOWED()                   => STATUS_SEMANTIC_ERROR,
    ER_PERIOD_TYPES_MISMATCH()                          => STATUS_SEMANTIC_ERROR,
    ER_PLUGIN_IS_NOT_LOADED()                           => STATUS_SEMANTIC_ERROR,
    ER_QUERY_INTERRUPTED()                              => STATUS_SKIP,
    ER_FAILED_READ_FROM_PAR_FILE()                      => STATUS_DATABASE_CORRUPTION,
    ER_RECORD_FILE_FULL()                               => STATUS_ENVIRONMENT_FAILURE,
    ER_REFERENCED_TRG_DOES_NOT_EXIST()                  => STATUS_SEMANTIC_ERROR,
    ER_REORG_HASH_ONLY_ON_SAME_NO()                     => STATUS_SEMANTIC_ERROR,
    ER_REORG_NO_PARAM_ERROR()                           => STATUS_SEMANTIC_ERROR,
    ER_RESIGNAL_WITHOUT_ACTIVE_HANDLER()                => STATUS_SEMANTIC_ERROR,
    ER_ROW_DOES_NOT_MATCH_GIVEN_PARTITION_SET()         => STATUS_SEMANTIC_ERROR,
    ER_ROW_IS_REFERENCED()                              => STATUS_SEMANTIC_ERROR,
    ER_ROW_IS_REFERENCED_2()                            => STATUS_SEMANTIC_ERROR,
    ER_SAME_NAME_PARTITION()                            => STATUS_SEMANTIC_ERROR,
    ER_CONSECUTIVE_REORG_PARTITIONS()                   => STATUS_SEMANTIC_ERROR,

    # This was flipped from STATUS_SERVER_CRASHED to STATUS_SEMANTIC_ERROR in order to
    # minimize trouble with prepared statements.
    # Flipping back for experiments
#   ER_SERVER_GONE_ERROR()                              => STATUS_SEMANTIC_ERROR,
    ER_SERVER_GONE_ERROR()                              => STATUS_SERVER_CRASHED,
    # ER_SERVER_GONE_ERROR not found in 10.3. There is a CR_SERVER_GONE_ERROR only.
#   CR_SERVER_GONE_ERROR()                              => STATUS_SEMANTIC_ERROR,
    CR_SERVER_GONE_ERROR()                              => STATUS_SERVER_CRASHED,

    # ER_SERVER_LOST not found in 10.3. There is a CR_SERVER_LOST only.
    ER_SERVER_LOST()                                    => STATUS_SERVER_CRASHED,
    ER_SERVER_LOST_EXTENDED()                           => STATUS_SERVER_CRASHED,
    ER_SERVER_SHUTDOWN()                                => STATUS_SERVER_KILLED,
    ER_SEQUENCE_INVALID_DATA()                          => STATUS_SEMANTIC_ERROR,
    ER_SEQUENCE_INVALID_TABLE_STRUCTURE()               => STATUS_SEMANTIC_ERROR,
    ER_SEQUENCE_RUN_OUT()                               => STATUS_SEMANTIC_ERROR,
    ER_SET_PASSWORD_AUTH_PLUGIN()                       => STATUS_SEMANTIC_ERROR,
    ER_SIGNAL_BAD_CONDITION_TYPE()                      => STATUS_SEMANTIC_ERROR,
    ER_SIGNAL_EXCEPTION()                               => STATUS_SEMANTIC_ERROR,
    ER_SP_ALREADY_EXISTS()                              => STATUS_SEMANTIC_ERROR,
    ER_SP_BADSTATEMENT()                                => STATUS_SEMANTIC_ERROR,
    ER_SP_COND_MISMATCH()                               => STATUS_SEMANTIC_ERROR,
    ER_SP_DOES_NOT_EXIST()                              => STATUS_SEMANTIC_ERROR,
    ER_SP_DUP_COND()                                    => STATUS_SEMANTIC_ERROR,
    ER_SP_DUP_HANDLER()                                 => STATUS_SEMANTIC_ERROR,
    ER_SP_DUP_PARAM()                                   => STATUS_SEMANTIC_ERROR,
    ER_SP_NORETURNEND()                                 => STATUS_SEMANTIC_ERROR,
    ER_SP_NO_DROP_SP()                                  => STATUS_SEMANTIC_ERROR,
    ER_SP_NO_RECURSION()                                => STATUS_SEMANTIC_ERROR,
    ER_SP_NO_RECURSIVE_CREATE()                         => STATUS_SEMANTIC_ERROR,
    ER_SP_NO_RETSET()                                   => STATUS_SEMANTIC_ERROR,
#    ER_SP_PROC_TABLE_CORRUPT()                          => STATUS_DATABASE_CORRUPTION,  # this error is bogus due to bug # 47870
    ER_SP_RECURSION_LIMIT()                             => STATUS_SEMANTIC_ERROR,
    ER_SPATIAL_CANT_HAVE_NULL()                         => STATUS_SEMANTIC_ERROR,
    ER_STACK_OVERRUN()                                  => STATUS_ENVIRONMENT_FAILURE,
    ER_STATEMENT_TIMEOUT()                              => STATUS_SKIP,
    ER_STMT_NOT_ALLOWED_IN_SF_OR_TRG()                  => STATUS_SEMANTIC_ERROR,
    ER_STORED_FUNCTION_PREVENTS_SWITCH_BINLOG_FORMAT()  => STATUS_SEMANTIC_ERROR,
    ER_SYNTAX_ERROR()                                   => STATUS_SYNTAX_ERROR,
    ER_TABLESPACE_DATAFILE_EXIST()                      => STATUS_SEMANTIC_ERROR,
    ER_TABLESPACE_EXIST()                               => STATUS_SEMANTIC_ERROR,
    ER_TABLESPACE_NOT_EMPTY()                           => STATUS_SEMANTIC_ERROR,
    ER_TABLE_CANT_HANDLE_BLOB()                         => STATUS_SEMANTIC_ERROR,
    ER_TABLE_CANT_HANDLE_FT()                           => STATUS_SEMANTIC_ERROR,
    ER_TABLE_CANT_HANDLE_SPKEYS()                       => STATUS_SEMANTIC_ERROR,
    ER_TABLE_EXISTS_ERROR()                             => STATUS_SEMANTIC_ERROR,
    ER_TABLE_MUST_HAVE_COLUMNS()                        => STATUS_SEMANTIC_ERROR,
    ER_TABLE_NOT_LOCKED()                               => STATUS_SEMANTIC_ERROR,
    ER_TABLE_NOT_LOCKED_FOR_WRITE()                     => STATUS_SEMANTIC_ERROR,
    ER_TARGET_NOT_EXPLAINABLE()                         => STATUS_SEMANTIC_ERROR,
    ER_TOO_BIG_ROWSIZE()                                => STATUS_SEMANTIC_ERROR,
    ER_TOO_BIG_SCALE()                                  => STATUS_SEMANTIC_ERROR,
    ER_TOO_BIG_SELECT()                                 => STATUS_SEMANTIC_ERROR,
    ER_TOO_LONG_KEY()                                   => STATUS_SEMANTIC_ERROR,
    ER_TOO_MANY_KEYS()                                  => STATUS_SEMANTIC_ERROR,
    ER_TOO_MANY_ROWS()                                  => STATUS_SEMANTIC_ERROR,
    ER_TRANS_CACHE_FULL()                               => STATUS_SEMANTIC_ERROR, # or STATUS_TRANSACTION_ERROR
    ER_TRG_ALREADY_EXISTS()                             => STATUS_SEMANTIC_ERROR,
    ER_TRG_DOES_NOT_EXIST()                             => STATUS_SEMANTIC_ERROR,
    ER_TRG_ON_VIEW_OR_TEMP_TABLE()                      => STATUS_SEMANTIC_ERROR,
    ER_TRUNCATED_WRONG_VALUE()                          => STATUS_SEMANTIC_ERROR,
    ER_TRUNCATED_WRONG_VALUE_FOR_FIELD()                => STATUS_SEMANTIC_ERROR,
    ER_UNEXPECTED_EOF()                                 => STATUS_DATABASE_CORRUPTION,
    ER_UNIQUE_KEY_NEED_ALL_FIELDS_IN_PF()               => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_KEY_CACHE()                              => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_OPTION()                                 => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_PARTITION()                              => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_SEQUENCES()                              => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_STMT_HANDLER()                           => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_STORAGE_ENGINE()                         => STATUS_ENVIRONMENT_FAILURE,
    ER_UNKNOWN_SYSTEM_VARIABLE()                        => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_TABLE()                                  => STATUS_SEMANTIC_ERROR,
    ER_UNKNOWN_VIEW()                                   => STATUS_SEMANTIC_ERROR,
    ER_UNSUPPORTED_ACTION_ON_GENERATED_COLUMN()         => STATUS_UNSUPPORTED,
    ER_UNSUPPORT_COMPRESSED_TEMPORARY_TABLE()           => STATUS_UNSUPPORTED,
    ER_UNSUPPORTED_PS()                                 => STATUS_UNSUPPORTED,
    ER_UPDATE_TABLE_USED()                              => STATUS_SEMANTIC_ERROR,
    ER_VAR_CANT_BE_READ()                               => STATUS_SEMANTIC_ERROR,
    ER_VERS_ALREADY_VERSIONED()                         => STATUS_SEMANTIC_ERROR,
    ER_VERS_ALTER_ENGINE_PROHIBITED()                   => STATUS_SEMANTIC_ERROR,
    ER_VERS_ALTER_NOT_ALLOWED()                         => STATUS_SEMANTIC_ERROR,
    ER_VERS_ALTER_SYSTEM_FIELD()                        => STATUS_SEMANTIC_ERROR,
    ER_VERS_DUPLICATE_ROW_START_END()                   => STATUS_SEMANTIC_ERROR,
    ER_VERS_ENGINE_UNSUPPORTED()                        => STATUS_UNSUPPORTED,
    ER_VERS_FIELD_WRONG_TYPE()                          => STATUS_SEMANTIC_ERROR,
    ER_VERS_NO_TRX_ID()                                 => STATUS_SEMANTIC_ERROR,
    ER_VERS_NOT_VERSIONED()                             => STATUS_SEMANTIC_ERROR,
    ER_VERS_PERIOD_COLUMNS()                            => STATUS_SEMANTIC_ERROR,
    ER_VERS_TEMPORARY()                                 => STATUS_SEMANTIC_ERROR,
    ER_VERS_WRONG_PARTS()                               => STATUS_SEMANTIC_ERROR,
    ER_VERSIONING_REQUIRED()                            => STATUS_SEMANTIC_ERROR,
    ER_VIEW_INVALID()                                   => STATUS_SEMANTIC_ERROR,
    ER_VIEW_RECURSIVE()                                 => STATUS_SEMANTIC_ERROR,
    ER_VIEW_SELECT_DERIVED()                            => STATUS_SEMANTIC_ERROR,
    ER_VIEW_SELECT_TMPTABLE()                           => STATUS_SEMANTIC_ERROR,
    ER_VIRTUAL_COLUMN_FUNCTION_IS_NOT_ALLOWED()         => STATUS_SEMANTIC_ERROR,
    ER_WARN_DATA_OUT_OF_RANGE()                         => STATUS_SEMANTIC_ERROR,
    ER_WARN_TOO_FEW_RECORDS()                           => STATUS_SEMANTIC_ERROR,
    ER_WARN_TOO_MANY_RECORDS()                          => STATUS_SEMANTIC_ERROR,
    ER_WARNING_NON_DEFAULT_VALUE_FOR_GENERATED_COLUMN() => STATUS_SEMANTIC_ERROR,
    ER_WRONG_ARGUMENTS()                                => STATUS_SEMANTIC_ERROR,
    ER_WRONG_AUTO_KEY()                                 => STATUS_SEMANTIC_ERROR,
    ER_WRONG_FIELD_SPEC()                               => STATUS_SEMANTIC_ERROR,
    ER_WRONG_FIELD_WITH_GROUP()                         => STATUS_SEMANTIC_ERROR,
    ER_WRONG_FK_DEF()                                   => STATUS_SEMANTIC_ERROR,
    ER_WRONG_GROUP_FIELD()                              => STATUS_SEMANTIC_ERROR,
    ER_WRONG_MRG_TABLE()                                => STATUS_SEMANTIC_ERROR,
    ER_WRONG_OBJECT()                                   => STATUS_SEMANTIC_ERROR,
    ER_WRONG_PARTITION_NAME()                           => STATUS_SEMANTIC_ERROR,
    ER_WRONG_STRING_LENGTH()                            => STATUS_SEMANTIC_ERROR,
    ER_WRONG_SUB_KEY()                                  => STATUS_SEMANTIC_ERROR,
    ER_WRONG_USAGE()                                    => STATUS_SEMANTIC_ERROR,
    ER_WRONG_VALUE()                                    => STATUS_SEMANTIC_ERROR,
    ER_WRONG_VALUE_COUNT_ON_ROW()                       => STATUS_SEMANTIC_ERROR,
    ER_WRONG_VALUE_FOR_VAR()                            => STATUS_SEMANTIC_ERROR,
    ER_XA_RBDEADLOCK()                                  => STATUS_SEMANTIC_ERROR,
    ER_XA_RBROLLBACK()                                  => STATUS_TRANSACTION_ERROR,
    ER_XAER_DUPID()                                     => STATUS_SEMANTIC_ERROR,
    ER_XAER_NOTA()                                      => STATUS_SEMANTIC_ERROR,
    ER_XAER_RMFAIL()                                    => STATUS_SEMANTIC_ERROR,
    ER_XAER_OUTSIDE()                                   => STATUS_SEMANTIC_ERROR,

    WARN_DATA_TRUNCATED()                               => STATUS_SEMANTIC_ERROR,
);

# Sub-error numbers (<nr>) from storage engine failures (ER_GET_ERRNO);
# "1030 Got error <nr> from storage engine", which should not lead to
# STATUS_DATABASE_CORRUPTION, as they are acceptable runtime errors.

my %acceptable_se_errors = (
        139                     => "TOO_BIG_ROW"
);

my ($version, $major_version);
# Do not initialize like    my $query_no = 0   and than only here.
# The impact would be:
# When the main process initializes the first executor (GenData) it gets $query_no=0.
# SQL's causes that $query_no raises to m.
# Than the main process initializes the second Executor Metadacacher ...
# The executors for the threads during YY grammar processing belong to other processes.
my $query_no;

sub get_dbh {
    my ($dsn, $role, $timeout) = @_;

    my $who_am_i = Basics::who_am_i;

    if (not defined $dsn) {
        Carp::cluck("ERROR: \$dsn is undef.");
        exit STATUS_INTERNAL_ERROR;
    }
    if (not defined $role) {
        Carp::cluck("ERROR: \$role is undef.");
        exit STATUS_INTERNAL_ERROR;
    }
    $timeout = Runtime::CONNECT_TIMEOUT if not defined $timeout;

    my $dbh;
    # At least for worker threads mysql_auto_reconnect MUST be 0.
    # If not than we will get an automatic reconnect without executing *_connect.
    # say("DEBUG: $who_am_i dsn ->" . $dsn . "<-");
    $dbh = DBI->connect($dsn, undef, undef, {
        mysql_connect_timeout  => Runtime::get_runtime_factor() * $timeout,
        PrintError             => 0,
        RaiseError             => 0,
        AutoCommit             => 1,
        mysql_multi_statements => 1,
        mysql_auto_reconnect   => 0
    });
    if (not defined $dbh) {
        my $message_part = "ERROR: $who_am_i " . $role . " connect to dsn " .
                           $dsn . " failed: " . $DBI::errstr ;
        say("$message_part. Will return undef");
    }
    return $dbh;
}

# The parent process (...app/GenTest_e.pm) connects first.
# And in case that passes all future childs see the value 0. ?????
my $first_connect = 1;
sub get_connection {
    my $executor =  shift;

    my $who_am_i =  Basics::who_am_i;
    my $status =    STATUS_OK;
    # We need the $executor->role as important detail for messages.
    if (not defined $executor->role) {
        $status =   STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL_ERROR: $who_am_i Executor Role is undef. " .
                    Basics::exit_status_text($status));
        # Exit because this must never happen.
        exit $status;
    }

    # exp_server_kill($who_am_i, "get_dbh(...)");
    my $dbh = get_dbh($executor->dsn(), $executor->role(), undef);
    if (not defined $dbh) {
        my $message_part = "ERROR: $who_am_i " . $executor->role;
        if ($first_connect == 1) {
            $status = STATUS_ENVIRONMENT_FAILURE;
            say("$message_part: " . Basics::return_status_text($status));
            return $status;
        } else {
            # $status = STATUS_SERVER_CRASHED;
            $status = STATUS_CRITICAL_FAILURE;
            say("$message_part: " . Basics::return_status_text($status));
            return $status;
        }
    }
    $first_connect = 0;

    $executor->setDbh($dbh);

    # Observation 2018-09
    # -------------------
    # Whatever threads report connection loss short before because of some server crash.
    # The actual thread was a bit earlier the victim of some KILL CONNECTION, has checked something,
    # and connected again. In the moment this thread will be never the target of some KILL again.
    # Than comes a
    # Can't use an undefined value as an ARRAY reference at lib/GenTest_e/Executor/MySQL.pm line ...
    # for the next statement and than the affected thread/process dies with PERL failure.
    # The reason is
    #    $executor->setCurrentUser($dbh->selectrow_arrayref("SELECT CURRENT_USER()")->[0])
    #                                                                               XXXXX
    # The same is valid for the other $dbh->selectrow_arrayref("SELECT CURRENT_USER()")->[0].
    # $dbh->selectrow_arrayref itself is "clean" and retturns undef according to the spec!
    #
    # $executor->setConnectionId($dbh->selectrow_arrayref("SELECT CONNECTION_ID()")->[0]);
    #

    my $aux_query;
    my $trace_me = 0;    # <-------------------- Make that + setting it right global!
    $aux_query = "SELECT CONNECTION_ID()" . ' /* E_R ' . $executor->role .
                 ' QNO 0 CON_ID unknown */ ';
    SQLtrace::sqltrace_before_execution($aux_query);
    # exp_server_kill($who_am_i, $aux_query);
    my $row_arrayref = $dbh->selectrow_arrayref($aux_query);
    my $error =        $dbh->err();
    my $error_type =   STATUS_OK;
    SQLtrace::sqltrace_after_execution($error);
    if (defined $error) {
        $error_type = $err2type{$error} || STATUS_OK;
        my $message_part = "ERROR: $who_am_i " . $executor->role . " query ->" . $aux_query .
                           "<- failed: $error " .  $dbh->errstr();
        $status = $error_type;
        say("$message_part. " . Basics::return_status_text($status));
        return $status;
    }
    $executor->setConnectionId($row_arrayref->[0]);

    my $trace_addition = '/* E_R ' . $executor->role . ' QNO 0 CON_ID ' .
                         $executor->connectionId() . ' */ ';

    # exp_server_kill($who_am_i, "Call of set_safe_max_statement_time");
    $status = $executor->set_safe_max_statement_time ;
    return $status if $status != STATUS_OK;

    my ($host) = $executor->dsn() =~ m/:host=([^:]+):/;
    $executor->setHost($host);
    my ($port) = $executor->dsn() =~ m/:port=([^:]+):/;
    $executor->setPort($port);

    ####  system("killall -9 mysqld mariadbd");
    ####  sleep 5;
    $version = version($executor);
    if (not defined $version) {
        my $error =        $dbh->err();
        my $error_type =   STATUS_OK;
        if (defined $error) {
            $error_type = $err2type{$error} || STATUS_OK;
            $status = $error_type;
        } else {
            $status = STATUS_CRITICAL_FAILURE;
        }
        say("ERROR: $who_am_i " . $executor->role . " getting the version failed. " .
            Basics::return_status_text($status));
        return $status;
    }
    if ($version =~ /^(\d+\.\d+)/) {
        $major_version = $1;
    }

    #
    # Hack around bug 35676, optimizer_switch must be set session-wide in order to have effect.
    # So we read it from the GLOBAL_VARIABLE table and set it locally to the session.
    # Please leave this statement on a single line, which allows easier correct parsing
    # from general log.
    $aux_query = "SET optimizer_switch = (SELECT variable_value FROM INFORMATION_SCHEMA . " .
                 "GLOBAL_VARIABLES WHERE VARIABLE_NAME = 'optimizer_switch') " .
                 $trace_addition;
    # exp_server_kill($who_am_i, $aux_query);
    $status = GenTest_e::Executor::MySQL::run_do($dbh, $executor->role, $aux_query);
    if (STATUS_OK != $status) {
        say("ERROR: $who_am_i " . $executor->role . " " .  Basics::return_status_text($status));
        return $status;
    }

    # exp_server_kill($who_am_i, "executor->currentSchema()");
    # currentSchema makes SQL tracing if required.
    (my $result, $status) = $executor->currentSchema();
    if (STATUS_OK != $status) {
        say("ERROR: $who_am_i " . $executor->role . ": Getting the current schema failed. " .
            Basics::return_status_text($status));
        return $status;
    }
    if (not defined $result) {
        # Variants:
        # a) The server has crashed or is damaged otherwise
        # b) use ... was forgotten or similar == internal error
        $status = STATUS_CRITICAL_FAILURE;
        say("FATAL ERROR: $who_am_i " . $executor->role . ": current schema provided an undef " .
            "result. " .  Basics::return_status_text($status));
        return $status;
    }
    $executor->defaultSchema($result);

#   FIXME: Either remove the code or enable it.
#   if (($executor->fetchMethod() == FETCH_METHOD_AUTO) ||
#       ($executor->fetchMethod() == FETCH_METHOD_USE_RESULT)) {
#       say("Setting mysql_use_result to 1, so mysql_use_result() will be used.") if rqg_debug();
#       $dbh->{'mysql_use_result'} = 1;
#   } elsif ($executor->fetchMethod() == FETCH_METHOD_STORE_RESULT) {
#       say("Setting mysql_use_result to 0, so mysql_store_result() will be used.") if rqg_debug();
#       $dbh->{'mysql_use_result'} = 0;
#   }

    $aux_query = "SELECT CURRENT_USER() " . $trace_addition;
    SQLtrace::sqltrace_before_execution($aux_query);
    # exp_server_kill($who_am_i, $aux_query);
    $row_arrayref = $dbh->selectrow_arrayref($aux_query);
    $error = $dbh->err();
    $error_type = STATUS_OK;
    SQLtrace::sqltrace_after_execution($error);
    if (defined $error) {
        $error_type = $err2type{$error} || STATUS_OK;
        my $message_part = "ERROR: $who_am_i " . $executor->role . " query ->" . $aux_query .
                           "<- failed: $error " .  $dbh->errstr();
        $status = $error_type;
        say("$message_part. " . Basics::return_status_text($status));
        return $status;
    }
    $executor->setCurrentUser($row_arrayref->[0]);

    if (not defined $executor->id) {
        Carp::cluck("WARN: Executor id is undef");
    }
    if (not defined $executor->defaultSchema()) {
        Carp::cluck("WARN: Executor defaultSchema is undef");
    }
    if (not defined $executor->connectionId()) {
        Carp::cluck("WARN: Executor connectionId is undef");
    }
    if (not defined rqg_debug()) {
        Carp::cluck("WARN: Executor rqg_debug is undef");
    }
    say("Executor initialized. Role: " . $executor->role . "; id: " . $executor->id() .
        "; default schema: " . $executor->defaultSchema() . "; connection ID: " .
        $executor->connectionId()) if rqg_debug();

    #-------------------------------------
    # sqltraces need to "publish" the sql_mode of the session.
    # Reason:
    # Serious problems to replay single user bugs in MTR later because the defaults for
    # sql_mode within the server or set by MTR differ often dramatic.
    # Solution:
    # - pull the current sql_mode of the session
    # - Set the sql_mode of the session to the mode pulled via $executor->execute.
    #   This should have nearly (rather harmless additional SQL before we run the testing SQL)
    #   zero impact on the state of the session. But it follows the important principle
    #   "We print only what we have really done" and using "execute" gives a crowd of advantages
    #   like its already prepared to write sqltraces and it has extra checks.
    # - set/trace sql_mode gets done at end of executor::get_connection only == We trace only once.
    #   Manipulations of the sql_mode by the YY grammar will be traced later anyway.
    #   get_connection gets called by init and Executor::init gets called by the relevant modules
    #   Mixer GendataAdvanced Gendata GendataSimple GendataSQL GenTest_e PopulateSchema ...
    #
    $aux_query = "SELECT \@\@sql_mode " . $trace_addition;

    SQLtrace::sqltrace_before_execution($aux_query);

    # exp_server_kill($who_am_i, $aux_query);
    $row_arrayref = $dbh->selectrow_arrayref($aux_query);
    $error = $dbh->err();
    $error_type = STATUS_OK;
    SQLtrace::sqltrace_after_execution($error);
    if (defined $error) {
        $error_type = $err2type{$error} || STATUS_OK;
        my $message_part = "ERROR: $who_am_i " . $executor->role . " query ->" . $aux_query .
                           "<- failed: $error " .  $dbh->errstr();
        $status = $error_type;
        say("$message_part. " . Basics::return_status_text($status));
        return $status;
    }

    my $sql_mode = $row_arrayref->[0];
    $aux_query = "SET SESSION sql_mode = '$sql_mode' " . $trace_addition;
    $status = GenTest_e::Executor::MySQL::run_do($dbh, $executor->role, $aux_query);
    # run_do makes SQL tracing if required.
    if (STATUS_OK != $status) {
        say("ERROR: $who_am_i " . $executor->role . " " . Basics::return_status_text($status));
        return $status;
    }

    # exp_server_kill($who_am_i, "Call of restore_max_statement_time");
    $status = $executor->restore_max_statement_time ;

    return $status;

} # End sub get_connection

sub init {
    my $executor = shift;

    my $who_am_i = Basics::who_am_i;
    # Experiment begin
    # We need to set $query_no exact here.
    $query_no = 0;
    # Experiment end

    my $status = get_connection($executor);

    if ($status) {
        say("ERROR: $who_am_i Getting a proper connection for " .
             $executor->role() . " failed. " . Basics::return_status_text($status));
        return $status;
    } else {
        # say("DEBUG: $who_am_i connection id is : " . $executor->connectionId());
        if ($executor->task() != GenTest_e::Executor::EXECUTOR_TASK_THREAD) {
            # SQL run by some executor of the remaining 'tasks'
            #     EXECUTOR_TASK_GENDATA, EXECUTOR_TASK_CACHER, EXECUTOR_TASK_REPORTER,
            #     EXECUTOR_TASK_UNKNOWN, EXECUTOR_TASK_CHECKER
            # must be not vulnerable to a short max_statement_time.
            $status = $executor->set_safe_max_statement_time ;
            return $status if $status != STATUS_OK;
        }
        if ($executor->task() == GenTest_e::Executor::EXECUTOR_TASK_CHECKER) {
            $status = $executor->set_safe_max_statement_time ;
            return $status if $status != STATUS_OK;
            my $trace_addition = '/* E_R ' . $executor->role . ' QNO 0 CON_ID ' .
                                 $executor->connectionId() . ' */ ';
            my $aux_query = 'SET @@innodb_lock_wait_timeout = 30 ' . $trace_addition;
            my $status = GenTest_e::Executor::MySQL::run_do($executor->dbh, $executor->role,
                                                            $aux_query);
            if (STATUS_OK != $status) {
                say("ERROR: $who_am_i " . $executor->role . " " .
                    Basics::return_status_text($status));
                return $status;
            } else {
                return STATUS_OK;
            }

        }
        # Experimental code. Do not remove even though currently disabled.
        # Intention: Accelerate the generation of data by temporary increase of buffer pool size.
        # if ($executor->task() == GenTest_e::Executor::EXECUTOR_TASK_GENDATA) {
        #     $status = $executor->set_innodb_buffer_pool_size ;
        #     return $status if $status != STATUS_OK;
        # }
    }
    return STATUS_OK;
}

sub reportError {
    my ($self, $query, $err, $errstr, $execution_flags) = @_;

    my $msg = [$query,$err,$errstr];

    if (defined $self->channel) {
        $self->sendError($msg) if not ($execution_flags & EXECUTOR_FLAG_SILENT);
    } elsif (not defined $reported_errors{$errstr}) {
        my $query_for_print= shorten_message($query);
        say("Executor: Query: $query_for_print failed: $err $errstr. Further errors of this " .
            "kind will be suppressed.") if not ($execution_flags & EXECUTOR_FLAG_SILENT);
       $reported_errors{$errstr}++;
    }
}


sub execute {
    my ($executor, $query, $execution_flags) = @_;

    my $who_am_i = Basics::who_am_i;
    my $status;
    $execution_flags= 0 unless defined $execution_flags;


    my $executor_role = $executor->role();
    $executor_role = 'unknown' if not defined $executor_role;

    if (not defined $executor->task()) {
        Carp::cluck("WARN: Executor Task is not defined. Will set it to EXECUTOR_TASK_UNKNOWN.");
        $executor->setTask(GenTest_e::Executor::EXECUTOR_TASK_UNKNOWN);
    }

    if (not defined $query) {
       $status = STATUS_INTERNAL_ERROR;
       # Its so fatal that we should exit immediate.
       Carp::cluck("ERROR: The query is not defined for $executor_role. " .
                   Basics::exit_status_text($status));
       exit $status;
    }

    if (($executor->task() == GenTest_e::Executor::EXECUTOR_TASK_UNKNOWN) or
        ($executor->task() == GenTest_e::Executor::EXECUTOR_TASK_THREAD and
         $query =~ m{^\s*(select|show|check)}sio )) {
        # Observation from the early days of RQG more or less up till today:
        # ------------------------------------------------------------------
        # 1. A query gets generated because current time < end_time.
        # 2. Than this query gets executed on the first server and maybe
        #    - executed on other servers too (some kind of replication) + results compared
        #    - transformed into many variants which get executed too
        #    - checked by validators.
        #    During one of these actions some RQG timeout (threshold of reporter Deadlock,
        #    alarm in rqg.pl, rqg_batch.pl, ...) kicks in and claims to have caught a problem
        #    which might be a server deadlock or freeze or whatever.
        #    Some typical candidate where this happened frequent are optimizer tests and
        #    the query is some SELECT.
        # Worker threads get the end time assigned. So check that limit here.
        #
        # Warning:
        # In case the "give up" of the worker thread is not handled perfect than tests
        # running some kind of replication might end with content diff between servers.
        #    Typical bad scenario from the RQG builtin statement based replication:
        #    Run on server m a data modifying statement with success.
        #    Omit doing that on server m+1 and exit because $give_up_time was exceeded.
        #    Get finally a content diff between the servers.
        #
        #    Changing some global server parameter like SQL mode might have some similar bad
        #    effect.
        #
        # This all is not relevant for: Gendata*, MetadataCacher, Reporter
        #
        my $give_up_time = $executor->end_time();
        if (defined $give_up_time and time() > $give_up_time) {
            $status = STATUS_SKIP;
            say("INFO: $who_am_i $executor_role has already exceeded " .
                "the end_time (1). " . Basics::return_rc_status_text($status));
            return GenTest_e::Result->new(
                query       => $query,
                status      => $status,
            );
        }
    }

    my $dbh = $executor->dbh();
    if (not defined $dbh) {
        # One executor lost his connection but the server was connectable.
        # --> return a result with status STATUS_SKIP_RELOOP to Mixer::next.
        # Mixer disconnects than all executors, omits running any validator for the current
        # query and also omits running the remaining queries.
        # Hint: A call of Generator leads to some "multi" query == list of "single" queries.
        #       Mixer picks the leftmost "single" query from that list and gives it to every
        #       executor (one per DB server). After execution (includes validators) the next
        # query from that list is picked.
        # Maybe Not relevant for: Gendata*, MetadataCacher, Reporter
        say("DEBUG: $who_am_i The connection to the server for " .
            "$executor_role was lost. Trying to reconnect.") if $debug_here;
        $status = get_connection($executor);
        # Hint: get_connection maintains the connection_id etc.
        if ($status) {
            say("ERROR: $who_am_i Getting a connection for $executor_role failed " .
                "with $status. "  . Basics::return_status_text($status));
            return GenTest_e::Result->new(
                query       => '/* During connect attempt */',
                status      => $status,
            );
        } else {
            # Connecting might last long.
            if ($executor->task() == GenTest_e::Executor::EXECUTOR_TASK_THREAD or
                $executor->task() == GenTest_e::Executor::EXECUTOR_TASK_UNKNOWN) {
                my $give_up_time = $executor->end_time();
                if (defined $give_up_time and time() > $give_up_time) {
                    $status = STATUS_SKIP;
                    say("INFO: $who_am_i $executor_role has already exceeded " .
                        "the end_time (2). " . Basics::return_rc_status_text($status));
                    return GenTest_e::Result->new(
                        query       => $query,
                        status      => $status,
                    );
                }
            }
        }
        $dbh = $executor->dbh();
    }
    # Attention:
    # Having a defined dbh does not imply that this connection will work.
    # Just imagine some previous COMMIT RELEASE.

   my $trace_addition = ' /* E_R ' . $executor_role . ' QNO ' . (++$query_no) .
                        ' CON_ID ' . $executor->connectionId() . ' */ ';
   $query = $query . $trace_addition;

   $execution_flags = $execution_flags | $executor->flags();

   # Filter out any /*executor */ comments that do not pertain to this particular Executor/DBI.
   # $executor_id is the number of the server to run against.
   if (index($query, 'executor') > -1) {
      my $executor_id = $executor->id();
      $query =~ s{/\*executor$executor_id (.*?) \*/}{$1}sg;
      $query =~ s{/\*executor.*?\*/}{}sgo;
   }

   #  say("DEBUG: $trace_addition Before preprocess");

    $query = $executor->preprocess($query);
    # Hint: The sub preprocess does not run any SQL.

    if ($executor->task() == GenTest_e::Executor::EXECUTOR_TASK_THREAD or
        $executor->task() == GenTest_e::Executor::EXECUTOR_TASK_UNKNOWN) {
        if ((not defined $executor->[EXECUTOR_MYSQL_AUTOCOMMIT]) &&
            ($query =~ m{^\s*(start\s+transaction|begin|commit|rollback)}io)) {
            my $aux_query = "SET AUTOCOMMIT=OFF";
            # exp_server_kill($who_am_i, $aux_query);
            $dbh->do($aux_query);
            my $error =      $dbh->err();
            my $error_type = STATUS_OK;
            if (defined $error) {
                $error_type = $err2type{$error} || STATUS_OK;
                my $message_part = "ERROR: $who_am_i $executor_role Auxiliary query ->" .
                                   $aux_query . "<- failed: $error " .  $dbh->errstr();
                my $status = $error_type;
                if (($error_type == STATUS_SERVER_CRASHED) ||
                    ($error_type == STATUS_SERVER_KILLED)) {
                   $executor->disconnect(); # FIXME: Would be that good?
                   if (STATUS_OK == $executor->is_connectable()) {
                      $status = STATUS_SKIP_RELOOP;
                      say("INFO: $message_part");
                      say("INFO: $trace_addition : The server is connectable. " .
                          Basics::return_rc_status_text($status));
                   } else {
                      $status = STATUS_CRITICAL_FAILURE;
                      say("ERROR: $message_part");
                      say("INFO: $trace_addition :  The server is not connectable. Will sleep " .
                          "3s and than " . Basics::return_rc_status_text($status));
                      sleep(3);
                   }
                } else {
                   say("ERROR: $message_part. " . Basics::return_rc_status_text($status));
                }
                return GenTest_e::Result->new(
                   query       => $query . '/* During additional auxiliary query */',
                   status      => $status,
                );
            }

            $executor->[EXECUTOR_MYSQL_AUTOCOMMIT] = 0;
            if ($executor->fetchMethod() == FETCH_METHOD_AUTO) {
                say("INFO: $who_am_i $executor_role Transactions detected. Setting " .
                    "mysql_use_result to 0, so mysql_store_result() will be used.") if rqg_debug();
                $dbh->{'mysql_use_result'} = 0;
            }
        }
    }

    my $trace_query;
    my $trace_me = 0;

    # Transform the query to be traced so that mariadb/mysql and mariadb-test/mysql-test
    # find the delimiter required for
    #     CREATE [OR REPLACE] PROCEDURE/TRIGGER/... [IF NOT EXISTS] ...
    if ($query =~ m{^ *create .*(procedure|function|trigger)}msgio) {
        $trace_query = "DELIMITER |;\n$query |\nDELIMITER |";
    } else {
        $trace_query = $query;
    }

    SQLtrace::sqltrace_before_execution($trace_query);

    my $performance;
    # The validator Performance assigns EXECUTOR_FLAG_PERFORMANCE
    if ($execution_flags & EXECUTOR_FLAG_PERFORMANCE) {
        # say("DEBUG: Executor: $trace_addition Before performance 'init'");
        # FIXME:
        # This can be victim
        $performance = GenTest_e::QueryPerformance->new(
            dbh   => $executor->dbh(),
            query => $query
        );
    }

    # say("DEBUG: Executor: $trace_addition Before prepare");
    my $start_time = Time::HiRes::time();
    # exp_server_kill($who_am_i, $query);
    my $sth = $dbh->prepare($query);

    if (not defined $sth) {            # Error on PREPARE
        my $errstr_prepare = $executor->normalizeError($dbh->errstr());
        $executor->[EXECUTOR_ERROR_COUNTS]->{$errstr_prepare}++
            if not ($execution_flags & EXECUTOR_FLAG_SILENT);
        return GenTest_e::Result->new(
            query       => $query,
            status      => $err2type{$dbh->err()} || STATUS_UNKNOWN_ERROR,
            err         => $dbh->err(),
            errstr      => $dbh->errstr(),
            sqlstate    => $dbh->state(),
            start_time  => $start_time,
            end_time    => Time::HiRes::time()
        );
    }

    # say("DEBUG: Executor: $trace_addition Before execute");

    ######## HERE THE QUERY GETS SENT TO THE SERVER ?? ########
    my $affected_rows =  $sth->execute();
    # In case the RQG log contains a
    # DBD::mysql::st execute warning:  at /data/RQG_mleich1/lib/GenTest_e/Executor/MySQL.pm line 1321, <CONF> line 72
    # than we have tried to execute a statement but loast the connection to the server.
    #
    # Harvesting undef is "normal".
    my $end_time =       Time::HiRes::time();
    my $execution_time = $end_time - $start_time;

    my $err =      $sth->err();
    SQLtrace::sqltrace_after_execution($err);
    my $errstr =   $executor->normalizeError($sth->errstr()) if defined $sth->errstr();
    my $err_type = STATUS_OK;
    if (defined $err) {
        $err_type = $err2type{$err} || STATUS_OK;
        if ($err == ER_GET_ERRNO) {
            my $se_err = $sth->errstr() =~ m{^Got error\s+(\d+)\s+from storage engine}sgio;
            if (defined $se_err and exists $acceptable_se_errors{$se_err}) {
                $err_type = STATUS_OK;
            }
        }
        if ($err == ER_DUP_KEY) {
            # InnoDB: Error (Duplicate key) writing word node to FTS auxiliary index table
            # Fixed October 2022
            if ($sth->errstr() =~ m{InnoDB: Error \(Duplicate key\) writing word node to FTS auxiliary index table}sgio) {
                say("ERROR: MDEV-15237 hit");
                $err_type = STATUS_CRITICAL_FAILURE;
            }
        }
    }

    # FIXME:
    # Check for some Reporter using an executor from here if he
    # - will update the EXECUTOR_STATUS_COUNTS.
    # - fiddles with mysql_info etc.
    # - needs $matched_rows, $changed_rows etc.
    $executor->[EXECUTOR_STATUS_COUNTS]->{$err_type}++
        if not ($execution_flags & EXECUTOR_FLAG_SILENT);

    my $result;
    if (defined $err) {            # Error on EXECUTE
        # say("DEBUG: $trace_addition At begin of Error '$err' processing");

        if ($executor->task() == GenTest_e::Executor::EXECUTOR_TASK_REPORTER or
            $executor->task() == GenTest_e::Executor::EXECUTOR_TASK_CHECKER) {
            # FIXME:
            # Check for some Reporter using an executor from here if he needs anything of the
            # stuff which follows.
            # STATUS_SKIP_RELOOP and its consequences is not for Reporters
            # EXECUTOR_ERROR_COUNTS etc. is also not for Reporters
            # Certain system reactions like STATUS_TRANSACTION_ERROR or STATUS_UNSUPPORTED
            # are thinkable but I have doubts if they should be tolerated for Reporters.
            return GenTest_e::Result->new(
                query        => $query,
                status       => $err2type{$dbh->err()} || STATUS_UNKNOWN_ERROR,
                err          => $dbh->err(),
                errstr       => $dbh->errstr(),
                sqlstate     => $dbh->state(),
                start_time   => $start_time,
                end_time     => Time::HiRes::time()
            );
        }

        # EXECUTOR_TASK_THREAD or ....
        if (($err_type == STATUS_SKIP)             ||
            ($err_type == STATUS_SYNTAX_ERROR)     ||
            ($err_type == STATUS_UNSUPPORTED)      ||
            ($err_type == STATUS_SEMANTIC_ERROR)   ||
            ($err_type == STATUS_TRANSACTION_ERROR)  ) {
            # STATUS_SYNTAX_ERROR gets not triggered by 1064 You have an error in your SQL syntax ...
            $executor->[EXECUTOR_ERROR_COUNTS]->{$errstr}++
                if not ($execution_flags & EXECUTOR_FLAG_SILENT);
            $executor->reportError($query, $err, $errstr, $execution_flags);
        } elsif (($err_type == STATUS_SERVER_CRASHED) ||
                 ($err_type == STATUS_SERVER_KILLED)    ) {
            # STATUS_SERVER_KILLED just for completeness and (unlikely) some piece of RQG is capable
            # to manage that this status shows up here.
            my $query_for_print= shorten_message($query);
            say("$who_am_i $executor_role Query: $query_for_print failed: $err " . $sth->errstr())
                if not ($execution_flags & EXECUTOR_FLAG_SILENT);
            $executor->disconnect();
            # Lets assume some evil and complicated scenario (lost connection but no real crash)
            # ----------------------------------------------------------------------------------
            # Query from generator is a multi statement query like
            #    update row A; update row B; COMMIT ; update row C column col1 to @aux ;
            # State of session on server 1:
            #    no AUTOCOMMIT, @aux = 13, open transaction with a row updated
            # State of session on server 2:
            #    no AUTOCOMMIT, @aux = 13, open transaction with a row updated
            # We got the error when executing the single query "update row B".
            # Session on server 1:
            #    loss of connection -> rollback of update
            # Session on server 2:
            #    no AUTOCOMMIT, @aux = 13, open transaction with a row updated
            # So in case we would just reconnect (assume success) to server 1 than we would suffer
            # compared to server 2 from missing update and @aux = NULL.
            # There is IMHO only one clean solution:
            # 1. For any non first server issue ROLLBACK(if not done per disconnect) and disconnect.
            # 2. After disconnect followed by reconnect do not go on with the remaining queries of
            #    the multi query.
            #    There might be some validator running at the end of the multi statement query and
            #    being not prepared for
            #    - lose connection/reconnect between
            #    - @aux is now NULL
            #    - a single query failed
            #    etc.
            # So check first if a connect is possible.
            # Experiment because of observation 2018-06-22
            #    Even with mysql_connect_timeout => 20 added the distance between message about
            #    connection lost and connect attempt failed < 1s seen.
            # First (because easier to handle) hypothesis:
            #    The server is for some short timespan so busy especially around managing
            #    connections so that he simply denies to create a new one.
            #    2018-07-02 Up till today I have never seen a false alarm from here again.
            my $status;
            if (STATUS_OK == $executor->is_connectable()) {
                $status = STATUS_SKIP_RELOOP;
                say("INFO: $trace_addition :  The server is connectable. " .
                    Basics::return_rc_status_text($status));
            } else {
                # FIXME:
                # Check if STATUS_SERVER_CRASHED would be better.
                # Could it happen that we meet some just initiated server shutdown and what would
                # happen than?
                $status = STATUS_CRITICAL_FAILURE;
                say("INFO: $trace_addition :  The server is not connectable. Will sleep 3s and " .
                    "than " . Basics::return_rc_status_text($status));
                # The sleep is for preventing the following scenario:
                # A reporter like CrashRecovery has send SIGKILL/SIGSEGV/SIGABRT to the server and
                # exited immediate with STATUS_SERVER_KILLED. Of course worker threads will detect
                # the dead server too and exit with STATUS_CRITICAL_FAILURE if not been killed
                # earlier. Caused by heavy load and unfortunate scheduling it can happen that the
                # main process (RQG runner executing GenTest_e) detects the exited thread before the
                # exited reporter and than we might end up with the final STATUS_CRITICAL_FAILURE.
                # The reporter Backtrace will later confirm the crash and GenTest_e will transform
                # that status to STATUS_SERVER_CRASHED.
                # In case the main process would receive the status STATUS_SERVER_KILLED first than
                # the crash would be confirmed by Backtrace and the status would get transformed
                # to STATUS_OK.
                sleep(3);
            }
            return GenTest_e::Result->new(
                query        => $query,
              # status       => $err2type{$dbh->err()} || STATUS_UNKNOWN_ERROR,
                status       => $status,
                err          => $dbh->err(),
                errstr       => $dbh->errstr(),
                sqlstate     => $dbh->state(),
                start_time   => $start_time,
                end_time     => Time::HiRes::time()
            );
        } elsif ($err_type == STATUS_CRITICAL_FAILURE) {
            my $query_for_print= shorten_message($query);
            say("ERROR: $who_am_i $executor_role Query: $query_for_print failed: $err " .
                $sth->errstr() . " err_type : STATUS_SERVER_CRASHED");
            say("ERROR: $who_am_i $executor_role Handling for STATUS_CRITICAL_FAILURE is missing. " .
                "Hence returning result with status STATUS_INTERNAL_FAILURE");
            return GenTest_e::Result->new(
                query        => $query,
              # status       => $err2type{$dbh->err()} || STATUS_UNKNOWN_ERROR,
                status       => STATUS_INTERNAL_ERROR,
                err          => $dbh->err(),
                errstr       => $dbh->errstr(),
                sqlstate     => $dbh->state(),
                start_time   => $start_time,
                end_time     => Time::HiRes::time()
            );
        } elsif (not ($execution_flags & EXECUTOR_FLAG_SILENT)) {
            # Any query harvesting an error where the mapping (see top of this file) to some
            # error_type was either
            # - likely forgotten in case new failure messages get introduced.
            #   Example of what is missing
            #   use constant  ER_DO_NOT_WANT   => 7777;
            #   ER_DO_NOT_WANT()               => STATUS_UNSUPPORTED,
            # or
            # - intentionally deactivated or not made at all because we want become aware of it
            #   Example:
            #   1064 You have an error in your SQL syntax ... does not get mapped to
            #   STATUS_SYNTAX_ERROR
            # has err_type == 0 in order to "land" here and get printed.
            my $errstr = $executor->normalizeError($sth->errstr());
            $executor->[EXECUTOR_ERROR_COUNTS]->{$errstr}++;
            my $query_for_print= shorten_message($query);
            say("$who_am_i $executor_role Query: $query_for_print failed: $err , errstr: " .
                $sth->errstr());
        }

        $result = GenTest_e::Result->new(
            query           => $query,
            status          => $err_type || STATUS_UNKNOWN_ERROR,
            err             => $err,
            errstr          => $errstr,
            sqlstate        => $sth->state(),
            start_time      => $start_time,
            end_time        => $end_time,
            performance     => $performance
        );

    } else {
        # An execute without error up till now.
        #--------------------------------------
        my $mysql_info = $dbh->{'mysql_info'};
        $mysql_info= '' unless defined $mysql_info;
        my ($matched_rows, $changed_rows) = $mysql_info =~ m{^Rows matched:\s+(\d+)\s+Changed:\s+(\d+)}sgio;
        my $column_names = $sth->{NAME} if $sth and $sth->{NUM_OF_FIELDS};
        my $column_types = $sth->{mysql_type_name} if $sth and $sth->{NUM_OF_FIELDS};

        if (defined $performance) {
            # say("DEBUG: Executor: $trace_addition Before performance 'record'");
            # FIXME:
            # This can be a victim of a crash.
            $performance->record();
            $performance->setExecutionTime($execution_time);
        }

        if ((not defined $sth->{NUM_OF_FIELDS}) || ($sth->{NUM_OF_FIELDS} == 0)) {
            $result = GenTest_e::Result->new(
                query           => $query,
                status          => STATUS_OK,
                affected_rows   => $affected_rows,
                matched_rows    => $matched_rows,
                changed_rows    => $changed_rows,
                info            => $mysql_info,
                start_time      => $start_time,
                end_time        => $end_time,
                performance     => $performance
            );
            $executor->[EXECUTOR_ERROR_COUNTS]->{'(no error)'}++
                if not ($execution_flags & EXECUTOR_FLAG_SILENT);
        } else {
            my @data;                   #
            my %data_hash;              # Filled if   $execution_flags & EXECUTOR_FLAG_HASH_DATA
            my $row_count = 0;
            my $result_status = STATUS_OK;

            # What follows could fail because of real crash or connection killed etc.
            # The if (defined $sth->err())  a bit later should catch this.
            while (my @row = $sth->fetchrow_array()) {
                $row_count++;
                if ($execution_flags & EXECUTOR_FLAG_HASH_DATA) {
                    $data_hash{substr(Digest::MD5::md5_hex(@row), 0, 3)}++;
                } else {
                    push @data, \@row;
                }

                last if ($row_count > MAX_ROWS_THRESHOLD and
                    $executor->task() == GenTest_e::Executor::EXECUTOR_TASK_THREAD);
            }

            # Do one extra check to catch 'query execution was interrupted' error
            if (defined $sth->err()) {
                $result_status = $err2type{$sth->err()};
                @data = ();
            } elsif ($row_count > MAX_ROWS_THRESHOLD and
                     $executor->task() == GenTest_e::Executor::EXECUTOR_TASK_THREAD) {
                my $query_for_print= shorten_message($query);
                @data = ();
                say("Query: $query_for_print returned more than MAX_ROWS_THRESHOLD (" .
                    MAX_ROWS_THRESHOLD() . ") rows. Will kill it ...");
                $executor->[EXECUTOR_RETURNED_ROW_COUNTS]->{'>MAX_ROWS_THRESHOLD'}++;

                my $kill_dbh = get_dbh($executor->dsn(), 'QueryKiller', undef);
                if (not defined $kill_dbh) {
                    my $status = STATUS_CRITICAL_FAILURE;
                    my $message_part = "ERROR: $who_am_i QueryKiller:";
                    say("$message_part. " . Basics::return_rc_status_text($status));
                    $sth->finish();
                    return GenTest_e::Result->new(
                        query       => '/* During auxiliary connect */',
                        status      => $status,
                    );
                }
                # Per manual:
                # Killing queries that repair or create indexes on MyISAM and Aria tables may result
                # in corrupted tables. Use the SOFT option to avoid this!
                # We are fortunately on the safe side because even though CHECK/REPAIR ... deliver
                # result sets too they are smaller than MAX_ROWS_THRESHOLD.
                my $aux_query = "KILL QUERY " . $executor->connectionId() . '/* ' .
                                "QueryKiller for $executor_role " . '*/';
                # exp_server_kill($who_am_i, $aux_query);
                my $aux_status = GenTest_e::Executor::MySQL::run_do($kill_dbh, 'QueryKiller',
                                                                    $aux_query);
                # $kill_dbh and $sth are no more needed no matter what $aux_status is.
                $kill_dbh->disconnect();
                $sth->finish();
                if (STATUS_OK != $aux_status) {
                  return GenTest_e::Result->new(
                      query       => '/* During auxiliary query */',
                      status      => $aux_status,
                  );
                }

                $aux_query = "SELECT 1 FROM DUAL /* Guard query so that the KILL QUERY we just " .
                             "issued does not affect future queries */;";
                # exp_server_kill($who_am_i, $aux_query);
                $aux_status = GenTest_e::Executor::MySQL::run_do($dbh, $executor_role, $aux_query);
                if (STATUS_OK != $aux_status) {
                    return GenTest_e::Result->new(
                        query       => '/* During auxiliary query */',
                        status      => $aux_status,
                    );
                }
                $result_status = STATUS_SKIP;
            } elsif ($execution_flags & EXECUTOR_FLAG_HASH_DATA) {
                while (my ($key, $value) = each %data_hash) {
                    push @data, [ $key , $value ];
                }
            }

            # FIXME:
            # We have @data and %data_hash.
            # Figure out when what (just one or both) is filled and pick the right.

            # Check if the query was a CHECK TABLE/VIEW and if we harvested a result set which points
            # clear to data corruption in InnoDB. In the moment all other bad cases get ignored.
            # ------------------------------------------------------------------------------------------
            if ($query =~ m{check\s+table\s+}i or $query =~ m{check\s+view\s+}i) {
                # Experiment for checking if the reporter 'RestartConsistency*.pm' works correct.
                # if ($executor->task() == GenTest_e::Executor::EXECUTOR_TASK_REPORTER) {
                #         $result_status = STATUS_DATABASE_CORRUPTION;
                # }
                my $full_result = "Executor: Full result of ->$query<-";

                foreach my $data_elem (@data) {
                    my $line = join(" ", @{$data_elem});
                    $full_result .= "\n" . join(" ", @{$data_elem});
                    my ($ct_table, $ct_Op, $ct_Msg_type, $ct_Msg_text) = @{$data_elem};
                    # We can have
                    # - concurrency by other session or EVENT and they may run
                    #   kill query or SQL causing locks
                    # - a short max_statement_time
                    #   Example:
                    #   <TS> [118034] test.t3 check Error Query execution was interrupted
                    #   <TS> [118034] test.t3 check error Corrupt <=====
                    # - a history where
                    #   - base tables of a view were dropped
                    #   - a table/view name gets picked but that object does no more or did never exist
                    # checkDatabaseIntegrity within MySQLd.pm picks only existing views and base tables.
                    if ((# The semantic error Table/View to be checked does no more or did never exist
                         # has to be accepted.
                         $ct_Msg_text =~ /Table \'$ct_table\' doesn\'t exist/ and
                         'checkDatabaseIntegrity' ne $executor->role             ) or
                        ($ct_Msg_text =~ /Deadlock found when trying to get lock/) or
                        ($ct_Msg_text =~ /Lock wait timeout exceeded/)             or
                        ($ct_Msg_text =~ /Query execution was interrupted/)          ) {
                        say("INFO: Executor: For query '" . $query . "' most likely legitimate '" .
                            $line . "' observed. Will return STATUS_SKIP.");
                        return GenTest_e::Result->new(
                            query       => $query,
                            status      => STATUS_SKIP,
                        );
                    }
                    say("DEBUG: Query '" . $query . "' harvested '" . $line . "'.") if $debug_here;
                }

                # Dangling view test.extra_v1 AS SELECT * FROM test.extra_t1
                # Error Table 'test.extra_t1' doesn't exist
                # View 'test.extra_v1' references invalid table(s) or column(s) or function(s) or ...
                # Corrupt
                if ($full_result =~ /View .{1,200} references invalid table\(s\)/) {
                    say("DEBUG: " . $full_result . "\nobserved. Its most probably not a bug.")
                        if $debug_here;
                    return GenTest_e::Result->new(
                            query       => $query,
                            status      => STATUS_SKIP,
                    );
                }
                if ($full_result =~ /View .{1,200} contains view recursion/) {
                    say("DEBUG: " . $full_result . "\nobserved. Its most probably not a bug.")
                        if $debug_here;
                    return GenTest_e::Result->new(
                            query       => $query,
                            status      => STATUS_SKIP,
                    );
                }

                foreach my $data_elem (@data) {
                    # ->test.t1<->check<->Warning<->InnoDB: Index 'c' contains 1 entries, should be 0.<-
                    my $line = join(" ", @{$data_elem});
                    # say("DEBUG: Executor: line ->" . $line . "<-");
                    my ($ct_table, $ct_Op, $ct_Msg_type, $ct_Msg_text) = @{$data_elem};
                    # say("DEBUG: Executor: $ct_Msg_text -->" . $ct_Msg_text . "<-");
                    next if ('status' eq $ct_Msg_type or 'note' eq $ct_Msg_type);
                    if ('Warning' eq $ct_Msg_type) {
                        # Regarding the "cannot be used in the GENERATED ALWAYS":
                        # CREATE TABLE t1 (
                        #    col1 INT PRIMARY KEY, col_string CHAR(20),
                        #    col_string_g VARCHAR(13) GENERATED ALWAYS AS (SUBSTR(col_string,4,13)) PERSISTENT
                        # ) ENGINE = InnoDB ROW_FORMAT = Dynamic ;
                        # harvests in 10.4
                        # Warnings:
                        # Warning 1901    Function or expression 'substr(`col_string`,4,13)' cannot be
                        #                 used in the GENERATED ALWAYS AS clause of `col_string_g`
                        # Warning 1105    Expression depends on the @@sql_mode value PAD_CHAR_TO_FULL_LENGTH
                        # + that warning during CHECK TABLE.
                        # In 10.6 already the CREATE TABLE fails with
                        # ERROR HY000: Function or expression 'substr(`col_string`,4,13)' cannot be used
                        #       in the GENERATED ALWAYS AS clause of `col_string_g`
                        # Per Marko: The InnoDB messages come only if CHECK ... EXTENDED
                        #            + harmless/to be expected.
                        if ($ct_Msg_text =~ /InnoDB: Unpurged clustered index record/            or
                            $ct_Msg_text =~ /InnoDB: Clustered index record with stale history/  or
                            $ct_Msg_text =~ /InnoDB: Clustered index record not found for index/ or
                            $ct_Msg_text =~ /Function or expression .{1,200} cannot be used in the GENERATED ALWAYS .{1,200}/ or
                            $ct_Msg_text =~ /Expression depends on the \@\@sql_mode .{1,30}/       )
                        {
                            say("DEBUG: Executor: For query '" . $query . "' harmless '" . $line . "' observed.")
                                if $debug_here;
                            next;
                        } else {
                            say("ERROR: Executor: The query '" . $query . "' passed but has a result set line '" .
                                $line . "'.");
                                $result_status = STATUS_DATABASE_CORRUPTION;
                        }
                    }
                    if ('Error') {
                        say("ERROR: Executor: The query '$query' passed but has a result set line\n" .
                            "ERROR: ->$line<-.\n");
                        $result_status = STATUS_DATABASE_CORRUPTION;
                    }
                    if ($result_status == STATUS_DATABASE_CORRUPTION) {
                        if ($executor->task() == GenTest_e::Executor::EXECUTOR_TASK_THREAD or
                            $executor->task() == GenTest_e::Executor::EXECUTOR_TASK_REPORTER) {
                            # A process which can exit without harm.
                            # Enforcing some rapid test end might look attractive.
                            # But without knowing the server process we can only request a SHUTDOWN.
                            # And during experiments that caused RQG reporting finally a DEADLOCK.
                            # $dbh->do("SHUTDOWN");
                            say("ERROR: $full_result");
                            say("ERROR: Executor: " . Basics::exit_status_text($result_status));
                            exit $result_status;
                        } else {
                            # A process like rqg.pl which should not exit without cleanup.
                            say("ERROR: $full_result");
                            say("ERROR: Executor: " . Basics::return_rc_status_text($result_status));
                            return GenTest_e::Result->new(
                               query       => $query,
                               status      => $result_status,
                            );
                        }
                    }
                }
            } # End of CHECK TABLE/VIEW handling

            $result = GenTest_e::Result->new(
                query           => $query,
                status          => $result_status,
                affected_rows   => $affected_rows,
                data            => \@data,
                start_time      => $start_time,
                end_time        => $end_time,
                column_names    => $column_names,
                column_types    => $column_types,
                performance     => $performance
            );

            $executor->[EXECUTOR_ERROR_COUNTS]->{'(no error)'}++
                if not ($execution_flags & EXECUTOR_FLAG_SILENT);

        }

        $sth->finish();

        if ($sth->{mysql_warning_count} > 0) {
            eval {
                my $aux_query = "SHOW WARNINGS";
                # exp_server_kill($who_am_i, $aux_query);
                my $warnings   = $dbh->selectall_arrayref($aux_query);
                my $error      = $dbh->err();
                my $error_type = STATUS_OK;
                if (defined $error) {
                    $error_type = $err2type{$error} || STATUS_OK;
                    my $message_part = "$who_am_i $executor_role. Auxiliary query ->" . $aux_query .
                                       "<- failed: $error " .  $dbh->errstr();
                    my $status = $error_type;
                    if (($error_type == STATUS_SERVER_CRASHED) ||
                        ($error_type == STATUS_SERVER_KILLED)) {
                        $executor->disconnect(); # FIXME: Would be that good?
                        if (STATUS_OK == $executor->is_connectable()) {
                            $status = STATUS_SKIP_RELOOP;
                            say("INFO: $message_part");
                            say("INFO: $trace_addition : The server is connectable. " .
                                Basics::return_rc_status_text($status));
                        } else {
                            $status = STATUS_CRITICAL_FAILURE;
                            say("ERROR: $message_part");
                            say("INFO: $trace_addition :  The server is not connectable. Will sleep " .
                                "3s and than " . Basics::return_rc_status_text($status));
                            sleep(3);
                        }
                    } else {
                         say("ERROR: $message_part. " . Basics::return_rc_status_text($status));
                    }
                    return GenTest_e::Result->new(
                        query       => $query . '/* During additional auxiliary query */',
                        status      => $status,
                    );
                }
                $result->setWarnings($warnings);
            }
        }

        if ($result->status() == STATUS_OK) {
            # Now we have excluded certain classes of failing statements where all what follows
            # makes no sense up till additional trouble with not initialized values etc.
            #
            # (mleich)
            # What follows gets only executed if   rqg_debug() ....  hence it
            # - runs not often
            #   I appreciate that because its serious overhead and maybe dangerous(what if KILL QUERY..)
            #   especially for DDL/DML concurrency crash testing.
            # - was not seen as very important when it was written.
            # EXPLAIN on for example DELETE works. But no idea if an explain on that would be valuable
            # or if the counters collected here are of serious value at all.
            # SELECT ... INTO @user_variable harvests systematic that the return of
            # $result->rows() is not defined. So exclude that kind of SELECT.
            #
            if ( (rqg_debug()) && (! ($execution_flags & EXECUTOR_FLAG_SILENT)) ) {
                if (($query =~ m{^\s*select}sio) and (not $query =~ m{^\s*select\s.*into @}sio)) {
                    # exp_server_kill($who_am_i, "executor->explain");
                    $executor->explain($query);
                    my $row_group = $result->rows() > 100 ? '>100' : ($result->rows() > 10 ? ">10" : sprintf("%5d", $sth->rows()) );
                    $executor->[EXECUTOR_RETURNED_ROW_COUNTS]->{$row_group}++;
                } elsif ($query =~ m{^\s*(update|delete|insert|replace)}sio) {
                    my $row_group = $affected_rows > 100 ? '>100' : ($affected_rows > 10 ? ">10" : sprintf("%5d", $affected_rows) );
                    $executor->[EXECUTOR_AFFECTED_ROW_COUNTS]->{$row_group}++;
                }
            }
        }
    } # End of EXECUTE without error handling

    return $result;

} # End of sub execute

sub version {
    my $executor = shift;
    if (defined $version) {
        return $version;
    } else {
        # exp_server_kill("version", "selectrow_array");
        my $dbh = $executor->dbh();
        my $aux_query = "SELECT VERSION()";
        SQLtrace::sqltrace_before_execution($aux_query);
        my $row_array = $dbh->selectrow_array($aux_query);
        my $error =        $dbh->err();
        my $error_type =   STATUS_OK;
        SQLtrace::sqltrace_after_execution($error);
        if (defined $error) {
            my $message_part = "ERROR: " . $executor->role . " query ->" . $aux_query .
                               "<- failed: $error " .  $dbh->errstr();
            say("$message_part. Will return undef.");
        }
        return $row_array;
        # Hint: A caller like get_connection could process $dbh->err().
   }
}

sub versionNumeric {
   my $executor = shift;
   version() =~ /([0-9]+)\.([0-9]+)\.([0-9]+)/;
   return sprintf("%02d%02d%02d",int($1),int($2),int($3));
}

sub slaveInfo {
   my $executor = shift;
   my $slave_info = $executor->dbh()->selectrow_arrayref("SHOW SLAVE HOSTS");
   return ($slave_info->[SLAVE_INFO_HOST], $slave_info->[SLAVE_INFO_PORT]);
}

sub masterStatus {
   my $executor = shift;
   return $executor->dbh()->selectrow_array("SHOW MASTER STATUS");
}

#
# Run EXPLAIN on the query in question, recording all notes in the EXPLAIN's Extra field into the statistics
#

sub explain {
   # FIXME:
   # Prepare, execute, fetchrow_hashref, do can fail
   my ($executor, $query) = @_;

   return unless is_query_explainable($executor,$query);

   my $sth_output = $executor->dbh()->prepare("EXPLAIN /*!50100 PARTITIONS */ $query");

   $sth_output->execute();

   my @explain_fragments;

   while (my $explain_row = $sth_output->fetchrow_hashref()) {
      push @explain_fragments, "select_type: " . ($explain_row->{select_type} || '(empty)');
      push @explain_fragments, "type: " . ($explain_row->{type} || '(empty)');
      push @explain_fragments, "partitions: " . $explain_row->{table} . ":" . $explain_row->{partitions} if defined $explain_row->{partitions};

      push @explain_fragments, "ref: " . ($explain_row->{ref} || '(empty)');

      foreach my $extra_item (split('; ', ($explain_row->{Extra} || '(empty)')) ) {
         $extra_item =~ s{0x.*?\)}{%d\)}sgio;
         $extra_item =~ s{PRIMARY|[a-z_]+_key|i_l_[a-z_]+}{%s}sgio;
         push @explain_fragments, "extra: " . $extra_item;
      }
   }

   $executor->dbh()->do("EXPLAIN EXTENDED $query");
   my $explain_extended = $executor->dbh()->selectrow_arrayref("SHOW WARNINGS");
   if (defined $explain_extended) {
      push @explain_fragments, $explain_extended->[2] =~ m{<[a-z_0-9\-]*?>}sgo;
   }

   foreach my $explain_fragment (@explain_fragments) {
      $executor->[EXECUTOR_EXPLAIN_COUNTS]->{$explain_fragment}++;
      if ($executor->[EXECUTOR_EXPLAIN_COUNTS]->{$explain_fragment} > RARE_QUERY_THRESHOLD) {
         delete $executor->[EXECUTOR_EXPLAIN_QUERIES]->{$explain_fragment};
      } else {
         push @{$executor->[EXECUTOR_EXPLAIN_QUERIES]->{$explain_fragment}}, $query;
      }
   }

}

# If Oracle ever issues 5.10.x, this logic will stop working.
# Until then it should be fine
sub is_query_explainable {
   my ($executor, $query) = @_;

   if ( $major_version > 5.5 ) {
      return $query =~ /^\s*(?:SELECT|UPDATE|DELETE|INSERT)/i;
   } else {
      return $query =~ /^\s*SELECT/;
   }
}

sub disconnect {
    my $executor = shift;
    if (defined $executor->dbh()) {
        # Experimental code. Do not remove even though currently disabled.
        # Intention: Accelerate the generation of data by temporary increase of buffer pool size.
        # if ($executor->task() == GenTest_e::Executor::EXECUTOR_TASK_GENDATA) {
        #     my $status = $executor->restore_innodb_buffer_pool_size ;
        #     # FIXME: What to do with $status?
        # }
        # 2022-05-30 Observed once:
        # The corresponding history:
        # ERROR: GenTest_e::Executor::MySQL::get_dbh: Thread6 connect to dsn ... failed:
        #        Host 'localhost' is not allowed to connect to this MariaDB server. Will return undef
        # ERROR: GenTest_e::Executor::MySQL::get_connection: Thread6:
        #        Will return status STATUS_SERVER_CRASHED(101).
        # ERROR: GenTest_e::Executor::MySQL::init: Getting a proper connection for Thread6
        #        failed with 101. Will return status STATUS_SERVER_CRASHED(101).
        # GenTest_e failed to create a Mixer for Thread6. Status will be set to ENVIRONMENT_FAILURE
        # GenTest_e: child 241752 is being stopped with status STATUS_ENVIRONMENT_FAILURE
        # Process with pid 241752 for Thread6 ended with status STATUS_ENVIRONMENT_FAILURE
        # Killing (TERM) remaining worker process with pid 241743...
        # ...
        # Use of uninitialized value in concatenation (.) or string
        # Assumption:
        # The thread emitting the "Use of uninitialized value" is already connected but has
        # not yet determined its connectionId.
        my $connectionId = $executor->connectionId();
        $connectionId = "unknown" if not defined $connectionId;
        say('DEBUG: /* E_R ' . $executor->role . ' QNO 0 CON_ID ' .
                         $connectionId . ' before disconnect. */ ');
        $executor->dbh()->disconnect();
    }
    $executor->setDbh(undef);
    $executor->setConnectionId(undef);
}

sub DESTROY {
    my $executor = shift;
    $executor->disconnect();

    # Exclude executors with tasks where the statistics makes no sense.
    return STATUS_OK if $executor->task() == GenTest_e::Executor::EXECUTOR_TASK_REPORTER;
    return STATUS_OK if $executor->task() == GenTest_e::Executor::EXECUTOR_TASK_GENDATA;
    return STATUS_OK if $executor->task() == GenTest_e::Executor::EXECUTOR_TASK_CHECKER;

    if ((rqg_debug()) && (defined $executor->[EXECUTOR_STATUS_COUNTS])) {
        # FIXME: Are there "roles" where the statistics makes no sense? Gendata*?
        my $executor_role;
        # FIXME:
        # For not defined $executor->role
        #    Carp::cluck on first use + set to 'Unknown'
        if (not defined $executor->role) {
            say("WARN: No executor role defined. Set it to 'Unknown'.");
            $executor_role = 'Unknown';
        } else {
            $executor_role = $executor->role;
        }
        # Diff to older code:
        # Collect everything in some huge string with line breaks and print so all at once.
        # This reduces the risk that other stuff gets written by other threads etc. between.
        my $statistics_part =  "Statistics of Executor for $executor_role (" . $executor->dsn() . ")";
        my $statistics =       $statistics_part . " ------- Begin\n";
        use Data::Dumper;
        $Data::Dumper::Sortkeys = 1;
        $statistics = $statistics . "Rows returned:\n";
        $statistics = $statistics . Dumper($executor->[EXECUTOR_RETURNED_ROW_COUNTS]) . "\n";
        $statistics = $statistics . "Rows affected:\n";
        $statistics = $statistics . Dumper($executor->[EXECUTOR_AFFECTED_ROW_COUNTS]) . "\n";
        $statistics = $statistics . "Explain items:\n";
        $statistics = $statistics . Dumper($executor->[EXECUTOR_EXPLAIN_COUNTS])      . "\n";
        $statistics = $statistics . "Errors:\n";
        $statistics = $statistics . Dumper($executor->[EXECUTOR_ERROR_COUNTS])        . "\n";
#       say("Rare EXPLAIN items:");
#       print Dumper $executor->[EXECUTOR_EXPLAIN_QUERIES];
        # Diff to older code:
        # Sort the keys in order to get better comparable message lines.
        $statistics = $statistics . "Statuses: " . join(', ',
                      map { status2text($_) . ": " . $executor->[EXECUTOR_STATUS_COUNTS]->{$_} .
                          " queries" } sort keys %{$executor->[EXECUTOR_STATUS_COUNTS]}) . "\n";
        $statistics =  $statistics . $statistics_part . " ------- End\n";
        say($statistics);
    }
}

sub currentSchema {
# Return
# - undef, status if hitting an error
# - assigned or if nothing was assigned current database, STATUS_OK
# If a $schema was assigned than move (USE ...) into it and return undef if that fails.
#

    my ($executor, $schema) = @_;

    my $who_am_i = Basics::who_am_i;
    my $status;

    # Hint:
    # $executor->dbh() is safe because it just returns the known dbh or undef.
    my $dbh = $executor->dbh();
    if (not defined $dbh) {
        $status = STATUS_CRITICAL_FAILURE;
        say("ERROR: $who_am_i dbh is not defined. Will return undef, $status");
        return undef, $status;
    }

    my $executor_role = $executor->role();
    if (defined $schema) {
        # FIXME: Why not rund_do??
        my $aux_query = "USE $schema";
        my $result = $executor->execute("$aux_query");
        # We cannot live with any error.
        my $err = $result->err;
        my $errstr = $result->errstr;
        my $status = $result->status;
        if (STATUS_OK != $status) {
            say("ERROR: $who_am_i Query ->" . $aux_query . "<- failed with status $status $err : $errstr. " .
                "Will return undef, $status");
            return undef, $status;
        }
    }
    # ---------------------
    # Impact of SIGKILLed server process
    # system("killall -9 mysqld mariadbd");
    # sleep 5;
    #
    # Impact of wrong syntax
    # my $aux_query =  "OMO";                    # STATUS_UNKNOWN_ERROR(2)   1064 syntax error
    #
    # Impact of missing table
    # my $aux_query =  "SELECT 1 FROM omo";      # STATUS_SEMANTIC_ERROR(22) 1146 missing table
    #
    # Impact of empty result set
    # my $aux_query =  "SELECT 1 WHERE 1 = 2";
    #
    # Impact of result set with too many rows.
    # my $aux_query =  "SELECT 1 UNION SELECT 2";

    my $aux_query =  "SELECT DATABASE()";

    # FIXME:
    # Is there a shorter and more elegant way to do what follows?
    # The old code just used a
    #    $executor->dbh()->selectrow_array("SELECT DATABASE()");
    # without rather recommended checks.
    # And what we lack at the current position is mostly just a complete trace addition
    # ($query_count is not accessible here) and sqltracing.
    my $res = $executor->execute($aux_query);
    # The status is either STATUS_OK or $err mapped to some status
    $status = $res->status;
    if (STATUS_OK != $status) {
        if (STATUS_SKIP        == $status or
            STATUS_SKIP_RELOOP == $status   ) {
            return undef, $status;
        }
        my $err    = $res->err;
        my $errstr = $res->errstr;
        say("ERROR: $who_am_i Query ->" . $aux_query . "<- failed with status : $status, " .
            " $err : $errstr. Will return undef, $status");
        return undef, $status;
    }
    my $value_list_ref = $res->data;
    if (not defined $value_list_ref) {
        my $status = STATUS_CRITICAL_FAILURE;
        say("ERROR: $who_am_i Query ->" . $aux_query . "<- provided some undef result set. " .
            "Will return undef, $status");
        return undef, $status;
    }
    my @result_row_ref_array = @{$value_list_ref};
    if (0 == scalar @result_row_ref_array) {
        my $status = STATUS_CRITICAL_FAILURE;
        say("ERROR: $who_am_i Query ->" . $aux_query . "<- provided some empty result set. " .
            "Will return undef, $status");
        return undef, $status;
    }
    if (1 != scalar @result_row_ref_array) {
        my $status = STATUS_CRITICAL_FAILURE;
        say("ERROR: $who_am_i Query ->" . $aux_query . "<- provided some too big result set. " .
            "Will return undef, $status");
        return undef, $status;
    }
    my $database = $result_row_ref_array[0][0];
    if (defined $database) {
        return $database, STATUS_OK;
    } else {
        my $status = STATUS_CRITICAL_FAILURE;
        say("ERROR: $who_am_i Query ->" . $aux_query . "<- provided no valid result. " .
            "Will return undef, $status");
        return undef, $status;
    }
}


sub errorType {
   return undef if not defined $_[0];
   return $err2type{$_[0]} || STATUS_UNKNOWN_ERROR ;
}

sub normalizeError {
    my ($executor, $errstr) = @_;

    foreach my $i (0..$#errors) {
       last if $errstr =~ s{$patterns[$i]}{$errors[$i]}s;
    }

    # Remove that marker (unique per any statement executed by the server) in case of
    # debug statistics.
    # <part of a query> /* E_R Thread23 QNO 6957 CON_ID 14 */
    $errstr =~ s{\/\* E_R Thread\d+ QNO \d+ CON_ID \d+ \*\/}{}sgio;

    # Make all errors involving numbers the same, e.g. duplicate key errors.
    $errstr =~ s{\d+}{%d}sgio if $errstr !~ m{from storage engine}sio;

    $errstr =~ s{\.\*\?}{%s}sgio;

    return $errstr;
}


sub getSchemaMetaData {
   ## Return the result from a query with the following columns:
   ## 1. Schema (aka database) name
   ## 2. Table name
   ## 3. TABLE for tables VIEW for views and MISC for other stuff
   ## 4. Column name
   ## 5. PRIMARY for primary key, INDEXED for indexed column and "ORDINARY" for all other columns
   ## 6. generalized data type (INT, FLOAT, BLOB, etc.)
   ## 7. real data type
   ## or undef if hitting an error.
   ## SCHEMAs without tables and also the maybe existing SCHEMA 'rqg' get ignored.
   ## Hence "_database" will never return their name.

    # The caller has to take care that the executor task is set to EXECUTOR_TASK_CACHER.
    # Otherwise we might run come into trouble because of too small max_statement_timeout.

    my ($self) = @_; # $self is an executor.

    my $dbh = $self->dbh;
    # Check if its undef

    my $who_am_i = Basics::who_am_i;

    my $role = $self->role;
    my $trace_addition = ' /* E_R ' . $role . ' QNO 0' .
                        ' CON_ID ' . $self->connectionId() . ' */ ';

    # exp_server_kill("getSchemaMetaData", $query);
    my $status;
    my $query =
        "SELECT DISTINCT " .
                "CASE WHEN table_schema = 'information_schema' ".
                     "THEN 'INFORMATION_SCHEMA' ".  ## Hack due to
                                                    ## weird MySQL
                                                    ## behaviour on
                                                    ## schema names
                                                    ## (See Bug#49708)
                     "ELSE table_schema END AS table_schema, ".
               "table_name, ".
               "CASE WHEN table_type = 'BASE TABLE' THEN 'table' ".
                    "WHEN table_type = 'SYSTEM VERSIONED' THEN 'table' ".
                    "WHEN table_type = 'SEQUENCE' THEN 'table' ".
                    "WHEN table_type = 'VIEW' THEN 'view' ".
                    "WHEN table_type = 'SYSTEM VIEW' then 'view' ".
                    "ELSE 'misc' END AS table_type, ".
               "column_name, ".
               "CASE WHEN column_key = 'PRI' THEN 'primary' ".
                    "WHEN column_key IN ('MUL','UNI') THEN 'indexed' ".
                    "WHEN index_name = 'PRIMARY' THEN 'primary' ".
                    "WHEN non_unique IS NOT NULL THEN 'indexed' ".
                    "ELSE 'ordinary' END AS column_key, ".
               "CASE WHEN data_type IN ('bit','tinyint','smallint','mediumint','int','bigint') THEN 'int' ".
                    "WHEN data_type IN ('float','double') THEN 'float' ".
                    "WHEN data_type IN ('decimal') THEN 'decimal' ".
                    "WHEN data_type IN ('datetime','timestamp') THEN 'timestamp' ".
                    "WHEN data_type IN ('char','varchar','binary','varbinary') THEN 'char' ".
                    "WHEN data_type IN ('tinyblob','blob','mediumblob','longblob') THEN 'blob' ".
                    "WHEN data_type IN ('tinytext','text','mediumtext','longtext') THEN 'text' ".
                    "ELSE data_type END AS data_type_normalized, ".
               "data_type, ".
               "character_maximum_length, ".
               "table_rows ".
        "FROM information_schema.tables INNER JOIN ".
             "information_schema.columns USING(table_schema,table_name) LEFT JOIN ".
             "information_schema.statistics USING(table_schema,table_name,column_name) ".

        "WHERE table_schema <> 'rqg' AND table_name <> 'DUMMY'" . $trace_addition ;

   SQLtrace::sqltrace_before_execution($query);

   # exp_server_kill("getSchemaMetaData", $query);
   my $res =   $self->dbh()->selectall_arrayref($query);
   my $error = $self->dbh()->err();
   SQLtrace::sqltrace_after_execution($error);
   if (not defined $res) {
       # SQL syntax error or DB server dead.
       # In case of empty result sets we will not end up here.
       my $error = $self->dbh()->err();
       Carp::cluck("ERROR: getSchemaMetaData: selectall_arrayref failed.");
       say("ERROR: getSchemaMetaData: The query was ->$query<-.");
       say("ERROR: $error: " . $self->dbh()->errstr());
       say("ERROR: getSchemaMetaData: Will return undef.");
       return undef;
   }

   my %table_rows = ();
   foreach my $i (0..$#$res) {
      my $tbl = $res->[$i]->[0] . '.' . $res->[$i]->[1];
      if ((not defined $table_rows{$tbl}) or ($table_rows{$tbl} eq 'NULL') or
          ($table_rows{$tbl} eq '')) {
         $query = "SELECT COUNT(*) FROM $tbl" . $trace_addition;
         SQLtrace::sqltrace_before_execution($query);
         # exp_server_kill("getSchemaMetaData", $query);
         my $count_row = $self->dbh()->selectrow_arrayref($query);
         $error =        $self->dbh()->err();
         SQLtrace::sqltrace_after_execution($error);
         if (not defined $count_row) {
             # SQL syntax error or DB server dead.
             # In case of empty result sets we will not end up here.
             my $error = $self->dbh()->err();
             Carp::cluck("ERROR: getSchemaMetaData: selectrow_arrayref failed.");
             say("ERROR: getSchemaMetaData: The query was ->$query<-.");
             say("ERROR: $error: " . $self->dbh()->errstr());
             say("ERROR: getSchemaMetaData: Will return undef.");
             return undef;
         }
         $table_rows{$tbl} = $count_row->[0];
      }
      $res->[$i]->[8] = $table_rows{$tbl};
   }

   return $res;

} # End of sub getSchemaMetaData

sub getCollationMetaData {
    ## Return the result from a query with the following columns:
    ## 1. Collation name
    ## 2. Character set
    ## or undef if hitting an error.
    #     $self is an executor
    my ($self) = @_;
    my $who_am_i = Basics::who_am_i;
    my $query = "SELECT collation_name,character_set_name FROM information_schema.collations";
    # exp_server_kill($who_am_i, $query);

    my $result = $self->execute($query);
    my $res = $result->data;
    if (not defined $res) {
        # SQL syntax error, DB server dead but not empty result set
        my $error = $result->err;
        say("FATAL ERROR: $who_am_i The query ->$query<- failed with error $error. " .
            "Will return undef.");
        return undef;
    }
    return $res;
}

sub read_only {
   my $executor = shift;
   my $dbh = $executor->dbh();
   # FIXME: This can fail too, replace with ->execute.
   my ($grant_command) = $dbh->selectrow_array("SHOW GRANTS FOR CURRENT_USER()");
   my ($grants) = $grant_command =~ m{^grant (.*?) on}sio;
   if (uc($grants) eq 'SELECT') {
      return 1;
   } else {
      return 0;
   }
}

sub is_connectable {
    # To be used in case some worker thread lost his connection (STATUS_SERVER_CRASHED) but we need
    # to figure out if the reason was a
    # - previous KILL SESSION <own> or COMMIT/ROLLBACK RELEASE
    # - KILL SESSION <our> issued by some other session
    # - "death" of server
    my $executor = shift;

    my $role = "ConnectChecker";
    # exp_server_kill("is_connectable", "Connect");
    my $check_dbh = get_dbh($executor->dsn(), $role, undef);
    my $msg_snip = "Executor: Helper for " . $executor->role . " figured out: The server is ";
    if (defined $check_dbh) {
        say("DEBUG: " . $msg_snip . "connectable.")
            if $debug_here;
        $check_dbh->disconnect();
        return STATUS_OK;
    } else {
        say("ERROR: " . $msg_snip . "not connectable.");
        return STATUS_SERVER_CRASHED;
    }
}

sub exp_server_kill {
    # exp_server_kill is dedicated for experimenting/debugging only.
    my ($who_am_i, $where) = @_;
    say("EXPERIMENT: $who_am_i Kill all servers before calling ->" . $where . "<-");
    system("killall -9 mysqld mariadbd");
    sleep 3;
}

sub run_do {
# Just some SQL command without result set.
# Sample call:
# my $status = GenTest_e::Executor::MySQL::run_do($dbh, $role, $query);

    my ($dbh, $role, $query) = @_;

    my $who_am_i = Basics::who_am_i;

    if (not defined $dbh) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("FATAL ERROR: dbh is not defined. ".
                    Basics::exit_status_text($status));
        exit $status;
    }
    if (not defined $role) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("FATAL ERROR: role is not defined. " .
                    Basics::exit_status_text($status));
        exit $status;
    }
    if (not defined $query) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("FATAL ERROR: query is not defined. " .
                    Basics::exit_status_text($status));
        exit $status;
    }

    SQLtrace::sqltrace_before_execution($query);
    # exp_server_kill($who_am_i, $query);
    $dbh->do($query);
    my $error = $dbh->err();
    my $error_type = STATUS_OK;
    SQLtrace::sqltrace_after_execution($error);
    if (defined $error) {
        $error_type = $err2type{$error} || STATUS_OK;
        say("ERROR: $who_am_i Role: " . $role . " query ->" . $query . "<- failed: $error " .
            $dbh->errstr());
        my $status = $error_type;
        if (not defined $status) {
            my $status = STATUS_INTERNAL_ERROR;
            Carp::cluck("FATAL ERROR: The type of the error got is unknown. " .
                        Basics::exit_status_text($status));
            exit $status;
        } else {
            say("ERROR: $who_am_i Role: " . $role . " " . Basics::return_status_text($status));
            return $status;
        }
    }
    return STATUS_OK;
}


sub set_safe_max_statement_time {
    my $executor = shift;

    my $who_am_i = Basics::who_am_i;

    my $trace_addition = '/* E_R ' . $executor->role . ' QNO 0 CON_ID ' .
                             $executor->connectionId() . ' */ ';

    # @@max_statement_time might be so small that
    # - some of the initial SQL's of any executor could fail but all must pass
    # - some of the SQL's of Reporters fail (observed 2020-11 for Deadlock, but rare)
    # - some of the SQL's of MetadataCacher fail (observed 2020-11 and not rare)
    # exp_server_kill($who_am_i, $aux_query);
    my $aux_query = '/*!100108 SET @@max_statement_time = 0 */ ' . $trace_addition;
    # exp_server_kill($who_am_i, $aux_query);
    my $status = GenTest_e::Executor::MySQL::run_do($executor->dbh, $executor->role, $aux_query);
    if (STATUS_OK != $status) {
        say("ERROR: $who_am_i " . $executor->role . " " . Basics::return_status_text($status));
        return $status;
    } else {
        return STATUS_OK;
    }
}
sub restore_max_statement_time {
    my $executor = shift;

    my $who_am_i = Basics::who_am_i;

    my $trace_addition = '/* E_R ' . $executor->role . ' QNO 0 CON_ID ' .
                         $executor->connectionId() . ' */ ';
    # my $aux_query = '/*!100108 SET @@max_statement_time = @max_statement_time_save */ ' .
    my $aux_query = '/*!100108 SET @@max_statement_time = @@global.max_statement_time */ ' .
                    $trace_addition;
    # exp_server_kill($who_am_i, $aux_query);
    my $status = GenTest_e::Executor::MySQL::run_do($executor->dbh, $executor->role, $aux_query);
    if (STATUS_OK != $status) {
        say("ERROR: $who_am_i " . $executor->role . " " . Basics::return_status_text($status));
        return $status;
    } else {
        return STATUS_OK;
    }
}


# 2021-05
# I am aware that the SQL's which follow could fail in case the MariaDB version used does not
# support dynamic setting of innodb_buffer_pool_size or innodb_disable_resize_buffer_pool_debug.
sub set_innodb_buffer_pool_size {
    my $executor = shift;

    my $who_am_i = Basics::who_am_i;

    my $trace_addition = '/* E_R ' . $executor->role . ' QNO 0 CON_ID ' .
                         $executor->connectionId() . ' */ ';
    my $aux_query;
    my $status;
    # exp_server_kill($who_am_i, $aux_query);
    $aux_query = 'SET @innodb_buffer_pool_size_save = ' .
                 '@@global.innodb_buffer_pool_size ' . $trace_addition;
    $status = GenTest_e::Executor::MySQL::run_do($executor->dbh, $executor->role, $aux_query);
    if (STATUS_CRITICAL_FAILURE <= $status) {
        say("ERROR: $who_am_i " . $executor->role . " " . Basics::return_status_text($status));
        return $status;
    }
    #
    $aux_query = 'SET @innodb_disable_resize_buffer_pool_debug_save = ' .
                 '@@global.innodb_disable_resize_buffer_pool_debug ' . $trace_addition;
    $status = GenTest_e::Executor::MySQL::run_do($executor->dbh, $executor->role, $aux_query);
    if (STATUS_CRITICAL_FAILURE <= $status) {
        say("ERROR: $who_am_i " . $executor->role . " " . Basics::return_status_text($status));
        return $status;
    }
    #
    $aux_query = 'SET @@global.innodb_disable_resize_buffer_pool_debug = 0 ' .
                 $trace_addition;
    $status = GenTest_e::Executor::MySQL::run_do($executor->dbh, $executor->role, $aux_query);
    if (STATUS_CRITICAL_FAILURE <= $status) {
        say("ERROR: $who_am_i " . $executor->role . " " . Basics::return_status_text($status));
        return $status;
    }
    #
    $aux_query = 'SET @@global.innodb_buffer_pool_size = IF(268435456 > ' .
                 '@@innodb_buffer_pool_size, 268435456, @@innodb_buffer_pool_size) ' .
                 $trace_addition;
    $status = GenTest_e::Executor::MySQL::run_do($executor->dbh, $executor->role, $aux_query);
    if (STATUS_CRITICAL_FAILURE <= $status) {
        say("ERROR: $who_am_i " . $executor->role . " " . Basics::return_status_text($status));
        return $status;
    }
}
sub restore_innodb_buffer_pool_size {
    my $executor = shift;

    my $who_am_i = Basics::who_am_i;

    my $trace_addition = '/* E_R ' . $executor->role . ' QNO 0 CON_ID ' .
                         $executor->connectionId() . ' */ ';
    my $aux_query;
    my $status;
    $aux_query = 'SET @@global.innodb_buffer_pool_size = ' .
                 '@innodb_buffer_pool_size_save ' . $trace_addition;
    $status = GenTest_e::Executor::MySQL::run_do($executor->dbh, $executor->role, $aux_query);
    if (STATUS_CRITICAL_FAILURE <= $status) {
        say("ERROR: $who_am_i " . $executor->role . " " . Basics::return_status_text($status));
        return $status;
    }
    #
    $aux_query = 'SET @@global.innodb_disable_resize_buffer_pool_debug = ' .
                 '@innodb_disable_resize_buffer_pool_debug_save ' . $trace_addition;
    $status = GenTest_e::Executor::MySQL::run_do($executor->dbh, $executor->role, $aux_query);
    if (STATUS_CRITICAL_FAILURE <= $status) {
        say("ERROR: $who_am_i " . $executor->role . " " . Basics::return_status_text($status));
        return $status;
    }
}

1;
