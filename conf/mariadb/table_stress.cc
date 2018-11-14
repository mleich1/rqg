# Copyright (C) 2018 MariaDB Corporation Ab.
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

# In some environment with many parallel RQG runs the following settings
# are required for reducing trouble caused by
# - shortages of resources
# or
# - slow responses of clients and servers
# IMHO it is recommended to set values even if the current defaults are
# already good enough. Defaults could ge changed in future and than maybe
# to some unfortunate direction.
# =========================================================
# aio is on most boxes/OS a very short resource.
# So
# --mysqld=--loose_innodb_use_native_aio=0,
# is usually required but it implies that aio related code of InnoDB is not covered.
# It just prevents valueless starts of RQG runners and also other ugly effects to be
# accepted+already known from that reason.
#
#
# Threads running the queries from YY grammar might frequent lose their
# connection (get killed by other threads or reporters) and than need to
# 1. connect again (other timeouts are there important)
# 2. run a few initial SQL's (here the timouts above count) before the
#    running of YY grammar queries goes on
# And in case 1. or 2. fails the RQG core tends to claim STATUS_SERVER_CRASHED,
# STATUS_SERVER_CRASHED, STATUS_ENVIRONMENT_FAILURE and similar which might be
# some false alarm because in case the box is heavy loaded and timeouts are
# too short for that.
# 1. becomes often a victim of connection related timeouts.
# 2. becomes often a victim of locking related timeouts and depending on the functionality
#    within the RQG core we get either some immediate end of the RQG run with questionable
#    status or the test goes on but the thread has not done things which are mandatory
#    for the test to work proper. In the second case we could end up with false positives
#    and similar.
#    Per my experience the innodb lock and MDL lock timeouts are quite critical.
#    In case the threads should use small values for these timeout during YY grammar processing
#    than these timeouts could be set in the *_connect rules.
#
# connect_timeout
# Time in seconds that the server waits for a connect packet before returning a
# 'Bad handshake'. Increasing may help if clients regularly encounter
# 'Lost connection to MySQL server at 'X', system error: error_number' type-errors.
# Default: 10
# --mysqld=--connect_timeout=60
#
# net_read_timeout
# Time in seconds the server will wait for a client connection to send more data before aborting the read.
# Default: 30
# --mysqld=--net_read_timeout=30,
#
# net_write_timeout
# Time in seconds to wait on writing a block to a connection before aborting the write.
# Default: 60
# --mysqld=--net_write_timeout=60,
#
# idle_readonly_transaction_timeout
# Time in seconds that the server waits for idle read-only transactions before killing the
# connection. If set to 0, the default, connections are never killed.
# --mysqld=--loose-idle_readonly_transaction_timeout=0
# Default Value: 0
#
# idle_transaction_timeout
# Time in seconds that the server waits for idle transactions before killing the connection.
# If set to 0, the default, connections are never killed.
# Default Value: 0
# --mysqld=--loose-idle_transaction_timeout=0
#
# idle_write_transaction_timeout
# Time in seconds that the server waits for idle read-write transactions before killing the
# connection. If set to 0, the default, connections are never killed.
# Default Value: 0
# --mysqld=--loose-idle_write_transaction_timeout=0
#
# innodb_lock_wait_timeout
# Time in seconds that an InnoDB transaction waits for an InnoDB row lock (not table lock) before
# giving up with the error ERROR 1205 (HY000): Lock wait timeout exceeded; try restarting trans...
# When this occurs, the statement (not transaction) is rolled back. The whole transaction can be
# rolled back if the innodb_rollback_on_timeout option is used. Increase this for data warehousing
# applications or where other long-running operations are common, or decrease for OLTP and other
# highly interactive applications. This setting does not apply to deadlocks, which InnoDB detects
# immediately, rolling back a deadlocked transaction.
# 0 (from MariaDB 10.3.0) means no wait. See WAIT and NOWAIT.
# Default Value: 50
# --mysqld=--innodb-lock-wait-timeout=50
#
# interactive_timeout
# Time in seconds that the server waits for an interactive connection (one that connects with the
# mysql_real_connect() CLIENT_INTERACTIVE option) to become active before closing it.
# Default Value: 28800
# AFAIK RQG will not initiate such connections.
# --mysqld=--interactive_timeout=28800
#
# lock_wait_timeout
# Timeout in seconds for attempts to acquire metadata locks. Statements using metadata locks include
# FLUSH TABLES WITH READ LOCK, LOCK TABLES, HANDLER and DML and DDL operations on tables, stored
# procedures and functions, and views. The timeout is separate for each attempt, of which there may
# be multiple in a single statement. 0 (from MariaDB 10.3.0) means no wait. See WAIT and NOWAIT.
# Default Value:
#       86400 (1 day) >= MariaDB 10.2.4
#       31536000 (1 year) <= MariaDB 10.2.3
# --mysqld=--lock_wait_timeout=86400
#
# table_lock_wait_timeout
# Unused, and removed in MariaDB/MySQL 5.5.3
#   Default Value: 50
# IMHO ist better to set it because we do not know what RQG might meet.
# --mysqld=--loose-table_lock_wait_timeout=50
#
# wait_timeout
# Time in seconds that the server waits for a connection to become active before closing it.
# The session value is initialized when a thread starts up from either the global value,
# if the connection is non-interactive, or from the interactive_timeout value, if the connection
# is interactive.
#   Default Value: 28800
# --mysqld=--wait_timeout=28800
#
# slave_net_timeout
# Time in seconds for the slave to wait for more data from the master before considering the
# connection broken, after which it will abort the read and attempt to reconnect. The retry
# interval is determined by the MASTER_CONNECT_RETRY open for the CHANGE MASTER statement, while
# the maximum number of reconnection attempts is set by the master-retry-count variable.
# The first reconnect attempt takes place immediately.
# Default Value:
#       60 (1 minute) (>= MariaDB 10.2.4)
#       3600 (1 hour) (<= MariaDB 10.2.3)
# --mysqld=--slave_net_timeout=60
#
#
# Avoid to hit known open bugs:
# - MDEV-16664
#   InnoDB: Failing assertion: !other_lock || wsrep_thd_is_BF(lock->trx->mysql_thd, FALSE) ||
#           wsrep_thd_is_BF(other_lock->trx->mysql_thd, FALSE) for DELETE
#   --mysqld=--loose-innodb_lock_schedule_algorithm=fcfs
# - MDEV-16136 (now closed)
#   Various ASAN failures when testing 10.2/10.3
#   --mysqld=--innodb_stats_persistent=off
#
# I do not trust Recovery
# --reporters=Deadlock,ErrorLog,Backtrace,Recovery,Shutdown
$combinations = [
   [
      '
         --mysqld=--loose-innodb_lock_schedule_algorithm=fcfs
         --grammar=conf/mariadb/table_stress.yy
         --gendata=conf/mariadb/table_stress.zz
         --gendata_sql=conf/mariadb/table_stress.sql
         --engine=Innodb
         --reporters=Deadlock,ErrorLog,Backtrace
         --mysqld=--loose_innodb_use_native_aio=0
         --mysqld=--connect_timeout=60
         --mysqld=--net_read_timeout=30
         --mysqld=--net_write_timeout=60
         --mysqld=--loose-idle_readonly_transaction_timeout=0
         --mysqld=--loose-idle_transaction_timeout=0
         --mysqld=--loose-idle_write_transaction_timeout=0
         --mysqld=--interactive_timeout=28800
         --mysqld=--lock_wait_timeout=86400
         --mysqld=--innodb-lock-wait-timeout=50
         --mysqld=--loose-table_lock_wait_timeout=50
         --mysqld=--wait_timeout=28800
         --mysqld=--slave_net_timeout=60
         --mysqld=--log-output=none
         --duration=300
         --seed=random
         --sqltrace=MarkErrors
      '
   ],
   [
         '--threads=4',
         '--threads=8',
         '--threads=16',
         '--threads=32',
         '--threads=64',
   ],[
         '--mysqld=--innodb-flush-log-at-trx-commit=0',
         '--mysqld=--innodb-flush-log-at-trx-commit=1',
         '--mysqld=--innodb-flush-log-at-trx-commit=2',
         '--mysqld=--innodb-flush-log-at-trx-commit=3',
   ], [
         '--mysqld=--transaction-isolation=READ-UNCOMMITTED',
         '--mysqld=--transaction-isolation=READ-COMMITTED',
         '--mysqld=--transaction-isolation=REPEATABLE-READ',
         '--mysqld=--transaction-isolation=SERIALIZABLE'
   ],
];
