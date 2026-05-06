#  Copyright (c) 2026 MariaDB
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

# This is a derivate of alter_table_indexes_dynamic.yy
#   MDEV-37070  Implement table options to enable/disable features
#
#   Added ADAPTIVE_HASH_INDEX=DEFAULT|YES|NO table and index option to InnoDB.
#   The table and index options only have an effect if InnoDB adaptive hash
#   index feature is enabled.
#
#   - Having the ADAPTIVE_HASH_INDEX TABLE option set to NO will disable
#     adaptive hash index for all indexes in the table that do not have
#     the index option adaptive_hash_index=yes.
#   - Having the ADAPTIVE_HASH_INDEX TABLE option set to YES will enable the
#     adaptive hash index for all indexes in the table that do not have
#     the index option adaptive_hash_index=no.
#   - Using adaptive_hash_index=default deletes the old setting.
#   - One can also use OFF/ON as the options. This is to make it work similar
#     as other existing options.
#   - innodb.adaptive_hash_index has been changed from a bool to an enum with
#     values OFF, ON and IF_SPECIFIED. If IF_SPECIFIED is used, adaptive
#     hash index is only used for tables and indexes that specify
#     adaptive_hash_index=on.
#   - The following new options can be used to further optimize adaptive hash
#     index for an index (default is unset/auto for all of them):
#      - complete_fields:
#        - 0 to the number of columns the key is defined on (max 64)
#      - bytes_from_incomplete_field:
#        - This is only usable for memcmp()-comparable index fields, such as
#          VARBINARY or INT. For example, a 3-byte prefix on an INT will
#          return an identical hash value for 0‥255, another one for 256‥511,
#          and so on.
#        - Range is min 0 max 16383.
#      - for_equal_hash_point_to_last_record:
#        - Default is unset/auto, NO points to the first record, known as
#          left_side in the code; YES points to the last record.
#          Example: we have an INT column with the values 1,4,10 and bytes=3,
#          will that hash value point to the record 1 or the record 10?
#          Note: all values will necessarily have the same hash value
#          computed on the big-endian byte prefix 0x800000, for all of the
#          values 0x80000001, 0x80000004, 0x8000000a. InnoDB inverts the
#          sign bit in order to have memcmp()-compatible comparison.
#
#   Example:
#   CREATE TABLE t1 (a int primary key, b varchar(100), c int,
#   index (b) adaptive_hash_index=no, index (c))
#   engine=innodb, adaptive_hash_index=yes;
#
#
# 2026-05-04
# Re-checking the description of this MDEV, it's worth noting that [#4507|https://github.com/MariaDB/server/pull/4507] covers only the {{ADAPTIVE_HASH_INDEX}} per-table/per-index options (and related per-index options {{COMPLETE_FIELDS}}, {{BYTES_FROM_INCOMPLETE_FIELD}}, {{FOR_EQUAL_HASH_POINT_TO_LAST_RECORD}}).
#

query_add:
  query | query | query | alttind_query
;

alttind_query:
  ALTER alttind_online alttind_ignore TABLE _table /*!100301 alttind_wait */ alttind_list_with_optional_order_by
;

alttind_online:
  | | | ONLINE
;

alttind_ignore:
  | | IGNORE
;

alttind_wait:
  | | | WAIT _digit | NOWAIT
;

alttind_list_with_optional_order_by:
  alttind_list alttind_order_by
;

alttind_list:
  alttind_item_alg_lock | alttind_item_alg_lock | alttind_item_alg_lock, alttind_list
;

# Can't put it on the list, as ORDER BY should always go last
alttind_order_by:
  | | | | | | | | | | , ORDER BY alttind_column_list
;

alttind_item_alg_lock:
  alttind_item alttind_algorithm alttind_lock
;

# Spatial indexes, fulltext indexes and foreign keys are in separate modules

alttind_item:
# Some entries had to be set to comment because not implemented by MDEV-37070.
    alttind_add_index | alttind_add_index | alttind_add_index | alttind_add_index
  | alttind_add_index | alttind_add_index | alttind_add_index | alttind_add_index
  | alttind_add_pk | alttind_add_pk 
  | alttind_add_unique | alttind_add_unique | alttind_add_unique
  | alttind_drop_index | alttind_drop_index | alttind_drop_index | alttind_drop_index
  | alttind_drop_pk
  | alttind_drop_constraint | alttind_drop_constraint
  | alttind_enable_disable_keys
# | alttind_query_cache
  | alttind_adaptive_hash_index
# | alttind_binlog_row
  | alttind_complete_fields
  | alttind_bytes_from_incomplete_field
  | alttind_for_equal_hash_point_to_last_record
;

alttind_query_cache:
    query_cache = alttind_on_off_def ;

alttind_adaptive_hash_index:
    adaptive_hash_index = alttind_on_off_def ;

alttind_binlog_row:
    binlog_row = alttind_on_off_def ;

alttind_complete_fields:
    complete_fields = alttind_complete_fields_val ;

alttind_bytes_from_incomplete_field:
    bytes_from_incomplete_field = alttind_bytes_from_incomplete_field_val ;

alttind_for_equal_hash_point_to_last_record:
    for_equal_hash_point_to_last_record = alttind_on_off_def ;

alttind_on_off_def:
    ON      |
    OFF     |
    DEFAULT ;

alttind_complete_fields_val:
    DEFAULT |
          0 |
          1 |
         64 ;

alttind_bytes_from_incomplete_field_val:
    DEFAULT |
          0 |
          1 |
       8192 |
      16383 ;

alttind_add_index:
  ADD alttind_index_word alttind_if_not_exists alttind_ind_name_optional alttind_ind_type_optional ( alttind_column_list ) alttind_option_list
;

alttind_drop_index:
  DROP alttind_index_word alttind_if_exists alttind_ind_name_or_col_name
;

alttind_drop_constraint:
  DROP CONSTRAINT alttind_if_exists alttind_ind_name_or_col_name
;

alttind_add_pk:
  ADD alttind_constraint_word_optional PRIMARY KEY alttind_ind_type_optional ( alttind_column_list ) alttind_option_list
;

alttind_drop_pk:
  DROP PRIMARY KEY
;

alttind_enable_disable_keys:
  ENABLE KEYS | DISABLE KEYS
;

alttind_add_unique:
  ADD alttind_constraint_word_optional UNIQUE alttind_index_word_optional alttind_ind_name_optional alttind_ind_type_optional ( alttind_column_list ) alttind_option_list
;

alttind_ind_name_or_col_name:
  alttind_ind_name | alttind_ind_name | alttind_ind_name | _field
;

alttind_ind_type_optional:
  | | USING alttind_ind_type
;

alttind_ind_type:
    BTREE | BTREE | BTREE | BTREE | BTREE | BTREE | BTREE | BTREE
  | HASH | HASH | HASH | HASH
  | RTREE
;

alttind_option_list:
  | | | | alttind_ind_option | alttind_ind_option | alttind_ind_option alttind_option_list
;

alttind_ind_option:
  KEY_BLOCK_SIZE = _smallint_unsigned | COMMENT _english
;

alttind_column_name:
  _field | _letter
;

alttind_index_word:
  INDEX | KEY
;

alttind_index_word_optional:
  | alttind_index_word
;

alttind_constraint_word_optional:
  | | | CONSTRAINT | CONSTRAINT _letter
;

alttind_column_item:
    alttind_column_name alttind_asc_desc_optional
  | alttind_column_name alttind_asc_desc_optional 
  | alttind_column_name(_tinyint_unsigned) alttind_asc_desc_optional
;

alttind_asc_desc_optional:
  | | | | | ASC | DESC
;
 
alttind_column_list:
    alttind_column_item| alttind_column_item | alttind_column_item 
  | alttind_column_item, alttind_column_list
;

alttind_if_not_exists:
  | IF NOT EXISTS | IF NOT EXISTS | IF NOT EXISTS | IF NOT EXISTS
;

alttind_if_exists:
  | IF EXISTS | IF EXISTS | IF EXISTS | IF EXISTS
;

alttind_ind_name_optional:
  | alttind_ind_name | alttind_ind_name | alttind_ind_name
;

alttind_ind_name:
  { 'ind'.$prng->int(1,9) } | _letter
;

alttind_algorithm:
  | | | | , ALGORITHM=DEFAULT | , ALGORITHM=INPLACE | , ALGORITHM=COPY | /*!100307 , ALGORITHM=NOCOPY */ | /*!100307 , ALGORITHM=INSTANT */
;

alttind_lock:
  | | | | , LOCK=DEFAULT | , LOCK=NONE | , LOCK=SHARED | , LOCK=EXCLUSIVE
;

