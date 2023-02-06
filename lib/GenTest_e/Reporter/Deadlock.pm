# Copyright (c) 2008,2012 Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2018,2022 MariaDB Coporation Ab.
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

# Attention:
# The term 'Deadlock' is partially incorrect.
# The current reporter is
# - also capable to catch
#   - unfair scheduling within the server affecting certain sessions
#   - server too slow up till maybe never responding
#   - Deadlocks at whatever place (SQL, storage engine, ??)
# - partially either vulnerable or elapsed runtime wasting because of
#   - $query_lifetime_threshold does not depend on maybe set query timeouts
#   - $actual_test_duration_exceed does not depend on $query_lifetime_threshold per pure math.
#   - The settings of $query_lifetime_threshold and $query_lifetime_threshold are "too" static.
#     Some comfortable adjustment of the setup of the RQG run (-> Variables specific to some
#     reporter or validator) to specific properties of some test is currently not supported.
#     Or at least I do not know how to do it.
#   - statements being slow because the data set is extreme huge combined with heavy load on
#     the testing box and too small timeouts
#   - STALLED_QUERY_COUNT_THRESHOLD is also static
#     IMHO better would be STALLED_QUERY_COUNT_THRESHOLD <= threads.
#   - maybe network problems
# and will report in all these cases STATUS_SERVER_DEADLOCKED.
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
# 3. The default value of 240s for $query_lifetime_threshold might look unfortunate small but
#    its quite good for RQG test simplification.
#
# FIXME if possible/time permits:
# $query_lifetime_threshold should be <= assigned duration
# $query_lifetime_threshold should be ~ QueryTimeout + ...
use constant QUERY_LIFETIME_THRESHOLD        => 120;  # Seconds

# Number of suspicious queries required before a deadlock is declared.
# use constant STALLED_QUERY_COUNT_THRESHOLD   => 5;
use constant STALLED_QUERY_COUNT_THRESHOLD   => 2;

# Number of times the actual test duration is allowed to exceed the desired one.
# use constant ACTUAL_TEST_DURATION_MULTIPLIER => 2;

# Number of seconds the actual test duration is allowed to exceed the desired one.
use constant ACTUAL_TEST_DURATION_EXCEED     => 300;  # Seconds

# The time, in seconds, we will wait for some query issued by the reporter (i.e. SHOW PROCESSLIST)
# before we declare the server hanged.
use constant REPORTER_QUERY_THRESHOLD        => 60;   # Seconds

# FIXME: Add a dependency from the number of threads.
# The time, in seconds, we will wait in addition for connect or a some query response in order
# to compensate for some heavy overloaded box and maybe unfortunate OS scheduling before we declare
# the server hanged.
use constant OVERLOAD_ADD                    => 15;   # Seconds

# exists $ENV{'RUNNING_UNDER_RR'}
# if (defined $reporter->properties->rr) {

my $who_am_i = "Reporter 'Deadlock':";
my $query_lifetime_threshold;
my $actual_test_duration_exceed;
my $reporter_query_threshold;
my $connect_timeout_threshold;

sub init {
    my $reporter = shift;
    $query_lifetime_threshold    = Runtime::get_runtime_factor() * QUERY_LIFETIME_THRESHOLD;
    $actual_test_duration_exceed = Runtime::get_runtime_factor() * ACTUAL_TEST_DURATION_EXCEED;
    $reporter_query_threshold    = Runtime::get_runtime_factor() * REPORTER_QUERY_THRESHOLD;
    $connect_timeout_threshold   = Runtime::get_runtime_factor() * CONNECT_TIMEOUT_THRESHOLD;
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
    # Actual observation (2019-10)
    # duration = 300, total test runtime > 1100 but the check direct below does not kick in.
    # Reason: gendata loads a lot and the box is heavy loaded. No defect in RQG or here.
    #

    my $actual_test_duration = time() - $reporter->testStart();
    if ($actual_test_duration > $actual_test_duration_exceed + $reporter->testDuration()) {
        say("ERROR: $who_am_i Actual test duration($actual_test_duration" . "s) is more than "     .
            "$actual_test_duration_exceed(" . $actual_test_duration_exceed  . "s) + the desired "  .
            "duration (" . $reporter->testDuration() . "s). Will kill the server later so that "   .
            "we get a core and exit with STATUS_SERVER_DEADLOCKED.");
        my $status;
        if (osWindows()) {
            $status = $reporter->monitor_threaded();
        } else {
            $status = $reporter->monitor_nonthreaded();
        }
        say("INFO: $who_am_i monitor... delivered status $status.");

        $reporter->kill_with_core;
        exit STATUS_SERVER_DEADLOCKED;
    }

    if (osWindows()) {
        return $reporter->monitor_threaded();
    } else {
        return $reporter->monitor_nonthreaded();
    }
}

sub monitor_nonthreaded {
    # Version for OS != WIN
    my $reporter = shift;
    my $dsn      = $reporter->dsn();

    # We connect on every run in order to be able to use the mysql_connect_timeout to detect very
    # debilitating deadlocks.

    # For testing
    # system("killall -11 mysqld"); # return STATUS_SERVER_CRASHED
    my $dbh;

    # We directly call exit() in the handler because attempting to catch and handle the signal in
    # a more civilized manner does not work for some reason -- the read() call from the server gets
    # restarted instead.

    my $exit_msg      = '';
    my $alarm_timeout = 0;
    my $query         = 'INIT';

    sigaction SIGALRM, new POSIX::SigAction sub {
        # Concept:
        # 1. Check first if the server process is gone.
        # 2. Set the error_exit_message for deadlock/freeze before setting the alarm.
        if (STATUS_OK != server_dead($reporter)) {
            exit STATUS_SERVER_CRASHED;
        }
        say("ERROR: $who_am_i $exit_msg " .
            "Will exit with STATUS_SERVER_DEADLOCKED later.");
        $reporter->kill_with_core;
        exit STATUS_SERVER_DEADLOCKED;
    } or die "ERROR: $who_am_i Error setting SIGALRM handler: $!\n";

    $alarm_timeout =    $connect_timeout_threshold + OVERLOAD_ADD;
    $exit_msg      =    "Got no connect to server within " . $alarm_timeout . "s. ";
    my $connect_start = time();
    say("DEBUG: $who_am_i Try to get a connection") if $script_debug;
    alarm ($alarm_timeout);
    $dbh = DBI->connect($dsn, undef, undef,
                        { mysql_connect_timeout => $connect_timeout_threshold,
                          PrintError            => 0,
                          RaiseError            => 0});
    alarm (0);
    if (not defined $dbh) {
        say("WARN: $who_am_i The connect attempt to dsn $dsn failed: " . $DBI::errstr .
            " after " . (time() - $connect_start) . "s.");
        my $return = GenTest_e::Executor::MySQL::errorType($DBI::err);
        if (not defined $return) {
            say("ERROR: $who_am_i The type of the error got is unknown. " .
                "Will exit with STATUS_INTERNAL_ERROR");
            exit STATUS_INTERNAL_ERROR;
        }
        if (STATUS_OK != server_dead($reporter)) {
            exit STATUS_SERVER_CRASHED;
        } else {
            # The DB server process is running and there are no signs of a server death in
            # the seerver error log.
            # Hence we have either
            # - a server freeze (STATUS_SERVER_DEADLOCKED) or
            # - the timeouts are too short.
            say("ERROR: $who_am_i Assuming a server freeze or too short timeouts. " .
                "Will exit with STATUS_SERVER_DEADLOCKED later.");
            $reporter->kill_with_core;
            exit STATUS_SERVER_DEADLOCKED;
        }
    }
    say("DEBUG: $who_am_i Some connection got. Runtime was " . (time() - $connect_start) . "s.")
        if $script_debug;

    $alarm_timeout = $reporter_query_threshold + OVERLOAD_ADD;
    my $query_start = time();
    $query    = '/*!100108 SET @@max_statement_time = 0 */';
    say("DEBUG: $who_am_i Try to run '" . $query . "'") if $script_debug;
    $exit_msg = "Got no response from server to query '$query' within " . $alarm_timeout . "s.";
    alarm ($alarm_timeout);
    # For testing: Syntax error -> STATUS_UNKNOWN_ERROR
    # $query    = "SHOW FULL OMO";          # Syntax error -> STATUS_SYNTAX_ERROR(21)
    # system("killall -9 mysqld; sleep 1"); # Dead server  -> STATUS_SERVER_CRASHED(101)
    #
    # alarm (3);                            # Exceed $alarm_timeout -> STATUS_SERVER_DEADLOCKED
    # $query = "SELECT SLEEP(4)";
    $dbh->do($query);
    alarm (0);
    my $err = $dbh->err();
    if (defined $err) {
        say("ERROR: $who_am_i The query '$query' failed with $err: " . $dbh->errstr());
        $dbh->disconnect;
        if (STATUS_OK != server_dead($reporter)) {
            say("ERROR: $who_am_i Will exit with STATUS_SERVER_CRASHED.");
            exit STATUS_SERVER_CRASHED;
        }
        my $return = GenTest_e::Executor::MySQL::errorType($err);
        if (not defined $return) {
            say("ERROR: $who_am_i The type of the error got is unknown. " .
                "Will exit with STATUS_INTERNAL_ERROR");
            exit STATUS_INTERNAL_ERROR;
            # return STATUS_UNKNOWN_ERROR;
        } else {
            say("ERROR: $who_am_i Will return status $return" . ".");
            return $return;
        }
    }
    say("DEBUG: $who_am_i '" . $query . "' runtime was " . (time() - $query_start) . "s.")
        if $script_debug;

    $query    = "SHOW FULL PROCESSLIST";
    # For testing:
    # $query    = "SHOW FULL OMO";  # Syntax error -> STATUS_INTERNAL_ERROR
    $exit_msg = "Got no response from server to query '$query' within " . $alarm_timeout . "s.";
    $query_start = time();
    alarm ($alarm_timeout);
    my $processlist = $dbh->selectall_arrayref($query);
    alarm (0);
    $err = $dbh->err();
    if (defined $err) {
        say("ERROR: $who_am_i The query '$query' failed with $err: " . $dbh->errstr());
        $dbh->disconnect;
        if (STATUS_OK != server_dead($reporter)) {
            say("ERROR: $who_am_i Will exit with STATUS_SERVER_CRASHED.");
            exit STATUS_SERVER_CRASHED;
        }
        my $return = GenTest_e::Executor::MySQL::errorType($err);
        if (not defined $return) {
            say("ERROR: $who_am_i The type of the error got is unknown. " .
                "Will exit with STATUS_INTERNAL_ERROR");
            exit STATUS_INTERNAL_ERROR;
            # return STATUS_UNKNOWN_ERROR;
        } else {
            say("ERROR: $who_am_i Will return status $return" . ".");
            return $return;
        }
    }
    if (not defined $processlist) {
        say("ERROR: $who_am_i The processlist content is undef. " .
            "Will exit with STATUS_INTERNAL_ERROR");
        $dbh->disconnect;
        exit STATUS_INTERNAL_ERROR;
    }
    say("DEBUG: $who_am_i '" . $query . "' runtime was " . (time() - $query_start) . "s.")
        if $script_debug;

    my $stalled_queries = 0;

    my $processlist_report = "$who_am_i Content of processlist ---------- begin\n";
    $processlist_report .= "$who_am_i ID -- COMMAND -- TIME -- INFO -- state\n";
    foreach my $process (@$processlist) {
        my $process_command = $process->[PROCESSLIST_PROCESS_COMMAND];
        $process_command = "<undef>" if not defined $process_command;
        # next if $process_command eq 'Daemon';
        my $process_id   = $process->[PROCESSLIST_PROCESS_ID];
        my $process_info = $process->[PROCESSLIST_PROCESS_INFO];
        $process_info    = "<undef>" if not defined $process_info;
        my $process_time = $process->[PROCESSLIST_PROCESS_TIME];
        $process_time    = "<undef>" if not defined $process_time;
        if (defined $process->[PROCESSLIST_PROCESS_INFO] and
            $process->[PROCESSLIST_PROCESS_INFO] ne ''   and
            defined $process->[PROCESSLIST_PROCESS_TIME] and
            $process->[PROCESSLIST_PROCESS_TIME] > $query_lifetime_threshold) {
            $stalled_queries++;
            $processlist_report .= "$who_am_i " . $process_id . " -- " . $process_command . " -- " .
                                   $process_time . " -- " . $process_info . " -- stalled?\n";
        } else {
            $processlist_report .= "$who_am_i " . $process_id . " -- " . $process_command . " -- " .
                                   $process_time . " -- " . $process_info . " -- ok\n";
        }
    }
    # In case we have a stalled query at all than we already print the content of the processlist.
    if ($stalled_queries or $script_debug) {
        $processlist_report .= "$who_am_i Content of processlist ---------- end";
        say($processlist_report);
    }

    if ($stalled_queries >= STALLED_QUERY_COUNT_THRESHOLD) {
        say("ERROR: $who_am_i $stalled_queries stalled queries detected, declaring deadlock at " .
            "DSN $dsn. Will exit with STATUS_SERVER_DEADLOCKED later.");
        say($processlist_report);

        foreach $query (
            "SHOW PROCESSLIST",
            "SHOW ENGINE INNODB STATUS"
            # "SHOW OPEN TABLES" - disabled due to bug #46433
        ) {
            say("INFO: $who_am_i Executing query '$query'");
            $exit_msg = "Got no response from server to query '$query' within " .
                        $alarm_timeout . "s.";
            $query_start = time();
            alarm ($alarm_timeout);
            my $status_result = $dbh->selectall_arrayref($query);
            alarm (0);
            if (not defined $status_result) {
                say("ERROR: $who_am_i The query '$query' failed with " . $DBI::err);
                my $return = GenTest_e::Executor::MySQL::errorType($DBI::err);
                if (not defined $return) {
                    say("ERROR: $who_am_i The type of the error got is unknown. " .
                        "Will exit with STATUS_INTERNAL_ERROR instead of STATUS_SERVER_DEADLOCKED");
                    $dbh->disconnect;
                    exit STATUS_INTERNAL_ERROR;
                }
            } else {
                print Dumper $status_result;
            }
        }
        $dbh->disconnect;
        $reporter->kill_with_core;
        exit STATUS_SERVER_DEADLOCKED;
    } else {
        $dbh->disconnect;
        return STATUS_OK;
    }
}

sub monitor_threaded {
    # Version for OS == WIN
    my $reporter = shift;

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

    my $stalled_queries = 0;

    foreach my $process (@$processlist) {
        if (
            ($process->[PROCESSLIST_PROCESS_INFO] ne '') &&
            ($process->[PROCESSLIST_PROCESS_TIME] > $query_lifetime_threshold)
        ) {
            $stalled_queries++;
        }
    }

    if ($stalled_queries >= STALLED_QUERY_COUNT_THRESHOLD) {
        say("ERROR: $who_am_i $stalled_queries stalled queries detected, declaring deadlock at DSN $dsn.");
        print Dumper $processlist;
        return STATUS_SERVER_DEADLOCKED;
    } else {
        return STATUS_OK;
    }
}

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

    my $who_am_i = Basics::who_am_i();

    my $error_log = $reporter->serverInfo('errorlog');
    if (not defined $error_log) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        Carp::cluck("ERROR: $who_am_i error log is not defined. " .
                    "Will exit with STATUS_ENVIRONMENT_FAILURE.");
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
        my $found = Auxiliary::search_in_file($error_log, '\[ERROR\] mysqld got signal');
        if (not defined $found) {
            # Technical problems!
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("FATAL ERROR: $who_am_i \$found is not defined. " .
                "Will exit with STATUS_ENVIRONMENT_FAILURE.");
            exit $status;
        } elsif ($found) {
            say("INFO: $who_am_i '\[ERROR\] mysqld got signal' detected. " .
                "Will exit with STATUS_SERVER_CRASHED.");
            exit STATUS_SERVER_CRASHED;
        } else {
            $found = Auxiliary::search_in_file($error_log, 'Aborted \(core dumped\)');
            if (not defined $found) {
                # Technical problems!
                my $status = STATUS_ENVIRONMENT_FAILURE;
                say("FATAL ERROR: $who_am_i \$found is undef. " .
                    "Will exit with STATUS_ENVIRONMENT_FAILURE.");
                exit $status;
            } elsif ($found) {
                say("INFO: $who_am_i 'Aborted (core dumped)' detected. " .
                    "Will exit with STATUS_SERVER_CRASHED.");
                exit STATUS_SERVER_CRASHED;
            } else {
                return STATUS_OK;
            }
        }
    } else {
        say("INFO: $who_am_i:server_dead: The process of the DB server $pid is no more running. " .
            "Will return STATUS_SERVER_CRASHED.");
        exit STATUS_SERVER_CRASHED;
    }
}


sub report {
    # When hitting during monitoring
    # - a situation looking like a server hang than we have already initiated that the server gets
    #   killed with core and exited with STATUS_SERVER_DEADLOCKED.
    #   The reporter 'Backtrace' will do or has already done
    #   1. Detect that the server is dead
    #   2. Search for the core and make the final analysis.
    #   3. Return STATUS_SERVER_CRASHED
    #   But 'Deadlock' has exited with STATUS_SERVER_DEADLOCKED before and that is the higher value.
    # - no suspicious situation than we have no reason to do anything.
    # Hence we report nothing and return STATUS_OK.
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
        # system("gdb --batch -p $server_pid -ex 'thread apply all backtrace'");
        my $msg_begin = "INFO: $who_am_i Killing mysqld with pid $server_pid with";
        say("$msg_begin SIGHUP in order to force debug output.");
        # MariaDB prints a round status information into the server error log.
        kill(1, $server_pid);

        # FIXME:
        # How to ensure that
        # - all debug output is written before the SIGSEGV is sent
        # - worker threads detecting that the server does not respond twist the final status to
        #   something != STATUS_SERVER_DEADLOCKED
        sleep(($reporter_query_threshold + OVERLOAD_ADD) / 2);

        say("$msg_begin SIGSEGV in order to capture core.");
        kill(11, $server_pid);
        # It is intentional that we do not wait till the server process has disappeared.
        # The latter could last long (minutes!) because of writing the core on some overloaded box.
        # The risk could be that (see code in lib/GenTest_e/App/GenTest_e.pm)
        # 1. A RQG worker thread loses his connection, retries ~ 30s and gives than up with
        #    STATUS_SERVER_CRASHED.
        # 2. Then the periodic reporting process (running for 'Deadlock') gets maybe killed before
        #    exiting with STATUS_SERVERDEAD_LOCKED.
        # 3. Than we end most probably up with STATUS_SERVER_CRASHED which is misleading.
        # FIXME:
        # Whenever a RQG worker thread has problems with the connection than it should exit with
        # STATUS_CRITICAL_FAILURE or similar.
        # Basically: Reporters should finally figure out what the defect is.
    }

    exit STATUS_SERVER_DEADLOCKED;
}

sub type {
    return REPORTER_TYPE_PERIODIC | REPORTER_TYPE_DEADLOCK;
}

1;

