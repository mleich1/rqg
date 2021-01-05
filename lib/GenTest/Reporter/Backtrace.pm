# Copyright (c) 2008,2012 Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2018-2020 MariaDB Corporation Ab.
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

package GenTest::Reporter::Backtrace;

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use GenTest;
use Auxiliary;
use GenTest::Constants;
use GenTest::Reporter;
use GenTest::Incident;
use GenTest::CallbackPlugin;

#-----------------------------------------------------------------------
# Some notes (sorry if its for you too banal or obvious):
# 1. Backtrace is not a periodic reporter.
#    So it does not matter if the periodic reporting process is alive.
# 2. Backtrace will be called if ever only around test end.
# 3. Builds with ASAN do not write a core file except the process environment
#    gets corresponding set
#    export ASAN_OPTIONS=abort_on_error=1,disable_coredump=0
# 4. In case of runs invoking 'rr' writing of cores of the server process is
#    disabled.

my @end_line_patterns = (
    '^Aborted$',
    '^Segmentation fault$',
    'mysqld: Shutdown complete$',
    '^Killed$'
);


my $who_am_i = "Reporter 'Backtrace':";

sub report {
    if (defined $ENV{RQG_CALLBACK}) {
        return callbackReport(@_);
    } else {
        return nativeReport(@_);
    }
}

sub nativeReport {
    my $reporter = shift;


    say("INFO: $who_am_i ----- nativeReport ----------- Begin");

    my $datadir = $reporter->serverVariable('datadir');
    say("datadir is $datadir");

    my $binary = $reporter->serverInfo('binary');
    say("binary is $binary");

    my $bindir = $reporter->serverInfo('bindir');
    say("bindir is $bindir");

    my $error_log = $reporter->serverInfo('errorlog');
    say("error_log is $error_log");

    my $vardir = $reporter->properties->servers->[0]->vardir();
    # /dev/shm/vardir/SINGLE_RQG/1  <---- We get this.
    # /dev/shm/vardir/SINGLE_RQG/2
    # /dev/shm/vardir/SINGLE_RQG/rr_trace
    # /dev/shm/vardir/SINGLE_RQG/rr_trace/last_trace
    # /dev/shm/vardir/SINGLE_RQG/rr_trace/mysqld-0
    # /dev/shm/vardir/SINGLE_RQG/rr_trace/mysqld-1

    my $pid_file = $reporter->serverVariable('pid_file');
    say("pid_file is $pid_file");

    my $pid = $reporter->serverInfo('pid');

    # Observation: 2018 June - September
    # ----------------------------------
    # rqg_batch on some extreme strong box
    #    > 100 RQG's concurrent and all use tmpfs, no paging
    # There is some too big (partially > 30%) fraction of RQG runs which end definitely with
    # crash/assert but the core file is not found in time (timeout 90s).
    # Hence we get finally STATUS_CRITICAL_FAILURE (100) because there was no core file
    # and maybe the verdict 'interest' instead of replay.
    #
    # In case we go with serious less concurrent RQG runs than this fraction decreases serious.
    # This is doable as temporary measure but never in general.
    #
    # The timeout is required because we do not want to wait "endless" for some core which will
    # maybe never show up (ASAN setup without core, Bug in RQG core, ...). from whatever reason.
    #
    # Some real life example what happened:
    # Some threads lose their connection + attempt to connect to server again failed.
    # So they stop with status STATUS_SERVER_CRASHED.
    # 04T18:34:06 [190727] GenTest: child 190727 is being stopped with status STATUS_SERVER_CRASHED
    # 04T18:34:09 [188964] Process with pid 190772 for Thread5 ended with status STATUS_SERVER_CRASHED
    # 04T18:34:09 [188964] Killing remaining worker process with pid 190727...
    # ...
    # 04T18:34:09 [188964] Killing remaining worker process with pid 190872...
    # 04T18:34:10 [188964] Killing periodic reporting process with pid 190620...
    # 04T18:34:10 [190620] GenTest: child 190620 is being stopped with status STATUS_OK
    # 04T18:34:10 [188964] For pid 190620 reporter status STATUS_OK
    # 04T18:34:10 [188964] Kill GenTest::ErrorFilter(190619)
    # 04T18:34:10 [188964] Server crash reported, initiating post-crash analysis...
    # --------- Contents of /dev/shm/vardir/1530722017/13/1/data//../mysql.err -------------
    # The usual stuff including the typical "poor" backtrace in mysql.err.
    # ...
    # 04T18:34:10 [188964] | Writing a core file at /dev/shm/vardir/1530722017/13/1/data/
    # 04T18:34:10 [188964] | Aborted (core dumped)
    # 04T18:34:10 [188964] ----------------------------------
    # 04T18:34:10 [188964] INFO: Reporter 'Backtrace' ------------------------------ Begin
    # 04T18:34:11 [188964] DEBUG: server pid : 190034 , server_running : 0
    # 04T18:34:11 [188964] DEBUG: Aborted + core dumped found in server error log.
    # 04T18:34:11 [188964] INFO: Reporter::Backtrace The pid_file '.../mysql.pid' did not disappear.
    # 04T18:34:11 [188964] DEBUG: The core file name is not defined.
    # 04T18:34:11 [188964] DEBUG: The core file name is not defined.
    # 04T18:34:11 [188964] Will return STATUS_OK,undef
    # 04T18:34:11 [188964] INFO: Reporter 'Backtrace' ------------------------------ End
    # So the reporter gave up before a core file became visible.
    # And the RQG run ended with
    # STATUS_SERVER_CRASHED --> STATUS_CRITICAL_FAILURE (100) because there was no core file.
    # Around 04T18:34:20 one of the concurrent RQG runs with the same grammars etc. ended with
    # finding a core, getting a backtrace and throwing STATUS_SERVER_CRASHED.
    # Conclusion: Wait longer for the core file showing up.
    #
    # First measure (June 2018)
    # Increase the timeout from 90s to 270s.
    # Serious improvement in general. And nearly sufficient for debug without ASAN builds.
    #
    # Second (experimental) measure in September:
    #     Have such a high fraction (> 30%) again but now with ASAN builds.
    #     Experiments with "sync $error_log" show some serious progress (fraction ~ 3%).
    # Use 'system ("sync $error_log ... ");' in addition
    # - before searching for applying the 270s timeout.
    #
    # My guesss:
    # If using sync than we might be able to reduce the timeout later.
    #
    # Btw. some simple 'system ("sync")' could have some unexpected impact on the total runtime
    # of the current RQG test.
    # 1. By that we would sync the data of concurrent RQG runs and get some further delay.
    #    But it is not known in advance if that gives some advantage to these tests at all.
    #    So let this task to them because only they know if its required.
    # 2. I had once a "format some 32GB USB Flash drive with dd" performed by root in parallel
    #    to my single RQG run using tmpfs. The delay was several minutes.
    #

    # Do not look for a core file in case the server pid exists.
    # Observation on ASAN build but weak statistics
    # - If '(core dumped)' shows up in server error log than the timestamp in the log is 0 to 1s
    #   before Backtrace.pm detects that the server process disappeared.
    # - A high fraction of the crashes cause the usual block of related entries in the error log
    #   and
    #   - none of these entries look like made by ASAN
    #   - the error log ends with
    #     ... Writing a core file at /dev/shm/vardir/1536609514/2/1/data/
    #     ... Aborted (core dumped)
    # - A small fraction
    #   ERROR: AddressSanitizer: unknown-crash
    #   ==132668==ABORTING
    #   In case the ASAN options allow core writing and we wait long enough than a
    #   'Aborted (core dumped)' follows later.

    # FIXME:
    # - The next section gives a significant acceleration if the current total status is
    #   STATUS_CRITICAL_FAILURE/STATUS_SERVER_CRASHED or STATUS_ENVIRONMENT_FAILURE and
    #   its a false alarm because of too short connect_timeout.
    # - It could also cause some false final status in case one reporter like Deadlock tried to
    #   kill the server process and that had not the expected impact till now. (seen 2020-12)
    #   kill SIGABRT; exit STATUS_SERVER_DEADLOCKED
    #   The main process in GenTest reaps that status and leaves the loop OUTER.
    #   Stopping/Reaping of worker processes + the periodic reporting process is already gone.
    #   Backtrace detects that the server is connectable and reduces the status to
    #   STATUS_CRITICAL_FAILURE etc.
    # But it had to be disabled because having an ugly impact in case of
    # - the testing box is under heavy load
    # - the periodic reporter initiated a server crash (CrashRecovery or similar) and exited
    # - we have already left loop OUTER in GenTest
    # and than the reporter Backtrace is able to connect because the crash is not finished
    # and changes the status or similar.
    my $server_running = kill (0, $pid);
#   if ($server_running) {
#       # Maybe its complete false (regarding STATUS_SERVER_CRASHED) alarm
#       # So we simply try to connect;
#       my $dbh = DBI->connect($reporter->dsn(), undef, undef, { mysql_multi_statements => 0,
#                                                                RaiseError => 0 } );
#       if (defined $dbh) {
#           $dbh->disconnect;
#           my $status = STATUS_CRITICAL_FAILURE;
#           say("INFO: $who_am_i The server is connectable. Will return " .
#               "STATUS_CRITICAL_FAILURE, undef");
#           return STATUS_CRITICAL_FAILURE, undef;
#       }
#   }

    my $end_line_found    = 0;
    my $wait_timeout      = 180;
    my $start_time        = Time::HiRes::time();
    my $max_end_time      = $start_time + $wait_timeout;
    while ($server_running and not $end_line_found and (Time::HiRes::time() < $max_end_time)) {
        sleep 1;
        $server_running = kill (0, $pid);
        # say("DEBUG: server pid : $pid , server_running : $server_running");
        my $content = Auxiliary::getFileSlice($error_log, 1000000);
        if (not defined $content or '' eq $content) {
            say("FATAL ERROR: $who_am_i No server error log content got. Will return undef.");
            return STATUS_ENVIRONMENT_FAILURE, undef;
        }
        my $return = Auxiliary::content_matching($content, \@end_line_patterns, '', 0);
        if      ($return eq Auxiliary::MATCH_YES) {
            $end_line_found = 1;
        } elsif ($return eq Auxiliary::MATCH_NO) {
            # Do nothing
        } else {
            say("ERROR: $who_am_i Problem when processing '" . $error_log . "'. Will return " .
                "STATUS_ENVIRONMENT_FAILURE, undef");
            return STATUS_ENVIRONMENT_FAILURE, undef;
        }
    }

    my $wait_time     = Time::HiRes::time() - $start_time;
    my $message_begin = "ALARM: $who_am_i $wait_time" . "s waited but the server";
    if (not defined $server_running) {
        say("ERROR: $who_am_i kill 0 on server process $pid delivered undef.");
        system("ps -elf | egrep 'mysqld|mariadbd' | grep $pid");
    } elsif ( $server_running ) {
        say("$message_begin process $pid has not disappeared.");
        # It does not make sense to wait longer.
        say("INFO: Most probably false alarm. Will return STATUS_OK, undef.");
        say("INFO: Reporter 'Backtrace' ------------------------------ End");
        return STATUS_OK, undef;
    } else {
        say("ERROR: $who_am_i The server process $pid has disappeared.");
    }

    # Starting from here only the cases with disappeared server pid are left over.
    # Hence we need to report the status STATUS_SERVER_CRASHED whenever we return.

    if ( -e $pid_file ) {
        say("INFO: $who_am_i The pid_file '$pid_file' did not disappear.");
    } else {
        say("WARN: $who_am_i The pid_file '$pid_file' did disappear. Hence (likely) the server " .
            "was able to remove it or (less likely) something else did that.");
        my $found = Auxiliary::search_in_file($error_log, 'mysqld: Shutdown complete^');
        if      (not defined $found) {
            say("ERROR: $who_am_i Problem when processing '" . $error_log . "'. Will return " .
                "STATUS_ENVIRONMENT_FAILURE, undef");
            return STATUS_ENVIRONMENT_FAILURE, undef;
        } elsif (1 == $found) {
            say("WARN: $who_am_i Normal shutdown detected. This is unexpected. Will return " .
                "STATUS_CRITICAL_FAILURE, undef");
            return STATUS_CRITICAL_FAILURE, undef;
        } else {
            # Do nothing
        }
    }
    my $rqg_homedir = $ENV{RQG_HOME} . "/";
    # For testing:
    # $rqg_homedir = undef;
    if (not defined $rqg_homedir) {
        say("ERROR: $who_am_i The RQG runner has not set RQG_HOME in environment. Will return " .
            "STATUS_ENVIRONMENT_FAILURE, undef");
        return STATUS_ENVIRONMENT_FAILURE, undef;
    }
    # Note:
    # The message within the server error log "Writing a core file..." describes the intention
    # but not if that really happened.
    my $core_dumped_pattern = 'core dumped';
    my $found = Auxiliary::search_in_file($error_log, $core_dumped_pattern);
    if      (not defined $found) {
        say("ERROR: $who_am_i Problem when processing '" . $error_log . "'. Will return " .
            "STATUS_ENVIRONMENT_FAILURE, undef");
        return STATUS_ENVIRONMENT_FAILURE, undef;
    } elsif (1 == $found) {
        # Go on
    } else {
        say("INFO: $who_am_i The pattern '$core_dumped_pattern' was not found in '$error_log'.");
        if (defined $reporter->properties->rr) {
            # We try to generate a backtrace form the rr trace.
            my $rr_trace_dir = $vardir . '/rr';
            my $backtrace =    $vardir . '/backtrace.txt';
            my $backtrace_cfg = $rqg_homedir . "backtrace-rr.gdb";
            # Note: STDERR just shows the content of the server error log which we have anyway.
            my $command = "_RR_TRACE_DIR=$rr_trace_dir rr replay >$backtrace 2>/dev/null < $backtrace_cfg";
            system('bash -c "set -o pipefail; '. $command .'"');
            sayFile($backtrace);
        }
        say("INFO: $who_am_i No core file to be expected. Will return " .
                "STATUS_SERVER_CRASHED, undef");
        return STATUS_SERVER_CRASHED, undef;
    }

    $wait_timeout   = 270;
    $start_time     = Time::HiRes::time();
    $max_end_time   = $start_time + $wait_timeout;
    my $core;
    while (not defined $core and Time::HiRes::time() < $max_end_time) {
        sleep 1;
        $core = <$datadir/core*>;
        if (defined $core) {
            # say("DEBUG: The core file name computed is '$core'");
        } else {
            $core = </cores/core.$pid> if $^O eq 'darwin';
            if (defined $core) {
                # say("DEBUG: The core file name computed is '$core'");
            } else {
                $core = <$datadir/vgcore*> if defined $reporter->properties->valgrind;
                if (defined $core) {
                    # say("DEBUG: The core file name computed is '$core'");
                } else {
                    # say("DEBUG: The core file name is not defined.");
                }
            }
        }
    }
    if (not defined $core) {
        say("INFO: Even after $wait_timeout" . "s waiting: The core file name is not defined.");
        say("Will return STATUS_SERVER_CRASHED, undef");
        say("INFO: Reporter 'Backtrace' ------------------------------ End");
        return STATUS_SERVER_CRASHED, undef;
    }
    say("INFO: The core file name computed is '$core'.");
    $core = File::Spec->rel2abs($core);
    if (-f $core) {
        my @filestats = stat($core);
        my $filesize  = $filestats[7] / 1024;
        say("INFO: Core file '$core' size in KB: $filesize");
    } else {
        say("WARNING: Core file not found!");
        # AFAIR:
        # Starting GDB for some not existing core file could waste serious runtime and
        # especially CPU time too.
        say("Will return STATUS_SERVER_CRASHED, undef");
        say("INFO: Reporter 'Backtrace' ------------------------------ End");
        return STATUS_SERVER_CRASHED, undef;
    }

    my @commands;

    if (osWindows()) {
        $bindir =~ s{/}{\\}sgio;
        my $cdb_cmd = "!sym prompts off; !analyze -v; .ecxr; !for_each_frame dv /t;~*k;q";
        push @commands,
            'cdb -i "' . $bindir . '" -y "' . $bindir .
            ';srv*C:\\cdb_symbols*http://msdl.microsoft.com/download/symbols" -z "' . $datadir .
            '\mysqld.dmp" -lines -c "'.$cdb_cmd.'"';
    } elsif (osSolaris()) {
        ## We don't want to run gdb on solaris since it may core-dump
        ## if the executable was generated with SunStudio.

        ## 1) First try to do it with dbx. dbx should work for both
        ## Sunstudio and GNU CC. This is a bit complicated since we
        ## need to first ask dbx which threads we have, and then dump
        ## the stack for each thread.

        ## The code below is "inspired by MTR
        `echo | dbx - $core 2>&1` =~ m/Corefile specified executable: "([^"]+)"/;
        if ($1) {
            ## We do apparently have a working dbx

            # First, identify all threads
            my @threads = `echo threads | dbx $binary $core 2>&1` =~ m/t@\d+/g;

            ## Then we make a command for each thread (It would be
            ## more efficient and get nicer output to have all
            ## commands in one dbx-batch, TODO!)

            my $traces = join("; ", map{"where " . $_} @threads);

            push @commands, "echo \"$traces\" | dbx $binary $core";
        } elsif ($core) {
            ## We'll attempt pstack and c++filt which should allways
            ## work and show all threads. c++filt from SunStudio
            ## should even be able to demangle GNU CC-compiled
            ## executables.
            push @commands, "pstack $core | c++filt";
        } else {
            say ("No core available");
            say("Will return STATUS_SERVER_CRASHED, undef");
            say("INFO: Reporter 'Backtrace' ------------------------------ End");
            return STATUS_SERVER_CRASHED, undef;
        }
    } else {
        ## Assume all other systems are gdb-"friendly" ;-)
        # We should not expect that our RQG Runner has some current working directory
        # containing the RQG to be used or some RQG at all.
        my $command_part = "gdb --batch --se=$binary --core=$core --command=$rqg_homedir";
        push @commands, "$command_part" . "backtrace.gdb";
        push @commands, "$command_part" . "backtrace-all.gdb";
    }

    my @debugs;

    foreach my $command (@commands) {
        my $output = `$command`;
        say("$output");
        push @debugs, [$command, $output];

        # Observation 2018-07-12
        # During some grammar simplification run the grammar loses its balance (INSERTS remain,
        # DELETE is gone) and caused by this and some other things we end up in rapid increasing
        # space consumption --> no more space on tmpfs which than causes
        # - fail in bootstrap
        # - storage engine reports error 28 (disk full), the server asserts and gdb tells
        #   BFD: Warning: /dev/shm/vardir/1531326733/23/54/1/data/core is truncated:
        #   expected core file size >= 959647744, found: 55398400.
        #   --> Add it to the default black list patterns

    }

    my $incident = GenTest::Incident->new(
        result   => 'fail',
        corefile => $core,
        debugs   => \@debugs
    );

    # return STATUS_OK, $incident;
    say("Will return STATUS_SERVER_CRASHED, ...");
    say("INFO: Reporter 'Backtrace' ------------------------------ End");
    return STATUS_SERVER_CRASHED, $incident;
}

sub callbackReport {
    my $output = GenTest::CallbackPlugin::run("backtrace");
    say("$output");
    ## Need some incident interface here in the output from
    ## the callback
    return STATUS_OK, undef;
}

sub type {
    return REPORTER_TYPE_CRASH | REPORTER_TYPE_DEADLOCK;
}

1;
