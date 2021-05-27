#!/usr/bin/perl

# Copyright (c) 2019, 2021 MariaDB Corporation Ab.
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

use strict;
use Carp;
use Cwd;
use Time::HiRes;
use POSIX ":sys_wait_h"; # for nonblocking read
use File::Basename;
use File::Path qw(make_path);
use File::Copy;
use File::Compare;
use Getopt::Long;
my $rqg_home;
my $general_config_file;
BEGIN {
    # Cwd::abs_path reports the target of a symlink.
    $rqg_home = File::Basename::dirname(Cwd::abs_path($0));
    print("# DEBUG: rqg_home computed is '$rqg_home'.\n");
    my $rqg_libdir = $rqg_home . '/lib';
    unshift @INC , $rqg_libdir;
    print("# DEBUG: '$rqg_libdir' added to begin of \@INC\n");
    print("# DEBUG \@INC is ->" . join("---", @INC) . "<-\n");
    # In case of making verdicts its most probably unlikely that $RQG_HOME shows up in content.
    # But so we are at least prepared for such cases.
    $ENV{'RQG_HOME'} = $rqg_home;
    if (not -e $rqg_home . "/lib/GenTest.pm") {
        print("ERROR: The rqg_home ('$rqg_home') determined does not look like the root of a " .
              "RQG install.\n");
        exit 2;
    }
    print("# INFO: Environment variable 'RQG_HOME' set to '$rqg_home'.\n");
}

use Auxiliary;
use Verdict;
use GenTest;
use GenTest::Random;
use GenTest::Constants;
use GenTest::Properties;


my $command_line = "$0 ".join(" ", @ARGV);

$| = 1;

my $start_cwd     = Cwd::getcwd();

# my $ctrl_c = 0;

my $verdict_general_config_file = $rqg_home . "/" . Verdict::VERDICT_CONFIG_GENERAL;

my ($config_file, $log_file, $workdir, $help, $help_verdict, $script_debug_value );

# Take the options assigned in command line and
# - fill them into the variables allowed in command line
# - abort in case of meeting some not supported options
my $opt_result = {};
sub help();

my $verdict_file;
my $options = {};
if (not GetOptions(
           'help'                      => \$help,
           'help_verdict'              => \$help_verdict,
           # Configuration file for the rqg_batch.pl
           # == Extraction of code required +  duplicate keys possible
           #    Preload verdict_general.cfg and than the extract.
           'batch_config=s'            => \$config_file,
           # File ready for use for calculation of verdict
           # == Extraction of code not required + no duplicate keys
           #    No preload of verdict_general.cfg.
           'verdict_config=s'          => \$verdict_file,
           # Protocol/log of some finished RQG run
           'log=s'                     => \$log_file,
           # Here sits maybe the config file copy but we might not know its name.
           'workdir=s'                 => \$workdir,
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
$script_debug_value = Auxiliary::script_debug_init($script_debug_value);

# Do not fiddle with other stuff when only help is requested.
if (defined $help) {
    help();
    safe_exit(0);
} elsif (defined $help_verdict) {
    Verdict::help();
    safe_exit(0);
}

my $verdict_config_file;
my $config_setup;


if (defined $workdir) {
    check_and_set_work_dir();
}
if (defined $log_file) {
    check_and_set_log_file();
}
if (defined $config_file) {
    check_and_set_config_file();
}
if (defined $verdict_file) {
    check_and_set_verdict_file();
}


my $variant;
if      (defined $config_file and defined $verdict_file) {
    say("ERROR: batch_config and verdict_config are mutual exclusive.");
    say("The call line was\n    " . $command_line . "\n\n");
    safe_exit(STATUS_ENVIRONMENT_FAILURE);
} elsif (defined $workdir and not defined $config_file and not defined $log_file) {
    # Called by RQG workers (controlled by RQG Batch tool) around end of their work.
    # CWD: rqg_vardir like /dev/shm/vardir/<timestamp>/<worker>
    #      rqg_workdir like /data/Results/<timestamp>/<worker>
    # $command = "perl $rqg_home/verdict.pl --workdir=$rqg_workdir > " .
    #                          "$rqg_workdir/rqg_matching.log 2>&1";
    # $rqg_workdir/rqg.log        --> the log_file to be used here
    # $rqg_workdir/../Verdict.cfg --> the one and only verdict config file to be used here
    #                                 no config extraction required
    $variant = 1;
    say("DEBUG: Verdict.pl call variant $variant") if Auxiliary::script_debug("V2");
    my $up_dir = File::Basename::dirname($workdir);
    $config_file = $up_dir . "/" . Verdict::VERDICT_CONFIG_FILE; # Verdict.cfg
    check_and_set_config_file();
    $log_file = $workdir . "/rqg.log";
    check_and_set_log_file();
    my $content = Auxiliary::getFileSlice($config_file, 10000000);
    Verdict::load_verdict_config($content);
} elsif (defined $workdir and defined $config_file and not defined $log_file) {
    # rqg_batch.pl uses that variant around begin of its work for generating its Verdict.cfg.
    $variant = 2;
    say("DEBUG: Verdict.pl call variant $variant") if Auxiliary::script_debug("V2");
    my $verdict_setup_text  = make_verdict_config($config_file);
    my $verdict_config_file;
    if ($workdir eq $rqg_home) {
        $verdict_config_file = $workdir . "/" . Verdict::VERDICT_CONFIG_TMP_FILE;
    } else {
        $verdict_config_file = $workdir . "/" . Verdict::VERDICT_CONFIG_FILE;
    }
    unlink($verdict_config_file);
    my $result = Auxiliary::make_file ($verdict_config_file, $verdict_setup_text);
    if (STATUS_OK != $result) {
        # Auxiliary::make_file already reported the problem.
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }
    exit STATUS_OK;
} elsif (not defined $workdir and defined $log_file and defined $config_file) {
    # Load verdict_general.cfg, check it, merge parts of $config_file over it and judge.
    $variant = 3;
    say("DEBUG: Verdict.pl call variant $variant") if Auxiliary::script_debug("V2");
    $workdir = $start_cwd;
    my $verdict_setup_text = make_verdict_config($config_file);
    my $verdict_config_file = $rqg_home . "/" . Verdict::VERDICT_CONFIG_TMP_FILE;
    unlink($verdict_config_file);
    my $result = Auxiliary::make_file ($verdict_config_file, $verdict_setup_text);
    if (STATUS_OK != $result) {
        # Auxiliary::make_file already reported the problem.
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }
} elsif (not defined $workdir     and defined $log_file and
         not defined $config_file and not defined $verdict_file) {
    # Load verdict_general.cfg, check it and judge.
    $variant = 4;
    say("DEBUG: Verdict.pl call variant $variant") if Auxiliary::script_debug("V2");
    $workdir = $start_cwd;
    my $verdict_setup_text  = make_verdict_config($verdict_general_config_file);
    my $verdict_config_file = $rqg_home . "/" . Verdict::VERDICT_CONFIG_TMP_FILE;
    unlink($verdict_config_file);
    my $result = Auxiliary::make_file ($verdict_config_file, $verdict_setup_text);
    if (STATUS_OK != $result) {
        # Auxiliary::make_file already reported the problem.
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }
} elsif (not defined $workdir     and defined $log_file and
         not defined $config_file and defined $verdict_file) {
    # Load  $verdict_file and judge.
    $variant = 5;
    say("DEBUG: Verdict.pl call variant $variant") if Auxiliary::script_debug("V2");
    $workdir = $start_cwd;
    my $content = Auxiliary::getFileSlice($verdict_file, 10000000);
    Verdict::load_verdict_config($content);
} else {
    say("ERROR: No idea what to do for the command:\n" . $command_line);
    safe_exit(STATUS_ENVIRONMENT_FAILURE);
}

my ($verdict, $extra_info) = Verdict::calculate_verdict($log_file);
if (1 == $variant) {
    my $status = Verdict::set_final_rqg_verdict($workdir, $verdict, $extra_info);
}

say("\nVerdict: " . $verdict . ", Extra_info: " . $extra_info);

sub help() {
   print(
   "\nSorry, under construction and therefore partially different or not yet implemented.\n\n"     .
   "Purpose: (mostly) Classify the result of some RQG run and give a verdict.\n\n"                 .
   "         Classification: STATUS_SERVER_CRASHED--TBR-826-MDEV-24643\n"                          .
   "                         status reported by RQG runner--names of text patterns found\n\n"      .
   "         Verdict    | Reaction of tools calling verdict.pl\n"                                  .
   "         -----------+-----------------------------------------------------------\n"            .
   "         'replay'   | archiving of results (*) and progress if test simplification\n"          .
   "         'interest' | archiving of results (*)\n"                                              .
   "         'ignore*'  | no archiving of results and removal of rqg.log(**)\n\n"                  .
   "         (*)  if not disabled via   --noarchiving\n"                                           .
   "         (**) if enabled via        --discard_logs\n\n"                                          .
   "    perl verdict.pl [[--config_file=<value>|--verdict_file=<value>]] [--log=<value>] "         .
   "[--workdir=<value>] [--script_debug=<value>]\\n"                                               .
   "Some typical calls:\n"                                                                         .
   "    # Check some RQG run.\n"                                                                   .
   "    perl verdict.pl --log_file=<whatever>/000013.log\n"                                        .
   "         load the default RQG_HOME/" . Verdict::VERDICT_CONFIG_GENERAL . "\n"                  .
   "         store the setup in RQG_HOME/" .  Verdict::VERDICT_CONFIG_TMP_FILE . "\n"              .
   "         emit verdict and classification\n"                                                    .
   "\n"                                                                                            .
   "    # Check if the simplifier config simp97.cfg fits.\n"                                       .
   "    perl verdict.pl --batch_config=simp97.cfg --log_file==<whatever>/000013.log\n"             .
   "         load the default RQG_HOME/" . Verdict::VERDICT_CONFIG_GENERAL . " first\n"            .
   "         than load+overwrite(assessment per pattern) with content from CWD/simp97.cfg\n"       .
   "         store the setup in RQG_HOME/" .  Verdict::VERDICT_CONFIG_TMP_FILE . "\n"              .
   "         emit verdict and classification\n"                                                    .
   "\n"                                                                                            .
   "    # Check if a ready for use (== generated by verdict.pl) verdict config fits.\n"            .
   "    perl verdict.pl --verdict_config=Verdict.cfg --log_file=last_batch_workdir/000013.log\n"   .
   "         load CWD/Verdict.cfg\n"                                                               .
   "         emit verdict and classification\n"                                                    .
   "\n"                                                                                            .
   "--help\n"                                                                                      .
   "      Some general help about verdict.pl and its command line parameters/options\n"            .
   "--help_verdict\n"                                                                              .
   "      Information about how to setup parameters which are used for classification of test\n"   .
   "      results and defining desired and to be ignored test outcomes.\n"                         .
   "\n"                                                                                            .
   "--batch_config=<config file to be used by a tool like rqg_batch.pl>\n"                         .
   "      This file is usually a\n"                                                                .
   "      - Combinator configuration file (common extension .cc)\n"                                .
   "      - Simplifier configuration file (common extension .cfg)\n"                               .
   "      and could contain additional information about classifications and assessment.\n"        .
   "--verdict_config=<ready for use Verdict configuration file (common extension .cfg)\n"          .
   "--log=<RQG log file to be checked>\n"                                                          .
   "--script_debug=...\n"                                                                          .
   "      Print additional detailed information about decisions made by the tool components\n"     .
   "      assigned and observations made during runtime.\n"                                        .
   "      (Default) No additional debug information.\n"                                            .
   "          '--script_debug=_all_' == Debug output as much as available\n"                       .
   "-------------------------------------------------------------------------------------------\n" .
   "All assigned files must be either with absolute path or path relative to the current working " .
   "directory.\n"                                                                                  .
   "Certain components (lib/Verdict.pm, " . Verdict::VERDICT_CONFIG_GENERAL . ") have to be "      .
   "taken from the top level directory of the RQG install.\n"                                      .
   "The required value for RQG_HOME gets computed from the call of verdict.pl.\n"                  .
   "Any setting of RQG_HOME within the environment will get ignored!\n"                            .
   "\n");

}

sub check_and_set_config_file {
    if (not -f $config_file) {
        say("ERROR: The assigned file '$config_file' does not exist or is not a plain file.");
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }
    $config_file = Cwd::abs_path($config_file);
    # my ($throw_away1, $throw_away2, $suffix) = fileparse($config_file, qr/\.[^.]*/);
}

sub check_and_set_verdict_file {
    if (not -f $verdict_file) {
        say("ERROR: The assigned file '$verdict_file' does not exist or is not a plain file.");
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }
    my $fname1 = Verdict::VERDICT_CONFIG_FILE;
    my $fname2 = Verdict::VERDICT_CONFIG_TMP_FILE;
    if (not $verdict_file =~ m{$fname1} and not $verdict_file =~ m{$fname2}) {
        say("ERROR: verdict_file '$verdict_file' looks suspicious..");
        say("ERROR: Please assign it to '--batch_config' instead.");
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }
    $verdict_file = Cwd::abs_path($verdict_file);
}

sub check_and_set_log_file {
    if (not -f $log_file) {
        say("ERROR: The assigned file '$log_file' does not exist or is not a plain file.");
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }
    $log_file = Cwd::abs_path($log_file);
}

sub check_and_set_work_dir {
    if (not -d $workdir) {
        say("ERROR: The assigned directory '$workdir' does not exist or is not a directory.");
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }
    $workdir = Cwd::abs_path($workdir);
}

sub make_verdict_config {
    my ($assigned_config_file) = @_;

    say("DEBUG: make_verdict_config with '$assigned_config_file' start.")
        if Auxiliary::script_debug("V5");
    $config_file = $assigned_config_file;

    # check_and_set_config_file transforms $config_file to go with abspath.
    check_and_set_config_file();
    # PGM begin sets $verdict_general_config_file with absolute path.
    my $content = Auxiliary::getFileSlice($verdict_general_config_file, 10000000);
    # load_verdict_config aborts in case of failure
    Verdict::load_verdict_config($content);
    say("INFO: make_verdict_config: '$verdict_general_config_file' processing finished.");
    my $verdict_setup_text;
    $verdict_setup_text = Verdict::get_setup_text();
    say("VERDICT SETUP per '($verdict_general_config_file' is =>\n" .  $verdict_setup_text . "\n<=")
        if Auxiliary::script_debug("V2");

    if (Cwd::abs_path($config_file) eq $verdict_general_config_file) {
        # Do nothing
    } else {
        say("INFO: make_verdict_config: Start processing of '$config_file'.");
        $content = Verdict::extract_verdict_config(Cwd::abs_path($config_file));
        if (not defined $content) {
            say("ERROR: Extracting content relevant for verdict setup failed.");
            help();
            safe_exit(STATUS_ENVIRONMENT_FAILURE);
        } elsif ('' eq $content) {
            say("INFO: No content relevant for verdict setup found in '$config_file'.");
        } else {
            say("\nContent of '$config_file' -------------\n" . $content . "\n\n")
                if Auxiliary::script_debug("V2");
            Verdict::load_verdict_config($content);
            say("INFO: make_verdict_config: '$config_file' processing finished.");
        }
    }
    $verdict_setup_text = Verdict::get_setup_text();
    if (not defined $verdict_setup_text) {
        say("ERROR: Verdict::get_setup_text returned undef.");
        safe_exit(STATUS_INTERNAL_ERROR);
    }
    if ('' eq $verdict_setup_text) {
        say("ERROR: Verdict::get_setup_text returned ''.");
        safe_exit(STATUS_INTERNAL_ERROR);
    }
    my $text_A = $verdict_setup_text;

    # Plausibility check:
    Verdict::reset_hashes();
    Verdict::load_verdict_config($text_A);

    $verdict_setup_text = Verdict::get_setup_text();
    if (not defined $verdict_setup_text) {
        say("ERROR: Verdict::get_setup_text returned undef.");
        safe_exit(STATUS_INTERNAL_ERROR);
    }
    if ('' eq $verdict_setup_text) {
        say("ERROR: Verdict::get_setup_text returned ''.");
        safe_exit(STATUS_INTERNAL_ERROR);
    }
    my $text_B = $verdict_setup_text;

    if ($text_A ne $text_B) {
        say("ERROR: make_verdict_config: Plausibility check failed: Diff between 'text_A' and " .
            "'text_B'.");
        say("text_A--->\n" . $text_A . "\n<--");
        say("text_B--->\n" . $text_B . "\n<--");
        safe_exit(STATUS_INTERNAL_ERROR);
    }

    return $verdict_setup_text;

}


1;
