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
    # This is a variant of "before execution" tracing. TO BE IMPLEMENTED
    # CREATE PROCEDURE ....
    # END §
    # Some tool extracting or running such a file could interpret the '§' as statement end.
    # Use case:
    # Try to replay problems in MTR or some other tool.
    # And if that works well than simplify the amount of SQL.
    # The difference to SQLTRACE_SIMPLE is that the SQL trace does not need to be extracted
    # from some RQG log.

# use constant SQL_TRACE_INIT                  => 'Init';

use constant SQLTRACE_ALLOWED_VALUE_LIST => [
       SQLTRACE_NONE,
       SQLTRACE_SIMPLE,
       SQLTRACE_MARKERRORS,
       SQLTRACE_CONCURRENCY,
       SQLTRACE_FILE
];

use GenTest;
use GenTest::Constants;

# my $sqltrace = SQL_TRACE_INIT;
my $sqltrace;
my $sqltrace_file;
my $file_handle;
sub check_and_set_sqltracing {
    ($sqltrace, my $workdir) = @_;

use utf8;

    my $status = STATUS_OK;
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
        Auxiliary::print_list("The values supported for 'sqltrace' are :" ,
                              SQLTRACE_ALLOWED_VALUE_LIST);
        $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: " . Auxiliary::build_wrs($status));
        return $status;
    }
    say("INFO: sqltrace_mode is set to : '$sqltrace'.");
    if ($sqltrace eq SQLTRACE_FILE) {
        $sqltrace_file = $workdir . "/rqg.trc";
        $result = Auxiliary::make_file ($sqltrace_file, "# " . isoTimestamp());
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
    # Carp::confess("INTERNAL_ERROR: \$sqltrace is not set.") if SQL_TRACE_INIT eq $sqltrace;
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
    # Carp::confess("INTERNAL_ERROR: \$sqltrace is not set.") if SQL_TRACE_INIT eq $sqltrace;
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


1;
