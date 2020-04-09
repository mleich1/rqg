#  Copyright (c) 2018, 2019 MariaDB Corporation Ab.
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; version 2 of the License.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301  USA */
#

package Verdict;

use strict;
use Auxiliary;
use GenTest::Constants;
use GenTest;
use File::Copy;
use Cwd;

# use constant STATUS_OK           => 0;
use constant STATUS_FAILURE        => 1; # Just the opposite of STATUS_OK

use constant SEARCH_PATTERN        => 1;
use constant EXTRA_INFO            => 0;

use constant VERDICT_CONFIG_FILE   => 'Verdict.cfg';

# *_verdict_infrastructure
#
# Purpose
# -------
# Make and check the existence of the standardized infrastructure (set of files) within
# the RQG workdir.
# Some RQG runner might call this in order to get or check some premade play ground(RQG workdir)
# filled with standard files.
# Also some RQG tool managing several RQG runs might call this in order to prepare the
# play ground for RQG runners to be started.
# Attention:
# This is should be only done in case we perform RQG runs.
# In case of determining the verdict on the protocol of some RQG run this would be
# just overhead.
#
# Return values
# -------------
# STATUS_OK      -- Success
# STATUS_FAILURE -- No success
#
sub make_verdict_infrastructure {
    my ($workdir) = @_;
    # It is expected that the caller has already checked if $workdir is correct.
    my $my_file = $workdir . '/rqg_verdict.init';
    my $result  = Auxiliary::make_file ($my_file, undef);
    return $result;
}
#
sub check_verdict_infrastructure {
    my ($workdir) = @_;
    # It is expected that the caller has already checked if $workdir is correct.
    my $my_file = $workdir . '/rqg_verdict.init';
    if (not -e $my_file) {
        say("ERROR: RQG file '$my_file' is missing.");
        return STATUS_FAILURE;
    }
    return STATUS_OK;
}


####################################################################################################
# Black and white list matching with statuses and text patterns
#
# Typical use cases
# -----------------
# 1. Figure out if the remainings of some RQG run are worth to be preserved.
#    This operations itself is fast and does not need that much resources temporary.
#    If not than we save
#    - temporary resources by not running the archiving (small win)
#    - permanent resources by not using storage space for an archive (usually small win)
#    - immediate resources in vardir by destroying the remainings of the test (small up till
#      serious win if dangerous storage space shortages ahead).
# 2. Let the RQG runner do this and make by that any RQG tool managing several RQG runs more robust
#    and responsive. The RQG runner will be busy and maybe die in case of errors.
# 3. Perform a batch of RQG runs managed by some RQG tool having a goal like
#    - simplify a grammar for some effect we are searching for
#    - hunt bugs but not bad effects we already know
#
# Complete RQG logs contain two 'marker' lines which define the region in which pattern matching
# should be applied. This serves for avoiding of self matches like
#    There is a line telling that some black_list_pattern is set to 'abc'.
#    The pattern matching mechanism at test end detects this line and assumes a hit.
use constant MATCHING_START    => 'MATCHING: Region start =====================';
use constant MATCHING_END      => 'MATCHING: Region end   =====================';
#
# Constants defined in Auxiliary.pm with frequent use here too.
# The pattern list was empty.
# use constant MATCH_NO_LIST_EMPTY   => 'match_no_list_empty';
# The pattern list was not empty but the text is obvious incomplete.
# Therefore a decision is impossible.
# use constant MATCH_UNKNOWN         => 'match_unknown';
# The pattern list was not empty and one element matched.
# use constant MATCH_YES             => 'match_yes';
# The pattern list was not empty, none of the elements matched and nothing looks interesting at all.
# use constant MATCH_NO              => 'match_no';
# The pattern list was not empty, none of the elements matched but the outcome looks interesting.
# use constant MATCH_NO_BUT_INTEREST => 'match_no_but_interest';


my $status_prefix;
my @blacklist_statuses;
my @blacklist_patterns,
my @whitelist_statuses;
my @whitelist_patterns;
my $bw_lists_set = 0;

# sub report_setup {

sub get_verdict_config_file {
    my ($workdir, $config_file_copy) = @_;

    my $who_am_i = 'Verdict::get_verdict_config_file:';

    if (2 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: $who_am_i Two parameters " .
                    "(workdir, config_file_copy) are required.");
        safe_exit($status);
    }
    if (not defined $workdir) {
        my $status = STATUS_INTERNAL_ERROR;
        say("INTERNAL ERROR: $who_am_i workdir is not defined.");
        safe_exit($status);
    } else {
        if (not -d $workdir) {
            my $status = STATUS_INTERNAL_ERROR;
            say("INTERNAL ERROR: $who_am_i The workdir '$workdir' does not exist or " .
                "is not a directory.");
            safe_exit($status);
        }
    }
    if (not defined $config_file_copy) {
        my $status = STATUS_INTERNAL_ERROR;
        say("INTERNAL ERROR: $who_am_i config_file_copy is not defined.");
        safe_exit($status);
    } else {
        if (not -f $config_file_copy) {
            my $status = STATUS_INTERNAL_ERROR;
            say("INTERNAL ERROR: $who_am_i The config_file_copy '$config_file_copy' does not " .
                "exist or is not a plain file.");
            safe_exit($status);
        }
    }

    my $verdict_config_file;
    say("DEBUG: workdir is '$workdir'");
    if ($workdir eq Cwd::getcwd()) {
        # Verdict.pl called on command line
        $verdict_config_file = $workdir . "/Verdict_tmp.cfg";
        unlink $verdict_config_file;
    } else {
        $verdict_config_file = $workdir . "/" . VERDICT_CONFIG_FILE;
    }

    say("$verdict_config_file -- $config_file_copy");

    # FIXME maybe
    if ($config_file_copy =~ m{/Verdict\.cfg$}) {
        say("INFO: Setting verdict_config_file = config_file_copy '$config_file_copy'");
        $verdict_config_file = $config_file_copy;
    } else {
        if (-e $verdict_config_file) {
            # Do nothing
        } else {
            my $verdict_code = Auxiliary::getFileSection($config_file_copy, 'Verdict setup');
            if (not defined $verdict_code) {
                # say("DEBUG: verdict_code is undef");
                my $status = STATUS_ENVIRONMENT_FAILURE;
                say("ERROR: $who_am_i Extracting \$verdict_code out of '$config_file_copy' failed. " .
                    Auxiliary::exit_status_text($status));
                safe_exit($status);
            } elsif ('' eq $verdict_code) {
                # Extracting worked but no verdict definition found.
                # say("DEBUG: '$config_file_copy' does not contain verdict_code.");
                my $default_verdict_config_file = 'verdict_for_combinations.cfg';
                say("INFO: Extracting verdict config out of '$config_file_copy' impossible.");
                if (not File::Copy::copy($default_verdict_config_file, $verdict_config_file)) {
                    my $status = STATUS_ENVIRONMENT_FAILURE;
                    say("ERROR: Copying '$default_verdict_config_file' to '$verdict_config_file' failed : $!. " .
                        Auxiliary::exit_status_text($status));
                    safe_exit($status);
                }
                say("INFO: Created verdict_config_file '$verdict_config_file' as copy of the " .
                    "default '$default_verdict_config_file'.");
            } else {
                if (Auxiliary::make_file($verdict_config_file, $verdict_code) != STATUS_OK) {
                    my $status = STATUS_ENVIRONMENT_FAILURE;
                    say("ERROR: $who_am_i Creating the verdict config file '$verdict_config_file' failed. " .
                        Auxiliary::exit_status_text($status));
                    safe_exit($status);
                } else {
                    say("DEBUG: Created the verdict config file '$verdict_config_file' by extracting data out of '$config_file_copy'.");
                }
            }
        }
    }
    return $verdict_config_file;

} # End of sub get_verdict_config_file


sub load_verdict_config_file {
# Input: Verdict config file (neither a Combinator cc nor a Simplifier cfg file!)
# Return:
# undef -- error around or in config file
# printable description
    my ($verdict_config_file) = @_;

    my $who_am_i = 'Verdict::load_verdict_config_file:';

    if (1 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: $who_am_i One parameter " .
                    "(verdict_config_file) is required.");
        safe_exit($status);
    }
    if (not defined $verdict_config_file) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: $who_am_i verdict_config_file is not defined.");
        safe_exit($status);
    } else {
        if (not -f $verdict_config_file) {
            my $status = STATUS_INTERNAL_ERROR;
            say("INTERNAL ERROR: $who_am_i The verdict config file '$verdict_config_file' " .
                "does not exist or is not a plain file.");
            safe_exit($status);
        }
    }

    my $options = {};
    $options->{'config'} = $verdict_config_file;
    # FIXME: Check what happens in case of error. Show help_verdict?
    my $config = GenTest::Properties->new(
        options     => $options,
        legal       => [
        ],
        required    => [
                    'search_var_size',
                    'whitelist_statuses',
                    'whitelist_patterns',
                    'blacklist_statuses',
                    'blacklist_patterns',
        ],
        defaults    => {
        }
    );
    say("DEBUG: $who_am_i Verdict config file '$verdict_config_file' loaded.")
            if Auxiliary::script_debug("V2");

    my $failure_met = 0;
    my $num;

    my $verdict_setup   = '';
    my $value_separator = "' -- '";

    @blacklist_statuses = @{$config->blacklist_statuses};
    if (0 == scalar @blacklist_statuses) {
        say("ERROR: $who_am_i 0 blacklist_statuses defined. Will return undef later.");
        $failure_met = 1;
    }
    foreach my $status ( @blacklist_statuses ) {
        if (not $status =~ m{^STATUS_}) {
            say("ERROR: $who_am_i The element '$status' within blacklist_statuses does not " .
                "begin with 'STATUS_'. Will return undef later.");
            $failure_met = 1;
        }
        # FIXME: How to check if the STATUS constant is defined?
    }

    $verdict_setup .= "blacklist_statuses:       '" .
                      join($value_separator, @blacklist_statuses) . "'\n";

    @blacklist_patterns = @{$config->blacklist_patterns};
    $num = 0;
    foreach my $blacklist_pattern (@blacklist_patterns) {
        $num++;
        my @blacklist_pattern = @{$blacklist_pattern};
        if (not defined $blacklist_pattern[SEARCH_PATTERN]) {
            say("ERROR in blacklist_pattern pair $num: '" .
                join($value_separator, @blacklist_pattern) . "'");
            say("ERROR: $who_am_i Undef search_pattern between blacklist_patterns found. " .
                "Will return undef later.");
            $failure_met = 1;
        }
        if (not defined $blacklist_pattern[EXTRA_INFO]) {
            say("ERROR in blacklist_pattern pair $num: '" .
                join($value_separator, @blacklist_pattern) . "'");
            say("ERROR: $who_am_i Undef extra_info between blacklist_patterns found. " .
                "Will return undef later.");
            $failure_met = 1;
        }
        if ($blacklist_pattern[EXTRA_INFO] =~ m{\s}) {
            say("ERROR in blacklist_pattern pair $num: '" .
                join($value_separator, @blacklist_pattern) . "'");
            say("ERROR: $who_am_i extra_info must not contain white spaces. " .
                "Will return undef later.");
            $failure_met = 1;
        }
        $verdict_setup .= "blacklist_pattern pair $num: '" .
                          join($value_separator, @blacklist_pattern) . "'\n";
        if (0) {
            say("DEBUG: blacklist_pattern pair $num SEARCH_PATTERN: " .
                $blacklist_pattern[SEARCH_PATTERN]);
            say("DEBUG: blacklist_pattern pair $num EXTRA_INFO:     " .
                $blacklist_pattern[EXTRA_INFO]);
        }
    }
    if (0 == scalar @blacklist_patterns) {
        $verdict_setup .= "blacklist_pattern pairs:  none\n";
    }

    @whitelist_statuses = @{$config->whitelist_statuses};
    if (0 == scalar @whitelist_statuses) {
        say("ERROR: $who_am_i 0 whitelist_statuses defined. Will return undef later.");
        $failure_met = 1;
    }
    foreach my $status ( @whitelist_statuses ) {
        if (not $status =~ m{^STATUS_}) {
            say("ERROR: $who_am_i The element '$status' within whitelist_statuses does not " .
                "begin with 'STATUS_'. Will return undef later.");
            $failure_met = 1;
        }
        # FIXME: How to check if the STATUS constant is defined?
    }

    $verdict_setup .= "whitelist_statuses:       '" .
                      join($value_separator, @whitelist_statuses) . "'\n";

    @whitelist_patterns = @{$config->whitelist_patterns};
    $num = 0;
    foreach my $whitelist_pattern (@whitelist_patterns) {
        $num++;
        my @whitelist_pattern = @{$whitelist_pattern};
        if (not defined $whitelist_pattern[SEARCH_PATTERN]) {
            say("ERROR in whitelist_pattern pair $num: '" .
                join($value_separator, @whitelist_pattern) . "'");
            say("ERROR: $who_am_i Undef search_pattern between whitelist_patterns found. " .
                "Will return undef later.");
            $failure_met = 1;
        }
        if (not defined $whitelist_pattern[EXTRA_INFO]) {
            say("ERROR in whitelist_pattern pair $num: '" .
                join($value_separator, @whitelist_pattern) . "'");
            say("ERROR: $who_am_i Undef extra_info between whitelist_patterns found. " .
                "Will return undef later.");
            $failure_met = 1;
        }
        if ($whitelist_pattern[EXTRA_INFO] =~ m{\s}) {
            say("ERROR in whitelist_pattern pair $num: '" .
                join($value_separator, @whitelist_pattern) . "'");
            say("ERROR: $who_am_i extra_info must not contain white spaces. " .
                "Will return undef later.");
            $failure_met = 1;
        }
        $verdict_setup .= "whitelist_pattern pair $num: '" .
                          join($value_separator, @whitelist_pattern) . "'\n";
    }
    if (0 == scalar @whitelist_patterns) {
        $verdict_setup .= "whitelist_pattern pairs:  none\n";
    }

    if ($failure_met) {
        say("INFO: Verdict setup ---- begin");
        say("$verdict_setup");
        say("INFO: Verdict setup ---- end");
        return undef;
    } else {
        $bw_lists_set = 1;
        return $verdict_setup;
    }
}


# RQG_VERDICT_INIT
# Initial value == The RQG run not finished. So there is real verdict at all.
use constant RQG_VERDICT_INIT               => 'init';
#
# RQG_VERDICT_REPLAY
# The RQG run is finished and analyzed. White list match. No black list match.
# We got what we were searching for.
use constant RQG_VERDICT_REPLAY             => 'replay';
#
# RQG_VERDICT_INTEREST
# The RQG run is finished and analyzed. No white list match. No black list match.
# We did not got what we were searching for but its some interesting 'bad' result.
use constant RQG_VERDICT_INTEREST           => 'interest';
#
# RQG_VERDICT_IGNORE*
# The RQG run is finished and analyzed. Black list match or STATUS_OK got etc.
# Its absolute not what we were searching for. There will be no archiving.
#
# RQG run harvesting STATUS_OK
use constant RQG_VERDICT_IGNORE_STATUS_OK   => 'ignore_status_ok';
# RQG run harvesting a blacklist match
use constant RQG_VERDICT_IGNORE_BLACKLIST   => 'ignore_blacklist';
# RQG run was stopped by rqg_batch.pl because of
# - technical reasons like trouble with resources ahead
# - Combinator/Simplifier 'asking' for stopping of ongoing RQG runs including the
#   current one.
use constant RQG_VERDICT_IGNORE_STOPPED     => 'ignore_stopped';
# RQG run with somehow unclear outcome. This constant might disappear in future.
use constant RQG_VERDICT_IGNORE             => 'ignore';
#
# Warning:
# Giving the RQG_VERDICT_* a shape optimized for printing result tables like
# 'init    ' will cause trouble because we construct file names from that value.
#
#
use constant RQG_VERDICT_ALLOWED_VALUE_LIST => [
        RQG_VERDICT_INIT, RQG_VERDICT_REPLAY, RQG_VERDICT_INTEREST,
        RQG_VERDICT_IGNORE_STATUS_OK, RQG_VERDICT_IGNORE_BLACKLIST,
        RQG_VERDICT_IGNORE_STOPPED, RQG_VERDICT_IGNORE ,
    ];
#
# Maximum length of a RQG_VERDICT_* constant above.
use constant RQG_VERDICT_LENGTH             => 16;
# Column title maybe used in printing tables with results.
use constant RQG_VERDICT_TITLE              => 'Verdict         ';


sub calculate_verdict {
#
# Return values
# -------------
# If success in calculation
#     verdict , (status + extra_info taken from relevant pattern)
# If failure in calculation.
#     undef, indef
#

    my ($file_to_search_in) = @_;

    if (not $bw_lists_set) {
        Carp::cluck("INTERNAL ERROR: calculate_verdict was called before " .
                    "the call of check_normalize_set_black_white_lists.");
        return undef;
    }

    say("DEBUG: file_to_search_in '$file_to_search_in'") if Auxiliary::script_debug("V3");

    # RQG logs could be huge and even the memory on testing boxes is limited.
    # So we push in maximum the last 100000000 bytes of the log into $content.
    my $content = Auxiliary::getFileSlice($file_to_search_in, 100000000);
    if (not defined $content or '' eq $content) {
        say("FATAL ERROR: calculate_verdict: No RQG log content got. Will return undef.");
        return undef, undef;
    } else {
        say("DEBUG: Auxiliary::getFileSlice got content : ->$content<-")
            if Auxiliary::script_debug("V4");
    }

    my $cut_position;
    $cut_position = index($content, MATCHING_START);
    if ($cut_position >= 0) {
        $content = substr($content, $cut_position);
        say("DEBUG: cut_position : $cut_position") if Auxiliary::script_debug("V3");
    }

    $cut_position = index($content, MATCHING_END);
    if ($cut_position >= 0) {
        $content = substr($content, 0, $cut_position);
        say("DEBUG: cut_position : $cut_position") if Auxiliary::script_debug("V3");
    }

    if (not defined $content or $content eq '') {
        say("INFO: No RQG log content left over after cutting. Will return undef.");
        return undef, undef;
    }

    #############################################
#   my $status_prefix;
#   my @blacklist_statuses;
#   my @blacklist_patterns;
#   my @whitelist_statuses;
#   my @whitelist_patterns;

    my $p_match;
    my $p_info;
    my $f_info         = 'undef_initial';
    my $z_info         = 'undef_initial';
    my $maybe_match    = 1;
    my $maybe_interest = 1;
    my $bl_match       = 0;
    my $ok_match       = 0;
    my $was_stopped    = 0;

    my $script_debug   = 1;

    my $status_prefix = ' The RQG run ended with status ';

    my @list;
    $list[0] = 'BATCH: Stop the run';
    ($p_match, $p_info) = Auxiliary::content_matching($content, \@list,
                                           'MATCHING: Stop the run', 1);
    if ($p_match eq Auxiliary::MATCH_YES) {
        $maybe_match    = 0;
        $maybe_interest = 0;
        $was_stopped    = 1;
        return RQG_VERDICT_IGNORE_STOPPED , 'stopped';
    }

    $list[0] = 'STATUS_OK';
    ($p_match, $p_info) = Auxiliary::status_matching($content, \@list, $status_prefix,
                                           'MATCHING: STATUS_OK', 1);
    if ($p_match eq Auxiliary::MATCH_YES) {
        $ok_match = 1;
    }
    $f_info = $p_info; # Get the exit status into it

    ($p_match, $p_info) = Auxiliary::status_matching($content, \@blacklist_statuses   ,
                                          $status_prefix, 'MATCHING: Blacklist statuses', 1);
    say("INFO: Blacklist status matching returned : $p_match");
    # Note: Hitting Auxiliary::MATCH_UNKNOWN would be not nice.
    #       But its acceptable compared to Auxiliary::MATCH_YES.
    if ($p_match eq Auxiliary::MATCH_YES) {
        $maybe_match    = 0;
        $maybe_interest = 0;
        $bl_match       = 1;
    }
    say("DEBUG: maybe_interest : $maybe_interest, maybe_match : $maybe_match, " .
        "p_match : $p_match, f_info: $f_info")
        if Auxiliary::script_debug("V2");

    ($p_match, $p_info) = Auxiliary::content_matching2 ($content, \@blacklist_patterns ,
                                           'MATCHING: Blacklist text patterns', 1);
    $p_info = '<undef2>' if not defined $p_info;
    say("INFO: Blacklist pattern matching returned : $p_match - $p_info");
    if ($p_match eq Auxiliary::MATCH_YES) {
        $maybe_match    = 0;
        $maybe_interest = 0;
        $bl_match       = 1;
        $f_info         = $f_info . '--' . $p_info;
    }
    say("DEBUG: maybe_interest : $maybe_interest, maybe_match : $maybe_match, " .
        "p_match : $p_match, f_info: $f_info")
        if Auxiliary::script_debug("V2");

    # At this point we could omit checking in case $maybe_match = 0.
    # But there might be some interest to know if the whitelist stuff was hit too.
    # So we run it here in any case too.
    ($p_match, $p_info) = Auxiliary::status_matching($content, \@whitelist_statuses   ,
                                          $status_prefix, 'MATCHING: Whitelist statuses', 1);
    say("INFO: Whitelist status matching returned : $p_match , $p_info");
    if (0 == $bl_match) {
        # Note: Hitting Auxiliary::MATCH_UNKNOWN is not acceptable because it would
        #       degenerate runs of the grammar simplifier.
        if ($p_match ne Auxiliary::MATCH_YES) {
            $maybe_match = 0;
        }
    }
    say("DEBUG: maybe_interest : $maybe_interest, maybe_match : $maybe_match, " .
        "p_match : $p_match, f_info: $f_info")
        if Auxiliary::script_debug("V2");

    ($p_match, $p_info) = Auxiliary::content_matching2 ($content, \@whitelist_patterns ,
                                            'MATCHING: Whitelist text patterns', 1);
    $p_info = '<undef4>' if not defined $p_info;
    say("INFO: Whitelist pattern matching returned : $p_match - $p_info");
    if (0 == $bl_match) {
        if (1 == $maybe_match) {
            # We had a status match and now some pattern too. So refine $f_info.
            if ($p_match eq Auxiliary::MATCH_YES) {
                $f_info      = $f_info . '--' . $p_info;
            } elsif ($p_match eq Auxiliary::MATCH_NO_LIST_EMPTY) {
                # Do nothing
            } else {
                $maybe_match = 0;
            }
        }
    }
    say("DEBUG: maybe_interest : $maybe_interest, maybe_match : $maybe_match, " .
        "p_match : $p_match, f_info: $f_info")
        if Auxiliary::script_debug("V2");
    my $verdict = RQG_VERDICT_INIT;
    if ($maybe_match) {
        $verdict = RQG_VERDICT_REPLAY;
    } elsif ($maybe_interest) {
        $verdict = RQG_VERDICT_INTEREST;
    } elsif ($bl_match) {
        $verdict = RQG_VERDICT_IGNORE_BLACKLIST;
    } elsif ($ok_match) {
        $verdict = RQG_VERDICT_IGNORE_STATUS_OK;
    } elsif ($was_stopped) {
        $verdict = RQG_VERDICT_IGNORE_STOPPED;
    } else {
        $verdict = RQG_VERDICT_IGNORE;
    }
    return $verdict, $f_info;

} # End of sub calculate_verdict


sub set_final_rqg_verdict {
#
# Purpose
# -------
# Signal via setting a file name the final verdict.
#
    my $who_am_i = "Verdict::set_final_rqg_verdict:";

    my ($workdir, $verdict, $extra_info) = @_;
    if (3 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: $who_am_i Three parameters (workdir, verdict, extra_info) " .
                      "are required.");
        return STATUS_FAILURE;
    }

    if (not -d $workdir) {
        say("ERROR: $who_am_i RQG workdir '$workdir' is missing or not a directory.");
        return STATUS_FAILURE;
    }
    if (not defined $verdict or $verdict eq '') {
        Carp::cluck("ERROR: $who_am_i verdict is either not defined or ''.");
        return STATUS_FAILURE;
    }
    my $extra_text = "EXTRA_INFO: ";
    if ((not defined $extra_info) or ('' eq $extra_info)) {
        Carp::cluck("ERROR: $who_am_i \$extra_info is not defined or ''.");
        $extra_text .= "<undef>";
    } else {
        $extra_text .= $extra_info;
    }

    my $result = Auxiliary::check_value_supported ('verdict', RQG_VERDICT_ALLOWED_VALUE_LIST,
                                                  $verdict);
    if ($result != STATUS_OK) {
        Carp::cluck("ERROR: $who_am_i Auxiliary::check_value_supported returned $result. " .
                    "Will return that too.");
        return $result;
    }
    my $initial_verdict = RQG_VERDICT_INIT;

    my $source_file = $workdir . '/rqg_verdict.' . $initial_verdict;
    my $target_file = $workdir . '/rqg_verdict.' . $verdict;

    # Auxiliary::rename_file is safe regarding existence of these files.
    $result = Auxiliary::rename_file ($source_file, $target_file);
    if ($result) {
        say("ERROR: set_rqg_verdict from '$initial_verdict' to '$verdict' failed.");
        return STATUS_FAILURE;
    } else {
        $result = Auxiliary::append_string_to_file($target_file, $extra_text . "\n");
        if ($result) {
            say("ERROR: set_rqg_verdict: Appending '$extra_text' to '$target_file' failed.");
            return STATUS_FAILURE;
        } else {
            say("DEBUG: set_rqg_verdict from '$initial_verdict' to '$verdict' and " .
                "extra_info '$extra_info'.") if Auxiliary::script_debug("V2");
            return STATUS_OK;
        }
    }
} # End sub set_final_rqg_verdict


sub get_rqg_verdict {
#
# Return values
# -------------
# undef - $workdir not existing, verdict file not found ==> RQG should abort later
# $verdict_value - all ok
    my ($workdir) = @_;
    if (not -d $workdir) {
        say("ERROR: get_rqg_verdict : RQG workdir '$workdir' " .
            " is missing or not a directory. Will return undef, '<undef>'.");
        system("ls -ld $workdir");
        return undef, '<undef>';
    }
    my $extra_info;
    foreach my $verdict_value (@{&RQG_VERDICT_ALLOWED_VALUE_LIST}) {
        my $file_to_try = $workdir . '/rqg_verdict.' . $verdict_value;
        if (-e $file_to_try) {
            if ($file_to_try ne $workdir . '/rqg_verdict.' . RQG_VERDICT_INIT) {
                $extra_info = Auxiliary::get_string_after_pattern($file_to_try, 'EXTRA_INFO: ');
                # say("DEBUG: verdict: $verdict_value, extra_info: $extra_info");
            }
            $extra_info = '<undef>' if not defined $extra_info;
            return $verdict_value, $extra_info;
        }
    }
    # In case we reach this point than we have no verdict file found.
    say("ERROR: get_rqg_verdict : No RQG verdict file in directory '$workdir' found. " .
        "Will return undef, '<undef>'.");
    return undef, '<undef>';
}


sub help {

print <<EOF

Help for Verdict and Blacklist/Whitelist setup
----------------------------------------------
In order to reach certain goals of RQG tools we need to have some mechanisms which
- allow to define how desired and unwanted results look like
      black and white lists of RQG statuses and text patterns in RQG run protocols
- inspect the results of some finished RQG run, give a verdict and inform the user.

Verdicts:
'ignore*'  -- STATUS_OK got or blacklist parameter match or stopped because of technical reason
'init'     -- RQG run died prematurely
'interest' -- No STATUS_OK got and no blacklist parameter match but also no whitelist
              parameter match
'replay'   -- whitelist parameter match and no blacklist parameter match
              == desired outcome
Some examples how RQG tools exploit that verdict (except disabled):
RQG runner (rqg.pl):
   Verdict 'replay', 'interest' : Archive remainings of that RQG run.
   Verdict 'ignore*', 'init' : No archiving
                      --> Nothing left over to check, save storage space
RQG batch runner (rqg_batch.pl):
   Let rqg.pl do the job and archive or clean up according to verdict.
   Make a summary about RQG runs and their verdicts in <workdir>/results.txt.
   Report the best (order is 'replay', 'interest', ignore') verdict got to the caller.
   If "stop_on_replay" was assigned and one RQG run achieved the verdict 'replay'
   stop immediate all ongoing RQG runs managed, give a summary and exit.

Any matching is performed against the content of the RQG protocol only.
The exit statuses of whatever OS processes performing RQG runs get ignored.

The status matching is focused on a line starting with
    'The RQG run ended with status'
printed by RQG runners like rqg.pl after the last thinkable testing action like
compare the content of servers is finished.
The status matching setup accepts strings starting with 'STATUS_' only.
The supported values are in lib/GenTest/Constants.pm.
The status matching will not check your input against this file.
STATUS_ANY matches any status != STATUS_OK.

The text pattern matching is restricted to a region starting with some
    'MATCHING: Region start ====================='
and ending with
    'MATCHING: Region end   ====================='
defined in lib/Verdict.pm and printed by RQG runners like rqg.pl.

You can assign more than one value to the matching parameters.
Comma has to be used as separator between different values.
As soon as one value matches it counts as 'match' for that parameter.
Also using single quotes around the values is highly recommended because
otherwise mechanisms might split at the wrong position.

EOF
;
}

1;

