# Copyright (c) 2008, 2012 Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2018, 2022 MariaDB Coporation Ab.
# Copyright (c) 2023, 2024 MariaDB plc
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

# Attention:
# The term 'Deadlock' is partially incorrect.
# The current reporter is
# - also capable to catch
#   - unfair scheduling within the server affecting certain sessions
#   - server too slow up till maybe never responding
#   - Deadlocks at whatever place (SQL, storage engine, ??)
# - partially not that reliable
#   - $query_lifetime_threshold does not depend sufficient or at all on
#        server timeouts , required work for some SQL (huge table or ...) , general load on box
#   - $reporter_query_threshold does not depend ... on general load on box ...
#   - $actual_test_duration_exceed does not depend on $query_lifetime_threshold per pure math.
#   - STALLED_QUERY_COUNT_THRESHOLD is some guess and does not take into account if these
#     suspicious queries have conflicting needs etc.
#   - maybe network problems
# and will report in most of these cases STATUS_SERVER_DEADLOCKED.
#
# Please read the comments around the constant $query_lifetime_threshold.
#
# Rule of thumb for coding:
# Exit (This is the exit of the periodic reporting process running maybe several reporters.)
# - (banal) only if having met a serious bad state
# - immediate after having initiated the intentional server crash needed for debugging.
# Do not initiate the crash and just return STATUS_SERVER_DEADLOCKED or similar because it seems
# that caused by other processes etc. the RQG run might end with STATUS_SERVER_CRASHED,
# STATUS_ALARM or STATUS_ENVIRONMENT_FAILURE.
#
# Observation 2020-01 (30s $connect_timeout_threshold at that point of time)
# In case $connect_timeout_threshold gets exceeded than something like
#    ERROR: Reporter 'Deadlock': The connect attempt to dsn .... failed:
#    Lost connection to MySQL server at 'waiting for initial communication packet',
#    system error: 110 after 30.0861439704895 s.
# shows up.
# The reason was finally not known
# - too much overloaded DB server/testing box
# or
# - server freeze ?
#

package GenTest_e::Reporter::Deadlock;

require Exporter;
@ISA = qw(GenTest_e::Reporter);

use strict;
use GenTest_e;
use GenTest_e::Constants;
use GenTest_e::Result;
use GenTest_e::Reporter;
use GenTest_e::Executor::MySQL;
use Runtime;

use DBI;
use Data::Dumper;
use POSIX;

my $script_debug = 0;

# Example of a SHOW PROCESSLIST result set.
# 0   1     2          3     4        5     6      7                 8
# Id  User  Host       db    Command  Time  State  Info              Progress
#  4  root  localhost  test  Query       0   Init  SHOW PROCESSLIST  0.000

use constant PROCESSLIST_PROCESS_ID          => 0;
use constant PROCESSLIST_PROCESS_COMMAND     => 4;
use constant PROCESSLIST_PROCESS_TIME        => 5;
use constant PROCESSLIST_PROCESS_STATE       => 6;
use constant PROCESSLIST_PROCESS_INFO        => 7;

# The time, in seconds, we will wait for a connect before we declare the server hanged.
use constant CONNECT_TIMEOUT_THRESHOLD       => 60;   # Seconds

# Minimum lifetime of a query issued by some RQG worker thread/Validators before it is
# considered suspicious.
# Some hints for avoiding to get false alarms.
# 1. It needs to be guranteed that SQL statements executed on some maybe overloaded testing box
#    do not exceed $query_lifetime_threshold.
#    This could be done by either
#    - making $query_lifetime_threshold(here) sufficient big
#    or
#    - using the reporter QueryTimeout and assigning some fitting value to the RQG run like
#      --querytimeout=<value>
#      ==> $query_lifetime_threshold(here) > <value assigned to querytimeout> + OVERLOAD_ADD
#    or
#    - assigning the GLOBAL/SESSION system variable "max_statement_time"
# 2. When meeting a high fraction of RQG runs failing with STATUS_SERVER_DEADLOCKED try first to
#    - reduce the load on the testiing box
#    or
#    - increase $query_lifetime_threshold
#    in order to see if the fraction of fails with STATUS_SERVER_DEADLOCKED goes drastic down.
# 3. The default value of 180 for $query_lifetime_threshold might look unfortunate small but
#    its quite good for RQG test simplification.
#

# QUERY_LIFETIME_THRESHOLD (to some extend misleading name)
# ---------------------------------------------------------
# QUERY_LIFETIME_THRESHOLD is used for the computation of query_lifetime_threshold.
# In case the value for PROCESSLIST.time exceeds the value query_lifetime_threshold than some
# query is declared to be suspicious.
# Running a query is working along some sequence of steps. In the PROCESSLIST such a step is
# called 'state'. PROCESSLIST.time just tells how long some thread is in the current state.
# FIXME:
# QUERY_LIFETIME_THRESHOLD should be < QueryTimeout(if used at all) + ...
#
use constant QUERY_LIFETIME_THRESHOLD        => 300;  # Seconds

# Number of suspicious queries required before a deadlock is declared.
# use constant STALLED_QUERY_COUNT_THRESHOLD   => 5;
use constant STALLED_QUERY_COUNT_THRESHOLD   => 2;

# Number of times the actual test duration is allowed to exceed the desired one.
# use constant ACTUAL_TEST_DURATION_MULTIPLIER => 2;

# Number of seconds the actual test duration is allowed to exceed the desired one.
use constant ACTUAL_TEST_DURATION_EXCEED     => 600;  # Seconds

# The time, in seconds, we will wait for some query issued by the reporter (i.e. SHOW PROCESSLIST)
# before we declare the server hanged.
use constant REPORTER_QUERY_THRESHOLD        => 90;   # Seconds

# FIXME: Add a dependency from the number of threads.
# The time, in seconds, we will wait in addition for connect or a some query response in order
# to compensate for some heavy overloaded box and maybe unfortunate OS scheduling before we declare
# the server hanged.
use constant OVERLOAD_ADD                    => 30;   # Seconds

# exists $ENV{'RUNNING_UNDER_RR'}
# if (defined $reporter->properties->rr) {

my $who_am_i = "Reporter 'Deadlock':";
my $query_lifetime_threshold;
my $actual_test_duration_exceed;
my $reporter_query_threshold;
my $connect_timeout_threshold;
my $mdl_timeout_threshold1;
my $mdl_timeout_threshold3;
my $with_asan = 0;

my $reporter;

sub init {
    $reporter = shift;
    $query_lifetime_threshold    = Runtime::get_runtime_factor() * QUERY_LIFETIME_THRESHOLD;
    $actual_test_duration_exceed = Runtime::get_runtime_factor() * ACTUAL_TEST_DURATION_EXCEED;
    $reporter_query_threshold    = Runtime::get_runtime_factor() * REPORTER_QUERY_THRESHOLD;
    $connect_timeout_threshold   = Runtime::get_runtime_factor() * CONNECT_TIMEOUT_THRESHOLD;
    my $mdl_timeout = $reporter->serverVariable('lock_wait_timeout');
    # Observation 2023-11 on 10.6:
    # lock_wait_timeout = 15, processlist entries with 'Waiting for table metadata lock',
    # the query uses one table, time values up to 106s(no significant diff between with/without rr).
    # No obvious defects.
    # Assume waiting for MDL lock on one table.
    $mdl_timeout_threshold1   = 100 + $mdl_timeout;
    # Assume waiting for MDL locks on three tables.
    $mdl_timeout_threshold3   = 100 + 3 * $mdl_timeout;
    my $have_sanitizer        = $reporter->serverVariable('have_sanitizer');
    if (defined $have_sanitizer and "ASAN" eq $have_sanitizer) {
        $with_asan = 1;
    }
}

sub monitor {
    my $reporter = shift;

    say("DEBUG: $who_am_i Start a monitoring round") if $script_debug;

    if (STATUS_OK != server_dead($reporter)) {
        exit STATUS_SERVER_CRASHED;
    }
    $reporter->init if not defined $reporter_query_threshold;
    # 2019-09 Observation (mleich)
    # The simplifier computed finally some adapted durations of 5s.
    # The reporter 'Deadlock.pm' kicked in on his third run and declared STATUS_SERVER_DEADLOCKED
    # because $actual_test_duration > ACTUAL_TEST_DURATION_MULTIPLIER (2) * 5s.
    # But all worker threads had already disconnected/given up.
    # In case all worker threads have already disconnected not applying the criterion might be
    # the solution.
    # Problems:
    # a) Reporters do not get the *actual* number of worker threads "told".
    # b) Looking into the processlist means making a connect and running SQL.
    #    And that is too vulnerable and this first check would be no more a rugged safety net.
    #
    # Incomplete list of states where a first simple check should not kick in
    # 1. Certain reporters were already executed before 'Deadlock*" gets executed first time.
    #    This timespan before lasted > n * duration (n >= 1).
    # 2. Worker thread n needs a new query. Caused by the fact that duration is not already
    #    exceeded it asks for a new one, gets and executes it.
    #    Per misfortune its a long running fat join or a SQL followed by validators which last
    #    in sum long and all that is not intercepted by a query timeout or similar.
    #
    # So I have decided to use some $actual_test_duration_exceed instead of the
    # ACTUAL_TEST_DURATION_MULTIPLIER.
    #

    my $actual_test_duration = time() - $reporter->testStart();
    if ($actual_test_duration > $reporter->testDuration()) {
        if (osWindows()) {
            return $reporter->monitor_threaded(1);
        } else {
            return $reporter->monitor_nonthreaded(1);
        }
    } else {
        if (osWindows()) {
            return $reporter->monitor_threaded(0);
        } else {
            return $reporter->monitor_nonthreaded(0);
        }
    }

    if ($actual_test_duration > $actual_test_duration_exceed + $reporter->testDuration()) {
        say("ERROR: $who_am_i Actual test duration($actual_test_duration" . "s) is more than "     .
            "$actual_test_duration_exceed(" . $actual_test_duration_exceed  . "s) + the desired "  .
            "duration (" . $reporter->testDuration() . "s). Will kill the server so that we get "  .
            "a core and exit with STATUS_SERVER_DEADLOCKED.");
        $reporter->kill_with_core;
        exit STATUS_SERVER_DEADLOCKED;
    }

}

my $executor;
sub monitor_nonthreaded {
    # Version for OS != WIN
    my $reporter = shift;
    my $print    = shift;
    my $dsn      = $reporter->dsn();

    # We connect on every run in order to be able to use the mysql_connect_timeout to detect very
    # debilitating deadlocks.

    # For testing
    # system("killall -11 mariadbd mysqld"); # return STATUS_SERVER_CRASHED

    # We directly call exit() in the handler because attempting to catch and handle the signal in
    # a more civilized manner does not work for some reason -- the read() call from the server gets
    # restarted instead.

    # Attention:
    # DBServer_e::MySQL::MySQL::server_is_operable cannot replace functionality of the current sub
    # because the criterions for declaring a Deadlock/Freeze differ.

    my $exit_msg =      '';
    my $alarm_timeout = 0;
    my $query =         '<initialize some executor>';

    sigaction SIGALRM, new POSIX::SigAction sub {
        # Concept:
        # 1. Check first if the server process is gone.
        # 2. Set the error_exit_message for deadlock/freeze before setting the alarm.
        if (STATUS_OK != server_dead($reporter)) {
            exit STATUS_SERVER_CRASHED;
        }
        my $status = STATUS_SERVER_DEADLOCKED;
        say("ERROR: $who_am_i ALRM1 $exit_msg " .
            Basics::exit_status_text($status) . " later.");
        $reporter->kill_with_core;
        exit $status;
    } or die "ERROR: $who_am_i Error setting SIGALRM handler: $!\n";

    say("DEBUG: $who_am_i Try to get a connection") if $script_debug;
    $executor =  GenTest_e::Executor->newFromDSN($dsn);
    $executor->setId(1);
    $executor->setRole("Deadlock");
    $executor->setTask(GenTest_e::Executor::EXECUTOR_TASK_REPORTER);

    $alarm_timeout =    $connect_timeout_threshold + OVERLOAD_ADD;
    $exit_msg      =    "Got no connect to server within " . $alarm_timeout . "s. ";
    my $connect_start = time();
    alarm ($alarm_timeout);

    # This will perform the connect and set max_statement_time = 0.
    my $status = $executor->init();

    alarm (0);
    $status = give_up($status, $query);
    return $status if STATUS_OK != $status;

    my $result;

    $alarm_timeout = $reporter_query_threshold + OVERLOAD_ADD;
    $exit_msg = "Got no response from server to query '$query' within " . $alarm_timeout . "s.";

    # For testing: Syntax error -> STATUS_UNKNOWN_ERROR
    # $query    = "SHOW FULL OMO";          # Syntax error -> STATUS_SYNTAX_ERROR(21)
    # system("killall -9 mariadbd mysqld; sleep 1"); # Dead server  -> STATUS_SERVER_CRASHED(101)
    #
    # alarm (3);                            # Exceed $alarm_timeout -> STATUS_SERVER_DEADLOCKED
    # $query = "SELECT SLEEP(4)";

    if (inspect_processlist($print)) {
        my $status = STATUS_SERVER_DEADLOCKED;
        say("ERROR: $who_am_i Declaring hang at DSN $dsn. " . Basics::exit_status_text($status) .
            " later.");

        foreach $query (
            "SHOW ENGINE INNODB STATUS",
            "SHOW OPEN TABLES",          # Once disabled due to bug #46433
            "SELECT THREAD_ID, LOCK_MODE, LOCK_DURATION, LOCK_TYPE, TABLE_NAME " .
            "FROM information_schema.METADATA_LOCK_INFO " .
            "WHERE TABLE_SCHEMA != 'information_schema'" , ) {
            alarm ($alarm_timeout);
            $result = $executor->execute($query);
            alarm (0);
            $status = $result->status;
            give_up($status, $query);

            my $result_set = $result->data;

            say("INFO: $who_am_i --- " . $query . " ---");
            my @row_refs = @{$result_set};
            foreach my $row_ref (@row_refs) {
                my @row = @{$row_ref};
                my $sentence = "";
                foreach my $element (@row) {
                    $element = "undef" if not defined $element;
                    $sentence .= "->" . $element . "<-";
                }
                say("INFO: $who_am_i " . $sentence );
            }
        }
        say("INFO: $who_am_i ----------------------");
        if (not defined Runtime::get_rr()) {
            my ($command, $output);
            $command = "gdb --batch --pid=" . $reporter->serverInfo('pid') .
                       " --se=" . $reporter->serverInfo('binary') .
                       " --command=" . Local::get_rqg_home . "/backtrace-all.gdb";
            $output = `$command`;
            say("$output");
            # The backtrace above gives sometimes not sufficient information.
            # So generate some core in addition.
            # Observation 2023-11 when testing on
            # - asan builds:
            #   RQG batch aborted the test battery because of filesystem nearly full.
            #   One of the core files was 130 GB.
            # - debug builds:
            #   Time required for
            #   - making the backtrace above ~120s
            #   - generating the core below  ~130s
            if (not $with_asan) {
              $command = "gcore -o " . $reporter->serverVariable('datadir') .
                         "/gcore "   . $reporter->serverInfo('pid');
              $output = `$command`;
              say("$output");
            }
            inspect_processlist(1);
        }
        $executor->disconnect;

        $reporter->kill_with_core;
        exit STATUS_SERVER_DEADLOCKED;
    } else {
        $executor->disconnect;
        say("INFO: $who_am_i Nothing obvious suspicious found.");
        return STATUS_OK;
    }
} # sub monitor_nonthreaded

sub monitor_threaded {
    # Version for OS == WIN
    my $reporter = shift;
    my $print    = shift;

    require threads;

#
# We create two threads:
# * alarm_thread keeps a timeout so that we do not hang forever
# * dbh_thread attempts to connect to the database and thus can hang forever because
# there are no network-level timeouts in DBD::mysql
#

    my $alarm_thread = threads->create( \&alarm_thread );
    my $dbh_thread = threads->create ( \&dbh_thread, $reporter );

    my $status;

    # We repeatedly check if either thread has terminated, and if so, reap its exit status

    while (1) {
        foreach my $thread ($alarm_thread, $dbh_thread) {
            $status = $thread->join() if defined $thread && $thread->is_joinable();
        }
        last if defined $status;
        sleep(1);
    }

    # And then we kill the remaining thread.

    foreach my $thread ($alarm_thread, $dbh_thread) {
        next if !$thread->is_running();
        # Windows hangs when joining killed threads
        if (osWindows()) {
            $thread->kill('SIGKILL');
        } else {
            $thread->kill('SIGKILL')->join();
        }
     }

    return ($status);
}

sub alarm_thread {
    local $SIG{KILL} = sub { threads->exit() };

    # We sleep in small increments so that signals can get delivered in the meantime

    foreach my $i (1..$connect_timeout_threshold) {
        sleep(1);
    };

    say("ERROR: $who_am_i Entire-server deadlock detected.");
    return(STATUS_SERVER_DEADLOCKED);
}

sub dbh_thread {
    local $SIG{KILL} = sub { threads->exit() };
    my $reporter = shift;
    my $dsn = $reporter->dsn();

    # We connect on every run in order to be able to use a timeout to detect very
    # debilitating deadlocks.
    my $dbh = DBI->connect($dsn, undef, undef,
                           { mysql_connect_timeout => $connect_timeout_threshold * 2,
                             PrintError => 1, RaiseError => 0 });

    if (defined GenTest_e::Executor::MySQL::errorType($DBI::err)) {
        return GenTest_e::Executor::MySQL::errorType($DBI::err);
    } elsif (not defined $dbh) {
        return STATUS_UNKNOWN_ERROR;
    }

    my $processlist = $dbh->selectall_arrayref("SHOW FULL PROCESSLIST");
    return GenTest_e::Executor::MySQL::errorType($DBI::err) if not defined $processlist;

    my $suspicious = 0;

    foreach my $process (@$processlist) {
        if (
            ($process->[PROCESSLIST_PROCESS_INFO] ne '') &&
            ($process->[PROCESSLIST_PROCESS_TIME] > $query_lifetime_threshold)
        ) {
            $suspicious++;
        }
    }

    if ($suspicious >= STALLED_QUERY_COUNT_THRESHOLD) {
        say("ERROR: $who_am_i $suspicious suspicious queries detected, declaring deadlock at DSN $dsn.");
        print Dumper $processlist;
        return STATUS_SERVER_DEADLOCKED;
    } else {
        return STATUS_OK;
    }
} # sub dbh_thread

sub kill_with_core {
    if (defined $ENV{RQG_CALLBACK}) {
        # (mleich1): Sorry, but I do not know if this works.
        return callbackReport(@_);
    } else {
        return nativeReport(@_);
    }
}

sub server_dead {
    if (defined $ENV{RQG_CALLBACK}) {
        # (mleich1): Sorry, but I do not know if this works.
        return callbackDead(@_);
    } else {
        return nativeDead(@_);
    }
}

# (mleich1): Sorry, but I do not know if this works.
sub callbackDead {
    my $output = GenTest_e::CallbackPlugin::run("dead");
    say("$output");
    return STATUS_OK;
}

sub nativeDead {
    my $reporter = shift;

    my $status   = STATUS_OK;

    my $error_log = $reporter->serverInfo('errorlog');
    if (not defined $error_log) {
        $status = STATUS_ENVIRONMENT_FAILURE;
        Carp::cluck("ERROR: $who_am_i error log is not defined. " .
                    Basics::exit_status_text($status));
        exit $status;
    }

    my $pid_file =  $reporter->serverVariable('pid_file');
    my $pid =       $reporter->serverInfo('pid');

    my $server_running = kill (0, $pid);
    if ($server_running) {
        # say("INFO: $who_am_i:server_dead: The process of the DB server $pid is running. " .
        #     "Will check more.");
        # Maybe the server is around crashing.
        my $error_log = $reporter->serverInfo('errorlog');

        my $content =   Auxiliary::getFileSlice($error_log, 1000000);
        if (not defined $content or '' eq $content) {
            $status = STATUS_ENVIRONMENT_FAILURE;
            say("FATAL ERROR: $who_am_i No server error log content got. " .
                Basics::exit_status_text($status));
            return $status;
        }

        # FIXME: @end_line_patterns is a redundancy to lib/DBServer_e/MySQL/MySQLd.pm
        my @end_line_patterns = (
            '^Aborted$',
            'core dumped',
            '^Segmentation fault$',
            '(mariadbd|mysqld): Shutdown complete$',
            '^Killed$',                              # SIGKILL by RQG or OS or user
            '(mariadbd|mysqld) got signal',          # SIG(!=KILL) by DB server or RQG or OS or user
        );

        my $return = Auxiliary::content_matching($content, \@end_line_patterns, '', 0);
        if      ($return eq Auxiliary::MATCH_YES) {
            say("INFO: $who_am_i end_line_pattern in server error log content found.");
            if ($status < STATUS_SERVER_CRASHED) {
                $status = STATUS_SERVER_CRASHED;
                say("INFO: $who_am_i " . Basics::exit_status_text($status));
                exit $status;
            }
        } elsif ($return eq Auxiliary::MATCH_NO) {
            # Do nothing
        } else {
            $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: $who_am_i Problem when processing '" . $error_log . "' content. " .
                Basics::exit_status_text($status));
            exit $status;
        }
        return $status;
    } else {
        $status = STATUS_SERVER_CRASHED;
        say("INFO: $who_am_i:server_dead: The process of the DB server $pid is no more running. " .
            Basics::exit_status_text($status));
        exit $status;
    }
} # End sub nativeDead

sub report {
return STATUS_OK;
    my $reporter   = shift;
    # We are now after the OUTER loop in App/GenTest. There is nothing we can do here.
    # 1. When hitting during monitoring a situation looking like a server hang than we have
    #    already initiated that the server gets killed and exited the periodic reporter process
    # 2. CrashRecovery might have done his job. We do not know sufficient about the current server.
    # The RQG runner will later check the server regarding
    #    process dead or dying, hang, corruption
    # anyway.
    # Hence the current task is only to detect if the DB server is alive or not.
    # In case we have left the OUTER without detecting a server hang we might have now
    # some hang. This will be detected after GenTest was finished when the RQG runner calls
    # checkServers
    if (STATUS_OK != server_dead($reporter)) {
        my $status = STATUS_SERVER_CRASHED;
        say("INFO: $who_am_i The DB server is no more running. " .
            Basics::return_status_text($status));
        return $status;
    }
#   # If we have some server freeze or not should be discovered by the RQG runner!
    return STATUS_OK;
}

sub callbackReport {
    my $output = GenTest_e::CallbackPlugin::run("deadlock");
    say("$output");
    return STATUS_OK;
}

sub nativeReport {

    my $reporter   = shift;
    $reporter->init if not defined $reporter_query_threshold;
    my $server_pid = $reporter->serverInfo('pid');
    my $datadir    = $reporter->serverVariable('datadir');

    if ( ($^O eq 'MSWin32') || ($^O eq 'MSWin64')) {
        # Original code
        # my $cdb_command = "cdb -p $server_pid -c \".dump /m $datadir\mysqld.dmp;q\"";
        # Attempt to fix the     "Unrecognized escape \m passed through"
        my $cdb_command = "cdb -p $server_pid -c \".dump /m $datadir\\mysqld.dmp;q\"";
        say("INFO: $who_am_i Executing $cdb_command");
        system($cdb_command);
    } else {
        # When being here it is not 100% clear if we have a real freeze or some dying server.
        my $msg_begin = "INFO: $who_am_i Killing <Db server> with pid $server_pid with";
        say("$msg_begin SIGHUP in order to force debug output.");
        # MariaDB prints a round status information into the server error log.
        kill(1, $server_pid);

        # Writing the status information will require some time.
        my $wait_end = time() + ($reporter_query_threshold + OVERLOAD_ADD) / 2;
        while(time() < $wait_end) {
            sleep(1);
            if (STATUS_OK != server_dead($reporter)) {
                exit STATUS_SERVER_CRASHED;
            }
        }

        say("$msg_begin SIGSEGV in order to capture core.");
        kill(11, $server_pid);
        # It is intentional that we do not wait till the server process has disappeared.
        # The latter could last long (minutes!) because of writing the core on some overloaded box.
        # The risk could be that (see code in lib/GenTest_e/App/GenTest_e.pm)
        # 1. A RQG worker thread loses his connection, retries ~ 30s and exits than with
        #    STATUS_SERVER_CRASHED or STATUS_CRITICAL_FAILURE.
        # 2. Then the periodic reporting process (running for 'Deadlock') gets maybe killed before
        #    exiting with STATUS_SERVERDEAD_LOCKED.
        # 3. Than we end most probably up with some status != STATUS_SERVERDEAD_LOCKED
        #    which is misleading.
        # FIXME thorough:
        # Whenever a RQG worker thread has problems with the connection than it should exit with
        # STATUS_CRITICAL_FAILURE or similar.
        # Basically:
        # Only reporters or some routine after gendata or YY grammar processing should finally
        # figure out what the defect is.
    }

    exit STATUS_SERVER_DEADLOCKED;
} # End sub nativeReport

sub give_up {
    my ($status, $query) = @_;
    if (STATUS_OK != $status) {
        $executor->disconnect if defined $executor->dbh;
        if (STATUS_SERVER_CRASHED == $status or STATUS_CRITICAL_FAILURE == $status) {
            if (STATUS_OK != server_dead($reporter)) {
                $status = STATUS_SERVER_CRASHED;
            } else {
                # The DB server process is running and there are no signs of a server death in
                # the seerver error log.
                # Hence we have either
                # - a server freeze (STATUS_SERVER_DEADLOCKED) or
                # - the timeouts are too short.
                $status = STATUS_SERVER_DEADLOCKED;
                say("ERROR: $who_am_i Assuming a server freeze or too short timeouts. " .
                    Basics::exit_status_text($status) . " later.");
                $reporter->kill_with_core;
            }
        } else {
            say("INFO: $who_am_i the query '$query' harvested status $status.");
            say("INFO: $who_am_i Will call 'make_backtrace' which will kill the server " .
                "process if running+ set status to STATUS_CRITICAL_FAILURE.");
            $status = STATUS_CRITICAL_FAILURE;
        }
        exit $status;
    }
} # End sub give_up

sub inspect_processlist {
# Input:
# $print -- 0 --> print PROCESSLIST even if not suspicious
#           1 --> print PROCESSLIST all time
# Output:
# - if whatever connection related failure: just exit
# - if no connection related failure:
#      if assumed hang    --> 1
#      if no assumed hang --> 0
#
    my ($print) =           @_;

    my $declare_hang =      0;
    my $exit_msg;

    my $threads =           0;
    my $threads_killed =    0;
    my $threads_waiting =   0;

    # FIXME: Check if its needed or causes frictions with the other SIGALRM
    sigaction SIGALRM, new POSIX::SigAction sub {
        # Concept:
        # 1. Check first if the server process is gone.
        # 2. Set the error_exit_message for deadlock/freeze before setting the alarm.
        alarm (0);
        if (STATUS_OK != server_dead($reporter)) {
            exit STATUS_SERVER_CRASHED;
        }
        my $status = STATUS_SERVER_DEADLOCKED;
        say("ERROR: $who_am_i ALRM2 $exit_msg " .
            Basics::exit_status_text($status) . " later.");
        $reporter->kill_with_core;
        exit STATUS_SERVER_DEADLOCKED;
    } or die "ERROR: $who_am_i Error setting SIGALRM handler: $!\n";

    my $query = "SHOW FULL PROCESSLIST";
    my $alarm_timeout = $reporter_query_threshold + OVERLOAD_ADD;
    $exit_msg = "Got no response from server to query '$query' within " . $alarm_timeout . "s.";
    alarm ($alarm_timeout);
    my $result =    $executor->execute($query);
    alarm (0);
    my $status = $result->status;
    give_up($status, $query);

    my $processlist = $result->data;

    # TIME == n means n seconds within the current state
    my $processlist_report = "$who_am_i Content of processlist ---------- begin\n";
    $processlist_report .=   "$who_am_i ID -- COMMAND -- TIME -- STATE -- INFO -- " .
                             "RQG_guess\n";
    my $suspicious = 0;
    foreach my $process (@$processlist) {
        my $process_command = $process->[PROCESSLIST_PROCESS_COMMAND];
        $process_command = "<undef>" if not defined $process_command;
        my $process_id   = $process->[PROCESSLIST_PROCESS_ID];
        my $process_info = $process->[PROCESSLIST_PROCESS_INFO];
        $process_info    = "<undef>" if not defined $process_info;
        my $process_time = $process->[PROCESSLIST_PROCESS_TIME];
        $process_time    = "<undef>" if not defined $process_time;
        my $process_state= $process->[PROCESSLIST_PROCESS_STATE];
        $process_state   = "<undef>" if not defined $process_state;
        $processlist_report .= "$who_am_i -->" . $process_id . " -- " .
                               $process_command . " -- " . $process_time . " -- " .
                               $process_state . " -- " . $process_info;

        # 1. Up till today I have no criterion without undefined process_time value.
        if      ($process_time eq "<undef>") {
            $processlist_report .= " <--ok\n";
        # 2. The printing of threads with command value 'Daemon' should be not omitted.
        #    Maybe some criterions for detecting suspicious states gets found later.
        } elsif ($process_command eq 'Daemon') {
            $processlist_report .= " <--ok\n";
        # 3. Sort out "Slave_SQL"
        } elsif ($process_command eq "Slave_SQL") {
            # 3.1. 10.4:  Slave has read all relay log; waiting for the slave I/O thread to
            #           update it has read all relay log; waiting ... update  is "normal".
            #      newer: Slave has read all relay log; waiting for more updates
            #      can happen without meeting a falure.
            if ($process_state =~ /has read all relay log; waiting for .{1,30} to update/i) {
                $processlist_report .= " <--ok\n";
            # 3.2. For "Slave_SQL" the value for time was usually between 30 and less than 60s.
            } elsif ($process_time ne "<undef>" and $process_time > 60) {
                say("WARN: $who_am_i Slave_SQL with time > 60ss detected. Fear failure.");
                $suspicious++;
                $processlist_report .= " <--suspicious\n";
            } else {
                $processlist_report .= " <--ok\n";
            }
        # 4. Unexpected long lasting query
        } elsif ($process_info ne "<undef>" and $process_time > $query_lifetime_threshold) {
            say("ERROR: $who_am_i Query with time > query_lifetime_threshold( " .
                $query_lifetime_threshold . "s) detected. Assume failure.");
            $suspicious++;
            $processlist_report .= " <--suspicious\n";
            $declare_hang = 1;
        # 5. MDL timeouts must have an effect even with maybe some lag.
        # Problem:
        #    If more than one table has to be locked than the following could happen
        #    1. Wait mdl_timeout - 1
        #    2. Get the MDL lock on one of the tables.
        #    3. Wait more than a second but less than mdl_timeout for the MDL lock on the
        #       second table.
        #    4. The processlist shows for that connection a time value > mdl_timeout.
        } elsif ($process_info ne "<undef>" and $process_state =~ m{Waiting for table metadata}) {
            if ($process_time > $mdl_timeout_threshold3) {
                say("ERROR: $who_am_i Query with 'Waiting for table metadata lock' and time > " .
                    "mdl_timeout_threshold3($mdl_timeout_threshold3" .
                    "s) detected. Assume failure.");
                $suspicious++;
                $processlist_report .= " <--suspicious\n";
                $declare_hang = 1;
            } elsif ($process_time > $mdl_timeout_threshold1) {
                say("WARN: $who_am_i Query with 'Waiting for table metadata lock' and time > " .
                    "mdl_timeout_threshold1($mdl_timeout_threshold1" . "s) detected. Fear failure.");
                $suspicious++;
                $processlist_report .= " <--suspicious\n";
            } else {
                $processlist_report .= " <--ok\n";
            }
        # 6. Experimental
        #    IMHO some "Killed" SELECT should no more crawl through tables nor send
        #    result sets after 60s.
        } elsif ($process_command eq "Killed" and $process_info =~ m{\^ *SELECT }i and
                 $process_time > 60) {
            say("WARN: $who_am_i Query with plain 'SELECT', 'Killed' and time > 60s detected. " .
                "Fear failure.");
            $suspicious++;
            $processlist_report .= " <--suspicious\n";
        } else {
            $processlist_report .= " <--ok\n";
        }

        # RQG worker threads get started in GenTest and prepend something like
        # /* E_R Thread4 QNO 2743 CON_ID 112 */ to their SQL statement.
        if ($process_info =~ m{E_R Thread}) {
            $threads++;
            $threads_killed++   if $process_command =~ m{Killed};
            $threads_waiting++  if $process_state =~   m{Waiting for table metadata lock};
        }
    }
    $processlist_report .= "$who_am_i Content of processlist ---------- end";

    say("INFO: $who_am_i RQG worker threads : $threads , threads_killed : $threads_killed ," .
        " threads_waiting : $threads_waiting");

    if ($suspicious > STALLED_QUERY_COUNT_THRESHOLD) {
        say("ERROR: $who_am_i $suspicious suspicious queries detected. The threshold is " .
            STALLED_QUERY_COUNT_THRESHOLD . ". Assume failure.");
        $declare_hang = 1;
    }

    say($processlist_report) if $declare_hang or $suspicious or $print or $script_debug;

    return $declare_hang;
} # End sub inspect_processlist

# Do not add REPORTER_TYPE_END because the reporter 'CrashRecovery' might have restarted the
# server. And Deadlock will not know sufficient about that server.
sub type {
    return REPORTER_TYPE_PERIODIC | REPORTER_TYPE_DEADLOCK ;
}

1;

