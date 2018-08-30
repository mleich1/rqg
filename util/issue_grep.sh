# Copyright (c) 2018 MariaDB Corporation Ab.
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

# Generate files containing some summary about the RQG run logs located in a directory
# (WORKDIR) and its direct sub directories. These summary files will be stored in WORKDIR.
#
# The directory WORKDIR can be assigned via command line
# - will be set to the symlinks
#   - 'last_batch_workdir'

WORKDIR="$1"
if [ "$WORKDIR" = "" ]
then
    # Assuming that
    # - OS is a UNIX derivate with support for symlinks
    # - the last run of rqg_batch.pl is meant
    if [ -s "last_batch_workdir" ]
    then
        WORKDIR="last_batch_workdir"
    elif [ -s "last_simp_workdir" ]
    then
        WORKDIR="last_simp_workdir"
    else
        echo "No symlinks 'last_batch_workdir' or ' last_simp_workdir' found."
        echo "Please call the script like"
        echo ""
        echo "       $0 <directory to be inspected>"
        exit
    fi
else
    if [ ! -e "$WORKDIR" ]
    then
        echo "($0) ERROR: The assigned WORKDIR '$WORKDIR' does not exist."
        exit
    fi
fi

set -e
cd "$WORKDIR"
set +e

# 19/65.log:# 2018-08-29T16:02:22 [227268] | mysqld: /work_m/bb-10.2-marko/storage/innobase/handler/ha_innodb.cc:5248: void innobase_kill_query(handlerton*, THD*, thd_kill_levels): Assertion `trx->mysql_thd == thd' failed.
ASSERT_PATTERN='\\[.*\\] \\| mysqld: .* Assertion .* failed'
# 19/65.log:# 2018-08-29T16:02:22 [227268] | SUMMARY: AddressSanitizer: use-after-poison /work_m/bb-10.2-marko/storage/innobase/handler/ha_innodb.cc:5248 in innobase_kill_query
  ASAN_PATTERN='\\[.*\\] \\| SUMMARY: AddressSanitizer: '

# Remove the RQG test run specific part
# 28/1.log:# 2018-08-22T14:33:20 [128561] | mysqld:
#          <------------------------------->
# my $egalize        = "sed -e '1,\$s/.* \| mysqld: /mysqld: /g'";

ASSERT_EGALIZE="sed -e '1,\$s/#.* | mysqld: /mysqld: /g'"
  ASAN_EGALIZE="sed -e '1,\$s/#.* | SUMMARY: AddressSanitizer: /SUMMARY: AddressSanitizer: /g'";

# 2>/dev/null because maybe
# - the subdirectories (result of grammar simplifier runs)    or
# - the RQG logs do not exist 
MyCmd="egrep -H -e '$ASSERT_PATTERN|$ASAN_PATTERN' *.log */*.log 2>/dev/null | $ASSERT_EGALIZE | $ASAN_EGALIZE | sort -n > issue_and_file.txt"
eval "$MyCmd"

MyCmd="sed -e '1,\$s/^.*[0-9][0-9]*.log://g' issue_and_file.txt | sort > issue_frequency.txt"
eval "$MyCmd"

MyCmd="sort -u issue_frequency.txt > issue_unique.txt"
eval "$MyCmd"

