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

# use constant STATUS_OK       => 0;
use constant STATUS_FAILURE    => 1; # Just the opposite of STATUS_OK

my $script_debug = 0;


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

sub check_normalize_set_black_white_lists {
#
# Purpose
# -------
# Check, normalize (make lists) and set the variables which might be later used for checking if
# certain content matches (black and white) list (statuses and patterns).
# Input variables:
# $status_prefix          -- Some text pattern defining what a line informing about an status needs
#                            to contain. This line is probably RQG runner specific.
#                            rqg.pl writes 'RESULT: The RQG run ended with status ...'
#                            The usual 'GenTest returned status ...' might be not sufficient
#                            because some advanced RQG runner might perform multiple YY grammar
#                            processing rounds.
# $blacklist_statuses_ref -- reference to the list (*) with blacklist statuses
# $blacklist_patterns_ref -- reference to the list (*) with blacklist text patterns
# $whitelist_statuses_ref -- reference to the list (*) with whitelist statuses
# $whitelist_patterns_ref -- reference to the list (*) with whitelist text patterns
#
#
# Return values:
# - STATUS_OK      success
# - STATUS_FAILURE no success
#

    my ($xstatus_prefix,
        $blacklist_statuses_ref, $blacklist_patterns_ref,
        $whitelist_statuses_ref, $whitelist_patterns_ref) = @_;

        # The $<black|white>list_<statuses|patterns> need to be references to the
        # corresponding lists.

    if (5 != scalar @_) {
        Carp::confess("INTERNAL ERROR: check_normalize_set_black_white_lists : " .
                      "five parameters are required.");
        # This accident could roughly only happen when coding RQG or its tools.
        # Already started servers need to be killed manually!
    }
    if (not defined $xstatus_prefix) {
        Carp::confess("INTERNAL ERROR: check_normalize_set_black_white_lists : ".
                      "The first parameter (status_prefix) is undef.");
    }
    $status_prefix = $xstatus_prefix;
    @whitelist_statuses = @{$whitelist_statuses_ref} if defined $whitelist_statuses_ref;
    @whitelist_patterns = @{$whitelist_patterns_ref} if defined $whitelist_patterns_ref;
    @blacklist_statuses = @{$blacklist_statuses_ref} if defined $blacklist_statuses_ref;
    @blacklist_patterns = @{$blacklist_patterns_ref} if defined $blacklist_patterns_ref;

    # Memorize if a failure met but return with STATUS_FAILURE only after the last list was checked.
    my $failure_met = 0;

    my $list_ref;
    Auxiliary::print_list("DEBUG: Initial RQG whitelist_statuses ",
                          @whitelist_statuses) if $script_debug;
    if (not defined $whitelist_statuses[0]) {
        $whitelist_statuses[0] = 'STATUS_ANY_ERROR';
        say("INFO: whitelist_statuses[0] was not defined. Setting whitelist_statuses[0] " .
            "to STATUS_ANY_ERROR (== default).");
    } elsif (defined $whitelist_statuses[1]) {
        # No treatment because we have more than just the first value.
        # So do nothing.
   } else {
        my $result = Auxiliary::surround_quote_check($whitelist_statuses[0]);
        say("Result of surround_quote_check for whitelist_statuses[0]") if $script_debug;
        if (     'bad quotes' eq $result) {
            $failure_met = 1;
        } elsif ('single quote protection' eq $result or
                 'double quote protection' eq $result or
                 'no quote protection' eq $result) {
            # The value is well formed and comes from a command line?
            $list_ref = Auxiliary::input_to_list(@whitelist_statuses);
            if(defined $list_ref) {
                @whitelist_statuses = @$list_ref;
            } else {
                say("ERROR: Auxiliary::input_to_list hit problems we cannot handle.");
                $failure_met = 1;
            }
        } else {
            say("INTERNAL ERROR: surround_quote_check returned '$result' which is not supported.");
            $failure_met = 1;
        }
    }
    foreach my $status ( @whitelist_statuses ) {
        if (not $status =~ m{^STATUS_}) {
            say("ERROR: The element '$status' within whitelist_statuses does not begin with " .
                "'STATUS_'.");
            $failure_met = 1;
        }
        # FIXME: How to check if the STATUS constant is defined?
    }
    Auxiliary::print_list("DEBUG: Final RQG whitelist_statuses ",
                          @whitelist_statuses) if $script_debug;

    Auxiliary::print_list("DEBUG: Initial RQG whitelist_patterns ",
                          @whitelist_patterns) if $script_debug;
    if (not defined $whitelist_patterns[0]) {
        $whitelist_patterns[0] = undef;
        say("INFO: whitelist_patterns[0] was not defined. Setting whitelist_patterns[0] " .
            "to undef (== default).");
    } elsif (defined $whitelist_patterns[1]) {
        # Optional splitting of first value is not supported if having more than one value.
        # So do nothing.
    } else {
        my $result = Auxiliary::surround_quote_check($whitelist_patterns[0]);
        if      ('no quote protection' eq $result) {
            # The value comes most probably from a config file.
            # So nothing to do.
        } elsif ('bad quotes' eq $result) {
            $failure_met = 1;
        } elsif ('single quote protection' eq $result or 'double quote protection' eq $result) {
            # The value is well formed and comes from a command line?
            $list_ref = Auxiliary::input_to_list(@whitelist_patterns);
            if(defined $list_ref) {
                @whitelist_patterns = @$list_ref;
            } else {
                say("ERROR: Auxiliary::input_to_list hit problems we cannot handle.");
                $failure_met = 1;
            }
        } else {
            say("INTERNAL ERROR: surround_quote_check returned '$result' which is not supported.");
        }
    }
    Auxiliary::print_list("DEBUG: Final RQG whitelist_patterns ",
                          @whitelist_patterns) if $script_debug;


    Auxiliary::print_list("DEBUG: Initial RQG blacklist_statuses ",
                          @blacklist_statuses) if $script_debug;
    if (not defined $blacklist_statuses[0]) {
        $blacklist_statuses[0] = 'STATUS_OK';
        say("INFO: blacklist_statuses[0] was not defined. Setting blacklist_statuses[0] " .
            "to STATUS_ANY_ERROR (== default).");
    } elsif (defined $blacklist_statuses[1]) {
        # No treatment because we have more than just the first value.
        # So do nothing.
    } else {
        my $result = Auxiliary::surround_quote_check($blacklist_statuses[0]);
        if      ('bad quotes' eq $result) {
            $failure_met = 1;
        } elsif ('single quote protection' eq $result or
                 'double quote protection' eq $result or
                 'no quote protection' eq $result) {
            # The value is well formed and comes from a command line?
            $list_ref = Auxiliary::input_to_list(@blacklist_statuses);
            if(defined $list_ref) {
                @blacklist_statuses = @$list_ref;
            } else {
                say("ERROR: Auxiliary::input_to_list hit problems we cannot handle.");
                $failure_met = 1;
            }
        } else {
            say("INTERNAL ERROR: surround_quote_check returned '$result' which is not supported.");
            $failure_met = 1;
        }
    }
    foreach my $status ( @blacklist_statuses ) {
        if (not $status =~ m{^STATUS_}) {
            say("ERROR: The element '$status' within blacklist_statuses does not begin with " .
                "'STATUS_'.");
            $failure_met = 1;
        }
        # FIXME: How to check if the STATUS constant is defined?
    }
    Auxiliary::print_list("DEBUG: Final RQG blacklist_statuses ",
                          @blacklist_statuses) if $script_debug;


    Auxiliary::print_list("DEBUG: Initial RQG blacklist_patterns ",
                          @blacklist_patterns) if $script_debug;
    if (not defined $blacklist_patterns[0]) {
        $blacklist_patterns[0] = undef;
        say("DEBUG: blacklist_patterns[0] was not defined. Setting blacklist_patterns[0] " .
            "to undef (== default).") if $script_debug;
    } elsif (defined $blacklist_patterns[1]) {
        say("DEBUG: \$blacklist_patterns[1] ->" . $blacklist_patterns[1] . "<-") if $script_debug;
        # Optional splitting of first value is not supported if having more than one value.
        # So do nothing.
    } else {
        say("DEBUG: \$blacklist_patterns[0] ->" . $blacklist_patterns[0] . "<-") if $script_debug;
        my $result = Auxiliary::surround_quote_check($blacklist_patterns[0]);
        say("Result of surround_quote_check : $result") if $script_debug;
        if      ('no quote protection' eq $result) {
            # The value comes most probably from a config file.
            # So nothing to do.
        } elsif ('bad quotes' eq $result) {
            $failure_met = 1;
        } elsif ('single quote protection' eq $result or 'double quote protection' eq $result) {
            # The value is well formed and comes from a command line?
            say("Sending blacklist_patterns to input_to_list.") if $script_debug;
            $list_ref = Auxiliary::input_to_list(@blacklist_patterns);
            if(defined $list_ref) {
                @blacklist_patterns = @$list_ref;
            } else {
                say("ERROR: Auxiliary::input_to_list hit problems we cannot handle.");
                $failure_met = 1;
            }
        } else {
            say("INTERNAL ERROR: surround_quote_check returned '$result' which is not supported.");
        }
    }
    Auxiliary::print_list("DEBUG: Final RQG blacklist_patterns ",
                          @blacklist_patterns) if $script_debug;

    if ($failure_met) {
        bw_lists_help();
        return STATUS_FAILURE;
    } else {
        $bw_lists_set = 1;
        return STATUS_OK;
    }
} # End of sub check_normalize_set_black_white_lists


sub black_white_lists_to_config_snip {
#
# Purpose
# -------
# After check_normalize_set_black_white_lists all lists are in arrays.
# But certain RQG tools to be started with 'system' need this stuff in command line with heavy
# single quoting because otherwise RQG could split strings wrong.
#
# Real life example
# -----------------
# We have exact one blacklist_patterns element and that is:
# ->Sentence is now longer than .{1,10} symbols. Possible endless loop in grammar. Aborting.<-
# Caused by having only that single element RQG fears that this might be a string in the style
#    <value1>,<value2>,value3>
# and wants to split at the comma.
# This would be plain wrong in the current case because than the perl code would become "ill" like
#   first element:  ->Sentence is now longer than .{1<-
#   second element: ->} symbols. Possible endless loop in grammar. Aborting<-
# So any value which could become the victim of some fatal split like these search patterns need
# to be surrounded by begin+end of value markers.
# These markers should be
# - not special characters inside perl
# - available on command line too -> easy typing on keyboard, trouble free on shell and WIN ...
# - not require to rewrite RQG code which interprets config files
# So I decided to use single quotes.
#   Accept and also generate command lines like
#   --blacklist_patterns="'Sentence is now longer than .{1,10} symbols.
# The next problem came when being faced
#   Certain tools have taken the values from command line or config file, filled them into
#   the arrays managed here but need to hand the over to other tools called.
#   In case that has to happen via generation of config file and than calling this tool
#   than some additional protection of the single quotes via '\' is required.
# I am searching for some better solution.
#

    my ($config_type) = @_;
    if (1 != scalar @_) {
        Carp::confess("INTERNAL ERROR: black_white_lists_to_config_snip : " .
                      "one parameter (config_type) is required.");
        # This accident could roughly only happen when coding RQG or its tools.
        # Already started servers need to be killed manually!
    }
    if (not defined $config_type) {
        Carp::confess("INTERNAL ERROR: black_white_lists_to_config_snip : ".
                      "The parameter (config_type) is undef.");
    }
    my $extra1; # Used for protecting single quotes if required.
    my $extra2; # Used for the extra '--' if required.
    my $extra3; # Used for the extra '=' or '    =>   [' if required.
    my $extra4; # Used for the extra '],' if required.
    my $extra5; # Used for the extra '],' if required.
                # A superfluous ',' makes no trouble.
    my $extra6; # Used for space at begin if readability required
    my $extra7; # "\n" after any parameter definition or other.
    if      ($config_type eq 'cc') {
        $extra6 = '    ';
        $extra5 = '';
        $extra1 = '\\';
        $extra2 = $extra6 . '--';
        $extra3 = '="';
        $extra4 = '"';
        $extra7 = "\n";
    } elsif ($config_type eq 'cfg') {
        $extra6 = '    ';
        $extra5 = "\n" . $extra6 . $extra6;
        $extra1 = '';
        $extra2 = $extra6 . '';
        $extra3 = '    =>   [' . $extra5;
        $extra4 = "\n" . $extra6 . '],';
        $extra7 = "\n";
    } elsif ($config_type eq 'cl') {
        # Prepare for use in for example     bash -c "$cl_snip"
        $extra6 = ' ';
        $extra5 = '';
        $extra1 = '';
        $extra2 = $extra6 . '--';
        $extra3 = '=\\"';
        $extra4 = '\\"';
        $extra7 = "";
    } else {
        Carp::confess("INTERNAL ERROR: black_white_lists_to_config_snip : ".
                      "config_type '$config_type' is unknown (neither 'cc' nor 'cfg')");
    }

    if (not $bw_lists_set) {
        Carp::confess("INTERNAL ERROR: black_white_lists_to_config_snip was called before " .
                      "the call of check_normalize_set_black_white_lists.");
    }

    sub give_value_list {
        my ($extra1, $extra5, @input)      = @_;
        my $has_elements = 0;
        my $result;
        foreach my $element (@input) {
            if (defined $element) {
                if ($has_elements) {
                    $result = $result . "," . $extra5 . "$extra1" . "'$element" . "$extra1" . "'";
                } else {
                    $result = "$extra1" . "'$element" . "$extra1" . "'";
                }
            } else {
                # Nothing initial assigned lands here.
            }
            $has_elements = 1;
        }
        if ($has_elements) {
            return $result;
        } else {
            return undef;
        }
    }
    my $content = '';
    my $result;
    my $config_snip = '';
    $result = give_value_list ($extra1, $extra5, @whitelist_statuses) ;
    if (defined $result) {
        $config_snip = $config_snip . $extra2 . 'whitelist_statuses' . $extra3 . $result .
                       $extra4 . $extra7;
    }
    $result = give_value_list ($extra1, $extra5, @whitelist_patterns) ;
    if (defined $result) {
        $config_snip = $config_snip . $extra2 . 'whitelist_patterns' . $extra3 . $result .
                       $extra4 . $extra7;
    }
    $result = give_value_list ($extra1, $extra5, @blacklist_statuses) ;
    if (defined $result) {
        $config_snip = $config_snip . $extra2 . 'blacklist_statuses' . $extra3 . $result .
                       $extra4 . $extra7;
    }
    $result = give_value_list ($extra1, $extra5, @blacklist_patterns) ;
    if (defined $result) {
        $config_snip = $config_snip . $extra2 . 'blacklist_patterns' . $extra3 . $result .
                       $extra4 . $extra7;
    }
    if (not defined $config_snip or '' eq $config_snip) {
        Carp::confess("INTERNAL ERROR: black_white_lists_to_config_snip : The final config_snip" .
                      "is either undef or ''.");
    }
    return $config_snip;
} # End of sub black_white_lists_to_config_snip


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
# verdict -- If success in calculation.
# undef   -- If failure in calculation.

    my ($file_to_search_in) = @_;

    if (not $bw_lists_set) {
        Carp::cluck("INTERNAL ERROR: calculate_verdict was called before " .
                    "the call of check_normalize_set_black_white_lists.");
        return undef;
    }

    say("DEBUG: file_to_search_in '$file_to_search_in'") if $script_debug;

    # RQG logs could be huge and even the memory on testing boxes is limited.
    # So we push in maximum the last 100000000 bytes of the log into $content.
    my $content = Auxiliary::getFileSlice($file_to_search_in, 100000000);
    if (not defined $content) {
        say("ERROR: calculate_verdict: No RQG log content got. Will return undef.");
        return undef;
    } else {
        say("DEBUG: Auxiliary::getFileSlice got content : ->$content<-") if $script_debug;
    }

    my $cut_position;
    $cut_position = index($content, MATCHING_START);
    if ($cut_position >= 0) {
        $content = substr($content, $cut_position);
        say("DEBUG: cut_position : $cut_position") if $script_debug;
    }

    $cut_position = index($content, MATCHING_END);
    if ($cut_position >= 0) {
        $content = substr($content, 0, $cut_position);
        say("DEBUG: cut_position : $cut_position") if $script_debug;
    }

    my $p_match;
    my $maybe_match    = 1;
    my $maybe_interest = 1;
    my $bw_match       = 0;
    my $ok_match       = 0;
    my $was_stopped    = 0;

    my $script_debug = 1;

    my @list;
    $list[0] = 'STATUS_OK';
    $p_match = Auxiliary::status_matching($content, \@list, $status_prefix,
                                           'MATCHING: STATUS_OK', $script_debug );
    if ($p_match eq Auxiliary::MATCH_YES) {
        $ok_match = 1;
    }

    $list[0] = 'BATCH: Stop the run';
    $p_match = Auxiliary::content_matching($content, \@list,
                                           'MATCHING: Stop the run', $script_debug );
    if ($p_match eq Auxiliary::MATCH_YES) {
        $maybe_interest = 0;
        $was_stopped = 1;
    }

    $p_match = Auxiliary::status_matching($content, \@blacklist_statuses   ,
                                          $status_prefix, 'MATCHING: Blacklist statuses', 1);
    say("DEBUG: Blacklist status matching returned : $p_match") if $script_debug;
    # Note: Hitting Auxiliary::MATCH_UNKNOWN would be not nice.
    #       But its acceptable compared to Auxiliary::MATCH_YES.
    if ($p_match eq Auxiliary::MATCH_YES) {
        $maybe_match    = 0;
        $maybe_interest = 0;
# FIXME: This is somehow not systematic of forbid STATUS_OK as Blacklist status.
#       $bw_match       = 1;
    }
    say("DEBUG: maybe_interest : $maybe_interest, maybe_match : $maybe_match") if $script_debug;

    $p_match = Auxiliary::content_matching ($content, \@blacklist_patterns ,
                                           'MATCHING: Blacklist text patterns', 1);
    say("DEBUG: Blacklist pattern matching returned : $p_match") if $script_debug;
    if ($p_match eq Auxiliary::MATCH_YES) {
        $maybe_match    = 0;
        $maybe_interest = 0;
        $bw_match       = 1;
    }
    say("DEBUG: maybe_interest : $maybe_interest, maybe_match : $maybe_match") if $script_debug;

    # At this point we could omit checking in case $maybe_match = 0.
    # But there might be some interest to know if the whitelist stuff was hit too.
    # So we run it here in any case too.
    $p_match = Auxiliary::status_matching($content, \@whitelist_statuses   ,
                                          $status_prefix, 'MATCHING: Whitelist statuses', 1);
    say("DEBUG: Whitelist status matching returned : $p_match") if $script_debug;
    # Note: Hitting Auxiliary::MATCH_UNKNOWN is not acceptable because it would
    #       degenerate runs of the grammar simplifier.
    if ($p_match ne Auxiliary::MATCH_YES) {
        $maybe_match    = 0;
    }
    say("DEBUG: maybe_interest : $maybe_interest, maybe_match : $maybe_match") if $script_debug;

    $p_match = Auxiliary::content_matching ($content, \@whitelist_patterns ,
                                            'MATCHING: Whitelist text patterns', 1);
    say("DEBUG: Whitelist pattern matching returned : $p_match") if $script_debug;
    if ($p_match ne Auxiliary::MATCH_YES and $p_match ne Auxiliary::MATCH_NO_LIST_EMPTY) {
        $maybe_match    = 0;
    }
    say("DEBUG: maybe_interest : $maybe_interest, maybe_match : $maybe_match") if $script_debug;
    my $verdict = RQG_VERDICT_INIT;
    if ($maybe_match) {
        $verdict = RQG_VERDICT_REPLAY;
    } elsif ($maybe_interest) {
        $verdict = RQG_VERDICT_INTEREST;
    } elsif ($bw_match) {
        $verdict = RQG_VERDICT_IGNORE_BLACKLIST;
    } elsif ($ok_match) {
        $verdict = RQG_VERDICT_IGNORE_STATUS_OK;
    } elsif ($was_stopped) {
        $verdict = RQG_VERDICT_IGNORE_STOPPED;
    } else {
        $verdict = RQG_VERDICT_IGNORE;
    }
    return $verdict;

} # End of sub calculate_verdict


sub set_final_rqg_verdict {
#
# Purpose
# -------
# Signal via setting a file name the final verdict.
#

    my ($workdir, $verdict) = @_;
    if (not -d $workdir) {
        say("ERROR: RQG workdir '$workdir' is missing or not a directory.");
        return STATUS_FAILURE;
    }
    if (not defined $verdict or $verdict eq '') {
        Carp::cluck("ERROR: Auxiliary::get_set_verdict verdict is either not defined or ''.");
        return STATUS_FAILURE;
    }
    my $result = Auxiliary::check_value_supported ('verdict', RQG_VERDICT_ALLOWED_VALUE_LIST,
                                                  $verdict);
    if ($result != STATUS_OK) {
        Carp::cluck("ERROR: Auxiliary::check_value_supported returned $result. " .
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
        say("DEBUG: set_rqg_verdict from '$initial_verdict' to " .
            "'$verdict'.") if $script_debug;
        return STATUS_OK;
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
            " is missing or not a directory. Will return undef.");
        return undef;
    }
    foreach my $verdict_value (@{&RQG_VERDICT_ALLOWED_VALUE_LIST}) {
        my $file_to_try = $workdir . '/rqg_verdict.' . $verdict_value;
        if (-e $file_to_try) {
            return $verdict_value;
        }
    }
    # In case we reach this point than we have no verdict file found.
    say("ERROR: get_rqg_verdict : No RQG verdict file in directory '$workdir' found. " .
        "Will return undef.");
    return undef;
}


sub help {

print <<EOF

Help for Verdict and Black list/White list setup
------------------------------------------------
In order to reach certain goals of RQG tools we need to have some mechanisms which
- allow to define how desired and unwanted results look like
      black and white lists of RQG statuses and text patterns in RQG run protocols
- inspect the results of some finished RQG run, give a verdict and inform the user.

Verdicts:
'ignore*'   -- STATUS_OK got or blacklist parameter match or stopped because of technical reason
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

Example for command line (shell will remove the surrounding '"'):
    --blacklist_statuses="'STATUS_OK','STATUS_ENVIRONMENT_FAILURE'" ...
Example for cc file (--> rqg_batch.pl)
    --blacklist_statuses=\"'STATUS_OK','STATUS_ENVIRONMENT_FAILURE'\"
Example for cfg file (--> new-simplify-grammar.pl)
   whitelist_statuses => [
       'STATUS_SERVER_CRASHED',
       'STATUS_DATABASE_CORRUPTION',
   ],

EOF
;
}

1;

