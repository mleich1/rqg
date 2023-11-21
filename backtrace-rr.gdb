# Copyright (C) 2020 MariaDB Corporation Ab.
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

set print elements 0
continue
when
thread apply all backtrace
# display <variable_name>    leads to
#     (rr) <number>: <variable_name> = <value>
# and is hereby better than
# print <variable_name>      leading to
#     (rr) $<number> = <value>
display write_slots.m_cache.m_pos
display buf_pool.free.count
display buf_pool.LRU.count
display buf_pool.flush_list.count
