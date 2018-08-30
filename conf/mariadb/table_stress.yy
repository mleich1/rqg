# Copyright (c) 2018, MariaDB Corporation
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
#

# The grammar is dedicated to stress tables with
# - DDL direct or indirect
#   Examples:
#      ALTER TABLE test.t1 ADD COLUMN
#      DROP TABLE test.t1
#      RENAME TABLE test.t1 TO new_test.t1
#      DROP SCHEMA new_test (affects the tables stored within the schema)
#      DROP several tables at once
#      Perform more than change affecting the definition of a table
# - DML trying to modify data and (combine with and/or)
#   - hitting frequent duplicate key or foreign key constraint violations
#   - being in some transaction which get intentional rolled back later
# - DDL and DML being "attacked" by KILL QUERY <session> and KILL <session>
# - DDL-DDL, DDL-DML, DML-DML locking conflicts caused by concurrency
# as efficient as possible regarding costs in
# - grammar development
# - at test runtime
# - in analysis (grammar simplification) and replay of bad effects met.
# In order to achieve that certain decisions had to be made
# 1. SQL statements should be kept as simple as possible.
# 2. No coverage for features like for the example the stored program language.
#    Nevertheless
#    - creating, use and drop of triggers needs to be checked because
#      they are bound to tables
#    - stored procedures might be used for auxiliary purposes
# 3. We focus on coarse grained bad effects like crashes and similar.
#    Some immediate (just after finishing statement execution) and deep
#    (table definition or table content) checking via some validator is mostly
#    impossible because of various reasons.
#
# The current grammar is partially based on the code of conf/runtime/alter_online.yy
#     Copyright (c) 2012 Oracle and/or its affiliates. All rights reserved.
# and should become the successor of that test.
#

# Even with threads = 1 an ALTER TABLE ... ADD COLUMN could fail.
# Example:
# ALTER TABLE t1 ADD COLUMN IF NOT EXISTS col3_copy INT FIRST,
# LOCK = NONE, ALGORITHM = COPY
# 1846 LOCK=NONE is not supported. Reason: COPY algorithm requires a lock. Try LOCK=SHARED.
# Impact:
# 1. 1054 Unknown column '%s' in 'field list' for
#    UPDATE t1 SET col3_copy = col3
# 2. ALTER TABLE t1 DROP COLUMN IF EXISTS col3  works
#    ALTER TABLE t1 CHANGE COLUMN <...> col3_copy col3 INT, LOCK = EXCLUSIVE makes no replacement
#    and the table is incomplete.
# Possible solutions:
# a) Try ALTER TABLE t1 ADD COLUMN IF NOT EXISTS <maybe missing column> and than fill it via
#    UPDATE t1 .... <template column or table> or REPLACE ...
# b) DROP and recreate any working table
#    - after some maximum lifetime and/or
#    - after detecting the defect (no of columns smaller than expected)
#


start_delay:
   # Avoid that worker threads cause a server crash before reporters are started.
   # This leads often to STATUS_ENVIRONMENT_ERROR though a crash happened.
   { sleep 5; return undef };

query_init:
   start_delay ; create_table ; thread_connect ;

thread_connect:
   maintain_session_entry ; SET AUTOCOMMIT = 0; SET @fill_amount = (@@innodb_page_size / 2 ) + 1 ; set_timeouts ;

set_timeouts:
   SET SESSION lock_wait_timeout = 2 ; SET SESSION innodb_lock_wait_timeout = 1 ;

maintain_session_entry:
   REPLACE INTO test . rqg_sessions SET rqg_id = _thread_id , processlist_id = CONNECTION_ID(), pid = { my $x = $$ } , connect_time = UNIX_TIMESTAMP();  COMMIT ;

kill_query_or_session_or_release:
# We are here interested on the impact of
# - killing (KILL ...)
#   - the excution of a DDL/DML
#   - a session
# - giving up the session voluntary (... RELEASE)
# regarding whatever statements being just in execution, transactions open, freeing of resources
# like locks, memory being occupied etc.
#
# Per manual:
#    KILL [HARD | SOFT] [CONNECTION | QUERY [ID] ] [thread_id | USER user_name | query_id]
#    Killing queries that repair or create indexes on MyISAM and Aria tables may result in
#    corrupted tables. Use the SOFT option to avoid this!
#
#    COMMIT [WORK] [AND [NO] CHAIN] [[NO] RELEASE]
#    ROLLBACK ... RELEASE
#
# The following aspects are not in scope at all
# - coverage of the full SQL syntax "KILL ...", "COMMIT/ROLLBACK ..."
# - will the right connections and queries get hit etc.
#
# Scenarios covered:
# 1. S1 kills S2
# 2. S1 kills S1
# 3. S1 tries to kill S3 which already does no more exist.
# 4. S1 gives up with COMMIT ... RELEASE.
#    It is assumed that RELEASE added to ROLLBACK will work as well as in combination with COMMIT.
#    Hence this will be not generated.
# 5. Various combinations of sessions running 1. till 5.
#
# (1) COMMIT before and after selecting in test . rqg_sessions in order to avoid effects caused by
#     - a maybe open transaction before that select
#     - the later statements of a transaction maybe opened by that select
# (2) No COMMIT before and after selecting in test . rqg_sessions in order to have no freed locks
#     before the KILL affecting the own session is issued. This is only valid iff AUTOCOMMIT=0.
#
   COMMIT ; correct_rqg_sessions_table      ; COMMIT                            | # (1)
            own_id_part   AND kill_age_cond          ; KILL CONNECTION @kill_id | # (2)
            own_id_part                              ; KILL QUERY      @kill_id | # (2)
   COMMIT ; other_id_part AND kill_age_cond ; COMMIT ; KILL CONNECTION @kill_id | # (1)
   COMMIT ; other_id_part                   ; COMMIT ; KILL QUERY      @kill_id | # (1)
            ROLLBACK RELEASE                                                    ;

own_id_part:
   SELECT     processlist_id  INTO @kill_id FROM test . rqg_sessions WHERE rqg_id  = _thread_id ;
other_id_part:
   SELECT MIN(processlist_id) INTO @kill_id FROM test . rqg_sessions WHERE rqg_id <> _thread_id AND processlist_id IS NOT NULL;
kill_50_cond:
   MOD(rqg_id,2) = 0;
kill_age_cond:
   UNIX_TIMESTAMP() - connect_time > 10;

correct_rqg_sessions_table:
   # UPDATE test . rqg_sessions SET processlist_id = NULL, connect_time = NULL WHERE processlist_id NOT IN (SELECT id FROM information_schema. processlist);
   UPDATE test . rqg_sessions SET processlist_id = CONNECTION_ID() WHERE rqg_id = _thread_id ;

create_table:
   # CREATE TABLE IF NOT EXISTS t1 (col1 INT, col2 INT, col_int_properties $col_name $col_type , col_text_properties $col_name $col_type, col_int_g_properties $col_name $col_type) ENGINE = InnoDB;
   CREATE TABLE IF NOT EXISTS t1 (col1 INT, col2 INT, col_int_properties $col_name $col_type , col_text_properties $col_name $col_type) ENGINE = InnoDB;

# preload_properties?

query:
   set_dbug ; ddl ; set_dbug_null |
   set_dbug ; dml ; set_dbug_null |
   set_dbug ; dml ; set_dbug_null ;

dml:
   # Ensure that the table does not grow endless.                                                      |
   delete ; COMMIT                                                                                     |
   # Make likely: Get duplicate key based on the two row INSERT only.                                  |
   enforce_duplicate1 ;                                                                commit_rollback |
   # Make likely: Get duplicate key based on two row UPDATE only.                                      |
   enforce_duplicate2 ;                                                                commit_rollback |
   # Make likely: Get duplicate key based on the row INSERT and the already committed data.            |
   insert_part ( my_int , $my_int,     $my_int,     fill_begin $my_int     fill_end ); commit_rollback |
   insert_part ( my_int , $my_int - 1, $my_int,     fill_begin $my_int     fill_end ); commit_rollback |
   insert_part ( my_int , $my_int,     $my_int - 1, fill_begin $my_int     fill_end ); commit_rollback |
   insert_part ( my_int , $my_int,     $my_int,     fill_begin $my_int - 1 fill_end ); commit_rollback ;

fill_begin:
   REPEAT(CAST( ;
fill_end:
   AS CHAR(1)), @fill_amount) ;

enforce_duplicate1:
   delete ; insert_part /* my_int */ some_record , some_record ;

enforce_duplicate2:
   UPDATE t1 SET column_name_int = my_int LIMIT 2 ;

insert_part:
   INSERT INTO t1 (col1,col2,col3,col4) VALUES ;

some_record:
   ($my_int,$my_int,$my_int,fill_begin $my_int fill_end ) ;

delete:
   DELETE FROM t1 WHERE column_name_int = my_int OR $column_name_int IS NULL                              ;
#   DELETE FROM t1 WHERE MATCH(col4) AGAINST (TRIM(' my_int ') IN BOOLEAN MODE) OR column_name_int IS NULL ;

my_int:
   # Maybe having some uneven distribution is of some value.
   { $my_int= 1                   } |
   { $my_int= $prng->int(1,    8) } |
   { $my_int= $prng->int(1,   64) } |
   { $my_int= $prng->int(1,  512) } |
   { $my_int= $prng->int(1, 4096) } |
   { $my_int= 'NULL'              } ;

commit_rollback:
   COMMIT   |
   ROLLBACK ;

# FIXME:
# https://mariadb.com/kb/en/library/wait-and-nowait/
ddl:
   ALTER TABLE t1 add_accelerator                     ddl_algorithm_lock_option |
   ALTER TABLE t1 add_accelerator                     ddl_algorithm_lock_option |
   ALTER TABLE t1 add_accelerator                     ddl_algorithm_lock_option |
   ALTER TABLE t1 add_accelerator                     ddl_algorithm_lock_option |
   ALTER TABLE t1 drop_accelerator                    ddl_algorithm_lock_option |
   ALTER TABLE t1 drop_accelerator                    ddl_algorithm_lock_option |
   ALTER TABLE t1 drop_accelerator                    ddl_algorithm_lock_option |
   ALTER TABLE t1 drop_accelerator                    ddl_algorithm_lock_option |
   ALTER TABLE t1 add_accelerator  , add_accelerator  ddl_algorithm_lock_option |
   ALTER TABLE t1 drop_accelerator , drop_accelerator ddl_algorithm_lock_option |
   ALTER TABLE t1 drop_accelerator , add_accelerator  ddl_algorithm_lock_option |
   # ddl_algorithm_lock_option is not supported by some statements
   check_table                                                                  |
   TRUNCATE TABLE t1                                                            |
   # ddl_algorithm_lock_option is within the replace_column sequence
   replace_column                                                               |
   # It is some rather arbitrary decision to place KILL session etc. here
   # but KILL ... etc. is like most DDL some rather heavy impact DDL.
   ALTER TABLE t1 enable_disable KEYS                                           |
   rename_column                                      ddl_algorithm_lock_option |
   kill_query_or_session_or_release                                             ;

enable_disable:
   ENABLE  |
   DISABLE ;

ddl_algorithm_lock_option:
                              |
   , ddl_algorithm            |
   , ddl_lock                 |
   , ddl_algorithm , ddl_lock |
   , ddl_lock , ddl_algorithm ;

ddl_algorithm:
   ALGORITHM = DEFAULT |
   ALGORITHM = INSTANT |
   ALGORITHM = NOCOPY  |
   ALGORITHM = INPLACE |
   ALGORITHM = COPY    ;

ddl_lock:
   LOCK = DEFAULT   |
   LOCK = NONE      |
   LOCK = SHARED    |
   LOCK = EXCLUSIVE ;


add_accelerator:
   ADD  UNIQUE   key_or_index  if_not_exists_mostly  uidx_name ( column_name_list_for_key ) |
   ADD           key_or_index  if_not_exists_mostly   idx_name ( column_name_list_for_key ) |
   ADD  PRIMARY  KEY           if_not_exists_mostly            ( column_name_list_for_key ) |
   ADD  FULLTEXT key_or_index  if_not_exists_mostly ftidx_name ( col_text                     ) ;

drop_accelerator:
   DROP         key_or_index  uidx_name |
   DROP         key_or_index   idx_name |
   DROP         key_or_index ftidx_name |
   DROP PRIMARY KEY                     ;

key_or_index:
   INDEX |
   KEY   ;

check_table:
   CHECK TABLE t1 ;

column_position:
                            |
   FIRST                    |
   AFTER random_column_name ;

column_name_int:
   { $column_name_int= 'col1' }    |
   { $column_name_int= 'col2' }    |
   { $column_name_int= 'col_int' } ;

column_name_list_for_key:
   random_column_properties $col_idx                                     |
   random_column_properties $col_idx , random_column_properties $col_idx ;

# The hope is that the 'ã' makes some stress.
uidx_name:
   { $name = '`Marvão_uidx1`';  return undef } name_convert |
   { $name = '`Marvão_uidx2`';  return undef } name_convert |
   { $name = '`Marvão_uidx3`';  return undef } name_convert ;
idx_name:
   { $name = '`Marvão_idx1`';   return undef } name_convert |
   { $name = '`Marvão_idx2`';   return undef } name_convert |
   { $name = '`Marvão_idx3`';   return undef } name_convert ;
ftidx_name:
   { $name = '`Marvão_ftidx1`'; return undef } name_convert |
   { $name = '`Marvão_ftidx2`'; return undef } name_convert |
   { $name = '`Marvão_ftidx3`'; return undef } name_convert ;


random_column_name:
# The import differences to the rule 'random_column_properties' are
# 1. No replacing of content in the variables $col_name , $col_type , $col_idx
#    ==> No impact on text of remaining statement sequence.
# 2. The column name just gets printed(returned).
   col1      |
   col2      |
   col_int   |
   # col_int_g |
   col_text  ;




#----------------------------------------------------------
replace_column:
   random_column_properties replace_column_add ; replace_column_update ; replace_column_drop ; replace_column_rename ;

replace_column_add:
   ALTER TABLE t1 ADD COLUMN if_not_exists_mostly {$forget= $col_name."_copy"} $col_type column_position ddl_algorithm_lock_option ;
replace_column_update:
   UPDATE t1 SET $forget = $col_name ;
replace_column_drop:
   ALTER TABLE t1 DROP COLUMN if_exists_mostly $col_name ddl_algorithm_lock_option ;
replace_column_rename:
   ALTER TABLE t1 CHANGE COLUMN if_exists_mostly $forget {$name = $col_name; return undef} name_convert $col_type ddl_algorithm_lock_option ;
#----------------------------------------------------------
# Names should be compared case insensitive.
# Given the fact that the current test should hunt bugs in storage engine and
# server -- storage engine relation I hope its sufficient to mangle column and
# index names within the column or index related DDL but not in other SQL.
rename_column:
   rename_column_begin {$name = $col_name; return undef} name_convert $col_name $col_type |
   rename_column_begin {$name = $col_name; return undef} $col_name name_convert $col_type ;
rename_column_begin:
   random_column_properties ALTER TABLE t1 CHANGE COLUMN if_exists_mostly ;
name_convert:
   $name                                                                                                  |
   $name                                                                                                  |
   $name                                                                                                  |
   $name                                                                                                  |
   $name                                                                                                  |
   $name                                                                                                  |
   $name                                                                                                  |
   $name                                                                                                  |
   $name                                                                                                  |
   get_cdigit {substr($name, 0, $cdigit - 1) . uc(substr($name, $cdigit -1, 1)) . substr($name, $cdigit)} |
   get_cdigit {substr($name, 0, $cdigit - 1) . lc(substr($name, $cdigit -1, 1)) . substr($name, $cdigit)} ;
get_cdigit:
   {$cdigit = $prng->int(1,10); return undef} ;

#######################
# 1. Have the alternatives
#    a) <nothing>
#    b) IF NOT EXISTS
#    because https://mariadb.com/kb/en/library/alter-table/ mentions
#    ... queries will not report errors when the condition is triggered for that clause.
#    ... the ALTER will move on to the next clause in the statement (or end if finished).
#    So cause that in case of already existing objects all possible kinds of fate are generated.
# 2. "IF NOT EXISTS" gets more frequent generated because that reduces the fraction
#    of failing statements. --> "Nicer" output + most probably more stress
# 3. <nothing> as first alternative is assumed to be better for grammar simplification.
#
if_not_exists_mostly:
                 |
   IF NOT EXISTS |
   IF NOT EXISTS ;
if_exists_mostly:
                 |
   IF     EXISTS |
   IF     EXISTS ;

random_column_properties:
   col1_properties      |
   col2_properties      |
   col_int_properties   |
#  col_int_g_properties |
   col_text_properties  ;

###### col<number>_properties
# Get the properties for some random picked column.
#    $col_name -- column name like "col1"
#    $col_type -- column base type like "TEXT"
#
col1_properties:
   { $col_name= 'col1'; $col_type= 'INT'  ; $col_idx= $col_name;          return undef } ;
col2_properties:
   { $col_name= 'col2'; $col_type= 'INT'  ; $col_idx= $col_name;          return undef } ;
col3_properties:
   { $col_name= 'col3'; $col_type= 'INT'  ; $col_idx= $col_name;          return undef } ;
col_varchar_properties:
   { $col_name= 'col_varchar'  ; $col_type= 'VARCHAR(500)'                                                            ; return undef }   col_varchar_idx ;
col_varchar_g_properties:
   { $col_name= 'col_varchar_g'; $col_type= 'VARCHAR(500) GENERATED ALWAYS AS (SUBSTR(col_varchar,1,499)) PERSISTENT' ; return undef }   col_varchar_idx |
   { $col_name= 'col_varchar_g'; $col_type= 'VARCHAR(500) GENERATED ALWAYS AS (SUBSTR(col_varchar,1,499)) VIRTUAL'    ; return undef }   col_varchar_idx ;
col_varchar_idx:
   { $col_idx= $col_name         ; return undef } |
   { $col_idx= $col_name . "(10)"; return undef } ;

col_text_properties:
   { $col_name= 'col_text'     ; $col_type= 'TEXT'                                                                    ; return undef }   col_text_idx ;
col_text_g_properties:
   { $col_name= 'col_text_g'   ; $col_type= 'TEXT         GENERATED ALWAYS AS (SUBSTR(col_text,1,499))    PERSISTENT' ; return undef }   col_text_idx |
   { $col_name= 'col_text_g'   ; $col_type= 'TEXT         GENERATED ALWAYS AS (SUBSTR(col_text,1,499))    VIRTUAL'    ; return undef }   col_text_idx ;
col_text_idx:
   { $col_idx= $col_name . "(10)"; return undef } ;

col_int_properties:
   { $col_name= 'col_int'      ; $col_type= 'INTEGER'                                                                 ; return undef }   col_int_idx ;
col_int_g_properties:
   { $col_name= 'col_int_g'    ; $col_type= 'INTEGER      GENERATED ALWAYS AS (col_int)                   PERSISTENT' ; return undef }   col_int_idx |
   { $col_name= 'col_int_g'    ; $col_type= 'INTEGER      GENERATED ALWAYS AS (col_int)                   VIRTUAL'    ; return undef }   col_int_idx ;
col_int_idx:
   { $col_idx= $col_name       ; return undef } ;

col_float_properties:
   { $col_name= 'col_float'    ; $col_type= 'FLOAT'                                                                   ; return undef }   col_float_idx ;
col_float_g_properties:
   { $col_name= 'col_float_g'  ; $col_type= 'FLOAT        GENERATED ALWAYS AS (col_float)                 PERSISTENT' ; return undef }   col_float_idx |
   { $col_name= 'col_float_g'  ; $col_type= 'FLOAT        GENERATED ALWAYS AS (col_float)                 VIRTUAL'    ; return undef }   col_float_idx ;
col_float_idx:
   { $col_idx= $col_name       ; return undef } ;


######
# For playing around with
#   SET DEBUG_DBUG='+d,ib_build_indexes_too_many_concurrent_trxs, ib_rename_indexes_too_many_concurrent_trxs, ib_drop_index_too_many_concurrent_trxs';
# and similar add a redefine like
#   conf/mariadb/ts_dbug_innodb.yy
#
set_dbug:
   ;

set_dbug_null:
   ;
