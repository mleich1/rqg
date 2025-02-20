#!/usr/bin/perl

# Copyright (c) 2010, 2012, Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2013, Monty Program Ab
# Copyright (C) 2016, 2022 MariaDB Corporation Ab
# Copyright (C) 2023, 2025 MariaDB plc
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

# FIXME maybe:
# Unify the handling of array indexes to be used for @basedir, @vardir, @dsns, @ports, @views, ...
# in order to achieve that for some server n the array index value is n too.
#
# State 2022-12
# -------------
# The first server ('Master' in case of replication) gets often called server[1] in messages
# has configuration data in server[0] and uses mysqld_options[1], basedirs[1], vardirs[1], dsns[0] ...
#
# basedirs[0], mysqld_options[0], ... have a semantic which is not specific to one server at
# all and get used like
# if (not defined mysqld_options[1]) {
#     mysqld_options[1] = mysqld_options[0];
# } else {
#     mysqld_options[1] = mysqld_options[0] , mysqld_options[1];
# }
#

use Carp;
use File::Basename;          # We use dirname
use Cwd qw(abs_path); # We use abs_path
use POSIX;            # For sigalarm stuff, getcwd
my $rqg_home;
BEGIN {
    # Cwd::abs_path reports the target of a symlink.
    $rqg_home = File::Basename::dirname(Cwd::abs_path($0));
    # print("# DEBUG: rqg_home computed is '$rqg_home'.\n");
    if (not -e $rqg_home . "/lib/GenTest_e.pm") {
        print("ERROR: The rqg_home ('$rqg_home') calculated does not look like the root of a " .
              "RQG install.\n");
        exit 2;
    }
    my $rqg_libdir = $rqg_home . '/lib';
    unshift @INC , $rqg_libdir;
    # print("# DEBUG: '$rqg_libdir' added to begin of \@INC\n");
    $ENV{'RQG_HOME'} = $rqg_home;
    print("# INFO: Top level directory of RQG calculated '$rqg_home'.\n"     .
          "# INFO: Environment variable 'RQG_HOME' set to '$rqg_home'.\n"    .
          "# INFO: Perl array variable \@INC adjusted to ->" . join("---", @INC) . "<-\n");
}

my $rqg_start_time = time();

my $start_cwd      = POSIX::getcwd();

# How many characters of each argument to a function to print.
$Carp::MaxArgLen=  200;
# How many arguments to each function to show. Btw. 8 is also the default.
$Carp::MaxArgNums= 8;

use constant RQG_RUNNER_VERSION  => 'Version 4.5.0 (2023-12)';
use constant STATUS_CONFIG_ERROR => 199;

use strict;
use GenTest_e;
use Auxiliary;
use Verdict;
use Runtime;
use Basics;
use Local;
use SQLtrace;
use GenTest_e::Constants;
use GenTest_e::Properties;
use GenTest_e::App::GenTest_e;
use GenTest_e::App::GenConfig;
use DBServer_e::DBServer;
use DBServer_e::MySQL::MySQLd;
use DBServer_e::MySQL::ReplMySQLd;
use DBServer_e::MySQL::GaleraMySQLd;

Local::check_and_set_rqg_home($rqg_home);


#--------------------
use GenTest_e::Grammar;
#--------------------

$| = 1;
if (osWindows()) {
    $SIG{CHLD} = "IGNORE";
}

use Getopt::Long;
use DBI;

my $message;

# $summary
# --------
# A summary consisting of a few grep friendly lines to be printed around end of the RQG run.
my $summary = '';

# This is the "default" database. Connects go into that database.
my $database = 'test';
# Connects which do not specify a different user use that user.
# (mleich) Try to escape the initialize the server trouble in 10.4
# my $user     = 'rqg';
my $user     = 'root';
my @dsns;    # To be filled around starting the servers.
my @server;  # To be filled around starting the servers

my (@basedirs, @mysqld_options, @vardirs, @engine, @vcols, @views,
    # $dbdir_type, $vardir_type, $rpl_mode, $major_runid, $minor_runid, $batch,
    $dbdir_type, $vardir_type,            $major_runid, $minor_runid, $batch,
    $help, $help_dbdir_type, $help_sqltrace, $help_rr, $debug,
    @validators, @reporters, @transformers, $filter,
    $gendata_advanced, $skip_gendata, @gendata_sql_files, $grammar_file, @redefine_files,
    $seed, $mask, $mask_level, $no_mask, $skip_recursive_rules,
    $rows, $queries, $ps_protocol, $sqltrace,
    $varchar_len, $notnull, $short_column_names, $strict_fields,
    $max_gd_duration,
    $valgrind, $valgrind_options, $rr, $rr_options, $wait_debugger,
    $start_dirty, $build_thread,
    $logfile, $querytimeout,
    $freeze_time,
    $skip_shutdown, $galera, $use_gtid, $annotate_rules,
    $restart_timeout, $scenario, $upgrade_test, $max_gt_rounds,
    $gendata_dump, $config_file,
    $workdir, $script_debug_value,
    $options);

our $rpl_mode;

my $gendata   = ''; ## default simple gendata
my $genconfig = ''; # if template is not set, the server will be run with --no-defaults

# Place rather into the preset/default section for all variables.
my $threads;
my $default_threads         = 10;
my $default_queries         = 100000000;
my $duration;
my $default_duration        = 300;
my $default_max_gd_duration = 300;

my @ARGV_saved = @ARGV;

# Warning:
# Lines starting with names of options like "rpl_mode" and "rpl-mode" are not duplicates because
# the difference "_" and "-".

# say("DEBUG: Before reading commannd line options");
# say("\@ARGV before: " . join(' ',@ARGV_saved));

# Take the options assigned in command line and
# - fill them into the variables allowed in command line
# - abort in case of meeting some not supported options
my $opt_result = {};

# Example (independent of perl call with -w or not)
# -------------------------------------------------
# Call line    Value of $help
# --help                    1
# <not set>             undef

if (not GetOptions(
    $opt_result,
#   'workdir:s'                   => \$workdir,    # Computed by lib/Local.pm etc.
    'major_runid:s'               => \$major_runid,
    'minor_runid:s'               => \$minor_runid,
    'batch'                       => \$batch,
    'mysqld=s@'                   => \$mysqld_options[0],
    'mysqld1=s@'                  => \$mysqld_options[1],
    'mysqld2=s@'                  => \$mysqld_options[2],
    'mysqld3=s@'                  => \$mysqld_options[3],
    'basedir=s@'                  => \$basedirs[0],
    'basedir1=s'                  => \$basedirs[1],
    'basedir2=s'                  => \$basedirs[2],
    'basedir3=s'                  => \$basedirs[3],
#   'basedir=s@'                  => \@basedirs,
    'dbdir_type:s'                => \$dbdir_type,
    'vardir_type:s'               => \$dbdir_type,
#   'vardir=s'                    => \$vardirs[0], # Computed by lib/Local.pm and used internal only
#   'vardir1=s'                   => \$vardirs[1], # used internal only
#   'vardir2=s'                   => \$vardirs[2], # used internal only
#   'vardir3=s'                   => \$vardirs[3], # used internal only
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
    'help_dbdir_type'             => \$help_dbdir_type,
    'help_rr'                     => \$help_rr,
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
    'restart-timeout=i'           => \$restart_timeout,
    'restart_timeout=i'           => \$restart_timeout,
    'valgrind!'                   => \$valgrind,
    'valgrind_options=s'          => \$valgrind_options,
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
#   'mtr-build-thread=i'          => \$build_thread, # Computed based on local.cfg and ...
    'sqltrace:s'                  => \$sqltrace,
    'logfile=s'                   => \$logfile,
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
    'rounds=i'                    => \$max_gt_rounds,
    )) {
    if (not defined $help and not defined $help_sqltrace and
        not defined $help_dbdir_type) {
        help();
        run_end(STATUS_CONFIG_ERROR);
    }
};

##### Use run_end(<some status>) for bailing out until the first server is started. #####

if ( defined $help ) {
    help();
    exit STATUS_OK;
}
if ( defined $help_sqltrace) {
    SQLtrace::help();
    exit STATUS_OK;
}
if (defined $help_dbdir_type) {
    Local::help_dbdir_type();
    exit STATUS_OK;
}
if (defined $help_rr) {
    Runtime::help_rr();
    exit STATUS_OK;
}

# say("DEBUG: After reading command line options");
# say("\@ARGV after : " . join(' ',@ARGV));

# Support script debugging as soon as possible and print its value.
$script_debug_value = Auxiliary::script_debug_init($script_debug_value);

$queries =         $default_queries         if not defined $queries;
$threads =         $default_threads         if not defined $threads;
$duration =        $default_duration        if not defined $duration;
$max_gd_duration = $default_max_gd_duration if not defined $max_gd_duration;

$batch = 0 if not defined $batch;
if (defined $batch and $batch != 0) {
    # say("DEBUG: The RQG run seems to be under control of RQG Batch.");
    if (not defined $major_runid) {
        say("ERROR: \$batch : $batch but major_runid is not defined.");
        run_end(STATUS_INTERNAL_ERROR);
    }
} else {
    $batch = 0;
    say("DEBUG: This seems to be a stand alone RQG run.");
}
if (defined $major_runid) {
    say("DEBUG: major_runid : ->$major_runid<-");
}
if (defined $minor_runid) {
    say("DEBUG: minor_runid : ->$minor_runid<-");
}

# Do this first before calling routines which create directories or similar.
my $status = Runtime::check_and_set_rr_valgrind ($rr, $rr_options, $valgrind, $valgrind_options, 0);
if ($status != STATUS_OK) {
    say("The $0 arguments were ->" . join(" ", @ARGV_saved) . "<-");
    run_end($status);
}
$rr_options = Runtime::get_rr_options();
my $rr_rules = Runtime::get_rr_rules;

# Solution for compatibility with older config files where the parameter 'vardir_type' was used.
if (not defined $dbdir_type) {
    $dbdir_type = $vardir_type;
}

# Read local.cfg
# 1. clean and generate some share of the required infrastructure if batch=0
# 2. check some share of the infrastructure
Local::check_and_set_local_config($major_runid, $minor_runid, $dbdir_type, $batch);

$workdir = Local::get_results_dir();
# say("DEBUG: workdir ->" . $workdir . "<-");
# Example from RQG stand alone run:
# DEBUG: workdir ->/data/results/SINGLE_RQG<-
$vardirs[0] = Local::get_vardir;
# say("DEBUG: vardirs[0] ->" . $vardirs[0] . "<-");
# Example from RQG stand alone run:
# DEBUG: vardirs[0] ->/dev/shm/rqg_ext4/SINGLE_RQG<-
my $dbdir_fs_type = Local::get_dbdir_fs_type;

my $result;
if (not $batch) {
    $result = Auxiliary::make_rqg_infrastructure($workdir);
    if ($result) {
        say("ERROR: Auxiliary::make_rqg_infrastructure failed with $result.");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        run_end($status);
    }
}
# system("find $workdir -follow");
# system("find $vardirs[0] -follow");
# Example from RQG stand alone run:
# /data/results/SINGLE_RQG
# /data/results/SINGLE_RQG/rqg.log
# /data/results/SINGLE_RQG/rqg_verdict.init
# /data/results/SINGLE_RQG/rqg_phase.init
# /data/results/SINGLE_RQG/rqg.job
# /dev/shm/rqg_ext4/SINGLE_RQG
$result = Auxiliary::check_rqg_infrastructure($workdir);
if ($result) {
    say("ERROR: Auxiliary::check_rqg_infrastructure failed with $result.");
    my $status = STATUS_ENVIRONMENT_FAILURE;
    run_end($status);
}

# Jump into $vardirs[0]).
# Main reason: Clients which fail should not dump core files direct into $RQG_HOME.
if (not chdir($vardirs[0])) {
    my $status = STATUS_ENVIRONMENT_FAILURE;
    say("INTERNAL ERROR: chdir to '$vardirs[0]' failed with : $!\n" .
        "         " .  Basics::return_status_text($status));
    run_end($status);
}

say("INFO: RQG workdir : '$workdir' and infrastructure is prepared.");
####################################################################################################
# STARTING FROM HERE THE WORKDIR AND ESPECIALLY THE RQG LOG SHOULD BE AVAILABLE.
####################################################################################################

# In case of failure use
#   run_end($status);
# and never
#   exit_test($status);
#

# Shift from init -> start
my $return = Auxiliary::set_rqg_phase($workdir, Auxiliary::RQG_PHASE_START);
if (STATUS_OK != $return){
    say("ERROR: Setting the phase of the RQG run failed.");
    my $status = STATUS_ENVIRONMENT_FAILURE;
    run_end($status);
}
# For debugging of Auxiliary::set_rqg_phase
# $return = Auxiliary::get_rqg_phase($workdir);
# say("DEBUG: RQG phase is '$return'");

if (defined $scenario) {
    # WARNING: run-scenario.pl does not know of stuff set in Runtime.pm or Local.pm
    system("perl $ENV{RQG_HOME}/run-scenario.pl @ARGV_saved");
    exit $? >> 8;
}

$logfile = $workdir . '/rqg.log';

say("Copyright (c) 2010,2011 Oracle and/or its affiliates. All rights reserved. Use is subject to license terms.");
say("Please see http://forge.mysql.com/wiki/Category:RandomQueryGenerator for more information on this test framework.");
# Note:
# We print here a roughly correct command line call like
# 2018-11-16T10:28:26 [200006] Starting
# 2018-11-16T10:28:26 [200006] # ./rqg.pl \
# 2018-11-16T10:28:26 [200006] # --gendata=conf/mariadb/concurrency.zz \
# 2018-11-16T10:28:26 [200006] # --gendata_sql=conf/mariadb/concurrency.sql \
# 2018-11-16T10:28:26 [200006] # --grammar=conf/mariadb/concurrency.yy \
# 2018-11-16T10:28:26 [200006] # --engine=Innodb \
# 2018-11-16T10:28:26 [200006] # --reporters=Deadlock,ErrorLog,Backtrace \
# 2018-11-16T10:28:26 [200006] # --mysqld=--loose_innodb_use_native_aio=0 \
# 2018-11-16T10:28:26 [200006] # --mysqld=--connect_timeout=60 \
#    Do not add a space after the '\' around line end. Otherwise when converting the printout to
#    a shell script the shell assumes command end after the '\ '.
# - rqg_options value does not get replaced by the effective value (affected by rqg_options_add)
# - dbdir_type gets maybe printed
# say("Starting \n# $0 \\\n# " . join(" \\\n# ", @ARGV_saved));
$message = "# -------- Informations useful for bug reports --------------------------------------" .
           "----------------------\n" .
           "# git clone https://github.com/mleich1/rqg --branch <pick the right branch> RQG\n#\n"  .
           "# " . Auxiliary::get_git_info($rqg_home) . "\n" .
           "# rqg.pl  : " . RQG_RUNNER_VERSION . "\n#\n" .
           "# $0 \\\n# " . join(" \\\n# ", @ARGV_saved) . "\n#--------\n";
$message =~ s|$rqg_home|\$RQG_HOME|g;
if ($rr) {
    my $rr_options_add = Local::get_rr_options_add;
    my $rqg_rr_add= Local::get_rqg_rr_add;
    $message .= "# rqg_rr_add="     . $rqg_rr_add     . "\n" if $rqg_rr_add     ne '';
    $message .= "# rr_options_add=" . $rr_options_add . "\n" if $rr_options_add ne '';
}
$message .= "# vardir=$vardirs[0] fs_type=$dbdir_fs_type\n";
$message .= "\n";
print($message);

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

# In lib/GenTest_e/App/GenTest_e.pm
# Generate a SQL file tmpdir . "gt_users.sql" containing (vague code)
#   foreach $user in (<all threads>, reporter) {
#       CREATE USER '<user_name>' ....
#       GRANT ALL ON *.* TO ''<user_name>'
#   }
# And than run it after the list of gendata_sql files.
# Advantage:
# - Better distinction between whatever threads showing up in the processlist.
# - A thread running no query might be 'thread1' which just executes 'sleep 10'.
#   == That thread is connected and might run further SQL soon.
#   Limitation: A thread could be temporary disconnected!
# - Permission related tests become easier doable.
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
    run_end($status);
} else {
    $grammar_file = $rqg_home . "/" . $grammar_file if not $grammar_file =~ m {^/};
    if (! -f $grammar_file) {
        say("ERROR: Grammar file '$grammar_file' does not exist or is not a plain file.");
        help();
        my $status = STATUS_ENVIRONMENT_FAILURE;
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
        say("INFO: mask is > 0 and mask_level is not defined. Therefore setting mask_level=1.");
        $mask_level = 1;
    } elsif (not defined $mask) {
        # say("DEBUG: mask is not defined. Therefore setting mask_level = 0 and mask = 0.");
        $mask_level = 0;
        $mask       = 0;
    }
} else {
    # say("DEBUG: no_mask is defind. Therefore setting mask_level=0 , mask=0 and no_mask=undef.");
    $mask_level = 0;
    $mask       = 0;
    $no_mask    = undef;
}

$grammar_file = Auxiliary::unify_grammar($grammar_file, $redefine_ref, $workdir,
                                         $skip_recursive_rules, $mask, $mask_level);
if (not defined $grammar_file) {
    say("ERROR: unify_grammar failed.");
    my $status = STATUS_ENVIRONMENT_FAILURE;
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

# Local::get_build_thread returns a build_thread calculated based on local.cfg
# and minor_runid.
$build_thread = Local::get_build_thread;
# Calculate master and slave ports based on MTR_BUILD_THREAD (MTR Version 1 behaviour)

# Experiment (adjust to actual MTR, 2019-08) begin
# Reasons:
# 1. Galera Clusters: At least up till 3 DB servers should be supported.
# 2. var/my.cnf generated by certain MTR tests could be used as template for setup in RQG.
# Original:
# my @ports = (10000 + 10 * $build_thread, 10000 + 10 * $build_thread + 2, 10000 + 10 * $build_thread + 4);
# FIXME: Could this be the reason why my RQG does not work with Galera?
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
} elsif ($rpl_mode eq Auxiliary::RQG_RPL_GALERA) {
    $number_of_servers = length($galera);
} else {
    # Who lands here?
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
# 7. vardir<whatever> computed by lib/Local.pm based on content of local.cfg etc.
#    Get one "top" vardir computed and than RQG creates subdirs which get than used
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

# Compute the vardirs of the servers
# Probably superfluous
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

my $tmpdir = $vardirs[0] . "/";
# Put into environment so that child processes will compute via GenTest_e.pm right.
$ENV{'TMP'} = $tmpdir;
GenTest_e::set_tmpdir($tmpdir);

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
    $vcols[$i]       = $vcols[0]        if not defined $vcols[$i];
    $views[$i]       = $views[0]        if not defined $views[$i];
    $engine[$i]      = $engine[0]       if not defined $engine[$i];
}

shift @mysqld_options;
shift @vcols;
shift @views;
shift @engine;

# We take all required clients out of $basedirs[0].
# FIXME: Why not $client_bindir ?
my $client_basedir = Auxiliary::find_client_bindir($basedirs[0]);
if (not defined $client_basedir) {
    say("ERROR: client_basedir '$client_basedir' was not found. " .
        "Maybe '" . $basedirs[0] . "' is not the top directory of a MariaDB install");
    my $status = STATUS_ENVIRONMENT_FAILURE;
    run_end($status);
}

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

my $all_binaries_exist = 1;
# I prefer to check all possible assignments and not only for the servers needed.
foreach my $i (0..3) {
    if (defined $basedirs[$i]) {
        my $found = 0;
        my $name = "mariadbd" . $extension;
        $return = Auxiliary::find_file_at_places($basedirs[$i], \@subdir_list, $name);
        if (defined $return) {
            # say("DEBUG: Server binary found : '$return'.");
            $found = 1;
            next;
        } else {
            $name = "mysqld" . $extension;
            $return = Auxiliary::find_file_at_places($basedirs[$i], \@subdir_list, $name);
            if (defined $return) {
                # say("DEBUG: Server binary found : '$return'.");
                $found = 1;
                next;
            } else {
                # say("DEBUG: No server binary named '$name' in '$basedirs[$i]' found.");
                if ($found == 0) {
                    say("ERROR: No server binary in $basedirs[$i]' found.");
                    $all_binaries_exist = 0;
                }
            }
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
        say("ERROR: Galera is not supported on Windows (yet).");
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
            say("ERROR: The wsrep_provider found in environment '$wsrep_provider' does not exist.");
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
# - assigned and computed setting of seed
#   and returns the computed value if all is fine
# - the "defect" and some help and returns undef if the value assigned to
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
    $cnf_array_ref = GenTest_e::App::GenConfig->new(spec_file => $genconfig,
                                                    seed      => $seed,
                                                    debug     => $debug
    );
}

### What follows should be checked (if at all) before any server is started.
# Otherwise it could happen that we have started some server and the test aborts later with
# Perl error because some prequisite is missing.
# Example:
# $upgrade_test is not defined + no replication variant assigned --> $number_of_servers == 1
# basedir1 and basedir2 were assigned. basedir2 was set to undef because $number_of_servers == 1.
# Finally rqg.pl concludes that is a "simple" test with one server and
# 1. starts that one + runs gendata + gentest
# 2. around end of gentest the reporter "Upgrade" becomes active and tries to start the upgrade
#    server based on basedir2 etc.
# 3. this will than fail with Perl error because of basedir2 , .. undef.
#    The big problem: The already started Server will be than not stopped.
# FIXME:
# Add default reporters, validators, .... already here?

my $hash_ref;
my $element_path;

$hash_ref =     Auxiliary::unify_rvt_array(\@validators);
@validators =   sort keys %{$hash_ref};
$element_path = $rqg_home . "/lib/GenTest_e/Validator/";
foreach my $element (@validators) {
    next if "None" eq $element;
    my $file = $element_path . $element . ".pm";
    if (not -f $file) {
        say("ERROR: The validator file '$file' does not exist or is not a plain file.");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        run_end($status);
    }
}
$hash_ref =     Auxiliary::unify_rvt_array(\@reporters);
@reporters =    sort keys %{$hash_ref};
$element_path = $rqg_home . "/lib/GenTest_e/Reporter/";
foreach my $element (@reporters) {
    next if "None" eq $element;
    my $file = $element_path . $element . ".pm";
    if (not -f $file) {
        say("ERROR: The reporter file '$file' does not exist or is not a plain file.");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        run_end($status);
    }
}
$hash_ref =     Auxiliary::unify_rvt_array(\@transformers);
@transformers = sort keys %{$hash_ref};
$element_path = $rqg_home . "/lib/GenTest_e/Transformer/";
foreach my $element (@transformers) {
    next if "None" eq $element;
    my $file = $element_path . $element . ".pm";
    if (not -f $file) {
        say("ERROR: The transformer file '$file' does not exist or is not a plain file.");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        run_end($status);
    }
}

my $upgrade_rep_found = 0;
foreach my $rep (@reporters) {
    if (defined $rep and $rep =~ m/Upgrade/) {
        $upgrade_rep_found = 1;
        last;
    }
}

# FIXME: Define which upgrade types are supported + check the value assigned.
if ($upgrade_rep_found && (not defined $upgrade_test)) {
    say("ERROR: Inconsistency: Some Upgrade reporter assigned but upgrade_test not.");
    my $status = STATUS_ENVIRONMENT_FAILURE;
    run_end($status);
}

# sqltracing
$status = SQLtrace::check_and_set_sqltracing($sqltrace, $workdir);
if (STATUS_OK != $status) {
    run_end($status);
};

if (not defined $max_gt_rounds) {
    $max_gt_rounds = 1;
}

#
# Final preparations followed by start servers.
#
Auxiliary::set_rqg_phase($workdir, Auxiliary::RQG_PHASE_PREPARE);

my $max_id = $number_of_servers - 1;
# say("DEBUG: max_id is $max_id");

# Generate the infrastructure for all required servers.
# -----------------------------------------------------
foreach my $server_id (0.. $max_id) {
    # Example in shell code
    # mkdir $fast_dir/1
    # ln -s $fast_dir/1 $vardir/1
    # Hence mysql.err lands in $fast_dir/1/mysql.err == tmpfs
    my $what_dir = $workdir . "/" . ($server_id+1);
    if (STATUS_OK != Auxiliary::make_dbs_dirs($what_dir)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Preparing the storage structure for the server[$server_id] failed.");
        run_end($status);
    }
}

##### Use exit_test(<some status>) for bailing out #####
#
# FIXME (check code again):
# Starting from here there should be NEARLY NO cases where the test aborts because some file is
# missing or a parameter set to non supported value.
#

my $rplsrv;
# say("DEBUG: rpl_mode is '$rpl_mode'");
# FIXME: Let a routine in Auxiliary figure that out or figure out once and memorize result.
if ((defined $rpl_mode and $rpl_mode ne Auxiliary::RQG_RPL_NONE) and
    (($rpl_mode eq Auxiliary::RQG_RPL_STATEMENT)        or
     ($rpl_mode eq Auxiliary::RQG_RPL_STATEMENT_NOSYNC) or
     ($rpl_mode eq Auxiliary::RQG_RPL_MIXED)            or
     ($rpl_mode eq Auxiliary::RQG_RPL_MIXED_NOSYNC)     or
     ($rpl_mode eq Auxiliary::RQG_RPL_ROW)              or
     ($rpl_mode eq Auxiliary::RQG_RPL_ROW_NOSYNC)         )) {

    say("INFO: We run with MariaDB replication. rpl_mode: $rpl_mode");

    $rplsrv = DBServer_e::MySQL::ReplMySQLd->new(
                 master_basedir      => $basedirs[1],
                 slave_basedir       => $basedirs[2],
                 master_vardir       => $workdir . "/1",
                 master_port         => $ports[0],
                 slave_vardir        => $workdir . "/2",
                 slave_port          => $ports[1],
                 mode                => $rpl_mode,
                 server_options      => $mysqld_options[1],
                 valgrind            => $valgrind,
                 valgrind_options    => $valgrind_options,
                 rr                  => $rr,
                 rr_options          => $rr_options,
                 general_log         => 1,
                 start_dirty         => $start_dirty, # This will not work for the first start. (vardir is empty)
                 use_gtid            => $use_gtid,
                 config              => $cnf_array_ref,
                 user                => $user
    );
    # ReplMySQLd->new --> MySQLd->new --> createMysqlBase(== bootstrap) except start_dirty is 1.
    if (not defined $rplsrv) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Could not create replicating server pair.");
        # Up till now no DB server was already started.
        run_end($status);
    }

    my $status = $rplsrv->startServer();

    if ($status > STATUS_OK) {
        if (osWindows()) {
            say(system("dir " . unix2winPath($rplsrv->master->datadir)));
            say(system("dir " . unix2winPath($rplsrv->slave->datadir)));
        } else {
            say(system("ls -l " . $rplsrv->master->datadir));
            say(system("ls -l " . $rplsrv->slave->datadir));
        }
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Could not start replicating server pair.");
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

    say("INFO: We run with Galera replication: $galera");

    $rplsrv = DBServer_e::MySQL::GaleraMySQLd1->new(
        basedir            => $basedirs[0],
        parent_vardir      => $vardirs[0],
        first_port         => $ports[0],
        server_options     => $mysqld_options[1],
        valgrind           => $valgrind,
        valgrind_options   => $valgrind_options,
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

    if ($status > STATUS_OK) {
        stopServers($status);
        say("ERROR: Could not start Galera cluster");
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
    if ($status > STATUS_OK) {
        stopServers($status);
        say("ERROR: Some Galera cluster nodes were not in sync.");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        exit_test($status);
    }

} elsif (defined $upgrade_test) {

    say("INFO: We are running an upgrade test.");

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
    $server[0] = DBServer_e::MySQL::MySQLd->new(
                                    basedir          => $basedirs[1],
                                    vardir           => $vardirs[1],
                                    port             => $ports[0],
                                    start_dirty      => $start_dirty,
                                    valgrind         => $valgrind,
                                    valgrind_options => $valgrind_options,
                                    rr               => $rr,
                                    rr_options       => $rr_options,
                                    server_options   => $mysqld_options[0],
                                    general_log      => 1,
                                    config           => $cnf_array_ref,
                                    id               => 1,
                                    user             => $user);
    if (not defined $server[0]) {
        say("ERROR: Preparing the server[0] for the start failed.");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        exit_test($status);
    }


    my $status = $server[0]->startServer;
    if ($status > STATUS_OK) {
        stopServers($status);
        if (osWindows()) {
            say(system("dir " . unix2winPath($server[0]->datadir)));
        } else {
            say(system("ls -l " . $server[0]->datadir));
        }
        say("ERROR: Could not start the old server in the upgrade test");
        my $status = STATUS_CRITICAL_FAILURE;
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
            exit_test($status);
        }
        $dbh->disconnect();
    }

    # server1 is the "new" server (after upgrade).
    # We will initialize it, but won't start it yet
    if (not defined $mysqld_options[1]) {
        # say("DEBUG: no mysqld_options for the to be upgraded server found.");
        $mysqld_options[1] = $mysqld_options[0];
    } else {
        # say("DEBUG: mysqld_options for the to be upgraded server found.");
    }
    $server[1] = DBServer_e::MySQL::MySQLd->new(
                   basedir           => $basedirs[2],
                   vardir            => $vardirs[1],        # Same vardir as for the first server!
                   port              => $ports[0],          # Same port as for the first server!
                   start_dirty       => 1,
                   valgrind          => $valgrind,
                   valgrind_options  => $valgrind_options,
                   rr                => $rr,
                   rr_options        => $rr_options,
                   server_options    => $mysqld_options[1],
                   general_log       => 1,
                   config            => $cnf_array_ref,
                   id                => 2,
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
    # say("DEBUG: max_id is $max_id");

    foreach my $server_id (0.. $max_id) {

        $server[$server_id] = DBServer_e::MySQL::MySQLd->new(
                            basedir            => $basedirs[$server_id+1],
                            vardir             => $workdir . "/" . ($server_id+1),
                            port               => $ports[$server_id],
                            start_dirty        => $start_dirty,
                            valgrind           => $valgrind,
                            valgrind_options   => $valgrind_options,
                            rr                 => $rr,
                            rr_options         => $rr_options,
                            server_options     => $mysqld_options[$server_id],
                            general_log        => 1,
                            config             => $cnf_array_ref,
                            id                 => ($server_id+1),
                            user               => $user);

        if (not defined $server[$server_id]) {
            say("ERROR: Preparing the server[$server_id] for the start failed.");
            my $status = STATUS_ENVIRONMENT_FAILURE;
            # $return = Auxiliary::set_rqg_phase($workdir, Auxiliary::RQG_PHASE_FINISHED);
            exit_test($status);
        }

        my $status = $server[$server_id]->startServer;
        if ($status > STATUS_OK) {
            # In case the server died upon start startServer itself generates the backtrace.
            say("ERROR: Could not start all servers");
            # exit_test will killServers and set_rqg_phase RQG_PHASE_FINISHED.
            exit_test($status);
        }

        # For experimenting
        # system("killall -11 mysqld; sleep 3");
        #   $server[$server_id]->make_backtrace();

        # Printing the systemvariables of the server here would be doable.
        #    $server[$server_id]->serverVariablesDump;
        # But I prefer printing that in startServer because
        # - Reporters could also reconfigure and start servers.
        # - the branches != "Simple" test ... need that too.

        $dsns[$server_id] = $server[$server_id]->dsn($database, $user);
        # say("DEBUG: dsns[$server_id] defined.");

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
                say("ERROR: Connect attempt to dsn " . $dsn . " failed: " . $DBI::errstr);
                my $status = STATUS_ENVIRONMENT_FAILURE;
                exit_test($status);
            }

            my $aux_query = "SET GLOBAL default_storage_engine = '$engine[$server_id]' " .
                            "/* RQG runner */";
            SQLtrace::sqltrace_before_execution($aux_query);
            $dbh->do($aux_query);
            my $error = $dbh->err();
            SQLtrace::sqltrace_after_execution($error);
            if (defined $error) {
                say("ERROR: ->" . $aux_query . "<- failed with $error");
                $dbh->disconnect();
                my $status = STATUS_ENVIRONMENT_FAILURE;
                exit_test($status);
            }

            $dbh->disconnect();
        }
    }
}
# In case something went wrong around server starts than the corresponding routine
# made a backtrace and there should have been some exit.

#
# Wait for user interaction before continuing, allowing the user to attach
# a debugger to the server process(es).
# Will print a message and ask the user to press a key to continue.
# User is responsible for actually attaching the debugger if so desired.
#
if ($wait_debugger) {
    say("Pausing test to allow attaching debuggers etc. to the server process.");
    my @pids;   # there may be more than one running server
    my $server_num = 0;
    foreach my $srv (@server) {
        $server_num++;
        if (not defined $srv) {
            # say("DEBUG: server[$server_num] is not defined.");
            next;
        } else {
            push @pids, $server[$server_num - 1]->serverpid;
        }
    }
    say('Server PID: ' . join(' , ', sort @pids));
    say("Press ENTER to continue the test run...");
    my $keypress = <STDIN>;
}

#
# Run actual queries
#

my $gentestProps = GenTest_e::Properties->new(
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
              'vcols',
              'views',
              'start-dirty',
              'filter',
              'notnull',
              'short_column_names',
              'strict_fields',
              'freeze_time',
              'valgrind',
              'rr',
              'rr_options',
              'sqltrace',
              'querytimeout',
              'logfile',
              'servers',
              'multi-master',
              'annotate-rules',
              'restart-timeout',
              'upgrade-test',
              'ps-protocol',
              'max_gd_duration'
    ]
);


$gentestProps->property('generator','FromGrammar')
    if not defined $gentestProps->property('generator');

$gentestProps->property('start-dirty',1) if defined $start_dirty;
# FIXME or document:
# Setting                                          | What to run
# -------------------------------------------------+------------------------------------------------
# --gendata-advanced --skip_gendata --gendata_sql= | gendata-advanced and gendata_sql
# --gendata-advanced                --gendata_sql= | gendata-advanced + gendata_simple + gendata_sql
$gentestProps->gendata($gendata) unless defined $skip_gendata;
$gentestProps->property('gendata-advanced',1) if defined $gendata_advanced;
$gentestProps->gendata_sql(\@gendata_sql_files) if @gendata_sql_files;
$gentestProps->engine(\@engine) if @engine;
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
$gentestProps->logfile($logfile) if defined $logfile;
$gentestProps->property('restart-timeout', $restart_timeout) if defined $restart_timeout;
# In case of multi-master topology (e.g. Galera with multiple "masters"),
# we don't want to compare results after each query.
# Instead, we want to run the flow independently and only compare dumps at the end.
# If GenTest_e gets 'multi-master' property, it won't run ResultsetComparator
$gentestProps->property('multi-master', 1) if (defined $galera and scalar(@dsns)>1);
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
# ------------------------------------------------------------------------------------------
# Number of "worker" threads
#    lib/GenTest_e/Generator/FromGrammar.pm will generate a corresponding grammar element.
$ENV{RQG_THREADS}= $threads;
#
# The pids of the servers started are good for crash testing and similar.
# Warning:
# The memorized values
# - are invalid/undef for not yet started server
# - become invalid for server shut down or crashed or previous+restarted
my $server_num;
$server_num = 0;
foreach my $srv (@server) {
    $server_num++;
    if (not defined $srv) {
        # say("DEBUG: server[$server_num] is not defined.");
        next;
    }
    my $varname = "SERVER_PID" . ($server_num);
    $ENV{$varname} = $server[$server_num - 1]->serverpid;
}

my $gentest_result = STATUS_OK;
my $final_result   = STATUS_OK;
my $gentest =        GenTest_e::App::GenTest_e->new(config => $gentestProps);
if (not defined $gentest) {
    say("ERROR: GenTest_e::App::GenTest_e->new delivered undef.");
    $final_result = STATUS_ENVIRONMENT_FAILURE;
    exit_test($final_result);
}

# Gendata -- generate some initial data ------------------------------------------------------------
my $alarm_msg;
sigaction SIGALRM, new POSIX::SigAction sub {
    say("INFO: SIGALRM located in rqg.pl kicked in.");
    if (not defined $alarm_msg or "" eq $alarm_msg) {
        say("INFO: ALARM coming from somewhere else. Will ignore it.");
    } else {
        say($alarm_msg);
        killServers();
        # IMHO it is extreme unlikely that content of $vardirs[0] == rqg_vardir explains why
        # max_gd_duration was exceeded.
        # Free space as soon as possible because parallel RQG runs might need it.
        # Welcome sideeffects:
        # A far way smaller archive and far way shorter load during compressing the archive.
        foreach my $i (0..$max_id) {
            my $db_vardir = $vardirs[0] . "/" . ($i + 1);
            File::Path::rmtree($db_vardir) if -e $db_vardir;
        }
        say("INFO: The vardirs of the servers were deleted.");

        # exit_test($status); cannot be called here because it will try to rerun killServers().
        # And that will assume additional fatal errors because the files containing the server
        # pid do no more exist.

        my $return = Auxiliary::set_rqg_phase($workdir, Auxiliary::RQG_PHASE_FINISHED);

        $message =  "RQG total runtime in s : " . (time() - $rqg_start_time);
        $summary .= "SUMMARY: $message\n";
        say("INFO: " . $message);

        if (not defined $logfile) {
            $logfile = $workdir . '/rqg.log';
        }

        Auxiliary::report_max_sizes;
        run_end($status);
    }
} or die "ERROR: rqg.pl: Error setting SIGALRM handler: $!\n";

my $gendata_start_time = time();
$return = Auxiliary::set_rqg_phase($workdir, Auxiliary::RQG_PHASE_GENDATA);
$alarm_msg = "ERROR: rqg.pl: max_gd_duration(" . $max_gd_duration . "s * " .
             Runtime::get_runtime_factor() . ") was exceeded. " .
             "Will kill DB servers and exit with STATUS_ALARM(" . $status . ") later.";
my $alarm_timeout = $max_gd_duration * Runtime::get_runtime_factor();
say("DEBUG: rqg.pl: Setting alarm with timeout $alarm_timeout" . "s.");
alarm ($alarm_timeout);

# For experimenting
# The usual time span required for GenData will exceed 1s.
# And so the alarm will kick in.
# alarm (1);

# For experimenting
# killServers();

$gentest_result = $gentest->doGenData();
say("DEBUG: rqg.pl: Reset alarm timeout.");
alarm (0);
$alarm_msg = "";

say("GenData returned status " . status2text($gentest_result) . "($gentest_result).");
$final_result = $gentest_result;
$message =  "RQG GenData runtime in s : " . (time() - $gendata_start_time);
$summary .= "SUMMARY: $message\n";
say("INFO: " . $message);
if (STATUS_INTERNAL_ERROR == $final_result) {
    # There is nothing which we can do automatic except aborting.
    exit_test($final_result);
}

# For debugging
# killServers();                              # All servers are affected
# system('kill -11 $SERVER_PID1; sleep 10');  # Only the first server is affected.
# system('kill -11 $SERVER_PID2; sleep 10');  # (for RPL) Only the second server is affected.

my $check_status = STATUS_OK;

# Catch if some server is no more operable.
# ----------------------------------------
# checkServers runs for any server involved DBServer_e::MySQL::MySQLd::server_is_operable.
# server_is_operable checks server process, error log, connectability and processlist.
$check_status = checkServers($final_result); # Exits if status >= STATUS_CRITICAL_FAILURE
$final_result = $check_status if $check_status > $final_result;
if ($final_result > STATUS_OK) {
    say("INFO: The testing will go on even though GenData+Servercheck ended with status " .
        status2text($final_result) . "($final_result) because GenData is slightly imperfect.");
    $final_result = STATUS_OK;
    say("INFO: Hence reducing the status to " . status2text($final_result) . "($final_result).");
}

# Dump here the inital content
if ($gendata_dump) {
    my @dump_files;
    # For testing:
    # killServers();
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
            # say("DEBUG: databases_string ->$databases_string<-");
            my $dump_prefix =  $vardirs[$i + 1] . "/rqg_after_gendata";
            my $dump_options = "--force --hex-blob --no-tablespaces --compact --order-by-primary ".
                               "--skip-extended-insert --databases $databases_string";
            my $dump_result =  $server[$i]->dumpSomething("$dump_options", $dump_prefix);
            if ( $dump_result > 0 ) {
                my $status = STATUS_CRITICAL_FAILURE;
                say("ERROR: 'mysqldump' failed. Will exit with status : " .
                    status2text($status) . "($status).");
                exit_test($status);
            }
        }
    # }
}

Auxiliary::update_sizes();

# FIXME maybe:
# Shutdown, maybe make a file backup, Restart
# Hint for the case that files should be copied.
#### if (STATUS_OK != Basics::copy_dir_to_newdir($clone_datadir, $rqg_backup_dir . "/data")) {

my $gentest_start_time;
# GenTest -- Generate load based on processing the YY grammar --------------------------------------
my $gt_round      = 1;

# Use case for more than one GenTest+Checks round:
#    One or more redefine files referring to cached metadata should be used
#    but the main working tables get created by the GenTest (YY grammar processing round).
# The reason for more than one GenTest+Checks round:
#    The meta data cacher runs his first time at begin of the first GenTest round.
#    Caused by the facts that
#    - the main working tables do not exist yet
#    - worker threads will never rerun the metadata caching
#      The load caused by other threads leads to a big runtime for the caching and short timeouts
#      make a lot problems.
#    the cached meta data will not contain data about the main working tables.
#    Hence redefines using cached data will be valueless.
#    Within some additional GenTest+Checks round the metadata cacher will run again and
#    catch data of many of the now existing main working tables.
# And the cacher "sees" now the tables of the first Gentest (YY grammar processing round).
while ( $gt_round <= $max_gt_rounds) {
# Important: Place Auxiliary::update_sizes before exiting because of bad status.
#
#FIXME maybe:
# Set an alarm for exceeding the RQG runtime
# If exceeding
# 1. SIGSEGV the first DB server, SIGKILL any other DB server belonging to the run
#    maybe declare STATUS_SERVER_DEADLOCKED
# 2. Reap the processes now or already in 1.
# 3. Initiate making a backtrace
# 4. Exit with STATUS_SERVER_DEADLOCKED?
    $gentest_start_time = time();
    $return =             Auxiliary::set_rqg_phase($workdir, Auxiliary::RQG_PHASE_GENTEST);
    if (STATUS_OK != $return) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        exit_test($status);
    }

    $gentest_result = $gentest->doGenTest();
    say("GenTest returned status " . status2text($gentest_result) . "($gentest_result)");
    $final_result = $gentest_result;
    $message =      "RQG GenTest runtime in s : " . (time() - $gentest_start_time);
    $summary .=     "SUMMARY: $message\n";
    say("INFO: " . $message);
    Auxiliary::update_sizes();
    if (STATUS_INTERNAL_ERROR == $final_result) {
        # There is nothing which we can do automatic except aborting.
        exit_test($final_result);
    }

    # Catch if some server is no more operable.
    # ----------------------------------------
    $check_status = checkServers($final_result); # Exits if status >= STATUS_CRITICAL_FAILURE
    $final_result = $check_status if $check_status > $final_result;
    if ($final_result > STATUS_OK) {
        say("INFO: The testing will go on even though GenTest+Servercheck ended with status " .
            status2text($final_result) . "($final_result). Need to look for corruptions.");
        # say("DEBUG: No reduction of final status.");
    }

    # For experimenting:
    # killServers();
    # system('kill -11 $SERVER_PID1; sleep 10'); # Not suitable for crash recovery tests

    $server_num = 0;
    foreach my $srv (@server) {
        $server_num++;
        if (not defined $srv) {
            # say("DEBUG: server[$server_num] is not defined.");
            next;
        }
        my $status = STATUS_OK;
        if ($server_num > 1) {
            # checkDatabaseIntegrity will follow soon.
            # In case of any type of synchronous replication (MariaDB RPL of Galera?) finished
            # synchronization must be guaranteed. Otherwise objects (schemas, tables, ...) or
            # rows in tables within slave might disappear, show up first time, get altered etc.
            # during the checks and cause false alarms.
            # Example:
            # There is some replication lag from whatever reason.
            # checkDatabaseIntegrity on slave runs its m'th walkquery on table t1 and gets 100 rows.
            # The SQL thread on slave runs some SQL from the master.
            # checkDatabaseIntegrity on slave runs its m+1'th walkquery on table t1 and gets
            # "no such table", different number of rows or different content.
            #
            # Do not abort immediate if waitForSlaveSync or waitForNodeSync deliver a bad status.
            # The checkDatabaseIntegrity and checkServers which follow later might give valuable
            # information.
            if (($rpl_mode eq Auxiliary::RQG_RPL_STATEMENT)   or
                ($rpl_mode eq Auxiliary::RQG_RPL_MIXED)       or
                ($rpl_mode eq Auxiliary::RQG_RPL_ROW)           ) {
                $status = $rplsrv->waitForSlaveSync;
                if ($status != STATUS_OK) {
                    # FIXME: We get only STATUS_FAILURE or STATUS_OK returned!
                    # STATUS_REPLICATION_FAILURE is a guess.
                    say("ERROR: waitForSlaveSync failed with $status. ".
                        "Setting final_result to STATUS_REPLICATION_FAILURE.");
                    $final_result = STATUS_REPLICATION_FAILURE ;
                }
            }
            if ($rpl_mode eq Auxiliary::RQG_RPL_GALERA) {
                $status = $rplsrv->waitForNodeSync();
                if ($status != STATUS_OK) {
                    # FIXME: We get only STATUS_FAILURE or STATUS_OK returned!
                    # STATUS_REPLICATION_FAILURE is a guess.
                    say("ERROR: waitForNodeSync Some Galera cluster nodes were not in sync. " .
                        "Setting final_result to STATUS_REPLICATION_FAILURE.");
                    $final_result = STATUS_REPLICATION_FAILURE ;
                }
            }
            # RQG builtin statement based replication is per se synchronized.
        }

        Auxiliary::update_sizes();

        if (STATUS_REPLICATION_FAILURE == $final_result) {
            # Give up because its just likely that the checkDatabaseIntegrity which follows
            # will fail because of that.
            exit_test($final_result);
        }

        # Do not abort immediate if checkDatabaseIntegrity delivers a bad status.
        # The checkServers which follows later might give valuable information.
        my $check_status = $server[$server_num - 1]->checkDatabaseIntegrity();
        if ($check_status != STATUS_OK) {
            say("ERROR: Database Integrity check for server[$server_num] failed " .
                "with status " . status2text($check_status) . " ($check_status).");
            # Maybe we crashed just now.
            my $is_operable = $server[$server_num - 1]->server_is_operable;
            if (STATUS_OK != $is_operable) {
                say("ERROR: server_is_operable server[$server_num] reported status " .
                    status2text($is_operable) . " ($is_operable).");
                if ($is_operable > $check_status) {
                    say("ERROR: Raising check_status from " .
                        status2text($check_status) . " ($check_status) to " .
                        status2text($is_operable) . " ($is_operable).");
                    $check_status = $is_operable;
                }
                if ($server_num > 1 and
                    defined $rpl_mode and $rpl_mode ne Auxiliary::RQG_RPL_NONE and
                    $check_status < STATUS_ENVIRONMENT_FAILURE) {
                    say("ERROR: Setting check_status STATUS_REPLICATION_FAILURE because its not " .
                        "the first server and some kind of replication ($rpl_mode) is involved.");
                    $check_status = STATUS_REPLICATION_FAILURE;
                }
            }
        }
        Auxiliary::update_sizes();
        if ($check_status > $final_result) {
            say("ERROR: Raising final_result from $final_result to $check_status.");
            $final_result = $check_status;
        }
    }
    if ($final_result >= STATUS_CRITICAL_FAILURE) {
        say("RESULT: The core of the RQG run ended with status " . status2text($final_result) .
            " ($final_result)");
        # Do not exit already here! Because for example backtraces are maybe not yet generated.
    }

    # Catch if some server is no more operable.
    # ----------------------------------------
    $check_status = checkServers($final_result); # Exits if status >= STATUS_CRITICAL_FAILURE
    if ($check_status > $final_result) {
        say("ERROR: Raising final_result from $final_result to $check_status.");
        $final_result = $check_status;
    }

    if ($final_result > STATUS_OK) {
        say("RESULT: The core of the RQG run ended with status " . status2text($final_result) .
            " ($final_result)");
        exit_test($final_result);
    }

    if (($final_result == STATUS_OK)                         and
        ($number_of_servers > 1)                             and
        (not defined $upgrade_test or $upgrade_test eq '')   and
        # FIXME: Couldn't some slightly modified $rplsrv->waitForSlaveSync solve that?
        ($rpl_mode ne Auxiliary::RQG_RPL_STATEMENT_NOSYNC)   and
        ($rpl_mode ne Auxiliary::RQG_RPL_MIXED_NOSYNC)       and
        ($rpl_mode ne Auxiliary::RQG_RPL_ROW_NOSYNC)            ) {
        $check_status = compare_servers();
        # ??? Auxiliary::update_sizes();
        if ($check_status > $final_result) {
            say("ERROR: Raising final_result from $final_result to $check_status.");
            $final_result = $check_status;
        }
    }
    if ($final_result > STATUS_OK) {
        say("RESULT: The core of the RQG run ended with status " . status2text($final_result) .
            " ($final_result)");
        exit_test($final_result);
    }

    say("INFO: GenTest + check round $gt_round achieved a 'pass'.");
    $gt_round++;

}

my $stop_status = stopServers($final_result);
if ($stop_status != STATUS_OK) {
    # stopServer has probably made a backtrace.
    # Are ther missing cases.
    say("ERROR: Stopping the server(s) failed with status $stop_status.");
    say("       Server already no more running or no reaction on admin shutdown or ...");
    if ($final_result > STATUS_CRITICAL_FAILURE) {
        say("INFO: The current status is already high enough. So it will be not modified.");
    } else {
        say("INFO: Raising status from " . $final_result . " to " . $stop_status);
        $final_result = $stop_status;
    }
}

# For experiments requiring that a RQG test has failed:
# $final_result = STATUS_SERVER_CRASHED;

exit_test($final_result);

exit;

sub checkServers {
    my $current_status = shift;
    my $who_am_i =       Basics::who_am_i;

    Carp::cluck("ERROR: \$current_status is not defined.") if not defined $current_status;

    # Catch if some server is no more operable.
    # -----------------------------------------
    # Check based on server_is_operable: DB server process, error log, processlist.
    #
    # In case of $current_status in (STATUS_SERVER_CRASHED, STATUS_CRITICAL_FAILURE) give the
    # corresponding servers more time to finish the crash.
    if (STATUS_SERVER_CRASHED == $current_status or STATUS_CRITICAL_FAILURE == $current_status) {
        sleep 10;
    }
    my $server_num = 0;
    foreach my $srv (@server) {
        $server_num++;
        if (not defined $srv) {
            # say("DEBUG: $who_am_i server[$server_num] is not defined.");
            next;
        }
        # For debugging
        # $server[1]->crashServer if $server_num > 1;
        my $status = $srv->server_is_operable;
        # Returns:
        # - STATUS_OK                    (DB process running + server connectable)
        # - STATUS_SERVER_DEADLOCKED     (DB process running + server not connectable)
        # - If DB process not running --> make_backtrace returns --> take that return
        #   - STATUS_SERVER_CRASHED      (no internal problems)
        #   - STATUS_ENVIRONMENT_FAILURE (internal error)
        #   - STATUS_INTERNAL_ERROR      (internal error)
        #   - STATUS_CRITICAL_FAILURE    (waitForServerToStop failed)
        if (STATUS_OK != $status) {
            say("ERROR: $who_am_i server_is_operable reported for server[$server_num] " .
                "status $status");
            # Observation 2023-01:
            # Start, make load, kill the server during that, restart with success.
            # During the checking of tables happens a server crash (-> STATUS_RECOVERY_FAILURE)
            # but is not finished yet. server_is_operable gets no connection, calls making a
            # backtrace which detects that the server process is not yet dead
            # (-> STATUS_SERVER_DEADLOCKED). And than we raise here the status to
            # STATUS_SERVER_DEADLOCKED which is misleading.
            if ($status > $current_status and $current_status != STATUS_RECOVERY_FAILURE) {
                say("ERROR: $who_am_i Raising current_status from " .
                    status2text($current_status) . "($current_status) to " .
                    status2text($status) . "($status).");
                $current_status = $status;
            }
            if ($server_num > 1 and
                defined $rpl_mode and $rpl_mode ne Auxiliary::RQG_RPL_NONE and
                $status < STATUS_ENVIRONMENT_FAILURE) {
                say("ERROR: Setting current_status STATUS_REPLICATION_FAILURE because its not " .
                    "the first server and some kind of replication ($rpl_mode) is involved.");
                $current_status = STATUS_REPLICATION_FAILURE;
            }
        }
    }
    # Status:
    # STATUS_CRITICAL_FAILURE(100) - either (unexpected server crash)
    #                                or (bug in RQG or problem in environment)
    #                                Hence try to  make a backtrace.
    # STATUS_SERVER_CRASHED(101)   - either (MariaDB bug) or (bug in RQG or problem in environment)
    #                                Hence try to  make a backtrace.
    # All other STATUSES >= STATUS_SERVER_KILLED(102) and STATUS < STATUS_CRITICAL_FAILURE do not
    # need a backtrace generation or RQG is buggy.
    if ($current_status <  STATUS_CRITICAL_FAILURE) {
        # Nothing to do.
    } elsif ($current_status >= STATUS_SERVER_KILLED) {
        exit_test($current_status);
    } else {
        # Experimental:
        # I assume that the first server is "ill". Most probably a freeze.
        say("ERROR: $who_am_i status is " . status2text($status) . "($status). Assuming " .
            "server[$server_num] is somehow ill. Will kill it and initiate making a backtrace.");
        $server[0]->crashServer;
        $server[0]->make_backtrace();
        exit_test($current_status);
    }

    if ($current_status > STATUS_OK) {
        say("ERROR: $who_am_i " . Basics::return_status_text($final_result) .
            " because of previous errors.");
    }
    return $current_status;

} # End of sub checkServers

#################################################


# Return if STATUS_OK!
sub compare_servers {
    # Compare the content of all servers
    $return = Auxiliary::set_rqg_phase($workdir, Auxiliary::RQG_PHASE_SERVER_COMPARE);
    if (STATUS_OK != $return) {
        exit_test(STATUS_ENVIRONMENT_FAILURE);
    }
    # The facts that
    # - the servers are alive + server error log free of suspicious entries
    # - reporters and validators did not detect trouble during gentest runtime
    #   But not all setups   (can have) or (can have and than also use) sensitive reporters ...
    # - waitForSlaveSync for synchronous MariaDB replication passed
    # - waitForNodeSync  for Galera replication passed
    # do not reveal/imply that the data content of masters and slaves is in sync.
    my $diff_result = STATUS_OK;
    my @dump_files;
    # For testing:
    # system("killall -9 mysqld mariadbd; sleep 3");
    my $server_num = 0;
    my $first_server_num;
    # FIXME maybe:
    # Save storage space by
    # 1. Dump the first server.
    # 2. For server in (second to last server)
    #       Dump that server
    #       Compare that dump to the dump of the first server
    #       delete the dump of the server if equal to dump of first server
    foreach my $srv (@server) {
        $server_num++;
        if (not defined $srv) {
            # say("DEBUG: Comparison of servers: server[$server_num] is not defined.");
            next;
        } else {
            $first_server_num = $server_num if not defined $first_server_num;
            # The numbering of servers -> name of subdir for data etc. starts with 1!
            # Example:
            # Workdir of RQG run: /data/results/<TS>/<No of RQG runner>
            # Vardir of first DB server: /data/results/<TS>/<No of RQG runner>/1
            # /data/results/<TS>/1 points to /dev/shm/rqg/<No of RQG runner>/1
            # So the dump file is on tmpfs.
            $dump_files[$server_num] = $vardirs[$server_num] . "/DB.dump";
            # Experiment
            # $dump_files[$server_num] = $vardirs[$server_num] . "/Data";
            my $result = $server[$server_num - 1]->nonSystemDatabases1;
            my $server_name = "server[$server_num]";
            if (not defined $result) {
                say("ERROR: Trouble running SQL on $server_name. Will exit with STATUS_ALARM");
                exit_test(STATUS_ALARM);
            } else {
                my @schema_list = @{$result};
                if (0 == scalar @schema_list) {
                    say("WARN: $server_name does not contain non system SCHEMAs. " .
                        "Will create a dummy dump file.");
                    if (STATUS_OK != Basics::make_file($dump_files[$server_num], 'Dummy')) {
                        say("ERROR: Will exit with STATUS_ALARM because of previous failure.");
                        exit_test(STATUS_ALARM);
                    }
                } else {
                    my $schema_listing = join (' ', @schema_list);
                    # say("DEBUG: $server_name schema_listing for mysqldump ->$schema_listing<-");
                    if ($schema_listing eq '') {
                        say("ERROR: Schemalisting for $server_name is empty. " .
                            "Will exit with STATUS_ALARM");
                        exit_test(STATUS_ALARM);
                    } else {
                        my $dump_result = $server[$server_num - 1]->dumpdb("--databases $schema_listing",
                                                                    $dump_files[$server_num]);
                        if ( $dump_result > 0 ) {
                            $final_result = $dump_result >> 8;
                            last;
                        }
                    }
                }
            }
        }
    }
    Auxiliary::update_sizes();
    if ($final_result == STATUS_OK) {
        say("INFO: Comparing SQL dumps...");
        my $server_num = 0;
        my $first_server = "server[$first_server_num]";
        foreach my $srv (@server) {
            $server_num++;
            if (not defined $srv) {
                # say("DEBUG: Comparison of servers: server[$server_num] is not defined.");
                next;
            } elsif ($first_server_num == $server_num) {
                next;
            } else {
                ### 1 vs. 2 , 1 vs. 3 ...
                my $other_server = "server[$server_num]";
                my $diff = system("diff -u $dump_files[$first_server_num] $dump_files[$server_num]");
                if ($diff == STATUS_OK) {
                    say("INFO: No differences were found between $first_server and $other_server.");
                    # Make free space as soon ass possible.
                    # say("DEBUG: Deleting the dump file of $other_server.");
                    unlink($dump_files[$server_num]);
                } else {
                    say("ERROR: Found differences between $first_server and $other_server. " .
                        "Setting final_result to STATUS_CONTENT_MISMATCH.");
                    $diff_result  = STATUS_CONTENT_MISMATCH;
                    $final_result = $diff_result;
                }
            }
        }
        if ($final_result == STATUS_OK) {
            # In case we have no diffs than even the dump of the first server is no more needed.
            say("INFO: No differences between the SQL dumps of the servers detected.");
            # say("DEBUG: Deleting the dump file of $first_server.");
            unlink($dump_files[$first_server_num]);
        } else {
            # FIXME maybe:
            # ok we have a diff. But maybe the dumps of the second and third server are equal
            # and than we could remove one.
        }
    }
    return $final_result;
}
#################################################

sub stopServers {
    # $status is relevant for replication only.
    # status value    | reaction if MariaDB replication involved
    # ----------------+-------------------------------------------------------------------
    # STATUS_OK     | DBServer_e::MySQL::ReplMySQLd::stopServer will call waitForSlaveSync
    # != STATUS_OK  | no call of waitForSlaveSync
    #
    my $status =   shift;
    my $who_am_i = Basics::who_am_i;

    # say("DEBUG: $who_am_i Entering stopServers with assigned status $status");

    if ($skip_shutdown) {
        say("INFO: $who_am_i Server shutdown is skipped upon request");
        return STATUS_OK;
    }
    # For experimenting
    # system("killall -11 mysqld mariadbd");
    my $ret = STATUS_OK;
    say("INFO: $who_am_i Stopping server(s)...");
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
        my $server_num = 0;
        foreach my $srv (@server) {
            $server_num++;
            if (not defined $srv) {
                # say("DEBUG: $who_am_i server[$server_num] is not defined.");
                next;
            } else {
                my $single_ret = $srv->stopServer;
                if (not defined $single_ret) {
                    say("ALARM: $who_am_i The return for stopping server[$server_num] " .
                        "is not defined.");
                } else {
                    $ret = $single_ret if $single_ret != STATUS_OK;
                }
            }
        }
    }
    if (STATUS_FAILURE == $ret) {
        $ret = STATUS_SERVER_SHUTDOWN_FAILURE;
    }
    return $ret;
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
#     We run under "rr", found a data corruption, emit SIGKILL and get a rotten trace.
    my ($silent) = @_;
    my $who_am_i = Basics::who_am_i;

    say("INFO: $who_am_i Killing server(s)...");
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
            $ret = $rplsrv->killServer($silent);
            sleep 10;
        } else {
            $ret = $rplsrv->killServer($silent);
        }
    } elsif (defined $upgrade_test) {
        if (defined $server[1]) {
            $ret = $server[1]->killServer($silent);
        } else {
            $ret = STATUS_OK;
        }
    } else {
        $ret = STATUS_OK;
        my $server_num = 0;
        foreach my $srv (@server) {
            $server_num++;
            if (not defined $srv) {
                # say("DEBUG: $who_am_i server[$server_num] is not defined.");
                next;
            } else {
                my $single_ret = STATUS_OK;
                if ($rr_rules) {
                    $single_ret = $srv->killServer($silent);
                    # sleep 10;
                } else {
                    $single_ret = $srv->killServer($silent);
                }
                if (not defined $single_ret) {
                    say("ALARM: $who_am_i The return for stopping server[$server_num] " .
                        "is not defined.");
                    $ret = STATUS_FAILURE;
                } else {
                    $ret = $single_ret if $single_ret != STATUS_OK;
                }
            }
        }
    }
    if ($ret != STATUS_OK) {
        # say("DEBUG: $who_am_i failed with : ret : $ret");
    }
}

sub help1 {
    print <<EOF

    mysqld    : Options to be set first for all servers.
                If (not defined mysqld) then
                    If (defined mysqld1) then
                        mysqld = mysqld1
                    fi
                fi
    mysqld<m> : Options to be set for the m'th server in addition to what is in mysqld.
                If (not defined mysqld<m>) then
                    (effective) mysqld<m> = mysqld
                else
                    (effective) mysqld<m> = mysqld , mysqld<m>
                fi
                In case of multiple settings of one option than the last wins.
                Example:
                mysqld:  --innodb_page_size=8K <other options>
                mysqld1: --innodb_page_size=16K
                         --> --innodb_page_size=8K <other options> --innodb_page_size=16K
                         --> <other options> --innodb_page_size=16K

    For all mysqld*: Do not set server system variables containing paths or file names like
                     --datadir or --log_error.
                     rqg.pl and components used calculate such paths and names.
                     They either win or the RQG run ends in a disaster.

    basedir    : Base directory (== directory with binaries) for any server n if basedir<n> is not specified..
                 If (not defined basedir) then
                     If (defined basedir1) then
                         basedir = basedir1
                     else
                         abort
                     fi
                 fi
    basedir<m> : Specifies the base directory for the m'th server.
                 If (not defined basedir<m>) then
                     (effective) basedir<m> = basedir
                 fi

EOF
  ;
}

sub help {

    print <<EOF
Copyright (c) 2010,2011 Oracle and/or its affiliates. All rights reserved. Use is subject to license terms.
Copyright (c) 2018,2022 MariaDB Corporation Ab.

$0 - Run a complete random query generation (RQG) test.
     Sorry, the description here might be partially outdated.

     How to catch output:
     Sorry the shape of the command lines is not really satisfying.
     perl rqg.pl ... --logfile=<RQG log>        # Output to screen and log file
     perl rqg.pl ... > <workdir>/rqg.log   2>&1 # Output to log file only
     perl rqg.pl ...   2>&1                     # Output to screen only

    <workdir> == Workdir of the current RQG run.
                 It gets calculated from the settings in local.cfg and
                 the values assigned to
                 --minor_runid (optional, default 'SINGLE_RUN')

    Options related to one standalone MariaDB server:

    --basedir   : Specifies the base directory of the stand-alone MariaDB installation (location of binaries)
    --mysqld    : Options passed to the MariaDB server

    Options related to two MariaDB servers

    --basedir1  : Specifies the base directory of the first MariaDB installation
    --basedir2  : Specifies the base directory of the second MariaDB installation
    --mysqld    : Options passed to both MariaDB servers
    --mysqld1   : Options passed to the first MariaDB server
    --mysqld2   : Options passed to the second MariaDB server
    The options --vardir* are no more supported.
    RQG computes the location of the vardir of the RQG run based on --vardir_type and 'local.cfg'.
    The vardirs of the servers will be subdirectories of that vardir of the RQG run.
    The options --debug-server* are no more supported.

    General options if not explained above
    ======================================
    In case of multiple assignments the behavior is "The last wins" except stated otherwise.

    All work phases
    ---------------
    --rpl_mode     : Replication type to use (statement|row|mixed) (default: no replication).
                     The mode can contain modifier 'nosync', e.g. row-nosync. It means that at the end the test
                     will not wait for the slave to catch up with master and perform the consistency check
    --use_gtid     : Use GTID mode for replication (current_pos|slave_pos|no). Adds the MASTER_USE_GTID clause to CHANGE MASTER,
                     (default: empty, no additional clause in CHANGE MASTER command).
    --galera       : Galera topology, presented as a string of 'm' or 's' (master or slave).
                     The test flow will be executed on each "master". "Slaves" will only be updated through Galera replication
    --engine       : Table engine to use when creating tables with gendata (default no ENGINE in CREATE TABLE).
                     Different values can be provided to servers through --engine1 | --engine2 | --engine3
    --logfile      : Generates rqg output log at the path specified.(Requires the module Log4Perl)
    --minor_runid  : Name of subdirectories. If not defined than its the UNIX timestamp from the start of the test.
                     The directories containing this subdirectory get calculated from the settings in local.cfg.
                     Examples:
                     /data/results/<TIMETANP>     for ongoing and finished RQG runs
                     /dev/shm/rqg/<TIMETANP>      for ongoing RQG run
                     /dev/shm/rqg_ext4/<TIMETANP> for ongoing RQG run
    --valgrind     : Start the DB server with valgrind, adjust timeouts to the use of valgrind
    --valgrind_options : Use these additional options for any start under valgrind
    --rr           : Start the DB server and mariabackup under rr including adjust timeouts to the use of rr
    --rr_options   : Use these additional options for any start under rr
    --wait-for-debugger: Pause and wait for keypress after server startup to allow attaching a debugger to the server process.
    --sqltrace     : Print all generated SQL statements (tracing before execution)
                     Optional: Specify
                     --sqltrace=MarkErrors   with mark invalid statements. (tracing after execution)
                     --sqltrace=Concurrency  with mark invalid statements. (tracing before and after execution)
                     --sqltrace=File         Write a trace to <workdir>/rqg.trc (tracing before execution)
    --mtr-build-thread: Value used for MTR_BUILD_THREAD when servers are started and accessed
    --debug        : Debug mode (refers mostly to RQG and grammars)

    Work phase GenData
    ------------------
    --gendata      : Generate data option. Passed to lib/GenTest_e/App/Gentest.pm. Takes a data template (.zz file)
                     as an optional argument. Without an argument, indicates the use of GendataSimple (default).
    --gendata-advanced: Generate the data using GendataAdvanced instead of default GendataSimple
    --short_column_names: use short column names in gendata (Example: c1)
    --strict_fields: Disable all AI applied to columns defined in \$fields in the gendata file. Allows for very specific column definitions
    --gendata_sql  : Generate data option. Passed to lib/GenTest_e/App/Gentest.pm. Takes files containing SQL as argument.
                     These files get processed after running Gendata, GendataSimple or GendataAdvanced.
    --notnull      : Generate all fields with NOT NULL
    --rows         : No of rows. Passed to lib/GenTest_e/App/Gentest.pm.
    --varchar-length: length of strings. Passed to lib/GenTest_e/App/Gentest.pm.
    --vcols        : Types of virtual columns (only used if data is generated by GendataSimple or GendataAdvanced)
    --views        : Generate views. Optionally specify view type (algorithm) as option value. Passed to lib/GenTest_e/App/Gentest.pm.
                     Different values can be provided to servers through --views1 | --views2 | --views3
    --max_gd_duration : Abort the RQG run in case the work phase Gendata lasts longer than max_gd_duration
    --gendata_dump : After running the work phase Gendata dump the content of the first DB server to the
                     file 'after_gendata.dump'. (OPTIONAL)

    Work phase GenTest
    ------------------
    --grammar      : Grammar file (extension '.yy') to use when generating queries (REQUIRED)
                     --grammar=A --grammar=B is equivalent to --grammar=B
    --redefine     : Grammar file(s) (extension '.yy') to redefine and/or add rules to the given grammar (OPTIONAL)
                     --redefine=A,B,C --redefine=C is equivalent to --redefine=A,B,C
    --threads      : Number of threads to spawn (default $default_threads).
    --queries      : Maximum number of queries to execute per thread (default $default_queries).
    --duration     : Maximum duration of the test in seconds (default $default_duration seconds).
    --validators   : The validators to use
                     --validators=A,B,C --validators=C is equivalent to --validators=A,B,C
    --reporters    : The reporters to use
                     --reporters=A,B,C --reporters=C is equivalent to --reporters=A,B,C
    --transformers : The transformers to use (leads to addition of --validator=transformer).
                     --transformers=A,B,C --transformers=C is equivalent to --transformers=A,B,C
    --querytimeout : The timeout to use for the QueryTimeout reporter
                     Sometimes useful for test simplification but otherwise a wasting of resources.
    --seed         : PRNG seed. Passed to lib/GenTest_e/App/Gentest.pm.
    --mask         : Grammar mask. Passed to lib/GenTest_e/App/Gentest.pm.
    --mask-level   : Grammar mask level. Passed to lib/GenTest_e/App/Gentest.pm.
    --filter       : File for disabling the execution of SQLs containing certain patterns. Passed to lib/GenTest_e/App/Gentest.pm.
    --freeze_time  : Freeze time for each query so that CURRENT_TIMESTAMP gives the same result for all transformers/validators
    --annotate-rules: Add to the resulting query a comment with the rule name before expanding each rule.
                      Useful for debugging query generation, otherwise makes the query look ugly and barely readable.
    --restart-timeout: If the server has gone away, do not fail immediately, but wait to see if it restarts (it might be a part of the test)
    --upgrade-test : enable Upgrade reporter and treat server1 and server2 as old/new server, correspondingly. After the test flow
                     on server1, server2 will be started on the same datadir, and the upgrade consistency will be checked
                     Non simple upgrade variants will most probably fail because of weaknesses in RQG. Sorry for that.
    --rounds       : Number of    GenTest(execute SQL generated from grammar+redefines) + check the DB server etc.    rounds.(default 1)

    --help         : This help message
    --help_sqltrace : help about SQL tracing by RQG
    --help_dbdir_type   : help about the parameter dbdir_type

EOF
    ;
    print "\n$0 arguments were: " . join(' ', @ARGV_saved) . "\n";
}

sub exit_test {
    my ($status, $silent) = @_;
    $silent = 0 if not defined $silent;
    $silent = 1 if $status == STATUS_OK;

    # Variants
    # 1.  Around end of test
    # 1a  status was < STATUS_CRITICAL_FAILURE and stopServers was tried
    #     The escalation is: admin shutdown -> term -> crashServer -> killServer
    # 1b  status was > STATUS_CRITICAL_FAILURE and killServer was tried
    # Hence it is unlikely that some server is running.
    # 2.  Somewhere around begin of test
    #     Some fatal error was hit and it is not unlikely that some server is running.
    # Hence some harsh killServers instead of stopServers is acceptable.
    killServers($status, $silent);

    my $return = Auxiliary::set_rqg_phase($workdir, Auxiliary::RQG_PHASE_FINISHED);

    $message =  "RQG total runtime in s : " . (time() - $rqg_start_time);
    $summary .= "SUMMARY: $message\n";
    say("INFO: " . $message);

    if (not defined $logfile) {
        $logfile = $workdir . '/rqg.log';
    }

    Auxiliary::report_max_sizes;
    run_end($status);
}

sub run_end {
    my ($status) = @_;
    say($summary);
    # There might be failures in the process handling of the RQG mechanics.
    # So better try to kill all left over processes being in the same process group
    # but not the current process only.
    kill '-9', $$;
    Auxiliary::reapChildren;

    show_processes();

    # Tolerate that we might fail before $vardirs[0] is set or checked and
    # avoid by that perl warnings etc.
    if (defined $vardirs[0] and -e $vardirs[0]) {
        Auxiliary::tweak_permissions($vardirs[0]);
    }
    # tweak_permissions reports errors and returns a status.
    # The latter is rather unimportant.
    say(STATUS_PREFIX . status2text($status) . "($status)");
    safe_exit($status);
}

sub show_processes {

    my $cmd1 = "ps -o user,pid,ppid,pgid,args -p " . $$;
    $return = `$cmd1`;
    if (not defined $return) {
          # say("DEBUG: ->" . $cmd1 . "<- harvested some undef result.");
    } elsif ('' eq $return) {
          # say("DEBUG: ->" . $cmd1 . "<- harvested an empty string.");
    } else {
          say("INFO: About current process -- begin");
          say($return);
          # The remaining processes of our processgroup.
          Auxiliary::print_ps_tree($$);
          say("INFO: About current process -- end");
    }

    $cmd1 = "fuser " . join("/tcp ", @ports) . "/tcp 2>err";
    # fuser 10443/tcp
    # 10443/tcp:            5112
    #  ps -elf | grep 5112
    # 0 S mleich      5112    2731  0  80   0 -  4361 do_pol 12:11 pts/12   00:00:01 ssh sdp
    # 0 S mleich      5113    5112  0  80   0 -  4377 do_pol 12:11 pts/12   00:00:01 ssh -W 192.168.7.2:22 sshserver
    # my $cmd1 = "fuser " . join("/tcp ", @ports) . "/tcp 10443/tcp 10022/tcp 10022/tcp 2>err";
    # err contains something like
    my $return = `$cmd1`;
    if (not defined $return) {
        # say("DEBUG: ->" . $cmd1 . "<- harvested some undef result.");
    } elsif ('' eq $return) {
        # say("DEBUG: ->" . $cmd1 . "<- harvested an empty string.");
    } else {
        # say("DEBUG: ->" . $cmd1 . "<- harvested ->" . $return . "<-");
        # Some typical return
        # -> 150522 150522 150522<-
        # Remove the leading space.
        $return =~ s/^\s+//;
        my @pid_list = split (/\s+/, $return);
        # say("DEBUG: pid_list ->" . join("-", @pid_list) . "<-");
        my %pid_hash;
        foreach my $pid (@pid_list) {
           $pid_hash{$pid} = 1;
        }
        say("INFO: Processes using the ports: " . join(' ', sort {$a <=> $b} keys %pid_hash) . "\n");
        foreach my $pid (sort {$a <=> $b} keys %pid_hash) {
            $cmd1 = "ps -o user,pid,ppid,pgid,args -p " . $pid;
            $return = `$cmd1`;
            if (not defined $return) {
                  say("DEBUG: ->" . $cmd1 . "<- harvested some undef result.");
            } elsif ('' eq $return) {
                  say("DEBUG: ->" . $cmd1 . "<- harvested an empty string.");
            } else {
                  say("DEBUG: ->" . $cmd1 . "<- harvested ->" . $return . "<-");
            }
            Auxiliary::print_ps_tree($pid);
            my $pgid = getpgrp($pid);
            if($pgid != $pid) {
                say("INFO: process with pid = pgid of process using the port.");
                $cmd1 = "ps -o user,pid,ppid,pgid,args -p " . $pgid;
                $return = `$cmd1`;
                if (not defined $return) {
                      say("DEBUG: ->" . $cmd1 . "<- harvested some undef result.");
                } elsif ('' eq $return) {
                      say("DEBUG: ->" . $cmd1 . "<- harvested an empty string.");
                } else {
                      say("DEBUG: ->" . $cmd1 . "<- harvested ->" . $return . "<-");
                }
                Auxiliary::print_ps_tree($pgid) if $pgid != $pid;
            }
        }
    }
}

1;

