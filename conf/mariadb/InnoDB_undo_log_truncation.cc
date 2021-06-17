# Copyright (C) 2021 MariaDB corporation Ab. All rights reserved.
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
#


# InnoDB_undo_log_truncation.cc
# InnoDB_standard.cc
#
# Suite for "torturing" preferably InnoDB with concurrent DDL/DML/....
# based on InnoDB_standard.cc and tweaked towards testing undo_log_truncation
# (MDEV-25062 , MDEV-25801)
#

our $test_compression_encryption =
  '--grammar=conf/mariadb/innodb_compression_encryption.yy --gendata=conf/mariadb/innodb_compression_encryption.zz --max_gd_duration=1800 ';

our $encryption_setup =
  '--mysqld=--plugin-load-add=file_key_management.so --mysqld=--loose-file-key-management-filename=$RQG_HOME/conf/mariadb/encryption_keys.txt ';

our $duration = 300;
our $grammars =
[

  # Suffers in old releases massive from https://jira.mariadb.org/browse/MDEV-19449
  '--gendata=conf/mariadb/oltp.zz --max_gd_duration=600 --grammar=conf/mariadb/oltp.yy --redefine=conf/mariadb/instant_add.yy',    # This looked once like a dud.
# Heavy space consumption in tmpfs -> throtteling by ResourceControl -> CPU's 30% idle
# '--gendata=conf/percona_qa/BT-16274/BT-16274.zz --grammar=conf/percona_qa/BT-16274/BT-16274.yy --redefine=conf/mariadb/alter_table.yy --redefine=conf/mariadb/instant_add.yy --redefine=conf/mariadb/bulk_insert.yy --redefine=conf/mariadb/redefine_temporary_tables.yy',
# Heavy space consumption in tmpfs -> throtteling by ResourceControl -> CPU's 30% idle
# '--gendata=conf/percona_qa/percona_qa.zz --grammar=conf/percona_qa/percona_qa.yy --redefine=conf/mariadb/alter_table.yy --redefine=conf/mariadb/instant_add.yy --redefine=conf/mariadb/bulk_insert.yy --redefine=conf/mariadb/versioning.yy --redefine=conf/mariadb/sequences.yy --redefine=conf/mariadb/redefine_temporary_tables.yy',
  '--views --grammar=conf/mariadb/partitions_innodb.yy --redefine=conf/mariadb/alter_table.yy --redefine=conf/mariadb/instant_add.yy --redefine=conf/mariadb/modules/alter_table_columns.yy --redefine=conf/mariadb/bulk_insert.yy --redefine=conf/mariadb/modules/foreign_keys.yy --redefine=conf/mariadb/modules/locks.yy --redefine=conf/mariadb/modules/sql_mode.yy --redefine=conf/mariadb/versioning.yy --redefine=conf/mariadb/sequences.yy --redefine=conf/mariadb/modules/locks-10.4-extra.yy',
  '--gendata=conf/engines/innodb/full_text_search.zz --max_gd_duration=1200 --short_column_names --grammar=conf/engines/innodb/full_text_search.yy --redefine=conf/mariadb/alter_table.yy --redefine=conf/mariadb/instant_add.yy --redefine=conf/mariadb/modules/alter_table_columns.yy --redefine=conf/mariadb/bulk_insert.yy --redefine=conf/mariadb/modules/foreign_keys.yy --redefine=conf/mariadb/modules/locks.yy --redefine=conf/mariadb/modules/sql_mode.yy --redefine=conf/mariadb/redefine_temporary_tables.yy --redefine=conf/mariadb/versioning.yy --redefine=conf/mariadb/sequences.yy',
  '--gendata=conf/engines/engine_stress.zz --views --grammar=conf/engines/engine_stress.yy --redefine=conf/mariadb/alter_table.yy --redefine=conf/mariadb/instant_add.yy --redefine=conf/mariadb/modules/alter_table_columns.yy --redefine=conf/mariadb/bulk_insert.yy --redefine=conf/mariadb/modules/foreign_keys.yy --redefine=conf/mariadb/modules/locks.yy --redefine=conf/mariadb/modules/sql_mode.yy --redefine=conf/mariadb/versioning.yy --redefine=conf/mariadb/sequences.yy --redefine=conf/mariadb/modules/locks-10.4-extra.yy',

  # This can run even without "extra" main grammar
  '--gendata --vcols --views --grammar=conf/mariadb/instant_add.yy',

  '--grammar=conf/runtime/metadata_stability.yy --gendata=conf/runtime/metadata_stability.zz',
  '--grammar=conf/engines/many_indexes.yy --gendata=conf/engines/many_indexes.zz',
  '--grammar=conf/mariadb/partitions_innodb.yy',
  '--grammar=conf/mariadb/partitions_innodb.yy --gendata-advanced --skip-gendata',
  '--grammar=conf/replication/replication.yy --gendata=conf/replication/replication-5.1.zz --max_gd_duration=1200', # rr on asan_Og exceeded 900 * 1.5
  '--grammar=conf/mariadb/oltp-transactional.yy --gendata=conf/mariadb/oltp.zz --max_gd_duration=600 ',
  '--grammar=conf/mariadb/oltp-transactional.yy --gendata-advanced --skip-gendata',
  '--grammar=conf/runtime/alter_online.yy --gendata=conf/runtime/alter_online.zz',

  # DDL-DDL, DDL-DML, DML-DML, syntax   stress test   for several storage engines
  # Certain new features might be not covered.
  '--gendata=conf/mariadb/concurrency.zz --gendata_sql=conf/mariadb/concurrency.sql --grammar=conf/mariadb/concurrency.yy',

  # Main DDL-DDL, DDL-DML stress work horse   with generated virtual columns, fulltext indexes, KILL QUERY/SESSION, BACKUP STAGE
  '--grammar=conf/mariadb/table_stress_innodb.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql',
  '--grammar=conf/mariadb/table_stress_innodb.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --reporters=CrashRecovery1',
  '--grammar=conf/mariadb/table_stress_innodb.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --reporters=CrashRecovery1',
  # Derivate of above which tries to avoid any DDL rebuilding the table, also without BACKUP STAGE
  #     IMHO this fits more likely to the average fate of production applications.
  #     No change of PK, get default ALGORITHM which is NOCOPY if doable, no BACKUP STAGE because too new and RPL used instead.
  '--grammar=conf/mariadb/table_stress_innodb_nocopy.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql',
  '--grammar=conf/mariadb/table_stress_innodb_nocopy1.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql',
  '--grammar=conf/mariadb/table_stress_innodb_nocopy1.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --reporters=RestartConsistency',
  '--grammar=conf/mariadb/table_stress_innodb_nocopy1.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --reporters=Mariabackup_linux',
  '--grammar=conf/mariadb/table_stress_innodb_nocopy1.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --reporters=CrashRecovery1',
  '--grammar=conf/mariadb/table_stress_innodb_nocopy1.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --rpl_mode=statement',
  '--grammar=conf/mariadb/table_stress_innodb_nocopy1.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --rpl_mode=mixed',
  '--grammar=conf/mariadb/table_stress_innodb_nocopy1.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --rpl_mode=row',
  '--grammar=conf/mariadb/table_stress_innodb_nocopy1.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --redefine=conf/mariadb/xa.yy',

  # Fiddle with FOREIGN Keys and TRUNCATE
  '--gendata=conf/mariadb/fk_truncate.zz --grammar=conf/mariadb/fk_truncate.yy',

  # Only used if there is some table_stress.yy version of special interest in RQG_HOME
  # '--grammar=table_stress.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql',

  # DML only together with Mariabackup
  '--gendata=conf/mariadb/oltp.zz --max_gd_duration=600 --grammar=conf/mariadb/oltp.yy --reporters=Mariabackup_linux ',
  '--grammar=conf/engines/many_indexes.yy --gendata=conf/engines/many_indexes.zz --reporters=Mariabackup_linux ',
  '--gendata=conf/engines/engine_stress.zz --views --grammar=conf/engines/engine_stress.yy --redefine=conf/mariadb/modules/locks.yy --redefine=conf/mariadb/modules/sql_mode.yy --reporters=Mariabackup_linux ',
  '--grammar=conf/mariadb/oltp-transactional.yy --gendata=conf/mariadb/oltp.zz --max_gd_duration=600 --reporters=Mariabackup_linux ',
  # DML only together with RestartConsistency
  '--gendata=conf/mariadb/oltp.zz --max_gd_duration=600 --grammar=conf/mariadb/oltp.yy --reporters=RestartConsistency ',
  '--grammar=conf/engines/many_indexes.yy --gendata=conf/engines/many_indexes.zz --reporters=RestartConsistency ',
  '--gendata=conf/engines/engine_stress.zz --views --grammar=conf/engines/engine_stress.yy --redefine=conf/mariadb/modules/locks.yy --redefine=conf/mariadb/modules/sql_mode.yy --reporters=RestartConsistency ',
  '--grammar=conf/mariadb/oltp-transactional.yy --gendata=conf/mariadb/oltp.zz --max_gd_duration=600 --reporters=RestartConsistency ',
  # DML only together with CrashRecovery1
  '--gendata=conf/mariadb/oltp.zz --max_gd_duration=600 --grammar=conf/mariadb/oltp.yy --reporters=CrashRecovery1 ',
  '--grammar=conf/engines/many_indexes.yy --gendata=conf/engines/many_indexes.zz --reporters=CrashRecovery1 ',
  '--gendata=conf/engines/engine_stress.zz --views --grammar=conf/engines/engine_stress.yy --redefine=conf/mariadb/modules/locks.yy --redefine=conf/mariadb/modules/sql_mode.yy --reporters=CrashRecovery1 ',
  '--grammar=conf/mariadb/oltp-transactional.yy --gendata=conf/mariadb/oltp.zz --max_gd_duration=600 --reporters=CrashRecovery1 ',

  # Tests checking transactional properties
  # FIXME: Add variations of the ISOLATION LEVEL is useful
  ' --grammar=conf/transactions/transactions.yy --gendata=conf/transactions/transactions.zz --validators=DatabaseConsistency ',
  ' --grammar=conf/transactions/repeatable_read.yy --gendata=conf/transactions/transactions.zz --validators=RepeatableRead ',

  "$test_compression_encryption                                                                --mysqld=--loose-innodb-encryption-threads=1 ",
  "$test_compression_encryption                                                                --mysqld=--loose-innodb-encryption-threads=7 ",
  "$test_compression_encryption                                                                --mysqld=--loose-innodb_encryption_rotate_key_age=1 ",
  "$test_compression_encryption                                                                --mysqld=--loose-innodb_encryption_rotate_key_age=2 ",
  "$test_compression_encryption                                                                --reporters=RestartConsistency ",
  "$test_compression_encryption                                                                --reporters=CrashRecovery1     ",
  "$test_compression_encryption --mysqld=--innodb-encrypt-log --mysqld=--innodb-encrypt-tables                                ",
  "$test_compression_encryption --mysqld=--innodb-encrypt-log --mysqld=--innodb-encrypt-tables --reporters=RestartConsistency ",
  "$test_compression_encryption --mysqld=--innodb-encrypt-log --mysqld=--innodb-encrypt-tables --reporters=CrashRecovery1     ",
  "$test_compression_encryption --mysqld=--innodb-encrypt-log --mysqld=--innodb-encrypt-tables --reporters=CrashRecovery1 --redefine=conf/mariadb/redefine_innodb_undo.yy --mysqld=--innodb-immediate-scrub-data-uncompressed=1 ",
];


# Sometimes useful settings
#   --mysqld=--innodb_stats_persistent=off
#   --mysqld=--innodb_adaptive_hash_index=OFF
#   --mysqld=--innodb_use_native_aio=0
#
# Reason for not writing '--reporters=Backtrace,ErrorLog,Deadlock1':
# Current RQG requires using either
#   --reporters=<list> ... but never --reporters=... again
# or
#   --reporters=<one reporter> ... --reporters=<one reporter> ...
# And it could be that already in the $grammars section some reporter was assigned.
#
$combinations = [ $grammars,
  [
    '
    --mysqld=--loose-innodb_undo_log_truncate=1
    --mysqld=--loose-innodb_lock_schedule_algorithm=fcfs
    --mysqld=--loose-idle_write_transaction_timeout=0
    --mysqld=--loose-idle_transaction_timeout=0
    --mysqld=--loose-idle_readonly_transaction_timeout=0
    --mysqld=--connect_timeout=60
    --mysqld=--interactive_timeout=28800
    --mysqld=--slave_net_timeout=60
    --mysqld=--net_read_timeout=30
    --mysqld=--net_write_timeout=60
    --mysqld=--loose-table_lock_wait_timeout=50
    --mysqld=--wait_timeout=28800
    --mysqld=--lock-wait-timeout=86400
    --mysqld=--innodb-lock-wait-timeout=50
    --no-mask
    --queries=10000000
    --seed=random
    --reporters=Backtrace --reporters=ErrorLog --reporters=Deadlock1
    --validators=None
    --mysqld=--log_output=none
    --mysqld=--log-bin
    --mysqld=--log_bin_trust_function_creators=1
    --mysqld=--loose-debug_assert_on_not_freed_memory=0
    --engine=InnoDB
    --restart_timeout=240
    ' .
    # Some grammars need encryption, file key management
    " $encryption_setup " .
    " --duration=$duration --mysqld=--loose-innodb_fatal_semaphore_wait_threshold=$duration "
  ],
  [
    ' --mysqld=--loose-innodb-sync-debug ',
    '',
  ],
  [
    ' --mysqld=--loose-innodb_undo_tablespaces=3 ',
    ' --mysqld=--loose-innodb_undo_tablespaces=63 ',
  ],
  [
    ' --mysqld=--innodb_stats_persistent=off ',
    ' --mysqld=--innodb_stats_persistent=on ',
  ],
  [
    ' --mysqld=--innodb_adaptive_hash_index=off ',
    ' --mysqld=--innodb_adaptive_hash_index=on ',
  ],
  [
    ' --mysqld=--loose-innodb_evict_tables_on_commit_debug=off ',
#   ' --mysqld=--loose-innodb_evict_tables_on_commit_debug=on  ',
  ],
  [
    # Warning (mleich 2020-06):
    # It might look as if max-statement-time is a good alternative to using the reporter
    # "Querytimeout". I fear that the latter is not that reliable.
    # But certain RQG tests showed that especially DDL's could run several minutes
    # without being stopped by max-statement-time.
    # Conclusion:
    # If facing frequent STATUS_SERVER_DEADLOCKED and assuming its false alarm
    # (= long runtime because of "natural" reason) than using
    # max-statement-time and the reporter Querytimeout makes sense.
    #
    ' --mysqld=--loose-max-statement-time=30 ',
  ],
  [
    ' --threads=1  ',
    ' --threads=2  ',
    ' --threads=9  ',
    ' --threads=33 ',
  ],
  [
    " --mysqld=--innodb-use-native-aio=0 --rr=Extended --rr_options='\"--chaos --wait\"' ",
    " --mysqld=--innodb-use-native-aio=0 --rr=Extended --rr_options='\"--wait\"' ",
    " --mysqld=--innodb_use_native_aio=1 ",
  ],
  [
    # 1. innodb_page_size >= 32K requires a innodb-buffer-pool-size >=24M
    #    otherwise the start of the server will fail.
    # 2. An innodb-buffer-pool-size=5M should work well with innodb_page_size < 32K
    # 3. A huge innodb-buffer-pool-size will not give an advantage if the tables are small.
    # 4. Small innodb-buffer-pool-size and small innodb_page_size stress Purge more.
    ' --mysqld=--innodb_page_size=4K  --mysqld=--innodb-buffer-pool-size=5M   ',
    ' --mysqld=--innodb_page_size=4K  --mysqld=--innodb-buffer-pool-size=256M ',
    ' --mysqld=--innodb_page_size=8K  --mysqld=--innodb-buffer-pool-size=8M   ',
    ' --mysqld=--innodb_page_size=8K  --mysqld=--innodb-buffer-pool-size=256M ',
    ' --mysqld=--innodb_page_size=16K --mysqld=--innodb-buffer-pool-size=8M   ',
    ' --mysqld=--innodb_page_size=16K --mysqld=--innodb-buffer-pool-size=256M ',
    ' --mysqld=--innodb_page_size=32K --mysqld=--innodb-buffer-pool-size=24M  ',
    ' --mysqld=--innodb_page_size=32K --mysqld=--innodb-buffer-pool-size=256M ',
    ' --mysqld=--innodb_page_size=64K --mysqld=--innodb-buffer-pool-size=24M  ',
    ' --mysqld=--innodb_page_size=64K --mysqld=--innodb-buffer-pool-size=256M ',
  ],
];


