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
# 2. I disabled certain tests, aded some new one and shifted the focus towards InnoDB.
#
#
# The suite contains certain adjustments in order to avoid critical areas with known but
# not yet fixed bugs.
#


our $grammars;
# require 'conf/mariadb/combo.grammars';

$grammars =
[

  # modules/acl.yy unclear error
  # modules/admin.yy -> error if RocksDB missing

  # Crowd of tests used by Elena in history.
  #    The mass of redefines per test cause
  #    - sometimes an advantage :
  #      Find bugs which the lean tests don't catch.
  #    - frequent disadvantages :
  #      - Slower RQG test simplifier
  #      - Hit too many unwanted/known but not yet fixed bugs
  #      compared to using more lean tests
  #    So better run that crowd but use rather lean or hand crafted tests for simplification
  #    or specific features if possible.
  #
  # Suffers in old releases massive from https://jira.mariadb.org/browse/MDEV-19449
  '--gendata=conf/mariadb/oltp.zz --grammar=conf/mariadb/oltp.yy --redefine=conf/mariadb/instant_add.yy',    # This looked once like a dud.
  '--gendata=conf/percona_qa/BT-16274/BT-16274.zz --grammar=conf/percona_qa/BT-16274/BT-16274.yy --redefine=conf/mariadb/alter_table.yy --redefine=conf/mariadb/instant_add.yy --redefine=conf/mariadb/sp.yy --redefine=conf/mariadb/bulk_insert.yy --redefine=conf/mariadb/redefine_temporary_tables.yy',
  '--gendata=conf/percona_qa/percona_qa.zz --grammar=conf/percona_qa/percona_qa.yy --redefine=conf/mariadb/alter_table.yy --redefine=conf/mariadb/instant_add.yy --redefine=conf/mariadb/bulk_insert.yy --redefine=conf/mariadb/versioning.yy --redefine=conf/mariadb/sequences.yy --redefine=conf/mariadb/redefine_temporary_tables.yy',
  '--views --grammar=conf/mariadb/partitions_innodb.yy --redefine=conf/mariadb/alter_table.yy --redefine=conf/mariadb/instant_add.yy --redefine=conf/mariadb/modules/alter_table_columns.yy --redefine=conf/mariadb/sp.yy --redefine=conf/mariadb/bulk_insert.yy --redefine=conf/mariadb/modules/userstat.yy --redefine=conf/mariadb/modules/foreign_keys.yy --redefine=conf/mariadb/modules/locks.yy --redefine=conf/mariadb/modules/sql_mode.yy --redefine=conf/mariadb/versioning.yy --redefine=conf/mariadb/sequences.yy --redefine=conf/mariadb/modules/locks-10.4-extra.yy',
  '--gendata=conf/engines/innodb/full_text_search.zz --short_column_names --grammar=conf/engines/innodb/full_text_search.yy --redefine=conf/mariadb/alter_table.yy --redefine=conf/mariadb/instant_add.yy --redefine=conf/mariadb/modules/alter_table_columns.yy --redefine=conf/mariadb/sp.yy --redefine=conf/mariadb/bulk_insert.yy --redefine=conf/mariadb/modules/foreign_keys.yy --redefine=conf/mariadb/modules/locks.yy --redefine=conf/mariadb/modules/sql_mode.yy --redefine=conf/mariadb/redefine_temporary_tables.yy --redefine=conf/mariadb/versioning.yy --redefine=conf/mariadb/sequences.yy',
  '--gendata=conf/engines/engine_stress.zz --views --grammar=conf/engines/engine_stress.yy --redefine=conf/mariadb/alter_table.yy --redefine=conf/mariadb/instant_add.yy --redefine=conf/mariadb/modules/alter_table_columns.yy --redefine=conf/mariadb/sp.yy --redefine=conf/mariadb/bulk_insert.yy --redefine=conf/mariadb/modules/userstat.yy --redefine=conf/mariadb/modules/foreign_keys.yy --redefine=conf/mariadb/modules/locks.yy --redefine=conf/mariadb/modules/sql_mode.yy --redefine=conf/mariadb/versioning.yy --redefine=conf/mariadb/sequences.yy --redefine=conf/mariadb/modules/locks-10.4-extra.yy',

  # This can run even without "extra" main grammar
  '--gendata --vcols --views --grammar=conf/mariadb/instant_add.yy',

  '--grammar=conf/runtime/metadata_stability.yy --gendata=conf/runtime/metadata_stability.zz',
  '--grammar=conf/engines/many_indexes.yy --gendata=conf/engines/many_indexes.zz',
  '--grammar=conf/mariadb/partitions_innodb.yy',
  '--grammar=conf/mariadb/partitions_innodb.yy --gendata-advanced --skip-gendata',
  '--grammar=conf/replication/replication.yy --gendata=conf/replication/replication-5.1.zz',
  '--grammar=conf/mariadb/oltp-transactional.yy --gendata=conf/mariadb/oltp.zz',
  '--grammar=conf/mariadb/oltp-transactional.yy --gendata-advanced --skip-gendata',
  '--grammar=conf/runtime/alter_online.yy --gendata=conf/runtime/alter_online.zz',

  # DDL-DDL, DDL-DML, DML-DML, syntax   stress test   for several storage engines
  # Certain new features might be not covered.
  '--gendata=conf/mariadb/concurrency.zz --gendata_sql=conf/mariadb/concurrency.sql --grammar=conf/mariadb/concurrency.yy',

  # Main DDL-DDL, DDL-DML stress work horse   with generated virtual columns, fulltext indexes, KILL QUERY/SESSION, BACKUP STAGE
  '--grammar=conf/mariadb/table_stress_innodb.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql',
  # Derivate of above which tries to avoid any DDL rebuilding the table, also without BACKUP STAGE
  #     IMHO this fits more likely to the average fate of production applications.
  #     No change of PK, get default ALGORITHM which is NOCOPY if doable, no BACKUP STAGE because too new and RPL used instead.
  '--grammar=conf/mariadb/table_stress_innodb_nocopy.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql',
  '--grammar=conf/mariadb/table_stress_innodb_nocopy.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --reporters=RestartConsistency',
  '--grammar=conf/mariadb/table_stress_innodb_nocopy.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql --reporters=CrashRecovery1',

  # Fiddle with FOREIGN Keys and TRUNCATE
  '--gendata=conf/mariadb/fk_truncate.zz --grammar=conf/mariadb/fk_truncate.yy',

  # Only used if there is some table_stress.yy version of special interest in RQG_HOME
  # '--grammar=table_stress.yy --gendata=conf/mariadb/table_stress.zz --gendata_sql=conf/mariadb/table_stress.sql',


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

];


# Most probably not relevant for InnoDB testing
#   --validators=TransformerNoComparator
#   --transformers=ExecuteAsCTE,ExecuteAsDeleteReturning,ExecuteAsExcept,ExecuteAsExecuteImmediate,ExecuteAsInsertSelect,ExecuteAsIntersect,ExecuteAsUnion,ExecuteAsUpdateDelete,ExecuteAsView,ExecuteAsPreparedTwice,ExecuteAsSPTwice
#   --vcols
#
# Avoid to hit known open bugs:
# - MDEV-16664
#   InnoDB: Failing assertion: !other_lock || wsrep_thd_is_BF(lock->trx->mysql_thd, FALSE) || wsrep_thd_is_BF(other_lock->trx->mysql_thd, FALSE) for DELETE
#   --mysqld=innodb_lock_schedule_algorithm=fcfs
# - MDEV-16136
#   Various ASAN failures when testing 10.2/10.3
#   --mysqld=--innodb_stats_persistent=off
#
#   Made trouble somewhere 2017 July/August
#   --mysqld=--innodb_adaptive_hash_index=ON    (server default)
#
# Avoid to hit known OS config limits. skylake01 has a big value but even that is too small!
# --mysqld=--innodb_use_native_aio=0
#
# Avoid to generate frequent false alarms because of too short timeouts and too overloaded boxes.
# I prefer to set the timeouts even if its only the current default because defaults could be changed over time.
# When needing small timeouts within the test set it in the grammar.
#
# Excessive sql tracing via RQG makes the RQG logs rather fat and is frequent of low value.
#     --sqltrace=MarkErrors
#
#

#   --reporters=Backtrace,ErrorLog,RestartConsistency,None
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
$combinations = [ $grammars,
  [
    '
    --mysqld=--innodb_use_native_aio=0
    --mysqld=--innodb_stats_persistent=off
    --mysqld=--innodb_adaptive_hash_index=OFF
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
    --duration=300
    --seed=random
    --reporters=Backtrace --reporters=ErrorLog --reporters=Deadlock1
    --validators=None
    --mysqld=--log_output=none
    --mysqld=--log-bin
    --mysqld=--log_bin_trust_function_creators=1
    --mysqld=--loose-max-statement-time=30
    --mysqld=--loose-debug_assert_on_not_freed_memory=0
    --engine=InnoDB
    --mysqld=--innodb-buffer-pool-size=256M
    --whitelist_statuses="\'STATUS_ANY_ERROR\'"
    --blacklist_statuses="\'STATUS_OK\'"
    --blacklist_patterns="\'Sentence is now longer than .{1,10} symbols. Possible endless loop in grammar. Aborting.\',\'\[ERROR\] InnoDB: preallocating .{1,120} with error 28\',\' is truncated: expected core file size \',\' is not a core dump: File truncated\'"
    '
  ],
  [
    ' --threads=2  ',
    ' --threads=8  ',
    ' --threads=32 ',
  ]
];

# blacklist_patterns
# ------------------
# - "ill" grammar caused by initial state or maybe masking
#   Sentence is now longer than ... Possible endless loop ...
# - no more space in filesystem containing the RQG vardir
#   - InnoDB suffering during server runtime
#     InnoDB: preallocating ... with error 28
#   - Server crashes with core but core file is too incomplete:
#     - is truncated: expected core file size
#     - is not a core dump: File truncated

