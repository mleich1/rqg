#!/usr/bin/perl

# Copyright (c) 2010, 2012, Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2013, Monty Program Ab
# Copyright (C) 2016, 2021 MariaDB Corporation Ab
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


# TODO:
# Make here some very strict version
# 0. Check the use of
#    - sub exit_test  stop servers, cleanup etc. and call run_end
#    - sub run_end  status is decided, give summary, flip to RQG_PHASE_COMPLETE, run safe_exit
#    - safe_exit from GenTest.pm making POSIX::_exit($exit_status)... but not setting RQG_PHASE
# 1. Conflicts option1 vs option2 are not allowed and lead to abort of test
# 2. Computing the number of servers based on number of basedirs or vardirs must not happen
# 3. vardir must be assigned but it is only a directory where the RQG runner itself will
#    handle all vardirs for servers required.
# 4. Zero ambiguity.
#    The tool calling the RQG runner, the RQG runner itself and all ingredients taken by it must
#    must belong to the same version.
#    We focus on  File::Basename::dirname(Cwd::abs_path($0)) only and ignore RQG_HOME!
# 5. workdir is rather mandatory
# 6. Maybe reduce the horrible flood of options
# 7. Introduce a config file for the RQG runner

use Carp;
use File::Basename; # We use dirname
use Cwd;            # We use abs_path , getcwd
use POSIX;          # For sigalarm
my $rqg_home;
BEGIN {
    # Cwd::abs_path reports the target of a symlink.
    $rqg_home = File::Basename::dirname(Cwd::abs_path($0));
    print("# DEBUG: rqg_home computed is '$rqg_home'.\n");
    my $rqg_libdir = $rqg_home . '/lib';
    unshift @INC , $rqg_libdir;
    print("# DEBUG: '$rqg_libdir' added to begin of \@INC\n");
    print("# DEBUG \@INC is ->" . join("---", @INC) . "<-\n");
    $ENV{'RQG_HOME'} = $rqg_home;
    print("# INFO: Environment variable 'RQG_HOME' set to '$rqg_home'.\n");
}

my $rqg_start_time = time();

my $start_cwd     = Cwd::getcwd();

if (not -e $rqg_home . "/lib/GenTest.pm") {
    print("ERROR: The rqg_home ('$rqg_home') determined does not look like the root of a " .
          "RQG install.\n");
    exit 2;
}


# How many characters of each argument to a function to print.
$Carp::MaxArgLen=  200;
# How many arguments to each function to show. Btw. 8 is also the default.
$Carp::MaxArgNums= 8;

use constant RQG_RUNNER_VERSION  => 'Version 3.3.2 (2021-01)';
use constant STATUS_CONFIG_ERROR => 199;

use strict;
use GenTest;
use Auxiliary;
use Verdict;
use Runtime;
use SQLtrace;
# use GenTest::BzrInfo;
use GenTest::Constants;
use GenTest::Properties;
use GenTest::App::GenTest;
use GenTest::App::GenConfig;
use DBServer::DBServer;
use DBServer::MySQL::MySQLd;
use DBServer::MySQL::ReplMySQLd;
use DBServer::MySQL::GaleraMySQLd1; # My version

Auxiliary::check_and_set_rqg_home($rqg_home);


#--------------------
use GenTest::Grammar;
#--------------------

# TODO:
# Direct
# - nearly all output to $rqg_workdir/rqg.log
#   This would be
#   - clash free in case a clash free $workdir is assigned.
#   - not clash free in case $workdir is not assigned -> pick cwd().
#     But than we should have no parallel RQG runs anyway and
#     additional clashes on vardirs etc. are to be feared too.
# - rare and only early and late output to STDOUT.
#   This can than be merged into the output of some upper level caller
#   like combinations.pl.
# Example:
# 1. combinations.pl reports that it calls rqg.pl.
# 2. rqg.pl reports into combinations.pl that it has taken over.
# 3. rqg.pl does its main work and reports into $rqg_workdir/rqg.log.
# 4. rqg.pl reports at end something of interest into combinations.pl.
#

$| = 1;
my $logger;
eval
{
    require Log::Log4perl;
    Log::Log4perl->import();
    $logger = Log::Log4perl->get_logger('randgen.gentest');
};

$| = 1;
if (osWindows()) {
    $SIG{CHLD} = "IGNORE";
}

if (defined $ENV{RQG_HOME}) {
    if (osWindows()) {
        $ENV{RQG_HOME} = $ENV{RQG_HOME}.'\\';
    } else {
        $ENV{RQG_HOME} = $ENV{RQG_HOME}.'/';
    }
}

use Getopt::Long;
use DBI;

my $message;

# $summary
# --------
# A summary consisting of a few grep friendly lines to be printed around end of the RQG run.
my $summary = '';

# job_file is use for auxiliary purposes
my $job_file;

# This is the "default" database. Connects go into that database.
my $database = 'test';
# Connects which do not specify a different user use that user.
# (mleich) Try to escape the initialize the server trouble in 10.4
# my $user     = 'rqg';
my $user     = 'root';
my @dsns;

my (@basedirs, @mysqld_options, @vardirs, $rpl_mode,
    @engine, $help, $help_vardir, $help_sqltrace, $debug, @validators, @reporters, @transformers,
    $grammar_file, $skip_recursive_rules,
    @redefine_files, $seed, $mask, $mask_level, $rows,
    $varchar_len, $xml_output, $valgrind, @valgrind_options, @vcols, @views,
    $start_dirty, $filter, $build_thread, $sqltrace, $testname,
    $report_xml_tt, $report_xml_tt_type, $report_xml_tt_dest,
    $notnull, $logfile, $logconf, $report_tt_logdir, $querytimeout, $no_mask,
    $short_column_names, $strict_fields, $freeze_time, $wait_debugger, @debug_server,
    $skip_gendata, $skip_shutdown, $galera, $use_gtid, $annotate_rules,
    $restart_timeout, $gendata_advanced, $scenario, $upgrade_test,
    $ps_protocol, @gendata_sql_files, $gendata_dump, $config_file,
    $workdir, $queries, $script_debug_value, $rr, $rr_options, $max_gd_duration,
    $options);

my $gendata   = ''; ## default simple gendata
my $genconfig = ''; # if template is not set, the server will be run with --no-defaults

# Place rather into the preset/default section for all variables.
my $threads;
my $default_threads         = 10;
# my $queries;
my $default_queries         = 100000000;
my $duration;
my $default_duration        = 3600;
my $default_max_gd_duration = 300;

my @ARGV_saved = @ARGV;

# Warning:
# Lines starting with names of options like "rpl_mode" and "rpl-mode" are not duplicates because
# the difference "_" and "-".

# say("DEBUG: Before reading commannd line options");
# say("\@ARGV_saved : " . join(' ',@ARGV_saved));

# Take the options assigned in command line and
# - fill them into the of variables allowed in command line
# - abort in case of meeting some not supported options
my $opt_result = {};

if (not GetOptions(
    $opt_result,
    'workdir:s'                   => \$workdir,
    'mysqld=s@'                   => \$mysqld_options[0],
    'mysqld1=s@'                  => \$mysqld_options[1],
    'mysqld2=s@'                  => \$mysqld_options[2],
    'mysqld3=s@'                  => \$mysqld_options[3],
    'basedir=s@'                  => \$basedirs[0],
    'basedir1=s'                  => \$basedirs[1],
    'basedir2=s'                  => \$basedirs[2],
    'basedir3=s'                  => \$basedirs[3],
    #'basedir=s@'                 => \@basedirs,
    'vardir=s'                    => \$vardirs[0],
#   'vardir1=s'                   => \$vardirs[1], # used internal only
#   'vardir2=s'                   => \$vardirs[2], # used internal only
#   'vardir3=s'                   => \$vardirs[3], # used internal only
    'debug-server'                => \$debug_server[0],
    'debug-server1'               => \$debug_server[1],
    'debug-server2'               => \$debug_server[2],
    'debug-server3'               => \$debug_server[3],
    #'vardir=s@'                  => \@vardirs,
    'rpl_mode=s'                  => \$rpl_mode,
    'rpl-mode=s'                  => \$rpl_mode,
    'engine=s'                    => \$engine[0],
    'engine1=s'                   => \$engine[1],
    'engine2=s'                   => \$engine[2],
    'engine3=s'                   => \$engine[3],
    'grammar=s'                   => \$grammar_file,
    'skip-recursive-rules'        => \$skip_recursive_rules,
    'redefine=s@'                 => \@redefine_files,
    'threads=i'                   => \$threads,
    'queries=i'                   => \$queries,
    'duration=i'                  => \$duration,
    'help'                        => \$help,
    'help_sqltrace'               => \$help_sqltrace,
    'help_vardir'                 => \$help_vardir,
    'debug'                       => \$debug,
    'validators=s@'               => \@validators,
    'reporters=s@'                => \@reporters,
    'transformers=s@'             => \@transformers,
    'gendata:s'                   => \$gendata,
    'gendata_sql:s@'              => \@gendata_sql_files,
    'gendata_advanced'            => \$gendata_advanced,
    'gendata-advanced'            => \$gendata_advanced,
    'skip-gendata'                => \$skip_gendata,
    'skip_gendata'                => \$skip_gendata,
    'gendata_dump'                => \$gendata_dump,
    'genconfig:s'                 => \$genconfig,
    'notnull'                     => \$notnull,
    'short_column_names'          => \$short_column_names,
    'freeze_time'                 => \$freeze_time,
    'strict_fields'               => \$strict_fields,
    'seed=s'                      => \$seed,
    'mask:i'                      => \$mask,
    'mask-level:i'                => \$mask_level,
    'mask_level:i'                => \$mask_level,
    'rows=s'                      => \$rows,
    'varchar-length=i'            => \$varchar_len,
    'xml-output=s'                => \$xml_output,
    'report-xml-tt'               => \$report_xml_tt,
    'report-xml-tt-type=s'        => \$report_xml_tt_type,
    'report-xml-tt-dest=s'        => \$report_xml_tt_dest,
    'restart-timeout=i'           => \$restart_timeout,
    'restart_timeout=i'           => \$restart_timeout,
    'testname=s'                  => \$testname,
    'valgrind!'                   => \$valgrind,
    'valgrind_options=s@'         => \@valgrind_options,
    'rr:s'                        => \$rr,
    'rr_options=s'                => \$rr_options,
    'vcols:s'                     => \$vcols[0],
    'vcols1:s'                    => \$vcols[1],
    'vcols2:s'                    => \$vcols[2],
    'vcols3:s'                    => \$vcols[3],
    # Hint:
    # views is NOT just a boolean because assigning some view type is supported.
    'views:s'                     => \$views[0],
    'views1:s'                    => \$views[1],
    'views2:s'                    => \$views[2],
    'views3:s'                    => \$views[3],
    'wait-for-debugger'           => \$wait_debugger,
    'start-dirty'                 => \$start_dirty,
    'filter=s'                    => \$filter,
    'mtr-build-thread=i'          => \$build_thread,
    'sqltrace:s'                  => \$sqltrace,
    'logfile=s'                   => \$logfile,
    'logconf=s'                   => \$logconf,
    'report-tt-logdir=s'          => \$report_tt_logdir,
    'querytimeout=i'              => \$querytimeout,
    'no-mask'                     => \$no_mask,
    'no_mask'                     => \$no_mask,
    'skip_shutdown'               => \$skip_shutdown,
    'skip-shutdown'               => \$skip_shutdown,
    'galera=s'                    => \$galera,
    'use-gtid=s'                  => \$use_gtid,
    'use_gtid=s'                  => \$use_gtid,
    'annotate_rules'              => \$annotate_rules,
    'annotate-rules'              => \$annotate_rules,
    'upgrade-test:s'              => \$upgrade_test,
    'upgrade_test:s'              => \$upgrade_test,
    'scenario:s'                  => \$scenario,
    'max_gd_duration=i'           => \$max_gd_duration,
    'ps-protocol'                 => \$ps_protocol,
    'ps_protocol'                 => \$ps_protocol,
    'script_debug:s'              => \$script_debug_value,
    )) {
    if (not defined $help and not defined $help_sqltrace and
        not defined $help_vardir) {
        help();
        exit STATUS_CONFIG_ERROR;
    }
};

if ( defined $help ) {
    help();
    exit STATUS_OK;
}
if ( defined $help_sqltrace) {
    SQLtrace::help();
    exit STATUS_OK;
}
if ( defined $help_vardir) {
    help_vardir();
    exit STATUS_OK;
}

# say("\@ARGV after : " . join(' ',@ARGV));

# Example (independent of perl call with -w or not)
# -------------------------------------------------
# Call line          $debug_server[0]
# --debug-server -->               1
# <not set>      -->           undef

# Support script debugging as soon as possible and print its value.
$script_debug_value = Auxiliary::script_debug_init($script_debug_value);

$queries =         $default_queries         if not defined $queries;
$threads =         $default_threads         if not defined $threads;
$duration =        $default_duration        if not defined $duration;
$max_gd_duration = $default_max_gd_duration if not defined $max_gd_duration;

# say("DEBUG: After reading command line options");

# FIXME: Maybe move into Auxiliary.pm
my $rr_rules = 0;
# $rr_rules is used for deciding if a SIGKILL of the server is acceptable or not.
if (defined $rr) {
    my $status = STATUS_OK;
    if (STATUS_OK != Auxiliary::find_external_command("rr")) {
        $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: The external binary 'rr' is required but was not found.");
        safe_exit($status);
    }
    if($rr eq '') {
        $rr = Auxiliary::RR_TYPE_DEFAULT;
    }

    my $result = Auxiliary::check_value_supported (
                'rr', Auxiliary::RR_TYPE_ALLOWED_VALUE_LIST, $rr);
    if ($result != STATUS_OK) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("$0 will exit with exit status " . status2text($status) . "($status)");
        run_end($status);
    }
    if ($rr eq Auxiliary::RR_TYPE_RQG) {
        say("ERROR: Only 'rqg_batch.pl' supports the 'rr' invocation type '$rr'.");
        $status = STATUS_ENVIRONMENT_FAILURE;
        safe_exit($status);
    }
    say("INFO: The 'rr' invocation type '$rr'.");
    $rr_rules = 1;
} else {
    if (defined $rr_options) {
        say("WARN: Setting rr_options('$rr_options') to undef because 'rr' is not defined.");
        $rr_options = undef;
    }
}
if (defined $rr_options) {
    say("INFO: rr_options ->$rr_options<-");
}
my $env_var = $ENV{RUNNING_UNDER_RR};
if (defined $env_var) {
    say("INFO: The environment variable RUNNING_UNDER_RR is set. " .
        "This means the complete RQG run (-> all processes) are under the control of 'rr'.");
    if (defined $rr) {
        say("ERROR: 'rqg.pl' should invoke 'rr' even though already running under control " .
            "of 'rr'. This makes no sense.");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        safe_exit($status);
    }
    $rr_rules = 1;
}
if($rr_rules) {
    Runtime::set_runtime_factor_rr;
}

if (defined $valgrind) {
    if (STATUS_OK == Auxiliary::find_external_command("valgrind")) {
        Runtime::set_runtime_factor_valgrind;
    } else {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: valgrind is required but was not found.");
        safe_exit($status);
    }
}

# FIXME: Make $workdir mandatory??
if (not defined $workdir) {
    $workdir = Cwd::getcwd() . "/workdir_" . $$;
    say("INFO: The RQG workdir was not defined. Setting it to '$workdir' and removing+creating it.");
    if(-d $workdir) {
        if(not File::Path::rmtree($workdir)) {
            say("ERROR: Removal of the tree '$workdir' failed. : $!.");
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("$0 will exit with exit status " . status2text($status) . "($status)");
            safe_exit($status);
        }
        say("DEBUG: The already existing RQG workdir '$workdir' was removed.");
    }
    if (mkdir $workdir) {
        say("DEBUG: The RQG workdir '$workdir' was created.");
    } else {
        say("ERROR: Creating the RQG workdir '$workdir' failed : $!.");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("$0 will exit with exit status " . status2text($status) . "($status)");
        safe_exit($status);
    }

    my $result = Auxiliary::make_rqg_infrastructure($workdir);
    if ($result) {
        say("ERROR: Auxiliary::make_rqg_infrastructure failed with $result.");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("$0 will exit with exit status " . status2text($status) . "($status)");
        safe_exit($status);
    }
}
my $result = Auxiliary::check_rqg_infrastructure($workdir);
if ($result) {
    say("ERROR: Auxiliary::check_rqg_infrastructure failed with $result.");
    my $status = STATUS_ENVIRONMENT_FAILURE;
    say("$0 will exit with exit status " . status2text($status) . "($status)");
    safe_exit($status);
}


$job_file = $workdir . "/rqg.job";

say("INFO: RQG workdir : '$workdir' and infrastructure is prepared.");
####################################################################################################
# STARTING FROM HERE THE WORKDIR AND ESPECIALLY THE RQG LOG SHOULD BE AVAILABLE.
####################################################################################################

# In case of failure use
#    run_end($status);
# and never
#   exit_test($status);
# as long as
# - it is not decided if our current script or a different script runs the final test
#   Reason: The other scripts do not write the entries required for unwanted/replay matching.
# - say(Verdict::MATCHING_START) was not run.
#   Reason:
#   The unwanted/replay matching borders are missing.
#   It might be that the help text including
#      print "\n$0 arguments were: " . join(' ', @ARGV_saved) . "\n";
#   was printed. And these arguments contain the bwlist search patterns which than leads to
#   phantom matches.
#
# FIXME: Find some general robust solution for that.
#        Auxiliary.pm ... insists in the borders etc. or
#        say(Verdict::MATCHING_START) before starting other scripts but than with system?
#

# Shift from init -> start
my $return = Auxiliary::set_rqg_phase($workdir, Auxiliary::RQG_PHASE_START);
if (STATUS_OK != $return){
    say("ERROR: Setting the phase of the RQG run failed.");
    my $status = STATUS_ENVIRONMENT_FAILURE;
    say("$0 will exit with exit status " . status2text($status) . "($status)");
    safe_exit($status);
}
# For debugging of Auxiliary::set_rqg_phase
# $return = Auxiliary::get_rqg_phase($workdir);
# say("DEBUG: RQG phase is '$return'");

if (defined $scenario) {
    system("perl $ENV{RQG_HOME}/run-scenario.pl @ARGV_saved");
    exit $? >> 8;
}

# FIXME:
# There is some heavy distinction between STDOUT and STDERR.
# In my RQG testing I was rather unhappy with that.
if (defined $logfile && defined $logger) {
    setLoggingToFile($logfile);
} else {
    # FIXME: What is this branch good for and how does a logconf look like?
    if (defined $logconf && defined $logger) {
        setLogConf($logconf);
    } else {
        if (not defined $logfile) {
            $logfile = $workdir . '/rqg.log';
        }
    }
}

say("Copyright (c) 2010,2011 Oracle and/or its affiliates. All rights reserved. Use is subject to license terms.");
say("Please see http://forge.mysql.com/wiki/Category:RandomQueryGenerator for more information on this test framework.");
# Note:
# We print here a roughly correct command line call like
# 2018-11-16T10:28:26 [200006] Starting
# 2018-11-16T10:28:26 [200006] # /mnt/r0/mleich/RQG_new/rqg.pl \
# 2018-11-16T10:28:26 [200006] # --gendata=conf/mariadb/concurrency.zz \
# 2018-11-16T10:28:26 [200006] # --gendata_sql=conf/mariadb/concurrency.sql \
# 2018-11-16T10:28:26 [200006] # --grammar=conf/mariadb/concurrency.yy \
# 2018-11-16T10:28:26 [200006] # --engine=Innodb \
# 2018-11-16T10:28:26 [200006] # --reporters=Deadlock,ErrorLog,Backtrace \
# 2018-11-16T10:28:26 [200006] # --mysqld=--loose_innodb_use_native_aio=0 \
# 2018-11-16T10:28:26 [200006] # --mysqld=--connect_timeout=60 \
#    Do not add a space after the '\' around line end. Otherwise when converting the printout to
#    a shell script the shell assumes command end after the '\ '.
say("Starting \n# $0 \\\n# " . join(" \\\n# ", @ARGV_saved));

# FIXME:
# $gendata gets precharged with '' at begin.
# Could it flipped to undef at all?
# The handling of $skip_gendata is not 100% required but maybe recommended.
#
# For testing/debugging:
# $gendata = Auxiliary::unify_gendata();
# $gendata = Auxiliary::unify_gendata($gendata);
# $gendata = Auxiliary::unify_gendata(undef, undef);
# $gendata = Auxiliary::unify_gendata($gendata, undef);
# $gendata = Auxiliary::unify_gendata($gendata, 'omo');
# $gendata = Auxiliary::unify_gendata($gendata, $workdir . "/rqg.log");
# $gendata = Auxiliary::unify_gendata($gendata, '/');
if (defined $skip_gendata) {
    $gendata = '';
} else {
    $gendata = Auxiliary::unify_gendata($gendata, $workdir);
    if (not defined $gendata) {
        help();
        my $status = STATUS_ENVIRONMENT_FAILURE;
        run_end($status);
    }
}
my $gendata_sql_ref = Auxiliary::unify_gendata_sql(\@gendata_sql_files, $workdir);
if (not defined $gendata_sql_ref) {
    help();
    my $status = STATUS_ENVIRONMENT_FAILURE;
    run_end($status);
}
@gendata_sql_files = @$gendata_sql_ref;

my $redefine_ref = Auxiliary::unify_redefine(\@redefine_files, $workdir);
if (not defined $redefine_ref) {
    help();
    my $status = STATUS_ENVIRONMENT_FAILURE;
    run_end($status);
}
@redefine_files = @$redefine_ref;

if (defined $gendata_dump) {
    $gendata_dump = 1;
} else {
    $gendata_dump = 0;
}

if (not defined $grammar_file) {
    say("ERROR: Grammar file is not defined.");
    help();
    my $status = STATUS_ENVIRONMENT_FAILURE;
    say("$0 will exit with exit status " . status2text($status) . "($status)");
    run_end($status);
} else {
    $grammar_file = $rqg_home . "/" . $grammar_file if not $grammar_file =~ m {^/};
    if (! -f $grammar_file) {
        say("ERROR: Grammar file '$grammar_file' does not exist or is not a plain file.");
        help();
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("$0 will exit with exit status " . status2text($status) . "($status)");
        run_end($status);
    }
}

# Consolidation of the settings for masking
# Goal for the final setting which is used later
#    $no_mask = undef
#    $mask_level is defined
#    $mask       is defined
if (not defined $no_mask) {
    if (defined $mask and $mask > 0 and not defined $mask_level) {
        say("DEBUG: mask is > 0 and mask_level is undef. Therefore setting mask_level=1.");
        $mask_level = 1;
    } elsif (not defined $mask) {
        say("DEBUG: mask is not defined. Therefore setting mask_level = 0 and mask = 0.");
        $mask_level = 0;
        $mask       = 0;
    }
} else {
    say("DEBUG: no_mask is defind. Therefore setting mask_level=0 , mask=0 and no_mask=undef.");
    $mask_level = 0;
    $mask       = 0;
    $no_mask    = undef;
}

$grammar_file = Auxiliary::unify_grammar($grammar_file, $redefine_ref, $workdir,
                                         $skip_recursive_rules, $mask, $mask_level);
if (not defined $grammar_file) {
    say("ERROR: unify_grammar failed.");
    my $status = STATUS_ENVIRONMENT_FAILURE;
    say("$0 will exit with exit status " . status2text($status) . "($status)");
    run_end($status);
};
# The effective grammar rqg.yy which incorporates any masking and redefines was generated
# and the filename assigned to $grammar.
# Therefore assigning
#   @redefine_files=()
# Using undef instead would be wrong. Grammar::extractFromFiles would get called with
#     $grammar_file, @redefine_files    assigned which is than
# $grammar_file (defined+right value) and undef.
# The latter leads to failure.
@redefine_files = ();

if (defined $filter) {
    $filter = Auxiliary::check_filter($filter, $workdir);
    if (not defined $filter) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        run_end($status);
    }
}

#
# Calculate master and slave ports based on MTR_BUILD_THREAD (MTR Version 1 behaviour)
#

$build_thread = Auxiliary::check_and_set_build_thread($build_thread);
if (not defined $build_thread) {
    my $status = STATUS_ENVIRONMENT_FAILURE;
    say("$0 will exit with exit status " . status2text($status) . "($status)");
    run_end($status);
}

# Experiment (adjust to actual MTR, 2019-08) begin
# Reasons:
# 1. Galera Clusters at least up till 3 DB servers should be supported.
# 2. var/my.cnf generated by certain MTR tests could be used as template for setup in RQG.
# Original: my @ports = (10000 + 10 * $build_thread, 10000 + 10 * $build_thread + 2, 10000 + 10 * $build_thread + 4);
my @ports = (10000 + 20 * $build_thread, 10000 + 20 * $build_thread + 1, 10000 + 20 * $build_thread + 2);
# Experiment end

say("INFO: master_port : $ports[0] slave_port : $ports[1] ports : @ports MTR_BUILD_THREAD : $build_thread ");

if (not defined $rpl_mode or $rpl_mode eq '') {
    $rpl_mode = Auxiliary::RQG_RPL_NONE;
    say("INFO: rpl_mode was not defined or eq '' and therefore set to '$rpl_mode'.");
}
$result = Auxiliary::check_value_supported (
             'rpl_mode', Auxiliary::RQG_RPL_ALLOWED_VALUE_LIST, $rpl_mode);
if ($result != STATUS_OK) {
    Auxiliary::print_list("The values supported for 'rpl_mode' are :" ,
                          Auxiliary::RQG_RPL_ALLOWED_VALUE_LIST);
    my $status = STATUS_ENVIRONMENT_FAILURE;
    say("$0 will exit with exit status " . status2text($status) . "($status)");
    run_end($status);
}
my $number_of_servers = 0;
if ($rpl_mode eq Auxiliary::RQG_RPL_NONE) {
    if (not defined $upgrade_test) {
       $number_of_servers = 1;
    } else {
       # Unsure if this is all time right.
       $number_of_servers = 2;
    }
} elsif (defined $upgrade_test) {
    say("ERROR: upgrade_test ($upgrade_test) in combination with rpl_mode ($rpl_mode) is " .
        "in the moment not supported. Will exit with STATUS_ENVIRONMENT_FAILURE.");
    my $status = STATUS_ENVIRONMENT_FAILURE;
    run_end($status);
} elsif (($rpl_mode eq Auxiliary::RQG_RPL_STATEMENT)        or
         ($rpl_mode eq Auxiliary::RQG_RPL_STATEMENT_NOSYNC) or
         ($rpl_mode eq Auxiliary::RQG_RPL_MIXED)            or
         ($rpl_mode eq Auxiliary::RQG_RPL_MIXED_NOSYNC)     or
         ($rpl_mode eq Auxiliary::RQG_RPL_ROW)              or
         ($rpl_mode eq Auxiliary::RQG_RPL_ROW_NOSYNC)       or
         ($rpl_mode eq Auxiliary::RQG_RPL_RQG2)        ) {
    $number_of_servers = 2;
} elsif ($rpl_mode eq Auxiliary::RQG_RPL_RQG3) {
    $number_of_servers = 3;
} else {
    # Galera lands here.
    $number_of_servers = 0;
}
say("INFO: Number of servers involved = $number_of_servers. (0 means unknown)");

# FIXME:
# It seems the concept of basedir, vardir and server use is like (I take 'basedir' as example)
# 1. The "walk through" of options to variables is
#    'basedir=s@'                  => \$basedirs[0],
#    'basedir1=s'                  => \$basedirs[1],
#    'basedir2=s'                  => \$basedirs[2],
#    'basedir3=s'                  => \$basedirs[3]
# 2. It is doable (convenient in command line) to assign values to several variables by assigning
#    a string with a comma separated list to basedir<no number>.
#    RQG will decompose that later and distribute the values got to basedirs[<n>].
#    It needs to be checked that such a decomposition will be only done in case @basedirs contains
#    nothing else than a defined $basedirs[0].
# --- After decomposition if required ---
# 3. Server get counted starting with 1.
# 4. Server <n> -> $basedirs[<n>] -> vardirs[<n>]
# 5. In case $basedirs[<n>] is required but nothing was assigned than take $basedirs[0] in case
#    that was assigned. Otherwise abort.
# 6. We could end up with
#       Server 1 uses $basedirs[1] (assigned as basedir1 in command line)
#       Server 2 uses $basedirs[2] (not assigned in command line but there was a basedir assigned
#                                   and that was pushed to $basedirs[2])
#    Would that be reasonable?
# 7. vardir<whatever> assigned at commandline
#    For the case that we want to have all servers on the current box only, than wouldn't is make
#    sense to: Get one "top" vardir assigned and than RQG creates subdirs which get than used
#    for the servers.
#    To be solved problem: What if the test should start with "start-dirty".
#
# Depending on how (command line, some tool managing RQG runs) the current RQG runner was started
# we might meet
# - undef   Example: --basedir1= --> $basedirs[1] is not defined
# - ''      Example: <tool> --basedir1= --> tool gets undef for variable but sets to default ''

# check_basedirs exits in case of failure.
@basedirs = Auxiliary::check_basedirs(@basedirs);
@basedirs = Auxiliary::expand_basedirs(@basedirs);

my $info;
$info = "INFO: RQG_HOME   : ->" . $rqg_home . "<- ";
# get_git_info exits in case of failure.
$info .= Auxiliary::get_git_info($rqg_home);
# Routines called by get_all_basedir_infos exit in case of failure.
$info .= "\n" . Auxiliary::get_all_basedir_infos(@basedirs);
say($info);

# Other semantics ?
# $vardirs[0] set
#    The RQG runner creates and destroys the required vardirs as subdirs below $vardirs[0].
# $vardirs[>0] set
#    The RQG runner will use that vardir. Create/destroy would be ok but what if start-dirty?
# rmtree or not? What if somebody assigns some valuable dir?
if (not defined $vardirs[0] or $vardirs[0] eq '') {
    say("INFO: 'vardirs' is not defined or eq ''. But we need some vardir for the RQG run and " .
        "its servers.");
    $vardirs[0] = $workdir . "/vardir";
    say("INFO: Setting 'vardirs' to its default '$vardirs[0]'.");
    if(-d $vardirs[0]) {
        if(not File::Path::rmtree($vardirs[0])) {
            say("ERROR: Removal of the tree ->" . $vardirs[0] . "<- failed. : $!.");
            my $status = STATUS_ENVIRONMENT_FAILURE;
            run_end($status);
        }
        say("DEBUG: The already existing RQG vardir ->" . $vardirs[0] . "<- was removed.");
    }
    if (mkdir $vardirs[0]) {
        say("DEBUG: The RQG vardir ->" . $vardirs[0] . "<- was created.");
    } else {
        say("ERROR: Creating the RQG vardir ->" . $vardirs[0] . "<- failed : $!.");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        run_end($status);
    }
}
if (not -e $vardirs[0]) {
    if (mkdir $vardirs[0]) {
        say("DEBUG: The RQG vardir ->" . $vardirs[0] . "<- was created.");
    } else {
        say("ERROR: Creating the RQG vardir ->" . $vardirs[0] . "<- failed : $!.");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        run_end($status);
    }
}
foreach my $number (1..$number_of_servers) {
    $vardirs[$number] = $vardirs[0] . '/' . $number;
}
Auxiliary::print_list("INFO: Final RQG vardirs ",  @vardirs);

# We need a directory where the RQG run could store temporary files and do that by setting
# the environment variable TMP to some directory which is specific for the RQG run
# before (REQUIRED) calling GenTest the first time.
# So we go with TMP=$vardirs[0]
# - This is already set. --> No extra command line parameter required.
# - It gets destroyed (if already existing) and than created at begin of the test.
#   --> No chance to accidently process files of some finished test missing cleanup.
# - In case $vardirs[0] is unique to the RQG run
#      Example:
#      Smart tools causing <n> concurrent RQG runs could go with generating a timestamp first.
#      vardir of tool run = /dev/shm/vardir/<timestamp>
#         in case that directory already exists sleep 1 second and try again.
#      vardir of first RQG runner = /dev/shm/vardir/<timestamp>/1
#      vardir of n'th  RQG runner = /dev/shm/vardir/<timestamp>/<n>
#   than clashes with concurrent RQG runs are nearly impossible.
# - In case of a RQG failing we archive the vardir of the RQG runner and the maybe valuable
#   temporary files (dumps?) are already included.
# - In case we destroy the RQG run vardir at test end than all the temporary files are gone.
#   --> free space in some maybe small filesystem like a tmpfs
#   --> no pollution of '/tmp' with garbage laying there around for months
# - No error prone addition of process pids to file names.
#   Pids will repeat sooner or later. And maybe a piece of code forgets to add the pid.
#
# if (not defined $vardirs[0]) {
#    say("ALARM: \$vardirs[0] is not defined. Abort");
#    exit STATUS_INTERNAL_ERROR;
# }

# Put into environment so that child processes will compute via GenTest.pm right.
# Unfortunately its too late because GenTest.pm was already initialized.
$ENV{'TMP'} = $vardirs[0];
# Modify direct so that we get rid of crap values.
say("tmpdir in GenTest ->" . GenTest::tmpdir() . "<-");
say("tmpdir in DBServer ->" . DBServer::DBServer::tmpdir() . "<-");

## Make sure that "default" values ([0]) are also set, for compatibility,
## in case they are used somewhere
## Already done by expand_basedirs
# $basedirs[0] ||= $basedirs[1];

# All vardirs get explicite managed by rqg.pl or ingredients.
# $vardirs[0]  ||= $vardirs[1];
# Auxiliary::print_list("INFO: Now 1 RQG vardirs ",  @vardirs);
# Auxiliary::print_list("INFO: Now 1 RQG basedirs ",  @basedirs);

# Now sort out other options that can be set differently for different servers:
# - mysqld_options
# - debug_server
# - views
# - vcols
# - engine
# values[0] are those that are applied to all servers.
# In case values[0] is not set but values[1] than values[0] = values[1]
# values[N] expand or override values[0] for the server N

if (not defined $mysqld_options[0]) {
    if (defined $mysqld_options[1]) {
        $mysqld_options[0] = $mysqld_options[1];
    } else {
        $mysqld_options[0] = ();
    }
}
# Call line          $debug_server[0]
# --debug-server -->               1
# <not set>      -->           undef

if (not defined $debug_server[0]) {
    if (defined $debug_server[1]) {
        $debug_server[0] = $debug_server[1];
    }
}
if (not defined $vcols[0]) {
    if (defined $vcols[1]) {
        $vcols[0] = $vcols[1];
    }
}
if (not defined $views[0]) {
    if (defined $views[1]) {
        $views[0] = $views[1];
    }
}
if (not defined $engine[0]) {
    if (defined $engine[1]) {
        $engine[0] = $engine[1];
    }
}

push @{$mysqld_options[0]}, "--sql-mode=no_engine_substitution"
    if join(' ', @ARGV_saved) !~ m{(sql-mode|sql_mode)}io;

foreach my $i (1..3) {
    @{$mysqld_options[$i]} = ( defined $mysqld_options[$i]
            ? ( @{$mysqld_options[0]}, @{$mysqld_options[$i]} )
            : @{$mysqld_options[0]}
    );
    $debug_server[$i]= $debug_server[0] if not defined $debug_server[$i];
    $vcols[$i]       = $vcols[0]        if not defined $vcols[$i];
    $views[$i]       = $views[0]        if not defined $views[$i];
    $engine[$i]      = $engine[0]       if not defined $engine[$i];
}

shift @mysqld_options;
shift @debug_server;
shift @vcols;
shift @views;
shift @engine;

my $client_basedir;


# We take all required clients out of $basedirs[0].
foreach my $path ("$basedirs[0]/client/RelWithDebInfo",
                  "$basedirs[0]/client/Debug",
                  "$basedirs[0]/client",
                  "$basedirs[0]/bin") {
    if (-e $path) {
        $client_basedir = $path;
        last;
    }
}
if (not defined $client_basedir) {
    say("ERROR: No client_basedir found. Maybe your basedir content is incomplete.");
    my $status = STATUS_ENVIRONMENT_FAILURE;
    run_end($status);
}

#-----------------------
# Master and slave get the same debug_server[1] applied.
# FIXME: Is $debug_server[2] = $debug_server[1] right?
if ((defined $rpl_mode and $rpl_mode ne Auxiliary::RQG_RPL_NONE) and
    (($rpl_mode eq Auxiliary::RQG_RPL_STATEMENT)        or
     ($rpl_mode eq Auxiliary::RQG_RPL_STATEMENT_NOSYNC) or
     ($rpl_mode eq Auxiliary::RQG_RPL_MIXED)            or
     ($rpl_mode eq Auxiliary::RQG_RPL_MIXED_NOSYNC)     or
     ($rpl_mode eq Auxiliary::RQG_RPL_ROW)              or
     ($rpl_mode eq Auxiliary::RQG_RPL_ROW_NOSYNC)         )) {
    say("INFO: The RQG run is with replication where the setting of debug_server[1] gets applied " .
        "to master and slave server.");
    if (defined $debug_server[2]) {
        say("WARNING: debug_server[2] is set to $debug_server[2] but that will be ignored.");
    }
    say("Setting debug_server[2] = debug_server[1].");
    $debug_server[2] = $debug_server[1];
}

#-----------------------
my @subdir_list;
my $extension;
if (osWindows()) {
    @subdir_list = ("sql/Debug", "sql/RelWithDebInfo", "sql/Release", "bin");
    $extension   = ".exe";
} else {
    @subdir_list = ("sql", "libexec", "bin", "sbin");
    $extension   = "";
}
Auxiliary::print_list("DEBUG: subdir_list " , @subdir_list);
Auxiliary::print_list("DEBUG: Basedirs "    , @basedirs);
Auxiliary::print_list("DEBUG: debug_server ", @debug_server);

my $all_binaries_exist = 1;
# I prefer to check all possible assignments and not only for the servers needed.
foreach my $i (0..3) {
    if (defined $basedirs[$i]) {
        my $found = 0;
        if (defined $debug_server[$i]) {
            my $name = "mysqld-debug" . $extension;
            my $return = Auxiliary::find_file_at_places($basedirs[$i], \@subdir_list, $name);
            if (defined $return) {
                say("DEBUG: Server binary found : '$return'.");
                $found = 1;
                next;
            } else {
                say("DEBUG: No server binary named '$name' in '$basedirs[$i]' found.");
                $name = "mysqld" . $extension;
                say("DEBUG: Looking for a server binary named '$name'.");
                $return = Auxiliary::find_file_at_places($basedirs[$i], \@subdir_list, $name);
                if (not defined $return) {
                    say("DEBUG: Also no server binary named '$name'.");
                } else{
                    say("DEBUG: Server binary found : '$return'.");
                    # FIXME:
                    # The code which follows is taken out of lib/DBServer/... because there it
                    # gets applied too late (just before server start) for some good work flow.
                    # RULE: Check as much as possible BEFORE ANY serious intrusive action like
                    #       start a server.
                    # But here its also non ideal because the text patterns for debug server
                    # detection might differ for different DBS.
                    my $command = "$return --version";
                    my $result = `$command 2>&1`;
                    if ($result =~ /debug/sig) {
                        say("DEBUG: Server binary '$return' is compiled with debug.");
                        $found = 1;
                        next;
                    } else {
                        say("DEBUG: Server binary '$return' is compiled without debug.");
                    }
                }
            }
            if ($found == 0) {
                say("ERROR: 'debug_server[$i]' was assigned, but no server binary compiled with " .
                    "debug in $basedirs[$i]' found.");
                $all_binaries_exist = 0;
            }
        } else {
            my $name = "mysqld" . $extension;
            $return = Auxiliary::find_file_at_places($basedirs[$i], \@subdir_list, $name);
            if (defined $return) {
                say("DEBUG: Server binary found : '$return'.");
                $found = 1;
                next;
            } else {
                say("DEBUG: No server binary named '$name' in '$basedirs[$i]' found.");
                $name = "mysqld-debug" . $extension;
                say("DEBUG: Looking for a server binary named '$name'.");
                $return = Auxiliary::find_file_at_places($basedirs[$i], \@subdir_list, $name);
                if (not defined $return) {
                    say("DEBUG: Also no server binary named '$name' in '$basedirs[$i]' found.");
                } else{
                    say("DEBUG: Server binary found : '$return'.");
                    $found = 1;
                }
            }
            if ($found == 0) {
                say("ERROR: No server binary in $basedirs[$i]' found.");
                $all_binaries_exist = 0;
            }
        }
        #
        if ($found == 0) {
            say("ERROR: 'debug_server[$i] was assigned, but no server compiled with debug found.");
            $all_binaries_exist = 0;
        }
    } # End of checking defined $basedirs[$i]
}
if ($all_binaries_exist != 1) {
    say("ERROR: One or more server binaries were not found or had wrong properties.");
    say("HINT: Is the binary in some out of source build?");

    my $status = STATUS_ENVIRONMENT_FAILURE;
    run_end($status);
}

# Galera requires some additional options. Check them.
# ---------------------------------------------------
# https://mariadb.com/kb/en/library/rqg-extensions-for-mariadb/#galera-mode
if ($rpl_mode eq Auxiliary::RQG_RPL_GALERA) {
    if (osWindows()) {
        sayError("Galera is not supported on Windows (yet).");
        my $status = STATUS_CONFIG_ERROR;
        run_end($status);
    }

    if (not defined $galera or $galera eq '') {
        say("ERROR: --galera option was not set or is ''.");
        my $status = STATUS_CONFIG_ERROR;
        run_end($status);
    }

    # FIXME: Refine this
    # 1. If wsrep_provider set in ENV than take from there.
    #    If yes + its also between the mysqld options than warn + tell that from ENV picked.
    # 2. If not 1. but wsrep_provider between the mysqld options than take from there.
    # 3. If not 1. and not 2. but there is a /usr/lib/libgalera_smm.so than don't take that.
    #    I have read too much about dependencies between MariaDB and Galera versions.
    my $wsrep_provider = $ENV{'WSREP_PROVIDER'};
    if (not defined $wsrep_provider) {
        # Do not abort because
        # - maybe we have one node only --> no wsrep_provider needed
        # - maybe wsrep_provider is set between the server options
        #   FIXME(later): Check this here.
        # my $status = STATUS_ENVIRONMENT_FAILURE;
        # say("ERROR: WSREP_PROVIDER is not set in environment");
        # run_end($status);
    } else {
        if (not -f $wsrep_provider) {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            sayError("The wsrep_provider found in environment '$wsrep_provider' does not exist.");
            run_end($status);
        # } else {
            # say("INFO: wsrep_provider is '$wsrep_provider'");
        }
    }

    unless ($galera =~ /^[ms]+$/i) {
        say("ERROR: --galera option should contain a combination of M and S, indicating masters " .
                 "and slaves\nValue got : '$galera'");
        my $status = STATUS_CONFIG_ERROR;
        run_end($status);
    }
}


# Auxiliary::calculate_seed writes a message about
# - writes a message about assigned and computed setting of seed
#   and returns the computed value if all is fine
# - writes a message about the "defect" and some help and returns undef if the value assigned to
#   seed is not supported
$seed = Auxiliary::calculate_seed($seed);
if (not defined $seed) {
    my $status = STATUS_ENVIRONMENT_FAILURE;
    run_end($status);
}

my $cmd = $0 . " " . join(" ", @ARGV_saved);
# Remove any seed assignment
$cmd =~ s/--seed=\w*//g;
# Add one using the new seed value.
$cmd .= " --seed=$seed";

$message = "Final command line: ->perl " . $cmd . "<-";
$summary .= "SUMMARY: $message\n";
say("INFO: " . $message);

my $cnf_array_ref;

if ($genconfig) {
    unless (-e $genconfig) {
        say("ERROR: Specified config template '$genconfig' does not exist");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        run_end($status);
    }
    $cnf_array_ref = GenTest::App::GenConfig->new(spec_file => $genconfig,
                                                  seed      => $seed,
                                                  debug     => $debug
    );
}

# if (defined $rr) {
#     if (defined $rr_options) {
#         $rr_options = $rr_options ;
#     }
# }

### What follows should be checked (if at all) before any server is started.
# Otherwise it could happen that we have started some server and the test aborts later with
# Perl error because some prequisite is missing.
# Example:
# $upgrade_test is undef + no replication variant assigned --> $number_of_servers == 1
# basedir1 and basedir2 were assigned. basedir2 was set to undef because $number_of_servers == 1.
# Finally rqg.pl concludes that is a "simple" test with one server and
# 1. starts that one + runs gendata + gentest
# 2. around end of gentest the reporter "Upgrade1" becomes active and tries to start the upgrade
#    server based on basedir2 , $debug_server[1] etc.
# 3. this will than fail with Perl error because of basedir2 , $debug_server[1] .... undef.
#    The big problem: The already started Server will be than not stopped.
# FIXME: Replace that splitting with some general routine in Auxiliary
if ($#validators == 0 and $validators[0] =~ m/,/) {
    @validators = split(/,/,$validators[0]);
}
if ($#reporters == 0 and $reporters[0] =~ m/,/) {
    @reporters = split(/,/,$reporters[0]);
}
if ($#transformers == 0 and $transformers[0] =~ m/,/) {
    @transformers = split(/,/,$transformers[0]);
}
my $upgrade_rep_found = 0;
foreach my $rep (@reporters) {
    if (defined $rep and $rep =~ m/Upgrade/) {
        $upgrade_rep_found = 1;
        last;
    }
}

# FIXME: Define which upgrade types ar supported + check the value assigned.
if ($upgrade_rep_found && (not defined $upgrade_test)) {
    say("ERROR: Inconsistency: Some Upgrade reporter assigned but upgrade_test not.");
    my $status = STATUS_ENVIRONMENT_FAILURE;
    run_end($status);
}

# sqltracing
my $status = SQLtrace::check_and_set_sqltracing($sqltrace, $workdir);
if (STATUS_OK != $status) {
    say("$0 will exit with exit status " . status2text($status) . "($status)");
    run_end($status);
};

say(Verdict::MATCHING_START);

# FIXME (check code again):
# Starting from here there should be NEARLY NO cases where the test aborts because some file is
# missing or a parameter set to non supported value.
#
#
# Start servers.
#
Auxiliary::set_rqg_phase($workdir, Auxiliary::RQG_PHASE_PREPARE);

my @server;
my $rplsrv;

say("DEBUG: rpl_mode is '$rpl_mode'");
# FIXME: Let a routine in Auxiliary figure that out or figure out once and memorize result.
if ((defined $rpl_mode and $rpl_mode ne Auxiliary::RQG_RPL_NONE) and
    (($rpl_mode eq Auxiliary::RQG_RPL_STATEMENT)        or
     ($rpl_mode eq Auxiliary::RQG_RPL_STATEMENT_NOSYNC) or
     ($rpl_mode eq Auxiliary::RQG_RPL_MIXED)            or
     ($rpl_mode eq Auxiliary::RQG_RPL_MIXED_NOSYNC)     or
     ($rpl_mode eq Auxiliary::RQG_RPL_ROW)              or
     ($rpl_mode eq Auxiliary::RQG_RPL_ROW_NOSYNC)         )) {

    say("DEBUG: We run with MariaDB replication");

    $rplsrv = DBServer::MySQL::ReplMySQLd->new(
                 master_basedir      => $basedirs[1],
                 slave_basedir       => $basedirs[2],
                 master_vardir       => $vardirs[1],
                 debug_server        => $debug_server[1],
                 master_port         => $ports[0],
                 slave_vardir        => $vardirs[2],
                 slave_port          => $ports[1],
                 mode                => $rpl_mode,
                 server_options      => $mysqld_options[1],
                 valgrind            => $valgrind,
                 valgrind_options    => \@valgrind_options,
                 rr                  => $rr,
                 rr_options          => $rr_options,
                 general_log         => 1,
                 start_dirty         => $start_dirty, # This will not work for the first start. (vardir is empty)
                 use_gtid            => $use_gtid,
                 config              => $cnf_array_ref,
                 user                => $user
    );
    # FIXME:
    # Could already making the setup above fail?

    my $status = $rplsrv->startServer();

    if ($status > DBSTATUS_OK) {
        if (osWindows()) {
            say(system("dir ".unix2winPath($rplsrv->master->datadir)));
            say(system("dir ".unix2winPath($rplsrv->slave->datadir)));
        } else {
            say(system("ls -l ".$rplsrv->master->datadir));
            say(system("ls -l ".$rplsrv->slave->datadir));
        }
        my $status = STATUS_ENVIRONMENT_FAILURE;
        sayError("Could not start replicating server pair.");
        exit_test($status);
    }

    $dsns[0]   = $rplsrv->master->dsn($database,$user);
    $dsns[1]   = undef; ## passed to gentest. No dsn for slave!
    $server[0] = $rplsrv->master;
    $server[1] = $rplsrv->slave;

} elsif ($rpl_mode eq Auxiliary::RQG_RPL_GALERA) {

    # FIXME:
    # If WSREP_PROVIDER is set in environment than
    # - it must rule over any setting coming from config file
    #   --> append it to the $mysqld_options[1]
    # - it must exist
    my $wsrep_provider = $ENV{'WSREP_PROVIDER'};

    say("DEBUG: We run with Galera replication: $galera");

    $rplsrv = DBServer::MySQL::GaleraMySQLd1->new(
        basedir            => $basedirs[0],
        parent_vardir      => $vardirs[0],
        debug_server       => $debug_server[1],
        first_port         => $ports[0],
        server_options     => $mysqld_options[1],
        valgrind           => $valgrind,
        valgrind_options   => \@valgrind_options,
        rr                 => $rr,
        rr_options         => $rr_options,
        general_log        => 1,
        start_dirty        => $start_dirty,
        node_count         => length($galera),
        user               => $user
    );
    if (not defined $rplsrv) {
        say("ERROR: Setting up the Galera Cluster failed.");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        exit_test($status);
    }

    my $status = $rplsrv->startServer();

    if ($status > DBSTATUS_OK) {
        stopServers($status);
        sayError("Could not start Galera cluster");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        exit_test($status);
    }

    my $galera_topology = $galera;
    my $i = 0;
    while ($galera_topology =~ s/^(\w)//) {
        if (lc($1) eq 'm') {
            $dsns[$i] = $rplsrv->nodes->[$i]->dsn($database, $user);
        }
        $server[$i] = $rplsrv->nodes->[$i];
        $i++;
    }

    # Experimental/might get removed later: Check if the nodes are in sync.
    $status = $rplsrv->waitForNodeSync();
    if ($status > DBSTATUS_OK) {
        stopServers($status);
        sayError("Some Galera cluster nodes were not in sync.");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        exit_test($status);
    }

} elsif (defined $upgrade_test) {

    say("DEBUG: We are running an upgrade test.");

    # There are 'normal', 'crash', 'recovery' and 'undo' modes.
    # 'normal' will be used by default
    $upgrade_test= 'normal' if $upgrade_test !~ /(?:crash|undo|recovery)/i;

    $upgrade_test= lc($upgrade_test);

    # recovery is an alias for 'crash' test when the basedir before and after is the same
    # undo-recovery is an alias for 'undo' test when the basedir before and after is the same
    if ($upgrade_test =~ /recovery/) {
        $basedirs[2] = $basedirs[1] = $basedirs[0];
    }
    if ($upgrade_test =~ /undo/ and not $restart_timeout) {
        $restart_timeout= int($duration / 2);
    }

    # server0 is the "old" server (before upgrade).
    # We will initialize and start it now
    $server[0] = DBServer::MySQL::MySQLd->new(basedir          => $basedirs[1],
                                              vardir           => $vardirs[1],
                                              debug_server     => $debug_server[0],
                                              port             => $ports[0],
                                              start_dirty      => $start_dirty,
                                              valgrind         => $valgrind,
                                              valgrind_options => \@valgrind_options,
                                              rr               => $rr,
                                              rr_options       => $rr_options,
                                              server_options   => $mysqld_options[0],
                                              general_log      => 1,
                                              config           => $cnf_array_ref,
                                              user             => $user);
    if (not defined $server[0]) {
        say("ERROR: Preparing the server[0] for the start failed.");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("$0 will exit with exit status " . status2text($status) . "($status)");
        exit_test($status);
    }

    my $status = $server[0]->startServer;
    if ($status > DBSTATUS_OK) {
        stopServers($status);
        if (osWindows()) {
            say(system("dir " . unix2winPath($server[0]->datadir)));
        } else {
            say(system("ls -l " . $server[0]->datadir));
        }
        sayError("Could not start the old server in the upgrade test");
        my $status = STATUS_CRITICAL_FAILURE;
        say("$0 will exit with exit status " . status2text($status) . "($status)");
        exit_test($status);
    }

    $dsns[0] = $server[0]->dsn($database, $user);

    if ((defined $dsns[0]) && (defined $engine[0])) {
        my $dsn = $dsns[0];
        my $dbh = DBI->connect($dsn, undef, undef, {
                               mysql_connect_timeout  => Runtime::get_connect_timeout(),
                               PrintError             => 0,
                               RaiseError             => 0,
                               AutoCommit             => 0,
                               mysql_multi_statements => 1,   # Why?
                               mysql_auto_reconnect   => 0
        });
        if (not defined $dbh) {
            say("ERROR: Connect attempt to dsn " . $dsn .
                " failed: " . $DBI::errstr);
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("$0 will exit with exit status " . status2text($status) . "($status)");
            exit_test($status);
        }

        my $aux_query = "SET GLOBAL default_storage_engine = '$engine[0]' /* RQG runner */";
        SQLtrace::sqltrace_before_execution($aux_query);
        $dbh->do($aux_query);
        my $error = $dbh->err();
        SQLtrace::sqltrace_after_execution($error);
        if (defined $error) {
            say("ERROR: ->" . $aux_query . "<- failed with $error");
            $dbh->disconnect();
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("$0 will exit with exit status " . status2text($status) . "($status)");
            exit_test($status);
        }
        $dbh->disconnect();

    }

    # server1 is the "new" server (after upgrade).
    # We will initialize it, but won't start it yet
    if (not defined $mysqld_options[1]) {
        # say("DEBUG: no mysqld_options for the to be upgraded server found.");
        $mysqld_options[1] = $mysqld_options[0];
        exit;
    } else {
        # say("DEBUG: mysqld_options for the to be upgraded server found.");
    }
    $server[1] = DBServer::MySQL::MySQLd->new(
                   basedir           => $basedirs[2],
                   vardir            => $vardirs[1],        # Same vardir as for the first server!
                   debug_server      => $debug_server[1],   # <======================== here is the problem.
                   port              => $ports[0],          # Same port as for the first server!
                   start_dirty       => 1,
                   valgrind          => $valgrind,
                   valgrind_options  => \@valgrind_options,
                   rr                => $rr,
                   rr_options        => $rr_options,
                   server_options    => $mysqld_options[1],
                   general_log       => 1,
                   config            => $cnf_array_ref,
                   user              => $user);

    $dsns[1] = $server[1]->dsn($database, $user);

} else {

    # "Simple" test with either
    # - one server
    # - two or three servers and checks maybe (some variants might be not yet supported) like
    #   a) same or different (origin like MariaDB, MySQL, versions like 10.1, 10.2) servers
    #      - show the same reaction (pass/fail) when running the same SQL statement
    #      - show logical the same result sets when running the same SELECTs
    #      - have finally the same content in user defined tables and similar
    #      Basically some RQG builtin statement based replication is used.
    #   b) same server binaries
    #      Show logical the same result sets when running some SELECT on the first server
    #      and transformed SELECTs on some other server
    #
    my $max_id = $number_of_servers - 1;
    say("DEBUG: max_id is $max_id");

    foreach my $server_id (0.. $max_id) {

        $server[$server_id] = DBServer::MySQL::MySQLd->new(
                            basedir            => $basedirs[$server_id+1],
                            vardir             => $vardirs[$server_id+1],
                            debug_server       => $debug_server[$server_id],
                            port               => $ports[$server_id],
                            start_dirty        => $start_dirty,
                            valgrind           => $valgrind,
                            valgrind_options   => \@valgrind_options,
                            rr                 => $rr,
                            rr_options         => $rr_options,
                            server_options     => $mysqld_options[$server_id],
                            general_log        => 1,
                            config             => $cnf_array_ref,
                            user               => $user);

        if (not defined $server[$server_id]) {
            say("ERROR: Preparing the server[$server_id] for the start failed.");
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("RESULT: The RQG run ended with status " . status2text($status) . " ($status)");
            # $return = Auxiliary::set_rqg_phase($workdir, Auxiliary::RQG_PHASE_FINISHED);
            exit_test($status);
        }

        my $status = $server[$server_id]->startServer;
        if ($status > DBSTATUS_OK) {
            # exit_test will run killServers
            say("ERROR: Could not start all servers");
            my $status = STATUS_CRITICAL_FAILURE;
            say("RESULT: The RQG run ended with status " . status2text($status) . " ($status)");
            # $return = Auxiliary::set_rqg_phase($workdir, Auxiliary::RQG_PHASE_FINISHED);
            exit_test($status);
        }

        # Printing the systemvariables of the server is doable.
        # But for the moment I prefer printing that in startServer.
        # $server[$server_id]->serverVariablesDump;

        $dsns[$server_id] = $server[$server_id]->dsn($database, $user);
        say("DEBUG: dsns[$server_id] defined.");

        if ((defined $dsns[$server_id]) and
            (defined $engine[$server_id] and $engine[$server_id] ne '')) {
            my $dsn = $dsns[$server_id];
            my $dbh = DBI->connect($dsn, undef, undef, {
                                   mysql_connect_timeout  => Runtime::get_connect_timeout(),
                                   PrintError             => 0,
                                   RaiseError             => 0,
                                   AutoCommit             => 0,
                                   mysql_multi_statements => 1,   # Why?
                                   mysql_auto_reconnect   => 0
            });
            if (not defined $dbh) {
                say("ERROR: Connect attempt to dsn " . $dsn .
                    " failed: " . $DBI::errstr);
                my $status = STATUS_ENVIRONMENT_FAILURE;
                say("$0 will exit with exit status " . status2text($status) . "($status)");
                exit_test($status);
            }

            my $aux_query = "SET GLOBAL default_storage_engine = '$engine[$server_id]' /* RQG runner */";
            SQLtrace::sqltrace_before_execution($aux_query);
            $dbh->do($aux_query);
            my $error = $dbh->err();
            SQLtrace::sqltrace_after_execution($error);
            if (defined $error) {
                say("ERROR: ->" . $aux_query . "<- failed with $error");
                $dbh->disconnect();
                my $status = STATUS_ENVIRONMENT_FAILURE;
                say("$0 will exit with exit status " . status2text($status) . "($status)");
                exit_test($status);
            }

            $dbh->disconnect();
        }
    }
}

#
# Wait for user interaction before continuing, allowing the user to attach
# a debugger to the server process(es).
# Will print a message and ask the user to press a key to continue.
# User is responsible for actually attaching the debugger if so desired.
#
if ($wait_debugger) {
    say("Pausing test to allow attaching debuggers etc. to the server process.");
    my @pids;   # there may be more than one server process
    foreach my $server_id (0..$#server) {
        $pids[$server_id] = $server[$server_id]->serverpid;
    }
    say('Number of servers started: ' . ($#server + 1));
    say('Server PID: ' . join(', ', @pids));
    say("Press ENTER to continue the test run...");
    my $keypress = <STDIN>;
}


#
# Run actual queries
#

my $gentestProps = GenTest::Properties->new(
    legal => ['grammar',
              'skip-recursive-rules',
              'dsn',
              'engine',
              'gendata',
              'gendata-advanced',
              'gendata_sql',
              'generator',
              'redefine',
              'threads',
              'queries',
              'duration',
              'help',
              'debug',
              'rpl_mode',
              'validators',
              'reporters',
              'transformers',
              'seed',
              'mask',
              'mask-level',
              'rows',
              'varchar-length',
              'xml-output',
              'vcols',
              'views',
              'start-dirty',
              'filter',
              'notnull',
              'short_column_names',
              'strict_fields',
              'freeze_time',
              'valgrind',
              'valgrind-xml',
              'rr',
              'rr_options',
              'testname',
              'sqltrace',
              'querytimeout',
              'report-xml-tt',
              'report-xml-tt-type',
              'report-xml-tt-dest',
              'logfile',
              'logconf',
              'debug_server',
              'report-tt-logdir',
              'servers',
              'multi-master',
              'annotate-rules',
              'restart-timeout',
              'upgrade-test',
              'ps-protocol',
              'max_gd_duration'
    ]
);


$gentestProps->property('generator','FromGrammar') if not defined $gentestProps->property('generator');

$gentestProps->property('start-dirty',1) if defined $start_dirty;
# FIXME or document:
# --gendata-advanced --skip_gendata --gendata_sql=... --> run gendata-advanced and gendata_sql
# --gendata-advanced                --gendata_sql=... --> run gendata-advanced, gendata_simple and gendata_sql
$gentestProps->gendata($gendata) unless defined $skip_gendata;
$gentestProps->property('gendata-advanced',1) if defined $gendata_advanced;
$gentestProps->gendata_sql(\@gendata_sql_files) if @gendata_sql_files;
$gentestProps->engine(\@engine) if @engine;
# $gentestProps->rpl_mode($rpl_mode) if defined $rpl_mode;
$gentestProps->rpl_mode($rpl_mode);
$gentestProps->validators(\@validators) if @validators;
$gentestProps->reporters(\@reporters) if @reporters;
$gentestProps->transformers(\@transformers) if @transformers;
$gentestProps->threads($threads) if defined $threads;
$gentestProps->queries($queries) if defined $queries;
$gentestProps->duration($duration) if defined $duration;
$gentestProps->dsn(\@dsns) if @dsns;
$gentestProps->grammar($grammar_file);
$gentestProps->property('skip-recursive-rules', $skip_recursive_rules);
if (@redefine_files) {
    $gentestProps->redefine(\@redefine_files);
}
$gentestProps->redefine(\@redefine_files) if @redefine_files;
$gentestProps->seed($seed) if defined $seed;
$gentestProps->mask($mask) if (defined $mask) && (not defined $no_mask);
$gentestProps->property('mask-level',$mask_level) if defined $mask_level;
$gentestProps->rows($rows) if defined $rows;
$gentestProps->vcols(\@vcols) if @vcols;
$gentestProps->views(\@views) if @views;
$gentestProps->property('varchar-length',$varchar_len) if defined $varchar_len;
$gentestProps->property('xml-output',$xml_output) if defined $xml_output;
$gentestProps->debug(1) if defined $debug;
$gentestProps->filter($filter) if defined $filter;
$gentestProps->notnull($notnull) if defined $notnull;
$gentestProps->short_column_names($short_column_names) if defined $short_column_names;
$gentestProps->strict_fields($strict_fields) if defined $strict_fields;
$gentestProps->freeze_time($freeze_time) if defined $freeze_time;

if ($valgrind) {
    $gentestProps->valgrind(1);
}
$gentestProps->rr($rr) if $rr;
$gentestProps->rr_options($rr_options) if defined $rr_options;

$gentestProps->property('ps-protocol',1) if $ps_protocol;
$gentestProps->sqltrace($sqltrace) if defined $sqltrace;
$gentestProps->querytimeout($querytimeout) if defined $querytimeout;
$gentestProps->testname($testname) if $testname;
$gentestProps->logfile($logfile) if defined $logfile;
$gentestProps->logconf($logconf) if defined $logconf;
$gentestProps->property('report-tt-logdir',$report_tt_logdir) if defined $report_tt_logdir;
$gentestProps->property('report-xml-tt', 1) if defined $report_xml_tt;
$gentestProps->property('report-xml-tt-type', $report_xml_tt_type) if defined $report_xml_tt_type;
$gentestProps->property('report-xml-tt-dest', $report_xml_tt_dest) if defined $report_xml_tt_dest;
$gentestProps->property('restart-timeout', $restart_timeout) if defined $restart_timeout;
# In case of multi-master topology (e.g. Galera with multiple "masters"),
# we don't want to compare results after each query.
# Instead, we want to run the flow independently and only compare dumps at the end.
# If GenTest gets 'multi-master' property, it won't run ResultsetComparator
$gentestProps->property('multi-master', 1) if (defined $galera and scalar(@dsns)>1);
# Pass debug server if used.
$gentestProps->debug_server(\@debug_server) if @debug_server;
$gentestProps->servers(\@server) if @server;
$gentestProps->property('annotate-rules',$annotate_rules) if defined $annotate_rules;
$gentestProps->property('upgrade-test',$upgrade_test) if $upgrade_test;
$gentestProps->property('max_gd_duration',$max_gd_duration); #  if defined $max_gd_duration;

#
# Basically anything added via $gentestProps->property(<whatever name>,<value>)
# can be later found via $<object>->properties-><whatever name>.
#
# vardir might be required for a validator or reporter which starts some program.
# In case that program fails than some core file might show up within the current working
# directory. And that should be specific to the RQG run like vardir.
# Example: Mariabackup_linux

say("---------------------------------------------------------------" .
    "\nConfiguration");
$gentestProps->printProps;
say("---------------------------------------------------------------");


# Push certain information into environment variables so that grammars but also reporters
# and validators could exploit that in case the information is not somewhere else available.
#
# Number of "worker" threads
#    lib/GenTest/Generator/FromGrammar.pm will generate a corresponding grammar element.
$ENV{RQG_THREADS}= $threads;
#
# The pids of the servers started.
#    Good for crash testing and similar.
foreach my $server_id (0..$#server) {
    my $varname = "SERVER_PID" . ($server_id + 1);
    $ENV{$varname} = $server[$server_id]->serverpid;
}

my $gentest_result = STATUS_OK;
my $final_result   = STATUS_OK;
my $gentest = GenTest::App::GenTest->new(config => $gentestProps);
if (not defined $gentest) {
    say("ERROR: GenTest::App::GenTest->new delivered undef.");
    $final_result = STATUS_ENVIRONMENT_FAILURE;
}

# Original code to be later removed.
#
# Perform the GenTest run
#
# my $gentest_result = $gentest->run();
#
# say("GenTest returned status " . status2text($gentest_result) . " ($gentest_result)");
# my $final_result = $gentest_result;
#

# The branch is just for the optics :-).
if ($final_result == STATUS_OK) {
    sigaction SIGALRM, new POSIX::SigAction sub {
        my $status = STATUS_ALARM;
        say("ERROR: rqg.pl: max_gd_duration(" . $max_gd_duration . "s * " .
            Runtime::get_runtime_factor() . ") was exceeded. " .
            "Will kill DB servers and exit with STATUS_ALARM(" . $status . ") later.");
        killServers();
        # FIXME:
        # Check if killServers() fits here well in case rr is running.
        # Background:
        # Tests ended with "killing ... servers" as last protocol line.
    } or die "ERROR: rqg.pl: Error setting SIGALRM handler: $!\n";

    my $start_time = time();
    $return = Auxiliary::set_rqg_phase($workdir, Auxiliary::RQG_PHASE_GENDATA);
    alarm ($max_gd_duration * Runtime::get_runtime_factor());
    # For debugging
    # alarm (1);

    # For debugging
    # killServers();

    $gentest_result = $gentest->doGenData();
    alarm (0);

    say("GenData returned status " . status2text($gentest_result) . " ($gentest_result)");
    $final_result = $gentest_result;
    $message = "RQG GenData runtime in s : " . (time() - $start_time);
    $summary .= "SUMMARY: $message\n";
    say("INFO: " . $message);

    # Dump here the inital content
    if ($final_result == STATUS_OK and $gendata_dump) {
        my @dump_files;
        # For testing:
        # system("killall -9 mysqld mariadbd; sleep 3");
        my $i = 0;
        # foreach my $i (0..$#server) {
            # # Any server needs his own exlusive dumpfile. This is ensured by the '$i'.
            # # As soon as the caller takes care that any running rqg.pl uses his own exclusive
            # # $rqg_vardir and $rqg_wordir + dumpfiles in $rqg_vardir it must be clash free.
            # # The numbering of servers -> name of subdir for data etc. starts with 1!
            my $result = $server[$i]->nonSystemDatabases1;
            if (not defined $result) {
                say("ERROR: Trouble running SQL on Server " . ($i + 1) .
                    ". Will exit with STATUS_ALARM");
                exit_test(STATUS_ALARM);
            } else {
                my @schema_list = @{$result};
                my $databases_string = join(' ', @{$result});
                  say("DEBUG: databases_string ->$databases_string<-");
                # $vardirs[$server_id+1],
                my $dump_prefix =  $vardirs[$i + 1] . "/rqg_after_gendata";
                my $dump_options = "--force --hex-blob --no-tablespaces --compact --order-by-primary ".
                                   "--skip-extended-insert --databases $databases_string";
                my $dump_result = $server[$i]->dumpSomething("$dump_options", $dump_prefix);
                if ( $dump_result > 0 ) {
                    my $status = STATUS_CRITICAL_FAILURE;
                    say("ERROR: 'mysqldump' failed. Will exit with status : " .
                        status2text($status) . "($status).");
                    exit_test($status);
                }
            }
        # }
    }
}

if ($final_result > STATUS_OK) {
    # FIXME:
    # $gentest->doGenData should somehow tell if some server and which one looks like no
    # more responsive (no more connectable). And than some corresponding routine in
    # lib/DBServer/... should make the analysis and print to the RQG output.
    #
    # Provisoric solution because (in the moment)
    # 1. doGenData does not try to analyze the problem deeper like doGenTest would do.
    #    Example: doGenTest might activate the reporter Backtrace
    # 2. some sub generating a backtrace and located in lib/DBServer.... does not exist.
    # 3. doGenData reporting STATUS_ALARM and than aborting with that is so horrible unspecific.
    say("INFO: Printing content of all server error logs because of error in doGenTest ==========");
    foreach my $server_id (0..$#server) {
        say("INFO: Server[" . ($server_id + 1) . "] ---");
        my $error_log = $server[$server_id]->errorlog;
        sayFile($error_log);
    }
    say("INFO: Printing content of all server error logs End ==========");
}


if ($final_result == STATUS_OK) {
    # FIXME maybe:
    # Shutdown, maybe file backup, Restart but now including rr/valgrind/...
    my $start_time = time();
    $return = Auxiliary::set_rqg_phase($workdir, Auxiliary::RQG_PHASE_GENTEST);
    $gentest_result = $gentest->doGenTest();
    say("GenTest returned status " . status2text($gentest_result) . " ($gentest_result)");
    $final_result = $gentest_result;
    $message = "RQG GenTest runtime in s : " . (time() - $start_time);
    $summary .= "SUMMARY: $message\n";
    say("INFO: " . $message);
}


# If
# - none of the GenTest work phases produced a failure
# and
# - the test goes with whatever kind of replication which could be synchronized
# than compare the server dumps for any differences.

if (($final_result == STATUS_OK)                         and
    ($number_of_servers > 1 or $number_of_servers == 0)  and # 0 is Galera
    (not defined $upgrade_test or $upgrade_test eq '')   and
    # FIXME: Couldn't some slightly modified $rplsrv->waitForSlaveSync solve that?
    ($rpl_mode ne Auxiliary::RQG_RPL_STATEMENT_NOSYNC)   and
    ($rpl_mode ne Auxiliary::RQG_RPL_MIXED_NOSYNC)       and
    ($rpl_mode ne Auxiliary::RQG_RPL_ROW_NOSYNC)            ) {

    # Compare the content of all servers
    $return = Auxiliary::set_rqg_phase($workdir, Auxiliary::RQG_PHASE_SERVER_COMPARE);

    my $status = STATUS_OK;
    if (($rpl_mode eq Auxiliary::RQG_RPL_STATEMENT)   or
        ($rpl_mode eq Auxiliary::RQG_RPL_MIXED)       or
        ($rpl_mode eq Auxiliary::RQG_RPL_ROW)           ) {
        $status = $rplsrv->waitForSlaveSync;
        if ($status != STATUS_OK) {
            # FIXME: We get only DBSTATUS_FAILURE or DBSTATUS_OK returned!
            # STATUS_REPLICATION_FAILURE is a guess.
            say("ERROR: waitForSlaveSync failed with $status. ".
                "Setting final_result to STATUS_REPLICATION_FAILURE.");
            $final_result = STATUS_REPLICATION_FAILURE ;
        }
    } elsif ($rpl_mode eq Auxiliary::RQG_RPL_GALERA) {
        $status = $rplsrv->waitForNodeSync();
        if ($status != DBSTATUS_OK) {
            # FIXME: We get only DBSTATUS_FAILURE or DBSTATUS_OK returned!
            # STATUS_REPLICATION_FAILURE is a guess.
            say("ERROR: waitForNodeSync Some Galera cluster nodes were not in sync. " .
                "Setting final_result to STATUS_REPLICATION_FAILURE.");
            $final_result = STATUS_REPLICATION_FAILURE ;
        }
    } else {
        # There is nothing to do for RQG builtin statement based replication.
    }

#   foreach my $i (0..$#server) {
#      say("MLML: server " . $server[$i])
#   }
    # The facts that
    # - the servers are running (detection of trouble in gentest)
    # - reporters and validators did not detect trouble during gentest runtime
    #   But not all setups   (can have) or (can have and than also use) sensitive reporters ...
    # - waitForSlaveSync for synchronous MariaDB replication passed
    # - waitForNodeSync  for Galera replication passed
    # do not reveal/imply that the data content of masters and slaves is in sync.
    my $diff_result = DBSTATUS_OK;
    if ($status == DBSTATUS_OK) {
        my @dump_files;
        # For testing:
        # system("killall -9 mysqld mariadbd; sleep 3");
        foreach my $i (0..$#server) {
            # Any server needs his own exlusive dumpfile. This is ensured by the '$i'.
            # As soon as the caller takes care that any running rqg.pl uses his own exclusive
            # $rqg_vardir and $rqg_wordir + dumpfiles in $rqg_vardir it must be clash free.
            # The numbering of servers -> name of subdir for data etc. starts with 1!
            $dump_files[$i] = tmpdir() . ($i + 1) . "/DB.dump";
            my $result = $server[$i]->nonSystemDatabases1;
            if (not defined $result) {
                say("ERROR: Trouble running SQL on Server " . ($i + 1) .
                    ". Will exit with STATUS_ALARM");
                exit_test(STATUS_ALARM);
            } else {
                my @schema_list = @{$result};
                if (0 == scalar @schema_list) {
                    say("WARN: Server " . ($i + 1) . " does not contain non system SCHEMAs. " .
                        "Will create a dummy dump file.");
                    system("echo 'Dummy' > $dump_files[$i]");
                } else {
                    my $schema_listing = join (' ', @schema_list);
                    say("DEBUG: Server " . ($i + 1) . " schema_listing for mysqldump " .
                        "->$schema_listing<-");
                    if ($schema_listing eq '') {
                        say("ERROR: Schemalisting for Server " . ($i + 1) . " is empty. " .
                            "Will exit with STATUS_ALARM");
                        exit_test(STATUS_ALARM);
                    } else {
                        my $dump_result = $server[$i]->dumpdb("--databases $schema_listing",
                                                              $dump_files[$i]);
                        if ( $dump_result > 0 ) {
                            $final_result = $dump_result >> 8;
                            last;
                        }
                    }
                }
            }
        }
        if ($final_result == STATUS_OK) {
            say("INFO: Comparing SQL dumps...");
            foreach my $i (1..$#server) {
                ### 0 vs. 1 , 0 vs. 2 ...
                my $diff = system("diff -u $dump_files[0] $dump_files[$i]");
                if ($diff == STATUS_OK) {
                    say("INFO: No differences were found between first server and server " .
                        ($i + 1) . ".");
                    # Make free space as soon ass possible.
                    say("DEBUG: Deleting the dump file of server " . ($i + 1) . ".");
                    unlink($dump_files[$i]);
                } else {
                    sayError("ERROR: Found differences between first server and server " .
                             ($i + 1) . ". Setting final_result to STATUS_CONTENT_MISMATCH");
                    $diff_result  = STATUS_CONTENT_MISMATCH;
                    $final_result = $diff_result;
                }
            }
        }
        if ($final_result == STATUS_OK) {
            # In case we have no diffs than even the dump of the first server is no more needed.
            say("INFO: No differences between the SQL dumps of the servers detected.");
            say("DEBUG: Deleting the dump file of the first server.");
            unlink($dump_files[0]);
        } else {
            # FIXME:
            # ok we have a diff. But maybe the dumps of the second and third server are equal
            # and than we could remove one.
        }
    }
}

say("RESULT: The core of the RQG run ended with status " . status2text($final_result) .
    " ($final_result)");
# FIXME:
# If $final_result != STATUS_OK
#     print all server error logs, stop all servers + cleanup + exit
# and do not print any server error logs earlier except they would get later removed or ...


if ($final_result >= STATUS_CRITICAL_FAILURE) {
    # if (killServers() != STATUS_OK) {
    if (stopServers($final_result) != STATUS_OK) {
        say("ERROR: Killing the server(s) failed somehow.");
    } else {
        say("INFO: Any remaining servers were killed.");
    }
} else {
    if (stopServers($final_result) != STATUS_OK) {
        say("ERROR: Stopping the server(s) failed somehow.");
        say("       Server already no more running or no reaction on admin shutdown or ...");
        if ($final_result > STATUS_CRITICAL_FAILURE) {
            say("DEBUG: The current status is already high enough. So it will be not modified.");
        } else {
            say("DEBUG: Raising status from " . $final_result . " to " . STATUS_CRITICAL_FAILURE);
            $final_result = STATUS_CRITICAL_FAILURE;
        }
        # FIXME: In case there is a core file make a backtrace what than?
    }
}

# For experiments requiring that a RQG test has failed:
# $final_result = STATUS_SERVER_CRASHED;
# $return = Auxiliary::set_rqg_phase($workdir, Auxiliary::RQG_PHASE_FINISHED);
say("RESULT: The RQG run ended with status " . status2text($final_result) . " ($final_result)");

exit_test($final_result);

exit;



sub stopServers {
    # $status is relevant for replication only.
    # status value    | reaction
    # ----------------+-------------------------------------------------------------------
    # DBSTATUS_OK     | DBServer::MySQL::ReplMySQLd::stopServer will call waitForSlaveSync
    # != DBSTATUS_OK  | no call of waitForSlaveSync
    my $status = shift;

    say("DEBUG: rqg.pl: Entering stopServers with assigned status $status");

    if ($skip_shutdown) {
        say("Server shutdown is skipped upon request");
        return;
    }
    # For experimenting
    # system("killall -11 mysqld mariadbd");
    my $ret = STATUS_OK;
    say("Stopping server(s)...");
    if (($rpl_mode eq Auxiliary::RQG_RPL_STATEMENT)        or
        ($rpl_mode eq Auxiliary::RQG_RPL_STATEMENT_NOSYNC) or
        ($rpl_mode eq Auxiliary::RQG_RPL_MIXED)            or
        ($rpl_mode eq Auxiliary::RQG_RPL_MIXED_NOSYNC)     or
        ($rpl_mode eq Auxiliary::RQG_RPL_ROW)              or
        ($rpl_mode eq Auxiliary::RQG_RPL_ROW_NOSYNC)         ) {
        $ret = $rplsrv->stopServer($status);
    } elsif (defined $upgrade_test) {
        if (defined $server[1]) {
            $ret = $server[1]->stopServer;
        } else {
            $ret = STATUS_OK;
        }
    } else {
        foreach my $srv (@server) {
            if ($srv) {
                my $single_ret = $srv->stopServer;
                if (not defined $single_ret) {
                    say("ALARM: \$single_ret is not defined.");
                } else {
                    $ret = $single_ret if $single_ret != STATUS_OK;
                }
            }
        }
    }
    if ($ret != STATUS_OK) {
        say("DEBUG: stopServers(rqg.pl) failed with : ret : $ret");
    }
}

sub killServers {
# Use case:
# If the status is already bad than the final status must be not
# influenced by if a smooth shutdown is possible or not.
# Hence harsh and therefore reliable+fast treatment is best.
# --> SIGKILL whereever without harm
#     Positive example: No use of "rr" and all relevant is already in the RQG log.
# --> SIGABRT whenever "rr" is involved in order to avoid that "rr" traces are incomplete.
#     Negative example:
#     We run under "rr", found a data corruption, SIGKILL and get a rotten trace.
    my ($silent) = @_;

    say("Killing server(s)...");
    my $ret;
    if (($rpl_mode eq Auxiliary::RQG_RPL_STATEMENT)        or
        ($rpl_mode eq Auxiliary::RQG_RPL_STATEMENT_NOSYNC) or
        ($rpl_mode eq Auxiliary::RQG_RPL_MIXED)            or
        ($rpl_mode eq Auxiliary::RQG_RPL_MIXED_NOSYNC)     or
        ($rpl_mode eq Auxiliary::RQG_RPL_ROW)              or
        ($rpl_mode eq Auxiliary::RQG_RPL_ROW_NOSYNC)         ) {
        if ($rr_rules) {
            # FIXME:
            # Figure out if crashServer() or killServer is better
            # and if that sleep is really needed.
            # $ret = $rplsrv->crashServer();
            $ret = $rplsrv->killServer();
            sleep 10;
        } else {
            $ret = $rplsrv->killServer();
        }
    } elsif (defined $upgrade_test) {
        if (defined $server[1]) {
            $ret = $server[1]->killServer;
        } else {
            $ret = STATUS_OK;
        }
    } else {
        $ret = STATUS_OK;
        foreach my $srv (@server) {
            if ($srv) {
                my $single_ret = STATUS_OK;
                if ($rr_rules) {
                    $single_ret = $srv->killServer($silent);
                    # sleep 10;
                } else {
                    $single_ret = $srv->killServer($silent);
                }
                if (not defined $single_ret) {
                    say("ALARM: \$single_ret is not defined.");
                    $ret = STATUS_FAILURE;
                } else {
                    $ret = $single_ret if $single_ret != STATUS_OK;
                }
            }
        }
    }
    if ($ret != STATUS_OK) {
        say("DEBUG: killServers in rqg.pl failed with : ret : $ret");
    }
}

sub help1 {
    print <<EOF


    basedir<m> : Specifies the base directory (== directory with binaries) for the m'th server.
                 If (not defined basedir<m>) then
                     basedir<m> = basedir
                 fi
    basedir    : Base directory for any server n if basedir<n> is not specified..
                 If (not defined basedir) then
                     If (defined basedir1) then
                         basedir = basedir1
                     else
                         abort
                     fi
                 fi

    debug-server<m> : Use mysqld-debug server for MariaDB server <m>
    The "take over" mechanism is like for "basedir".

                 If (not defined debug-server<m>) then
                     debug-server<m> = debug-server
                 fi


EOF
  ;
}

sub help {

    print <<EOF
Copyright (c) 2010,2011 Oracle and/or its affiliates. All rights reserved. Use is subject to license terms.
Copyright (c) 2018,2021 MariaDB Corporation Ab.

$0 - Run a complete random query generation (RQG) test.
     Sorry, the description here is partially outdated.

     How to catch output:
     Sorry the shape of the command lines is not really satisfying.
     perl rqg.pl ... --logfile=<RQG log>                                # Output to screen and log file
     perl rqg.pl ... --workdir="\$WORKDIR" > \$WORKDIR/rqg.log 2>&1     # Output to log file only
     perl rqg.pl ... --workdir="\$WORKDIR"                     2>&1     # Output to screen only

    Options related to one standalone MariaDB server:

    --basedir   : Specifies the base directory of the stand-alone MariaDB installation (location of binaries)
    --mysqld    : Options passed to the MariaDB server
    --vardir    : vardir of the RQG run. The vardirs of the servers will get created within it.
                  Depending on certain requirements it is recommended to use
                  - a RAM based filesystem like tmpfs (/dev/shm/vardir) -- high IO speed but small filesystem
                  - a non RAM based filesystem -- not that fast IO but usual big filesystem
                  The default \$workdir/vardir is frequent not that optimal.
    --debug-server: Use mysqld-debug server

    Options related to two MariaDB servers

    --basedir1  : Specifies the base directory of the first MariaDB installation
    --basedir2  : Specifies the base directory of the second MariaDB installation
    --mysqld    : Options passed to both MariaDB servers
    --mysqld1   : Options passed to the first MariaDB server
    --mysqld2   : Options passed to the second MariaDB server
    --debug-server1: Use mysqld-debug server for MariaDB server1
    --debug-server2: Use mysqld-debug server for MariaDB server2
    The options vardir1 and vardir2 are no more supported.
    RQG places the vardirs of the servers inside of the vardir of the RQG run (see --vardir).

    General options

    --grammar      : Grammar file to use when generating queries (REQUIRED)
    --redefine     : Grammar file(s) to redefine and/or add rules to the given grammar (OPTIONAL)
                     Write: --redefine='A B'    or    --redefine='A' --redefine='B'
    --rpl_mode     : Replication type to use (statement|row|mixed) (default: no replication).
                     The mode can contain modifier 'nosync', e.g. row-nosync. It means that at the end the test
                     will not wait for the slave to catch up with master and perform the consistency check
    --use_gtid     : Use GTID mode for replication (current_pos|slave_pos|no). Adds the MASTER_USE_GTID clause to CHANGE MASTER,
                     (default: empty, no additional clause in CHANGE MASTER command);
    --galera       : Galera topology, presented as a string of 'm' or 's' (master or slave).
                     The test flow will be executed on each "master". "Slaves" will only be updated through Galera replication
    --engine       : Table engine to use when creating tables with gendata (default no ENGINE in CREATE TABLE);
                     Different values can be provided to servers through --engine1 | --engine2 | --engine3
    --threads      : Number of threads to spawn (default $default_threads);
    --queries      : Maximum number of queries to execute per thread (default $default_queries);
    --duration     : Maximum duration of the test in seconds (default $default_duration seconds);
    --validators   : The validators to use
    --reporters    : The reporters to use
    --transformers : The transformers to use (turns on --validator=transformer). Accepts comma separated list
    --querytimeout : The timeout to use for the QueryTimeout reporter
    --max_gd_duration : Abort the RQG run in case the work phase Gendata lasts longer than max_gd_duration
    --gendata      : Generate data option. Passed to lib/GenTest/App/Gentest.pm. Takes a data template (.zz file)
                     as an optional argument. Without an argument, indicates the use of GendataSimple (default).
    --gendata-advanced: Generate the data using GendataAdvanced instead of default GendataSimple
    --gendata_sql  : Generate data option. Passed to lib/GenTest/App/Gentest.pm. Takes files containing SQL as argument.
                     These files get processed after running Gendata, GendataSimple or GendataAdvanced.
    --gendata_dump : After running the work phase Gendata dump the content of the first DB server to the
                     file 'after_gendata.dump'. (OPTIONAL)
                     Sometimes useful for test simplification but otherwise a wasting of resources.
    --logfile      : Generates rqg output log at the path specified.(Requires the module Log4Perl)
    --seed         : PRNG seed. Passed to lib/GenTest/App/Gentest.pm.
    --mask         : Grammar mask. Passed to lib/GenTest/App/Gentest.pm.
    --mask-level   : Grammar mask level. Passed to lib/GenTest/App/Gentest.pm.
    --notnull      : Generate all fields with NOT NULL
    --rows         : No of rows. Passed to lib/GenTest/App/Gentest.pm.
    --sqltrace     : Print all generated SQL statements (tracing before execution)
                     Optional: Specify
                     --sqltrace=MarkErrors   with mark invalid statements. (tracing after execution)
                     --sqltrace=Concurrency  with mark invalid statements. (tracing before and after execution)
                     --sqltrace=File         Write a trace to <workdir>/rqg.trc (tracing before execution)
    --varchar-length: length of strings. Passed to lib/GenTest/App/Gentest.pm.
    --xml-outputs  : Passed to gentest.pl
    --vcols        : Types of virtual columns (only used if data is generated by GendataSimple or GendataAdvanced)
    --views        : Generate views. Optionally specify view type (algorithm) as option value. Passed to gentest.pl.
                     Different values can be provided to servers through --views1 | --views2 | --views3
    --valgrind     : Start the DB server with valgrind, adjust timeouts to the use of valgrind
    --valgrind_options : Use these additional options for any start under valgrind
    --rr           : Start the DB server and maybe more programs under rr rr, adjust timeouts to the use of rr
    --rr_options   : Use these additional options for any start under rr
    --filter       : File for disabling the execution of SQLs containing certain patterns. Passed to lib/GenTest/App/Gentest.pm.
    --mtr-build-thread: Value used for MTR_BUILD_THREAD when servers are started and accessed
    --debug        : Debug mode
    --short_column_names: use short column names in gendata (c<number>)
    --strict_fields: Disable all AI applied to columns defined in \$fields in the gendata file. Allows for very specific column definitions
    --freeze_time  : Freeze time for each query so that CURRENT_TIMESTAMP gives the same result for all transformers/validators
    --annotate-rules: Add to the resulting query a comment with the rule name before expanding each rule.
                      Useful for debugging query generation, otherwise makes the query look ugly and barely readable.
    --wait-for-debugger: Pause and wait for keypress after server startup to allow attaching a debugger to the server process.
    --restart-timeout: If the server has gone away, do not fail immediately, but wait to see if it restarts (it might be a part of the test)
    --upgrade-test : enable Upgrade reporter and treat server1 and server2 as old/new server, correspondingly. After the test flow
                     on server1, server2 will be started on the same datadir, and the upgrade consistency will be checked
                     Non simple upgrade variants will most probably fail because of weaknesses in RQG. Sorry for that.
    --workdir      : (optional) Workdir of this RQG run
                     Nothing assigned: We use the current working directory of the RQG runner process, certain files will be created.
                     Some directory assigned: We use the assigned directory and expect that certain files already exist.
    --help         : This help message
    --help_sqltrace : help about SQL tracing by RQG
    --help_vardir   : help about the parameter vardir

EOF
    ;
    print "\n$0 arguments were: " . join(' ', @ARGV_saved) . "\n";
}

sub exit_test {
    my $status = shift;

    say(Verdict::MATCHING_END);

    # Variants
    # 1.  Around end of test
    # 1a  status was < STATUS_CRITICAL_FAILURE and stopServers was tried
    #     The escalation is: admin shutdown -> term -> crashServer -> killServer
    # 1b  status was > STATUS_CRITICAL_FAILURE and killServer was tried
    # Hence it is unlikely that some server is running.
    # 2.  Somewhere around begin of test
    #     Some fatal error was hit and it is not unlikely that some server is running.
    # Hence some harsh killServers instead of stopServers is acceptable.
    killServers($status);

    # my $return = Auxiliary::set_rqg_phase($workdir, Auxiliary::RQG_PHASE_ANALYZE);
    my $return = Auxiliary::set_rqg_phase($workdir, Auxiliary::RQG_PHASE_FINISHED);

    $message = "RQG total runtime in s : " . (time() - $rqg_start_time);
    $summary .= "SUMMARY: $message\n";
    say("INFO: " . $message);

    if (not defined $logfile) {
        $logfile = $workdir . '/rqg.log';
    }

    my $vardir_size = Auxiliary::measure_space_consumption($vardirs[0]);
    say("INFO: vardir_size : $vardir_size");

    run_end($status);
}

sub run_end {
    my ($status) = @_;
    say($summary);
    # $return = Auxiliary::set_rqg_phase($workdir, Auxiliary::RQG_PHASE_COMPLETE);
    say("$0 will exit with exit status " . status2text($status) . "($status)");
    safe_exit($status);
}

sub help_vardir {

   say("HELP: The vardir of the RQG run ('vardir').\n"                                             .
       "      The vardirs of all database servers will be created as sub directories within "      .
       "that directory.\n"                                                                         .
       "      Also certain dumps, temporary files (variable tmpdir in RQG code) etc. will be "     .
       "placed there.\n"                                                                           .
       "      RQG tools and the RQG runners feel 'free' to destroy or create the vardir whenever " .
       "they want.\n"                                                                              .
       "      The parent directory of 'vardir' must exist in advance.\n"                           .
       "      The recommendation is to assign some directory placed on some filesystem which "     .
       "satisfies your needs.\n"                                                                   .
       "      Example 1:\n"                                                                        .
       "         Higher throughput and/or all CPU cores heavy loaded gives better results. "       .
       "(very often)\n"                                                                            .
       "         AND\n"                                                                            .
       "         The RQG test does not consume much storage space during runtime. (often)\n"       .
       "         Use some vardir placed on a RAM based filesystem(tmpfs) like '/dev/shm/vardir'."  .
       "      Example 2:\n"                                                                        .
       "         Slow responding IO system towards data storage gives better results. (rare)\n"    .
       "         OR\n"                                                                             .
       "         The RQG test does consume much storage space during runtime. (sometimes)\n"       .
       "         Use some vardir placed on a disk based filesystem like <RQG workdir>/vardir.\n"   .
       "         Having the vardir on some SSD is not recommended because RQG runs would write\n"  .
       "         there a huge amount of data and IO is there maybe not slow enough.\n"             .
       "      Default(sometimes sub optimal because test properties and your needs are not known " .
       "to RQG)\n"                                                                                 .
       "         <RQG workdir>/vardir\n"                                                           .
       "      Why is it no more supported to set the vardir<n> for the DB servers within the "     .
       "RQG call?\n"                                                                               .
       "      - Maximum safety against concurrent activity of other RQG and MTR tests could be\n"  .
       "        only ensured if the RQG run uses vardirs for servers which are specific to the\n"  .
       "        RQG run. Just assume the ugly case that concurrent tests create/destroy/modify\n"  .
       "        in <release>/mysql-test/var.\n"                                                    .
       "      - Creating/Archiving/Removing only one directory 'vardir' only is easier.");
}

1;

