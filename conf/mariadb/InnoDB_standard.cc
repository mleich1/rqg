# Copyright (C) 2019, 2022 MariaDB corporation Ab. All rights reserved.
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


# InnoDB_standard.cc
#
# Suite for "torturing" preferably InnoDB with concurrent DDL/DML/....
#
#
#
# History
# -------
# 1. The initial set of tests (2018-05) was developed by Elena and covers roughly everything of
#    MariaDB. When testing MDEVs fixing or enhancing features usually a sub set of tests were used.
# 2. I disabled certain tests, added some new one and shifted the focus towards InnoDB.
#
# The suite might contain certain adjustments in order to avoid critical areas with known but
# not yet fixed bugs.
#

# Section Verdict setup ---------------------------------------------------------------------- start
#
# $statuses_replay =
# [
#   # [ 'STATUS_ANY_ERROR' ],
# ];
#
# $patterns_replay =
# [
#   # [ 'Import_1', '#3  <signal handler called>.{1,300}#4  .{1,20}in ha_innobase::discard_or_import_tablespace' ],
# ];
#
#
# Section Verdict setup ------------------------------------------------------------------------ end

our $test_compression_encryption =
  '--grammar=conf/mariadb/innodb_compression_encryption.yy --gendata=conf/mariadb/innodb_compression_encryption.zz --max_gd_duration=1800 ';

our $encryption_setup =
  '--mysqld=--plugin-load-add=file_key_management.so --mysqld=--loose-file-key-management-filename=$RQG_HOME/conf/mariadb/encryption_keys.txt ';

our $compression_setup =
  # The availability of the plugins depends on 1. build mechanics 2. Content of OS
  # The server startup will not fail if some plugin is missing except its very important
  # like for some storage engine. Of course some error message will be emitted.
  # Without this setting
  # - innodb page compression will be less till not covered by MariaDB versions >= 10.7
  # - upgrade tests starting with version < 10.7 and going up to version >= 10.7 will
  #   suffer from TBR-1313 effects.
  '--mysqld=--plugin-load-add=provider_lzo.so --mysqld=--plugin-load-add=provider_bzip2.so --mysqld=--plugin-load-add=provider_lzma.so ' .
  '--mysqld=--plugin-load-add=provider_snappy.so --mysqld=--plugin-load-add=provider_lz4.so ';

our $duration = 300;
our $grammars =
[

  # modules/acl.yy unclear error
  # modules/admin.yy -> error if RocksDB missing
  #
  # conf/mariadb/modules/userstat.yy    quite unlikely that it hits something of interest for InnoDB
  # conf/mariadb/sp.yy                  quite unlikely that it hits something of interest for InnoDB


  # Crowd of tests used by Elena in history.
  #    The mass of redefines per test cause sometimes an
  #    - advantage
  #      Find bugs which the lean tests don't catch.
  #    - disadvantages
  #      - Slower RQG test simplifier
  #      - Hit too many unwanted/known but not yet fixed bugs
  #    compared to using more lean tests
  #    So better run that crowd but use rather lean or hand crafted tests for simplification
  #    or specific features if possible.
  # DDL-DDL, DDL-DML, DML-DML
  '--gendata=conf/mariadb/oltp.zz --max_gd_duration=900 --grammar=conf/mariadb/oltp.yy --redefine=conf/mariadb/instant_add.yy',
  # Heavy space consumption in tmpfs -> throtteling by ResourceControl -> CPU's 30% idle
    '--gendata=conf/percona_qa/BT-16274/BT-16274.zz --grammar=conf/percona_qa/BT-16274/BT-16274.yy ' .
        '--redefine=conf/mariadb/alter_table.yy --redefine=conf/mariadb/instant_add.yy --redefine=conf/mariadb/bulk_insert.yy --redefine=conf/mariadb/redefine_temporary_tables.yy',
  # Heavy space consumption in tmpfs -> throtteling by ResourceControl -> CPU's 30% idle
    '--gendata=conf/percona_qa/percona_qa.zz --max_gd_duration=900 --grammar=conf/percona_qa/percona_qa.yy ' .
        '--redefine=conf/mariadb/alter_table.yy --redefine=conf/mariadb/instant_add.yy --redefine=conf/mariadb/bulk_insert.yy --redefine=conf/mariadb/versioning.yy --redefine=conf/mariadb/sequences.yy --redefine=conf/mariadb/redefine_temporary_tables.yy',
  '--views --grammar=conf/mariadb/partitions_innodb.yy ' .
      '--redefine=conf/mariadb/alter_table.yy --redefine=conf/mariadb/instant_add.yy --redefine=conf/mariadb/modules/alter_table_columns.yy --redefine=conf/mariadb/bulk_insert.yy --redefine=conf/mariadb/modules/foreign_keys.yy --redefine=conf/mariadb/modules/locks.yy --redefine=conf/mariadb/modules/sql_mode.yy --redefine=conf/mariadb/versioning.yy --redefine=conf/mariadb/sequences.yy --redefine=conf/mariadb/modules/locks-10.4-extra.yy',
  '--gendata=conf/engines/innodb/full_text_search.zz --max_gd_duration=1200 --short_column_names --grammar=conf/engines/innodb/full_text_search.yy ' .
      '--redefine=conf/mariadb/alter_table.yy --redefine=conf/mariadb/instant_add.yy --redefine=conf/mariadb/modules/alter_table_columns.yy --redefine=conf/mariadb/bulk_insert.yy --redefine=conf/mariadb/modules/foreign_keys.yy --redefine=conf/mariadb/modules/locks.yy --redefine=conf/mariadb/modules/sql_mode.yy --redefine=conf/mariadb/redefine_temporary_tables.yy --redefine=conf/mariadb/versioning.yy --redefine=conf/mariadb/sequences.yy',
  '--gendata=conf/engines/engine_stress.zz --views --grammar=conf/engines/engine_stress.yy ' .
      '--redefine=conf/mariadb/alter_table.yy --redefine=conf/mariadb/instant_add.yy --redefine=conf/mariadb/modules/alter_table_columns.yy --redefine=conf/mariadb/bulk_insert.yy --redefine=conf/mariadb/modules/foreign_keys.yy --redefine=conf/mariadb/modules/locks.yy --redefine=conf/mariadb/modules/sql_mode.yy --redefine=conf/mariadb/versioning.yy --redefine=conf/mariadb/sequences.yy --redefine=conf/mariadb/modules/locks-10.4-extra.yy',

  # This can run even without "extra" main grammar
  '--gendata --vcols --views --grammar=conf/mariadb/instant_add.yy',

  '--grammar=conf/runtime/metadata_stability.yy --gendata=conf/runtime/metadata_stability.zz',
  '--grammar=conf/engines/many_indexes.yy --gendata=conf/engines/many_indexes.zz',
  '--grammar=conf/mariadb/partitions_innodb.yy',
  '--grammar=conf/mariadb/partitions_innodb.yy --gendata-advanced --skip-gendata',
  '--grammar=conf/replication/replication.yy --gendata=conf/replication/replication-5.1.zz --max_gd_duration=1200', # rr on asan_Og exceeded 900 * 1.5
  '--grammar=conf/mariadb/oltp-transactional.yy --gendata=conf/mariadb/oltp.zz --max_gd_duration=900 ',
  '--grammar=conf/mariadb/oltp-transactional.yy --gendata-advanced --skip-gendata',
  '--grammar=conf/runtime/alter_online.yy --gendata=conf/runtime/alter_online.zz',

  # DDL-DDL, DDL-DML, DML-DML, syntax   stress test   for several storage engines
  # Certain new SQL features might be not covered.
  # Rather small tables with short lifetime.
  '--gendata=conf/mariadb/concurrency.zz --gendata_sql=conf/mariadb/concurrency.sql --grammar=conf/mariadb/concurrency.yy',

  # rare DDL-DML, heavy DML-DML
  '--grammar=conf/mariadb/table_stress_innodb_dml.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql',

  # Main DDL-DDL, DDL-DML, DML-DML stress work horse   with generated virtual columns, fulltext indexes, KILL QUERY/SESSION, BACKUP STAGE
  '--grammar=conf/mariadb/table_stress_innodb.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql',
  '--grammar=conf/mariadb/table_stress_innodb.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --reporters=CrashRecovery',
  '--grammar=conf/mariadb/table_stress_innodb.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --reporters=CrashRecovery',
  # Derivate of above which tries to avoid any DDL rebuilding the table, also without BACKUP STAGE
  #     IMHO this fits more likely to the average fate of production applications.
  #     No change of PK, get default ALGORITHM which is NOCOPY if doable, no BACKUP STAGE because too new or rare and RPL used instead.
  '--grammar=conf/mariadb/table_stress_innodb_nocopy.yy  --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql',
  '--grammar=conf/mariadb/table_stress_innodb_nocopy1.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql',
  '--grammar=conf/mariadb/table_stress_innodb_nocopy1.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --reporters=RestartConsistency',
  '--grammar=conf/mariadb/table_stress_innodb_nocopy1.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --reporters=Mariabackup_linux',
  '--grammar=conf/mariadb/table_stress_innodb_nocopy1.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --reporters=CrashRecovery',
  '--grammar=conf/mariadb/table_stress_innodb_nocopy1.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --mysqld=--log-bin --rpl_mode=statement',
  '--grammar=conf/mariadb/table_stress_innodb_nocopy1.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --mysqld=--log-bin --rpl_mode=mixed',
  '--grammar=conf/mariadb/table_stress_innodb_nocopy1.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --mysqld=--log-bin --rpl_mode=row',
  '--grammar=conf/mariadb/table_stress_innodb_nocopy1.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --redefine=conf/mariadb/xa.yy',

  # Fiddle with FOREIGN Keys and TRUNCATE
  '--gendata=conf/mariadb/fk_truncate.zz --grammar=conf/mariadb/fk_truncate.yy',

  # DML only together with Mariabackup
  '--gendata=conf/mariadb/oltp.zz --max_gd_duration=900 --grammar=conf/mariadb/oltp.yy --reporters=Mariabackup_linux ',
  '--grammar=conf/engines/many_indexes.yy --gendata=conf/engines/many_indexes.zz --reporters=Mariabackup_linux ',
  '--gendata=conf/engines/engine_stress.zz --views --grammar=conf/engines/engine_stress.yy --redefine=conf/mariadb/modules/locks.yy --redefine=conf/mariadb/modules/sql_mode.yy --reporters=Mariabackup_linux ',
  '--grammar=conf/mariadb/oltp-transactional.yy --gendata=conf/mariadb/oltp.zz --max_gd_duration=900 --reporters=Mariabackup_linux ',
  # DML only together with RestartConsistency
  '--gendata=conf/mariadb/oltp.zz --max_gd_duration=900 --grammar=conf/mariadb/oltp.yy --reporters=RestartConsistency ',
  '--grammar=conf/engines/many_indexes.yy --gendata=conf/engines/many_indexes.zz --reporters=RestartConsistency ',
  '--gendata=conf/engines/engine_stress.zz --views --grammar=conf/engines/engine_stress.yy --redefine=conf/mariadb/modules/locks.yy --redefine=conf/mariadb/modules/sql_mode.yy --reporters=RestartConsistency ',
  '--grammar=conf/mariadb/oltp-transactional.yy --gendata=conf/mariadb/oltp.zz --max_gd_duration=900 --reporters=RestartConsistency ',
  # DML only together with CrashRecovery
  '--gendata=conf/mariadb/oltp.zz --max_gd_duration=900 --grammar=conf/mariadb/oltp.yy --reporters=CrashRecovery ',
  '--grammar=conf/engines/many_indexes.yy --gendata=conf/engines/many_indexes.zz --reporters=CrashRecovery ',
  '--gendata=conf/engines/engine_stress.zz --views --grammar=conf/engines/engine_stress.yy --redefine=conf/mariadb/modules/locks.yy --redefine=conf/mariadb/modules/sql_mode.yy --reporters=CrashRecovery ',
  '--grammar=conf/mariadb/oltp-transactional.yy --gendata=conf/mariadb/oltp.zz --max_gd_duration=900 --reporters=CrashRecovery ',

  # Tests checking transactional properties
  # =======================================
  # READ-UNCOMMITTED and READ-COMMITTED will be not assigned because they guarantee less than
  # we can check in the moment.
  # Disabled because not compatible with max_statement_timeout and other timeouts etc.
  # ' --grammar=conf/transactions/transactions.yy --gendata=conf/transactions/transactions.zz --validators=DatabaseConsistency ',
  ' --grammar=conf/transactions/repeatable_read.yy --gendata=conf/transactions/transactions.zz --validators=RepeatableRead ',
  ###
  # DML only together with --validator=SelectStability ----------------
  '--gendata=conf/mariadb/oltp.zz --max_gd_duration=900 --grammar=conf/mariadb/oltp.yy --mysqld=--transaction-isolation=REPEATABLE-READ --validator=SelectStability ',
  '--gendata=conf/mariadb/oltp.zz --max_gd_duration=900 --grammar=conf/mariadb/oltp.yy --mysqld=--transaction-isolation=SERIALIZABLE    --validator=SelectStability ',
  '--grammar=conf/engines/many_indexes.yy --gendata=conf/engines/many_indexes.zz --mysqld=--transaction-isolation=REPEATABLE-READ --validator=SelectStability ',
  '--grammar=conf/engines/many_indexes.yy --gendata=conf/engines/many_indexes.zz --mysqld=--transaction-isolation=SERIALIZABLE    --validator=SelectStability ',
  #     conf/engines/engine_stress.yy switches the ISOLATION LEVEL around and that does not fit to the capabilities of SelectStability
  # '--gendata=conf/engines/engine_stress.zz --views --grammar=conf/engines/engine_stress.yy --redefine=conf/mariadb/modules/locks.yy --redefine=conf/mariadb/modules/sql_mode.yy --validator=SelectStability ',
  '--grammar=conf/mariadb/oltp-transactional.yy --gendata=conf/mariadb/oltp.zz --max_gd_duration=900 --mysqld=--transaction-isolation=REPEATABLE-READ --validator=SelectStability ',
  '--grammar=conf/mariadb/oltp-transactional.yy --gendata=conf/mariadb/oltp.zz --max_gd_duration=900 --mysqld=--transaction-isolation=SERIALIZABLE    --validator=SelectStability ',
  # DDL-DDL, DDL-DML, DML-DML and KILL QUERY/SESSION etc.
  '--grammar=conf/mariadb/table_stress_innodb.yy         --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --mysqld=--transaction-isolation=REPEATABLE-READ  --validator=SelectStability ',
  '--grammar=conf/mariadb/table_stress_innodb.yy         --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --mysqld=--transaction-isolation=SERIALIZABLE     --validator=SelectStability ',
  '--grammar=conf/mariadb/table_stress_innodb_nocopy1.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --mysqld=--transaction-isolation=REPEATABLE-READ  --validator=SelectStability ',
  '--grammar=conf/mariadb/table_stress_innodb_nocopy1.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --mysqld=--transaction-isolation=SERIALIZABLE     --validator=SelectStability ',

  # Most probably not relevant for InnoDB testing
  # '--grammar=conf/runtime/performance_schema.yy  --mysqld=--performance-schema --gendata-advanced --skip-gendata',
  # '--grammar=conf/runtime/information_schema.yy --gendata-advanced --skip-gendata',
  # '--grammar=conf/partitioning/partition_pruning.yy --gendata=conf/partitioning/partition_pruning.zz',
  # '--grammar=conf/replication/replication-ddl_sql.yy --gendata=conf/replication/replication-ddl_data.zz',
  # '--grammar=conf/replication/replication-dml_sql.yy --gendata=conf/replication/replication-dml_data.zz',
  # '--grammar=conf/runtime/connect_kill_sql.yy --gendata=conf/runtime/connect_kill_data.zz',
  # '--grammar=conf/mariadb/optimizer.yy --gendata-advanced --skip-gendata',
  # '--grammar=conf/optimizer/updateable_views.yy --mysqld=--init-file='.$ENV{RQG_HOME}.'/conf/optimizer/updateable_views.init',
  # '--grammar=conf/mariadb/functions.yy --gendata-advanced --skip-gendata',

  "$test_compression_encryption                                                                --mysqld=--loose-innodb-encryption-threads=1 ",
  "$test_compression_encryption                                                                --mysqld=--loose-innodb-encryption-threads=7 ",
  "$test_compression_encryption                                                                --mysqld=--loose-innodb_encryption_rotate_key_age=1 ",
  "$test_compression_encryption                                                                --mysqld=--loose-innodb_encryption_rotate_key_age=2 ",
  "$test_compression_encryption                                                                --reporters=RestartConsistency ",
  "$test_compression_encryption                                                                --reporters=CrashRecovery     ",
  "$test_compression_encryption --mysqld=--innodb-encrypt-log --mysqld=--innodb-encrypt-tables                                ",
  "$test_compression_encryption --mysqld=--innodb-encrypt-log --mysqld=--innodb-encrypt-tables --reporters=RestartConsistency ",
  "$test_compression_encryption --mysqld=--innodb-encrypt-log --mysqld=--innodb-encrypt-tables --reporters=CrashRecovery     ",
  "$test_compression_encryption --mysqld=--innodb-encrypt-log --mysqld=--innodb-encrypt-tables --reporters=CrashRecovery --redefine=conf/mariadb/redefine_innodb_undo.yy --mysqld=--innodb-immediate-scrub-data-uncompressed=1 ",
];


# Most probably not relevant for InnoDB testing
#   --validators=TransformerNoComparator
#   --transformers=ExecuteAsCTE,ExecuteAsDeleteReturning,ExecuteAsExcept,ExecuteAsExecuteImmediate,ExecuteAsInsertSelect,ExecuteAsIntersect,ExecuteAsUnion,ExecuteAsUpdateDelete,ExecuteAsView,ExecuteAsPreparedTwice,ExecuteAsSPTwice
#   --vcols
#
# Avoid to hit known open or already fixed bugs:
# - MDEV-16664
#   InnoDB: Failing assertion: !other_lock || wsrep_thd_is_BF(lock->trx->mysql_thd, FALSE) || wsrep_thd_is_BF(other_lock->trx->mysql_thd, FALSE) for DELETE
#   --mysqld=innodb_lock_schedule_algorithm=fcfs
# - MDEV-16136
#   Various ASAN failures when testing 10.2/10.3
#   --mysqld=--innodb_stats_persistent=off
#
# - The server default "on" made trouble somewhere 2018 July/August
#   --mysqld=--innodb_adaptive_hash_index=off
#
# Avoid to hit known OS config limits in case the OS resource is too small (usually valid)
# and the MariaDB version is too old (< 10.0?). Newer versions can handle a shortage.
# --mysqld=--innodb_use_native_aio=0
#
# Avoid to generate frequent false alarms because of too short timeouts and too overloaded boxes.
# I prefer to set the timeouts even if its only the current default because defaults could be changed over time.
# When needing small timeouts within the test set it in the grammar.
#
# Excessive sql tracing via RQG makes the RQG logs rather fat and is frequent of low value only.
#     --sqltrace=MarkErrors
#

# Reason for not writing '--reporters=Backtrace,ErrorLog,Deadlock':
# Current RQG requires using either
#   --reporters=<list> ... but never --reporters=... again
# or
#   --reporters=<one reporter> ... --reporters=<one reporter> ...
# And it could be that already in the $grammars section some reporter was assigned.
#
$combinations = [ $grammars,
  [
    '
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
    --reporters=Backtrace --reporters=ErrorLog --reporters=Deadlock
    --validators=None
    --mysqld=--log_output=none
    --mysqld=--log_bin_trust_function_creators=1
    --mysqld=--loose-debug_assert_on_not_freed_memory=0
    --engine=InnoDB
    --restart_timeout=240
    ' .
    # Some grammars need encryption, file key management
    " $encryption_setup " .
    " $compression_setup " .
    " --duration=$duration --mysqld=--loose-innodb_fatal_semaphore_wait_threshold=300 ",
  ],
  [
    # innodb_file_per_table
    # ...
    # Page compression is only available with file-per-table tablespaces.
    # Note that this value is also used when a table is re-created with an ALTER TABLE which requires a table copy.
    # Scope: Global, Dynamic: Yes, Data Type: boolean, Default Value: ON
    '',
    ' --mysqld=--innodb_file_per_table=0 ',
    ' --mysqld=--innodb_file_per_table=1 ',
  ],
  [
    # Since ~ 10.5 or 10.6 going with ROW_FORMAT = Compressed was no more recommended because
    # ROW_FORMAT = <whatever !=Compressed> PAGE_COMPRESSED=1 is better.
    # In order to accelerate the move away from ROW_FORMAT = Compressed the variable
    # innodb_read_only_compressed with the default ON was introduced.
    # Impact on older tests + setups: ROW_FORMAT = Compressed is mostly no more checked.
    # Hence we need to enable checking of that feature by assigning innodb_read_only_compressed=OFF.
    # Forecast: ROW_FORMAT = Compressed will stay supported.
    ' --mysqld=--loose-innodb_read_only_compressed=OFF ',
  ],
  [
    # No more supported since 10.6
    ' --mysqld=--loose-innodb-sync-debug ',
    '',
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
    ' --mysqld=--innodb_sort_buffer_size=65536 ',
    '',
    '',
  ],
  [
    ' --redefine=conf/mariadb/redefine_checks_off.yy ',
    '',
    '',
  ],
  [
    # Binary logging is more likely enabled.
    # With log-bin and the default sync-binlog=0 we risk to get 'TBR-1136' (just to be expected
    # and not a bug) in Crashrecovery tests.
    ' --mysqld=--log-bin --mysqld=--sync-binlog=1 ',
    ' --mysqld=--log-bin --mysqld=--sync-binlog=1 ',
    #
    # Tests invoking MariaDB replication need binary logging too.
    # This has to be ensured per test in the $grammars section above!
    #
    # Binary logging is less likely disabled.
    # But this has to be checked too.
    # In adition certain bugs replay better if binary logging is not enabled.
    '',
  ],
  [
    ' --mysqld=--loose-innodb_evict_tables_on_commit_debug=off ',
    # This suffered and maybe suffers from https://jira.mariadb.org/browse/MDEV-20810
    ' --mysqld=--loose-innodb_evict_tables_on_commit_debug=on  ',
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
    # rr
    # - trace analysis is serious more comfortable than analyzing cores
    #   -> 2/3 of all runs should use it
    # - replays certain bugs significant less likely than without rr
    #   -> at least 1/3 of all runs go without it
    #   -> maybe running rr with and without --chaos helps a bit
    # - has trouble with (libaio or liburing)
    #   -> runs with rr use --mysqld=--innodb-use-native-aio=0
    #   -> runs without rr use --mysqld=--innodb-use-native-aio=1 so that InnoDB using
    #      libaio/liburing is covered at all
    #
    # In case rr denies to work because it does not know the CPU family than the rr option
    # --microarch can be set like in the next line.
    # Recommendations:
    # - Check if some newer version of rr can fix that problem.
    # - Needing such an assignment is a property specific to the testing box.
    #   So rather set this in local.cfg variable $rr_options_add.
    # " --mysqld=--innodb-use-native-aio=0 --rr=Extended --rr_options='--chaos --wait --microarch=\"Intel Kabylake\"' ",
    #
    # Experiments (try the values 1000, 300, 150) with the rr option "--num-cpu-ticks=<value>"
    # showed some remarkable impact on the user+nice versus system CPU time.
    # Lower values lead to some significant increase of system CPU time and context switches
    # per second. And that seems to cause a higher fraction of tests invoking rr where the
    # max_gd_timeout gets exceeded. Per current experience the impact on the fraction of bugs found
    # or replayed is rather more negative than positive. But there is one case where this helped.
    " --mysqld=--innodb-use-native-aio=0 --mysqld=--loose-gdb --mysqld=--loose-debug-gdb --rr=Extended --rr_options='--wait' ",
    " --mysqld=--innodb-use-native-aio=0 --mysqld=--loose-gdb --mysqld=--loose-debug-gdb --rr=Extended --rr_options='--chaos --wait' ",
    # Coverage for libaio or liburing.
    " --mysqld=--innodb_use_native_aio=1 ",
    # rr+InnoDB running on usual filesystem on HDD or SSD need
    #     --mysqld=--innodb_flush_method=fsync
    # Otherwise already bootstrap fails.
    # Needing such an assignment is a property specific to the testing box.
    # So rather set this in local.cfg variable $rqg_slow_dbdir_rr_add.
  ],
  [
    '',
    '',
    '',
    '',
    # Next line suffered in history much of MDEV-26450.
    # innodb_undo_log_truncate=ON is not default. So it should run less frequent.
    ' --mysqld=--innodb_undo_tablespaces=3 --mysqld=--innodb_undo_log_truncate=ON ',
  ],
  [
    # innodb_change_buffering
    # Scope: Global     Dynamic: Yes
    # Data Type: enumeration (>= MariaDB 10.3.7), string (<= MariaDB 10.3.6)
    # Default Value:
    #   >= MariaDB 10.5.15, MariaDB 10.6.7, MariaDB 10.7.3, MariaDB 10.8.2: none
    #   <= MariaDB 10.5.14, MariaDB 10.6.6, MariaDB 10.7.2, MariaDB 10.8.1: all
    # Valid Values: inserts, none, deletes, purges, changes, all
    # Deprecated: MariaDB 10.9.0
    '',
    '',
    '',
    ' --mysqld=--loose_innodb_change_buffering=inserts ',
    ' --mysqld=--loose_innodb_change_buffering=none ',
    ' --mysqld=--loose_innodb_change_buffering=deletes ',
    ' --mysqld=--loose_innodb_change_buffering=purges ',
    ' --mysqld=--loose_innodb_change_buffering=changes ',
    ' --mysqld=--loose_innodb_change_buffering=all ',
  ],
  [
    # The default is off.
    ' --mysqld=--innodb_rollback_on_timeout=ON ',
    ' --mysqld=--innodb_rollback_on_timeout=OFF ',
    ' --mysqld=--innodb_rollback_on_timeout=OFF ',
    ' --mysqld=--innodb_rollback_on_timeout=OFF ',
    ' --mysqld=--innodb_rollback_on_timeout=OFF ',
  ],
  [
    # 1. innodb_page_size >= 32K requires a innodb-buffer-pool-size >=24M
    #    otherwise the start of the server will fail.
    # 2. An innodb-buffer-pool-size=5M should work well with innodb_page_size < 32K
    # 3. A huge innodb-buffer-pool-size will not give an advantage if the tables are small.
    # 4. Small innodb-buffer-pool-size and small innodb_page_size stress Purge more.
    # 5. Gendata is faster when using a big innodb-buffer-pool-size.
    # 6. If huge innodb-buffer-pool sizes
    #    - get accepted at all
    #    - work well
    #    does not fit into the characteristics of the current test battery.
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
  [
    # slow (usually SSD/HDD) at all in order to cover
    # - maybe a device with slow IO
    # - a filesystem type != tmpfs
    # fast (RAM) at all in order to cover
    # - some higher CPU and RAM IO load by not spending to much time on slow devices
    # - tmpfs
    #
    # 90% fast to 10% slow (if HDD or SSD) or 50% fast to 50% slow (if ext4 in virtual memory)
    # in order to
    # - get extreme load for CPU and RAM IO because that seems to be better for bug detection/replay
    #   A higher percentage for slow leads easy to a high percentage of CPU waiting for IO
    #   instead of CPU system/user
    # - avoid to wear out some SSD, the slow device might be a SSD, too fast
    ' --vardir_type=slow ',
    ' --vardir_type=slow ',
    ' --vardir_type=slow ',
    ' --vardir_type=slow ',
    ' --vardir_type=slow ',
    ' --vardir_type=fast ',
    ' --vardir_type=fast ',
    ' --vardir_type=fast ',
    ' --vardir_type=fast ',
    ' --vardir_type=fast ',
  ],
];

# Marko: (sentence is edited)
# @matthias.leich You can be more mad DBA than usual:
# enable STATS_AUTO_RECALC (on per default and needs innodb_stats_persistent enabled, also default)
# and do not hesitate to run ALTER TABLE mysql.innodb_index_stats FORCE in parallel to normal
# DDL/DML workload (including concurrent ALTER TABLE or ANALYZE TABLE on user tables).
