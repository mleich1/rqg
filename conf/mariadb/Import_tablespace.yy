# Copyright (c) 2021 MariaDB Corporation
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

# The grammar is check ALTER TABLE ... IMPORT TABLESPACE and its impact on the consistency of
# table and index trees for the case that only ibd files but not cfg files are copied to the
# corresponding destination. See MDEV-20931.
# Basically:
# The Server/InnoDB can execute and pass everything or
# - deny the DDL operation
# - try it, fail and roll back
# - try it, commit and not crash on successing checks
# - try it, commit and declare during successing checks the table or indexes to be corrupt
# but never crash during execution of the IMPORT or during the checks.
#
# Attention
# ---------
# You will need some temporary modified lib/GenTest/Executor/MySQL.pm where nearly all mapping
# to STATUS_DATABASE_CORRUPTION has to be disabled disabled.
# If not
# IMPORT of logical not fitting or physical rotten tablespaces etc. could harvest error messages
# which get mapped to STATUS_DATABASE_CORRUPTION and cause an abort of the RQG run.
# But we just want test what could happen if .... the application does not abort.
# Without DISCARD/IMPORT a missing tablespace is a serious bug except "gaming" with partitions.
# With DISCARD, omitting of copy ibd file to destination followed by IMPORT attempt we will get
# criticized because of missing tablespace. But that is just some failure of the user.
#

query:
    # The next line
    #   set_names flush_for_export ; make_copy unlock_tables ; create_table ; alter_discard ; copy_around alter_import ; drop_table remove_used |
    # does not work like it looks because it
    # - counts as one query
    # - for a query all perl snippets inside of its components get executed first and than the SQL.
    # Observed impact in case of single thread scenario:
    # The CREATE TABLE fails because the ibd file is already in place.
    # And that is caused by the perl snippet in copy_around getting executed before the
    # CREATE TABLE statement.
    # It is also to be assumed that copying the ibd file happens when the table is not yet locked for export.
    set_names copy_around   |
    set_names create_table  |
    set_names create_table  |
    set_names alter_discard |
    set_names alter_import  |
    set_names drop_table    |
    set_names remove_used   ;

set_names:
    table_name imp_table_name source_ibd used_ibd ;

table_name:
    { $table_name = "table0_innodb" ;  return undef } |
    { $table_name = "table1_innodb" ;  return undef } |
    { $table_name = "table10_innodb" ; return undef } ;

imp_table_name:
    { $imp_table_name = "imp_" . $table_name ; return undef } ;

query_init:
    set_tmp ;

thread1_init:
    set_tmp ; FLUSH TABLES table0_innodb , table1_innodb , table10_innodb FOR EXPORT ; unlock_tables ;

layout:
    (col_int INT, col_varchar_255 VARCHAR(255), col_text TEXT) ;

set_tmp:
    # The "our" is essential!
    { our $tmp = $ENV{TMP} ; return undef };

source_ibd:
    { $source_ibd = $tmp . '/1/data/test/' . $table_name     . '.ibd'       ; return undef } ;
used_ibd:
    { $used_ibd   = $tmp . '/1/data/test/' . $imp_table_name . '.ibd'       ; return undef } ;

copy_around:
    # Is not fault tolerant
    { if (not File::Copy::copy($source_ibd, $used_ibd)) { print("ERROR $! during 'copy_around'.\n"); exit 200 } else { return undef } } /* 'copy_around' $table_name */;
remove_used:
    # Is fault tolerant
    { unlink $used_ibd ; return "/* 'remove_ibd' $table_name */" };

create_table:
    CREATE TABLE IF NOT EXISTS $imp_table_name LIKE $table_name ; target_distortion ;
target_distortion:
     | | | | | | | | | | | | | | | | | |
     | | | | | | | | | | | | | | | | | |
    ALTER TABLE $imp_table_name CONVERT TO CHARACTER SET character_set                                ddl_algorithm_lock_option |
    ALTER TABLE $imp_table_name ADD KEY IF NOT EXISTS idx ( idx_col )                                 ddl_algorithm_lock_option |
    ALTER TABLE $imp_table_name DROP KEY IF EXISTS idx                                                ddl_algorithm_lock_option |
    ALTER TABLE $imp_table_name ADD PRIMARY KEY  ( idx_col )                                          ddl_algorithm_lock_option |
    ALTER TABLE $imp_table_name DROP PRIMARY KEY                                                      ddl_algorithm_lock_option |
    ALTER TABLE $imp_table_name ADD COLUMN IF NOT EXISTS some_col_with_type null_not_null             ddl_algorithm_lock_option |
    ALTER TABLE $imp_table_name DROP COLUMN IF EXISTS    some_col                                     ddl_algorithm_lock_option |
    ALTER TABLE $imp_table_name MODIFY COLUMN modify_type                                             ddl_algorithm_lock_option |
    ALTER TABLE $imp_table_name MODIFY COLUMN modify_pos                                              ddl_algorithm_lock_option |
    ALTER TABLE $imp_table_name ENGINE = InnoDB ROW_FORMAT = row_format PAGE_COMPRESSED = compression ddl_algorithm_lock_option ;
character_set:
    ascii |
    utf8  ;

idx_col:
    col_int         |
    col_varchar_255 |
    col_text(13)    ;
modify_type:
    col_int BIGINT               |
    col_int SMALLINT             |
    col_int VARCHAR(255)         |
    col_int TEXT                 |
    col_varchar_255 VARCHAR(511) |
    col_varchar_255 VARCHAR(127) |
    col_varchar_255 INT          |
    col_varchar_255 TEXT         |
    col_text INT                 |
    col_text TEXT                |
    col_varchar_255 TEXT         ;
modify_pos:
    col_int INT                  FIRST                 |
    col_int INT                  AFTER col_varchar_255 |
    col_int INT                  AFTER col_text        |
    col_varchar_255 VARCHAR(255) FIRST                 |
    col_varchar_255 VARCHAR(255) AFTER col_int         |
    col_varchar_255 VARCHAR(255) AFTER col_text        |
    col_text TEXT                FIRST                 |
    col_text TEXT                AFTER col_int         |
    col_text TEXT                AFTER col_varchar_255 ;
some_col:
    col_extra       |
    col_int         |
    col_varchar_255 |
    col_text        ;
some_col_with_type:
    col_extra FLOAT              |
    col_int INT                  |
    col_varchar_255 VARCHAR(255) |
    col_text TEXT                ;
null_not_null:
    # The default is NULL.
    | | | | | | | | | | | | | | | | | |
    NOT NULL |
    NULL     ;
row_format:
    REDUNDANT |
    COMPACT   |
    DYNAMIC   ;
compression:
    0 |
    1 ;
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

drop_table:
    DROP TABLE IF EXISTS $imp_table_name ;

flush_for_export:
    FLUSH TABLES $table_name FOR EXPORT ;
unlock_tables:
    UNLOCK TABLES ;

alter_discard:
    ALTER TABLE $imp_table_name DISCARD TABLESPACE ;

alter_import:
    ALTER TABLE $imp_table_name IMPORT TABLESPACE ;




