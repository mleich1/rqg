#!/usr/bin/perl

# Copyright (c) 2018, MariaDB Corporation Ab.
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
# The concept and code here is only in some portions based on
#    util/simplify-grammar.pl
# There we have GNU General Public License version 2 too and
# Copyright (c) 2008, 2011 Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2013, Monty Program Ab.
# Copyright (c) 2018, MariaDB Corporation Ab.
#
# The amount of parameters (call line + config file) is in the moment
# not that stable.
# On the long run the script rql_batch.pl will be extended and replace
# the current script.
#

use strict;
use lib 'lib';
use lib '../lib';
use DBI;
use Carp;
use Getopt::Long;
use Data::Dumper;

use GenTest;
use GenTest::Constants;
use GenTest::Grammar;
use Auxiliary;
use Verdict;
use GenTest::Properties;
use GenTest::Simplifier::Grammar1; # We use the correct working simplifier only.
use Time::HiRes;

# Overview
# ========
# This script can be used to simplify grammar files to the smallest form
# which will still reproduce a desired outcome.
#
# More information
# ================
# https://github.com/RQG/RQG-Documentation/wiki/RandomQueryGeneratorSimplification
#
# Usage
# =====
# To adjust parameters to your use case and environment:
#
# (mleich) What follows is partially outdated. Sorry
# 1. Copy simplify-grammar_template.cfg to for example 1.cfg
# 2. Adjust the settings in 1.cfg
# 3. Execute: perl util/simplify-grammar.pl --config=1.cfg
#
# Technical information
# =====================
# The GenTest::Simplifier::Grammar1 module provides progressively simpler grammars.
# We define an "oracle" function which runs those grammars through RQG, and we
# report if RQG returns the desired status code (for example STATUS_SERVER_CRASHED)
#
# IOW, RQG grammar simplification with an "oracle" function based on:
# 1. RQG exit status codes (-> desired_status_codes)
# 2. expected RQG protocol output (-> expected_output)
# Hint: 2 will be not checked if 1 failed already

# get configuration

my $command_line= "$0 ".join(" ", @ARGV);

my $mtrbt = defined $ENV{MTR_BUILD_THREAD}?$ENV{MTR_BUILD_THREAD}:400;

my $options = {};

my ($help, $config_file,
   );

# Read the command line options.
if (not GetOptions(
    $options,
    'help'        => \$help,
    'config=s',
    'whitelist_statuses:s@',
    'whitelist_patterns:s@',
    'blacklist_statuses:s@',
    'blacklist_patterns:s@',
    'grammar=s',
    'parallel=i',
    'workdir=s',
    'vardir=s',
    )) {
    # Most probably not supported command line option provided.
    print("The command line was ->$command_line<-\n");
    help();
    exit STATUS_ENVIRONMENT_FAILURE;
};

if (defined $help) {
    help();
    exit 0;
}

$config_file = $options->{'config'};
if (not defined $config_file) {
    print("ERROR: Assigning a config_file is mandatory.\n");
    print("The command line was ->$command_line<-\n");
    help();
    exit STATUS_ENVIRONMENT_FAILURE;
} else {
   if (! -f $config_file) {
       print("ERROR: The assigned config_file does not exist or is not a plain file.\n");
       exit STATUS_ENVIRONMENT_FAILURE;
   }
}

# Read the options found in config_file.
my $config = GenTest::Properties->new(
    options => $options,
    legal => [
              'grammar',
              'mask',
              'mask-level',
              'grammar_flags',
              'parallel',
              'initial_seed',
              'search_var_size',
              'whitelist_statuses',
              'whitelist_patterns',
              'blacklist_statuses',
              'blacklist_patterns',
              'rqg_options',
              'vardir',
              'workdir'],
    required=>['rqg_options',
               'grammar',
               'workdir'],
    );

if (STATUS_OK != Verdict::check_normalize_set_black_white_lists (
                    ' The RQG run ended with status ', # $status_prefix,
                    $config->blacklist_statuses, $config->blacklist_patterns,
                    $config->whitelist_statuses, $config->whitelist_patterns)) {
    say("ERROR: Setting the values for blacklist and whitelist search failed.");
    # my $status = STATUS_CONFIG_ERROR;
    my $status = STATUS_ENVIRONMENT_FAILURE;
    say("$0 will exit with exit status " . status2text($status) . "($status)");
    safe_exit($status);
}

# Dump settings
say("SIMPLIFY RQG GRAMMAR BASED ON EXPECTED CONTENT WITHIN SOME FILE");
say("---------------------------------------------------------------");
$config->printProps;
my $bw_option_string = my $cc_snip  = Verdict::black_white_lists_to_config_snip('cc');
# say("DEBUG: $cc_snip ->$$cc_snip<-");
say("---------------------------------------------------------------");

my $symlink = "last_simp_workdir";
# The undef for the third parameter (runid) is intentional.
my ($workdir, $vardir) = Auxiliary::make_multi_runner_infrastructure (
    $config->workdir, $config->vardir, undef, $symlink);
# Note: In case of hitting an error make_multi_runner_infrastructure exits.
# Note: File::Copy::copy works only file to file. And so we might extract the name.
#       But using uniform file names isn't that bad.
File::Copy::copy($config_file, $workdir . "/simp.cfg");


## Calculate mysqld and rqg options

my $mysqlopt = $config->genOpt('--mysqld=--', $config->rqg_options->{mysqld});

## The one below is a hack.... Need support for nested options like these
delete $config->rqg_options->{mysqld};

my $rqgoptions = $config->genOpt('--', 'rqg_options');

my $parallel = $config->parallel;

# Determine some runtime parameter, check parameters, ....

my $run_id = time();

say("The ID of this run is $run_id.");

my $initial_grammar;

if (defined $config->property('mask') and $config->property('mask') > 0) {
    my $initial_grammar_obj = GenTest::Grammar1->new( 'grammar_file'  => $config->grammar );
    my $top_grammar = $initial_grammar_obj->topGrammar($config->property('mask-level'), "query", "query_init");
    my $masked_top = $top_grammar->mask($config->property('mask'));
    $initial_grammar = $initial_grammar_obj->patch($masked_top);
} else {
    open(INITIAL_GRAMMAR, $config->grammar) or croak "Unable to open initial_grammar_file '" . $config->grammar . "' : $!";
    read(INITIAL_GRAMMAR, $initial_grammar , -s $config->grammar);
    close(INITIAL_GRAMMAR);
}

my $iteration;

my $simplifier = GenTest::Simplifier::Grammar1->new(
    grammar_flags => $config->grammar_flags,
    oracle => sub {
        $iteration++;
        my $oracle_grammar = shift;

        my $current_grammar = $workdir . '/' . $iteration . '.yy';
        open (GRAMMAR, ">$current_grammar")
           or croak "unable to create $current_grammar : $!";
        print GRAMMAR $oracle_grammar;
        close (GRAMMAR);

        say("run_id = $run_id; iteration = $iteration");

        my $current_batch_log = $workdir . '/' . $iteration . '.log';

        my $start_time = Time::HiRes::time();


        my $batch_config_file = $workdir . "/" . $iteration . ".cc";
        open(BATCH_CONF, '>', $batch_config_file)
            or croak "ERROR: Unable to open config file '$batch_config_file' for writing: $!";
        print BATCH_CONF
            "# Config file was generated by util/new-simplify-grammar.pl\n"        .
            "\$combinations = [ [ '\n"                                             .
            "    $rqgoptions\n"                                                    .
            "    $mysqlopt\n"                                                      .
            "    --no-mask\n"                                                      .
            "    --seed=random\n"                                                  .
            "$cc_snip"                                                             .
            "' ] ];\n"                                                             ;
        close(BATCH_CONF);
        # sayFile($batch_config_file);
        my $batch_cmd = "perl rqg_batch.pl --config=$batch_config_file"            .
                        " --build_thread=$mtrbt --discard_logs"                    .
                        " --grammar=$current_grammar --seed=random"                .
                        " --workdir=$workdir --vardir=$vardir --stop_on_replay"    .
                        " --parallel=$parallel --trials=$parallel"                 .
                        " --runid=$iteration"                                      .
                        " >$current_batch_log 2>&1"                                ;

        say("INFO: Will call ->$batch_cmd<-");
        my $batch_status = system($batch_cmd);
        $batch_status    = $batch_status >> 8;
        if($batch_status != STATUS_OK) {
            say("ERROR: The run of rqg_batch.pl exited with exit status $batch_status.\n" .
                "       See the log file '$current_batch_log'. Abort");
            exit 99;
        }
        my $end_time =  Time::HiRes::time();
        my $duration =  $end_time - $start_time;
        my $content  =  Auxiliary::getFileSlice($current_batch_log, $config->search_var_size);
        # say("DEBUG: Log of the RQG batch iteration $iteration ->$content<-");
        my $search_pattern = "RESULT:     The best verdict reached was : '" .
                             Verdict::RQG_VERDICT_REPLAY . "'";
        if ($content =~ m{$search_pattern}s) {
            File::Copy::copy($current_grammar, $workdir . "/best_grammar.yy");
            say("INFO: Replay with grammar '$current_grammar'");
            return ORACLE_ISSUE_STILL_REPEATABLE;
        } else {
            return ORACLE_ISSUE_NO_LONGER_REPEATABLE;
        }
    }
);

my $simplified_grammar = $simplifier->simplify($initial_grammar);

print "Simplified grammar:\n\n$simplified_grammar\n\n" if defined $simplified_grammar;


sub help {
   print("\n Sorry, help content not yet implemented.\n");
}

1;
