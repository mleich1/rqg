# Copyright (C) 2020,2021 MariaDB corporation Ab. All rights reserved.
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
#

# InnoDB_CrashRecovery.cc
#
# Suite for "torturing" preferably InnoDB with concurrent DDL/DML/....
# interrupted by intentional server crash followed by restart with recovery and checks.
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
  # The availability of the plugins depends on 1. build mechanics 2. Content of OS install
  # The server startup will not fail if some plugin is missing except its very important
  # like for some storage engine. Of course some error message will be emitted.
  # Without this setting
  # - innodb page compression will be less till not covered by MariaDB versions >= 10.7
  # - upgrade tests starting with version < 10.7 and going up to version >= 10.7 will
  #   suffer from TBR-1313 effects.
  # In case the compression algorithm used is in ('zlib','lzma') than we can assign some compression level.
  # Use the smallest which is 1 instead of 6 (default).
  # The hope is that it raises the throughput and/or reduces the fraction of max_gd_timeout exceeded
  # and/or false alarms when running a test with compression.
  '--mysqld=--plugin-load-add=provider_lzo.so --mysqld=--plugin-load-add=provider_bzip2.so --mysqld=--plugin-load-add=provider_lzma.so ' .
  '--mysqld=--plugin-load-add=provider_snappy.so --mysqld=--plugin-load-add=provider_lz4.so --mysqld=--loose-innodb_compression_level=1';

our $duration = 300;
our $grammars =
[

    # DML only
    '--gendata=conf/mariadb/oltp.zz --max_gd_duration=900 --grammar=conf/mariadb/oltp.yy ',
    '--grammar=conf/engines/many_indexes.yy --gendata=conf/engines/many_indexes.zz ',
    '--gendata=conf/engines/engine_stress.zz --views --grammar=conf/engines/engine_stress.yy --redefine=conf/mariadb/modules/locks.yy ',
    '--grammar=conf/mariadb/oltp-transactional.yy --gendata=conf/mariadb/oltp.zz --max_gd_duration=900 ',
    '--grammar=conf/mariadb/table_stress_innodb_dml.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql',
    #               and FOREIGN KEYs
    '--grammar=conf/mariadb/table_stress_innodb_fk_dml.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql',

    # DDL/DML mix
    '--grammar=conf/mariadb/table_stress_innodb_nocopy.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql ',
    '--grammar=conf/mariadb/table_stress_innodb_nocopy1.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql ',
    '--gendata --vcols --views --grammar=conf/mariadb/instant_add.yy',
    '--gendata=conf/mariadb/concurrency.zz --gendata_sql=conf/mariadb/concurrency.sql --grammar=conf/mariadb/concurrency.yy',
    '--grammar=conf/mariadb/table_stress_innodb.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql',
    '--gendata=conf/mariadb/fk_truncate.zz --grammar=conf/mariadb/fk_truncate.yy',
    '--grammar=conf/runtime/alter_online.yy --gendata=conf/runtime/alter_online.zz',
    '--grammar=conf/mariadb/partitions_innodb.yy',
    '--grammar=conf/runtime/metadata_stability.yy --gendata=conf/runtime/metadata_stability.zz',
    '--views --grammar=conf/mariadb/partitions_innodb.yy ' .
    '--redefine=conf/mariadb/alter_table.yy --redefine=conf/mariadb/instant_add.yy --redefine=conf/mariadb/modules/alter_table_columns.yy --redefine=conf/mariadb/bulk_insert.yy --redefine=conf/mariadb/modules/foreign_keys.yy --redefine=conf/mariadb/modules/locks.yy --redefine=conf/mariadb/versioning.yy --redefine=conf/mariadb/sequences.yy --redefine=conf/mariadb/modules/locks-10.4-extra.yy',
    '--gendata=conf/engines/innodb/full_text_search.zz --max_gd_duration=1200 --short_column_names --grammar=conf/engines/innodb/full_text_search.yy ' .
      '--redefine=conf/mariadb/alter_table.yy --redefine=conf/mariadb/instant_add.yy --redefine=conf/mariadb/modules/alter_table_columns.yy --redefine=conf/mariadb/bulk_insert.yy --redefine=conf/mariadb/modules/foreign_keys.yy --redefine=conf/mariadb/modules/locks.yy --redefine=conf/mariadb/redefine_temporary_tables.yy --redefine=conf/mariadb/versioning.yy --redefine=conf/mariadb/sequences.yy',
    '--gendata=conf/engines/engine_stress.zz --views --grammar=conf/engines/engine_stress.yy ' .
      '--redefine=conf/mariadb/alter_table.yy --redefine=conf/mariadb/instant_add.yy --redefine=conf/mariadb/modules/alter_table_columns.yy --redefine=conf/mariadb/bulk_insert.yy --redefine=conf/mariadb/modules/foreign_keys.yy --redefine=conf/mariadb/modules/locks.yy --redefine=conf/mariadb/versioning.yy --redefine=conf/mariadb/sequences.yy --redefine=conf/mariadb/modules/locks-10.4-extra.yy',

    # That encryption stuff was/is error prone.
    "$test_compression_encryption                                                                ",
    "$test_compression_encryption --mysqld=--innodb-encrypt-log                                  ",
    "$test_compression_encryption                               --mysqld=--innodb-encrypt-tables ",
    "$test_compression_encryption --mysqld=--innodb-encrypt-log --mysqld=--innodb-encrypt-tables ",
    "$test_compression_encryption --mysqld=--innodb-encrypt-log --mysqld=--innodb-encrypt-tables --redefine=conf/mariadb/redefine_innodb_undo.yy --mysqld=--innodb-immediate-scrub-data-uncompressed=1 ",

];


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
    --no_mask
    --queries=10000000
    --seed=random
    --reporters=None --reporters=ErrorLog --reporters=Deadlock
    --validators=None
    --mysqld=--log_output=none
    --mysqld=--log_bin_trust_function_creators=1
    --mysqld=--loose-debug_assert_on_not_freed_memory=0
    --engine=InnoDB
    --restart_timeout=900
    --rows=10000
    ' .
    # Some grammars need encryption, file key management
    " $encryption_setup " .
    " $compression_setup " .
    " --duration=$duration --mysqld=--loose-innodb_fatal_semaphore_wait_threshold=300 ",
  ],
  [
    # 2023-06
    # The combination lock-wait-timeout=<small> -- innodb-lock-wait-timeout=<a bit bigger>
    # seems to be important too.
    '--mysqld=--lock-wait-timeout=15    --mysqld=--innodb-lock-wait-timeout=10' ,
    # The defaults 2023-06
    '--mysqld=--lock-wait-timeout=86400 --mysqld=--innodb-lock-wait-timeout=50' ,
  ],
# [
#   # The default is innodb_fast_shutdown=1.
#   '--mysqld=--loose-innodb_fast_shutdown=1' ,
#   '' ,
#   '' ,
#   '' ,
#   '--mysqld=--loose-innodb_fast_shutdown=0' ,
# ],
  [
    '--mysqld=--sql_mode=traditional' ,
    # Below the default since 10.2.4
    '--mysqld=--sql_mode=STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' ,
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
    ' --reporters=CrashRecovery     --duration=100 ',
    ' --reporters=CrashRecovery     --duration=100 ',
    ' --reporters=CrashRecovery     --duration=300 ',
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
    '',
    '',
  ],
  [
    # innodb_random_read_ahead: Default Value: OFF
    # innodb_read_ahead_threshold: Default Value: 56
    ' --mysqld=--innodb_random_read_ahead=OFF ',
    ' --mysqld=--innodb_random_read_ahead=OFF ',
    ' --mysqld=--innodb_random_read_ahead=OFF ',
    ' --mysqld=--innodb_random_read_ahead=OFF ',
    ' --mysqld=--innodb_random_read_ahead=ON --mysqld=--innodb_read_ahead_threshold=0 ',
    ' --mysqld=--innodb_random_read_ahead=ON ',
  ],
  [
    ' --mysqld=--innodb-open-files=10 ',
    '',
    '',
    '',
    '',
  ],
  [
    ' --redefine=conf/mariadb/redefine_checks_off.yy ',
    '',
    '',
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
    # Default Value: OFF
    ' --mysqld=--innodb_undo_log_truncate=OFF ',
    ' --mysqld=--innodb_undo_log_truncate=OFF ',
    ' --mysqld=--innodb_undo_log_truncate=OFF ',
    ' --mysqld=--innodb_undo_log_truncate=ON ',
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
    # Global, not dynamic
    # Default Value: 3 (>= MariaDB 11.0), 0 (<= MariaDB 10.11)
    # Range: 0, or 2 to 95 (>= MariaDB 10.2.2), 0, or 2 to 126 (<= MariaDB 10.2.1)
    '',
    '',
    ' --mysqld=--innodb_undo_tablespaces=0 ',
    ' --mysqld=--innodb_undo_tablespaces=3 ',
    ' --mysqld=--innodb_undo_tablespaces=16 ',
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


