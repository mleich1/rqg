# Copyright (c) 2008,2012 Oracle and/or its affiliates. All rights reserved.
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

    my $pid = $reporter->serverInfo('pid');

    # Whereas the "sync" looks reasonable it might have some unexpected impact on total runtime.
    # Some dd into some USB Flash drive performed by root caused a delay of several minutes.
    # system ("sync");

    # Do not look for a core file in case the server pid exists.
    my $server_running = 1;
    my $core_dumped_found  = 0;
    my $wait_timeout   = 180;
    my $start_time     = Time::HiRes::time();
    my $max_end_time   = $start_time + $wait_timeout;
    while ($server_running and not $core_dumped_found and (Time::HiRes::time() < $max_end_time)) {
        sleep 1;
        $server_running = kill (0, $pid);
        say("DEBUG: server pid : $pid , server_running : $server_running");

        if ($core_dumped_found == 0) {
            open(LOGFILE, "$error_log") or Carp::cluck("Error on open Server error file $error_log");
            while(<LOGFILE>) {
                if( /\(core dumped\)/ ) {
                    $core_dumped_found = 1;
                    say("DEBUG: '(core dumped)' found in server error log.");
                }
                # Segmentation fault (core dumped)
                # Aborted (core dumped)
            }
            close LOGFILE;
        }
    }
    my $wait_time = Time::HiRes::time() - $start_time;
    my $message_begin = "ALARM: Reporter::Backtrace $wait_time" . "s waited but the server";
    if ( $server_running ) {
        say("$message_begin process has not disappeared.");
        # It does not make sense to wait longer.
        say("INFO: Most probably false alarm. Will return STATUS_OK,undef.");
        say("INFO: Reporter 'Backtrace' ------------------------------ End");
        return STATUS_OK,undef;
    }
    if ( -e $pid_file ) {
        say("INFO: Reporter::Backtrace The pid_file '$pid_file' did not disappear.");
    }
    if ( not $core_dumped_found ) {
        say("$message_begin error_log remains without '... (core dumped)'.");
    }

    # Observation: 2018-07-04
    # -----------------------
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
    # Per first try: Polling for the core helped 100%.
    #

    $wait_timeout   = 90;
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
        say("Will return STATUS_OK,undef");
        say("INFO: Reporter 'Backtrace' ------------------------------ End");
        return STATUS_OK, undef;
    }
    say("INFO: The core file name computed is '$core'.");
    $core = File::Spec->rel2abs($core);
    if (-f $core) {
        say("INFO: The core file '$core' exists.")
    } else {
        say("WARNING: Core file not found!");
        # AFAIR:
        # Starting GDB for some not existing core file could waste serious runtime and
        # especially CPU time too.
        say("Will return STATUS_OK,undef");
        say("INFO: Reporter 'Backtrace' ------------------------------ End");
        return STATUS_OK, undef;
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
            say("Will return STATUS_OK,undef");
            say("INFO: Reporter 'Backtrace' ------------------------------ End");
            return STATUS_OK, undef;
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
