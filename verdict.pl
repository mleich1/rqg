#!/usr/bin/perl

# Copyright (c) 2019 MariaDB Corporation Ab.
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
#   - Per just finished RQG run immediate judging based on status + text patterns
#     and creation of archives + first cleanup (all moved to rqg.pl)
#   - unification regarding storage places
# - combinations.pl
#   Parallelization + combinations mechanism
# There we have GNU General Public License version 2 too and
# Copyright (c) 2008, 2011 Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2013, Monty Program Ab.
# Copyright (c) 2018, MariaDB Corporation Ab.
#
# The amount of parameters (call line + config file) is in the moment
# not that stable.
#

use strict;
use Carp;
use Cwd;
use Time::HiRes;
use POSIX ":sys_wait_h"; # for nonblocking read
use File::Basename;
use File::Path qw(make_path);
use File::Copy;
use lib 'lib';
use lib "$ENV{RQG_HOME}/lib";
use Auxiliary;
use Verdict;
# use Combinator;
# use Simplifier;
use GenTest;
use GenTest::Random;
use GenTest::Constants;
use GenTest::Properties;
use Getopt::Long;
# use Data::Dumper;

my $command_line = "$0 ".join(" ", @ARGV);

$| = 1;

my $batch_start_time = time();


#---------------------
my $rqg_home;
my $rqg_home_call = Cwd::abs_path(File::Basename::dirname($0));
my $rqg_home_env  = $ENV{'RQG_HOME'};
my $start_cwd     = Cwd::getcwd();
#---------------------

# FIXME: Harden that
# rqg_batch.pl and RQG_HOME if assigned must be from the same universe
if (defined $rqg_home_env) {
    print("WARNING: The variable RQG_HOME with the value '$rqg_home_env' was found in the " .
          "environment.\n");
    if (osWindows()) {
        $ENV{RQG_HOME} = $ENV{RQG_HOME}.'\\';
    } else {
        $ENV{RQG_HOME} = $ENV{RQG_HOME}.'/';
    }
} else {
    $ENV{RQG_HOME} = dirname(Cwd::abs_path($0));
}
$rqg_home = $rqg_home_call;

if ( osWindows() )
{
    require Win32::API;
    my $errfunc = Win32::API->new('kernel32', 'SetErrorMode', 'I', 'I');
    my $initial_mode = $errfunc->Call(2);
    $errfunc->Call($initial_mode | 2);
};

# FIXME: Do we really need the logger
# my $logger;
# eval
# {
    # require Log::Log4perl;
    # Log::Log4perl->import();
    # $logger = Log::Log4perl->get_logger('randgen.gentest');
# };

# my $ctrl_c = 0;

my ($config_file, $log_file, $dryrun, $workdir, $help, $help_verdict, $script_debug_value );

# Take the options assigned in command line and
# - fill them into the variables allowed in command line
# - abort in case of meeting some not supported options
my $opt_result = {};
sub help();

my $options = {};
if (not GetOptions(
           'help'                      => \$help,
           'help_verdict'              => \$help_verdict,
           ### config == Details of campaign setup
           # Check existence of file here. pass_through as parameter
           'config=s'                  => \$config_file,
           'log_file=s'                => \$log_file,
           # Here sits maybe the config file copy but we might not know its name.
           'workdir=s'                 => \$workdir,
# ???      'dryrun=s'                  => \$dryrun,
           'script_debug=s'            => \$script_debug_value,
                                                   )) {
    # Somehow wrong option.
    help();
    safe_exit(STATUS_ENVIRONMENT_FAILURE);
};

my $argv_remain = join(" ", @ARGV);
if (defined $argv_remain and $argv_remain ne '') {
    say("WARN: The following command line content is left over ==> gets ignored. ->$argv_remain<-");
}

# Support script debugging as soon as possible.
# my $scrip_debug_string = Auxiliary::script_debug_init($script_debug_value);
$script_debug_value = Auxiliary::script_debug_init($script_debug_value);

# Do not fiddle with other stuff when only help is requested.
if (defined $help) {
    help();
    safe_exit(0);
} elsif (defined $help_verdict) {
    Verdict::help();
    safe_exit(0);
}

# use constant STATUS_OK       => 0;
use constant STATUS_FAILURE    => 1; # Just the opposite of STATUS_OK

my $variant;
if (defined $workdir and not defined $config_file and not defined $log_file) {
    # Called by RQG workers around end of their work.
    $variant = 1;
    # Check existence++ $workdir
    my $up_dir = File::Basename::dirname($workdir);
    $config_file = $up_dir . "/" . Verdict::VERDICT_CONFIG_FILE;
    # Check existence++ $config_file
    $log_file = $workdir . "/rqg.log";
    check_and_set_log_file();
} elsif (not defined $workdir and defined $log_file and defined $config_file) {
    # Called from command line with config file specified.
    $variant = 2;
    $workdir = $start_cwd;
    check_and_set_config_file();
    check_and_set_log_file();
} elsif (not defined $workdir and defined $log_file and not defined $config_file) {
    # Called from command line without config file specified.
    $variant = 3;
    $workdir = $start_cwd;
    $config_file = $workdir . '/verdict_for_combinations.cfg';
    check_and_set_config_file();
    check_and_set_log_file();
} else {
    say("ERROR: No idea what to do for the command:\n" . $command_line);
    exit(4);
}
say("DEBUG: variant is $variant");

my $verdict_config_file = Verdict::get_verdict_config_file ($workdir, $config_file);
say("DEBUG: verdict_config_file is '$verdict_config_file'");
my $config_setup        = Verdict::load_verdict_config_file($verdict_config_file);

if (not defined $config_setup or '' eq $config_setup or '') {
    say("ERROR: Setup of Verdict configuration failed.");
    exit 4;
}
if (not 1 == $variant) {
    say("\nVerdict setup ---------------------------------------- begin\n" .
        $config_setup .
        "Verdict setup ---------------------------------------- end");
    say('');
}

my ($verdict, $extra_info) = Verdict::calculate_verdict($log_file);
if (1 == $variant) {
    my $status = Verdict::set_final_rqg_verdict($workdir, $verdict, $extra_info);
}

say("\nVerdict: " . $verdict . ", Extra_info: " . $extra_info);

sub help() {
   print(
   "\nSorry, under construction and partially different or not yet implemented.\n\n"               .
   "Purpose: Perform a batch of RQG runs with massive parallelization according to setup/config\n" .
   "\n"                                                                                            .
   "--help\n"                                                                                      .
   "      Some general help about verdict.pl and its command line parameters/options\n"            .
   "--help_verdict\n"                                                                              .
   "      Information about how to setup the black and whitelist parameters which are used for\n"  .
   "      defining desired and to be ignored test outcomes.\n"                                     .
   "\n"                                                                                            .
   "--config=<config file with path absolute or path relative to top directory of RQG install>\n"  .
   "      This file could be a\n"                                                                  .
   "      - Combinator configuration file (extension .cc)\n"                                       .
   "      - Simplifier configuration file (extension .cfg)\n"                                      .
   "      - Verdict configuration file (extension .cfg)\n"                                         .
   "--log_file=<verdict_value>\n"                                                                  .
   "      RQG log file to be checked\n"                                                            .
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
   "-------------------------------------------------------------------------------------------\n" .
   "Impact of RQG_HOME if found in environment and the current working directory:\n"               .
   "Around its start rqg_batch.pl searches for RQG components in <CWD>/lib and ENV(\$RQG_HOME)/lib\n" .
   "- rqg_batch.pl computes than a RQG_HOME based on its call and sets than some corresponding "   .
   "  environment variable or aborts.\n"                                                           .
   "  All required RQG components (runner/reporter/validator/...) will be taken from this \n"      .
   "  RQG_HOME 'Universe' in order to ensure consistency between these components.\n"              .
   "- All other ingredients with relationship to some filesystem like\n"                           .
   "     grammars, config files, workdir, vardir, ...\n"                                           .
   "  will be taken according to their setting with absolute path or relative to the current "     .
   "working directory.\n");

}

sub check_and_set_config_file {
    if (not defined $config_file) {
        say("ERROR: The mandatory config file is not defined.");
        help();
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }
    if (not -f $config_file) {
        say("ERROR: The config file '$config_file' does not exist or is not a plain file.");
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }
    $config_file = Cwd::abs_path($config_file);
    my ($throw_away1, $throw_away2, $suffix) = fileparse($config_file, qr/\.[^.]*/);
    say("DEBUG: Config file '$config_file', suffix '$suffix'.");
}

sub check_and_set_log_file {
    if (not defined $log_file) {
        say("ERROR: The mandatory log file is not defined.");
        help();
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }
    if (not -f $log_file) {
        say("ERROR: The RQG log file '$log_file' does not exits or is not a plain file.");
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }
    $log_file = Cwd::abs_path($log_file);
    say("DEBUG: RQG log file '$log_file'.");
}

1;
