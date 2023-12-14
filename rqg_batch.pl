#!/usr/bin/perl

# Copyright (c) 2018, 2022 MariaDB Corporation Ab.
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
#

# Note about history and future of this script:
# ---------------------------------------------
# The concept and code here is only in small portions based on
# - util/bughunt.pl
#   - Per just finished RQG run
#     1. immediate judging based on status + text patterns (done by calling Verdict.pl)
#     2. creation of archives if necessary (done by calling Auxiliary::archive_results)
#     3. first cleanup
#   - unification regarding storage places
# - combinations.pl
#   Parallelization + combinations mechanism
# There we have GNU General Public License version 2 too and
#    Copyright (c) 2008, 2011 Oracle and/or its affiliates. All rights reserved.
#    Copyright (c) 2013, Monty Program Ab.
#    Copyright (c) 2018, MariaDB Corporation Ab.
# Both perl programs were removed from my current RQG version.
#
# The amount of parameters (call line + config file) is in the moment
# not that stable.
#

use strict;
use Carp;
use File::Basename; # We use dirname , make_path
use Cwd;            # We use abs_path , getcwd
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
use Time::HiRes;
use POSIX ":sys_wait_h"; # for nonblocking read
use File::Path qw(make_path);
use File::Copy;
use Auxiliary;
use Basics;
use Local;
use Verdict;
use Batch;
use Combinator;
use Runtime;
use Simplifier;
use SQLtrace;
use GenTest_e;
use GenTest_e::Random;
use GenTest_e::Constants;
use Getopt::Long;
use Data::Dumper;

use ResourceControl;

# Structure for managing RQG Worker (child processes)
# ---------------------------------------------------
# RQG Worker 'life'
# 0. Get forked by the parent (rqg_batch.pl) process and "know" already at begin of life detailed
#    which RQG run to initiate later, where to store data etc.
# 1. Make some basic preparations of the "play ground".
# 2. Start to the RQG runner (usually rqg.pl) via Perl 'system'.
# -- What follows is some brief description what this RQG runner does --
# 3. Analyze the parameters/options provided via command line. In future maybe also config files.
# 4. Compute all values which distinct him from other RQG workers (workdir, vardir, build thread)
#    but will be the same when he makes his next RQG run.
# 3. Append these values to the RQG call.
# 4. Start the RQG run with system.
# 5. Make some analysis of the result and report the verdict.
# 6. Perform archiving if needed, cleanup, signal that the work is finished and exit.
# The parent has to perform some bookkeeping about the actual state of the RQG workers in order to
# - avoid double use of such a worker (Two RQG tests would meet on the same vardirs, ports etc.!)
# - be capable to stop active RQG worker whenever it is recommended up till required.
#   Typical reasons: Regular test end, resource trouble ahead, tricks for faster replay etc.
#
# Batch.pm contains the following definition which we use here quite often
# our @worker_array = ();
#    use constant WORKER_PID         =>  0;
#    use constant WORKER_START       =>  1;
#    use constant WORKER_ORDER_ID    =>  2;
#    use constant WORKER_EXTRA1      =>  3; # child grammar == grammar used if Simplifier
#    use constant WORKER_EXTRA2      =>  4; # parent grammar if Simplifier
#    use constant WORKER_EXTRA3      =>  5; # adapted duration if Simplifier
#    use constant WORKER_END         =>  6;
#    use constant WORKER_VERDICT     =>  7;
#    use constant WORKER_LOG         =>  8;
#    use constant WORKER_STOP_REASON =>  9; # in case the run was stopped than the reason
#    use constant WORKER_V_INFO      => 10; # Additional info around the verdict
#    use constant WORKER_COMMAND     => 11; # Essentials of RQG call
# In case a 'stop_worker' had to be performed than WORKER_END will be set to the current timestamp
# when issuing the SIGKILL that RQG worker processgroup.
# When 'reap_worker' gets active the following should happen
# if defined WORKER_END
#    make a note within the RQG log of the affected worker that he was stopped
#    set verdict to VERDICT_IGNORE_STOPPED etc.
# else
#    set WORKER_END will be set to the current timestamp
#

# Name of the convenience symlink if symlinking supported by OS
use constant BATCH_RESULT_SYMLINK    => 'last_result_dir';

my $command_line= "$0 ".join(" ", @ARGV);
my @ARGV_saved = @ARGV;

$| = 1;

my $batch_start_time = time();

# Currently unused
my $start_cwd     = Cwd::getcwd();

if ( osWindows() )
{
    require Win32::API;
    my $errfunc = Win32::API->new('kernel32', 'SetErrorMode', 'I', 'I');
    my $initial_mode = $errfunc->Call(2);
    $errfunc->Call($initial_mode | 2);
};

my $logger;
eval
{
    require Log::Log4perl;
    Log::Log4perl->import();
    $logger = Log::Log4perl->get_logger('randgen.gentest');
};

$| = 1;
my $ctrl_c = 0;

# FIXME: Discover Which impact has the value within $ctrl_c?
#
# SIGINT should NOT lead to some abort of the rqg_batch.pl run.
# A
#     $SIG{INT}  = sub { Batch::emergency_exit("INFO: SIGTERM or SIGINT received. " .
#                               "Will stop all RQG worker and exit without cleanup.", STATUS_OK) };
# would cause exact some abort with cleanup but without summary.
$SIG{INT}  = sub { $ctrl_c = 1 };
# SIGTERM should lead to some abort with cleanup but without summary.
$SIG{TERM} = sub { Batch::emergency_exit(STATUS_OK, "INFO: SIGTERM or SIGINT received. Will stop " .
                                         "all RQG worker and exit without cleanup.") };
$SIG{CHLD} = "IGNORE" if osWindows();

my ($config_file, $basedir, $vardir, $trials, $duration, $grammar, $gendata,
    $seed, $max_runtime,
    $force, $no_mask, $exhaustive, $start_combination, $dryrun, $noLog,
    $parallel, $noshuffle, $workdir, $discard_logs, $max_rqg_runtime,
    $help, $help_simplifier, $help_combinator, $help_verdict, $help_rr, $help_archiving, $help_local,
    $help_rqg_home, $help_dbdir_type, $runner, $noarchiving,
    $rr, $rr_options, $sqltrace,
    $dbdir_type, $vardir_type, $fast_vardir, $slow_vardir,
    $stop_on_replay, $script_debug_value, $runid, $threads, $type, $algorithm, $resource_control);

use constant DEFAULT_MAX_RQG_RUNTIME => 7200;

# my @basedirs    = ('', '');
my @basedirs;


$discard_logs  = 0;

# FIXME:
# Modify these options.
# --debug
# This should rather focus on debugging of the current script.
# ------------
# --no-log
# Figure out what is does.
# Printing the output of combinations.pl and also the output of the RQG runners to
# screen makes no sense. Too much of too mixed content.
# ------------
# --force how it works here is quite questionable in several aspects
# 1. In case of not that good setups, grammars and/or certain trouble in server
#    likely STATUS_ENVIRONMENT_FAILURE
#    not likely perl errors could happen.
#    So some fault tolerance makes at least a bit sense.
# 2. On the other hand:
#    Its questionable if too lazy programming/setups/comb config files should get
#    that much comfort.
# 3. MTR makes that better though also not perfect.
# 4. Default should be:
#    In case the first chunk of tests (10 or 20) dies early
#    (loading of grammars/validators, maybe bootstrap and similar) than the run
#    should be aborted.
#    Lets say: In case the early failing tests are
#              >= 50% of all tests executed and their number is alreay >= 10.
#    Some reduced use of STATUS_ENVIRONMENT_FAILURE and distinct more different
#    bad statuses seem to be required.
#    For the moment: Do not change the current semantics.
# 5. no-mask
#    Applying masking everywhere might be good for optimizer tests but is poison
#    for concurrency tests.
#    1. Flip the default masking off!
#    2. Preserve the no-mask (-> override the setting from config file)
#

# Take the options assigned in command line and
# - fill them into the variables allowed in command line
# - abort in case of meeting some not supported options
my $opt_result = {};
sub help();

# Read certain command line options
# =================================
# - Read all options (GetOptions removes all options found from @ARGV) which do not need to
#    be passed to any module in the list Combinator, Simplifier, Variator, Replayer
# - 'pass_through' causes that we do not abort in case meeting some option which is not listed here.
# - The difference between "parm=s" and "parm:s"
#   Assignment       Content of $parm
#                    parm=s           parm:s
#   <no --parm...>   undef            undef
#   --parm           undef            ''
#   --parm=          undef            ''
#   --parm=otto      'otto'           'otto'
# Example:
# 'threads'
# 1. In case the value is assigned on command line than
# 1.1 rqg_batch could
#     memorize it, not pass it through to Combinator, Variator, Replayer and glue it to every RQG call.
# 1.2 if the Simplifier is used rqg_batch needs to pass that value through to Simplifier because
#     that value is used for optimizing the simplification
#     Example: If thread = 3 than any thread_< n>3 >_* becomes never used.
# 2. In case the value is not assigned on command line but can be assigned in config file than
#    the config file reader (Combinator, Simplifier, Variator, Replayer) will read the value and
#    needs to pass it somehow back to rqg_batch.
# Problem with 'pass_through'
#    rqg.pl call was with
#    --dryrun     \   <== mandatory value is missing!!
#    --parallel=2 \
#    --threads=2
# Later $dryrun contained '--parallel=2' and $parallel was undef.
Getopt::Long::Configure('pass_through');
if (not GetOptions(
#   $opt_result,
           'help'                      => \$help,
           'help_simplifier'           => \$help_simplifier,
           'help_combinator'           => \$help_combinator,
           'help_verdict'              => \$help_verdict,
           'help_local'                => \$help_local,
           'help_rr'                   => \$help_rr,
           'help_archiving'            => \$help_archiving,
           'help_dbdir_type'           => \$help_dbdir_type,
           'help_rqg_home'             => \$help_rqg_home,
           ### type == Which type of campaign to run
           # pass_through: no
           'type=s'                    => \$type,        # Swallowed and handled by rqg_batch
           ### config == Details of campaign setup
           # Check existence of file here. pass_through as parameter
           'config=s'                  => \$config_file, # Check+set here but pass as parameter to Combinator etc.
           ### basedir<n>
           # Check here if assigned basedir<n> exists.
           # Do not pass_through. Glue to end of rqg.pl call.
####       'basedir=s'                 => \$basedirs[0],
           'basedir1=s'                => \$basedirs[1],  # Swallowed and handled by rqg_batch
           'basedir2=s'                => \$basedirs[2],  # Swallowed and handled by rqg_batch
           'basedir3=s'                => \$basedirs[3],  # Swallowed and handled by rqg_batch
#          'workdir=s'                 => \$workdir,      # Check+set here but pass as parameter to Combinator etc.
           'dbdir_type=s'              => \$dbdir_type,   # Swallowed and handled by rqg_batch
           'vardir_type=s'             => \$vardir_type,  # Swallowed and handled by rqg_batch
#          'vardir=s'                  => \$vardir,       # Swallowed and handled by rqg_batch      local.cfg
#          'build_thread=i'            => \$build_thread, # Swallowed and handled by rqg_batch     local.cfg
#          'trials=i'                  => \$trials,       # Pass through (@ARGV) to Combinator ...
#          'duration=i'                => \$duration,     # Pass through (@ARGV) to Combinator ...
#          'seed=s'                    => \$seed,         # Pass through (@ARGV) to Combinator ...
           'force'                     => \$force,                  # Swallowed and handled by rqg_batch
#          'no-mask'                   => \$no_mask,      # Pass through (@ARGV) to Combinator ...
#          'grammar=s'                 => \$grammar,      # Pass through (@ARGV) to Combinator ...
           'gendata=s'                 => \$gendata,                # Currently handle here
#          'run-all-combinations-once' => \$exhaustive,             # Pass through (@ARGV). Combinator maybe needs that
#          'start-combination=i'       => \$start_combination,      # Pass through (@ARGV). Combinator maybe needs that
#          'no-shuffle'                => \$noshuffle,              # Pass through (@ARGV). Combinator maybe needs that
           'max_runtime=i'             => \$max_runtime,            # Swallowed and handled by rqg_batch
           'dryrun=s'                  => \$dryrun,                 # Swallowed and handled by rqg_batch
           'no-log'                    => \$noLog,                  # Swallowed and handled by rqg_batch
           'parallel=i'                => \$parallel,               # Swallowed and handled by rqg_batch
           # runner
           # If
           # - defined than
           #   - check existence etc.
           #   - wipe out any runner if in call line snip returned by module
           # - not defined or '' than
           #   If runner in call line snip returned by module than use that.
           #   If no runner in call line snip than use 'rqg.pl'.
           'runner=s'                  => \$runner,                 # Swallowed and handled by rqg_batch
           # <option>:1   Value is optional, if no value given than treat as if 1 given
           'stop_on_replay:1'          => \$stop_on_replay,         # Swallowed and handled by rqg_batch
           'noarchiving'               => \$noarchiving,            # Swallowed and handled by rqg_batch
           'rr:s'                      => \$rr,                     # Swallowed and handled by rqg_batch
           'rr_options=s'              => \$rr_options,             # Swallowed and handled by rqg_batch
           'sqltrace:s'                => \$sqltrace,               # Swallowed and handled by rqg_batch
#          'threads=i'                 => \$threads,                # Pass through (@ARGV). Simplifier maybe needs that
           'discard_logs'              => \$discard_logs,           # Swallowed and handled by rqg_batch
           'discard-logs'              => \$discard_logs,
           'resource_control=s'        => \$resource_control,       # Swallowed and handled by rqg_batch
           'script_debug=s'            => \$script_debug_value,     # Swallowed and handled by rqg_batch
           'runid:i'                   => \$runid,                  # Swallowed and handled by rqg_batch
                                                   )) {
    if (not defined $help             and
        not defined $help_simplifier  and not defined $help_combinator and
        not defined $help_verdict     and not defined $help_rr         and
        not defined $help_dbdir_type                                     and
        not defined $help_archiving   and not defined $help_rqg_home      ) {
        # Somehow wrong option.
        help();
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }
};

# Do not fiddle with other stuff when help is requested.
if (defined $help) {
    help();
    safe_exit(0);
} elsif (defined $help_combinator) {
    Combinator::help();
    safe_exit(0);
} elsif (defined $help_simplifier) {
    Simplifier::help();
    safe_exit(0);
} elsif (defined $help_rqg_home) {
    Auxiliary::help_rqg_home();
    safe_exit(0);
} elsif (defined $help_verdict) {
    Verdict::help();
    safe_exit(0);
} elsif (defined $help_dbdir_type) {
    Local::help_dbdir_type();
    safe_exit(0);
} elsif (defined $help_rr) {
    Runtime::help_rr();
    safe_exit(0);
} elsif (defined $help_archiving) {
    Batch::help_archiving();
    safe_exit(0);
}


# Support script debugging as soon as possible.
# my $scrip_debug_string = Auxiliary::script_debug_init($script_debug_value);
$script_debug_value = Auxiliary::script_debug_init($script_debug_value);
# FIXME: Its outdated
# For testing if script_debug works:
# 1. Enable the following two lines
#    say("script_debug match of 'T4'") if Auxiliary::script_debug("T4");
#    exit;
# 2. Append to the rqg_batch call
#    --script_debug=_all_
#        INFO: script_debug : _all_
#        script_debug match of 'T4'
#    --script_debug=1,T4,1,2
#        INFO: script_debug : T4,2,1
#        script_debug match of 'T4'
#    --script_debug=A,B,4,C
#        INFO: script_debug : A,C,4,B
#        script_debug match of 'T4'
#    --script_debug=T,B,4,C
#        INFO: script_debug : 4,T,C,B
#        script_debug match of 'T4'
#    --script_debug=T3,B,C
#        INFO: script_debug : B,T3,C
#    --script_debug=T3,,C
#        WARN: script_debug element '' omitted. In case you want all debug messages assign '_all_'.
#        INFO: script_debug : T3,C
#    --script_debug=''
#        INFO: script_debug :
#    --script_debug=''
#        INFO: script_debug :
#    --script_debug=T4 --script_debug=B
#        INFO: script_debug : B,T4
#        script_debug match of 'T4'
#    no --script_debug=...... assigned
#        INFO: script_debug :
#

# For testing
# $type='omo';
Batch::check_and_set_batch_type($type);

Local::check_and_set_rqg_home($rqg_home);

# Solution for compatibility with older config files where the parameter 'vardir_type' was used.
if (not defined $dbdir_type) {
    $dbdir_type = $vardir_type;
}

# Read local.cfg and make the infrastructure down to <whatever>/<runid>.
# ($major_runid, $minor_runid, $dbdir_type, my $batch)
Local::check_and_set_local_config(undef, undef, $dbdir_type, 2);
# Never use $vardir = Local::get_vardir();

# In case rr is invoked and local.cfg contains some defined value rr_options_add than
# rqg.pl will pick the rr_options_add value and take care that its used.
# == No need to do this here.
my $status = Runtime::check_and_set_rr_valgrind ($rr, $rr_options, undef, undef, 1);
if ($status != STATUS_OK) {
    say("The $0 arguments were ->" . join(" ", @ARGV_saved) . "<-");
    say("$0 will exit with exit status " . status2text($status) . "($status)");
    safe_exit($status);
}
$rr =         Runtime::get_rr();
# Any $rr_options_add needs to be added when the cmd for the RQG runner gets defined.
# get_rr_options returns a union of rr_options and rr_options_add.
$rr_options = Runtime::get_rr_options();
# say("DEBUG: rr_options ->" . $rr_options . "<-");

# FIXME:
# Hard (apply no matter what duration is) or soft (adjust how?) border?
# Set in call line --> apply to all RQG runs started. What if duration in config file and bigger?
# Set in config file                 --> apply in general ?
# Set in config file for one variant --> apply how ?
$max_rqg_runtime = DEFAULT_MAX_RQG_RUNTIME if not defined $max_rqg_runtime;
say("INFO: Maximum runtime of a single RQG run $max_rqg_runtime" . "s.");

check_and_set_config_file();

# Variable for stuff to be glued at the end of the rqg.pl call.
my $cl_end = '';

# $basedir_info is required for result.txt and setup.txt.
my $basedir_info = '';
# For testing:
# $basedirs[1] = '/weg';

# check_basedirs exits in case of failure.
@basedirs = Auxiliary::check_basedirs(@basedirs);
foreach my $i (1..3) {
    $cl_end .= " --basedir" . "$i" . "=" . $basedirs[$i]
       if defined $basedirs[$i] and $basedirs[$i] ne '';
}

# Convenience feature
# -------------------
# Make a symlink so that the last work/resultdir used by some tool performing multiple RQG runs like
#    combinations.pl, bughunt.pl, simplify_grammar.pl
# is easier found.
# Creating the symlink might fail on some OS (see perlport) but should not abort our run.
my $symlink = $Local::rqg_home . "/" . BATCH_RESULT_SYMLINK;
unlink($symlink);
my $symlink_exists = eval { symlink($Local::results_dir, $symlink) ; 1 };

# $workdir, $vardir are the "general" work/var directories of rqg_batch.pl run.
$workdir = Local::get_results_dir();
# say("DEBUG: $workdir "); # with runid

my $bin_arch_dir = Local::get_binarch_dir();

# Generate the infrastructure (several files) for bookkeeping of all the RQG runs somehow finished
# ------------------------------------------------------------------------------------------------
Batch::make_infrastructure($workdir);

if (defined $sqltrace) {
    $sqltrace = SQLtrace::check_sqltracing($sqltrace);
    if (not defined $sqltrace) {
        $status = STATUS_ENVIRONMENT_FAILURE;
        safe_exit($status);
    };
}

my $info;
$info = "INFO: RQG_HOME   : ->" . $rqg_home . "<- ";
$info .= Auxiliary::get_git_info($rqg_home);
$info .= "\n" . Auxiliary::get_all_basedir_infos(@basedirs);
say($info);
# Replace INFO (typical for logs) with '$iso_ts '(better for summaries)'.
my $iso_ts = isoTimestamp();
$info =~ s/INFO: /$iso_ts /g;
if (STATUS_OK != Basics::make_file($workdir . "/" . Auxiliary::SOURCE_INFO_FILE, $info)) {
    safe_exit(STATUS_ENVIRONMENT_FAILURE);
}

if (not defined $resource_control) {
    say("DEBUG: resource_control is not defined") if Auxiliary::script_debug("T2");
}
my ($load_status, $workers_mid, $workers_min) =
    # FIXME, maybe:
    # This is not roughly 100% safe because rqg_slow_dir gets not perfect attention.
    ResourceControl::init($resource_control, $workdir,
                          Local::get_rqg_fast_dir(), Local::get_rqg_slow_dir());
if($load_status ne ResourceControl::LOAD_INCREASE) {
    $status = STATUS_ENVIRONMENT_FAILURE;
    say("ERROR: ResourceControl reported the load status '$load_status' but around begin the " .
        "status '" . ResourceControl::LOAD_INCREASE . "' must be valid.");
    safe_exit($status);
}
if (not defined $parallel) {
    say("WARN: There was no upper limit for the number of parallel RQG runners (--parallel=...) " .
        "assigned.");
    $parallel = $workers_mid;
    say("INFO: Setting the upper limit for the number of parallel RQG runners to $parallel.");
}
Batch::set_workers_range($parallel, $workers_mid, $workers_min);

if (defined $gendata) {
    $cl_end .= " --gendata=$gendata";
    if ($gendata ne '' and not -f $gendata) {
        say("ERROR: gendata is set to '" . $gendata .
            "' but does not exist or is not a plain file.");
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }
}

$cl_end .= " --script_debug=" . $script_debug_value
    if $script_debug_value ne '';
$cl_end .= " --sqltrace=" . $sqltrace if defined $sqltrace;

my $cl_begin = '';

use constant DEFAULT_RQG_RUNNER => 'rqg.pl';
if (not defined $runner) {
    $runner = DEFAULT_RQG_RUNNER;
    say("INFO: RQG runner was not assigned. Taking the default '$runner'.");
}
if (defined $runner) {
    if (File::Basename::basename($runner) ne $runner) {
        say("Error: The value for the RQG runner '$runner' needs to be without any path.");
        safe_exit(4);
    }
    # For experimenting
    # $runner = 'mimi';
    my $runner_file = $rqg_home . "/" . $runner;
    if (not -e $runner_file) {
        $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: The RQG runner '$runner_file' does not exist. " .
            Basics::exit_status_text($status));
        safe_exit($status);
    }
}

Batch::check_and_set_dryrun($dryrun);
Batch::check_and_set_stop_on_replay($stop_on_replay);
## say("DEBUG: stop_on_replay ->" . $stop_on_replay . "<-");
Batch::check_and_set_discard_logs($discard_logs);


# FIXME: Harden + restructure the code which follows.
my @subdir_list;
my $extension;
if (osWindows()) {
    @subdir_list = ("sql/Debug", "sql/RelWithDebInfo", "sql/Release", "bin");
    $extension   = ".exe";
} else {
    @subdir_list = ("sql", "libexec", "bin", "sbin");
    $extension   = "";
}
if (not defined $noarchiving) {
    $noarchiving = 0;
}
if ($noarchiving) {
    say("INFO: Archiving of data of interesting RQG runs is disabled.");
    if (defined $rr) {
        say("ERROR: 'rr' tracing without archiving is not supported.");
        $status = STATUS_ENVIRONMENT_FAILURE;
        safe_exit($status);
    }
} else {
    say("INFO: Archiving of data of interesting RQG runs is enabled.");
    if ( STATUS_OK == Auxiliary::find_external_command('xz') ) {
    } else {
        say("ERROR: The compressor 'xz' was not found.");
        $status = STATUS_ENVIRONMENT_FAILURE;
        safe_exit($status);
    }

    ######### Archive/Preserve the binaries by hardlinking
    # Goals:
    # 1. Be able to
    #    - analyze the results of failing tests
    #    - repeat the run of some testbattery
    #    even if
    #    - the MariaDB installation used during testing was deleted
    #    - the archive of the MariaDB was deleted from the directy for archives of installations
    # 2. Minimize storage space consumption.
    #
    # The general directory for archives of binaries/archive of installations is in
    # $bin_arch_dir. Auxiliary::make_multi_runner_infrastructure has already
    # calculated its value, created that directory if missing and returned that value.
    #
    # Description of concept by example:
    # 1. cd <source tree dirs>
    #    git clone https://github.com/MariaDB/server.git 10.8
    #    cd 10.8
    #    git checkout origin/10.8
    #    Maybe apply patches.
    #    bld_asan.sh 10.8
    # 2. Get after the build
    #    - <directory for installed binaries>/10.8_asan with some installed MariaDB
    #      and the two additional files
    #      short.prt -- important (git show, git diff, cmake ...) information only
    #      build.prt -- very detailed information about the build
    #    - within the directory for archived binaries some
    #      - Compressed archive of the directory with the installation
    #        10.8_asan_1653043446.tar.xz
    #      - Compressed version of build.prt
    #        10.8_asan_1653043446.prt.xz
    #      - Copy of short.prt
    #        10.8_asan_1653043446.short
    # 3. rqg_batch.pl .... /Server_bin/10.8_asan
    #    Look into /Server_bin/10.8_asan/short.prt for the prefix of the archve stuff.
    #    In the current case its '10.8_asan_1653043446'.
    #    Make hardlinks
    #    RQG batch workdir | filesystem | <directory with archives of installed binaries>
    #    basedir<n>.tar.xz | inode <A>  | 10.8_asan_1653043446.tar.xz
    #    basedir<n>.short  | inode <B>  | 10.8_asan_1653043446.short
    #
    #######################################################

    foreach my $i (1..3) {
        next if not defined $basedirs[$i];
        next if $basedirs[$i] eq '';

        my $short_prot   = $basedirs[$i] . '/short.prt';
        if (not -e $short_prot) {
            say("WARN: No protocol of the build '$short_prot' found. " .
                "Preserving of basedir content impossible.");
            say("HINT: Use buildscripts like 'util/bld_*.sh'.");
            next;
        }
        say("INFO: Protocol of build '$short_prot' detected.");
        my $pattern = 'BASENAME of the archive and protocols: ';
        my $base_name = Auxiliary::get_string_after_pattern($short_prot, $pattern);
        if (not defined $base_name) {
            say("WARN: '$short_prot' does not contain a line with '$pattern'. " .
                "Preserving of basedir content impossible.");
            say("HINT: Use buildscripts like 'util/bld_*.sh'.");
            next;
        }
        say("DEBUG: $pattern  $base_name");

        my $s_prefix         = $bin_arch_dir . "/" . $base_name;
        my $s_bin_arch       = $s_prefix . '.tar.xz';
        my $s_bin_arch_short = $s_prefix . '.short';

        my $l_prefix         = $workdir  . '/basedir' . $i;
        my $l_bin_arch       = $l_prefix . '.tar.xz';
        my $l_bin_arch_prt   = $l_prefix . '.short';

        if (not -e $s_bin_arch) {
            say("WARN: No archive '$s_bin_arch' found. Preserving of basedir content impossible.");
            say("HINT: Use buildscripts like 'util/bld_*.sh' or build like you want and take " .
                "care that one of these archives exists.");
            next;
        }

        if (not link($s_bin_arch, $l_bin_arch)) {
            say("ERROR: Hardlinking '$s_bin_arch' to '$l_bin_arch' failed: $!");
            $status = STATUS_ENVIRONMENT_FAILURE;
            safe_exit($status);
        }
        if (not link($s_bin_arch_short, $l_bin_arch_prt)) {
            say("ERROR: Hardlinking '$s_bin_arch_short' to '$l_bin_arch_prt' failed: $!");
            $status = STATUS_ENVIRONMENT_FAILURE;
            safe_exit($status);
        }
        say("INFO: Hardlinks for basedirs[$i] related files in '$workdir' created.");
        system("ls -lid $s_prefix* $l_prefix* | sort -n") if Auxiliary::script_debug("T3");

    }
}

# Check (at least) if all the assigned basedirs contain a mysqld.
$status = STATUS_OK;
foreach my $i (1..3) {
    next if not defined $basedirs[$i];
    next if $basedirs[$i] eq '';
    my $some_mysqld = Auxiliary::find_file_at_places ($basedirs[$i], \@subdir_list, 'mysqld');
    if (not defined $some_mysqld) {
        say("ERROR: No binary with name 'mysqld' found below basedirs[$i] '" . $basedirs[$i] . "'");
        $status = STATUS_ENVIRONMENT_FAILURE;
    }
}
if ($status != STATUS_OK) {
    say("ERROR: A server binary is missing. $0 will exit with exit status " .
        status2text($status) . "($status)");
    safe_exit($status);
}

# Counter for statistics
# ----------------------
my $runs_started          = 0;
my $runs_stopped          = 0;

say("DEBUG: rqg_batch.pl : Leftover after the ARGV processing : ->" . join(" ", @ARGV) . "<-")
    if Auxiliary::script_debug("T2");
say("cl_end ->$cl_end<-") if Auxiliary::script_debug("T4");

my $config_file_copy = $workdir . "/" . $Batch::batch_type . '.cfg';
if (not File::Copy::copy($config_file, $config_file_copy)) {
    $status = STATUS_ENVIRONMENT_FAILURE;
    say("ERROR: Copying the config file '$config_file' to '$config_file_copy' failed : $!. " .
        Basics::exit_status_text($status));
    safe_exit($status);
}

my $verdict_prt = $workdir . "/verdict.prt";
my $verdict_cmd = "perl $rqg_home/verdict.pl --workdir=$workdir --batch_config=$config_file_copy" .
                  " > $verdict_prt";
my $rc = system($verdict_cmd) >> 8;
if (STATUS_OK != $rc) {
    sayFile($verdict_prt);
    say("ERROR: Generating the verdict config file failed.");
    say("ERROR: The command was ->" . $verdict_cmd . "<-");
    safe_exit(STATUS_ENVIRONMENT_FAILURE);
}
unlink ($verdict_prt);
my $verdict_setup      = "Verdict.cfg";
my $full_verdict_setup = $workdir . "/" . $verdict_setup;
if (not -f $full_verdict_setup) {
    say("ERROR: The verdict config file '" . $full_verdict_setup . "' does not exist.");
    safe_exit(STATUS_INTERNAL_ERROR);
}

if      ($Batch::batch_type eq Batch::BATCH_TYPE_COMBINATOR) {
    Combinator::init($config_file, $workdir);
} elsif ($Batch::batch_type eq Batch::BATCH_TYPE_RQG_SIMPLIFIER) {
    # If wanting some configurable amount of bug replays than the Simplifier needs to
    # know the value assigned to stop_on_replay.
    Simplifier::init($config_file, $workdir, $stop_on_replay);
} else {
    say("INTERNAL ERROR: The batch type '$Batch::batch_type' is unknown. Abort");
    safe_exit(4);
}

say("DEBUG: Command line options to be appended to the call of the RQG runner: ->" .
    $cl_end . "<-") if Auxiliary::script_debug("T1");

use constant DEFAULT_MAX_RUNTIME => 432000;
if (not defined $max_runtime) {
    $max_runtime = DEFAULT_MAX_RUNTIME;
    my $max_days = $max_runtime / 24 / 3600;
    say("INFO: rqg_batch.pl : Setting the maximum runtime to the default of $max_runtime" .
        "s ($max_days days).");
}
my $batch_end_time = $batch_start_time + $max_runtime;

my $logToStd = !osWindows() && !$noLog;

say("DEBUG: logToStd is ->$logToStd<-") if Auxiliary::script_debug("T1");

my $exit_file    = $workdir . "/exit";

my $total_status = STATUS_OK;

# Number of the next trial if started at all.
# This also implies that incrementing must be after getting a valid command.
my $trial_num    = 1;

while($Batch::give_up <= 1) {
    say("DEBUG: Begin of while(...) loop. Next trial_num is $trial_num.")
        if Auxiliary::script_debug("T6");
    # First handle all cases for giving up, stopping some worker etc.
    # 1. The user created $exit_file for signalling rqg_batch.pl that it should stop.
    # For experimenting:
    # system("touch $exit_file");
    Batch::check_exit_file($exit_file);
    last if $Batch::give_up > 1;
    # 2. The assigned max_runtime is exceeded.
    Batch::check_runtime_exceeded($batch_end_time);
    last if $Batch::give_up > 1;
    # 3. Resource problem is ahead.
    my $delay_start = Batch::check_resources();
    last if $Batch::give_up > 1;
    # 4. Some worker misbehaved (bad setup or server no more responsive)
    Batch::check_rqg_runtime_exceeded($max_rqg_runtime);

    my $just_forked = 0;

    if (0 < Batch::count_free_workers   # Free workers exist
        and 0 == $Batch::give_up        # We do not need to bring the current phase of work to an end.
        and not $delay_start    ) {     # We have no to be feared resource problem or similar.

        # We count per bookkeeping active RQG workers and hand it to ...::get_job.
        # This allows get_job to judge if an ordered switch_phase (--> Simplifier only) is called
        # in the right situation.
        my $active_workers = Batch::count_active_workers();

        my @job;
        if      ($Batch::batch_type eq Batch::BATCH_TYPE_COMBINATOR) {
            # ($order_id, $cl_snip)
            @job = Combinator::get_job($active_workers);
        } elsif ($Batch::batch_type eq Batch::BATCH_TYPE_RQG_SIMPLIFIER) {
            # ...REPLAY
            # ($order_id, $cl_snip, grammar      , undef)
            # ...GRAMMAR_SIMP
            # ($order_id, $cl_snip, child grammar, parent_grammar, adapted_duration)
            @job = Simplifier::get_job($active_workers);
            # use constant JOB_CL_SNIP    => 0;
            # use constant JOB_ORDER_ID   => 1;
            # use constant JOB_MEMO1      => 2;  # Child  grammar or Child rvt_snip
            # use constant JOB_MEMO2      => 3;  # Parent grammar or Parent rvt_snip
            # use constant JOB_MEMO3
        } else {
            # A batch campaign has exact one type.
            # So in case we are in the current branch than its before starting the first worker.
            # Hence exiting should not make trouble later.
            say("INTERNAL ERROR: The batch type '$Batch::batch_type' is unknown. Abort");
            safe_exit(4);
        }

        my $order_id = $job[Batch::JOB_ORDER_ID];
        if (not defined $order_id) {
            # ...::get_job did not found an order
            # == @try_first_queue and @try_queue were empty and ...::generate_orders gave nothing.
            # == All possible orders were generated.
            #    Some might be in execution and all other must be in @try_over_queue.
            say("DEBUG: No order got") if Auxiliary::script_debug("T6");
        } else {
            my $free_worker = Batch::get_free_worker;
            if (not defined $free_worker) {
                say("INTERNAL ERROR: No free worker got though there should be some. Abort.");
                my $status = STATUS_INTERNAL_ERROR;
                Batch::emergency_exit($status);
            }
            # We have now a free/non busy RQG runner and a job
            say("DEBUG: Preparing command for RQG worker [$free_worker] based on valid " .
                "order $order_id.") if Auxiliary::script_debug("T6");
            my $cl_snip = $job[Batch::JOB_CL_SNIP];

            say("DEBUG: cl_snip returned by Module is =>" . $cl_snip . "<=")
                if Auxiliary::script_debug("T6");
            if (not defined $cl_snip) {
                Carp::cluck("INTERNAL ERROR: job[Batch::JOB_CL_SNIP] is undef. Abort.");
                my $status = STATUS_INTERNAL_ERROR;
                Batch::emergency_exit($status);
            }

            # Beautify cl_snip by shrinking multiple spaces to one.
            $cl_snip =~ s{ +}{ }img;
            # Expand "--seed=time" to the real value.
            my $tm = time();
            $cl_snip =~ s/--seed=time/--seed=$tm/g;
            say("DEBUG: cl_snip after some processing =>$cl_snip<=");
            #   if Auxiliary::script_debug("T6");

            say("Job generated : $order_id § $cl_snip") if Auxiliary::script_debug("T5");

            # OPEN (not done till here but below)
            # -----------------------------------
            # - append RQG Worker specific stuff like RQG runner, vardir etc.
            # - append $cl_end
            # - glue "perl .... $rqg_home/" to the begin.
            # - enclose on non WIN with bash .....

            my $command = $cl_snip;

            $Batch::worker_array[$free_worker][Batch::WORKER_ORDER_ID] = $order_id;
            $Batch::worker_array[$free_worker][Batch::WORKER_EXTRA1]   = $job[Batch::JOB_MEMO1];
            $Batch::worker_array[$free_worker][Batch::WORKER_EXTRA2]   = $job[Batch::JOB_MEMO2];
            $Batch::worker_array[$free_worker][Batch::WORKER_EXTRA3]   = $job[Batch::JOB_MEMO3];
            $Batch::worker_array[$free_worker][Batch::WORKER_COMMAND]  = $command;

            say("COMMAND ->$command<-") if Auxiliary::script_debug("T5");

            # Remove tree $rqg_workdir if it already exists. Create tree $rqg_workdir.
            # ------------------------------------------------------------------------
            # In theory this could be done by the RQG worker instead.
            # But would be that really better?
            # 1. A failing rmtree or create file/directory points either to
            #    - some serious problem in the RQG batch mechanics
            #    - "illegal" activity of some user in the storage area of RQG batch
            #    Both should lead immediate to running emergency_exit.
            # 2. ...
            my $rqg_workdir = Local::get_results_dir . "/" . "$free_worker";
            # say("DEBUG: rqg_workdir ==>" . $rqg_workdir . "<==");
            if (STATUS_OK != Auxiliary::make_rqg_infrastructure($rqg_workdir)) {
                my $status = STATUS_ENVIRONMENT_FAILURE;
                Batch::emergency_exit($status, "FATAL ERROR: Making the infrastructure around " .
                                      "'$rqg_workdir' failed.");
            }

            my $pid = fork();
            if (not defined $pid) {
                Batch::emergency_exit(STATUS_CRITICAL_FAILURE,
                               "ERROR: The fork of the process for a RQG Worker failed.\n"     .
                               "       Assume some serious problem. Perform an EMERGENCY exit" .
                               "(try to stop all child processes).");
            }
            $runs_started++;
            if ($pid == 0) {
                ########## Child == RQG Worker ##############################
                $| = 1;
                # Warning
                # -------
                # Anything written via "say" gets directed to STDERR and "lands" in the output
                # of rqg_batch.pl which might be often unwanted.
                my $who_am_i = "RQG Worker [$free_worker]:";
                say("$who_am_i Taking over.");

                # We use "system" and not "exec" later. So set certain memory structures inherited
                # from the parent to undef.
                # Reason:
                # We hopefully reduce the memory foot print a bit.
                # In case I memorize correct than the perl process will not hand back the freed
                # memory to the OS. But it will maybe use the freed memory for
                # - (I am very unsure) stuff called with "system" like rqg.pl
                # - (more sure) anything else
                # Batch queues: @try_queue, @try_first_queue, @try_later_queue, @try_over_queue
                # Combinator/simplifier structure: @order_array
                Batch::free_memory();
                if      ($Batch::batch_type eq Batch::BATCH_TYPE_COMBINATOR) {
                    Combinator::free_memory;
                } elsif ($Batch::batch_type eq Batch::BATCH_TYPE_RQG_SIMPLIFIER) {
                    Simplifier::free_memory;
                } else {
                    say("INTERNAL ERROR: $who_am_i The batch type '$Batch::batch_type' is " .
                        "unknown. Abort");
                    safe_exit(4);
                }

                # The parent has already created infrastructure like the $workdir.

                setpgrp(0,0);

                # For experimenting:
                # - get some delayed death of server.
                #   system ("/work_m/RQG_mleich1/killer.sh &");
                # - Call some not existing command.
                #   $command = "/";
                # - In case we exit here than the parent will detect that the RQG worker has not
                #   taken over and perform an emergency_exit.
                #   safe_exit(0);

                # For the case that $RQG_HOME occurs within the command like for encryption keys.
                $ENV{'RQG_HOME'} = $rqg_home;

                # What follows is no more needed because
                # rqg.pl --batch ... --minor_runid=$free_worker performs
                # 1. "Tell" local.pm the minor_runid (==$free_worker)
                # 2. local.pm computes based on that and content in local.cfg the build_thread
                # 3. rqg.pl "asks" local.pm for the build_thread to be used
                # my $rqg_build_thread = $build_thread + ($free_worker - 1);
                # $command .= " --mtr-build-thread=$rqg_build_thread";

                $command .= " --batch";

                if (defined $rr) {
                    $cl_end .= " --rr=" . $rr;
                    if (defined $rr_options) {
                        $cl_end .= " --rr_options='" . $rr_options ."'";
                    }
                }

                $command .= $cl_end;
                # Add dbdir_type if defined in command line because parameter set there should
                # overrule setting from the Combinator or Simplifier config file.
                if (defined $dbdir_type) {
                    $command .= " --dbdir_type=$dbdir_type";
                }
                my $rqg_log = $rqg_workdir . "/rqg.log";
                my ($whatever, $rqg_major_runid) = Local::get_runid();
                # Experimental:
                # $rqg_log = "/tmp/otto";
                $command .= " --major_runid=$rqg_major_runid --minor_runid=" . $free_worker .
                            " >> " . $rqg_log . ' 2>&1' ;
                $command = "perl -w " . ($Carp::Verbose?"-MCarp=verbose ":"") . " $rqg_home" .
                           "/" . $runner . ' ' . $command;
                # "Decorate" for use with bash + add nice -19 etc.
                $command = Auxiliary::prepare_command_for_system($command);
                say("DEBUG: command ==>" . $command . "<==") if Auxiliary::script_debug("T5");

                # $rqg_job is used for
                # 1. debugging the simplifier/combinator mechanics (--> OrderID, Memo1, ...)
                #    Q: Do the simplification phases work correct?
                # 2. being able to get some rather complete overview about how RQG test setups
                #    achieving whatever verdict looked like
                #    Q1: What is the most promising setup (grammar, ...) for replaying some
                #        search pattern TBR/MDEV-nnnnn?
                #    Q2: Which setups (grammar, ...) tend to frequent false alarms etc.
                my $rqg_job = $rqg_workdir . "/rqg.job";
                # say("DEBUG: $who_am_i rqg_job ==>" . $rqg_job . "<==");
                my $content =
                    "OrderID: " . $job[Batch::JOB_ORDER_ID]                                             . "\n" .
                    "Memo1:   " . (defined $job[Batch::JOB_MEMO1] ? $job[Batch::JOB_MEMO1] : '<undef>') . "\n" .
                    "Memo2:   " . (defined $job[Batch::JOB_MEMO2] ? $job[Batch::JOB_MEMO2] : '<undef>') . "\n" .
                    "Memo3:   " . (defined $job[Batch::JOB_MEMO3] ? $job[Batch::JOB_MEMO3] : '<undef>') . "\n" .
                    "Cl_Snip: " . $command ;
                if (STATUS_OK != Batch::append_string_to_file($rqg_job, $content . "\n")) {
                    say("ERROR when writing to $rqg_job");
                    $status = STATUS_ENVIRONMENT_FAILURE;
                    safe_exit($status);
                }
                my $message = "# " . isoTimestamp() . " INFO: Logfile for RQG Worker [$free_worker]\n";
                Batch::append_string_to_file($rqg_log, $message);
                # say("DEBUG: $who_am_i rqg_log ==>" . $rqg_log . "<==");


                # Unclear of 100% needed.
                $ENV{_RR_TRACE_DIR} = undef;

                if ($dryrun) {
                    say("LIST: ==>$command<==");
                    # The parent waits for the take over by the RQG worker which is visible per
                    # the worker calls rqg.pl and that sets the phase to Auxiliary::RQG_PHASE_START.
                    # So we fake that here.
                    Batch::append_string_to_file($rqg_log,
                                                 "LIST: ==>$command<==\n");
                    if (STATUS_OK != Auxiliary::set_rqg_phase($rqg_workdir,
                                                              Auxiliary::RQG_PHASE_START)) {
                        my $status = STATUS_ENVIRONMENT_FAILURE;
                        say("ERROR: $who_am_i Aborting because of previous error.\n" .
                            Basics::exit_status_text($status));
                        safe_exit($status);
                        # We do not need to signal the parent anything because the parent will
                        # detect that the shift to Auxiliary::RQG_PHASE_START did not happened
                        # and perform an emergency_exit.
                    }
                    if (STATUS_OK != Verdict::set_final_rqg_verdict ($rqg_workdir, $dryrun,
                                                                     '<undef>')            ) {
                        my $status = STATUS_ENVIRONMENT_FAILURE;
                        say("ERROR: $who_am_i Aborting because of previous error.\n" .
                            Basics::exit_status_text($status));
                        safe_exit($status);
                    }
                    Batch::append_string_to_file($rqg_log,
                                                 "INFO: GenTest_e: Effective duration in s : 30\n");
                    Batch::append_string_to_file($rqg_log,
                                                 "SUMMARY: RQG GenTest_e runtime in s : 60\n");
                    Auxiliary::set_rqg_phase($rqg_workdir, Auxiliary::RQG_PHASE_COMPLETE);
                    safe_exit(STATUS_OK);
                } else {
                    # Child == RQG Worker
                    #
                    # The RQG Worker does
                    # 1. Further preparations (already done)
                    # 2. Perform the RQG test via "system"
                    # 3. Verdict computation via "system"
                    # 4. Archiving if required and cleanup
                    # compared to the alternative that we start the RQG runner via "exec" and that
                    # the RQG runner (like rqg.pl) computes the verdict and archives.
                    # Reason:
                    #    The RQG runner does no more need to check his own protocol
                    #    == Knowing the storage place in advance is not needed
                    #    == Whatever stderr/stdout redirection is a smaller problem
                    # If ever bundling the stuff for checking exits status etc. in a routine than we need
                    #     $command, $?, $!, $who_am_i, script_debug_value W2

                    # say("DEBUG: $who_am_i =>" . $command . "<=");
                    #

                    my $rc = system($command);
                    if      ($? == -1) {
                        say("WARNING: $who_am_i ->" . $command . "<- failed to execute: $!");
                        safe_exit(STATUS_UNKNOWN_ERROR);
                    } elsif ($? & 127) {
                        say("WARNING: $who_am_i ->" . $command . "<- died with signal " .
                            ($? & 127));
                        safe_exit(STATUS_PERL_FAILURE);
                    } elsif (($? >> 8) != 0) {
                        say("DEBUG: $who_am_i ->"   . $command . "<- exited with value " .
                            ($? >> 8)) if Auxiliary::script_debug("W2");
                        # Do not exit because the RQG runner harvested most probably something like
                        # STATUS_SERVER_CRASHED or similar.
                    } else {
                        say("DEBUG: $who_am_i ->" .   $command . "<- exited with value " .
                            ($? >> 8)) if Auxiliary::script_debug("W2");
                    }
                    Batch::append_string_to_file($rqg_log, Basics::get_process_family());

                    # say("DEBUG: $who_am_i After performing the RQG run and before calculation of verdict.");

                    # Initiate calculation of verdict
                    # -------------------------------
                    # 2>&1 at command end ensures that we do not pollute the output of rqg_batch.pl
                    # with the verdict output.
                    # 'rqg_matching.log' will be archived if archiving not disabled.
                    $command = "perl $rqg_home/verdict.pl --workdir=$rqg_workdir > " .
                               "$rqg_workdir/rqg_matching.log 2>&1";
                    $command = Auxiliary::prepare_command_for_system($command);
                    $rc = system($command);
                    if      ($? == -1) {
                        say("WARNING: $who_am_i ->" . $command . "<- failed to execute: $!");
                        safe_exit(STATUS_UNKNOWN_ERROR);
                    } elsif ($? & 127) {
                        say("WARNING: $who_am_i ->" . $command . "<- died with signal " .
                            ($? & 127));
                        safe_exit(STATUS_PERL_FAILURE);
                    } elsif (($? >> 8) != 0) {
                        say("WARNING: $who_am_i ->" . $command . "<- exited with value " .
                            ($? >> 8));
                        safe_exit(STATUS_UNKNOWN_ERROR);
                    } else {
                        say("DEBUG: $who_am_i ->"   . $command . "<- exited with value " .
                            ($? >> 8)) if Auxiliary::script_debug("W2");
                    }

                    my ($verdict, $extra_info) = Verdict::get_rqg_verdict($rqg_workdir);
                    say("DEBUG: $who_am_i verdict: $verdict, extra_info: $extra_info")
                        if Auxiliary::script_debug("W2");

                    if ($verdict ne Verdict::RQG_VERDICT_IGNORE           and
                        $verdict ne Verdict::RQG_VERDICT_IGNORE_STATUS_OK and
                        $verdict ne Verdict::RQG_VERDICT_IGNORE_UNWANTED  and
                        $verdict ne Verdict::RQG_VERDICT_IGNORE_STOPPED) {
                        # The set of conditions above leads to "The result is of interest".
                        # say("DEBUG: The result in $rqg_workdir is of interest -----------------");
                        # say("find $rqg_workdir -follow");
                        if (STATUS_OK != Auxiliary::set_rqg_phase($rqg_workdir,
                                                        Auxiliary::RQG_PHASE_ARCHIVING)) {
                            safe_exit(STATUS_ENVIRONMENT_FAILURE);
                        }
                        if (not $noarchiving) {
                            if (STATUS_OK != Auxiliary::archive_results($rqg_workdir)) {
                                my $msg_snip = "ERROR: Archiving the remainings of the RQG " .
                                               "test failed.";
                                # We already have the current process family within the rqg.log.
                                # And they are quite probably the reason for archiver trouble.
                                Batch::append_string_to_file($rqg_log, $msg_snip . "\n");
                                say($msg_snip);
                                safe_exit(STATUS_ENVIRONMENT_FAILURE);
                            } else {
                              # say("DEBUG: $who_am_i Archive '" . $rqg_workdir .
                              #     "/archive.tar.xz' created.") if Auxiliary::script_debug("W2");
                            }
                        }
                        # 2020-10-21
                        # cannot remove path when cwd is /dev/shm/vardir/1603279578/1 for
                        # /dev/shm/vardir/1603279578/1:  at ./rqg_batch.pl line 1141.
                        # So this looks like we cannot remove a directory tree in case
                        # our current working directory is in it.
                        chdir($rqg_workdir);
                        my $extra = Local::get_dbdir . "/$free_worker";
                        # say("DEBUG rqg_workdir ->$rqg_workdir<-");
                        # say("DEBUG: Some fast dir ->" . Local::get_rqg_fast_dir . "/$free_worker<-");
                        # say("DEBUG: Some slow dir ->" . Local::get_rqg_slow_dir . "/$free_worker<-");
                        if (STATUS_OK != Auxiliary::clean_workdir_preserve($rqg_workdir)) {
                            say("ERROR FATAL: rqg_batch.pl Auxiliary::clean_workdir_preserve failed.");
                            my $status = STATUS_ENVIRONMENT_FAILURE;
                            safe_exit($status);
                        }
                    } else {
                        # say("DEBUG: The result in $rqg_workdir is not of interest -------------");
                        if (STATUS_OK != Auxiliary::clean_workdir($rqg_workdir)) {
                            say("ERROR FATAL: rqg_batch.pl Auxiliary::clean_workdir failed.");
                            my $status = STATUS_ENVIRONMENT_FAILURE;
                            safe_exit($status);
                        }
                    }

                    if (STATUS_OK != Auxiliary::set_rqg_phase($rqg_workdir,
                                                    Auxiliary::RQG_PHASE_COMPLETE)) {
                        safe_exit(STATUS_ENVIRONMENT_FAILURE);
                    }
                    safe_exit(STATUS_OK);
                }

            } else {
                ########## Parent ##############################
                my $workerspec = "Worker[$free_worker] with pid $pid for trial $trial_num";
                # FIXME: Set the complete worker_array_entry here
                $Batch::worker_array[$free_worker][Batch::WORKER_PID] = $pid;
                say("DEBUG: $workerspec forked.") if Auxiliary::script_debug("T1");
                # Poll till the RQG Worker has taken over.
                # This has happened when
                # 1. the worker has run setpgrp(0,0) which is not available for WIN.
                # and
                # 2. Set a tiny bit later work phase != init.
                # The first is essential for Unix/Linux in order to make the stop_worker* routines
                # work well. It is currently not known how good these routines work on WIN.
                # Caused by the possible presence of WIN we cannot poll for a change of the
                # processgroup of the RQG worker. We just focus on 2. instead.
                # Observation: 2018-08 10s were not sufficient on some box under heavy load.
                my $max_waittime  = 30;
                my $waittime_unit = 0.1;
                my $start_time    = Time::HiRes::time();
                my $end_waittime  = $start_time + $max_waittime;
                my $measure_time  = $start_time + 2;
                my $phase         = Auxiliary::get_rqg_phase($rqg_workdir);
                my $message       = '';
                if (not defined $phase) {
                    # Most likely: Rotten infrastructure/Internal error
                    $message = "ERROR: Problem to determine the work phase of " .
                               "the just started $workerspec.";
                } else {
                    while(time() < $end_waittime) {
                        last if $phase ne Auxiliary::RQG_PHASE_INIT;

                        # 1. The user created $exit_file might exist.
                        Batch::check_exit_file($exit_file);
                        last if $Batch::give_up > 1;
                        # 2. The assigned max_runtime might be exceeded.
                        Batch::check_runtime_exceeded($batch_end_time);
                        last if $Batch::give_up > 1;

                        # 3. A resource problem might be ahead.
                        if (Time::HiRes::time() > $measure_time) {
                            my $delay_start = Batch::check_resources();
                            last if $Batch::give_up > 1;
                            # Batch::check_resources can stop some worker.
                            # We might have stopped the just started worker (observed 2020-10).
                            # Than the Auxiliary::get_rqg_phase at end of while loop would
                            # cause error messages and return undef.
                            last if $Batch::worker_array[$free_worker][Batch::WORKER_PID] == -1;
                            $measure_time = Time::HiRes::time() + 2;
                        } else {
                            Time::HiRes::sleep($waittime_unit);
                        }
                        $phase = Auxiliary::get_rqg_phase($rqg_workdir);
                    }
                    # last if $Batch::give_up > 1 above might have send us to here.
                    last if $Batch::give_up > 1;
                    # last if .....[Batch::WORKER_PID] == -1 above might have send us to here.
                    last if $Batch::worker_array[$free_worker][Batch::WORKER_PID] == -1;
                    if (Time::HiRes::time() > $end_waittime) {
                        $message = "Waitet >= $max_waittime" . "s for the just started " .
                                   "$workerspec to start his work. But no success.";
                    }
                }
                if ('' ne $message) {
                    if (1 == $runs_started) {
                        # Its the first start of some RQG Worker!
                        Batch::emergency_exit(STATUS_CRITICAL_FAILURE, "ERROR: " .
                        $message . "\n       Assume some serious problem. Perform an EMERGENCY exit" .
                        "(try to stop all child processes) without any cleanup of vardir and workdir.");
                    } else {
                        # There seems to be more load than we are willing to handle.
                        say("INFO: $message");
                        Batch::stop_worker_till_phase(Auxiliary::RQG_PHASE_PREPARE,
                                                            Batch::STOP_REASON_RESOURCE);
                        Batch::adjust_workers_range;
                    }
                } else {
                    # No fractions of seconds because its not needed and makes prints too long.
                    $Batch::worker_array[$free_worker][Batch::WORKER_START] = time();
                    say("$workerspec forked and worker has taken over.") if Auxiliary::script_debug("T6");
                    $trial_num++;
                    $just_forked = 1;
                    # $free_worker = -1;
                }
            }
        }
    } else {
        # Either
        # - there was no free RQG worker at all etc.
        # or
        # - the previous loop round harvested a few lines lower give_up == 1 which means
        #   stop the current campaign.
    }

    # Phase or campaign end with stop all workers.
    if (1 == $Batch::give_up) {
        say("DEBUG: give_up is 1 --> loop waiting till all RQG worker have finished.")
            if Auxiliary::script_debug("T5");
        my $poll_time = 0.1;
        while (Batch::reap_workers()) {
            Batch::check_rqg_runtime_exceeded($max_rqg_runtime);
            Batch::process_finished_runs();
            last if $Batch::give_up > 1;
            # First handle all cases for giving up.
            # 1. The user created $exit_file for signalling rqg_batch.pl that it should stop.
            # For experimenting:
            # system("touch $exit_file");
            Batch::check_exit_file($exit_file);
            last if $Batch::give_up > 1;
            my $delay_start = Batch::check_resources();
            last if $Batch::give_up > 1;
            Batch::check_runtime_exceeded($batch_end_time);
            last if $Batch::give_up > 1;
            sleep $poll_time;
        }
        # Reaping with final result of having 0 active Workers leads to

        say("DEBUG: After get all worker inactive loop, active workers : ",
            Batch::count_active_workers()) if Auxiliary::script_debug("T6");
        last if $Batch::give_up > 1;
        $Batch::give_up = 0
    }

    # All with $Batch::give_up > 1 have already left our main loop
    say("DEBUG: Waiting for a free RQG worker.") if Auxiliary::script_debug("T6");
    # "Wait" as long as
    #   (the number of active workers == maximum number of workers.)
    # Extend later by or load too high for taking the risk to start another worker
    # or
    #   ((load too high for taking the risk to start another worker) and
    #    ($Batch::give_up == 0))

    my $active_workers = Batch::reap_workers();
    Batch::process_finished_runs();
    last if $Batch::give_up > 1;

    next if defined $dryrun;

    # ResourceControl should take care that reasonable big delays between starts are made.
    # This is completely handled in Batch::check_resources.
    # So in case we have here a sleep not set to comment than it serves only for preventing a too
    # busy rqg_batch.
      sleep 0.05;

} # End of while($Batch::give_up <= 1) loop with search for a free RQG runner + job + starting it.

say("INFO: Phase of job generation and bring it into execution is over. " .
    "give_up is $Batch::give_up ");

# We start with a moderate sleep time in seconds because
# - not too much load intended ==> value minimum >= 0.2
# - not too long because checks for bad states (partially not yet implemented) of the testing
#   environment need to happen frequent enough ==> maximum <= 1.0
# As soon as the checks require in sum some significant runtime >= 1s the sleep should be removed.
my $poll_time = 1;
# Poll till none of the RQG workers is active
while (Batch::count_active_workers()) {
    Batch::reap_workers();
    Batch::process_finished_runs();
    Batch::check_rqg_runtime_exceeded($max_rqg_runtime);
    Batch::process_finished_runs();
    say("DEBUG: At begin of loop waiting till all RQG worker have finished.")
        if Auxiliary::script_debug("T5");
    # First handle all cases for giving up.
    # 1. The user created $exit_file for signalling rqg_batch.pl that it should stop.
    # For experimenting:
    # system("touch $exit_file");
    Batch::check_exit_file($exit_file);
    # No "last if $Batch::give_up > 1;" because we want the Batch::reap_workers() with the cleanup.
    $poll_time = 0.1 if $Batch::give_up > 1;
    my $delay_start = Batch::check_resources();
    last if $Batch::give_up > 2;
    # 2. The assigned max_runtime is exceeded.
    Batch::check_runtime_exceeded($batch_end_time);
    $poll_time = 0.1 if $Batch::give_up > 1;
    sleep $poll_time;
}

# WARNING:
# The loop begin above will cause all time that Batch::reap_workers gets executed.
# But in case this returns 0 than we will not run the loop body and so Batch::process_finished_runs
# would be not called.  So we must do that here again.
Batch::process_finished_runs();
Batch::dump_try_hashes() if Auxiliary::script_debug("T3");
# dump_orders();

my $best_verdict;
$best_verdict = '--';
$best_verdict = Verdict::RQG_VERDICT_INIT     if 0 < $Batch::verdict_init;
$best_verdict = Verdict::RQG_VERDICT_IGNORE   if 0 < $Batch::verdict_ignore;
$best_verdict = Verdict::RQG_VERDICT_INTEREST if 0 < $Batch::verdict_interest;
$best_verdict = Verdict::RQG_VERDICT_REPLAY   if 0 < $Batch::verdict_replay;

say("\n\n");
ResourceControl::print_statistics;
my $fat_message = Batch::get_extra_info_hash("STATISTICS");
my $pl = Verdict::RQG_VERDICT_LENGTH + 2;
my $message = ""                                                                                   .
"STATISTICS: RQG runs -- Verdict\n"                                                                .
"STATISTICS: " . Basics::lfill($Batch::verdict_replay, 8)    . " -- "                              .
                 Basics::rfill("'" . Verdict::RQG_VERDICT_REPLAY   . "'",$pl)                      .
             " -- Replay of desired effect (replay list match, no unwanted list match)\n"          .
"STATISTICS: " . Basics::lfill($Batch::verdict_interest, 8)  . " -- "                              .
                 Basics::rfill("'" . Verdict::RQG_VERDICT_INTEREST . "'",$pl)                      .
             " -- Otherwise interesting effect (no replay list match, no unwanted list match)\n"   .
"STATISTICS: " . Basics::lfill($Batch::verdict_ignore, 8)    . " -- "                              .
                 Basics::rfill("'" . Verdict::RQG_VERDICT_IGNORE   . "_*'",$pl)                    .
             " -- Effect is not of interest (unwanted list match or STATUS_OK or stopped)\n"       .
"STATISTICS: " . Basics::lfill($Batch::stopped, 8)   . " -- "                                      .
                 Basics::rfill("'" . Verdict::RQG_VERDICT_IGNORE_STOPPED . "'",$pl)                .
             " -- RQG run stopped by rqg_batch.pl because of whatever reasons\n"                   .
"STATISTICS: " . Basics::lfill($Batch::verdict_init, 8)      . " -- "                              .
                 Basics::rfill("'" . Verdict::RQG_VERDICT_INIT     . "'",$pl)                      .
             " -- RQG run too incomplete (maybe wrong RQG call)\n"                                 .
"STATISTICS: " . Basics::lfill($Batch::verdict_collected, 8) . " -- Some verdict made.\n\n"        .
$fat_message . "\n"                                                                                .
"STATISTICS: Total runtime in seconds : " . (time() - $batch_start_time) . "\n"                    .
"STATISTICS: RQG runs started         : $runs_started\n\n"                                         .
"RESULT:     The logs and archives of the RQG runs performed including files with summaries\n"     .
"            are in the workdir of the rqg_batch.pl run\n"                                         .
"                 $workdir\n"                                                                      .
"HINT:       As long as this was the last run of rqg_batch.pl the symlink\n"                       .
"                 " . BATCH_RESULT_SYMLINK . "\n"                                                  .
"            will point to this workdir.\n"                                                        .
"RESULT:     The highest (process) exit status of some RQG Worker was : $total_status\n"           .
"                        0 == No trouble from the OS/Perl/RQG Worker logics points of view.\n"     .
"RESULT:     The best verdict reached was : '$best_verdict'"                                       ;
say($message);
# Append that message to $workdir/result.txt too because
# - the current rqg_batch.pl log gets often
#   - overwritten by the next run of the same test battery
#   or
#   - simply lost because of whatever reason but $workdir/result.txt survives
# - the aggregated information in $message is too valuable
Batch::write_result($message . "\n");

# Even though subdirs of $vardir belonging to RQG Workers get
# - most probably already deleted by the corresponding RQG Workers
# - most probably deleted by rqg_batch.pl when being forced to stop some RQG Worker
# the $vardir will survive and in case of mistakes even directories belonging to RQG workers.
# Hence we clean up here again.

File::Path::rmtree(Local::get_rqg_fast_dir);
File::Path::rmtree(Local::get_rqg_slow_dir);
safe_exit(STATUS_OK);


sub help() {
   print(
   "\nSorry, under construction and partially different or not yet implemented.\n\n"               .
   "Purpose: Perform a batch of RQG runs with massive parallelization according to setup/config\n" .
   "         Be a replacement for\n"                                                               .
   "         combinations.pl, bughunt.pl, runall-trials.pl, simplify-grammar.pl\n"                 .
   "Terms used:\n"                                                                                 .
   "Default\n"                                                                                     .
   "      What you get in case you do not assign some corresponding --<parameter>=<value>.\n"      .
   "RQG Worker\n"                                                                                  .
   "      A child process which\n"                                                                 .
   "      1. Runs an extreme small 'prepare play ground'.\n"                                       .
   "      2. Starts via Perl 'system' a RQG run (--> rqg.pl or other RQG runner).\n"               .
   "      3. Obtains via Perl 'system' a verdict about that RQG run (--> verdict.pl).\n"           .
   "      4. Archives data of that RQG run depending on the verdict got and the setup.\n"          .
   "Regular finished RQG run\n"                                                                    .
   "      A RQG run which ended regular with success or failure (crash, perl error ...).\n"        .
   "      rqg_batch.pl might stop (KILL) RQG runs because of technical reasons.\n"                 .
   "      Such stopped runs will be restarted with the same setup as soon as possible.\n"          .
   "\n"                                                                                            .
   "--help\n"                                                                                      .
   "      Some general help about rqg_batch.pl and its command line parameters/options which\n"    .
   "      are not handled by the Combinator or the Simplifier.\n"                                  .
   "--help_combinator\n"                                                                           .
   "      Information about the rqg_batch.pl command line parameters/options which are handled "   .
   "by the Combinator.\n"                                                                          .
   "      Purpose: Plain bug hunting.\n"                                                           .
   "--help_simplifier\n"                                                                           .
   "      Information about the rqg_batch.pl command line parameters/options which are handled "   .
   "by the Simplifier.\n"                                                                          .
   "      Purpose: Reduce the complexity (setup+grammar) of a test replaying some problem.\n"      .
   "--help_verdict\n"                                                                              .
   "      Information about how to setup the unwanted/interest/replay lists which are used for\n"  .
   "      defining desired and to be ignored test outcomes.\n"                                     .
   "--help_rqg_home\n"                                                                             .
   "      Information about the RQG home directory used and the RQG tool/runner called.\n"         .
   "--help_rr\n"                                                                                   .
   "      Information about how and when to invoke the tool 'rr' (https://rr-project.org/)\n"      .
   "--help_archiving\n"                                                                            .
   "      Information about how and when archives of the binaries used and results are made\n"     .
   "--help_sqltrace\n"                                                                             .
   "      Information about client side SQL tracing by RQG\n"                                      .
   "--help_dbdir_type\n"                                                                           .
   "      Information about the RQG option dbdir_type\n"                                           .
   "--help_local\n"                                                                                .
   "      Information about the mandatory file local.cfg which gets used for computing the\n"      .
   "      storage places for archives, vardirs, workdirs and other stuff.\n"                       .
   "      Purpose: Adjustments to the properties of the testing box.\n"                            .
   "\n"                                                                                            .
   "--type=<Which type of work ("                                                                  .
   Auxiliary::list_values_supported(Batch::BATCH_TYPE_ALLOWED_VALUE_LIST) . "') to do>\n"          .
   "      (Default) '" . Batch::BATCH_TYPE_COMBINATOR . "'\n"                                      .
   "--config=<config file with path absolute or path relative to top directory of RQG install>\n"  .
   "      Assigning this file is mandatory.\n"                                                     .
   "--max_runtime=<n>\n"                                                                           .
   "      Stop all ongoing RQG runs if the total runtime in seconds has exceeded this value, "     .
   "give a summary and exit.\n"                                                                    .
   "      (Default) " . DEFAULT_MAX_RUNTIME . "\n"                                                 .
   "--parallel=<n>\n"                                                                              .
   "      Maximum number of parallel RQG Workers performing RQG runs.\n"                           .
   "      (Default) All OS: If supported <return of OS command nproc> otherwise 1.\n\n"            .
   "      WARNING - WARNING - WARNING -  WARNING - WARNING - WARNING - WARNING - WARNING\n"        .
   "         Please be aware that OS/user/hardware resources are limited.\n"                       .
   "         Extreme resource consumption (high value for <n> and/or fat RQG tests) could result\n".
   "         in some very slow reacting testing box up till OS crashes.\n"                         .
   "         Critical candidates: open files, max user processes, free space in tmpfs\n"           .
   "      The risks decrease drastic in case the automatic RQG BATCH resource control is not "     .
   "disabled. (see paramater --resource_control=...)\n\n"                                          .
   "No more supported: --build_thread=<n>  start of the range of build threads assigned to RQG "   .
   "runs. The value has to be assigned in local.cfg.\n\n"                                          .
   "--runner=...\n"                                                                                .
   "      The RQG runner to be used. The value assigned must be without path.\n"                   .
   "      (Default) '" . DEFAULT_RQG_RUNNER . " in RQG_HOME.\n"                                    .
   "--discard_logs\n"                                                                              .
   "      Remove even the logs of RQG runs with the verdict '" .Verdict::RQG_VERDICT_IGNORE. "'\n" .
   "--stop_on_replay=<n>\n"                                                                        .
   "      As soon as <n> RQG runs achieved the verdict '" . Verdict::RQG_VERDICT_REPLAY            .
   " , stop all active RQG Worker, cleanup, give a summary and exit.\n"                            .
   "      '--stop_on_replay '   in command line leads to use n = 1\n"                              .
   "      '--stop_on_replay...' not in command line n = " . Batch::MAX_BATCH_STARTS . "\n"         .
   "      If type of work\n"                                                                       .
   "      - " . Batch::BATCH_TYPE_COMBINATOR                                                       .
   " :     Generate the stream of tests to be run via combinatorics.\n"                            .
   "      - " . Batch::BATCH_TYPE_RQG_SIMPLIFIER                                                   .
   " : Run all time the non simplified test.\n\n"                                                  .
   "--dryrun=<verdict_value>\n"                                                                    .
   "      Run the complete mechanics except that the RQG worker processes forked\n"                .
   "      - print the RQG call which they would run\n"                                             .
   "      - do not start a RQG run at all but fake a few effects checked by the parent process\n"  .
   "      Debug functionality of other RQG parts like the RQG runner will be not touched!\n"       .
   "--script_debug=...       FIXME: Only rudimentary and different implemented\n"                  .
   "      Print additional detailed information about decisions made by the tool components\n"     .
   "      assigned and observations made during runtime.\n"                                        .
   "      B - Batch.pm and rqg_batch.pl\n"                                                         .
   "      C - Combinator.pm\n"                                                                     .
   "      S - Simplifier.pm\n"                                                                     .
   "      V - Auxiliary.pm\n"                                                                      .
   "      (Default) No additional debug information.\n"                                            .
   "      Hints:\n"                                                                                .
   "          '--script_debug=SB' == Debug Simplifier and Batch ...\n"                             .
   "      The combination\n"                                                                       .
   "                  --dryrun=ignore  --script_debug¸\n"                                          .
   "      is an easy/fast way to check certains aspects of\n"                                      .
   "      - the order and job management in rqg_batch in general\n"                                .
   "      - optimizations (depend on progress) for grammar simplification\n"                       .
   "--resource_control=...  Automatic RQG BATCH resource control (Linux only)\n"                   .
   "      help_resource_control (FIXME: is missing)\n"                                             .
   "      (Recommended) Do not assign '--resource_control=...' at all\n"                           .
   "         --> Get the Automatic resource control enabled.\n"                                    .
   "      (Quite risky if 'parallel' is high) '" . ResourceControl::RC_NONE . "'\n"                .
   "         --> No automatic resource control\n"                                                  .
   "--noarchiving\n"                                                                               .
   "      Do not archive the remainings (core, data dir etc.) of some RQG run even if the\n"       .
   "      verdict is '" . Verdict::RQG_VERDICT_REPLAY . "' or '" . Verdict::RQG_VERDICT_INTEREST   .
   "'.\n"                                                                                          .
   "      Advantage: RQG test simplification will be significant faster + save storage space.\n"   .
   "      Disadvantage: You will have to repeat some run for getting cores and similar.\n\n"       .
   "      The default is to generate an archive in case getting such a positive verdict.\n"        .
   "      Content of the archive:\n"                                                               .
   "      - Any file where the name starts with 'rqg*' from the workdir of the RQG run.\n"         .
   "        Examples: rqg.log rqg.yy rqg.sql rqg.zz rqg.trc rqg_gd.dump\n"                         .
   "      - The vardir of the RQG run.\n"                                                          .
   "        Examples: data dirs of DB servers, core files, rr traces\n"                            .
   "-------------------------------------------------------------------------------------------\n" .
   "Group of parameters which get either passed through to the Simplifier or appended to the\n"    .
   "final command line of the RQG runner. Both things cause that certain settings within the\n"    .
   "the Combinator or Simplifier config files get overridden or deleted.\n"                        .
   "For their meaning please look into the output of '<runner> --help'.\n"                         .
   "--duration=<n>\n"                                                                              .
   "--gendata=...\n"                                                                               .
   "--grammar=...\n"                                                                               .
   "  Combinator: Override only the grammar maybe assigned in config file.\n"                      .
   "  Simplifier: Ignore any grammar and redefine file maybe assigned in config file.\n"           .
   "--threads=<n>\n"                                                                               .
   "--no_mask      (Assigning --mask or --mask-level on command line is not supported anyway.)\n"  .
   "--sqltrace=...\n"                                                                              .
   "-------------------------------------------------------------------------------------------\n" .
   "rqg_batch will create a symlink '" . BATCH_RESULT_SYMLINK . "' pointing to the workdir of "    .
   "his run\n which is <value assigned to workdir>/<runid>.\n"                                     .
   "-------------------------------------------------------------------------------------------\n" .
   "How to cause some rapid stop of the ongoing rqg_batch.pl run without using some dangerous "    .
   "killall SIGKILL <whatever>?\n"                                                                 .
   "    touch " . BATCH_RESULT_SYMLINK . "/exit\n"                                                 .
   "rqg_batch.pl will stop all active RQG runners, cleanup and give a summary.\n\n"                .
   "What to do on Linux in the rare case (RQG core or runner broken) that this somehow fails?\n"   .
   "    killall -9 perl mysqld mariadbd rr\n"                                                      .
   "-------------------------------------------------------------------------------------------\n" .
   "How to get the roughly 'smallest' rqg_batch.pl run possible for config file checking?\n"       .
   "Just assign\n"                                                                                 .
   "    --parallel=1     --> Have never more than one RQG runner active.\n"                        .
   "    --trials=1       --> Exit after the first regular finished RQG run.\n"                     .
   "-------------------------------------------------------------------------------------------\n" .
   "Impact of RQG_HOME if found in environment and the current working directory:\n"               .
   "Around its start rqg_batch.pl searches for RQG components in <CWD>/lib and "                   .
   "ENV(\$RQG_HOME)/lib\n"                                                                         .
   "- rqg_batch.pl computes than a RQG_HOME based on its call and sets than some corresponding "   .
   "environment variable or aborts.\n"                                                             .
   "  All required RQG components (runner/reporter/validator/...) will be taken from this \n"      .
   "  RQG_HOME 'Universe' in order to ensure consistency between these components.\n"              .
   "- All other ingredients with relationship to some filesystem like\n"                           .
   "     grammars, config files, workdir, vardir, ...\n"                                           .
   "  will be taken according to their setting with absolute path or relative to the current "     .
   "working directory.\n");

}

# Routines to be provided by the packages like Combinator.pm
#
# sub init
#
# sub order_is_valid
#     my ($order_id) = @_;
#
# sub print_order
#     my ($order_id) = @_;
#
# sub dump_orders {
#    no parameters
#
# sub get job
#
# sub register_result
#

sub check_and_set_config_file {
    if (not defined $config_file) {
        say("ERROR: The mandatory config file is not defined.");
        help();
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }
    if (not -f $config_file) {
        say("ERROR: The config file '$config_file' does not exits or is not a plain file.");
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }
    $config_file = Cwd::abs_path($config_file);
    my ($throw_away1, $throw_away2, $suffix) = fileparse($config_file, qr/\.[^.]*/);
    say("INFO: Config file '$config_file', suffix '$suffix'.");
}

sub check_and_set_sqltrace {
    my $status = SQLtrace::check_and_set_sqltracing($sqltrace, $workdir);
    if (STATUS_OK != $status) {
        say("$0 will exit with exit status " . status2text($status) . "($status)");
        run_end($status);
    };
}

1;
