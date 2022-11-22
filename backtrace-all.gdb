# Copyright (C) 2008 Sun Microsystems, Inc. All rights reserved.
# Copyright (C) 2020, 2021 MariaDB Corporation Ab.
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
# "full" consumes a rather not acceptable amount of CPU time and elapsed time.
# Given the facts that
# - search patterns are based on non "full" backtraces if at all
# - we have frequent several hits for one problem and only one archive gets finally picked
#   for analysis
# the generation of a backtrace with "full" can be made later for the case picked.
# echo #===== Output of GDB     thread apply all backtrace full   ===================#
# thread apply all backtrace full
echo #===== Output of GDB     thread apply all backtrace        ===================#
thread apply all backtrace

