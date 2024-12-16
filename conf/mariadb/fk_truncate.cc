# Copyright (C) 2016, 2020 MariaDB Corporation Ab.
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
# Time in seconds that the server waits for idle read-only transactions before killing the connection.
# If set to 0, the default, connections are never killed.
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
# Time in seconds that the server waits for idle read-write transactions before killing the connection.
# If set to 0, the default, connections are never killed.
# Default Value: 0
# --mysqld=--loose-idle_write_transaction_timeout=0
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

# I do not trust Recovery
# --reporters=Deadlock,ErrorLog,Backtrace,Recovery,Shutdown
#
# Its better to set that per command line
# --basedir1=/work_m/10.3/bld_fast
$combinations =
    [ [
        '
        --gendata=conf/mariadb/fk_truncate.zz
        --gendata_sql=conf/mariadb/fk_truncate.sql
        --threads=10
        --duration=300
        --queries=1000000
        --engine=InnoDB
        --reporter=ErrorLog,Backtrace
        --mysqld=--loose-idle_readonly_transaction_timeout=0
        --mysqld=--lock-wait-timeout=86400
        --mysqld=--wait_timeout=28800
        --mysqld=--net_read_timeout=30
        --mysqld=--connect_timeout=60
        --mysqld=--interactive_timeout=28800
        --mysqld=--log-output=none
        --mysqld=--loose-table_lock_wait_timeout=50
        --mysqld=--loose_innodb_use_native_aio=1
        --mysqld=--loose_innodb_lock_schedule_algorithm=fcfs
        --mysqld=--loose-idle_write_transaction_timeout=0
        --mysqld=--innodb_stats_persistent=off
        --mysqld=--slave_net_timeout=60
        --mysqld=--innodb-lock-wait-timeout=50
        --mysqld=--loose-idle_transaction_timeout=0
        --mysqld=--net_write_timeout=60
        --sqltrace=MarkErrors
        --no-mask
        --seed=random
     ' ] ];

