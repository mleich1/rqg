#  Copyright (c) 2018,2021 MariaDB
#  Copyright (c) 2023 MariaDB plc
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; version 2 of the License.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301  USA */
#
# Use in special cases only
# -------------------------
# Start the server with some quite strict sql_mode like 'traditional'.
#   connect of session 1
#   SET SESSION SQL_MODE= '';
#   CREATE TABLE `table100_innodb_int_autoinc` (tscol2 TIMESTAMP DEFAULT 0);
#      pass but harvest ER_INVALID_DEFAULT (1067) if SESSION SQL_MODE= 'traditional'
#   disconnect:
#   connect of session 2:
#   ALTER TABLE `test` . `table100_innodb_int_autoinc` FORCE;
#      and harvest ER_INVALID_DEFAULT (1067): Invalid default value for 'tscol2'
#      --> status STATUS_SEMANTIC_ERROR
# == Its something to be expected and not some defect in the data dictionary of
#    server and/or InnoDB.
#

query_add:
  query | query | query | query | query | query | query | sql_mode_set
;

sql_mode_set:
  SET sql_mode_session_or_global SQL_MODE= sql_mode_value
;

sql_mode_session_or_global:
  | | | | | SESSION | SESSION | SESSION | GLOBAL
;

sql_mode_value:
  sql_mode_list | '' | DEFAULT
;

sql_mode_list:
  { @modes= qw(
      ALLOW_INVALID_DATES
      ANSI
      ANSI_QUOTES
      DB2
      EMPTY_STRING_IS_NULL
      ERROR_FOR_DIVISION_BY_ZERO
      HIGH_NOT_PRECEDENCE
      IGNORE_BAD_TABLE_OPTIONS
      IGNORE_SPACE
      MAXDB
      MSSQL
      MYSQL323
      MYSQL40
      NO_AUTO_CREATE_USER
      NO_AUTO_VALUE_ON_ZERO
      NO_BACKSLASH_ESCAPES
      NO_DIR_IN_CREATE
      NO_ENGINE_SUBSTITUTION
      NO_FIELD_OPTIONS
      NO_KEY_OPTIONS
      NO_TABLE_OPTIONS
      NO_UNSIGNED_SUBTRACTION
      NO_ZERO_DATE
      NO_ZERO_IN_DATE
      ONLY_FULL_GROUP_BY
      ORACLE
      PAD_CHAR_TO_FULL_LENGTH
      PIPES_AS_CONCAT
      POSTGRESQL
      REAL_AS_FLOAT
      SIMULTANEOUS_ASSIGNMENT
      STRICT_ALL_TABLES
      STRICT_TRANS_TABLES
      TIME_ROUND_FRACTIONAL
      TRADITIONAL
    ); $length=$prng->int(1,scalar(@modes) - 1); "'" . (join ',', @{$prng->shuffleArray(\@modes)}[0..$length]) . "'"
  }
;
