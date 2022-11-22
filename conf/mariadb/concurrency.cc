# Copyright (C) 2018, 2021 MariaDB Corporation Ab. All rights reserved.
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


our $encryption_setup =
  '--mysqld=--plugin-load-add=file_key_management.so --mysqld=--loose-file-key-management-filename=$RQG_HOME/conf/mariadb/encryption_keys.txt ';

our $duration = 300;
our $grammars =
[

  # DDL-DDL, DDL-DML, DML-DML, syntax   stress test   for several storage engines
  # Certain new features might be not covered.
  '--gendata=conf/mariadb/concurrency.zz --gendata_sql=conf/mariadb/concurrency.sql --grammar=conf/mariadb/concurrency.yy',

  # Main DDL-DDL, DDL-DML stress work horse   with generated virtual columns, fulltext indexes, KILL QUERY/SESSION, BACKUP STAGE
  # Derivate of above which tries to avoid any DDL rebuilding the table, also without BACKUP STAGE
  #     IMHO this fits more likely to the average fate of production applications.
  #     No change of PK, get default ALGORITHM which is NOCOPY if doable, no BACKUP STAGE because too new or rare and RPL used instead.

];


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
    --restart_timeout=360
    ' .
    # Some grammars need encryption, file key management
    " $encryption_setup " .
    " --duration=$duration --mysqld=--loose-innodb_fatal_semaphore_wait_threshold=300 ",
  ],
  [
    # Since ~ 10.5 or 10.6 going with ROW_FORMAT = Compressed is no more recommended because
    # ROW_FORMAT = <whatever !=Compressed> PAGE_COMPRESSED=1 is better.
    # In order to accelerate the move away from ROW_FORMAT = Compressed the variable
    # innodb_read_only_compressed with the default ON was introduced.
    # Impact on older tests + setups: ROW_FORMAT = Compressed is mostly no more checked.
    # Hence we need to enable checking of that feature till ist removed via
    # innodb_read_only_compressed=OFF.
    ' --mysqld=--loose-innodb_read_only_compressed=OFF ',
  ],
  [
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
    '--mysqld=--transaction-isolation=READ-UNCOMMITTED',
    '--mysqld=--transaction-isolation=READ-COMMITTED',
    '--mysqld=--transaction-isolation=REPEATABLE-READ',
    '--mysqld=--transaction-isolation=SERIALIZABLE'
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
    # " --mysqld=--innodb-use-native-aio=0 --rr=Extended --rr_options='--chaos --wait --microarch=\"Intel Kabylake\"' ",
    #
    # Experiments (try the values 1000, 300, 150) with the rr option "--num-cpu-ticks=<value>"
    # showed some remarkable impact on the user+nice versus system CPU time.
    # Lower values lead to some significant increase of system CPU time and context switches
    # per second. And that seems to cause a higher fraction of tests invoking rr where the
    # max_gd_timeout gets exceeded.
    # But up till now the impact on the fraction of bugs found or replayed is unclear.
    " --mysqld=--innodb-use-native-aio=0 --rr=Extended --rr_options='--chaos --wait' ",
    " --mysqld=--innodb-use-native-aio=0 --rr=Extended --rr_options='--wait' ",
    # Coverage for libaio or liburing.
    " --mysqld=--innodb_use_native_aio=1 ",
    # rr+InnoDB running on usual filesystem on HDD or SSD need
    #     --mysqld=--innodb_flush_method=fsync
    # Otherwise already bootstrap fails.
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
];

# Marko: (sentence is edited)
# @matthias.leich You can be more mad DBA than usual:
# enable STATS_AUTO_RECALC (on per default and needs innodb_stats_persistent enabled, also default)
# and do not hesitate to run ALTER TABLE mysql.innodb_index_stats FORCE in parallel to normal
# DDL/DML workload (including concurrent ALTER TABLE or ANALYZE TABLE on user tables).
