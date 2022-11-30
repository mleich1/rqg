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

# Bookkeeping for RQG test threads which are allowed to be target of some
# KILL QUERY <session> or KILL <session> issued by the YY grammar.
#
# Concept:
# 1. *.sql creates the container (the table).
# 2. Per YY grammar rule query_init or thread<number>_init all RQG worker
#    threads which are allowed to get affected by KILL ...
#    - add (first connect) or
#    - replace (non first connect)
#    their entry in that table.
# 3. Per YY grammar rule query or thread<number> RQG worker threads
#    - delete or
#    - update
#    entries for currently not connected RQG worker threads.
# 4. Per YY grammar rule query or thread<number> RQG worker threads
#    pick a processlist_id following whatever strategy from the table
#    and "attack" the session via KILL ...
# Notes:
# The content of the table is expected to be imperfect because it cannot
# guaranteed that
# - a DML (INSERT/UPDATE/REPLACE/DELETE) of this table passes.
#   Transaction related fails are at least thinkable.
# - the actual content of that table reflects the current state of the system
#   For example the last refresh of the table content might be too long ago.
# A KILL using
# - some processlist_id value of NULL or of some currently not existing id
#   will fail like expected but make no further trouble
# - some id belonging to some historic session already gone can never affect
#   some other currently existing session (maybe a RQG worker thread, some
#   reporter or whatever) because the DB server counts the ids all time up.
#   So that KILL ... will fail too.
#
# rqg_id         -- id of the RQG worker thread used within RQG
#                   This allows to identify what this worker is told to do
#                   per YY grammar content.
# processlist_id -- Processlist id of the RQG worker thread
#                   The value to be used in KILL ...
# pid            -- The process id in the OS.
#                   Maybe its sometimes useful.
# connect_time   -- The time of the last connect.
#                   The diff between current time and this could be used for
#                   sophisticated functionality like
#                   - longer lifetime is required (but not already sufficient)
#                     for generating bigger transactions
#                   - less connects and disconnects for some RQG worker thread
#                     increase the stress on functionality in focus by
#                     spending less ressources on required activity being
#                     not or at least less in focus of checking
#
CREATE TABLE IF NOT EXISTS test . rqg_sessions (rqg_id BIGINT, processlist_id BIGINT, pid BIGINT, connect_time INT, PRIMARY KEY(rqg_id)) ENGINE = MyISAM ;

