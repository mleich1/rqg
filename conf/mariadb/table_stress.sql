# Copyright (c) 2018, 2019 MariaDB Corporation Ab.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# Bookkeeping for RQG test threads which are allowed to be target of some
# KILL QUERY <session> or KILL <session> issued by the YY grammar.
#
# Concept:
# 1. *.sql creates the container (the table).
# 2. Per YY grammar (usual rule 'thread_connect') all RQG worker
#    threads which are allowed to get affected by KILL ...
#    - add (first connect) or
#    - replace (non first connect)
#    their entry in that table.
# 3. Per YY grammar RQG worker threads might manipulate the entries in this table.
# 4. Per YY grammar RQG worker threads (usual rule 'kill_query_or_session_or_release'
#    pick a processlist_id following whatever strategy (where condition) from this
#    table and "attack" the session via KILL ...
# Notes:
# The content of the table is expected to be imperfect because it cannot
# guaranteed that
# - a DML (INSERT/UPDATE/REPLACE/DELETE) passes
#   Transaction related fails are possible but expected to be rare because the
#   data modifying statements are rare. Of course the storage engine properties
#   will have some impact too.
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
#                   Maybe its some day in future useful.
# connect_time   -- The time of the last connect.
#                   The diff between current time and this could be used for
#                   sophisticated functionality like
#                   - longer lifetime is required (but not already sufficient)
#                     for generating bigger transactions
#                   - less connects and disconnects for some RQG worker thread
#                     increase the stress on functionality maybe in focus by
#                     spending less ressources on required activity being
#                     not or at least less in focus of checking
#
# Picking some good enough ENGINE for test . rqg_sessions:
# There are test variants which invoke killing the server process intentionally,
# restart and go on with whatever.
# 1. In case we would use MyISAM than we would have a serious risk that the table needs to be
#    repaired after such a crash. This would disturb to some more or less big extend.
# 2. In case we would use some more robust storage engine like InnoDB than the table should
#    survive the crash without trouble on restart etc.
# 3. For whatever engine where the table has survived without damage and proper data
#    we might be faced with minor trouble because of the data.
#    That all belongs to the previous server uptime.
# So it looks like ENGINE = InnoDB or MEMORY is the optimal choice.
# FIXME:
# Is it necessary to protect the table against grammars and redefines which use
# the YY grammar language builtin '_table' and attack them via DDL or DML?
#
CREATE SCHEMA rqg;
CREATE TABLE IF NOT EXISTS rqg . rqg_sessions (rqg_id BIGINT, processlist_id BIGINT, pid BIGINT, connect_time INT, PRIMARY KEY(rqg_id)) ENGINE = InnoDB ;

