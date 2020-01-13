# Copyright (c) 2008,2012 Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2018-2019 MariaDB Corporation Ab.
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
use GenTest::Constants;
use GenTest::Reporter;
use GenTest::Incident;
use GenTest::CallbackPlugin;

#-----------------------------------------------------------------------
# Some notes (sorry if its for you too banal or obvious):
# 1. Backtrace is not a periodic reporter.
#    So it does not matter if the periodic reporting process is alive.
# 2. Backtrace will be called if ever only around end.
# 3. Builds with ASAN do not write a core file except the process environment
#    gets corresponding set
#    export ASAN_OPTIONS=abort_on_error=1,disable_coredump=0
#

sub report {
    if (defined $ENV{RQG_CALLBACK}) {
        return callbackReport(@_);
    } else {
        return nativeReport(@_);
    }
}

sub nativeReport {
    my $reporter = shift;

    say("INFO: Reporter 'Backtrace' ------------------------------ Begin");

    my $datadir = $reporter->serverVariable('datadir');
    say("datadir is $datadir");

    my $binary = $reporter->serverInfo('binary');
    say("binary is $binary");

    my $bindir = $reporter->serverInfo('bindir');
    say("bindir is $bindir");

    my $error_log = $reporter->serverInfo('errorlog');
    say("error_log is $error_log");

    my $pid_file = $reporter->serverVariable('pid_file');
    say("pid_file is $pid_file");

    # Observation 2019-12
    # -------------------
    # 14:59:06 [26267] pid_file is /dev/shm/vardir/1576241904/19/1/mysql.pid
    # sync: error opening '/dev/shm/vardir/1576241904/19/1/mysql.pid': No such file or directory
    # sync: error opening '/dev/shm/vardir/1576241904/19/1/mysql.pid': No such file or directory
    # 14:59:11 [26267] ALARM: Reporter::Backtrace 4.92569899559021s waited but the server error_log remains without '... (core dumped)'.
    # 15:03:42 [26267] INFO: Even after 270s waiting: The core file name is not defined.
    # 15:03:42 [26267] Will return STATUS_SERVER_CRASHED, undef
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
    # - before serching for applying the 270s timeout.
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
    #   Backtrace.pm detects that the server process disappered.
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
    my $server_running    = 1;
    my $core_dumped_found = 0;
    my $wait_timeout      = 180;
    my $start_time        = Time::HiRes::time();
    my $max_end_time      = $start_time + $wait_timeout;
    while ($server_running and not $core_dumped_found and (Time::HiRes::time() < $max_end_time)) {
        sleep 1;
        $server_running = kill (0, $pid);
        # say("DEBUG: server pid : $pid , server_running : $server_running");

        if (not osWindows()) {
            system ("sync $datadir/* $error_log $pid_file");
        }
        if ($core_dumped_found == 0) {
            open(LOGFILE, "$error_log") or Carp::cluck("Error on open Server error file $error_log");
            while(<LOGFILE>) {
                if( /\(core dumped\)/ ) {
                    $core_dumped_found = 1;
                    # say("DEBUG: '(core dumped)' found in server error log.");
                }
                # Segmentation fault (core dumped)
                # Aborted (core dumped)
            }
            close LOGFILE;
        }
    }

    my $wait_time     = Time::HiRes::time() - $start_time;
    my $message_begin = "ALARM: Reporter::Backtrace $wait_time" . "s waited but the server";
    if ( $server_running ) {
        say("$message_begin process has not disappeared.");
        # It does not make sense to wait longer.
        say("INFO: Most probably false alarm. Will return STATUS_OK, undef.");
        say("INFO: Reporter 'Backtrace' ------------------------------ End");
        return STATUS_OK, undef;
    };

    # Starting from here only the cases with disappeared server pid are left over.
    # Hence we need to report the status STATUS_SERVER_CRASHED whenever we return.

    if ( -e $pid_file ) {
        say("INFO: Reporter::Backtrace The pid_file '$pid_file' did not disappear.");
    }
    if ( not $core_dumped_found ) {
        say("$message_begin error_log remains without '... (core dumped)'.");
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
        my $rqg_homedir = "./";
        if (defined $ENV{RQG_HOME}) {
            $rqg_homedir = $ENV{RQG_HOME} . "/";
        }
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
