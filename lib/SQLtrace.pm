#  Copyright (c) 2021 MariaDB Corporation Ab.
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; version 2 of the License.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301  USA */
#

package SQLtrace;

use strict;

# Some hints:
# 1. The SQL tracing happens in RQG. This is the client side.
#    Any transmission of data between client and server could suffer from reasons outside of the
#    responsibilities of the client and the server. And that affects the trace got.
#    Example "before execution" tracing:
#       There is at least for no guarantee that the server ever "saw" that statement.
#    Example "post execution" tracing:
#       It is quite unlikely that a result for a query causing a crash will be sent by the server.
#       The RQG machinery might detect a server crash so fast and react with killing the clients
#       so that some entry like "[9298] UPDATE ...  ; COMMIT;" gets written by the client.
# 2. Certain activities, example: InnoDB Purge, are triggered by a crowd SQL commands where the
#    execution and the result was already sent to the client.
#    In short: There might be no direct connection between one SQL and the crash.
#    We might have SQL commands where the result sent back to the client only acknowledges that
#    the order was received and maybe some initial check passed.
#    shutdown ?
#    INSERT DELAYED ?
#    The CREATION of EVENTs gets traced but not when this EVENT becomes active.
#    In short: The main activity happens asynchronous and after reporting success to the client.
# 3. Neither "before execution" nor "post execution" nor "before+post execution" tracing give
#    sufficient information for 100% correct imaging what happened inside of the server even if
#    asynchronous activity would not exist at all.
#    Just a view examples for the most perfect variant "before+post execution"
#    - The sequence
#         entry m:   REAP: ... /* ... Thread1 ...*/
#         entry m+1: REAP: ... /* ... Thread2 ...*/
#      does not guarantee that the server finished the execution of the query for Thread1 first.
#      The OS scheduling has here some inpact.
#    - The sequence
#         entry m:   SEND: ... /* ... Thread1 ...*/
#         entry m+1: SEND: ... /* ... Thread2 ...*/
#         no further entries where a result of one of these two queries
#         server crash
#      cannot help to calculate which of these two queries caused the crash if at all.
# 4. Certain RQG components like many Reporters do not write SQL trace. I am improving that.
#
# So the main point is to pick the right kind of trace for some already exsiting task.
#

use constant SQLTRACE_NONE                   => 'None';
    # No SQL tracing
use constant SQLTRACE_SIMPLE                 => 'Simple';
    # This is a variant of "before execution" tracing.
    # Print (only when sending to the server) something like
    # INSERT /*! IGNORE */ INTO PP_B VALUES
    # ('19741212122231.044582', 'a', 'u', 'e', '05:40:15.000638');
    #
    # Use case:
    # Try to replay a problem in MTR or some other tool.
    # And if that works well than simplify the amount of SQL.

use constant SQLTRACE_MARKERRORS             => 'MarkErrors';
    # This is a variant of "post execution" tracing.
    # Print (only when receiving the result from the server) something like
    # [9298] SELECT 1 /* E_R Thread1 QNO 10 CON_ID 16 */ ;
    # [9298] [sqltrace] ERROR 1146: SELECT * FROM not_exists /* E_R Thread1 QNO 11 CON_ID 16 */ ;
    #
    # Use case:
    # Try to replay a problem in MTR or some other tool.
    # And if that works well than simplify the amount of SQL.
    # The statements marked as failing are frequent not required for a replay.
    # Hence some replay attempt without these statements could give a sppedup in simplification.

use constant SQLTRACE_CONCURRENCY            => 'Concurrency';
    # This is a variant of "before+post execution" tracing.
    # Print (when sending to the server and receiving the result from the server) something like
    # SEND == Before execution entry, REAP == Post execution entry
    # SEND: [9517] SELECT * FROM not_exists /* E_R Thread8 QNO 17 CON_ID 16 */ ;
    # SEND: [9488] SELECT 1 /* E_R Thread1 QNO 17 CON_ID 9 */ ;
    # REAP: [9517] ERROR 1146: SELECT * FROM not_exists /* E_R Thread8 QNO 17 CON_ID 16 */ ;
    #
    # Use cases:
    # - Hit a problem in some concurrency scenario.
    #   Seeing the overlapping of statement executions might help to find the reason.
    # - Try to replay a problem in MTR or some other tool ...

use constant SQLTRACE_FILE                   => 'File';
    # Idea
    ######
    # This is a variant of "before execution" tracing.
    # CREATE PROCEDURE ....
    # END §
    # Some tool extracting or running such a file could interpret the '§' as statement end.
    # Use case:
    # Try to replay problems in MTR or some other tool.
    # And if that works well than simplify the amount of SQL.
    # The difference to SQLTRACE_SIMPLE is that the SQL trace does not need to be extracted
    # from some RQG log.

use constant SQLTRACE_ALLOWED_VALUE_LIST => [
       SQLTRACE_NONE,
       SQLTRACE_SIMPLE,
       SQLTRACE_MARKERRORS,
       SQLTRACE_CONCURRENCY,
       SQLTRACE_FILE
];

use GenTest;
use GenTest::Constants;

use utf8;
my $sqltrace;
sub check_sqltracing {
# To be used by rqg_batch.pl.
# Return in case of
# - success    The value for sqltracing (-> SQL_TRACE_*)
# - failure    undef
    ($sqltrace) = @_;

    if (not defined $sqltrace) {
        $sqltrace = SQLTRACE_NONE;
        say("INFO: sqltrace was not defined and therefore set to '" . $sqltrace . "'.");
    }
    if ($sqltrace eq '') {
        $sqltrace = SQLTRACE_SIMPLE;
    }
    my $result = Auxiliary::check_value_supported ('sqltrace', SQLTRACE_ALLOWED_VALUE_LIST,
                                                   $sqltrace);
    if ($result != STATUS_OK) {
        help();
        return undef;
    } else {
        return $sqltrace;
    }
}

my $sqltrace_file;
my $file_handle;
sub check_and_set_sqltracing {
# To be used by rqg.pl. Only that runs finally sqltracing.
    ($sqltrace, my $workdir) = @_;

    my $status = STATUS_OK;
    $sqltrace = check_sqltracing($sqltrace);
    if (not defined $sqltrace) {
        $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: " . Auxiliary::build_wrs($status));
        return $status;
    }
    # FIXME:
    # Does this work well for more than one session regarding
    # - (unsorted) content == No written statement missing in file
    # - sorting ~ roughly
    if ($sqltrace eq SQLTRACE_FILE) {
        $sqltrace_file = $workdir . "/rqg.trc";
        my $result = Auxiliary::make_file ($sqltrace_file, "# " . isoTimestamp());
        if ($result != STATUS_OK) {
            $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: " . Auxiliary::build_wrs($status));
            return $status;
        } else {
            say("INFO: SQL trace file '$sqltrace_file' created.");
            if (not open ($file_handle, '>>', $sqltrace_file)) {
                say("ERROR: Open file '>>$sqltrace_file' failed : $!");
                $status = STATUS_ENVIRONMENT_FAILURE;
                say("ERROR: " . Auxiliary::build_wrs($status));
                return $status;
            }
            binmode $file_handle, ':utf8';
        }
    }
    return $status;
}

my $sqltrace_query;
sub sqltrace_before_execution {
    ($sqltrace_query) = @_;
    Carp::confess("INTERNAL_ERROR: \$sqltrace_query is undef") if not defined $sqltrace_query;
    Carp::confess("INTERNAL_ERROR: \$sqltrace is not set.")    if not defined $sqltrace;
    if      (SQLTRACE_NONE eq $sqltrace) {
        return STATUS_OK;
    } elsif (SQLTRACE_SIMPLE eq $sqltrace) {
        print STDOUT "$sqltrace_query;\n";
    } elsif (SQLTRACE_MARKERRORS eq $sqltrace) {
        return STATUS_OK;
    } elsif (SQLTRACE_CONCURRENCY eq $sqltrace) {
        print STDOUT "SEND: [$$] $sqltrace_query;\n";
    } elsif (SQLTRACE_FILE eq $sqltrace) {
        print $file_handle "$sqltrace_query;\n";
    } else {
        say("INTERNAL_ERROR: Handling of \$sqltrace $sqltrace is not implemented.");
        Carp::confess("mleich: Fix that error");
    }
    # say("DEBUG: sqltrace $sqltrace , query ->" . $sqltrace_query . "<-");
    return STATUS_OK;
}

sub sqltrace_after_execution {
    my ($error) = @_;
    Carp::confess("INTERNAL_ERROR: \$sqltrace_query is undef") if not defined $sqltrace_query;
    Carp::confess("INTERNAL_ERROR: \$sqltrace is not set.")    if not defined $sqltrace;
    if      (SQLTRACE_NONE eq $sqltrace) {
    } elsif (SQLTRACE_SIMPLE eq $sqltrace) {
    } elsif (SQLTRACE_FILE eq $sqltrace) {
    } elsif (SQLTRACE_MARKERRORS eq $sqltrace) {
        if (defined $error) {
            # Mark invalid queries in the trace by prefixing each line.
            # We need to prefix all lines of multi-line statements also.
            $sqltrace_query =~ s/\n/\n# [sqltrace]    /g;
            print STDOUT "# [$$] [sqltrace] ERROR " . $error . ": $sqltrace_query;\n";
        } else {
            print STDOUT "[$$] $sqltrace_query;\n";
        }
    } elsif (SQLTRACE_CONCURRENCY eq $sqltrace) {
        if (defined $error) {
            # Mark invalid queries in the trace by prefixing each line.
            # We need to prefix all lines of multi-line statements also.
            $sqltrace_query =~ s/\n/\n# [sqltrace]    /g;
            print STDOUT "REAP: [$$] ERROR " . $error . ": $sqltrace_query;\n";
        } else {
            print STDOUT "REAP: [$$] $sqltrace_query;\n";
        }
    } else {
        say("INTERNAL_ERROR: Handling of \$sqltrace $sqltrace is not implemented.");
        Carp::confess("mleich: Fix that error");
    }
    $sqltrace_query = undef;
    return STATUS_OK;
}

sub help {
    print("\nRQG option 'sqltrace'\n\n" .
          "Client side tracing of SQL statements.\n"                                                                               .
          "    The threads processing the YY grammar should trace roughly perfect.\n"                                              .
          "    Some RQG components (DBServer, Gendata, Reporter, Validator) do not print all SQL statements issued.\n"             .
          "    None of the tracing variants below is capable to show the real order of SQL processing within the DB server!\n\n"   .
          "Supported values\n"                                                                                                     .
          "None    (default)\n"                                                                                                    .
          "    No tracing of SQL.\n"                                                                                               .
          "    --sqltrace=None and ./rqg.pl <nothing with --sqltrace> have the same effect.\n"                                     .
          "Simple\n"                                                                                                               .
          "    --sqltrace=Simple and ./rqg.pl --sqltrace<nothing assigned> have the same effect.\n"                                .
          "    Write the trace entries into the RQG log.\n"                                                                        .
          "    Make the trace entry before the statement is sent to the DB server.\n"                                              .
          "    Example trace entry:\n"                                                                                             .
          "    SELECT 1 /* E_R Thread1 QNO 17 CON_ID 9 */ ;\n"                                                                     .
          "MarkErrors\n"                                                                                                           .
          "    Write the trace entries into the RQG log.\n"                                                                        .
          "    Make the trace entry when receiving the response of the DB server.\n"                                               .
          "    Example trace entries:\n"                                                                                           .
          "    [9298] SELECT * FROM t1 /* E_R Thread1 QNO 11 CON_ID 16 */ ;\n"                                                     .
          "    # [9298] [sqltrace] ERROR 1146: SELECT * FROM not_exists /* E_R Thread1 QNO 11 CON_ID 16 */ ;\n"                    .
          "Concurrency\n"                                                                                                          .
          "    Write the trace entries into the RQG log.\n"                                                                        .
          "    Print when sending SQL to the DB server and receiving response from the server.\n"                                  .
          "    Example trace entries:\n"                                                                                           .
          "        SEND == Before execution entry, REAP == Post execution entry\n"                                                 .
          "    SEND: [9517] SELECT * FROM not_exists /* E_R Thread8 QNO 17 CON_ID 16 */ ;\n"                                       .
          "    SEND: [9488] SELECT 1 /* E_R Thread1 QNO 17 CON_ID 9 */ ;\n"                                                        .
          "    REAP: [9517] ERROR 1146: SELECT * FROM not_exists /* E_R Thread8 QNO 17 CON_ID 16 */ ;\n"                           .
          "File(experimental)\n"                                                                                                                 .
          "    Write the trace entries into <workdir of RQG run>/rqg.trc\n"                                                        .
          "    Make the trace entry before the statement is sent to the DB server.\n"                                              .
          "    Example trace entry:\n"                                                                                             .
          "    SELECT 1 /* E_R Thread1 QNO 17 CON_ID 9 */ ;\n\n"                                                                   .
          "Details and hints:\n"                                                                                                   .
          "- The '[9488]' above shows the id of the process who was issuing the SQL statement.\n"                                  .
          "- The comment '/* E_R Thread1 QNO 17 CON_ID 9 */' within the SQL statements gets added by Executor.pm or Reporters\n"   .
          "  Value after -- meaning\n"                                                                                             .
          "     E_R         Role/Task of that executor like\n"                                                                     .
          "                 'Thread1'        (YY grammar processing in GenTest)\n"                                                 .
          "                 'CrashRecovery1' (Reporter)\n"                                                                         .
          "     QNO         Number of the query (only for Threads roughly accurate)\n"                                             .
          "     CON_ID      Connection id in the processlist of that DB server\n\n"
    );
}

1;
