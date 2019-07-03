# Copyright (c) 2018, 2019 MariaDB Corporation Ab.
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
# set -x

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

OLD_PWD=`pwd`
set -e
cd "$WORKDIR"
set +e
# 2019-07-01T12:30:09 [343628] | [00] FATAL ERROR: 2019-07-01 12:30:09 failed to execute query BACKUP STAGE BLOCK_DDL: Deadlock found when trying to get lock; try restarting transaction
    FATAL_PATTERN='\[.*\] \| .* FATAL ERROR: '
# 2019-07-02 17:31:05 0 [ERROR] [FATAL] InnoDB: Semaphore wait has lasted > 600 seconds. We intentionally crash the server because it appears to be hung.
   FATAL_PATTERN1='\[ERROR\] \[FATAL\] InnoDB: '
# 2019-06-28T18:17:11 [179361] RESULT: The RQG run ended with status STATUS_SERVER_DEADLOCKED (107)
   STATUS_PATTERN='\[.*\] RESULT: The RQG run ended with status '
# 2019-06-25T14:01:52 [224814] | 190625 14:01:37 [ERROR] mysqld got signal 11 ;
   SIGNAL_PATTERN='\[.*\] \| .* \[ERROR\] mysqld got signal '
# 19/65.log:# 2018-08-29T16:02:22 [227268] | mysqld: /work_m/bb-10.2-marko/storage/innobase/handler/ha_innodb.cc:5248: void innobase_kill_query(handlerton*, THD*, thd_kill_levels): Assertion `trx->mysql_thd == thd' failed.
  ASSERT_PATTERN0='\[.*\] \| mysqld: .* Assertion .* failed'
# ASSERT_PATTERN1='\\[.*\\] \\| mariabackup: .* Assertion .* failed'
  ASSERT_PATTERN1='\[.*\] \| mariabackup: .* Assertion .* failed'
# 19/65.log:# 2018-08-29T16:02:22 [227268] | SUMMARY: AddressSanitizer: use-after-poison /work_m/bb-10.2-marko/storage/innobase/handler/ha_innodb.cc:5248 in innobase_kill_query
  ASAN_PATTERN='\[.*\] \| SUMMARY: AddressSanitizer: '

# 2018-09-02T18:27:10 [107463] | 2018-09-02 18:27:03 0x7f481064a700  InnoDB: Assertion failure in file /work_m/bb-10.2-marko/storage/innobase/lock/lock0lock.cc line 5573
  INNO_PATTERN1='\[.*\] \| .* InnoDB: Assertion failure'
# 2018-09-02T18:27:10 [107463] | InnoDB: Failing assertion: !other_lock || wsrep_thd_is_BF(lock->trx->mysql_thd, FALSE) || wsrep_thd_is_BF(other_lock->trx->mysql_thd, FALSE)
  INNO_PATTERN2='\[.*\] \| InnoDB: Failing assertion: '
# 2019-06-27T16:27:20 [192529] | 2019-06-27 16:26:38 265 [ERROR] InnoDB: Clustered record for sec rec not found index `uidx3` of table `test`.`t3`
  INNO_PATTERN3='\[.*\] \| .* \[ERROR\] InnoDB: '

EXCLUDE="egrep -iv 'whitelist|blacklist'"

# Remove the RQG test run specific part
# 28/1.log:# 2018-08-22T14:33:20 [128561] | mysqld:
#          <------------------------------->
# my $egalize        = "sed -e '1,\$s/.* \| mysqld: /mysqld: /g'";

  FATAL_EGALIZE=" -e '1,\$s/#.* | .* FATAL ERROR: .* failed/FATAL ERROR: <timestamp> failed/g'";
 STATUS_EGALIZE=" -e '1,\$s/#.* RESULT: The RQG run ended with status /RESULT: The RQG run ended with status /g'";
 SIGNAL_EGALIZE=" -e '1,\$s/#.* | .* \[ERROR\] mysqld got signal /[ERROR] mysqld got signal /g'";
ASSERT_EGALIZE0=" -e '1,\$s/#.* | mysqld: /mysqld: /g'"
ASSERT_EGALIZE1=" -e '1,\$s/#.* | mariabackup: /mariabackup: /g'"
   ASAN_EGALIZE=" -e '1,\$s/#.* | SUMMARY: AddressSanitizer: /SUMMARY: AddressSanitizer: /g'";
  INNO_EGALIZE1=" -e '1,\$s/#.* | .* InnoDB: Assertion failure /InnoDB: Assertion failure /g'";
  INNO_EGALIZE2=" -e '1,\$s/#.* | InnoDB: Failing assertion: /InnoDB: Failing assertion: /g'";
  INNO_EGALIZE3=" -e '1,\$s/#.* | .* \[ERROR\] InnoDB: /[ERROR] InnoDB: /g'";

# 2>/dev/null because maybe
# - the subdirectories (result of grammar simplifier runs)    or
# - the RQG logs do not exist
# MyCmd="egrep -H -e '$FATAL_PATTERN|$FATAL_PATTERN1|$STATUS_PATTERN|$SIGNAL_PATTERN|$ASSERT_PATTERN0|$ASSERT_PATTERN1|$ASAN_PATTERN|$INNO_PATTERN1|$INNO_PATTERN2|$INNO_PATTERN3' *.log */*.log 2>/dev/null | \
MyCmd="egrep -H -e \
'$FATAL_PATTERN|$FATAL_PATTERN1|$STATUS_PATTERN|$SIGNAL_PATTERN|\
 $ASSERT_PATTERN0|$ASSERT_PATTERN1|$ASAN_PATTERN|$INNO_PATTERN1|$INNO_PATTERN2|$INNO_PATTERN3' *.log */*.log 2>/dev/null | \
 $EXCLUDE | sed $FATAL_EGALIZE $STATUS_EGALIZE $SIGNAL_EGALIZE $ASSERT_EGALIZE0 $ASSERT_EGALIZE1 $ASAN_EGALIZE $INNO_EGALIZE1 $INNO_EGALIZE2 $INNO_EGALIZE3 | sort -n > issue_and_file.txt"
eval "$MyCmd"

MyCmd="sed -e '1,\$s/^.*[0-9][0-9]*.log://g' issue_and_file.txt | sort > issue_frequency.txt"
eval "$MyCmd"

MyCmd="sort -u issue_frequency.txt > issue_unique.txt"
eval "$MyCmd"

cd "$OLD_PWD"
vi "$WORKDIR"/issue_*
