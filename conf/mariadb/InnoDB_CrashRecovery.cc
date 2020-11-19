# Copyright (C) 2020 MariaDB corporation Ab. All rights reserved.
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

our $test_compression_encryption =
  '--grammar=conf/mariadb/innodb_compression_encryption.yy --gendata=conf/mariadb/innodb_compression_encryption.zz ';

our $encryption_setup =
  '--mysqld=--plugin-load-add=file_key_management.so --mysqld=--loose-file-key-management-filename=$RQG_HOME/conf/mariadb/encryption_keys.txt ';

our $duration = 300;
our $grammars =
[

# '--grammar=conf/replication/replication.yy --gendata=conf/replication/replication-5.1.zz',
  # '--grammar=conf/replication/replication-ddl_sql.yy --gendata=conf/replication/replication-ddl_data.zz',
  # '--grammar=conf/replication/replication-dml_sql.yy --gendata=conf/replication/replication-dml_data.zz',
  # '--grammar=conf/optimizer/updateable_views.yy --mysqld=--init-file='.$ENV{RQG_HOME}.'/conf/optimizer/updateable_views.init',
  # '--grammar=conf/mariadb/functions.yy --gendata-advanced --skip-gendata',

    # DML only
    '--gendata=conf/mariadb/oltp.zz --grammar=conf/mariadb/oltp.yy ',
    '--grammar=conf/engines/many_indexes.yy --gendata=conf/engines/many_indexes.zz ',
    '--gendata=conf/engines/engine_stress.zz --views --grammar=conf/engines/engine_stress.yy --redefine=conf/mariadb/modules/locks.yy --redefine=conf/mariadb/modules/sql_mode.yy ',
    '--grammar=conf/mariadb/oltp-transactional.yy --gendata=conf/mariadb/oltp.zz ',

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
    # That encryption stuff was/is error prone.
    "$test_compression_encryption                                                                ",
    "$test_compression_encryption --mysqld=--innodb-encrypt-log                                  ",
    "$test_compression_encryption                               --mysqld=--innodb-encrypt-tables ",
    "$test_compression_encryption --mysqld=--innodb-encrypt-log --mysqld=--innodb-encrypt-tables ",

];


#
# Avoid to hit known open bugs:
# - MDEV-16664
#   InnoDB: Failing assertion: !other_lock || wsrep_thd_is_BF(lock->trx->mysql_thd, FALSE) || wsrep_thd_is_BF(other_lock->trx->mysql_thd, FALSE) for DELETE
#   --mysqld=innodb_lock_schedule_algorithm=fcfs
# - MDEV-16136
#   Various ASAN failures when testing 10.2/10.3
#   --mysqld=--innodb_stats_persistent=off
#
#   The server default "on" made trouble somewhere 2018 July/August
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
# Excessive sql tracing via RQG makes the RQG logs rather fat and is frequent of low value.
#     --sqltrace=MarkErrors
#

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
    --mysqld=--innodb_use_native_aio=1
    --mysqld=--innodb_lock_schedule_algorithm=fcfs
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
    --reporters=Backtrace --reporters=ErrorLog --reporters=Deadlock1 --reporters=CrashRecovery1
    --validators=None
    --mysqld=--log_output=none
    --mysqld=--log-bin
    --mysqld=--log_bin_trust_function_creators=1
    --mysqld=--loose-debug_assert_on_not_freed_memory=0
    --engine=InnoDB
    --restart_timeout=120
    --max_gd_duration=1000
    ' .
    # Some grammars need encryption, file key management
    " $encryption_setup " .
    " --duration=$duration --mysqld=--loose-innodb_fatal_semaphore_wait_threshold=$duration ",
    # --reporters=Backtrace --reporters=ErrorLog --reporters=Deadlock1 --reporters=CrashRecovery2
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
    # 1. innodb_page_size >= 32K requires a innodb-buffer-pool-size >=24M
    #    otherwise the start of the server will fail.
    # 2. An innodb-buffer-pool-size=5M should work well with innodb_page_size < 32K
    # 3. A huge innodb-buffer-pool-size will not give an advantage if the tables are small.
    # 4. Small innodb-buffer-pool-size and small innodb_page_size stress Purge more.
    ' --mysqld=--innodb_page_size=4K  --mysqld=--innodb-buffer-pool-size=5M   ',
    ' --mysqld=--innodb_page_size=4K  --mysqld=--innodb-buffer-pool-size=8M   ',
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


