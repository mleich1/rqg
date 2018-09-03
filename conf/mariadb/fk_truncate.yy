# Copyright (c) 2018, MariaDB Corporation
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

# The grammar is dedicated to stress tables having a foreign key relationship with concurrent
# - simple DML
# - TRUNCATE
# and was developed for checking patches for https://jira.mariadb.org/browse/MDEV-13564
# TRUNCATE TABLE and undo tablespace truncation are not compatible with Mariabackup.
#
# Problems replayed (2018-09):
# - not found in JIRA
#   mysqld: storage/innobase/row/row0mysql.cc:1724:
#   void init_fts_doc_id_for_ref(dict_table_t*, ulint*):
#   Assertion `foreign->foreign_table != __null' failed.
# - https://jira.mariadb.org/browse/MDEV-16664
#   InnoDB: Failing assertion: !other_lock || wsrep_thd_is_BF(lock->trx->mysql_thd, FALSE) ||
#           wsrep_thd_is_BF(other_lock->trx->mysql_thd, FALSE) for DELETE
#   and that even is "innodb_lock_schedule_algorithm=fcfs" was set.
#   The latter helped in some other replay test.
#

thread1_init:
    CREATE TABLE parent (a INT PRIMARY KEY) ENGINE=InnoDB ; CREATE TABLE child (a INT PRIMARY KEY, FOREIGN KEY (a) REFERENCES parent(a) ON UPDATE CASCADE) ENGINE=InnoDB;

thread_connect:
    SET SESSION lock_wait_timeout = 2 ; SET SESSION innodb_lock_wait_timeout = 1 ;

query_init:
    start_delay ;

start_delay:
   # Avoid that worker threads cause a server crash before reporters are started.
   # This leads often to STATUS_ENVIRONMENT_ERROR though a crash happened.
   { sleep 5; return undef } ;


thread1:
    truncate |
    dml      |
    dml      |
    dml      |
    dml      |
    dml      ;

truncate:
    TRUNCATE TABLE child  |
    TRUNCATE TABLE child  |
    TRUNCATE TABLE child  |
    TRUNCATE TABLE child  |
    TRUNCATE TABLE child  |
    TRUNCATE TABLE child  |
    TRUNCATE TABLE parent ;

query:
    dml ;

dml:
    update |
    insert |
    insert |
    delete ;

insert:
    INSERT INTO rand_table (a) VALUES rand_values ;

update:
    UPDATE OF rand_table SET a = my_int where ;

delete:
    DELETE FROM rand_table where ;

where:
    WHERE a = my_int               |
    WHERE a = my_int or a = my_int ;

rand_values:
    ( my_int) |
    ( my_int) , ( my_int) ;

my_int:
    # Maybe having some uneven distribution is of some value.
    { $my_int= 1                   } |
    { $my_int= $prng->int(1,    8) } |
    { $my_int= $prng->int(1,   64) } |
    { $my_int= $prng->int(1,  512) } |
    { $my_int= $prng->int(1, 4096) } |
    { $my_int= 'NULL'              } ;


rand_table:
    parent |
    child  ;


