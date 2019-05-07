# conf/mariadb/innodb_compression_encryption1.cc
# ----------------------------------------------
# This is a derivate of conf/mariadb/innodb_compression_encryption.cc
# containing adjustments to properties of MariaDB 10.4 (2019-03).
#
# Purpose:
# Check InnoDB compression/encryption in general.
#

# mleich: Some changes compared to innodb_compression_encryption.cc
# 0. --queries=100000000 instead of --queries=100M because rqg.pl does not have the required conversion
# 1. boot_strap failed
#    ...  [Warning] InnoDB: Failed to set O_DIRECT on file./ibdata1; CREATE: Invalid argument, continuing anyway. O_DIRECT is known to result in 'Invalid argument' on Linux on tmpfs, see MySQL Bug#26662.
#       --mysqld=--innodb_flush_method=O_DIRECT
# 2. --innodb-use-trim
#    Deprecated: MariaDB 10.2.4
#    Removed: MariaDB 10.3.0
# 3. --innodb_use_fallocate
#    Deprecated: MariaDB 10.2.5 (treated as if ON)
#    Removed: MariaDB 10.3.0
# 4. --mysqld=--plugin-load-add=file_key_management.so failed because .so was not found
#    Solution: Create the expected directory inside basedir and copy the .so's into that directory.
#    Note:
#    The yy grammar loads file_key_management.so in the grammar rule 'query_init'.
#    Nevertheless the .so etc. need to be assigned to the server startup because RestartConsistency
#    makes a server shutdown and a restart. And after that restart the YY grammar will be not
#    used again but the file_key_management.so and mariadb/encryption_keys.txt are required.
# 5. (maybe temporary) --duration=300 instead of --duration=600
#    --sqltrace=MarkErrors
#    --mysqld=--loose_innodb_use_native_aio=0
# 6. (temporary) Omit the reporter QueryTimeout
#    Original: --reporters=QueryTimeout,Backtrace,ErrorLog,Deadlock,RestartConsistency
#    Basic reason:
#    When using the reporter 'QueryTimeout' I met frequent
#    a) certain DDL's (especially CREATE TABLE OR REPLACE ... AS SELECT ...) were killed because
#       lasting too long (intended/to be accepted)
#    b) too frequent in server error log before shutdown/restart
#          cannot do this or that because some "<final table_name>.ibd" already exists
#          and a hint how to fix that
#    c) mysqldump called by the reporter 'RestartConsistency' before server shutdown fails with
#          Got error: 1146: "Table 'test.<final table_name>' doesn't exist" when using LOCK TABLES
#    d) frequent diffs between dump before and after server shutdown/restart like
#       autoincrement value or encryption key value or ....
#       There was at least never a diff of table content.
#    e) The server error log after shutdown/restart was all time free of suspicious messages.
#    Assumed problem:
#    DDL's affected by the KILL QUERY emitted by QueryTimeout are not atomic regarding file system
#    content. There is maybe more not atomic.
#    Hence we get either
#    - an inconsistency between server and InnoDB data dictionary reported in server error log
#      or as response to whatever SQL
#    or
#    - the server denies to execute certain DDL because he feels unsure if he is allowed to
#      a file "<looks like a final table_name>.ibd".
# 7. (maybe permanent) Play around with different values for
#    innodb_buffer_pool_instances , innodb_doublewrite , innodb-encryption-threads , threads
#
$combinations = [
    [
        '
          --no-mask
          --seed=time
          --duration=300
          --engine=InnoDB
          --queries=100000000
          --mysqld=--loose_innodb_use_native_aio=0
          --reporters=Backtrace,ErrorLog,Deadlock,RestartConsistency
          --restart_timeout=30
          --mysqld=--log_output=FILE
          --sqltrace=MarkErrors
          --grammar=conf/mariadb/innodb_compression_encryption.yy
          --gendata=conf/mariadb/innodb_compression_encryption.zz
          --mysqld=--loose-innodb-use-atomic-writes
          --mysqld=--plugin-load-add=file_key_management.so
          --mysqld=--loose-file-key-management-filename=$RQG_HOME/conf/mariadb/encryption_keys.txt
        '
    ],[
        '--mysqld=--loose-innodb_buffer_pool_instances=1  ',
        '--mysqld=--loose-innodb_buffer_pool_instances=3  ',
        '--mysqld=--loose-innodb_buffer_pool_instances=11 ',
    ],[
        '--mysqld=--loose-innodb_doublewrite=0 ',
        '--mysqld=--loose-innodb_doublewrite=0 ',
        '--mysqld=--loose-innodb_doublewrite=1 ',
    ],[
        '--mysqld=--loose-innodb-encryption-threads=1 ',
        '--mysqld=--loose-innodb-encryption-threads=7 ',
    ],[
        '--threads=1  ',
        '--threads=13 ',
    ],[
        ' ',
        '--mysqld=--innodb-encrypt-log ',
    ],[
        ' ',
        '--mysqld=--innodb-encrypt-tables '
    ],

];

