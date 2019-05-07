#!/usr/bin/perl

# Copyright (C) 2018, 2019 MariaDB Corporation Ab.
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

use Carp;
# How many characters of each argument to a function to print.
$Carp::MaxArgLen=  200;
# How many arguments to each function to show. Btw. 8 is also the default.
$Carp::MaxArgNums= 8;

# use File::Basename qw(dirname);
# use Cwd qw(abs_path);
use File::Basename; # We use dirname
use Cwd;            # We use abs_path , getcwd
my $rqg_home;
my $rqg_home_call = Cwd::abs_path(File::Basename::dirname($0));
# Warning:
#     my $rqg_home_env  = Cwd::abs_path($ENV{'RQG_HOME'});
# This delivers the absolute path to the current directory in case RQG_HOME is not set!
my $rqg_home_env  = $ENV{'RQG_HOME'};
if (defined $rqg_home_env) {
    $rqg_home_env  = Cwd::abs_path($rqg_home_env);
}
my $start_cwd     = Cwd::getcwd();

use lib 'lib'; # In case we are in the root of a RQG install than we have at least a chance.

if (defined $rqg_home_env) {
   if ($rqg_home_env ne $rqg_home_call) {
      print("ERROR: RQG_HOME found in environment ('$rqg_home_env') and RQG_HOME computed from " .
            "the RQG call ('$rqg_home_call') differ.\n");
      Auxiliary::help_rqg_home();
      exit 2;
   } else {
      $rqg_home = $rqg_home_env;
      say("DEBUG: rqg_home '$rqg_home' taken from environment might be usable.\n");
   }
} else {
   # RQG_HOME is not set
   if ($rqg_home_call ne $start_cwd) {
      # We will maybe not able to find the libs and harvest
      # Perl BEGIN failed--compilation aborted ... immediate.
      print("ERROR: RQG_HOME was not found in environment and RQG_HOME computed from the "  .
            "RQG call ('$rqg_home_call') is not equal to the current working directory.\n");
      Auxiliary::help_rqg_home();
      exit 2;
   } else {
      $rqg_home = $start_cwd;
      print("DEBUG: rqg_home '$rqg_home' computed usable\n");
   }
}
# say("DEBUG: rqg_home might be ->$rqg_home<-");
if (not -e $rqg_home . "/lib/GenTest.pm") {
   print("ERROR: The rqg_home ('$rqg_home') determined does not look like the root of a " .
         "RQG install.\n");
         exit 2;
}
$ENV{'RQG_HOME'} = $rqg_home;
say("INFO: Environment variable 'RQG_HOME' set to '$rqg_home'");

# use lib 'lib';
use lib $rqg_home . "/lib";
$rqg_home_env = $ENV{'RQG_HOME'};


use constant RQG_RUNNER_VERSION  => 'Version 3.0.0 (2018-05)';
use constant STATUS_CONFIG_ERROR => 199;

use strict;
use GenTest;
use Auxiliary;
use GenTest::Constants;
use GenTest::Properties;
use GenTest::App::GenTest;
use GenTest::App::GenConfig;
# use DBServer::DBServer;
# use DBServer::MySQL::MySQLd;
# use DBServer::MySQL::ReplMySQLd;
# use DBServer::MySQL::GaleraMySQLd;
use Verdict;

if (defined $ENV{RQG_HOME}) {
   if (osWindows()) {
      $ENV{RQG_HOME} = $ENV{RQG_HOME}.'\\';
   } else {
      $ENV{RQG_HOME} = $ENV{RQG_HOME}.'/';
   }
}

use Getopt::Long;
use GenTest::Constants;
use DBI;
use Cwd;

# This is the "default" database. Connects go into that database.
my $database = 'test';
# Connects which do not specify a different user use that user.
my $user     = 'rqg';
my @dsns;

my ($gendata, @basedirs, @mysqld_options, @vardirs, $rpl_mode,
    @engine, $help, $help_long, $debug, @validators, @reporters, @transformers,
    $grammar_file, $skip_recursive_rules,
    @redefine_files, $seed, $mask, $mask_level, $mem, $rows,
    $varchar_len, $xml_output, $valgrind, @valgrind_options, @vcols, @views,
    $start_dirty, $filter, $build_thread, $sqltrace, $testname,
    $report_xml_tt, $report_xml_tt_type, $report_xml_tt_dest,
    $notnull, $logfile, $logconf, $report_tt_logdir, $querytimeout, $no_mask,
    $short_column_names, $strict_fields, $freeze_time, $wait_debugger, @debug_server,
    $skip_gendata, $skip_shutdown, $galera, $use_gtid, $genconfig, $annotate_rules,
    $restart_timeout, $gendata_advanced, $scenario, $upgrade_test, $store_binaries,
    $ps_protocol, @gendata_sql_files, $config_file,
    @whitelist_statuses, @whitelist_patterns, @blacklist_statuses, @blacklist_patterns,
    $archiver_call, $workdir,
    $options, $script_debug);

my $gendata   = ''; ## default simple gendata
my $genconfig = ''; # if template is not set, the server will be run with --no-defaults

# Place rather into the preset/default section for all variables.
my $threads  = my $default_threads  = 10;
my $queries  = my $default_queries  = 100000000;
my $duration = my $default_duration = 3600;

my @ARGV_saved = @ARGV;

# Take the options assigned in command line and
# - fill them into the of variables allowed in command line
# - abort in case of meeting some not supported options
my $opt_result = {};

my $log_file;
if (not GetOptions(
    $opt_result,
    'log_file:s'                  => \$log_file,
    'workdir:s'                   => \$workdir,
    'help'                        => \$help,
    'help_long'                   => \$help_long,
    'debug'                       => \$debug,
    'whitelist_statuses:s@'       => \@whitelist_statuses,
    'whitelist_patterns:s@'       => \@whitelist_patterns,
    'blacklist_statuses:s@'       => \@blacklist_statuses,
    'blacklist_patterns:s@'       => \@blacklist_patterns,
    'script_debug:s@'             => \$script_debug,
    )) {
   help();
   exit STATUS_CONFIG_ERROR;
};

# Support script debugging as soon as possible.
Auxiliary::script_debug_init($script_debug);

if ( defined $help ) {
    help();
    exit STATUS_OK;
}

if ( defined $help_long ) {
    help_long();
    exit STATUS_OK;
}

if (not defined $log_file) {
    say("ERROR: \$log_file was not defined.");
    help();
    exit 99;
}

if (STATUS_OK != Verdict::check_normalize_set_black_white_lists (
       # RESULT: The RQG run ended with status STATUS_SERVER_CRASHED (101)
      'RESULT: The RQG run ended with status ',
      \@blacklist_statuses, \@blacklist_patterns,
      \@whitelist_statuses, \@whitelist_patterns)) {
    exit 99;
}

# If failure Verdict::black_white_lists_to_config_snip aborts with Carp::confess.
my $cfg_snip = Verdict::black_white_lists_to_config_snip('cfg');
my $cc_snip  = Verdict::black_white_lists_to_config_snip('cc');

my $verdict = Verdict::calculate_verdict($log_file);
if (not defined $verdict) {
    say("INTERNAL ERROR: The verdict returned was undef.");
    exit 99;
}
say("VERDICT: $verdict");

print("\nAssuming that you are satisfied with the matching result and verdict than the "           .
      "following applies\n\n"                                                                      .
      "Formatting style for config files used in new-simplify-grammar.pl (extension '.cfg')\n"     .
      "   '<pattern1>','<pattern2>',\nwhich is in case of the current setting\n\n"                 .
      "$cfg_snip\n\n"                                                                              .
      "Formatting style for config files used in rqg_batch.pl (extension '.cc')\n"                 .
      "   \"\\'<pattern1>\\',\\'<pattern2>\\'\"\nwhich is in case of the current setting\n\n"      .
      "$cc_snip\n"
      );

sub help {
print <<EOF

checker.pl is a tool for

1. Running iterations of
       ... experiment with <value>
       perl checker.pl --log_file=<log_file> --<bw_list_parameter>=<value>
       ... inspect the output of checker.pl
   till the matching results and the verdict reported is satisfying.
   The corresponding settings for config files (extensions '.cc' and '.cfg') will be printed.
   <log_file> must exist and be the log file of some RQG run.

   Example:

   perl checker.pl --log_file=112.log --blacklist_patterns="'mysqld. .{1,70}row0log.cc.{1,10} void row_log_table_delete.{1,100}. Assertion .new_index..n_uniq .. index..n_uniq. failed.'"


SORRY, 2. IS NOT YET IMPLEMENTED.
2. Checking if the combination of some RQG log and a config file leads to satisfying results
   regarding matching and verdict.

   perl checker.pl --log_file=<log_file> --config=<config file>


3. Print some short (the current) help

   perl checker.pl --help

4. Description how to derive the right whitelist_patterns/blacklist_patterns setting

   perl checker.pl --help_long


EOF
;
Verdict::help();
}

sub help_long {

help();

print <<EOF


How to derive the right whitelist_patterns/blacklist_patterns setting from some existing RQG log
------------------------------------------------------------------------------------------------

Snip from RQG log
# 2018-08-22T15:52:02 [16461] | mysqld: /work_m/10.2/storage/innobase/row/row0log.cc:631: void row_log_table_delete(const rec_t*, dict_index_t*, const ulint*, const byte*): Assertion `new_index->n_uniq == index->n_uniq' failed.

FIXME: Describe some better workflow
Description for everybody who is not interested to spend serious time on learning Perl pattern matching now.
1. Start with
      perl checker.pl --log_file=112.log --whitelist_patterns="'<snip from RQG log>'"
   which would be the following command line
      perl checker.pl --log_file=112.log --whitelist_patterns="'# 2018-08-22T15:52:02 [16461] | mysqld: /work_m/10.2/storage/innobase/row/row0log.cc:631: void row_log_table_delete(const rec_t*, dict_index_t*, const ulint*, const byte*): Assertion `new_index->n_uniq == index->n_uniq' failed.'"
   In order to get this command into bash history (hopefully configured with do not ignore failing commands) you need to replace any '!' with '.' or prepend a '\\' to it.
   Nevertheless its likely that it will
      a) not work now -- Trouble already in command line
      b) not work days later after the next push or on boxes with different directory structure
         even if a) is already fixed.
2. Be generous in removing content as long as what remains is highly selective.
   Remove the '# 2018-08-22T15:52:02 [16461] | ' which is specific to the historic RQG run.
      "'mysqld: /work_m/10.2/storage/innobase/row/row0log.cc:631: void row_log_table_delete(const rec_t*, dict_index_t*, const ulint*, const byte*): Assertion `new_index->n_uniq == index->n_uniq' failed.'"
   Replace the '/work_m/10.2/storage/innobase/row/' by '.{1,70}'.
      The top directory of source tree is testing box specific.
      There is inside it the to be handled '/' too.
      "'mysqld: .{1,70}row0log.cc:631: void row_log_table_delete(const rec_t*, dict_index_t*, const ulint*, const byte*): Assertion `new_index->n_uniq == index->n_uniq' failed.'"
   Replace line numbers because they differ between releases like 10.2 and 10.3 or even after the next push.
      "'mysqld: .{1,70}row0log.cc.{1,10} void row_log_table_delete(const rec_t*, dict_index_t*, const ulint*, const byte*): Assertion `new_index->n_uniq == index->n_uniq' failed.'"
   Replace much stuff containing maybe critical chars like '*', '(' etc. like
      "'mysqld: .{1,70}row0log.cc.{1,10} void row_log_table_delete.{1,100}: Assertion `new_index->n_uniq == index->n_uniq' failed.'"
   or
   simply replace any char where you fear that it might have some special meaning in perl pattern matching (== all non alpha numric) by '.'.
      "'mysqld. .{1,70}row0log.cc.{1,10} void row_log_table_delete.{1,100}. Assertion .new_index..n_uniq .. index..n_uniq. failed.'"

perl checker.pl --log_file=112.log --whitelist_patterns="'mysqld. .{1,70}row0log.cc.{1,10} void row_log_table_delete.{1,100}. Assertion .new_index..n_uniq .. index..n_uniq. failed.'"
...
... MATCHING: Blacklist statuses, element 'RESULT: The RQG run ended with status STATUS_OK' : no match
... MATCHING: Blacklist text patterns : No elements defined.
... INFO: Pattern is 'STATUS_ANY_ERROR' which means any status != 'STATUS_OK' matches.
... MATCHING: Whitelist statuses, element 'RESULT: The RQG run ended with status ' followed by a status != STATUS_OK' : match <======= SUCCESS, pattern is right
... MATCHING: Whitelist text patterns element 'mysqld. .{1,70}row0log.cc.{1,10} void row_log_table_delete.{1,100}. Assertion .new_index..n_uniq .. index..n_uniq. failed.' : match <======= SUCCESS, pattern is MAYBE right
... VERDICT: replay     <======= DESIRED REACTION

In case you want to put the RQG log snip to the blacklist_patterns because its some problem
already reported, not of interest now etc. than use
perl checker.pl --log_file=112.log --blacklist_patterns="'mysqld. .{1,70}row0log.cc.{1,10} void row_log_table_delete.{1,100}. Assertion .new_index..n_uniq .. index..n_uniq. failed.'"
...
... MATCHING: Blacklist statuses, element 'RESULT: The RQG run ended with status STATUS_OK' : no match
... MATCHING: Blacklist text patterns element 'mysqld. .{1,70}row0log.cc.{1,10} void row_log_table_delete.{1,100}. Assertion .new_index..n_uniq .. index..n_uniq. failed.' : match <======= SUCCESS, pattern is MAYBE right
... INFO: Pattern is 'STATUS_ANY_ERROR' which means any status != 'STATUS_OK' matches.
... MATCHING: Whitelist statuses, element 'RESULT: The RQG run ended with status ' followed by a status != STATUS_OK' : match <======= SUCCESS, pattern is right
... MATCHING: Whitelist text patterns : No elements defined.
... VERDICT: ignore     <======= DESIRED REACTION

The text above contains 'SUCCESS, pattern is MAYBE right'.
Well, there is the risk that your pattern contains some non escaped character like '|' which causes that most probably any text matches.
In order to prevent that just try something like
    perl checker.pl --log_file="\$HOME/.profile" ....
till you get no more a match.

By the way you can match a group of RQG protocol lines like
  "'assert.{0,150}safe_cond_timedwait.{0,150}thr_mutex\.c.{0,50}Item_func_sleep::val_int.{0,3000}SELECT 1,SLEEP\(10\)'"

EOF
;
}

1;
