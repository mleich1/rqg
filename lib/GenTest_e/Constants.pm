# Copyright (c) 2008,2011 Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2013 Monty Program Ab.
# Copyright (c) 2018,2022 MariaDB Corporation Ab.
# Copyright (c) 2023 MariaDB plc
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

package GenTest_e::Constants;

use Carp;

require Exporter;

@ISA = qw(Exporter);

@EXPORT = qw(
   STATUS_PREFIX

   STATUS_OK
   STATUS_FAILURE
   STATUS_CONFIGURATION_ERROR
   STATUS_INTERNAL_ERROR
   STATUS_UNKNOWN_ERROR
   STATUS_ANY_ERROR

   STATUS_EOF
   STATUS_ENVIRONMENT_FAILURE
   STATUS_PERL_FAILURE

   STATUS_CUSTOM_OUTCOME

   STATUS_WONT_HANDLE
   STATUS_SKIP
   STATUS_SKIP_RELOOP

   STATUS_UNSUPPORTED
   STATUS_SYNTAX_ERROR
   STATUS_SEMANTIC_ERROR
   STATUS_TRANSACTION_ERROR

   STATUS_TEST_FAILURE

   STATUS_REQUIREMENT_UNMET_SELECT
   STATUS_ERROR_MISMATCH_SELECT
   STATUS_LENGTH_MISMATCH_SELECT
   STATUS_CONTENT_MISMATCH_SELECT
   STATUS_SELECT_REDUCTION

   STATUS_REQUIREMENT_UNMET
   STATUS_ERROR_MISMATCH
   STATUS_SCHEMA_MISMATCH
   STATUS_LENGTH_MISMATCH
   STATUS_CONTENT_MISMATCH

   STATUS_POSSIBLE_FAILURE

   STATUS_CRITICAL_FAILURE
   STATUS_SERVER_CRASHED
   STATUS_SERVER_KILLED
   STATUS_REPLICATION_FAILURE
   STATUS_BACKUP_FAILURE
   STATUS_SERVER_SHUTDOWN_FAILURE
   STATUS_RECOVERY_FAILURE
   STATUS_UPGRADE_FAILURE
   STATUS_DATABASE_CORRUPTION
   STATUS_SERVER_DEADLOCKED
   STATUS_VALGRIND_FAILURE
   STATUS_ALARM

   STATUS_RSS_DOUBLED

   ORACLE_ISSUE_STILL_REPEATABLE
   ORACLE_ISSUE_NO_LONGER_REPEATABLE
   ORACLE_ISSUE_STATUS_UNKNOWN

   DB_UNKNOWN
   DB_DUMMY
   DB_MYSQL
   DB_POSTGRES
   DB_JAVADB
   DB_DRIZZLE

   DEFAULT_MTR_BUILD_THREAD

   constant2text
   status2text
);

use strict;

use constant STATUS_PREFIX                     => 'RESULT: The RQG run ended with status ';

use constant STATUS_OK                         => 0;    # Suitable for exit code
use constant STATUS_FAILURE                    => 1;    # Used as opposite of STATUS_OK by certain routines
use constant STATUS_UNKNOWN_ERROR              => 2;

use constant STATUS_ANY_ERROR                  => 3;    # Used in util/simplify* to not differentiate based on error code

use constant STATUS_EOF                        => 4;    # A module requested that the test is terminated without failure

use constant STATUS_WONT_HANDLE                => 5;    # A module, e.g. a Validator refuses to handle certain query
use constant STATUS_SKIP                       => 6;    # A Filter specifies that the query should not be processed further
use constant STATUS_SKIP_RELOOP                => 7;    # The Executor detected that the connection was lost but connect is possible.
                                                        # Assume: Loss of connection from natural reason.

use constant STATUS_UNSUPPORTED                => 20; # Error codes caused by certain functionality recognized as unsupported (NOT syntax errors)
use constant STATUS_SYNTAX_ERROR               => 21;
use constant STATUS_SEMANTIC_ERROR             => 22;   # Errors caused by the randomness of the test, e.g. dropping a non-existing table
use constant STATUS_TRANSACTION_ERROR          => 23;   # Lock wait timeouts, deadlocks, duplicate keys, etc.

use constant STATUS_TEST_FAILURE               => 24;   # Boundary between genuine errors and false positives due to randomness

use constant STATUS_SELECT_REDUCTION           => 5;    # A coefficient to substract from error codes in order to make them non-fatal

use constant STATUS_REQUIREMENT_UNMET_SELECT   => 25;
use constant STATUS_ERROR_MISMATCH_SELECT      => 26;   # A SELECT query caused those errors, however the test can continue
use constant STATUS_LENGTH_MISMATCH_SELECT     => 27;   # since the database has not been modified
use constant STATUS_CONTENT_MISMATCH_SELECT    => 28;   #
use constant STATUS_SCHEMA_MISMATCH            => 29;   #
use constant STATUS_REQUIREMENT_UNMET          => 30;
use constant STATUS_ERROR_MISMATCH             => 31;   # A DML statement caused those errors, and the test can not continue
use constant STATUS_LENGTH_MISMATCH            => 32;   # because the databases are in an unknown inconsistent state
use constant STATUS_CONTENT_MISMATCH           => 33;   #

use constant STATUS_CUSTOM_OUTCOME             => 36;   # Used for things such as signaling an EXPLAIN hit from the ExplainMatch Validator

use constant STATUS_POSSIBLE_FAILURE           => 60;

use constant STATUS_SERVER_SHUTDOWN_FAILURE    => 90;

# Higher-priority errors --------------------------------------------------------------------------#

# STATUS_CRITICAL_FAILURE(100) is the Boundary between critical and non-critical errors.
# Setting STATUS_CRITICAL_FAILURE in some RQG component
# - "means"
#   The situation met is critical but the component does not feel capable to give some sufficient
#   detailed or sufficient reliable status like for example STATUS_SERVER_CRASHED.
#   Example: Getting no connection does not imply that the server must have crashed.
# - should lead to calling other RQG components which might "feel" more capable to deliver some
#   more detailed and reliable status.
#   Possible outcomes:
#   - downsizing of the status to non critical --> in most cases the test goes on
#   - change to some other critical status or not --> in nearly most cases the test aborts
use constant STATUS_CRITICAL_FAILURE           => 100;


use constant STATUS_SERVER_CRASHED             => 101;
use constant STATUS_SERVER_KILLED              => 102;   # Willfull killing of the server, will not be reported as a crash
                                                         # Example: Reporter CrashRecovery

use constant STATUS_REPLICATION_FAILURE        => 103;
use constant STATUS_UPGRADE_FAILURE            => 104;
use constant STATUS_RECOVERY_FAILURE           => 105;
use constant STATUS_DATABASE_CORRUPTION        => 106;
use constant STATUS_SERVER_DEADLOCKED          => 107;
use constant STATUS_BACKUP_FAILURE             => 108;
use constant STATUS_VALGRIND_FAILURE           => 109;
use constant STATUS_ENVIRONMENT_FAILURE        => 110; # A failure in the environment or the grammar file
use constant STATUS_ALARM                      => 111; # A module, e.g. a Reporter, raises an alarm with critical severity

use constant STATUS_RSS_DOUBLED                => 120; # Reporter ServerMem raises an alarm with critical severity
                                                       # The existence and also the name of this status is not yet decided.
                                                       # So it might get renamed or disappear in some later RQG version.

# Use STATUS_CONFIGURATION_ERROR in case the configuration is obvious wrong.
# Please do not use it in case the situation became bad during test runtime.
use constant STATUS_CONFIGURATION_ERROR        => 199;

# Use STATUS_INTERNAL_ERROR in case you assume that RQG code is obvious wrong like a sub gets
# called with less or more parameters than needed or a value is undef though it shouldn't.
# Please do not use it in case some configuration is obvious wrong.
# This was in history '1'.
use constant STATUS_INTERNAL_ERROR             => 200;

use constant STATUS_PERL_FAILURE               => 255;  # Perl died for some reason

use constant ORACLE_ISSUE_STILL_REPEATABLE     => 2;
use constant ORACLE_ISSUE_NO_LONGER_REPEATABLE => 3;
use constant ORACLE_ISSUE_STATUS_UNKNOWN       => 4;

use constant DB_UNKNOWN                        => 0;
use constant DB_DUMMY                          => 1;
use constant DB_MYSQL                          => 2;
use constant DB_POSTGRES                       => 3;
use constant DB_JAVADB                         => 4;
use constant DB_DRIZZLE                        => 5;

# Original code
# use constant DEFAULT_MTR_BUILD_THREAD          => 930; ## Legacy...
# On extreme testing boxes (temporary more than 200 RQG runner) ports > 32000 might get computed.
# And they tend to be sometimes already occupied by whatever.
# The critical ones start around build_thread > ~ 1140
use constant DEFAULT_MTR_BUILD_THREAD          => 730;

#
# The part below deals with constant value to constant name conversions
#


my %text2value;

sub BEGIN {

   # What we do here is open the Constants.pm file and parse the 'use constant' lines from it
   # The regexp is faily hairy in order to be more permissive.

   open (CONSTFILE, __FILE__) or croak "Unable to read constants from ".__FILE__;
   read(CONSTFILE, my $constants_text, -s __FILE__);
   %text2value = $constants_text =~ m{^\s*use\s+constant\s+([A-Z_0-9]*?)\s*=>\s*(\d+)\s*;}mgio;
}

sub constant2text {
   my ($constant_value, $prefix) = @_;

   foreach my $constant_text (keys %text2value) {
      return $constant_text if $text2value{$constant_text} == $constant_value && $constant_text =~ m{^$prefix}si;
   }
   Carp::cluck "Unable to obtain constant text for constant_value = $constant_value; prefix = $prefix";
   return undef;
}

sub status2text {
   return constant2text($_[0], 'STATUS_');
}

1;
