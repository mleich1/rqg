#!/usr/bin/perl

# Copyright (C) 2008-2010 Sun Microsystems, Inc. All rights reserved.
# Copyright (c) 2025 MariaDB plc
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

$| = 1;

use strict;
use lib 'lib';
use lib '../lib';
use DBI;
use Carp;
use File::Compare;
use File::Copy;
use Getopt::Long;
use Time::HiRes;

use GenTest_e;
use GenTest_e::Properties;
use GenTest_e::Constants;
use GenTest_e::Simplifier::Mysqltest;
use Basics;
use Auxiliary;


# NOTE: "oracle" function behaves differently if basedir2 is specified in addition
#       to basedir. In this case expected_mtr_output is ignored, and result
#       comparison between servers is performed instead.

my $options = {};
my $o = GetOptions($options,
           'config=s',
           'input_file=s',
           'basedir=s',
           'basedir2=s',
           'expected_mtr_output=s',
           'verbose!',
           'mtr_options=s%',
           'mysqld=s%');
my $config = GenTest_e::Properties->new(
    options => $options,
    legal => [
        'config',
        'input_file',
        'basedir',
        'basedir2',
        'expected_mtr_output',
        'mtr_options',
        'verbose',
        'header',
        'footer',
        'filter',
        'mysqld',
        'use_connections'
    ],
    required => [
        'basedir',
        'input_file',
        'mtr_options']
    );

$config->printHelp if not $o;
$config->printProps;

my $header = $config->header() || [];
my $footer = $config->footer() || [];

# End of user-configurable section

my $iteration = 0;
my $run_id = time();

say("run_id = $run_id");
# FIXME maybe: Add setting that value etc.
my $script_debug_value = Auxiliary::script_debug_init("_nix_");

## Check/Build infrastructure
my $mysql_test_dir;
my $mysql_test_dir_new = $config->basedir . '/mariadb-test';
my $mysql_test_dir_old = $config->basedir . '/mysql-test';
if      (-e $mysql_test_dir_new) {
    $mysql_test_dir = $mysql_test_dir_new;
} elsif (-e $mysql_test_dir_old) {
    $mysql_test_dir = $mysql_test_dir_old;
} else {
    say("ERROR: Top level directory for MTR tests is missing.");
    say("ERROR: Neither '$mysql_test_dir_new' nor '$mysql_test_dir_old' found.");
    exit (STATUS_ENVIRONMENT_FAILURE);
}
say("INFO: mysql_test_dir : " . $mysql_test_dir);

my $suite_dir = "simplify";
my $suite_dir_full_path = $mysql_test_dir . '/suite/' . $suite_dir;
if (STATUS_OK != Basics::conditional_make_dir($suite_dir_full_path)) {
    exit (STATUS_ENVIRONMENT_FAILURE);
}
if (STATUS_OK != Basics::conditional_make_dir($suite_dir_full_path . '/t')) {
    exit (STATUS_ENVIRONMENT_FAILURE);
}
if (STATUS_OK != Basics::conditional_make_dir($suite_dir_full_path . '/r')) {
    exit (STATUS_ENVIRONMENT_FAILURE);
}
say("INFO: Simplified tests will be stored in : " . $suite_dir_full_path);

my $mysql_test_dir2;
my $suite_dir2_full_path;
if (defined $config->basedir2) {
    say ('Two basedirs specified. Will compare outputs instead of looking for expected output.');
    say ('Server A: ' . $config->basedir);
    say ('Server B: ' . $config->basedir2);

    ## Check/Build infrastructure
    my $mysql_test_dir2_new = $config->basedir2 . '/mariadb-test';
    my $mysql_test_dir2_old = $config->basedir2 . '/mysql-test';
    if      (-e $mysql_test_dir2_new) {
        $mysql_test_dir2 = $mysql_test_dir2_new;
    } elsif (-e $mysql_test_dir2_old) {
        $mysql_test_dir2 = $mysql_test_dir2_old;
    } else {
        say("ERROR: Top level directory for MTR tests is missing.");
        say("ERROR: Neither '$mysql_test_dir2_new' nor '$mysql_test_dir2_old' found.");
        exit (STATUS_ENVIRONMENT_FAILURE);
    }
    $suite_dir2_full_path = $mysql_test_dir2 . '/suite/' . $suite_dir;
    if (STATUS_OK != Basics::conditional_make_dir($suite_dir2_full_path)) {
        exit (STATUS_ENVIRONMENT_FAILURE);
    }
    if (STATUS_OK != Basics::conditional_make_dir($suite_dir2_full_path . '/t')) {
        exit (STATUS_ENVIRONMENT_FAILURE);
    }
    if (STATUS_OK != Basics::conditional_make_dir($suite_dir2_full_path . '/r')) {
        exit (STATUS_ENVIRONMENT_FAILURE);
    }
}

my $simplifier = GenTest_e::Simplifier::Mysqltest->new(
    filter => $config->filter(),
    use_connections => $config->use_connections(),
    oracle => sub {
        my $oracle_mysqltest = shift;
        $iteration++;

        chdir($mysql_test_dir);

        my $testfile_base_name =    $run_id . '-' . $iteration;
        my $testfile =              $testfile_base_name . '.test';
        my $testfile_full_path =    $suite_dir_full_path . "/t/" . $testfile;
        my $resultfile =            $testfile_base_name . '.result';
        my $resultfile_full_path =   $suite_dir_full_path . "/r/" . $resultfile;

        if (not open (ORACLE_MYSQLTEST, ">" . $testfile_full_path)) {
            Carp::cluck("ERROR: Unable to open $testfile: $!");
            exit (STATUS_ENVIRONMENT_FAILURE);
        }

        print ORACLE_MYSQLTEST join("\n", @{$header}) . "\n\n";
        print ORACLE_MYSQLTEST $oracle_mysqltest;
        print ORACLE_MYSQLTEST "\n\n" . join("\n", @{$footer}) . "\n";
        close ORACLE_MYSQLTEST;
        my $mysqldopt =         $config->genOpt('--mysqld=--', 'mysqld');
        my $mtr_start_time =    Time::HiRes::time();
        my $mysqltest_cmd =     "perl mysql-test-run.pl $mysqldopt " .
                                $config->genOpt('--', 'mtr_options') .
                                " --suite=$suite_dir $testfile 2>&1";
        my $mysqltest_output =  `$mysqltest_cmd`;
        my $mtr_exit_code =     $? >> 8;
        my $mtr_duration =      Time::HiRes::time() - $mtr_start_time;
        if ($iteration == 1) {
            say ($mysqltest_output);
        } else {
            say ("INFO: MTR test duration: $mtr_duration; exit_code: $mtr_exit_code");
        }

        my $error_log = $mysql_test_dir . '/var/log/mysqld.1.err';
        my $found = Auxiliary::search_in_file($error_log, 'Unsafe statement binlogged');
        if (not defined $found) {
            # File does not exist or is not readable was already reported.
            exit (STATUS_ENVIRONMENT_FAILURE);
        } elsif (1 == $found ) {
            say("Messages about unsafe replication found in master error log.");
            return ORACLE_ISSUE_NO_LONGER_REPEATABLE;
        } else {
            # Message not found + nothng extra to do.
        }


        ########################################################################
        # Start of comparison mode (two basedirs)
        ########################################################################

        if (defined $config->basedir2) {
            #
            # Run the test against basedir2 and compare results against the previous run.
            #

            chdir($mysql_test_dir2);

            # working dir is now for Server B, so we need full path to Server A's files for later

            # tests/results for Server B include "-b" in the filename
            my $testfile2_base_name =   $run_id . '-' . $iteration . '-b';;
            my $testfile2 =             $testfile2_base_name . '.test';
            my $testfile2_full_path =   $suite_dir2_full_path . "/t/" . $testfile2;
            my $resultfile2 =           $testfile2_base_name . '.result';
            my $resultfile2_full_path = $suite_dir2_full_path . "/r/" . $resultfile2;

            # Copy test file to server B
            if (Basics::copy_file($testfile_full_path, $testfile2_full_path)) {
                exit (STATUS_ENVIRONMENT_FAILURE);
            }

            my $mysqltest_cmd2 =    "perl mysql-test-run.pl $mysqldopt " .
                                    $config->genOpt('--', 'mtr_options') .
                                    " --suite=$suite_dir $testfile2 2>&1";
            # Run the test against server B
            # we don't really use this output for anything right now
            my $mysqltest_output2 = `$mysqltest_cmd2`;
            #say $mysqltest_output2 if $iteration == 1;


            # Compare the two results
            # We declare the tests to have failed properly only if the results
            # from the two test runs differ.
            # (We ignore expected_mtr_output in this mode)
            my $compare_result = compare($resultfile_full_path, $resultfile2_full_path);
            if ( $compare_result == 0) {
                # no diff
                say('Issue not repeatable (results were equal) with test '.$testfile_base_name);
                if ($iteration > 1) {
                    unlink($testfile_full_path); # deletes test for Server A
                    unlink($testfile2_full_path); # deletes test for Server B
                    unlink($resultfile_full_path); # deletes result for Server A
                    unlink($resultfile2_full_path); # deletes result for Server B
                }
                return ORACLE_ISSUE_NO_LONGER_REPEATABLE;
            } elsif ($compare_result > 0) {
                # diff
                say("Issue is repeatable (results differ) with test $testfile_base_name");
                return ORACLE_ISSUE_STILL_REPEATABLE;
            } else {
                # error ($compare_result < 0)
                if ( (! -e $resultfile_full_path) && (! -e $resultfile2_full_path) ) {
                    # both servers are lacking result file. Probably due to bad SQL in simplified test.
                    return ORACLE_ISSUE_NO_LONGER_REPEATABLE;
                }
                if (! -e $resultfile_full_path) {
                    say("Error ($compare_result) comparing result files for test $testfile_base_name");
                    say("Test output was:");
                    say $mysqltest_output;
                    croak("Resultfile  $resultfile_full_path not found");
                } elsif (! -e $resultfile2_full_path) {
                    say("Error ($compare_result) comparing result files for test $testfile_base_name");
                    say("Test output was:");
                    say $mysqltest_output2;
                    croak("Resultfile2 $resultfile2_full_path not found");
                }
            }

        ########################################################################
        # End of comparison mode (two basedirs)
        ########################################################################

        } else {
            # Only one basedir specified - retain old behavior (look for expected output).

            #
            # We declare the test to have failed properly only if the
            # desired message is present in the output and it is not a
            # result of an error that caused part of the test, including
            # the --croak construct, to be printed to stdout.
            #

            my $expected_mtr_output = $config->expected_mtr_output;
            if (
                ($mysqltest_output =~ m{$expected_mtr_output}sio) &&
                ($mysqltest_output !~ m{--die}sio)
            ) {
                say("Issue repeatable with $testfile");
                return ORACLE_ISSUE_STILL_REPEATABLE;
            } else {
                say("Issue not repeatable with $testfile.");
                if (
                    ($mtr_exit_code == 0) &&
                    ($iteration > 1)
                ) {
                    unlink($testfile);
                    unlink($resultfile_full_path);
                }

                say $mysqltest_output if $iteration > 1 && $mtr_exit_code != 0;
                return ORACLE_ISSUE_NO_LONGER_REPEATABLE;
            }
        }
    }
);

my $simplified_mysqltest;

## Copy input file
if (-f $config->input_file){
    $config->input_file =~ m/\.([a-z]+$)/i;
    my $extension = $1;
    my $input_file_copy = $suite_dir_full_path . "/t/" . $run_id . "-0." . $extension;
    if (Basics::copy_file($config->input_file, $input_file_copy)) {
        exit (STATUS_ENVIRONMENT_FAILURE);
    }
    # Fore testing
    # system("ls -ld $input_file_copy");

    if (lc($extension) eq 'csv') {
        say("INFO: Treating ".$config->input_file." as a CSV file");
        $simplified_mysqltest = $simplifier->simplifyFromCSV($input_file_copy);
    } elsif (lc($extension) eq 'test') {
        say("INFO: Treating " . $config->input_file . " as a mysqltest file");
        open (MYSQLTEST_FILE , $input_file_copy)
            or croak "ERROR: Unable to open " . $input_file_copy . " as a .test file: $!";
        read (MYSQLTEST_FILE , my $initial_mysqltest, -s $input_file_copy);
        close (MYSQLTEST_FILE);
        $simplified_mysqltest = $simplifier->simplify($initial_mysqltest);
    } else {
        carp "ERROR: Unknown file type for " . $config->input_file;
    }

    if (defined $simplified_mysqltest) {
        say "INFO: Simplified mysqltest:";
        print "\n\n" . join("\n", @{$header}) . "\n\n\n" . $simplified_mysqltest .
              join("\n", @{$footer}) . "\n\n";
        exit (STATUS_OK);
    } else {
        say "INFO: Unable to simplify " . $config->input_file . ".\n";
        exit (STATUS_ENVIRONMENT_FAILURE);
    }
} else {
    croak "ERROR: Can't find " . $config->input_file;
}
##

