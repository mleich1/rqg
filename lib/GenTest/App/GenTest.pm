#!/usr/bin/perl

# Copyright (c) 2008,2012 Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2013, Monty Program Ab.
# Copyright (c) 2016, 2021 MariaDB Corporation Ab
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

package GenTest::App::GenTest;

@ISA = qw(GenTest);

use strict;
use Carp;
use Data::Dumper;
use File::Basename;
use File::Path 'mkpath';
use File::Copy;
use File::Spec;

use Auxiliary;

use GenTest;
use GenTest::Properties;
use GenTest::Constants;
use GenTest::App::Gendata;
use GenTest::App::GendataSimple;
use GenTest::App::GendataAdvanced;
use GenTest::App::GendataSQL;
use GenTest::IPC::Channel;
use GenTest::IPC::Process;
use GenTest::ErrorFilter;
use GenTest::Grammar;

use POSIX;
use Time::HiRes;

use GenTest::XML::Report;
use GenTest::XML::Test;
use GenTest::XML::BuildInfo;
use GenTest::XML::Transporter;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Validator;
use GenTest::Executor;
use GenTest::Mixer;
use GenTest::Reporter;
use GenTest::ReporterManager;
use GenTest::Filter::Regexp;
use GenTest::Incident;

use constant PROCESS_TYPE_PARENT    => 0;
use constant PROCESS_TYPE_PERIODIC  => 1;
use constant PROCESS_TYPE_CHILD     => 2;

use constant GT_CONFIG              => 0;
use constant GT_XML_TEST            => 3;
use constant GT_XML_REPORT          => 4;
use constant GT_CHANNEL             => 5;

use constant GT_GRAMMAR             => 6;
use constant GT_GENERATOR           => 7;
use constant GT_REPORTER_MANAGER    => 8;
use constant GT_TEST_START          => 9;
use constant GT_TEST_END            => 10;
use constant GT_QUERY_FILTERS       => 11;
use constant GT_LOG_FILES_TO_REPORT => 12;

my $debug_here = 0;

sub new {
    my $class = shift;

    my $self = $class->SUPER::new({
        'config' => GT_CONFIG}, @_);

    # Reporters get used
    # - immediate after gendata steps if needed (server not reponding or similar)
    # - during gentest if assigned or after gentest if needed (server not reponding or similar)
    if ($self->config->reporters and not ref $self->config->reporters eq 'ARRAY') {
        $self->config->reporters([ split /,/, $self->config->reporters ]);
    }
    # Validators get used during gentest if assigned
    if ($self->config->validators and not ref $self->config->validators eq 'ARRAY') {
        $self->config->validators([ split /,/, $self->config->validators ]);
    }
    # Transformers get used during gentest if assigned
    if ($self->config->transformers and not ref $self->config->transformers eq 'ARRAY') {
        $self->config->transformers([ split /,/, $self->config->transformers ]);
    }
    if ($self->config->redefine and not ref $self->config->redefine eq 'ARRAY') {
        $self->config->redefine([ split /,/, $self->config->redefine ]);
    }
    if ($self->config->engine and not ref $self->config->engine eq 'ARRAY') {
        $self->config->engine([ split /,/, $self->config->engine ]);
    }
    if ($self->config->dsn and not ref $self->config->dsn eq 'ARRAY') {
        $self->config->dsn([ split /,/, $self->config->dsn ]);
    }
    if ($self->config->vcols and not ref $self->config->vcols eq 'ARRAY') {
        $self->config->vcols([ split /,/, $self->config->vcols ]);
    }
    if ($self->config->views and not ref $self->config->views eq 'ARRAY') {
        $self->config->views([ split /,/, $self->config->views ]);
    }
    if ($self->config->debug_server and not ref $self->config->debug_server eq 'ARRAY') {
        $self->config->debug_server([ split /,/, $self->config->debug_server ]);
    }
    if ($self->config->servers and not ref $self->config->servers eq 'ARRAY') {
        $self->config->servers([ split /,/, $self->config->servers ]);
    }

    # Initialize the reporters now because
    # - running parts of Gendata/GenTest with success but failing later because of defect or missing
    #   reporters is wasting of resources at runtime
    # - at least the reporter Backtrace is useful when hitting trouble in Gendata
    my $status = $self->initReporters;
    if (STATUS_OK != $status) {
        say("ERROR: GenTest: initReporters returned status $status. Will return undef.");
        return undef;
    }

    if (not defined $self->config) {
        Carp::cluck("ERROR: \$self->config is not defined but we need it. Will return undef.");
        return undef;
    } else {
        return $self;
    }
}

sub config {
    return $_[0]->[GT_CONFIG];
}

sub grammar {
    return $_[0]->[GT_GRAMMAR];
}

sub generator {
    return $_[0]->[GT_GENERATOR];
}

sub XMLTest {
    return $_[0]->[GT_XML_TEST];
}

sub XMLReport {
    return $_[0]->[GT_XML_REPORT];
}

sub channel {
    return $_[0]->[GT_CHANNEL];
}

sub reporterManager {
    return $_[0]->[GT_REPORTER_MANAGER];
}

sub queryFilters {
    return $_[0]->[GT_QUERY_FILTERS];
}

sub logFilesToReport {
    return @{$_[0]->[GT_LOG_FILES_TO_REPORT]};
}

sub do_init {
    my $self = shift;

    # Attention
    # ---------
    # Either
    # - never run SQL here (valid 2019-11)
    # or
    # - take care that sqltracing is done according to configuration
    #   Whatever sqltrace to test converter might need to pick even the SQL done here.
    #
    # Artificial negative example:
    # Here gets some global or session server variable set -> in sqltrace if enabled.
    # A marker like "Start of <whatever>" gets printed into RQG log.
    # New session (impact of global variable) or old session (impact of session ...) runs
    # the SQL stream <whatever>.
    # A marker like "End of <whatever>" gets printed into RQG log.
    # The converter processes the RQG log and extracts all SQL between the markers.
    # But the SQL which was done in "do_init" is missing!
    #

    our $initialized = 0 if not defined $initialized;

    if (not $initialized ) {

        # This handler for TERM is valid for all worker threads and the ErrorFilter.
        # For debugging
        # $SIG{TERM} = sub { say("DEBUG: $$ have just received TERM and will exit with exit status 0."); exit(0) };
        $SIG{TERM} = sub { exit(0) };
        $SIG{CHLD} = "IGNORE" if osWindows();
        $SIG{INT}  = "IGNORE";

        # FIXME:
        # Why do we fiddle here again with RQG_HOME?
        # Is there a risk to pull RQG components out of the wrong RQG universe?
        if (defined $ENV{RQG_HOME}) {
            $ENV{RQG_HOME} = osWindows() ? $ENV{RQG_HOME}.'\\' : $ENV{RQG_HOME}.'/';
        }

        $ENV{RQG_DEBUG} = 1 if $self->config->debug;

        $self->initSeed();

        # FIXME:
        # We only initialize here.
        # - Some hypothetic RQG runner might omit processing the YY grammar.
        # - Even with the current runners its questionable why to report this
        #   now (usually before gendata) and not when the YY grammar processing happens.
        my $queries = $self->config->queries;
        $queries =~ s{K}{000}so;
        $queries =~ s{M}{000000}so;
        $self->config->property('queries', $queries);

      # say("-------------------------------\nConfiguration");
      # $self->config->printProps;
        $initialized = 1;
        say("DEBUG: GenTest::App::GenTest::do_init: Have initialized.") if $debug_here;
    } else {
        say("DEBUG: GenTest::App::GenTest::do_init: Additional initialization omitted.")
            if $debug_here;
    }
}

sub run {
    my $self = shift;

    $self->do_init();

    my $status;
    $status = $self->doGenData();
    return $status if $status != STATUS_OK;

    $status = $self->doGenTest();
    return $status;

}

################################

sub doGenTest {

    my $self = shift;

    my $who_am_i = "doGenTest:";

    my $status;

    $self->do_init();

    # Cache metadata and other info that may be needed later
    # ------------------------------------------------------
    # Observation 2020-07:
    # This might last quite long on some heavy loaded box.
    # Hence we do it now before computing when worker threads should start their activity.
    my @log_files_to_report;
    foreach my $i (0..2) {
        # FIXME:
        # IMHO MetaDataCaching for different servers is questionable.
        # 1. What will be the impact on the SQL executed on the different servers
        #    if the Metadata between these servers differ?
        # 2. When using MySQL/MariaDB builtin replication than omitting to cache Metadata on
        #    slave servers makes sense. But should that get triggered by some undef dsn?
        # Wouldn't be Metadata caching only on the first server better.
        # But we have also the view[0] ... view[3] etc
        last if $self->config->property('upgrade-test') and $i > 0;
        next unless $self->config->dsn->[$i];
        if ($self->config->property('ps-protocol') and
            $self->config->dsn->[$i] !~ /mysql_server_prepare/) {
            $self->config->dsn->[$i] .= ';mysql_server_prepare=1';
        }
        next if $self->config->dsn->[$i] !~ m{mysql}sio;
        my $metadata_executor = GenTest::Executor->newFromDSN($self->config->dsn->[$i],
                                                              osWindows() ? undef : $self->channel());
        $metadata_executor->setId($i + 1);
        $metadata_executor->setRole("MetaDataCacher");
        $metadata_executor->setTask(GenTest::Executor::EXECUTOR_TASK_CACHER);

        # For experimenting:
        # system ("killall -9 mysqld mariadbd");
        # sleep 5;
        $status = $metadata_executor->init();
        last if $status != STATUS_OK;

        # We have now an executor with all features like a connection etc.

        # For experimenting:
        # system ("killall -9 mysqld mariadbd");
        # sleep 5;
        $status = $metadata_executor->cacheMetaData();
        last if $status != STATUS_OK;


        # Cache log file names needed for result reporting at end-of-test
        # ---------------------------------------------------------------
        # We do not copy the general log, as it may grow very large for some tests.
        # my $logfile_result = $metadata_executor->execute("SHOW VARIABLES LIKE 'general_log_file'");
        # push(@log_files_to_report, $logfile_result->data()->[0]->[1]);

        my $query = "SHOW VARIABLES LIKE 'datadir'" ;
        # $metadata_executor->execute will
        # - decorate the query by prepending
        #   /* E_R <executor->role> QNO n CON_ID <executor->connectionId()> */
        # - also write the sql trace.

        # For experimenting:
        # system ("killall -9 mysqld mariadbd");
        # sleep 5;
        my $datadir_result = $metadata_executor->execute($query);
        $status = $datadir_result->status;
        last if $status != STATUS_OK;

        # Guessing the error log file name relative to datadir (lacking safer methods).
        my $errorlog;
        foreach my $errorlog_path (
            "../log/master.err",  # MTRv1 regular layout
            "../log/mysqld1.err", # MTRv2 regular layout
            "../mysql.err"        # DBServer::MySQL layout
        ) {
            my $possible_path = File::Spec->catfile($datadir_result->data()->[0]->[1],
                                                    $errorlog_path);
            if (-e $possible_path) {
                $errorlog = $possible_path;
                last;
            }
        }
        push(@log_files_to_report, $errorlog) if defined $errorlog;

        $metadata_executor->disconnect();
        undef $metadata_executor;
    }
    $status = $self->check_for_crash($status);
    return $status if $status != STATUS_OK;

    # Give 1.0s delay per worker/thread configured.
    # Impact:
    # 1. The reporting process has connected and all workers have connected + got their Mixer.
    #    Exception:
    #    The setup or server is "ill" and than STATUS_ENVIRONMENT_FAILURE would be right.
    # 2. Hereby we hopefully mostly avoid the often seen wrong status codes STATUS_ALARM/
    #    STATUS_ENVIRONMENT_FAILURE which are based on scenarios like
    #    Some threads connect, get their mixer, start to run DDL/DML and crash hereby the server.
    #    They all report STATUS_SERVER_CRASHED which is right.
    #    But the periodic reporting process or some other threads are slower (box is heavy loaded),
    #    try to connect first time after the crash, get no connection and report than
    #    STATUS_ENVIRONMENT_FAILURE because its their first connect attempt.

    $self->[GT_TEST_START] = time() + 1.0 * $self->config->threads;
    say("INFO: GenTest: (Planned) Start of running queries : " . $self->[GT_TEST_START] .
        " -- " . isoTimestamp($self->[GT_TEST_START]));
    $self->[GT_TEST_END] = $self->[GT_TEST_START] + $self->config->duration;

    $self->[GT_CHANNEL] = GenTest::IPC::Channel->new();

    # For experimenting:
    # system ("killall -9 mysqld mariadbd");
    # sleep 5;
    my $init_generator_result = $self->initGenerator();
    return $init_generator_result if $init_generator_result != STATUS_OK;
    # initGenerator does not connect hence check_for_crash makes no sense.

    # For experimenting:
    # system ("killall -9 mysqld mariadbd");
    # sleep 5;

    # We initialize here the reporters again.
    # Reason: They get now correct values for testStart and testEnd.
    $status = $self->initReporters();
    return $status if $status != STATUS_OK;
    # initReporters tries to connect!
    $status = $self->check_for_crash($status);
    return $status if $status != STATUS_OK;

    my $init_validators_result = $self->initValidators();
    # initValidators does not seem to connect.
    return $init_validators_result if $init_validators_result != STATUS_OK;

    if ($debug_here) {
        say("DEBUG: GenTest::App::GenTest::doGenTest: Reporters:    ->" .
            join("<->", @{$self->config->reporters})    . "<-\n"        .
            "DEBUG: GenTest::App::GenTest::doGenTest: Validators:   ->" .
            join("<->", @{$self->config->validators})   . "<-\n"        .
            "DEBUG: GenTest::App::GenTest::doGenTest: Transformers: ->" .
            join("<->", @{$self->config->transformers}) . "<-");
    }

    $self->[GT_LOG_FILES_TO_REPORT] = \@log_files_to_report;

    if (defined $self->config->filter) {
        # $self->[GT_QUERY_FILTERS] = [ GenTest::Filter::Regexp->new( file => $self->config->filter) ];
        my $result = GenTest::Filter::Regexp->new( file => $self->config->filter);
        if (defined $result) {
            $self->[GT_QUERY_FILTERS] = [ $result ];
        } else {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: $who_am_i " . Auxiliary::build_wrs($status));
            return $status;
        }
    }

    say("Starting " . $self->config->threads . " processes, " .
        $self->config->queries  . " queries each, duration " .
        $self->config->duration . " seconds.");

    # Disabled because
    # - executed even if unwanted/being not asked/...
    # - perl warnings about uninitialized variables in whatever XMLReport related code observed
    # - I do not use it and have also not the time to fix that.
    # $self->initXMLReport();

    ### Start central reporting thread ####
    my $errorfilter   = GenTest::ErrorFilter->new(channel => $self->channel());
    my $errorfilter_p = GenTest::IPC::Process->new(object => $errorfilter);
    if (!osWindows()) {
        $errorfilter_p->start($self->config->property('upgrade-test') ? [$self->config->servers->[0]] : $self->config->servers);
    }

    # For experimenting:
    # system ("killall -9 mysqld mariadbd");
    # sleep 5;
    my $reporter_pid = $self->reportingProcess();

    ### Start worker children ###
    my %worker_pids;   # Hash with pairs: OS pid -- Task of that process inside RQG.

    if ($self->config->threads > 0) {
        foreach my $worker_id (1..$self->config->threads) {
            my $worker_pid = $self->workerProcess($worker_id);
            $worker_pids{$worker_pid} = "Thread" . $worker_id;
        }
    }

    ### Main process
    if (osWindows()) {
        ## Important that this is done here in the parent after the last
        ## fork since on windows Process.pm uses threads
        $errorfilter_p->start();
    }

    ## Parent thread does not use channel
    $self->channel()->close;

    # We are the parent process, wait for for all spawned processes to terminate
    my $total_status   = STATUS_OK;
    my $total_status_t = STATUS_OK;
    my $total_status_r = STATUS_OK;
    my $reporter_died  = 0;
    OUTER: while (1) {
        # Worker & Reporter processes that were spawned.
        my @spawned_pids = (keys %worker_pids, $reporter_pid);

        # Wait for processes to complete, i.e only processes spawned by workers & reporters.
        foreach my $spawned_pid (@spawned_pids) {

            my $message_begin = "Process with pid $spawned_pid ";

            my ($reaped, $child_exit_status) = Auxiliary::reapChild($spawned_pid,
                                                                    $worker_pids{$spawned_pid});
            if (0 == $reaped) {
                if ($child_exit_status > STATUS_OK) {
                    say("INTERNAL ERROR: Inconsistency that child_exit_status $child_exit_status " .
                        "was got though process [$spawned_pid] was not reaped.");
                    return STATUS_INTERNAL_ERROR;
                } else {
                    next;
                }
            } else {
                $total_status = $child_exit_status if $child_exit_status > $total_status;
                my $message_end   = " ended with status " . status2text($child_exit_status);
                if ($spawned_pid == $reporter_pid ) {
                    $total_status_r = $child_exit_status if $child_exit_status > $total_status_r;
                    say($message_begin . "for periodic reporter" . $message_end);
                    # There is only exact one reporter process. So we leave the loop.
                    $reporter_died = 1;
                    say("DEBUG: GenTest: Therefore leaving the 'OUTER' loop.") if $debug_here;
                    last OUTER;
                } else {
                    $total_status_t = $child_exit_status if $child_exit_status > $total_status_t;
                    say($message_begin . "for " . $worker_pids{$spawned_pid} . $message_end);
                    delete $worker_pids{$spawned_pid};
                }
                last OUTER if $child_exit_status >= STATUS_CRITICAL_FAILURE;
                last OUTER if 0 == scalar (keys %worker_pids);
            }
        }
        sleep 5;
    }

    foreach my $worker_pid (keys %worker_pids) {
        say("Killing (TERM) remaining worker process with pid $worker_pid...");
        kill(15, $worker_pid);
    }
    # 1. The box might be under heavy load --> Delay in reaction on TERM
    # 2. The worker might be in whatever state and temporary or permanent not reactive.
    my $end_time = Time::HiRes::time() + 15;
    while ((0 < scalar (keys %worker_pids)) and ($end_time > Time::HiRes::time())) {
        foreach my $worker_pid (keys %worker_pids) {
            my $message_begin = "Process with pid $worker_pid ";
            my ($reaped, $child_exit_status) = Auxiliary::reapChild($worker_pid,
                                                                    $worker_pids{$worker_pid});
            if (0 == $reaped) {
                if ($child_exit_status > STATUS_OK) {
                    say("INTERNAL ERROR: Inconsistency that child_exit_status $child_exit_status " .
                        "was got though process [$worker_pid] was not reaped.");
                    return STATUS_INTERNAL_ERROR;
                } else {
                    next;
                }
            } else {
                # It is intentional to not touch $total_status at all.
                # Just one historic example which shows why:
                # The reporter Deadlock initiates that the server gets killed with core.
                # Some worker is affected by the no more responding server and exits here with 110.
                # And on the way which follows the knowledge about the intentional server kill
                # because of assumed Deadlock/Freeze gets lost.
                my $message_end   = " ended with status " . status2text($child_exit_status);
                say($message_begin . "for " . $worker_pids{$worker_pid} . $message_end);
                delete $worker_pids{$worker_pid};
            }
        }
        sleep 0.1;
    }
    foreach my $worker_pid (keys %worker_pids) {
        say("Killing (KILL) remaining worker processes with pid $worker_pid...");
        kill(9, $worker_pid);
    }

    if ($reporter_died == 0) {
        # Wait for periodic process to return the status of its last execution.
        # Observation 2020-07-20
        # 1. The process of the last worker thread exited with STATUS_OK.
        # 2. A monitoring round ended with GenTest::ReporterManager::monitor: Will return the (maximum) status 0
        # 3. I guess we were than leaving OUTER, no activity required for worker threads.
        # 4. 12:33:18 [18207] Killing periodic reporting process with pid 108110...
        #    12:33:18 [108110] ERROR: Reporter 'Deadlock': Actual test duration(548s) is more than ACTUAL_TEST_DURATION_EXCEED(240s) ....
        #    12:33:18 [108110] INFO: Reporter 'Deadlock': monitor... delivered status 0. == Connectable+Processlist content is OK!
        #    12:33:18 [108110] INFO: Reporter 'Deadlock': Killing mysqld with pid 22558 with SIGHUP in order to force debug output.
        # 5. 15s (value is now raised to 60) waiting for the Reporter 'Deadlock' to terminate.
        #    12:33:33 [18207] Kill GenTest::ErrorFilter(108108)
        #    12:33:33 [18207] INFO: GenTest: Effective duration in s : 563
        # 6. total_status is currently STATUS_OK (Deadlock has not yet finished)
        #    reportResults starts and SUCCESS reporter get used
        #    12:33:33 [18207] INFO: Reporter 'RestartConsistency': At begin of report.
        #    12:33:33 [18207] INFO: Reporter 'RestartConsistency': Dumping the server before restart
        #    12:33:35 [108110] INFO: Reporter 'Deadlock': Killing mysqld with pid 22558 with SIGSEGV in order to capture core.
        # 7. 12:33:54 [18207] ERROR: Reporter 'RestartConsistency': Dumping the server before restart failed with 768.
        #    == Collision of periodic reporter activity with SUCCESS/End reporter.
        #    12:33:54 [18207] ERROR: Reporter 'RestartConsistency': Dumping the database failed with status 110. Will return STATUS_CRITICAL_FAILURE
        #
        # Conclusions:
        # 1. ACTUAL_TEST_DURATION_EXCEED(240s) is at least for some grammars and the usual
        #    excessive load too small.
        # 2. Increase the waiting for termination of periodic reporting process to 60s.
        # 3. SIGKILL the periodic reporting process in case he does not react fast enough.

        # The big problem with the reporter Crashrecovery
        # Within the loop he calls killServer which might last a while if rr was invoked.
        # But it needs to be killServer and not just SIGKILL server pid followed by exit
        # with status.
        Time::HiRes::sleep(1);
        say("Killing (TERM) periodic reporting process with pid $reporter_pid...");
        kill(15, $reporter_pid);

        my $reaped = 0;
        my $reporter_status = STATUS_OK;
        my $end_time = Time::HiRes::time() + 60;
        while ($end_time > Time::HiRes::time()) {
            ($reaped, $reporter_status) = Auxiliary::reapChild($reporter_pid,
                                                               "Periodic reporting process");
            if (0 == $reaped) {
                if ($reporter_status > STATUS_OK) {
                    say("INTERNAL ERROR: Inconsistency that a reporter_status $reporter_status " .
                        "was got though process [$reporter_pid] was not reaped.");
                    return STATUS_INTERNAL_ERROR;
                } else {
                    # Process is running
                    sleep(1);
                    next;
                }
            } else {
                say("For pid $reporter_pid reporter status " . status2text($reporter_status));
                # FIXME: See also/join with reportResults
                # Some of the periodic reporters have capabilities to detect more precise than the
                # threads running YY grammar what the state of the test is.
                # But its too complicated to distill here something valuable.
                # Q1: Which reporter reported what?
                # Q2: What are the reliable capabilities of reporter X?
                # Q3: Had the reporter a chance to detect a maybe bad state or was his last run too
                #     long ago? STATUS_OK does not all time imply that the system state was good.
                #     Per observation 2018-09-28 it is not guaranteed that some periodic reporter
                #     must have detected that a server really (there was a core) crashed.
                # So we cannot refine anything here even if
                # - we get here STATUS_OK
                # - we get here STATUS_SERVER_CRASHED and the maximum status got from the threads is
                #   STATUS_CRITICAL_FAILURE (== Its bad but don't know + let the other decide)
                #      than already the usual "take the maximum" mechanism does what is required.
                #   STATUS_ALARM or STATUS_ENVIRONMENT_FAILURE are often also real server crashes
                #   but they get their special treatment "look if its a real crash" in reportResults.
                $total_status = $reporter_status if $reporter_status > $total_status;
                last;
            }
        }
        if (0 == $reaped) {
            say("Killing (KILL) periodic reporting process with pid $reporter_pid...");
            kill(9, $reporter_pid);
        }
    }

    $errorfilter_p->kill();

    # This is some vague value because
    # - it is not 100% ensured that all threads are gone
    # - even if all threads are gone than we had the overhead for stopping threads + reporters.
    # - it is the diff between current time and planned start time of the threads
    #   Given the fact that a reporter could run + detect a problem before the planned start time
    #   the diff could be negative. Than we need to assign the value 1 instead.
    # Nevertheless the values got
    # - seem to be surprising accurate
    # - do not include the time required by gdb for analysing cores.
    # So this time can be used for the duration adaption mechanism of the Simplifier.
    my $duration_to_report = time() - $self->[GT_TEST_START];
    $duration_to_report = 1 if $duration_to_report < 0;

    say("INFO: GenTest: Effective duration in s : $duration_to_report");

    return $self->reportResults($total_status);

} # End of sub doGenTest

################################

sub reportResults {
    my ($self, $total_status) = @_;

    my $reporter_manager = $self->reporterManager();
    my @report_results;

    # New report type REPORTER_TYPE_END, used with reporter's that processes information at the end of a test.
    if ($total_status == STATUS_OK) {
        @report_results = $reporter_manager->report(REPORTER_TYPE_SUCCESS | REPORTER_TYPE_ALWAYS | REPORTER_TYPE_END);
    } elsif (
        ($total_status == STATUS_LENGTH_MISMATCH) ||
        ($total_status == STATUS_CONTENT_MISMATCH)
    ) {
        @report_results = $reporter_manager->report(REPORTER_TYPE_DATA | REPORTER_TYPE_ALWAYS | REPORTER_TYPE_END);
    } elsif ($total_status == STATUS_SERVER_CRASHED) {
        say("Server crash reported, initiating post-crash analysis...");
        @report_results = $reporter_manager->report(REPORTER_TYPE_CRASH | REPORTER_TYPE_ALWAYS);
    } elsif ($total_status == STATUS_SERVER_DEADLOCKED) {
        say("Server deadlock reported, initiating analysis...");
        @report_results = $reporter_manager->report(REPORTER_TYPE_DEADLOCK | REPORTER_TYPE_ALWAYS | REPORTER_TYPE_END);
    } elsif ($total_status == STATUS_SERVER_KILLED) {
        say("Server killed intentional reported, initiating analysis...");
        # Making a backtrace from an rr trace is doable but makes most often no sense.
        # @report_results = $reporter_manager->report(REPORTER_TYPE_CRASH);
        @report_results = $reporter_manager->report(REPORTER_TYPE_SERVER_KILLED | REPORTER_TYPE_ALWAYS | REPORTER_TYPE_END);
    } elsif ($total_status == STATUS_ENVIRONMENT_FAILURE or
             $total_status == STATUS_CRITICAL_FAILURE    or
             $total_status == STATUS_ALARM                 ) {
        # A real server crash could come so early that the first connect attempt of some RQG worker
        # (Thread<n>) or some reporter fails. And than we would harvest STATUS_ENVIRONMENT_FAILURE
        # which is unfortunate because that value is higher than the better STATUS_SERVER_CRASHED
        # some other routine might report. As long as I am not 100% sure that this weakness is fixed
        # I call the crash reporters too in order to have at least the information if there was a crash
        # or not. This will not fix the problem that the RQG run will maybe? end finally with exit
        # status STATUS_ENVIRONMENT_FAILURE even if we had a real crash.
        # Another candidates are STATUS_ALARM and STATUS_CRITICAL_FAILURE which means rougly
        # "Its very bad but I do not know why" which is often a real crash too.
        say("total_status " . status2text($total_status) . " was reported, but often the reason " .
            "is a crash. So trying post-crash analysis...");
        @report_results = $reporter_manager->report(REPORTER_TYPE_CRASH | REPORTER_TYPE_ALWAYS | REPORTER_TYPE_END);
    } else {
        @report_results = $reporter_manager->report(REPORTER_TYPE_ALWAYS | REPORTER_TYPE_END);
    }

    my $report_status = shift @report_results;

    say("INFO: The reporters to be run at test end delivered status " .
        status2text($report_status) . "($report_status)");

    if ($report_status > $total_status) {
       say("DEBUG: GenTest::App::GenTest::reportResults: Raising the total status from " .
           "$total_status to $report_status.") if $debug_here;
       $total_status = $report_status;
    }

    my $report_status_name = status2text($report_status);
    my $total_status_name  = status2text($total_status);
    if (STATUS_SERVER_KILLED == $total_status) {
       say("INFO: The total status $total_status_name($total_status) means that there was an " .
           "intentional server kill. Therefore reducing the total status to STATUS_OK(0).");
       $total_status = STATUS_OK;
    } elsif (STATUS_SERVER_CRASHED == $report_status and STATUS_SERVER_DEADLOCKED == $total_status) {
       # Scenario is:
       # Reporter "Deadlock" detects server freeze --> crash server intentionally -->
       # exit with STATUS_SERVER_DEADLOCKED --> Backtrace or ServerDead run and report
       # STATUS_SERVER_CRASHED.
       # Hence we do nothing.
    } elsif (STATUS_SERVER_CRASHED == $report_status and STATUS_SERVER_CRASHED != $total_status) {
       say("INFO: The reporter status $report_status_name($report_status) is more reliable.");
       say("INFO: Therefore setting the total status from $total_status_name($total_status) to " .
           "$report_status_name($report_status).");
       $total_status = STATUS_SERVER_CRASHED;
    } elsif ((STATUS_OK == $report_status or STATUS_CRITICAL_FAILURE == $report_status)
             and STATUS_SERVER_CRASHED == $total_status) {
       say("INFO: The reporter status $report_status_name($report_status) is more reliable " .
           "and does not claim a server crash.");
       say("INFO: Therefore reducing the total status from $total_status_name($total_status) to " .
           status2text(STATUS_CRITICAL_FAILURE) . "(" . STATUS_CRITICAL_FAILURE . ")");
       $total_status = STATUS_CRITICAL_FAILURE;
    }

    # FIXME:
    # Maybe check if the status is bad and if yes use logFilesToReport and dump all server error
    # logs mentioned there instead of dumping error logs of all time present servers in reporters
    # or similar.
    # Advantage:
    # - More information for bwlist search in the RQG log.
    # - Less frequent duplicate information.
    # Printing a lot in case of error should be ok but would be bad if having no error.
    # Disadvantage:
    # In case a test causes damage intentionally, the server laments from good reason but the
    # lamenting is interpreted as unexpected bad effect than we get maybe false alarms.

    # Disabled because
    # - executed even if unwanted/being not asked/...
    # - perl warnings about uninitialized variables in whatever XMLReport related code observed
    # - I do not use it and have also not the time to fix that.
    # $self->reportXMLIncidents($total_status, \@report_results);


    if ($total_status == STATUS_OK) {
        say("Test completed successfully.");
        return STATUS_OK;
    } else {
        say("Test completed with failure status " .
            status2text($total_status) . " ($total_status)");
        return $total_status;
    }
}

sub stopChild {
# FIXME:
# Correct the wording if time permits.
# a) The parent process has sent the TERM signal to the current process.
#    And the current process has received that, calls the current sub and exits.
# b) The child process itself has met some state which is bad + exit recommended.
# c) The amount of work limited by queries, duration, ... is done.

    my ($self, $status) = @_;

    if (not defined $status) {
        Carp::cluck("INTERNAL ERROR: stopChild was called with undefined status.");
        say("INTERNAL ERROR: Will set status to STATUS_INTERNAL_ERROR.");
        $status = STATUS_INTERNAL_ERROR;
    }
    say("GenTest: child $$ is being stopped with status " . status2text($status));

    if (osWindows()) {
        exit $status;
    } else {
        safe_exit($status);
    }
}

sub reportingProcess {
    my $self = shift;

    my $reporter_pid = fork();
    # FIXME: This can fail!

    if ($reporter_pid != 0) {
        # We are the parent.
        return $reporter_pid;
    }

    $| = 1;
    my $reporter_killed = 0;
    local $SIG{TERM} = sub { $reporter_killed = 1 };

    ## Reporter process does not use channel
    $self->channel()->close();

    # FIXME:
    # Earlier $self->[GT_TEST_START] = time() + number of threads.
    # The worker threads get forked after the parent process returned from the current sub.
    # These worker than connect (abort if getting no connection), run some 'harmless' SQL and wait
    # till $self->[GT_TEST_START] before running their more or less 'dangerous' YY grammar SQL.
    # So the wait till $self->[GT_TEST_START] should ensure that all worker threads have made
    # their required preparations + never throw STATUS_ENVIRONMENT_FAILURE if losing that
    # connection later.
    # The sleep which follows here ensures roughly that the threads have started YY grammar SQL
    # before the periodic reporters become active first time.
    # But is that of any importance?
    Time::HiRes::sleep(($self->config->threads + 1) / 10);
    say("INFO: Periodic reporting process at begin of activity");

    my $previous_status = STATUS_OK;
    my $status          = STATUS_OK;
    while (1) {
        $status = $self->reporterManager()->monitor(REPORTER_TYPE_PERIODIC);
        # It looks as if sending TERM to the periodic reporting process is capable to affect
        # what a reporter is currently doing and hereby the status finally reported.
        # In case that is true than the status could be a false positive like most probably the
        # following example observed 2019-10:
        #   [338151] Killing periodic reporting process with pid 339348...
        #   [339348] ERROR: Reporter 'Deadlock': The connect attempt to dsn ... failed:
        #            Lost connection to MySQL server at 'waiting for initial communication packet'..
        #   [339348] ERROR: Reporter 'Deadlock': Will return status 101.
        #       IMHO STATUS_SERVER_DEADLOCKED would be also thinkable.
        #   [339348] ERROR: Periodic reporting process: Critical status STATUS_SERVER_CRASHED got...
        #   [339348] GenTest: child 339348 is being stopped with status STATUS_SERVER_CRASHED
        #       The timespan between the messages is <= 1s.
        #       But the server process was running and the server error log entries looked harmless.
        # So we need to check $reporter_killed first and maybe return the previous status.
        if ($reporter_killed == 1) {
            $status = $previous_status;
            say("INFO: Periodic reporting process: Signal TERM received. Status of last reporter " .
                "might be invalid. Will exit with previous status " . status2text($status));
            last;
        } else {
            if ($status >= STATUS_CRITICAL_FAILURE) {
                say("ERROR: Periodic reporting process: Critical status " .
                    status2text($status) . " got. Will exit with that.");
                last;
            } else {
                # The reporter will have already reported the problem if any.
                $previous_status = $status;
            }
        }
        sleep(10);
    }

    $self->stopChild($status);
}

sub workerProcess {
    my ($self, $worker_id) = @_;

    my $worker_pid = fork();
    # FIXME: That fork can fail!

    $self->channel()->writer;

    if ($worker_pid != 0) {
        return $worker_pid;
    }
    my $worker_role = "Thread" . $worker_id;

    $| = 1;
    my $ctrl_c = 0;
    local $SIG{INT} = sub { $ctrl_c = 1 };

    $self->generator()->setSeed($self->config->seed() + $worker_id);
    $self->generator()->setThreadId($worker_id);

    my @executors;
    foreach my $i (0..2) {
        last if $self->config->property('upgrade-test') and $i>0;
        next unless $self->config->dsn->[$i];
        my $executor = GenTest::Executor->newFromDSN($self->config->dsn->[$i],
                                                     osWindows() ? undef : $self->channel());
        $executor->sqltrace($self->config->sqltrace);
        $executor->setId($i+1);
        $executor->setRole($worker_role);
        $executor->setTask(GenTest::Executor::EXECUTOR_TASK_THREAD);
        push @executors, $executor;
    }

    my $mixer = GenTest::Mixer->new(
        generator => $self->generator(),
        executors => \@executors,
        validators => $self->config->validators,
        properties =>  $self->config,
        filters => $self->queryFilters(),
        end_time => $self->[GT_TEST_END],
        restart_timeout => $self->config->property('restart-timeout'),
        role => $worker_role
    );

    if (not defined $mixer) {
        sayError("GenTest failed to create a Mixer for $worker_role. " .
                 "Status will be set to ENVIRONMENT_FAILURE");
        # Hint: stopChild exits
        $self->stopChild(STATUS_ENVIRONMENT_FAILURE);
    }

   while (time() < $self->[GT_TEST_START]) {
      sleep 1;
   }

   my $worker_result = 0;

   foreach my $i (1..$self->config->queries) {
      my $query_result = $mixer->next();
      $worker_result = $query_result if $query_result > $worker_result && $query_result > STATUS_TEST_FAILURE;

      if ($query_result >= STATUS_CRITICAL_FAILURE) {
         say("GenTest: Server crash or critical failure (" . status2text($query_result) .
             ") was reported.\n" .
             "         The child process for $worker_role will be stopped.");
         undef $mixer;   # so that destructors are called
         $self->stopChild($query_result);
      }

      last if $query_result == STATUS_EOF;
      last if $ctrl_c == 1;
      last if time() > $self->[GT_TEST_END];
   }

   foreach my $executor (@executors) {
      $executor->disconnect;
      undef $executor;
   }

   # Forcefully deallocate the Mixer so that Validator destructors are called
   undef $mixer;
   undef $self->[GT_QUERY_FILTERS];

   my $message_part= "INFO: GenTest: Child process for $worker_role completed";
   if ($worker_result > 0) {
      say("$message_part with status " . status2text($worker_result) . "($worker_result).");
      $self->stopChild($worker_result);
   } else {
      say("$message_part successfully.");
      $self->stopChild(STATUS_OK);
   }
}

sub doGenData {
    my $self = shift;

    my $who_am_i = "GenTest::App::GenTest::doGenData:";

    $self->do_init();
    # Hint:
    # $self->do_init also preloads the reporters.
    # Hence we can use some of them like Backtrace in case of GenData fails.

    return STATUS_OK if defined $self->config->property('start-dirty');


    say("INFO: $who_am_i Begin of activity");
    my $gendata_result = STATUS_OK;
    my $i = 0;
    # my $i = -1; The server numbers reported should be 1 2 3 ...
    foreach my $dsn (@{$self->config->dsn}) {
        $i++;
        if ($self->config->property('upgrade-test') and $i > 1) {
            say("INFO: $who_am_i Omitting whatever Gendata on the non first server because its " .
                "an 'upgrade-test'.");
            last;
        }
        # Avoid Gendata on slave server in replication.
        next unless $dsn;
        if (defined $self->config->property('gendata-advanced')) {
            $gendata_result = GenTest::App::GendataAdvanced->new(
               dsn                  => $dsn,
               vcols                => (defined $self->config->property('vcols') ?
                                              ${$self->config->property('vcols')}[$i] : undef),
               views                => (defined $self->config->views ?
                                              ${$self->config->views}[$i] : undef),
               engine               => (defined $self->config->engine ?
                                              ${$self->config->engine}[$i] : undef),
               sqltrace             => $self->config->sqltrace,
               server_id            => $i,
               notnull              => $self->config->notnull,
               rows                 => $self->config->rows,
               varchar_length       => $self->config->property('varchar-length')
            )->run();
        }
        last if STATUS_OK != $gendata_result;

        # Original code:
        # next if not defined $self->config->gendata();
        last if not defined $self->config->gendata();

        say("DEBUG: $who_am_i self->config->gendata : ->" .
            $self->config->gendata . "<-") if $debug_here;

        if ($self->config->gendata eq '' or $self->config->gendata eq '1') {
            $gendata_result = GenTest::App::GendataSimple->new(
               dsn                  => $dsn,
               vcols                => (defined $self->config->property('vcols') ?
                                              ${$self->config->property('vcols')}[$i] : undef),
               views                => (defined $self->config->views ?
                                              ${$self->config->views}[$i] : undef),
               engine               => (defined $self->config->engine ?
                                              ${$self->config->engine}[$i] : undef),
               sqltrace             => $self->config->sqltrace,
               server_id            => $i,
               notnull              => $self->config->notnull,
               rows                 => $self->config->rows,
               varchar_length       => $self->config->property('varchar-length')
            )->run();
        } elsif ($self->config->gendata() eq 'None') {
            # Do nothing
        } elsif ($self->config->gendata()) {
            # For experimenting:
            # system("killall -9 mysqld mariadbd");
            # sleep 5;
            $gendata_result = GenTest::App::Gendata->new(
               spec_file            => $self->config->gendata,
               dsn                  => $dsn,
               engine               => (defined $self->config->engine ?
                                              ${$self->config->engine}[$i] : undef),
               seed                 => $self->config->seed(),
               debug                => $self->config->debug,
               rows                 => $self->config->rows,
               views                => (defined $self->config->views ?
                                              ${$self->config->views}[$i] : undef),
               varchar_length       => $self->config->property('varchar-length'),
               sqltrace             => $self->config->sqltrace,
               server_id            => $i,
               short_column_names   => $self->config->short_column_names,
               strict_fields        => $self->config->strict_fields,
               notnull              => $self->config->notnull
            )->run();
        }
        last if STATUS_OK != $gendata_result;

        # For experimenting:
        # system("killall -9 mysqld mariadbd");
        # sleep 5;

        if ( $self->config->gendata_sql ) {
            # $self->config->gendata_sql might be just a string containing one file name
            # or a list of comma separated file names.
            # Transform it to an array with one element.
            if ( not ref $self->config->gendata_sql eq 'ARRAY' ) {
                my $gendata_sql = [ split /,/, $self->config->gendata_sql ];
                $self->config->gendata_sql($gendata_sql);
            }
            # In case of missing file rather abort before
            # - running any script processing at all (Scenario: The previous files exist.)
            # - creating an Executor etc. (Scenario: The current file does not exist.)
            foreach my $file ( @{$self->config->gendata_sql} )
            {
               if ( not -e $file ) {
                   $gendata_result = STATUS_ENVIRONMENT_FAILURE;
                   say("ERROR: lib::GenTest::App::GenTest::doGenData : The SQL file '$file' " .
                       "does not exist.");
                   say("ERROR: " . Auxiliary::build_wrs($gendata_result));
                   last;
               }
            }
            last if STATUS_OK != $gendata_result;
            foreach my $file ( @{$self->config->gendata_sql} )
            {
               say("INFO: $who_am_i Start processing the SQL file '$file'.");
               $gendata_result = GenTest::App::GendataSQL->new(
                    sql_file        => $file,
                    debug           => $self->config->debug,
                    dsn             => $dsn,
                    server_id       => $i, # 'server_id'   => GDS_SERVER_ID,
                    sqltrace        => $self->config->sqltrace,
               )->run();
               last if STATUS_OK != $gendata_result;
            }
        }
        last if STATUS_OK != $gendata_result;

        # For multi-master setup, e.g. Galera, we only need to do generation once
        # Original code:
        # return STATUS_OK if $self->config->property('multi-master');
        last if $self->config->property('multi-master');
    }

    $gendata_result = $self->check_for_crash($gendata_result);

    say("INFO: End of GenData activity");
    return $gendata_result;

} # End of sub doGenData

sub initSeed {
    my $self = shift;

    return if not defined $self->config->seed();

    my $orig_seed = $self->config->seed();
    my $new_seed;

    if ($orig_seed eq 'time') {
        $new_seed = time();
    } elsif ($self->config->seed() eq 'epoch5') {
        $new_seed = time() % 100000;
    } elsif ($self->config->seed() eq 'random') {
        $new_seed = int(rand(32767));
    } else {
        $new_seed = $orig_seed;
    }

    if ($new_seed ne $orig_seed) {
        say("Converting --seed=$orig_seed to --seed=$new_seed");
        $self->config->property('seed', $new_seed);
    }
}

sub initGenerator {
    my $self = shift;

    my $generator_name = "GenTest::Generator::".$self->config->generator;
    say("Loading Generator '$generator_name'.") if rqg_debug();
    # For testing:
    # $generator_name = "Monkey";
    eval("use $generator_name");
    if ('' ne $@) {
        say("ERROR: initGenerator : Loading Generator '$generator_name' failed : $@. Status will " .
            "be set to ENVIRONMENT_FAILURE");
        return STATUS_ENVIRONMENT_FAILURE;
    }

    if ($self->config->redefine and not ref $self->config->redefine eq 'ARRAY') {
        my $redefines= [ split /,/, $self->config->redefine ];
        $self->config->redefine($redefines);
    }

    if ($generator_name eq 'GenTest::Generator::FromGrammar') {
        if (not defined $self->config->grammar) {
            sayError("Grammar not specified but Generator is $generator_name, status will be " .
                     "set to ENVIRONMENT_FAILURE");
            return STATUS_ENVIRONMENT_FAILURE;
        }

        $self->[GT_GRAMMAR] = GenTest::Grammar->new(
            grammar_files => [ $self->config->grammar,
                               ( $self->config->redefine ? @{$self->config->redefine} : () ) ],
            grammar_flags => (defined $self->config->property('skip-recursive-rules') ?
                              GenTest::Grammar::GRAMMAR_FLAG_SKIP_RECURSIVE_RULES : undef )
        ) if defined $self->config->grammar;

        if (not defined $self->grammar()) {
            sayError("Could not initialize the grammar, status will be set to ENVIRONMENT_FAILURE");
            return STATUS_ENVIRONMENT_FAILURE;
        }

        if (not defined $self->grammar()) {
            sayError("Could not redefine the grammar, status will be set to ENVIRONMENT_FAILURE");
            return STATUS_ENVIRONMENT_FAILURE;
        }
    }

    $self->[GT_GENERATOR] = $generator_name->new(
        grammar => $self->grammar(),
        varchar_length => $self->config->property('varchar-length'),
        mask => $self->config->mask,
        mask_level => $self->config->property('mask-level'),
        annotate_rules => $self->config->property('annotate-rules')
    );

    if (not defined $self->generator()) {
        sayError("Could not initialize the generator, status will be set to ENVIRONMENT_FAILURE");
        return STATUS_ENVIRONMENT_FAILURE;
    }
}

sub isMySQLCompatible {
    my $self = shift;

    my $is_mysql_compatible = 1;

    foreach my $i (0..2) {
        next if (not defined $self->config->dsn->[$i] or $self->config->dsn->[$i] eq '');
        $is_mysql_compatible = 0 if ($self->config->dsn->[$i] !~ m{mysql|drizzle}sio);
    }
    return $is_mysql_compatible;
}


sub initReporters {
# Meaning of a reporter named 'None'
# ----------------------------------
# Example:
# --reporters=A,B        Add D because of whatever other property.
# --reporters=A,None,B   Do NOT add D of whatever other property.
#
# Why not preventing multiple init of the same reporter?
# ------------------------------------------------------
# We initialize all reporters usually at gendata.
# Unfortunately some of them have a parameter telling when they should kick in
#    Example: CrashRecovery* -- When to kill the DB server
# and that can only have some undef value around gendata.
# During gentest the required value is known but the reporter is already loaded and
# so the value inside of the reporter stays undef. And so we would harvest some perl warning
# because of uninitialized value including a malfunction of the reporter.
# I am looking for some better solution than the multiple inits.
#

    my $self = shift;

    # Initialize the array to avoid further checks on its existence
    if (not defined $self->config->reporters or $#{$self->config->reporters} < 0) {
        $self->config->reporters([]);
    }
    my @reporter_array;
    my %reporter_hash;
    my $array_ref;
    my $hash_ref;
    ($array_ref, $hash_ref) = Auxiliary::unify_rvt_array($self->config->reporters);
    @reporter_array = @{$array_ref};
    %reporter_hash  = %{$hash_ref};

    say("DEBUG: GenTest::App::GenTest::initReporters: Reporters (before check_and_set): ->" .
        join("<->", sort keys %reporter_hash) . "<-") if $debug_here;

    # If one of the reporters is 'None' than don't add any reporters automatically.
    my $no_reporters;
    if (exists $reporter_hash{'None'}) {
        $no_reporters = 1;
    } else {
        $no_reporters = 0;
    }
    say("DEBUG: GenTest::App::GenTest::initReporters: no_reporters : $no_reporters") if $debug_here;

    if (not $no_reporters) {
        if ($self->isMySQLCompatible()) {
            $reporter_hash{'ErrorLog'}   = 1;
            $reporter_hash{'Backtrace'}  = 1;
            if (defined $self->config->property('valgrind-xml')) {
                $reporter_hash{'ValgrindXMLErrors'} = 1;
            }
            my $rpl_mode = $self->config->rpl_mode;
            if (($rpl_mode eq Auxiliary::RQG_RPL_STATEMENT)        or
                ($rpl_mode eq Auxiliary::RQG_RPL_STATEMENT_NOSYNC) or
                ($rpl_mode eq Auxiliary::RQG_RPL_MIXED)            or
                ($rpl_mode eq Auxiliary::RQG_RPL_MIXED_NOSYNC)     or
                ($rpl_mode eq Auxiliary::RQG_RPL_ROW)              or
                ($rpl_mode eq Auxiliary::RQG_RPL_ROW_NOSYNC)         ) {
                # We run MariaDB/MySQL replication.
                $reporter_hash{'ReplicationSlaveStatus'} = 1;
                if (($rpl_mode eq Auxiliary::RQG_RPL_STATEMENT) or
                    ($rpl_mode eq Auxiliary::RQG_RPL_MIXED)     or
                    ($rpl_mode eq Auxiliary::RQG_RPL_ROW)         ) {
                    # Its synchronous replication.
                    $reporter_hash{'ReplicationConsistency'} = 1;
                }
            }
        }
        if ($self->config->property('upgrade-test') and
            $self->config->property('upgrade-test') =~ /undo/) {
            $reporter_hash{'UpgradeUndoLogs'} = 1;
        } elsif ($self->config->property('upgrade-test')) {
            $reporter_hash{'Upgrade1'} = 1;
        } else {
            if (exists $reporter_hash{'Upgrade'}) {
                say("WARNING: Upgrade reporter is requested, but --upgrade-test option is " .
                        "not set, the behavior is undefined");
            }
        }
        $reporter_hash{'None'} = 1;
    }
    say("Reporters (for Simplifier): ->" . join("<->", sort keys %reporter_hash) . "<-");
    @{$self->config->reporters} = sort keys %reporter_hash;
    say("DEBUG: GenTest::App::GenTest::initReporters: Reporters (after check_and_set): ->" .
        join("<->", @{$self->config->reporters}) . "<-") if $debug_here;

    my $reporter_manager = GenTest::ReporterManager->new();

    # pass option debug server to the reporter, for detecting the binary type.
    foreach my $i (0..2) {
        last if $self->config->property('upgrade-test') and $i > 0;
        next unless $self->config->dsn->[$i];
        foreach my $reporter (@{$self->config->reporters}) {
            # The reporter 'None' is used as switch if to extend the amount of reporters or not.
            # But its no real reporter and a file with that name also does not exist.
            # Hence we omit the attempt to load it.
            next if 'None' eq $reporter;
            my $add_result = $reporter_manager->addReporter($reporter, {
                dsn             => $self->config->dsn->[$i],
                test_start      => $self->[GT_TEST_START],
                test_end        => $self->[GT_TEST_END],
                test_duration   => $self->config->duration,
                debug_server    => (defined $self->config->debug_server ?
                                       ${$self->config->debug_server}[$i] : undef),
                properties      => $self->config
            });
            return $add_result if $add_result > STATUS_OK;
        }
    }

    $self->[GT_REPORTER_MANAGER] = $reporter_manager;
    return STATUS_OK;
}

sub initValidators {
    my $self = shift;

    if (not defined $self->config->validators or $#{$self->config->validators} < 0) {
        $self->config->validators([]);
    }
    my @validator_array;
    my %validator_hash;
    my $array_ref;
    my $hash_ref;
    ($array_ref, $hash_ref) = Auxiliary::unify_rvt_array($self->config->validators);
    @validator_array = @{$array_ref};
    %validator_hash  = %{$hash_ref};

    say("DEBUG: GenTest::App::GenTest::initValidators: Validators (before check_and_set): ->" .
        join("<->", sort keys %validator_hash) . "<-") if $debug_here;

    # If one of the validators is 'None' than don't add any validators automatically.
    my $no_validators;
    if (exists $validator_hash{'None'}) {
        $no_validators = 1;
    } else {
        $no_validators = 0;
    }
    say("DEBUG: GenTest::App::GenTest::initValidators: no_validators : $no_validators")
        if $debug_here;

    if (not $no_validators) {

        # In case of multi-master topology (e.g. Galera with multiple "masters"),
        # we don't want to compare results after each query.
        unless ($self->config->property('multi-master')) {
            if (defined $self->config->dsn->[2] and $self->config->dsn->[2] ne '') {
                $validator_hash{'ResultsetComparator3'} = 1;
            } elsif (defined $self->config->dsn->[1] and $self->config->dsn->[1] ne '') {
                $validator_hash{'ResultsetComparator'} = 1;
            }
        }

        $validator_hash{'MarkErrorLog'} = 1
            if (defined $self->config->valgrind) && $self->isMySQLCompatible();

        $validator_hash{'QueryProperties'} = 1
            if defined $self->grammar() && $self->grammar()->hasProperties() &&
                $self->isMySQLCompatible();

    }

    if (not defined $self->config->transformers or $#{$self->config->transformers} < 0) {
        $self->config->transformers([]);
    }
    my @transformer_array;
    my %transformer_hash;
    ($array_ref, $hash_ref) = Auxiliary::unify_rvt_array($self->config->transformers);
    @transformer_array      = @{$array_ref};
    %transformer_hash       = %{$hash_ref};

    say("DEBUG: GenTest::App::GenTest::initValidators: Transformers (before check_and_set): ->" .
        join("<->", sort keys %transformer_hash) . "<-") if $debug_here;

    if (exists $transformer_hash{'None'}) {
        say("ERROR: The Transformer 'None' is not supported in the current RQG core. Abort");
        return STATUS_ENVIRONMENT_FAILURE;
    }

    if (not $no_validators) {
        if (0 != scalar keys %transformer_hash) {
            my $hasTransformer = 0;
            foreach my $t (keys %validator_hash) {
                if ($t =~ /^Transformer/) {
                    $hasTransformer = 1;
                    last;
                }
            }
            $validator_hash{'Transformer'} = 1 if !$hasTransformer;
        }
    }

    $validator_hash{'None'} = 1;
    say("Validators (for Simplifier): ->" . join("<->", sort keys %validator_hash) . "<-");
    delete $validator_hash{'None'};
    @{$self->config->validators} = sort keys %validator_hash;
    say("DEBUG: GenTest::App::GenTest::initValidators: Validators (after check_and_set): ->" .
        join("<->", @{$self->config->validators}) . "<-") if $debug_here;

    # For testing/debugging
    # push @{$self->config->validators}, 'Huhu';

    # FIXME:
    # Using RQG's own replication + validator and transformer or not just 'None'
    # --> The validators ResultsetComparator and Transformer get added.
    #     And this is already visible here.
    # But when the validator 'Transformer' gets loaded we get a crowd of transformers in addition.
#   $transformer_hash{'None'} = 1;
#   say("Transformers (for Simplifier): ->" . join("<->", sort keys %transformer_hash) . "<-");
#   delete $transformer_hash{'None'};
#   @{$self->config->transformers} = sort keys %transformer_hash;
#   say("DEBUG: Transformers (after check_and_set): ->" . join("<->",
#       @{$self->config->transformers}) . "<-");

    return STATUS_OK;
}

sub copyLogFiles {
    my ($self, $logdir, $dsns) = @_;
    ## Do this only when tt-logging is enabled
    if (-e $self->config->property('report-tt-logdir')) {
        mkpath($logdir) if ! -e $logdir;

        # copy database logs
        foreach my $filename ($self->logFilesToReport()) {
            copyFileToDir($filename, $logdir);
        }
        # copy RQG log
        copyFileToDir($self->config->logfile, $logdir);
    }
}

sub copyFileToDir {
    my ($from, $todir) = @_;
    say("Copying '$from' to '$todir'");
    copy($from, $todir);
}


sub initXMLReport {
    my $self = shift;

    my $buildinfo;
    if (defined $self->config->property('xml-output')) {
        $buildinfo = GenTest::XML::BuildInfo->new(
            dsns => $self->config->dsn
        );
    }

    # XML:
    #  Define test suite name for reporting purposes.
    #  Until we support test suites and/or reports with multiple suites/tests,
    #  we use the test name as test suite name, from config option "testname".
    #  Default test name is the basename portion of the grammar file name.
    #  If a grammar file is not given, the default is "rqg_no_name".
    my $test_suite_name = $self->config->testname;
    if (not defined $test_suite_name) {
        if (defined $self->config->grammar) {
            $test_suite_name = basename($self->config->grammar, '.yy');
        } else {
            $test_suite_name = "rqg_no_name";
        }
    }

    # The XML stuff should rather only run if logdir is defined.
    if (defined $self->config->property('report-tt-logdir')) {
        $self->[GT_XML_TEST] = GenTest::XML::Test->new(
            id => time(),
            name => $test_suite_name,  # NOTE: Consider changing to test (or test case) name when suites are supported.
            logdir => $self->config->property('report-tt-logdir').'/'.$test_suite_name.isoUTCSimpleTimestamp,
            attributes => {
            engine => $self->config->engine,
            gendata => $self->config->gendata,
            grammar => $self->config->grammar,
            threads => $self->config->threads,
            queries => $self->config->queries,
            validators => ($self->config->validators ? join (',', @{$self->config->validators}) : ''),
            reporters => ($self->config->reporters ? join (',', @{$self->config->reporters}) : ''),
            seed => $self->config->seed,
            mask => $self->config->mask,
            mask_level => $self->config->property('mask-level'),
            rows => $self->config->rows,
            'varchar-length' => $self->config->property('varchar-length')
            }
        );
        $self->[GT_XML_REPORT] = GenTest::XML::Report->new(
            buildinfo => $buildinfo,
            name => $test_suite_name,  # NOTE: name here refers to the name of the test suite or "test".
            tests => [  $self->XMLTest() ]
        );
    }
}

sub reportXMLIncidents {
    my ($self, $total_status, $incidents) = @_;

    foreach my $incident (@$incidents) {
        $self->XMLTest()->addIncident($incident);
    }

    # If no Reporters reported an incident, and we have a test failure,
    # create an incident report and add it to the test report.
    if ((scalar(@$incidents) < 1) && ($total_status != STATUS_OK)) {
        my $unreported_incident = GenTest::Incident->new(
            result      => 'fail',   # can we have other results as incidents?
            description => 'Non-zero status code from RQG test run',
            signature   => 'Exit status '.$total_status # better than nothing?
        );
        # Add the incident to the test report
        $self->XMLTest()->addIncident($unreported_incident);
    }

    $self->XMLTest()->end($total_status == STATUS_OK ? "pass" : "fail");

    if (defined $self->config->property('xml-output')) {
        open (XML , '>'.$self->config->property('xml-output'))
            or carp("Unable to open ".$self->config->property('xml-output').": $!");
        print XML $self->XMLReport()->xml();
        close XML;
        say("XML report written to ". $self->config->property('xml-output'));
    }

    # XML Result reporting to Test Tool (TT).
    # Currently both --xml-output=<filename> and --report-xml-tt must be
    # set to trigger this.
    if (defined $self->config->property('report-xml-tt')) {
        my $xml_transporter = GenTest::XML::Transporter->new(
            type => $self->config->property('report-xml-tt-type')
        );

        # If xml-output option is not set, bail out. TODO: Make xml-output optional.
        if (not defined $self->config->property('xml-output')) {
            carp("ERROR: --xml-output=<filename> must be set when using --report-xml-tt");
        }

        my $xml_send_result = $xml_transporter->sendXML(
            $self->config->property('xml-output'),
            $self->config->property('report-xml-tt-dest')
        );

        if ($xml_send_result != STATUS_OK) {
            croak("Error from XML Transporter: $xml_send_result");
        }

        if (defined $self->config->logfile && defined
            $self->config->property('report-tt-logdir')) {
            $self->copyLogFiles($self->XMLTest->logdir(), $self->config->dsn);
        }
    }
}


sub check_for_crash {
# Purpose:
# In case a non final phase of the work flow invoked connecting and achieved some
# status != STATUS_OK than try to run some automatic analysis checking if its a crash.
# Goal: Generate a backtrace even if crashing before the final phase genTest etc.
#       Be able to exploit that result for making some more qualified verdict.
# We just use for that existing and future reporters.
#
    my ($self, $status) = @_;

    my $who_am_i = "GenTest::GenTest::check_for_crash:";
    my $final_status =  STATUS_INTERNAL_ERROR;
    my $reporter_manager = $self->reporterManager();
    my @report_results;

    if      ($status == STATUS_OK) {
        $final_status =  $status;
    } elsif ($status == STATUS_SERVER_KILLED) {
        $final_status = STATUS_INTERNAL_ERROR;
        say("INTERNAL_ERROR: $who_am_i The current status " . status2text($status) .
            "($status) means that there was an intentional server kill.");
        say("INTERNAL_ERROR: $who_am_i This must never happen in the previous work phases. " .
            "Will return status " .  status2text($final_status) . "($final_status).");
    } elsif ($status == STATUS_SERVER_CRASHED      or
             $status == STATUS_ENVIRONMENT_FAILURE or
             $status == STATUS_CRITICAL_FAILURE    or
             $status == STATUS_ALARM                 ) {

####         is_connectable(EXECUTOR)

        # $status per previous | $report_status | $final_status
        # work phases          | backtrace      |
        # ---------------------+----------------+-----------------------
        # val < SCF(100)       | no check       | val
        # ---------------------+----------------+-----------------------
        # SCF(100)             | SO(0)          | SCF(100)
        # SSC(101)             | SO(0)          | SCF(100)
        # SSK(102)             | no check       | SIE(200)
        # SSE/SA(110)          | SO(0)          | SSE/SA(110)
        # SIE(200)             | no check       | SIE(200)
        # ---------------------+----------------+-----------------------
        # SCF(100)             | SSC(101)       | SSC(101)
        # SSC(101)             | SSC(101)       | SSC(101)
        # SSE/SA(110)          | SSC(101)       | SSC(101)
        # ---------------------+----------------+-----------------------
        # SCF(100)             | SSE/SA(110)    | SIE(200)
        # SSC(101)             | SSE/SA(110)    | SIE(200)
        # SSE/SA(110)          | SSE/SA(110)    | SIE(200)
        # ---------------------+----------------+-----------------------
        # val not handled /\   | no check       | val
        #
        # All these not that specific statuses might be caused by a crashed server or similar.
        say("INFO: $who_am_i The current status is " . status2text($status) . "($status). " .
            "Trying to confirm and/or refine information by post-crash analysis...");
        @report_results = $reporter_manager->report(REPORTER_TYPE_CRASH);
        my $report_status = shift @report_results;
        say("INFO: $who_am_i The corresponding reporters delivered status $report_status.");
        if ($report_status == $status) {
            # Do nothing special.
            $final_status = $status;
        } elsif ($report_status == STATUS_SERVER_CRASHED) {
            $final_status = $report_status;
            say("INFO: $who_am_i The reporter status $report_status is more reliable. " .
                "Will return status " . status2text($final_status) . "($final_status).");
        } elsif ($report_status == STATUS_OK) {
            $final_status = $status;
            if ($status == STATUS_SERVER_CRASHED) {
                $final_status =  STATUS_CRITICAL_FAILURE;
                say("INFO: $who_am_i Its obviously not a crash. " .
                    "Will return status " . status2text($final_status) . "($final_status).");
            }
        } elsif ($report_status == STATUS_INTERNAL_ERROR) {
            $final_status = $report_status;
            say("INFO: $who_am_i Obviously trouble with reporters. " .
                "Will return status " . status2text($final_status) . "($final_status).");
        } else {
            $final_status = $status;
        }
    } else {
        # Do nothing in case we cannot raise our knowledge.
        $final_status = $status;
    }
    return $final_status;
} # End sub check_for_crash

1;

