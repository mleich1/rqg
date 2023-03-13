#  Copyright (c) 2018, 2022 MariaDB Corporation Ab.
#  Copyright (c) 2023 MariaDB plc
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

package Auxiliary;

# TODO:
# - Structure everything better.
# - Add missing routines
# - Decide about the relationship to the content of
#   lib/GenTest_e.pm, lib/DBServer_e/DBServer.pm, maybe more.
#   There are various duplicate routines like sayFile, tmpdir, ....
# - search for string (pid or whatever) after pattern before line end in some file
# - move too MariaDB/MySQL specific properties/settings out
# It looks like Cwd::abs_path "cleans" ugly looking paths with superfluous
# slashes etc.. Check closer and use more often.
#

# use Runtime;


use strict;
use Basics;
use GenTest_e;
use GenTest_e::Constants;
use GenTest_e::Grammar;
use Local;
use File::Copy;

# The script debugging "system"
# -----------------------------
# We set the global "valid" variable $script_debug here via the routine 'script_debug_init'.
# Thinkable settings:
# - '_all_'
#   Write debug output no matter what the value assigned to the routine script_debug was.
# - '_<char1><digit2>_<char3><digit2>_'
#   Write debug output if <char1><digit2> or <char3><digit2> was requested.
# Hint:
# The character
# T -> Tool       (rqg_batch.pm or whatever else managing RQG runs gets "invented")
# B -> Batch      (lib/Batch.pm)
# C -> Combinator (lib/Combinator.pm)
# S -> Simplifier (lib/Simplifier.pm)
# L -> Resource Control (lib/ResourceControl.pm)
# R -> RQG runner (rqg.pl)
# The digit
# 1     -- more important and/or less frequent
# n > 1 -- less important and/or more frequent
# I admit that
# - this concept is rather experimental
# - the digits used in the modules rather arbitrary.
#
my $script_debug_init;
our $script_debug_value;
sub script_debug_init {
    ($script_debug_value) = @_;
    if (1 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: script_debug_init: One Parameter (script_debug) is required.");
        safe_exit($status);
    }
    if (not defined $script_debug_value) {
        $script_debug_value = '';
    }
    say("INFO: script_debug : '$script_debug_value'");
    $script_debug_init = 1;
    # In case I ever modify $script_debug_value here than the caller needs to
    # a) get the manipulated value back     or
    # b) access the manipulated value via $Auxiliary::script_debug_value
    # I prefer a).
    return $script_debug_value;
}


sub script_debug {
    my ($pattern) = @_;

    if (not defined $pattern) {
        Carp::cluck("INTERNAL ERROR: The parameter pattern is undef.");
        exit STATUS_INTERNAL_ERROR;
    }
    if (not defined $script_debug_init) {
        Carp::cluck("INTERNAL ERROR: script debug was not initialized.");
        exit STATUS_INTERNAL_ERROR;
    }
    $pattern = '_' . $pattern . '_';
    if (($script_debug_value =~ /$pattern/) or ($script_debug_value eq '_all_')) {
        return 1;
    } else {
        return 0;
    }
}

# The following sub is currently unused but its fate is not decided finally.
our $rqg_home;
sub check_and_set_rqg_home {
# Used by rqg.pl only.
    ($rqg_home) = @_;
    if (1 != scalar @_) {
        Carp::cluck("INTERNAL ERROR: Exact one parameter(rqg_home) needs to get assigned.");
        exit STATUS_INTERNAL_ERROR;
    } else {
        if (not defined $rqg_home) {
            Carp::cluck("INTERNAL ERROR: The value for rqg_home is undef.");
            exit STATUS_INTERNAL_ERROR;
        } else {
            if (not -d $rqg_home) {
                Carp::cluck("INTERNAL ERROR: rqg_home($rqg_home) does not exist or is not " .
                            "a directory.");
                exit STATUS_INTERNAL_ERROR;
            }
        }
    }
    # say("DEBUG: rqg_home set to ->$rqg_home<-");
}

sub check_value_supported {
#
# Purpose
# -------
# Check if some value is in some premade list of supported values.
#
# Return values
# -------------
# STATUS_OK           -- Value is supported
# STATUS_FAILURE      -- Value is not supported.
# STATUS_INTERNAL_ERROR -- Looks like error in RQG code
#
# Typical use case
# ----------------
# The RQG runner was called with --rpl_mode='row'.
# Check if the value 'row' is supported by RQG mechanics because it needs to set up
# MariaDB/MySQL replication between a master and a slave server and use binlog_format='row'.
#

   my ($parameter, $value_list_ref, $assigned_value) = @_;

# Some testing code.
# --> The parameter name is not defined or ''.
# my $return = Auxiliary::check_value_supported (undef, ['A'] , 'iltis');
# --> The supported values for 'otto' are 'A'.
# my $return = Auxiliary::check_value_supported ('otto', ['A'] , 'iltis');
# --> The value assigned to the parameter 'otto' is not defined.
# my $return = Auxiliary::check_value_supported ('otto', ['A','B'] , undef);

   if (not defined $parameter or $parameter eq '') {
      Carp::cluck("INTERNAL ERROR: The parameter name is not defined or ''.");
      return STATUS_INTERNAL_ERROR;
   }
   if (not defined $value_list_ref) {
      Carp::cluck("INTERNAL ERROR: The value_list is not defined.");
      return STATUS_INTERNAL_ERROR;
   }
   if (not defined $assigned_value or $assigned_value eq '') {
      Carp::cluck("ERROR: The value assigned to the parameter '$parameter' is not defined.");
      # ??? This might be also a error in the test config. -> User error
      return STATUS_INTERNAL_ERROR;
   }

   my (@value_list) = @$value_list_ref;

   my $message1 = "ERROR: Configuration parameter '$parameter' : The assigned value ->" .
                  $assigned_value . "<- is not supported.";
   my $message2 = "ERROR: The supported values for '$parameter' are ";
   my $no_match = 0;

   # Problem: Pick right comparison operator depending on if the value is numeric or string.
   # Forward and backward comparison helps.
   foreach my $supported_value (@value_list) {
      if (    $assigned_value  =~ m{$supported_value}s
          and $supported_value =~ m{$assigned_value}s  ) {
         return STATUS_OK; # 0
      } else {
         if ($no_match == 0) {
            $message2 = $message2 . "'"   . $supported_value . "'";
            $no_match++;
         } else {
            $message2 = $message2 . ", '" . $supported_value . "'";
         }
      }
   }
   $message2 = $message2 . '.';
   say($message1);
   say($message2);

   return STATUS_FAILURE; # The opposite of STATUS_OK;

} # End of sub check_value_supported

sub list_values_supported {
#
# Purpose
# -------
# Return a string with a list of supported values.
#
# Return values
# -------------
# string
# undef
#
# A typical use case is enriching help text
# my $string = Auxiliary::list_values_supported(Runtime::RR_TYPE_ALLOWED_VALUE_LIST);
#

    my ($value_list_ref) = @_;

    if (not defined $value_list_ref) {
       Carp::cluck("INTERNAL ERROR: The value_list is not defined.");
       return undef;
    }

    my (@value_list) = @$value_list_ref;
    return "'" . join("' or '", @value_list) . "'";

} # End of sub list_values_supported


sub make_rqg_infrastructure {
#
# Purpose
# -------
# Make some standardized infrastructure (set of files) within the RQG workdir.
# Some RQG runner might call this in order to get some premade play ground(RQG workdir)
# filled with standard files.
# Also some RQG tool managing several RQG runs might call this in order to prepare the
# play ground for RQG runners to be started.
#
# Return values
# -------------
# STATUS_OK      -- Success
# STATUS_FAILURE -- No success
#
    my ($workdir) = @_;
    my $who_am_i = Basics::who_am_i();
    if (1 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: $who_am_i " .
                    "Exact two parameters(workdir, batch) need to get assigned. " .
                    Auxiliary::exit_status_text($status));
        safe_exit($status);
    }

    if (not defined $workdir or $workdir eq '') {
        Carp::cluck("INTERNAL ERROR: \$workdir is undef or ''.");
        return STATUS_FAILURE;
    }
    # say("DEBUG: Auxiliary::make_rqg_infrastructure workdir is '$workdir'");
    $workdir = Cwd::abs_path($workdir);

    if(-d $workdir) {
        if(not File::Path::rmtree($workdir)) {
            say("ERROR: Removal of the already existing tree ->" . $workdir . "<- failed. : $!.");
            my $status = STATUS_ENVIRONMENT_FAILURE;
            run_end($status);
        }
        say("DEBUG: The already existing RQG workdir ->" . $workdir . "<- was removed.");
    }
    if (STATUS_OK != Basics::make_dir($workdir)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        run_end($status);
    }

    my $my_file;
    my $result;
    $my_file = $workdir . '/rqg.log';
    $result  = Basics::make_file ($my_file, undef);
    return $result if $result;
    $my_file = $workdir . '/rqg_phase.init';
    $result  = Basics::make_file ($my_file, undef);
    return $result if $result;
    $my_file = $workdir . '/rqg.job';
    $result  = Basics::make_file ($my_file, undef);
    return $result if $result;
    my $return = Verdict::make_verdict_infrastructure($workdir);
    if (STATUS_OK != $return) {
        return $return;
    }
    return STATUS_OK;
}


sub check_rqg_infrastructure {
#
# Purpose
# -------
# Check that the standardized infrastructure (set of files) within the RQG workdir exists.
# Some RQG runner might call this if expecting to meet some premade play ground(RQG workdir).
# Warning:
# Do not run this after the RQG runner has taken over because than the names of some of the
# premade files will have changed.
#
# Return values
# -------------
# STATUS_OK      -- Success
# STATUS_FAILURE -- No success
#
    # We check the early/premade infrastructure.
    # The names of the files will change later.
    my ($workdir) = @_;
    say("DEBUG: Auxiliary::check_rqg_infrastructure workdir is '$workdir'")
        if script_debug("A3");
    if (not -d $workdir) {
        say("ERROR: RQG workdir '$workdir' is missing or not a directory.");
        return STATUS_FAILURE;
    }
    my $my_file;
    my $result;
    $my_file = $workdir . '/rqg.log';
    if (not -e $my_file) {
        say("ERROR: RQG file '$my_file' is missing.");
        return STATUS_FAILURE;
    }
    $my_file = $workdir . '/rqg_phase.init';
    if (not -e $my_file) {
        say("ERROR: RQG file '$my_file' is missing.");
        return STATUS_FAILURE;
    }
    $my_file = $workdir . '/rqg.job';
    if (not -e $my_file) {
        say("ERROR: RQG file '$my_file' is missing.");
        return STATUS_FAILURE;
    }
    my $return = Verdict::check_verdict_infrastructure($workdir);
    if (STATUS_OK != $return) {
        return $return;
    }
    return STATUS_OK;
}


sub find_file_at_places {
    my($basedirectory, $subdir_list_ref, $name) = @_;

    foreach my $subdirectory (@$subdir_list_ref) {
        my $path  = $basedirectory . "/" . $subdirectory . "/" . $name;
        return $path if -f $path;
    }
    # In case we are here than we have nothing found.
    say("ERROR: We searched at various places below '$basedirectory' but '$name' was not found. " .
        "Will return undef.");
    return undef;
}


use constant RQG_PHASE_INIT               => 'init';
   # Set by RQG tool. If not present set by RQG runner.
use constant RQG_PHASE_START              => 'start';
   # Set by the RQG runner after having the RQG workdir and especially the RQG log available.
   # RQG tool point of view:
   # - The RQG runner has taken over. == The runner seems to do what it should do.
   # - Up till now nothing important or valuable done. == Roughly no loss if stopped.
   # - Ressouce use of the runner is negligible. == Roughly no win if stopped.
use constant RQG_PHASE_PREPARE            => 'prepare';
   # Set by RQG runner.
   # RQG tool point of view:
   # - Important: DB servers are most probably running.
   # - Up till now nothing important or valuable done. == Roughly no loss if stopped.
   # - Ressouce use of the runner is significant. == Significant win if stopped.
use constant RQG_PHASE_GENDATA            => 'gendata';
   # Set by RQG runner.
   # RQG tool point of view:
   # - Important: DB servers are most probably running.
   # - GenData is usually not that valuable. == Minor loss if stopped.
   # - Ressouce use of the runner is serious. == Serious win if stopped.
use constant RQG_PHASE_GENTEST            => 'gentest';
   # Set by RQG runner.
   # RQG tool point of view:
   # - Important: DB servers are most probably running.
   # - GenData done + GenTest ongoing == Bigger loss if stopped.
   # - Ressouce use of the runner is serious. == Serious win if stopped.
use constant RQG_PHASE_SERVER_CHECK       => 'server_check';
   # Set by RQG runner when running checks inside a DB server. (not yet implemented)
   # RQG tool point of view:
   # - Important: DB servers are most probably running.
   # - GenData + GenTest done == Serious loss if stopped.
   # - Ressouce use of the runner is serious. == Serious win if stopped.
use constant RQG_PHASE_SERVER_COMPARE     => 'server_compare';
   # Set by RQG runner when comparing the content of DB servers.
   # RQG tool point of view:
   # - Important: DB servers are most probably running.
   # - GenData + GenTest + ... done == Serious loss if stopped.
   # - Ressouce use of the runner is serious. == Serious win if stopped.
use constant RQG_PHASE_FINISHED           => 'finished';
   # Set by RQG runner when his core work is over.
   # RQG tool point of view:
   # - DB servers are no more running.
   # - GenData + GenTest + ... done == Serious loss if stopped.
   # - Ressouce use of the runner is serious. == Medium win if stopped.
use constant RQG_PHASE_ANALYZE            => 'analyze';
   # Set by RQG tool or extended RQG runner when running replay/unwanted list matching.
   # RQG tool point of view:
   # - DB servers are no more running.
   # - GenData + GenTest + ... done == Serious loss if stopped.
   # - Ressouce use of the runner is medium till small. == Medium win if stopped.
use constant RQG_PHASE_ARCHIVING          => 'archiving';
   # Set by RQG tool or extended RQG runner when archiving data of the run.
   # RQG tool point of view:
   # - DB servers are no more running.
   # - GenData + GenTest + ... done == Serious loss if stopped.
   # - Ressouce use of the runner is medium. == Medium win if stopped.
   # - There is a verdict about the RQG run.
use constant RQG_PHASE_COMPLETE           => 'complete';
   # Set by RQG tool or extended RQG runner when all doable work is finished.
   # RQG tool point of view:
   # - The RQG runner and his DB servers are no more running.
   # - The storage space used by the remains of the RQG run are minimal
   #   for the options given.
   #   Compressed archive + non compressed RQG log + a few small files.
   #   Data which could be freed was freed. (Especially destroy the vardir of the RQG runner).
   # - There is a verdict about the RQG run.
   # - To be done by the tool: Move these remains to an appropriate directory.
   # - GenData + GenTest + ... done == Serious loss if stuff about a failing run gets thrown away.
# Notes about the wording used
# ----------------------------
# Resource use: Storage space (especially RQG vardir) + Virtual memory + current CPU load.
# Will killing this RQG runner including his DB servers etc. + throwing vardir and workdir away
# - free many currently occupied and usually critical resources -- "win if stopped"
# - destroy a lot historic investments                          -- "loss if stopped"
#      Here I mean: We invested CPU's/RAM/storage space not available for other stuff etc.
# Background:
# Some smart tool managing multiple RQG tests in parallel and one after the other should
# maximize how the available resources are exploited in order to minimize the time elapsed
# for one testing round. This leads to some serious increased risk to overload the available
# resources and to end up with valueless test results up till OS crash.
# So in case trouble on the testing box is just ahead (assume tmpfs full) or to be feared soon
# the smart tool might decide to stop certain RQG runs and to rerun them later.
#

# Warning: The order between the elements of the list is important.
use constant RQG_PHASE_ALLOWED_VALUE_LIST => [
      RQG_PHASE_INIT, RQG_PHASE_START, RQG_PHASE_PREPARE, RQG_PHASE_GENDATA, RQG_PHASE_GENTEST,
      RQG_PHASE_SERVER_CHECK, RQG_PHASE_SERVER_COMPARE, RQG_PHASE_FINISHED, RQG_PHASE_ANALYZE,
      RQG_PHASE_ARCHIVING, RQG_PHASE_COMPLETE
   ];


sub set_rqg_phase {
#
# Purpose
# -------
# Signal the current phase by name of file.
#
# Return values
# -------------
# STATUS_OK      -- Success
# STATUS_FAILURE -- No success
#
    my ($workdir, $new_phase) = @_;
    if (not -d $workdir) {
        say("ERROR: RQG workdir '$workdir' is missing or not a directory.");
        return STATUS_FAILURE;
    }
    if (not defined $new_phase or $new_phase eq '') {
        Carp::cluck("ERROR: Auxiliary::get_set_phase new_phase is either not defined or ''.");
        return STATUS_FAILURE;
    }
    my $result = Auxiliary::check_value_supported ('phase', RQG_PHASE_ALLOWED_VALUE_LIST,
                                                   $new_phase);
    if ($result != STATUS_OK) {
        Carp::cluck("ERROR: Auxiliary::check_value_supported returned $result." .
                    "Will return that too.");
        return $result;
    }

    my $old_phase = '';
    foreach my $phase_value (@{&RQG_PHASE_ALLOWED_VALUE_LIST}) {
        if ($old_phase eq '') {
            my $file_to_try = $workdir . '/rqg_phase.' . $phase_value;
            if (-e $file_to_try) {
                $old_phase = $phase_value;
            }
        }
    }
    if ($old_phase eq '') {
        Carp::cluck("ERROR: Auxiliary::set_rqg_phase no rqg_phase file found.");
        return STATUS_FAILURE;
    }
    if ($old_phase eq $new_phase) {
        Carp::cluck("INTERNAL ERROR: Auxiliary::set_rqg_phase old_phase equals new_phase.");
        return STATUS_FAILURE;
    }

    my $old_name = $workdir . '/rqg_phase.' . $old_phase;
    my $new_name = $workdir . '/rqg_phase.' . $new_phase;
    $result = Basics::rename_file ($old_name, $new_name);
    if ($result) {
        say("ERROR: Auxiliary::set_rqg_phase from '$old_phase' to '$new_phase' failed.");
        return STATUS_FAILURE;
    } else {
        # say("PHASE: $new_phase");
        return STATUS_OK;
    }
} # End set_rqg_phase

sub get_rqg_phase {
#
# Purpose
# -------
# Get the current phase of work of some RQG runner.
#
# Return values
# -------------
# <value>  -- The current phase
# undef    -- routine failed
#
    my ($workdir) = @_;
    if (not -d $workdir) {
        say("ERROR: Auxiliary::get_rqg_phase : RQG workdir '$workdir' " .
            "is missing or not a directory. Will return undef.");
        return undef;
    }
    foreach my $phase_value (@{&RQG_PHASE_ALLOWED_VALUE_LIST}) {
        my $file_to_try = $workdir . '/rqg_phase.' . $phase_value;
        if (-e $file_to_try) {
            return $phase_value;
        }
    }
    # In case we reach this point than we have no phase file found.
    say("ERROR: Auxiliary::get_rqg_phase : No RQG phase file in directory '$workdir' found. " .
        "Will return undef.");
    return undef;
}


####################################################################################################
# Basic routines used for matching against list of RQG statuses and RQG protocol text patterns.
# See also the replay/interest/unwanted list matching in Verdict.pm.
#
# The pattern list was empty.
# Example:
#    statuses are not defined.
#    == We focus on unwanted patterns only.
use constant MATCH_NO_LIST_EMPTY   => 'match_no_list_empty';
#
# The pattern list was not empty but the text is obvious incomplete.
# Therefore a decision is impossible.
# Example:
#    The RQG run ended (abort or get killed) before having
#    - the work finished and
#    - a message about the exit status code written.
use constant MATCH_UNKNOWN         => 'match_unknown';
#
# The pattern list was not empty and one element matched.
# Examples:
# 1. replay statuses has an element with STATUS_SERVER_CRASHED and the RQG(GenTest) run
#    finished with that status.
# 2. replay patterns has an element with '<signal handler called>' and the RQG log contains a
#    snip of a backtrace with that.
use constant MATCH_YES             => 'match_yes';
#
# The pattern list was not empty, none of the elements matched and nothing looks
# interesting at all.
# Example:
#    replay statuses has an element with STATUS_SERVER_CRASHED and the RQG(GenTest) run
#    finished with some other status. But this other status is STATUS_OK.
use constant MATCH_NO              => 'match_no';
#
# The pattern list was not empty, none of the elements matched but the outcome looks interesting.
# Example:
#    replay statuses has only one element like STATUS_SERVER_CRASHED and the RQG(GenTest) run
#    finished with some other status. But this other status is bad too (!= STATUS_OK).
use constant MATCH_NO_BUT_INTEREST => 'match_no_but_interest';


sub content_matching {
#
# Purpose
# =======
#
# Search within $content for matches with elements within some list of
# text patterns.
#

    my ($content, $pattern_list, $message_prefix, $debug) = @_;

# Input parameters
# ================
#
# Parameter               | Explanation
# ------------------------+-------------------------------------------------------
# $content                | Some text with multiple lines to be processed.
#                         | Typical example: The protocol of a RQG run.
# ------------------------+-------------------------------------------------------
# $pattern_list           | List of pattern to search for within the text.
# ------------------------+-------------------------------------------------------
# $message_prefix         | Use it for making messages written by the current
#                         | routine more informative.
#                         | Some upper level caller routine knows more about the
#                         | for calling content_matching on low level.
# ------------------------+-------------------------------------------------------
# $debug                  | If the value is > 0 than the routine is more verbose.
#                         | Use it for debugging the curent routine, the caller
#                         | routine, unit tests and similar.
#
# Return values
# =============
#
# Return value            | state
# ------------------------+---------------------------------------------
# MATCH_NO                | There are elements defined but none matched.
# ('match_no')            |
# ------------------------+---------------------------------------------
# MATCH_YES               | In minimum one element matched. This means
# ('match_yes')           | all remaining elements will be checked too.
# ------------------------+---------------------------------------------
# MATCH_NO_LIST_EMPTY     | There are no elements defined.
# ('match_no_list_empty') |
# ------------------------+---------------------------------------------
#
# Hint:
# The calling routines need frequent some rigorous Yes/No. Therefore they might
# twist the return value MATCH_NO_LIST_EMPTY.
# Example:
#    'replay'   list matching : MATCH_NO_LIST_EMPTY -> MATCH_YES
#    'unwanted' list matching : MATCH_NO_LIST_EMPTY -> MATCH_NO
#

    my $no_pattern = 1;
    my $match      = 0;
    foreach my $pattern (@{$pattern_list}) {
        last if not defined $pattern;
        $no_pattern = 0;
        my $message = "$message_prefix element '$pattern' :";
        if ($content =~ m{$pattern}ms) {
            if ($debug) { say("$message match"); };
            $match = 1;
        } else {
            if ($debug) { say("$message no match"); };
        }
    }
    if ($no_pattern == 1) {
        if ($debug) {
           say("$message_prefix : No elements defined.");
        }
        return MATCH_NO_LIST_EMPTY;
    } else {
        if ($match) {
           return MATCH_YES;
        } else {
           return MATCH_NO;
        }
    }

} # End sub content_matching


sub content_matching2 {
#
# Purpose
# =======
#
# Search within $content for matches with elements within some list of
# text patterns.
#

    my ($content, $pattern_list, $message_prefix, $debug) = @_;

# Input parameters
# ================
#
# Parameter               | Explanation
# ------------------------+-------------------------------------------------------
# $content                | Some text with multiple lines to be processed.
#                         | Typical example: The protocol of a RQG run.
# ------------------------+-------------------------------------------------------
# $pattern_list           | List of pattern to search for within the text.
# ------------------------+-------------------------------------------------------
# $message_prefix         | Use it for making messages written by the current
#                         | routine more informative.
#                         | Some upper level caller routine knows more about the
#                         | for calling content_matching on low level.
# ------------------------+-------------------------------------------------------
# $debug                  | If the value is > 0 than the routine is more verbose.
#                         | Use it for debugging the curent routine, the caller
#                         | routine, unit tests and similar.
#
# Return values
# =============
#
# Return value            | state
# ------------------------+---------------------------------------------
# MATCH_NO                | There are elements defined but none matched.
# ('match_no')            |
# ------------------------+---------------------------------------------
# MATCH_YES               | In minimum one element matched. This means
# ('match_yes')           | all remaining elements will be checked too.
# ------------------------+---------------------------------------------
# MATCH_NO_LIST_EMPTY     | There are no elements defined.
# ('match_no_list_empty') |
# ------------------------+---------------------------------------------
#
# Hint:
# The calling routines need frequent some rigorous Yes/No. Therefore they might
# twist the return value MATCH_NO_LIST_EMPTY.
# Example:
#    'replay'   list matching : MATCH_NO_LIST_EMPTY -> MATCH_YES
#    'unwanted' list matching : MATCH_NO_LIST_EMPTY -> MATCH_NO
#

    my $no_pattern = 1;
    my $match      = 0;
    my @match_info;
    use constant SEARCH_PATTERN => 1;
    use constant EXTRA_INFO     => 0;

    my @patterns = @{$pattern_list};
    my $num = 0;
    foreach my $pattern (@patterns) {
        $num++;
        my @pattern = @{$pattern};
        my $search_pattern = $pattern[SEARCH_PATTERN];
        my $extra_info     = $pattern[EXTRA_INFO];
        # say("pattern pair $num SEARCH_PATTERN: " . $search_pattern);
        # say("pattern pair $num EXTRA_INFO:     " . $extra_info);
        # FIXME: last or next
        last if not defined $search_pattern;
        $no_pattern = 0;
        my $message = "$message_prefix element '$search_pattern' :";
        if ($content =~ m{$search_pattern}s) {
            if ($debug) { say("$message match"); };
            $match = 1;
            if (defined $extra_info) {
                push @match_info , $extra_info;
            } else {
                push @match_info , '<undef>';
            }
        } else {
            if ($debug) { say("$message no match"); };
        }
    }

    if ($no_pattern == 1) {
        if ($debug) {
           say("$message_prefix : No elements defined.");
        }
        return MATCH_NO_LIST_EMPTY, undef;
    } else {
        if ($match) {
           return MATCH_YES, join("--", @match_info);
        } else {
           return MATCH_NO, undef;
        }
    }

} # End sub content_matching2

sub status_matching {

    if (5 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: Auxiliary::status_matching : Five parameters " .
                      "are required.");
        safe_exit($status);
    }

# Input parameters
# ================
#
# Purpose
# =======
#
# Search within $content for matches with elements within some list of
# text patterns.
#

    my ($content, $pattern_list, $pattern_prefix, $message_prefix, $debug) = @_;

# Parameter               | Explanation
# ------------------------+-------------------------------------------------------
# $content                | Some text with multiple lines to be processed.
#                         | Typical example: The protocol of a RQG run.
# ------------------------+-------------------------------------------------------
# $pattern_list           | List of patterns to search for within the text.
# ------------------------+-------------------------------------------------------
# $pattern_prefix         | Some additional text before the pattern.
#                         | Example: 'The RQG run ended with status'
# ------------------------+-------------------------------------------------------
# $message_prefix         | Use it for making messages written by the current
#                         | routine more informative.
#                         | Some upper level caller routine knows more about the
#                         | reason for calling content_matching on low level.
# ------------------------+-------------------------------------------------------
# $debug                  | If the value is > 0 than the routine is more verbose.
#                         | Use it for debugging the curent routine, the caller
#                         | routine, unit tests and similar.
#
# Return values
# =============
# FIXME:
# 1. Return some extra info (usually the status) as second parameter.
#    Reason:
#    Get finally (--> calculate_verdict) some more informative extra_info in case there
#    is no additional pattern match or the pattern list is empty.
# 2. Maybe change the wording
#    $pattern_list, $pattern_prefix and to some small extend how content was obtained
#    determine if we are fiddling with a status or something else.
#    ?? There is the extra handling of STATUS_ANY_ERROR.
#    ?? Introduce a STATUS_ANY_STATUS (ignore status, RQG log pattern matching only)
#
#
# Return value            | state                                        | extra_info
# ------------------------+----------------------------------------------+----------------
# MATCH_NO                | There are elements defined but none matched. | match_no ?
# ('match_no')            |                                              |
# ------------------------+----------------------------------------------+----------------
# MATCH_YES               | In minimum one element matched. This means   | $status
# ('match_yes')           | all remaining elements will be checked too.  |
# ------------------------+----------------------------------------------+----------------
# MATCH_NO_LIST_EMPTY     | There are no elements defined.               | list_empty
# ('match_no_list_empty') |                                              |
# ------------------------+----------------------------------------------+----------------
# MATCH_UNKNOWN           | $pattern_prefix was not found.               | match_unknown ?
# ('match_unknown)        |                                              |
# ------------------------+----------------------------------------------+----------------
#
# Hint:
# The calling routines need frequent some rigorous Yes/No. Therefore they might
# twist the return value MATCH_NO_LIST_EMPTY.
# Example:
#    'replay'   list matching : MATCH_NO_LIST_EMPTY -> MATCH_YES
#    'unwanted' list matching : MATCH_NO_LIST_EMPTY -> MATCH_NO
#

    say("DEBUG: pattern_prefix ->$pattern_prefix<-")
        if script_debug("A5");

    if (not defined $pattern_prefix or $pattern_prefix eq '') {
        # Its an internal error or (rather) misuse of routine.
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: pattern_prefix is not defined or empty");
        safe_exit($status);
    }
    if (not defined $content or $content eq '') {
        # Its an internal error or (rather) misuse of routine.
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: content is not defined or empty");
        safe_exit($status);
    }
    if (not defined $message_prefix or $message_prefix eq '') {
        # Its an internal error or (rather) misuse of routine.
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: message_prefix is not defined or empty");
        safe_exit($status);
    }

    # Count the number of pattern matches thanks to the 'g'.
    my $pattern_prefix_found = () = $content =~ m{$pattern_prefix}gs;
    if ($pattern_prefix_found > 1) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: pattern_prefix matched $pattern_prefix_found times.");
        safe_exit($status);
    } elsif ($pattern_prefix_found == 0) {
        say("INFO: status_matching : The pattern_prefix '$pattern_prefix' was not found. " .
            "Assume aborted RQG run and will return MATCH_UNKNOWN.");
        return MATCH_UNKNOWN;
    } else {
        say("DEBUG: status_matching : The pattern_prefix '$pattern_prefix' was " .
            "found once.") if script_debug("A5");
    }

    # FIXME:
    # 1. Maybe the file is not readable or ....
    # 2. Maybe just read $content line by line in order to save memory
    my $line;
    open my $handle, "<", \$content;
    while( $line = <$handle> ) {
        if ($line =~ m{$pattern_prefix}) {
            last;
        }
    }

    my $status_read  = $line;
    if ($status_read =~ s|.*$pattern_prefix([a-zA-Z0-9_/\.\-<>]+).*|$1|s) {
        say("DEBUG: status_matching: status_read ->$status_read<-") if script_debug("A2");
    } else {
        my $status = STATUS_INTERNAL_ERROR;
        say("INTERNAL ERROR: status_matching: No status found.") if script_debug("A2");
        safe_exit($status);
    }

    my $no_pattern = 1;
    my $match      = 0;
    foreach my $pattern (@{$pattern_list}) {
        last if not defined $pattern;
        $no_pattern = 0;
        my $search_pattern;
        my $message;
        say("DEBUG: Pattern to check ->$pattern<-") if script_debug("A5");
        if ($pattern eq 'STATUS_ANY_ERROR') {
            say("INFO: Pattern is 'STATUS_ANY_ERROR' which means any status != 'STATUS_OK' " .
                "matches.");
            # We search for something like
            #    -># 2018-05-31T20:42:35 [10095] The RQG run ended with status STATUS_OK (0)<-
            # $pattern_prefix will contain ->The RQG run ended with status<--
            # $pattern        will contain the "STATUS_....." belonging to the status.
            $search_pattern = $pattern_prefix . 'STATUS_OK';
            $message = "$message_prefix, element '" . $pattern_prefix .
                       "' followed by a status != STATUS_OK' :";
            if ($status_read =~ m{STATUS_OK}s) {
                if ($debug) { say("$message no match"); };
            } else {
                if ($debug) { say("$message match"); };
                $match   = 1;
            }
        } else {
            $search_pattern = $pattern_prefix . $pattern;
            $message = "$message_prefix, element '$search_pattern' :";
            if ($status_read =~ m{$pattern}s) {
                if ($debug) { say("$message match"); };
                $match   = 1;
            } else {
                if ($debug) { say("$message no match"); };
            }
        }
    }
    if ($no_pattern == 1) {
        if ($debug) {
            say("$message_prefix , no element defined.");
        }
        return MATCH_NO_LIST_EMPTY, $status_read;
    } else {
        if ($match) {
            return MATCH_YES, $status_read;
        } else {
            return MATCH_NO, $status_read;
        }
    }

} # End sub status_matching


sub print_list {
    my ($prefix, @input) = @_;
    my $output = $prefix .  ": ";
    my $has_elements = 0;
    foreach my $element (@input) {
        $has_elements = 1;
        if (not defined $element) {
            $element = "undef";
        }
        $output = $output . "->" . $element . "<-";
    }
    if ($has_elements) {
        say($output);
    } else {
        say($output . "List had no elements.");
    }
}

sub unified_value_list {
    my (@input) = @_;
    my $has_elements = 0;
    my @unified_element_list;
    foreach my $element (@input) {
        $has_elements = 1;
        if (not defined $element) {
            push @unified_element_list, 'undef';
        } else {
            push @unified_element_list, $element;
        }
    }
    if ($has_elements) {
        return @unified_element_list;
    } else {
        return undef;
    }
}


sub input_to_list {
#
# We have certain RQG options which need to be finally some list.
# But in order to offer some comfort in
# - RQG command line calls
# - config files
# assignments like xyz=<comma separated elements> should be supported.
#
# Example: --redefine=a.yy,b1.yy
#
# return a reference to @input or undef
#

    if (@_ < 1) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: Auxiliary::input_to_list : One Parameter " .
                    "(input) is required. Will return undef.");
        safe_exit($status);
        # This accident could roughly only happen when coding RQG or its tools.
        # Already started servers need to be killed manually!
    }
    my (@input) = @_;

    my $quote_val;
    print_list("DEBUG: input_to_list initial value ", @input) if script_debug("A5");

    if ($#input != 0) {
        say("DEBUG: input_to_list : The input does not consist of one element. " .
            "Will return that input.") if script_debug("A5");
        return \@input;
    }
    if (not defined $input[0]) {
        say("DEBUG: input_to_list : \$input[0] is not defined. " .
            "Will return the input.") if script_debug("A5");
        return \@input;
    } else {
        my $result = surround_quote_check($input[0]);
        if      ('no quote protection' eq $result) {
            # The value comes from a config file?
            $quote_val = '';
        } elsif ('bad quotes' eq $result) {
            say("Return undef because of error.");
            return undef;
        } elsif ('single quote protection' eq $result or 'double quote protection' eq $result) {
            # The value is well formed and comes from a command line?
            $quote_val = "'";
            if ('double quote protection' eq $result) {
                $quote_val = '"';
            }
        } else {
            say("INTERNAL ERROR: surround_quote_check returned '$result' which is not supported." .
                "Will return undef.");
            return undef;
        }
    }

    my $separator = $quote_val . ',' . $quote_val;
    if ($input[0] =~ m/$separator/) {
        say("DEBUG: -->" . $separator . "<-- in input found. Splitting required.") if script_debug("A5");
        # Remove the begin and end quote first.
        $input[0] = substr($input[0], 1, length($input[0]) - 2) if 1 == length($quote_val);
        @input = split(/$separator/, $input[0]);
    } else {
        say("DEBUG: -->$separator<-- not in input found.") if script_debug("A5");
        $input[0] = substr($input[0], 1, length($input[0]) - 2) if 1 == length($quote_val);
    }
    return \@input;
} # End sub input_to_list


sub getFileSlice {
#
# Return
# ------
# - up to $search_var_size bytes read from the end of the file $file_to_read
# - undef if there is whatever trouble with the file (existence, type etc.)
# or Carp::cluck and abort if the routine is used wrong.
#
# Some code used for testing the current routine
# 'not_exists' -- does not exist.
# 'empty'      -- is empty
# 'otto'       -- is not empty and bigger than 100 Bytes
# my $content_slice = Auxiliary::getFileSlice();
# say("EXPERIMENT:  Auxiliary::getFileSlice() content_slice : $content_slice");
# say("content_slice is undef") if not defined $content_slice;
#
# my $content_slice = Auxiliary::getFileSlice('not_exists');
# say("EXPERIMENT:  Auxiliary::getFileSlice('not_exists') content_slice : $content_slice");
# say("content_slice is undef") if not defined $content_slice;
#
# my $content_slice = Auxiliary::getFileSlice('not_exists', 100);
# say("EXPERIMENT:  Auxiliary::getFileSlice('not_exists', 100) content_slice : $content_slice");
# say("content_slice is undef") if not defined $content_slice;
#
# my $content_slice = Auxiliary::getFileSlice('empty', 100);
# say("EXPERIMENT:  Auxiliary::getFileSlice('empty', 100) content_slice : $content_slice");
# say("content_slice is undef") if not defined $content_slice;
#
# my $content_slice = Auxiliary::getFileSlice('otto', 100);
# say("EXPERIMENT:  Auxiliary::getFileSlice('otto', 100) content_slice : $content_slice");
# say("content_slice is undef") if not defined $content_slice;
#

    my ($file_to_read, $search_var_size) = @_;
    if (@_ != 2) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: Auxiliary::getFileSlice : 2 Parameters (file_to_read, " .
                      "search_var_size) are required.");
        safe_exit($status);
        # This accident could roughly only happen when coding RQG or its tools.
        # Already started servers need to be killed manually!
    }

    if (not defined $file_to_read) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: \$file_to_read is not defined.");
        safe_exit($status);
    }

    if (not -e $file_to_read) {
        say("ERROR: The file '$file_to_read' does not exist. Will return undef.");
        return undef;
    }
    if (not -f $file_to_read) {
        say("ERROR: The file '$file_to_read' is not a plain file. Will return undef.");
        return undef;
    }

    system("sync -d $file_to_read");

    my $file_handle;
    if (not open ($file_handle, '<', $file_to_read)) {
        say("ERROR: Open '$file_to_read' failed : $!. Will return undef.");
        return undef;
    }

    my @filestats = stat($file_to_read);
    my $filesize  = $filestats[7];
    my $offset    = $filesize - $search_var_size;

    if ($filesize <= $search_var_size) {
        if (not seek($file_handle, 0, 0)) {
            Carp::cluck("ERROR: Seek to the begin of '$file_to_read' failed: $!. Will return undef.");
            return undef;
        }
    } else {
        if (not seek($file_handle, - $search_var_size, 2)) {
            Carp::cluck("ERROR: Seek " . $search_var_size . " Bytes from end of '$file_to_read.' " .
                        "towards file begin failed: $!. Will return undef.");
        }
    }

    my $content_slice;
    read($file_handle, $content_slice, $search_var_size);
    close ($file_handle);

    return $content_slice;

} # End sub getFileSlice


sub getFileSection {
#
# Return
# ------
# - 1. Up to $search_var_size bytes will be read from the end of the file $file_to_read.
#   2. The content before the line with $begin_marker and the line with $end_marker will removed.
#   3. From every remaining line any leading '#<spaces>' get removed.
# - '' if nothing found is left over
# - undef if there is whatever trouble with the file (existence, type etc.)
# or Carp::cluck and abort if the routine is used wrong.
#
# Expected format
# BOL                                                                         EOL
# --># Section section_name -------<only '-' here> ----------------------- end<--

    my ($file_to_read, $section_name) = @_;
    if (@_ != 2) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: Auxiliary::getFileSection : 2 Parameters (file_to_read, " .
                    "section_name) are required.");
        safe_exit($status);
        # This accident could roughly only happen when coding RQG or its tools.
        # Already started servers need to be killed manually!
    }

    if (not defined $file_to_read) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: \$file_to_read is not defined.");
        safe_exit($status);
    }

    if (not -e $file_to_read) {
        say("ERROR: The file '$file_to_read' does not exist. Will return undef.");
        return undef;
    }
    if (not -f $file_to_read) {
        say("ERROR: The file '$file_to_read' is not a plain file. Will return undef.");
        return undef;
    }

    my $begin_marker = '^# Section ' . $section_name . ' -+ start$';
    my $end_marker   = '^# Section ' . $section_name . ' -+ end$';
    # say("begin_marker: ->" . $begin_marker . "<-");
    # say("end_marker:   ->" . $end_marker   . "<-");

    system("sync -d $file_to_read");

    my $file_handle;
    if (not open ($file_handle, '<', $file_to_read)) {
        say("ERROR: Open '$file_to_read' failed : $!. Will return undef.");
        return undef;
    }

    my $content_slice = '';
    while (my $line = <$file_handle>) {
        last if $line =~ m{$begin_marker};
    }
    while (my $line = <$file_handle>) {
        last if $line =~ m{$end_marker};
        # No 'chomp $line;' because we will need the \n at line end.
        $line =~ s/^# ?//;
        $content_slice .= $line;
        if (1000000 < length($content_slice)) {
            Carp::cluck("ERROR: Already more than 1000000 chars read. Will return undef.");
            close ($file_handle);
            return undef;
        }
    }

    # say("$content_slice");
    close ($file_handle);
    return $content_slice;

} # End sub getFileSection

# -----------------------------------------------------------------------------------
use constant SOURCE_INFO_FILE         => 'SourceInfo.txt';

my $git_supported;
sub check_git_support {

    # For experimenting/debugging
    ## -> failed to execute
    # $cmd = "nogit --version 2>&1";    # == git not installed or typo
    ## -> exited with value 2
    # $cmd = "git --version 2>&1 > /";  # == installed but some permission missing or typo
    ## -> exited with value 129
    # $cmd = "git --caramba 2>&1";      # == installed but wrong option or typo
    ## -> DEBUG: ... exited with value 0 but messages 'cannot open .... Permission denied'
    # $cmd = "fdisk -l 2>&1";
    my $cmd = "git --version 2>&1";
    my $return = `$cmd`;
    my $rc = $?;
    if ($rc == -1) {
        say("WARNING: '$cmd' failed to execute: $!");
        $git_supported = 0;
        return STATUS_OK;
    } elsif ($rc & 127) {
        say("WARNING: '$cmd' died with signal " . ($rc & 127));
        $git_supported = 0;
        my $status = STATUS_ENVIRONMENT_FAILURE;
        safe_exit($status);
    } elsif (($rc >> 8) != 0) {
        say("WARNING: '$cmd' exited with value " . ($rc >> 8));
        $git_supported = 0;
        my $status =  STATUS_INTERNAL_ERROR;
        safe_exit($status);
    } else {
        # say("DEBUG: '$cmd' exited with value " . ($rc >> 8));
        $git_supported = 1;
        return STATUS_OK;
    }
}


sub get_git_info {

    my ($directory) = @_;
    # $directory - the path including directory name like /dev/shm/bld_dir

    if (not defined $directory) {
        # The caller should prevent that!
        say("ERROR: Auxiliary::get_git_info : The assigned directory is undef. " .
            "Will return STATUS_INTERNAL_ERROR");
        my $status = STATUS_INTERNAL_ERROR;
        safe_exit($status);
    }

    if (not -e $directory) {
        say("ERROR: Auxiliary::get_git_info : The assigned '$directory' does not exist. " .
            "Will exit with  STATUS_INTERNAL_ERROR");
        my $status = STATUS_INTERNAL_ERROR;
        safe_exit($status);
    }
    if (not -d $directory) {
        say("ERROR: Auxiliary::get_git_info : The assigned '$directory' is not a directory. " .
            "Will exit with  STATUS_INTERNAL_ERROR");
        my $status = STATUS_INTERNAL_ERROR;
        safe_exit($status);
    }

    if (not defined $git_supported) {
        my $status = check_git_support();
        if ($status != STATUS_OK) {
            return $status;
        }
    }

    return STATUS_OK if not $git_supported;

    my $cwd = Cwd::cwd();
    if (not chdir($directory)) {
        say("ALARM: chdir to '$directory' failed with : $!\n" .
            "       Will exit with  STATUS_ENVIRONMENT_FAILURE");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        safe_exit($status);
    }

    # git show --pretty='format:%D %H  %cI' -s
    # HEAD -> experimental, origin/experimental ce3c84fc53216162ef8cc9fdcce7aed24887e305  2018-05-04T12:39:45+02:00
    # %s would show the title of the last commit but that could be longer than wanted.
    my $cmd = "git show --pretty='format:%D %H %cI' -s 2>&1";
    my $val= `$cmd`;
    # say("INFO: GIT on '$directory') $val");

    if (not chdir($cwd)) {
        say("ALARM: chdir to '$cwd' failed with : $!\n" .
            "       Will exit with  STATUS_ENVIRONMENT_FAILURE");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        safe_exit($status);
    }

    return "GIT_SHOW: $val";

    # Note:
    # The output for a directory not under control of git like
    #    Auxiliary::get_git_info('/', 'ROOT')   is
    #    ROOT('/') fatal: Not a git repository (or any of the parent directories): .git
    # and we should be able to live with that.

} # End sub get_git_info


sub get_basedir_info {
# success -- return string
# failure -- exit

    my ($directory) = @_;
    if (not defined $directory) {
        # The caller should prevent that!
        say("ERROR: Auxiliary::get_git_info : The assigned directory is undef. " .
            "Will exit with STATUS_INTERNAL_ERROR");
        my $status = STATUS_INTERNAL_ERROR;
        safe_exit($status);
    }


    if (not -e $directory) {
        say("ERROR: Auxiliary::get_git_info : The assigned '$directory' does not exist. " .
            "Will exit with STATUS_INTERNAL_ERROR");
        my $status = STATUS_INTERNAL_ERROR;
        safe_exit($status);
    }
    if (not -d $directory) {
        say("ERROR: Auxiliary::get_git_info : The assigned '$directory' is not a directory. " .
            "Will exit with STATUS_INTERNAL_ERROR");
        my $status = STATUS_INTERNAL_ERROR;
        safe_exit($status);
    }

    # Start with the most likely that its an install or an out of source build.
    my $build_prt = $directory . "/short.prt";
    if (-f $build_prt) {
        # say("DEBUG: Protocol of build '$build_prt' detected. Extracting some data ...");
        my $val= Auxiliary::get_scrap_after_pattern($build_prt, 'GIT_SHOW: ');
        if (not defined $val) {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            safe_exit($status);
        } elsif ('' eq $val) {
            # No such string found. So do nothing
        } else {
            return "GIT_SHOW: " . $val;
        }
    } else {
        # say("DEBUG: No protocol of build '$build_prt' found.");
    }

    my $cmd;             # For commands run through system ...
    my $cwd = Cwd::cwd();
    if (not chdir($directory))
    {
        say("ALARM: chdir to '$directory' failed with : $!\n" .
            "       Will exit with STATUS_ENVIRONMENT_FAILURE");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        safe_exit($status);
    }
    my $val = get_git_info($directory);
    if (not chdir($cwd)) {
        say("ALARM: chdir to '$cwd' failed with : $!\n" .
            "       Will exit with STATUS_ENVIRONMENT_FAILURE");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        safe_exit($status);
    }

    return $val;

} # End sub get_basedir_info

sub get_all_basedir_infos {
    my @basedirs = @_;
    my $i = 0;
    my $info;
    foreach my $basedir (@basedirs) {
        $info .= "\n" if 0 != $i;
        $info .= "INFO: basedir[$i] : ";
        if (defined $basedir) {
            $info .= "->" . $basedir . "<- ";
            $info .= get_basedir_info($basedir);
        } else {
            $info .= "<undef>";
        }
        $i++;
    }
    return $info;
}

sub check_basedirs {
    my @basedirs = @_;
    my $who_am_i = Basics::who_am_i();
    Auxiliary::print_list("INFO: Initial RQG basedirs ",  @basedirs);
    if ((not defined $basedirs[0] or $basedirs[0] eq '') and
        (not defined $basedirs[1] or $basedirs[1] eq '')    ) {
        # We need in minimum the server 1 and for it a basedir.
        say("ERROR: $who_am_i The values for basedir and basedir1 are undef or ''.");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        safe_exit($status);
    }
    if (0 == $#basedirs) {
        if (not defined $basedirs[0] or $basedirs[0] eq '') {
            say("ERROR: $who_am_i The values for basedir and basedir1 are undef or ''.");
            # FIXME: help_basedirs();
            my $status = STATUS_ENVIRONMENT_FAILURE;
            safe_exit($status);
        } else {
            # There might be several basedirs put into $basedirs[0]
            # Auxiliary::print_list("DEBUG: Initial RQG basedirs ", @basedirs);
            my $list_ref = Auxiliary::input_to_list(@basedirs);
            if(defined $list_ref) {
                @basedirs = @$list_ref;
            } else {
                say("ERROR: Auxiliary::input_to_list hit problems we cannot handle. " .
                    "Will exit with STATUS_ENVIRONMENT_FAILURE.");
                my $status = STATUS_ENVIRONMENT_FAILURE;
                safe_exit($status);
            }
        }
    }
    foreach my $i (0..3) {
        # Replace the annoying '//' with '/'.
        $basedirs[$i] =~ s/\/+/\//g if defined $basedirs[$i];
    }
    # Auxiliary::print_list("DEBUG: Intermediate RQG basedirs ", @basedirs);
    foreach my $i (0..3) {
        next if not defined $basedirs[$i];
        my $msg_begin = "ERROR: $who_am_i basedir" . $i . " '$basedirs[$i]'";
        if (defined $basedirs[$i] and $basedirs[$i] ne '') {
            if (not -e $basedirs[$i]) {
                say($msg_begin . " does not exist.");
                my $status = STATUS_ENVIRONMENT_FAILURE;
                safe_exit($status);
            }
            if (not -d $basedirs[$i]) {
                say($msg_begin . " is not a directory.");
                my $status = STATUS_ENVIRONMENT_FAILURE;
                safe_exit($status);
            }
            foreach my $i (0..3) {
                 if (defined $basedirs[$i] and $basedirs[$i] ne '') {
                     my $lib_dir = $basedirs[$i] . "/lib";
                     if (not -d $lib_dir) {
                         if (not mkdir $lib_dir) {
                             my $status = STATUS_ENVIRONMENT_FAILURE;
                             say("ERROR: $who_am_i mkdir '$lib_dir' failed : $!");
                             run_end($status);
                         }
                     }
                     my $plugin_dir = $lib_dir . "/plugin";
                     if (not -d $plugin_dir) {
                         if (not mkdir $plugin_dir) {
                             say("ERROR: $who_am_i mkdir '$plugin_dir' failed : $!");
                             my $status = STATUS_ENVIRONMENT_FAILURE;
                             run_end($status);
                         }
                     }
                     $plugin_dir = $plugin_dir . '/';
                     if (-d $basedirs[$i] . 'plugin') {
                         # Seems to be some in source or out of source build.
                         my $file_pattern = $basedirs[$i] . '/plugin/*/*.so';
                         # my $cmd = "cp -s " . $file_pattern . " " . $plugin_dir;
                         my $cmd = 'if [ `ls -d ' . $file_pattern . ' | wc -l` -gt 0 ] ; then cp -s ' .
                                   $file_pattern . ' ' . $plugin_dir . "; fi";
                         my $rc = system($cmd);
                         say("WARNING: $who_am_i The command to symlink plugins showed problems " .
                             "(frequent harmless).") if $rc > 0;
                     }
                 }
             }
        }
    }
    return @basedirs;
}

sub expand_basedirs {
# To be called by rqg.pl only.
    my @basedirs = @_;
    if ((not defined $basedirs[0] or $basedirs[0] eq '') and
        (defined $basedirs[1] and $basedirs[1] ne '')       ) {
        say("DEBUG: \$basedirs[0] is not defined or eq ''. Setting it to '$basedirs[1]'.");
        $basedirs[0] = $basedirs[1];
    }
    # $basedirs[0] should have now a defined value and that value is != ''.
    # Assign that value to all $basedirs[$] which have an undef value or value == ''.
    foreach my $i (1..3) {
        if (not defined $basedirs[$i] or $basedirs[$i] eq '') {
            $basedirs[$i] = $basedirs[0];
        }
    }
    # Auxiliary::print_list("INFO: RQG basedirs after expansion ", @basedirs);
    return @basedirs;
}

####################################################################################################
# Certain constants related to whatever kinds of replication
#
# Run with one server only.
use constant RQG_RPL_NONE                 => 'none';
# Run with two servers and binlog_format=statement.
use constant RQG_RPL_STATEMENT            => 'statement';
use constant RQG_RPL_STATEMENT_NOSYNC     => 'statement-nosync';
# Run with two servers and binlog_format=mixed.
use constant RQG_RPL_MIXED                => 'mixed';
use constant RQG_RPL_MIXED_NOSYNC         => 'mixed-nosync';
# Run with two servers and binlog_format=row.
use constant RQG_RPL_ROW                  => 'row';
use constant RQG_RPL_ROW_NOSYNC           => 'row-nosync';
# Not used. # Run with n? servers and Galera
use constant RQG_RPL_GALERA               => 'galera';
# Run with two servers and RQG builtin statement based replication.
use constant RQG_RPL_RQG2                 => 'rqg2';
# Run with three servers and RQG builtin statement based replication.
use constant RQG_RPL_RQG3                 => 'rqg3';

use constant RQG_RPL_ALLOWED_VALUE_LIST => [
       RQG_RPL_NONE,
       RQG_RPL_STATEMENT, RQG_RPL_STATEMENT_NOSYNC, RQG_RPL_MIXED, RQG_RPL_MIXED_NOSYNC,
       RQG_RPL_ROW, RQG_RPL_ROW_NOSYNC,
       RQG_RPL_GALERA,
       RQG_RPL_RQG2, RQG_RPL_RQG3
];

####################################################################################################

sub measure_space_consumption {
# Return values:
# -2 -- The assumption of rqg_batch about the state of the system at runtime is extreme violated.
#       Recommended: Abort the rqg_batch run.
# -1 -- "du -sk" failed because of whatever reason, most probably command not supported
# int > 0 -- The space consumption.
    my ($directory) = @_;
    if (not defined $directory) {
        Carp::confess("INTERNAL ERROR: Parameter (directory or file) is undef.");
    }
    if (not -e $directory) {
        Carp::cluck("ERROR: Parameter (directory or file) does not exist.");
        return -2;
    }
    my $cmd = "du -sk --dereference $directory | cut -f1";
    my $return = `$cmd`;
    if ($? == -1) {
        say("WARNING: '$cmd' failed to execute: $!");
        return -1;
    } elsif ($? & 127) {
        say("WARNING: '$cmd' died with signal " . ($? & 127));
        return -1;
    } elsif (($? >> 8) != 0) {
        say("WARNING: '$cmd' exited with value " . ($? >> 8));
        return -1;
    } else {
        chomp $return; # Remove the '\n' at end.
        return $return;
    }
}

sub run_cmd {
# Run a shell command and return return code, output.
    my ($cmd) = @_;
    my $who_am_i = Basics::who_am_i();
    if (not defined $cmd or $cmd eq '') {
        say("ERROR: $who_am_i \$cmd is undef or ''.");
        return STATUS_INTERNAL_ERROR, undef;
    }
    my $return = `$cmd`;
    if ($? == -1) {
        say("WARNING: $who_am_i '$cmd' failed to execute: $!");
        return STATUS_ENVIRONMENT_FAILURE, undef;
    } elsif ($? & 127) {
        say("WARNING: $who_am_i '$cmd' died with signal " . ($? & 127));
        return STATUS_ENVIRONMENT_FAILURE, undef;
    } elsif (($? >> 8) != 0) {
        say("WARNING: $who_am_i '$cmd' exited with value " . ($? >> 8));
        return STATUS_ENVIRONMENT_FAILURE, undef;
    } else {
        chomp $return; # Remove the '\n' at end.
        return STATUS_OK, $return;
    }
}

# Current total storage space consumption of some RQG test.
# == vardir including symlinks
# == fast_dir including symlinks
# == (fast_dir + tiny content on slow_dir) if DB data directories on fast_dir
# == (fast_dir + serious content on slow_dir) if DB data directories on slow_dir
my $total_size          = 0;
# Current storage space consumption of some RQG test on fast_dir (symlinks excluded)
my $fast_dir_size       = 0;
# Current storage space consumption of some RQG test on slow_dir (symlinks excluded)
my $slow_dir_size       = 0;
my $max_total_size      = 0;
my $max_fast_dir_size   = 0;
my $max_slow_dir_size   = 0;

sub update_sizes {
# 2023-03-09T14:11:29 [3568724] INFO: rqg_fast_dir          : '/dev/shm/rqg/1678366173/96' -- fs_type observed: tmpfs
# 2023-03-09T14:11:29 [3568724] INFO: rqg_slow_dir          : '/dev/shm/rqg_ext4/1678366173/96' -- fs_type observed: ext4
# 2023-03-09T14:11:29 [3568724] INFO: vardir                : '/dev/shm/rqg/1678366173/96'
#
# Ubuntu does not provide Filesys::DiskUsage hence I do not use it.
#
    my $who_am_i = Basics::who_am_i();
    my $status;
    ($status, $total_size) = run_cmd("du -sk --dereference " . Local::get_rqg_fast_dir);
    if (STATUS_OK != $status) {
        return $status;
    }
#   say("DEBUG: total size in KB: $total_size");
    $total_size =~ s{\s.*}{};
    if ($max_total_size < $total_size) {
        $max_total_size = $total_size;
    }

    ($status, $fast_dir_size) = run_cmd("du -sk " . Local::get_rqg_fast_dir);
    if (STATUS_OK != $status) {
        return $status;
    }
#   say("DEBUG: fast_dir size in KB: $fast_dir_size");
    $fast_dir_size =~ s{\s.*}{};
    if ($max_fast_dir_size < $fast_dir_size) {
        $max_fast_dir_size = $fast_dir_size;
    }

    ($status, $slow_dir_size) = run_cmd("du -sk " . Local::get_rqg_slow_dir);
    if (STATUS_OK != $status) {
        return $status;
    }
#   say("DEBUG: slow_dir size in KB: $slow_dir_size");
    $slow_dir_size =~ s{\s.*}{};
    if ($max_slow_dir_size < $slow_dir_size) {
        $max_slow_dir_size = $slow_dir_size;
    }

    return STATUS_OK;;
}

sub get_sizes {
    my $status = update_sizes;
    if (STATUS_OK != $status) {
        return $status;
    }
    return STATUS_OK, $total_size, $fast_dir_size, $slow_dir_size;
}

sub report_max_sizes {
    my $status = update_sizes;
    if (STATUS_OK != $status) {
        return $status;
    }
    say("Storage space comsumption in KB");
    say("Maximum total: $max_total_size");
    say("Maximum in fast_dir: $max_fast_dir_size");
    say("Maximum in slow_dir: $max_slow_dir_size");
    return STATUS_OK;
}


####################################################################################################

sub describe_object {
    my ($object) = @_;
    system ("ls -ld $object");
    my $line = "DEBUG: object '$object' is";
    if ($object eq '.' or $object eq '..') {
        $line .= " point object.";
    } else {
        if      (-l $object) {
            $line .= " symlink";
        } elsif (-d $object) {
            $line .= " directory";
        } elsif (-f $object) {
            $line .= " plain file";
        } else {
            $line .= " no symlink/file/directory";
        }
        $line .= " " . get_fs_type($object);
    }
    say($line . ".");
    return STATUS_OK;
}

sub archive_results {

    my $who_am_i = Basics::who_am_i();
    # say("DEBUG: $who_am_i --------------- begin");

    my ($workdir, $vardir) = @_;
    if (not -d $workdir) {
        say("ERROR: $who_am_i RQG workdir '$workdir' is missing or not a directory.");
        return STATUS_FAILURE;
    }
    # /data/results/1649954330/1
    # say("DEBUG: Processing workdir '$workdir'");
    if (not opendir(TOPDIR, $workdir)) {
        Carp::cluck("ERROR: Opening the directory '$workdir' failed: $!");
        return STATUS_FAILURE;
    }
    # Move the rr trace directories to their final position.
    while( (my $object = readdir(TOPDIR))) {
        my $more_object = $workdir . "/" . $object;
        # describe_object($more_object);
        if ($object eq '.' or $object eq '..') {
            # say("DEBUG: '$more_object' is point object. Omitting");
            next;
        }
        # say("Checking ---------- $more_object\n");
        if (-d $more_object) {
            # say("DEBUG: '$more_object' is directory.");
        } else {
            next;
        }

        # /data/results/1649954330/1/1
        if (not opendir(SUBDIR, $more_object)) {
            Carp::cluck("ERROR: Opening the directory '$more_object' failed: $!");
            return STATUS_FAILURE;
        }
        while( (my $subobject = readdir(SUBDIR))) {
            my $more_subobject = $more_object . "/" . $subobject;
            # say("Checking ---------- $more_subobject\n");
            # describe_object($more_subobject);
            # /data/results/1649954330/1/1/rr
            if ($subobject eq 'rr' and -l $more_subobject and -d $more_subobject) {
                # say("DEBUG: '$more_subobject' has the desired name and is a symlink pointing " .
                #     "to a directory.");
                my $abs_object = Cwd::abs_path($more_subobject);
                # system("ls -ld $more_subobject $abs_object");
                unlink($more_subobject);
                if (STATUS_OK != Basics::move_dir_to_newdir($abs_object, $more_subobject)) {
                    return STATUS_FAILURE;
                }
                # File::Path::rmtree($abs_object);
                # system("ls -ld $more_subobject $abs_object");
                # system("find $more_subobject");
            }

        }
        closedir(SUBDIR);
        # say("DEBUG: Finished processing of '$more_object'.");

    }
    closedir(TOPDIR);
    # say("DEBUG: Finished processing of '$workdir'.");

    my $compress_option;
    my $suffix;
    if ( STATUS_OK == find_external_command('xz') ) {
        $compress_option = 'xz -0';
        $suffix          = 'tar.xz';
    } else {
        say("ERROR: $who_am_i The compressor 'xz' was not found.");
        return STATUS_FAILURE;
    }

    # Maybe check if some of the all time required/used files exist in order to be sure to have
    # picked the right directory.
    # We make a "cd $workdir"   first!
    my $archive     = $workdir . "/archive." . $suffix;
    my $archive_err = $workdir . "/rqg_arch.err";
    my $cmd;
    my $rc;
    my $status;
    tweak_permissions($workdir);
    # WARNING:
    # Never run a    system("sync -f $workdir $vardir");    here
    # because that easy lasts > 2000s on a box with many concurrent RQG runs which all
    # work on maybe the same HDD.

    # Failing cmd for experimenting
    # $cmd = "cd $workdir ; tar csf $archive rqg* $vardir 2>$archive_err";
    #
    # 1. Having a compressed archive and appending files to it is not supported!
    # 2. Some thoughts about why not prepending a nice -19 to the tar command.
    #    - Less elapsed time for tar with compression means shorter remaining lifetime for the
    #      voluminous data on vardir. The latter is usual on fast storage like tmpfs with
    #      limited storage space. And it is frequent a bottleneck for increasing the load.
    #    - Not using nice -19 for some auxiliary task like archiving means also less CPU for
    #      for RQG runner, especially involved DB server. This increases the time required
    #      for any work phase. And that makes more capable to reveal phases where locks or
    #      similar are missing or wrong handled.
    # 3. cd $workdir prevents to have the full path in the archive.
    # 4. The subdirectory 'rr' gets excluded from the tar archiving because its nearly not
    #    compressible and not usable for replaying when being inside some tar archive.
    # 5. --dereference is required because of the excessive symlinking.
    $cmd = "cd $workdir 2>>$archive_err; tar --create --file - "               .
           "--exclude='./archive.*' --exclude='./*/rr' --dereference ./* | "   .
           "xz --threads=1 -0 --stdout > $archive 2>>$archive_err";
    say("DEBUG: cmd : ->$cmd<-") if script_debug("A5");
    system($cmd);
    $rc = $? >> 8;
    if ($rc != 0) {
        say("ERROR: $who_am_i The command for archiving '$cmd' failed with exit status $rc");
        sayFile($archive_err);
        $status = STATUS_FAILURE;
    } else {
        $status = STATUS_OK;
    }
    # We could get $archive_err even in case of archiver success because it might contain
    # messages like 'tar: Removing leading `/' from member names' etc.
    sayFile($archive_err) if script_debug("A5");
    unlink $archive_err;
    system("sync -d $archive");
    # say("DEBUG: $who_am_i --------------- end");
    return $status;
}

sub help_rqg_home {
    print(
"HELP: About the RQG home directory used and the RQG tool/runner called.\n"                        .
"      In order to ensure the consistency of the RQG tool/runner called and the ingredients\n"     .
"      picked from the libraries the following example call\n\n"                                   .
"          [RQG_HOME=<path_A>] perl <path_B>/<tool>.pl [-I<path_C>/lib] ...\n\n"                   .
"      will get handled like:\n\n"                                                                 .
"      1. Perl tries to start <path_B>/<tool_pl> ...\n"                                            .
"      2. <tool>.pl determines the real/absolute path (of <path_A>) and takes that as\n"           .
"         'rqg_home' before loading any RQG specific includes located in 'lib'.\n"                 .
"      3. <tool>.pl prepends a '\$rqg_home/lib' to the path \@INC for searching includes.\n"       .
"      4. <tool>.pl loads RQG related includes.\n"                                                 .
"      5. <tool>.pl sets environment variable RQG_HOME=\$rqg_home\n\n"                             .
"      The search for Grammar-, Redefine, Gendata- and Gendata_sql files works like\n"             .
"      assigned                          | search for\n"                                           .
"      ----------------------------------+----------------------------------------\n"              .
"      /RQG/conf/mariadb/table_stress.yy | /RQG/conf/mariadb/table_stress.yy\n"                    .
"      conf/mariadb/table_stress.yy      | \$rqg_home/conf/mariadb/table_stress.yy\n\n"            .
"      Justification:\n"                                                                           .
"      - made assignment for includes like '-I<path_B>/lib' might have less till no impact.\n"     .
"         The RQG tool/runner called is inside that RQG_HOME.\n"                                   .
"         Example\n"                                                                               .
"            RQG_HOME=\"/work/rqg\"\n"                                                             .
"            cd <somewhere>\n"                                                                     .
"            perl /work/rqg/<runner.pl> or /work/rqg/util/<tool>.pl\n"                             .
"      b) The current working directory is the root directory of a RQG install.\n"                 .
"         The RQG tool/runner called is inside the current working directory.\n"                   .
"         In case RQG_HOME is set than it must be equal to the current working directory.\n"       .
"         Example:\n"                                                                              .
"            unset RQG_HOME\n"                                                                     .
"            cd /work/rqg\n"                                                                       .
"            perl /work/rqg/<runner.pl> or /work/rqg/util/<tool>.pl\n"
    );
}

sub check_and_set_build_thread {
#
# Purpose
# -------
# Find some usable value for the build thread (used for port calculation).
#
# Input value
# -----------
# value for build_thread known to the calling routine. undef is ok.
#
# Return value
# -----------
# success -- a defined usable value
# failure -- undef
#
# Example of usage
# ----------------
# ...
# $build_thread is declared and undef or already filled from command line or config file.
# ...
# $build_thread = Auxiliary::check_and_set_build_thread($build_thread);
# if (not defined $build_thread) {
#    my $status = STATUS_ENVIRONMENT_FAILURE;
#    say("$0 will exit with exit status " . status2text($status) . "($status)");
#    safe_exit($status);
# }
#
# lib/GenTest_e/Constants.pm contains
# use constant DEFAULT_MTR_BUILD_THREAD          => 730;
#     The old value was 930 and causes trouble with the OS around port numbers when for one of
#     the many parallel RQG workers a build thread >~ 1140 gets computed.

    my ($build_thread) = @_;
    if (not defined $build_thread) {
        if (defined $ENV{MTR_BUILD_THREAD}) {
            $build_thread = $ENV{MTR_BUILD_THREAD};
            say("INFO: Setting build_thread to '$build_thread' picked from process environment " .
                "(MTR_BUILD_THREAD).");
        } else {
            $build_thread = DEFAULT_MTR_BUILD_THREAD;
            say("INFO: Setting build_thread to the RQG default '$build_thread'.");
        }
    } else {
        say("INFO: build_thread : $build_thread");
    }
    if ( $build_thread eq 'auto' ) {
        say ("ERROR: Please set the environment variable MTR_BUILD_THREAD to a value <> 'auto' " .
             "(recommended) or unset it (will take the default value " .
             DEFAULT_MTR_BUILD_THREAD . ").");
        say("Will return undef.");
        return undef;
    } else {
        return $build_thread;
    }
} # End sub check_and_set_build_thread


sub surround_quote_check {
    my ($input) = @_;
    say("surround_quote_check: Input is ->" . $input . "<-") if script_debug("A5");
    return 'empty' if not defined $input;
    if      (substr($input,  0, 1) eq "'" and substr($input, -1, 1) eq "'") {
        say("DEBUG: The input is surrounded by single quotes. Assume " .
            "'single quote protection'.") if script_debug("A5");
        return 'single quote protection';
    } elsif (substr($input,  0, 1) eq '"' and substr($input, -1, 1) eq '"') {
        say("DEBUG: The input is surrounded by double quotes. Assume " .
            "'double quote protection'.") if script_debug("A5");
        return 'double quote protection';
    } elsif (substr($input,  0, 1) ne "'" and substr($input, -1, 1) ne "'" and
             substr($input,  0, 1) ne '"' and substr($input, -1, 1) ne '"') {
        say("DEBUG: The input is not surrounded by single or double quotes. Assume " .
            "'no quote protection'.") if script_debug("A5");
        return 'no quote protection';
    } else {
        say("ERROR: Either begin and end with single or double quote or both without quotes.");
        say("ERROR: The input was -->" . $input . "<--");
        say("ERROR: Will return 'bad quotes'.");
        return 'bad quotes';
    }
}

# -----------------------------------------------------------------------------------

sub get_string_after_pattern {
# Purpose explained by example
# ----------------------------
# The RQG log contains
# 2018-07-29T13:39:25 [26141] INFO: Total RQG runtime in s : 55
# and we are interested in the 55 for whatever purposes.
#
# if (not defined $logfile) {
#     $logfile = $workdir . '/rqg.log';
# }
# my $content = Auxiliary::get_string_after_pattern($logfile, "INFO: Total RQG runtime in s : ");
#
# Note:
# In case there
# - are several lines with that pattern than we pick the string from the last line.
# - is after the pattern stuff like 'abc def' than we catch only the 'abc'.
#
# Return values
# -------------
# undef    -- trouble with getting the content of the file at all
# ''       -- No trouble with the file but either
#             - most likely   : A line with the pattern does not exist.
#             - very unlikely : The line ends direct after the pattern or only spaces follow.
#

    my ($file, $pattern) = @_;
    if (@_ != 2) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: Auxiliary::get_string_after_pattern : 2 Parameters (file, " .
                    "pattern) are required.");
        safe_exit($status);
        # This accident could roughly only happen when coding RQG or its tools.
        # Already started servers need to be killed manually!
    }

    my $content = Auxiliary::getFileSlice($file, 100000000);
    if (not defined $content) {
        say("ERROR: Trouble getting the content of '$file'. Will return undef");
        return undef;
    }

    # FIXME: The ([a-zA-Z0-9_/\.]+).*.... is questionable.
    if ($content=~ s|.*$pattern([a-zA-Z0-9_/\.\-<>]+).*|$1|s) {
        return $content;
    } else {
        return '';
    }
}

sub get_scrap_after_pattern {
# Purpose explained by example
# ----------------------------
# The RQG job file contains
# Cl_Snip:  --duration=300 --queries=10000000 ...
# and we are interested in the '  --duration=300 --queries=10000000 ...' whatever purposes.
#
# my $content = Auxiliary::get_scrap_after_pattern($file, "Cl_Snip: ");
#
# Note:
# In case there
# - are several lines with that pattern than we pick the string from the last line.
# - is after the pattern stuff like 'abc def' than we catch everything like 'abc def'.
#
# Return values
# -------------
# undef    -- trouble with getting the content of the file at all
# ''       -- No trouble with the file but either
#             - most likely   : A line with the pattern does not exist.
#             - very unlikely : The line ends direct after the pattern or only spaces follow.
#

    my ($file, $pattern) = @_;
    if (@_ != 2) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: Auxiliary::get_scrap_after_pattern : 2 Parameters (file, " .
                    "pattern) are required.");
        safe_exit($status);
        # This accident could roughly only happen when coding RQG or its tools.
        # Already started servers need to be killed manually!
    }

    my $content = Auxiliary::getFileSlice($file, 100000000);
    if (not defined $content) {
        say("ERROR: Trouble getting the content of '$file'. Will return undef");
        return undef;
    }

    if ($content=~ s|.*$pattern([^\n]*).*|$1|s) {
        return $content;
    } else {
        return '';
    }
}

# -----------------------------------------------------------------------------------

# The unify_* routines
# ====================
# In case the RQG runners get all time already compacted grammar files with the same names assigned
#    <RQG workdir>/rqg.zz
#    <RQG workdir>/rqg.yy
#    <RQG workdir>/rqg.sql
# than we have a lot advantages compared to
# 1. grabbing
#    - maybe one ZZ grammar
#    - maybe several SQL files
#    - one YY grammar
#    - maybe several redefine files
#    scattered over various directories
# 2. applying masking if required in addition
# Some short summary of advantages:
# - archiving <RQG workdir>/rqg.* picks all relevant files for attempts to replay the scenario.
#   By that we are at least safe against modifications of
#   - the original files like conf/mariadb/table_stress.yy after the run
#   - the masking algorithm
# - <RQG workdir>/rqg.yy gives a complete but shortest possible overview about what GenTest will
#   do at runtime. The information scattered over many files is extreme uncomfortable and being
#   forced to guess/calculate what masking will cause is ugly too.
# - The grammar simplifier needs to work most time on some compacted grammar anyway.
#
# Required workflow when wanting to go the "unified way" within
# - some RQG batch runner like rqg_batch.pl
#   - combinations (supported)
#     Here that batch runner could let the RQG runner (rqg.pl) do that job.
#   - grammar simplification (implemented soon)
#     rqg_batch.pl must do that job because it controls the complete simplification process.
#   - variations of RQG parameters (implemented somewhere in future)
#     Its more efficient in case rqg_batch.pl does that job.
# - some RQG runner like rqg.pl (see there)
#   0. Omit fiddling with @gendata_sql_files and @redefine_files regarding
#         If there is one element only but that contains several files than decompose to array.
#         Example: --gendata_sql="'A','B'"
#      because the unify_* will do that.
#   1. If relevant    $gendata = Auxiliary::unify_gendata($gendata, $workdir);
#   2. If relevant    $gendata_sql_ref = Auxiliary::unify_gendata_sql(\@gendata_sql_files, $workdir);
#   3. If relevant    $redefine_ref = Auxiliary::unify_redefine(\@redefine_files, $workdir);
#   4. Handle the settings for masking + check that the main grammar exists
#                     $return = Auxiliary::unify_grammar($grammar_file, $redefine_ref, $workdir,
#                                     $skip_recursive_rules, $mask, $mask_level);
#   FIXME: Maybe join unify_redefine and unify_grammar.
#
# Return values
# -------------
# undef == trouble --> Its recommended that the caller cleans up and simialar and aborts than
#                      with STATUS_ENVIRONMENT_FAILURE.
# valid value for the parameter
#
# or Carp::cluck followed by exit in case of INTERNAL FAILURE.
#    This accident could roughly only happen when coding RQG or its tools.
#    Already started servers need to be killed manually!
sub unify_gendata {
    my ($gendata, $workdir) = @_;

    if (@_ != 2) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: unify_gendata : 2 Parameters (gendata, " .
                      "workdir) are required.");
        safe_exit($status);
    }
    if (not defined $gendata) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: unify_gendata : Parameter gendata is not defined.");
        safe_exit($status);
    }
    if (not defined $workdir) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: unify_gendata : Parameter workdir is not defined.");
        safe_exit($status);
    } else {
        if (! -d $workdir) {
            my $status = STATUS_INTERNAL_ERROR;
            Carp::cluck("INTERNAL ERROR: unify_gendata : workdir '$workdir' does not exist " .
                          "or is not a directory.");
            safe_exit($status);
        }
    }

    if ($gendata eq '' or $gendata eq '1' or $gendata eq 'None') {
        # Do nothing.
    } else {
        $gendata = Local::get_rqg_home() . "/" . $gendata if not $gendata =~ m {^/};
        # We run gendata with a ZZ grammar. So the value in $gendata is a file which must exist.
        if (not -f $gendata) {
            say("ERROR: The file '$gendata' assigned to gendata does not exist or " .
                "is not a plain file.");
            my $status = STATUS_ENVIRONMENT_FAILURE;
            safe_exit($status);
        } else {
            # use File::Copy
            my $gendata_file = $workdir . "/rqg.zz";
            if ($gendata ne $gendata_file) {
                if (not File::Copy::copy($gendata, $gendata_file)) {
                    say("ERROR: Copying '$gendata' to '$gendata_file' failed: $!");
                    my $status = STATUS_ENVIRONMENT_FAILURE;
                    say("$0 will exit with exit status " . status2text($status) . "($status)");
                    safe_exit($status);
                }
                $gendata = $gendata_file;
            } else {
                # The file assigned is already what we need.
                # Most probably rqg.pl was called by some tool which already placed that file there.
                # So do nothing.
            }
        }
    }
    return $gendata;
}

sub unify_gendata_sql {
# FIXME: Clean up of code
    my ($gendata_sql_ref, $workdir) = @_;
    if (@_ != 2) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: unify_gendata_sql : 2 Parameters (gendata_sql_ref, " .
                      "workdir) are required.");
        safe_exit($status);
    }
    if (not defined $gendata_sql_ref) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: unify_gendata_sql : Parameter gendata_sql_ref is not defined.");
        safe_exit($status);
    }
    if (not defined $workdir) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: unify_gendata_sql : Parameter workdir is not defined.");
        safe_exit($status);
    } else {
        if (! -d $workdir) {
            my $status = STATUS_INTERNAL_ERROR;
            Carp::cluck("INTERNAL ERROR: unify_gendata_sql : workdir '$workdir' does not exist " .
                        "or is not a directory.");
            safe_exit($status);
        }
    }

    my @gendata_sql_files = @$gendata_sql_ref;
    if (0 == scalar @gendata_sql_files) {
        return $gendata_sql_ref;
    } else {
        # There might be several gendata_sql_files put into $gendata_sql_files[0]
        # Auxiliary::print_list("DEBUG: Initial gendata_sql_files files ", @gendata_sql_files);
        my $list_ref = Auxiliary::input_to_list(@gendata_sql_files);
        if(defined $list_ref) {
            @gendata_sql_files = @$list_ref;
        } else {
            return undef;
        }
        my $not_found = 0;
        my $is_used   = 0;
        foreach my $file (@gendata_sql_files) {
            $is_used   = 1;
            $file = Local::get_rqg_home() . "/" . $file if not $file =~ m {^/};
            if (not -f $file) {
                say("ERROR: The gendata_sql file '$file' does not exist or is not a plain file.");
                $not_found = 1;
            } else {
                # say("DEBUG: The gendata_sql file '$file' exists.");
            }
        }
        if ($not_found) {
            return undef;
        }
        my $gendata_sql_file = $workdir . "/rqg.sql";
        if (not -f $gendata_sql_file and $is_used) {
            foreach my $file (@gendata_sql_files) {
                $file = Local::get_rqg_home() . "/" . $file if not $file =~ m {^/};
                if (not -f $gendata_sql_file) {
                    if (not File::Copy::copy($file, $gendata_sql_file)) {
                        say("ERROR: Copying '$file' to '$gendata_sql_file' failed: $!");
                        return undef;
                    }
                } else {
                    my $content = Auxiliary::getFileSlice($file, 100000000);
                    if (not defined $content) {
                        say("ERROR: Getting the content of the file '$file' failed." .
                            "Will exit with STATUS_ENVIRONMENT_FAILURE.");
                        return undef;
                    } else {
                        if (not STATUS_OK ==
                                Basics::append_string_to_file($gendata_sql_file, $content)) {
                            say("ERROR: Appending the content of '$file' to '$gendata_sql_file' " .
                                "failed.");
                            return undef;
                        }
                    }
                }
            }
            @gendata_sql_files = ( $gendata_sql_file );
        }
    }
    return \@gendata_sql_files;
}

sub unify_redefine {
# FIXME: Clean up of code
    my ($redefine_ref, $workdir) = @_;
    if (@_ != 2) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: unify_redefine : 2 Parameters (redefine_ref, " .
                      "workdir) are required.");
        safe_exit($status);
    }
    if (not defined $redefine_ref) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: unify_redefine : Parameter redefine_ref is not defined.");
        safe_exit($status);
    }
    if (not defined $workdir) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: unify_redefine : Parameter workdir is not defined.");
        safe_exit($status);
    } else {
        if (! -d $workdir) {
            my $status = STATUS_INTERNAL_ERROR;
            Carp::cluck("INTERNAL ERROR: unify_redefine : workdir '$workdir' does not exist " .
                          "or is not a directory.");
            safe_exit($status);
        }
    }

    my @redefine_files = @$redefine_ref;
    if (0 == scalar @redefine_files) {
        return $redefine_ref;
    } else {
        # There might be several redefine_files put into $redefine_files[0]
        # Auxiliary::print_list("DEBUG: Initial redefine_files files ", @redefine_files);
        my $list_ref = Auxiliary::input_to_list(@redefine_files);
        if(defined $list_ref) {
            @redefine_files = @$list_ref;
        } else {
            return undef;
        }
        my $not_found = 0;
        my $is_used   = 0;
        foreach my $file (@redefine_files) {
            $is_used   = 1;
            $file = Local::get_rqg_home() . "/" . $file if not $file =~ m {^/};
            if (not -f $file) {
                say("ERROR: The redefine file '$file' does not exist or is not a plain file.");
                $not_found = 1;
            } else {
                # say("DEBUG: The redefine file '$file' exists.");
            }
        }
        if ($not_found) {
            return undef;
        }
        my $redefine_file = $workdir . "/tmp_rqg_redefine.yy";
        if (not -f $redefine_file and $is_used) {
            foreach my $file (@redefine_files) {
                $file = Local::get_rqg_home() . "/" . $file if not $file =~ m {^/};
                if (not -f $redefine_file) {
                    if (not File::Copy::copy($file, $redefine_file)) {
                        say("ERROR: Copying '$file' to '$redefine_file' failed: $!");
                        return undef;
                    }
                } else {
                    my $content = Auxiliary::getFileSlice($file, 100000000);
                    if (not defined $content) {
                        say("ERROR: Getting the content of the file '$file' failed." .
                            "Will return undef.");
                        return undef;
                    } else {
                        if (not STATUS_OK ==
                                Basics::append_string_to_file($redefine_file, $content)) {
                            say("ERROR: Appending the content of '$file' to '$redefine_file' " .
                                "failed. Will return undef.");
                            return undef;
                        }
                    }
                }
            }
            @redefine_files = ( $redefine_file );
        }
    }
    return \@redefine_files;
}

# Move to grammar.pm?
sub unify_grammar {
    my ($grammar_file, $redefine_ref, $workdir, $skip_recursive_rules, $mask, $mask_level) = @_;

    if (@_ != 6) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: unify_grammar : 6 Parameters (grammar, redefine_ref, " .
                      "workdir, skip_recursive_rules, mask_level, mask) are required.");
        safe_exit($status);
    }
    if (not defined $grammar_file) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: unify_grammar : Parameter grammar is not defined.");
        safe_exit($status);
    } else {
        $grammar_file = Local::get_rqg_home() . "/" . $grammar_file if not $grammar_file =~ m {^/};
        if (! -f $grammar_file) {
            my $status = STATUS_INTERNAL_ERROR;
            Carp::cluck("ERROR: Grammar file '$grammar_file' does not exist or is not a plain file.");
            safe_exit($status);
        }
    }
    if (not defined $redefine_ref) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: unify_grammar : Parameter redefine_ref is not defined.");
        safe_exit($status);
    }
    my @redefine_files = @$redefine_ref;
    if (not defined $workdir) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: unify_grammar : Parameter workdir is not defined.");
        safe_exit($status);
    } else {
        if (! -d $workdir) {
            my $status = STATUS_INTERNAL_ERROR;
            Carp::cluck("INTERNAL ERROR: unify_grammar : workdir '$workdir' does not exist " .
                          "or is not a directory.");
            safe_exit($status);
        }
    }

    my $grammar_obj = GenTest_e::Grammar->new(
        grammar_files => [ $grammar_file, ( @redefine_files ) ],
        grammar_flags => (defined $skip_recursive_rules ? GenTest_e::Grammar::GRAMMAR_FLAG_SKIP_RECURSIVE_RULES : undef )
    );
    if ($mask > 0 and $mask_level > 0) {
        my @top_rule_list = $grammar_obj->top_rule_list();
        if (0 == scalar @top_rule_list) {
            my $status = STATUS_INTERNAL_ERROR;
            Carp::cluck("ERROR: We had trouble with grammar_obj->top_rule_list().");
            safe_exit($status);
        } else {
            my $grammar1          = $grammar_obj->toString;
            say("DEBUG: The top rule list is '" . join ("', '", @top_rule_list) . "'.");
            my $top_grammar       = $grammar_obj->topGrammar($mask_level, @top_rule_list);
            my $masked_top        = $top_grammar->mask($mask);
            my $final_grammar_obj = $grammar_obj->patch($masked_top);
            my $grammar2          = $final_grammar_obj->toString;
            # For experimenting/debugging
            #   Basics::make_file('k1', $grammar1);
            #   Basics::make_file('k2', $grammar2);
            $grammar_obj          = $final_grammar_obj;
        }
    }
    my $grammar_string = $grammar_obj->toString;
    $grammar_file = $workdir . "/rqg.yy";
    if (STATUS_OK != Basics::make_file($grammar_file, $grammar_string)) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("ERROR: We had trouble generating the final YY grammar.");
        safe_exit($status);
    } else {
        return $grammar_file;
    }
}

sub unify_rvt_array {

# Purpose:
# Get a pointer to an array/list of reporters/validators/transformers.
# - Split all lists like --reporters=A,B,C at the comma and make the sub elements to elements.
# - Treat the multiple assignment additive like
#   --reporters=A,B --reporters=C is equivalent to --reporters=A,B,C
# - Eliminate duplicates.
# Return a pointer to a hash with the final content.
#

    my ($rvt_array_ref) = @_;
    my $who_am_i = Basics::who_am_i;
    if (@_ != 1) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: $who_am_i : One parameter (rvt_array_ref) is required.");
        safe_exit($status);
    }
    my @intermediate_rvt_array;
    my @rvt_array;
    my %rvt_hash;
    if (defined $rvt_array_ref) {
        # In case of assignment style
        #    --reporter=Backtrace,ErrorLog
        # split at ',' into elements.
        foreach my $element (@{$rvt_array_ref}) {
            if ($element =~ m/,/) {
                push @intermediate_rvt_array, split(/,/,$element);
            } else {
                push @intermediate_rvt_array, $element;
            }
            # say("DEBUG: intermediate_rvt_array ->" . join("<->", @intermediate_rvt_array) . "<-");
        }
        @rvt_array = @intermediate_rvt_array;
    }
    foreach my $element (@rvt_array) {
        $rvt_hash{$element} = 1;
    }
    @rvt_array = sort keys %rvt_hash;
    # say("DEBUG: final rvt_array ->" . join("<->", @rvt_array) . "<-");

    return \%rvt_hash;
} # End of sub unify_rvt_array

# -----------------------------------------------------------------------------------
sub check_filter {
# FIXME:
# Here is code missing.
# If filter files get copied to the workdir of the RQG run (like final grammars) than
# checking $workdir makes sense.
    my ($filter, $workdir) = @_;
    my $who_am_i = "Auxiliary::check_filter:";
    if (@_ != 2) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: $who_am_i : 2 Parameters (filter, " .
                      "workdir) are required.");
        safe_exit($status);
    }
    if (not defined $filter) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: $who_am_i : Parameter filter is not defined.");
        safe_exit($status);
    }
    if (not defined $workdir) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: $who_am_i : Parameter workdir is not defined.");
        safe_exit($status);
    } else {
        if (! -d $workdir) {
            my $status = STATUS_INTERNAL_ERROR;
            Carp::cluck("INTERNAL ERROR: $who_am_i : workdir '$workdir' does not exist " .
                        "or is not a directory.");
            safe_exit($status);
        }
    }

    $filter = Local::get_rqg_home() . "/" . $filter if not $filter =~ m {^/};
    # It is very unlikey that a duplicate $workdir/rqg.ff makes sense.
    if (not -f $filter) {
        say("ERROR: The file '$filter' assigned to --filter does not exist or " .
                 "is not a plain file. Will return undef.");
        return undef;
    }
    return $filter;
}
# -----------------------------------------------------------------------------------

# *_status_text
# =============
# These routines serve for
# - standardize the phrase printed when returning some status or exiting with some status
# - give maximum handy information like status as text (the constant) and number.
# Example for the string returned:
#    Will exit with exit status STATUS_SERVER_CRASHED(101).
#    Will return status STATUS_SERVER_CRASHED(101).
# Example of invocation:
# my $status = STATUS_SERVER_CRASHED;
# say("ERROR: All broken. " . Auxiliary::exit_status_text($status));
# safe_exit($status);
#
use constant PHRASE_EXIT   => 'exit with exit';
use constant PHRASE_RETURN => 'return with';


sub _status_text {
    my ($status, $action) = @_;
    # The calling routine MUST already check that $status and $action are defined.
    my $snip;
    if      ($action eq 'exit'  ) {
        $snip = PHRASE_EXIT;
    } elsif ($action eq 'return') {
        $snip = PHRASE_RETURN;
    } else {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL EXIT_PHRASE ERROR: Don't know how to handle the action '$action'." .
                    "Will " . PHRASE_EXIT . " " . status2text($status) . "($status).");
        safe_exit($status);
    }
    return "Will $snip status " . status2text($status) . "($status).";
}

sub exit_status_text {
    my ($status) = @_;
    if (not defined $status) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: The first parameter status is undef. " .
                    "Will " . PHRASE_EXIT . " " . status2text($status) . "($status).");
        safe_exit($status);
    }
    return _status_text($status, 'exit');
}

sub return_status_text {
    my ($status) = @_;
    if (not defined $status) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: The first parameter status is undef. " .
                    "Will " . PHRASE_EXIT . " " . status2text($status) . "($status).");
        safe_exit($status);
    }
    return _status_text($status, 'return');
}

# -----------------------------------------------------------------------------------

# *fill*
# ======
# Routined used for printing tables with results.
#
sub _fill_check {
    my ($string, $length) = @_;
    if (not defined $string) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: The first parameter string is undef. " .
                    exit_status_text($status));
        safe_exit($status);
    }
    if (not defined $length) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: The second parameter length is undef. " .
                    exit_status_text($status));
        safe_exit($status);
    }
#   if (length($string) > $length) {
#       my $status = STATUS_INTERNAL_ERROR;
#       Carp::cluck("INTERNAL ERROR: Length of string '$string' is bigger than allowed " .
#                   "length $length'. " . exit_status_text($status));
#       safe_exit($status);
#   }
}

sub rfill {
    my ($string, $length) = @_;
    _fill_check($string, $length);
    while (length($string) < $length) {
        $string = $string . ' ';
    }
    # say("DEBUG: rfilled string ->$string<-");
    return $string;
};

sub lfill {
    my ($string, $length) = @_;
    _fill_check($string, $length);
    while (length($string) < $length) {
        $string = ' ' . $string;
    }
    # say("DEBUG: lfilled string ->$string<-");
    return $string;
};

sub lfill0 {
    my ($string, $length) = @_;
    _fill_check($string, $length);
    while (length($string) < $length) {
        $string = '0' . $string;
    }
    # say("DEBUG: lfilled string ->$string<-");
    return $string;
};

sub dash_line {
# Use case:
# Print something well formed like
# 2022-05-17T18:52:59 [1670068] INFO: <whatever text with non static elements like a path>
# 2022-05-17T18:52:59 [1670068] ----------------------------------------------------------
    my ($length) = @_;
    my $string = '';
    while (length($string) < $length) {
        $string = $string . '-';
    }
    return $string;
};

sub string_is_strict_int {
# Return
# - STATUS_OK if the string consists of digits only.
#   Preceding additional zeros are not allowed.
#   Note:
#   To be used for integers >= 0 how you would assign them in shell.
#   Example: rqg.pl ... --seed=13 --> $seed contains '13' after command line processing.
#   Leading zeros or +/- signs, trailing '\n' etc. count as failure.
# STATUS_FAILURE otherwise
    my ($string) = @_;
    my $is_strict_int = (($string =~ /^[1-9][0-9]*$/) or ($string =~ /^[0-9]$/));
    if ($is_strict_int) {
        return STATUS_OK;
    } else {
        return STATUS_FAILURE;
    }
}

sub calculate_seed {
    my ($seed) = @_;

    if (not defined $seed) {
        $seed = 1;
        say("INFO: seed was not defined. Setting the default. seed : $seed");
    } else {
        my $orig_seed = $seed;
        if ($orig_seed eq 'time') {
            $seed = time();
            say("INFO: seed eq '$orig_seed'. Computation. seed : $seed");
        } elsif ($orig_seed eq 'epoch5') {
            $seed = time() % 100000;
            say("INFO: seed eq '$orig_seed'. Computation. seed : $seed");
        } elsif ($orig_seed eq 'random') {
            $seed = int(rand(32767));
            say("INFO: seed eq '$orig_seed'. Computation. seed : $seed");
        } elsif (STATUS_OK == Auxiliary::string_is_strict_int($seed)) {
            say("INFO: seed : $seed");
        } else {
            say("ERROR: seed '$seed' is no supported.");
            help_seed();
            $seed = undef;
        }
    }
    return $seed;
}

sub help_seed {
    say("RQG option 'seed':");
    say("The supported values are");
    say("- a group of digits only");
    say("- 'time'   == seconds since 1970-01-01 00:00:00 UTC");
    say("- 'epoch5' == Remainder of seconds since 1970-01-01 00:00:00 UTC modulo 100000");
    say("- 'random' == Random integer >= 0 and < 32767");
    say("Per my (mleich) experiences 'random' is optimal for bug hunting and test simplification.");
#   say("Impact of seed value assigned to");
#   say("RQG runner: Use it for the generation of data and the SQL streams.");
#   say("rqg_batch.pl: Pass the value through to the Combinator or Simplifier");
#   say("Combinator: Use it for the generation of the random combinations.");
#   say("            Assign --seed=random to any RQG run.");
#   say("Simplifier: Ignore the value.");
#   say("            Assign --seed=random to any RQG run.");
}

sub egalise_dump {
    my ($dump_file, $dump_file_egalized) = @_;

    my $who_am_i = 'Auxiliary::egalise_dump:';

    if (not defined $dump_file) {
        say("ERROR: $who_am_i The first parameter dump_file is not defined.");
        return STATUS_FAILURE;
    }
    if (not defined $dump_file_egalized) {
        say("ERROR: $who_am_i The second parameter dump_file_egalized is not defined.");
        return STATUS_FAILURE;
    }

    if (not open (DUMP_FILE, '<', $dump_file)) {
        say("ERROR: $who_am_i Open file '<$dump_file' failed : $!");
        return STATUS_FAILURE;
    }
    if (not open (DUMP_FILE_EGALIZED, '>', $dump_file_egalized)) {
        say("ERROR: $who_am_i Open file '>$dump_file_egalized' failed : $!");
        return STATUS_FAILURE;
    }
    while (my $line = <DUMP_FILE>) {
        # FIXME(later):
        # AFAIR certain things like EVENTS or TRIGGER should be disabled on a slave.
        # So test it out and add the required replacing.
        # $line =~ s{AUTO_INCREMENT=[1-9][0-9]*}{AUTO_INCREMENT=<egalized>};
        $line =~ s{ AUTO_INCREMENT=[1-9][0-9]*}{};
        $line =~ s{AUTO_INCREMENT=[1-9][0-9]* }{};
        if (not print DUMP_FILE_EGALIZED $line) {
            say("ERROR: Print to file '$dump_file_egalized' failed : $!");
        }
    }
    if (not close (DUMP_FILE)) {
        say("ERROR: Close file '$dump_file' failed : $!");
        return STATUS_FAILURE;
    }
    if (not close (DUMP_FILE_EGALIZED)) {
        say("ERROR: Close file '$dump_file_egalized' failed : $!");
        return STATUS_FAILURE;
    }
    return STATUS_OK; # 0
}

sub prepare_command_for_system {
    my ($command) = @_;
    unless (osWindows())
    {
        $command = 'bash -c "set -o pipefail; nice -19 ' . $command . '"';
    }
    return $command;
}

sub find_external_command {
    my ($command) = @_;
    my $return = `which $command`;
    # FIXME: Replace by using a routine with fine grained checking of responses.
    # See get_git_info
    chomp $return; # Remove the '\n' at end.
    if (not defined $return or $return eq '') {
        say("ERROR: which $command failed. Will return STATUS_FAILURE.");
        return STATUS_FAILURE;
    } else {
        # say("DEBUG: which $command returned ->" . $return . "<-");
        return STATUS_OK;
    }
}


sub search_in_file {
# Return:
# undef - $search_file does not exist or is not readable
# 0     - $search_file is ok, $pattern not found
# 1     - $search_file is ok, $pattern found
#
# Sample code for text fragment ->Aborted (core dumped)<-
# $found = Auxiliary::search_in_file($error_log, 'Aborted \(core dumped\)');
# if (not defined $found) {
#     # Technical problems!
#     my $status = STATUS_ENVIRONMENT_FAILURE;
#     say("FATAL ERROR: $who_am_i \$found is undef. " .
#         "Will exit with STATUS_ENVIRONMENT_FAILURE.");
#     exit $status;
# } elsif ($found) {
#     say("INFO: $who_am_i 'Aborted (core dumped)' detected. " .
#         "Will exit with STATUS_SERVER_CRASHED.");
#     exit STATUS_SERVER_CRASHED;
# } else {
#     return STATUS_OK;
# }
#
# Warning:
# Enclosing the pattern with ' or " could have a serious impact.
# So better test out if the pattern works like expected.
#
    my ($search_file, $pattern) = @_;

    my $who_am_i = "Auxiliary::search_in_file:";
    if (not -e $search_file) {
        Carp::cluck("ERROR: $who_am_i The file '$search_file' is missing. Will return undef.");
        return undef;
    }
    if (not osWindows()) {
        system ("sync -d $search_file");
    }
    if (open(LOGFILE, "$search_file")) {
        while(<LOGFILE>) {
            if( m{$pattern}m ) {
                close LOGFILE;
                # say("DEBUG: '" . $pattern . "' found in '" . $search_file . "'. Will return 1.");
                return 1;
            }
        }
        close LOGFILE;
        # say("DEBUG: '" . $pattern . "' not found in '" . $search_file . "'. Will return 0.");
        return 0;
    } else {
        Carp::cluck("ERROR: $who_am_i Open file '" . $search_file . "' failed : $!. " .
                    "Will return undef.");
        return undef;
    }
}


# FIXME: Maybe move from the Simplifier to here.
# Adaptive FIFO
#

# Conversion routine for 100M etc.
#

# Check if basedir contains a mysqld and clients

sub get_pid_from_file {
# Variants
# 1. File does not or no more exist --> undef
# 2. File exists but no sufficient permission --> undef
# 3. File exists with sufficient permission but value found does not look reasonable --> undef
# 4. all ok and looking like a DB server pid --> return it
#
# If $silent is defined than do not lament about expected events like undef pids or missing files.
# This makes RQG logs after passing
#    MATCHING: Region end   =====================
# less noisy.

    my $fname  = shift;
    my $silent = shift;
    my $who_am_i = "get_pid_from_file:";
    if (not open(PID, $fname)) {
        say("ERROR: $who_am_i Could not open pid file '$fname' for reading, " .
            "Will return undef") if not defined $silent;
        return undef;
    }
    my $pid = <PID>;
    close(PID);
    chomp $pid;
    # MariaDB 10.5 if the server is running.
    # Exact one line and no preceding or trailing chars around the pid.
    $pid =~ s/.*?([0-9]+).*/$1/;
    return check_if_reasonable_pid($pid);
}

sub check_if_reasonable_pid {
    my ($pid) =    @_;
    my $who_am_i = "check_if_reasonable_pid:";
    # The input is just what got extracted from file with preceding or trailing chars removed.
    # Thinkable content:
    # - undef              Never observed and if occuring at all than an internal error.
    # - empty string       Non rare and pid_file exists but is empty/not yet filled with pid.
    #                      The same was never observed for the err log line
    #                      [Note] <path>/mysqld (mysqld <version>) starting as process <pid> ...
    # - a too short value  Never observed but given that fact that not full written lines
    #                      were observed at least thinkable.
    if      (not defined $pid) {
        say("INTERNAL ERROR: value for \$pid is undef. Will return undef.");
        return undef;
    } elsif ($pid eq '') {
        # say("DEBUG: value for \$pid is empty string. Will return undef.");
        return undef;
    } elsif ($pid =~ /^0.*/) {
        say("ERROR: value for \$pid ->" . $pid . "<- starts with 0. Will return undef.");
        return undef;
    } elsif (not $pid =~ /^[0-9]+$/) {
        say("ERROR: value for \$pid ->" . $pid . "<- contains non digits. Will return undef.");
        return undef;
    } elsif ($pid =~ /^[0-9]?$/) {
        say("WARN: value for \$pid ->" . $pid . "<- is suspicious small. Will return undef.");
        return undef;
    } else {
        # say("DEBUG: value for \$pid ->" . $pid . "<- is ok. Will return it.");
        return $pid;
    }
}

sub print_ps_tree {
    my ($start_pid) = @_;
    Carp::cluck if not defined $start_pid;
    my $pstree = get_ps_tree($start_pid);
    say($pstree);
}

sub get_ps_tree {
    my ($start_pid) = @_;
    Carp::cluck("INTERNAL ERROR: \$start_pid is not defined.") if not defined $start_pid;
    if (STATUS_OK == find_external_command('pstree')) {
        my $pstree = `pstree --show-pids $start_pid`;
    }
}

sub print_ps_group {
    my $prgp = getpgrp;
    my $cmd = "ps -T -u `id -u` -o uid,pid,ppid,pgid,sid,args | egrep '" . $prgp . "|UID  *PID' " .
           "| sort | cut -c1-200";
    my $ps_group = `$cmd`;
    say($ps_group);
}

use POSIX;

sub reapChild {
# Usage
# -----
# Try to reap that child.
#
# Input
# -----
# $spawned_pid -- Pid of the process to check
# $info        -- Some text to be used for whatever messages
#
# Return
# ------
# $reaped -- 0 (not reaped) or 1 (reaped)
# $status -- exit status of the process if reaped,
#            otherwise STATUS_OK or STATUS_INTERNAL_ERROR
#     0, STATUS_INTERNAL_ERROR -- most probably already reaped == Defect in RQG logics
#

    my ($spawned_pid, $info) = @_;
    my $reaped = 0;
    my $status = STATUS_OK;

    #---------------------------
    my $waitpid_return = waitpid($spawned_pid, POSIX::WNOHANG);
    my $child_exit_status = $? > 0 ? ($? >> 8) : 0;
    # Returns observed:
    if      (not defined $waitpid_return) {
        # 1. !!! undef !!!
        #    In case of excessive load we could harvest that.
        #    Observations with a lot debugging code showed
        #    1.1 childs which have not initiated to exit and have not got a TERM or KILL ..
        #        did never show an undef here ~ no undef if child process is active
        #    1.2 never a case where the next call of waitpid ... delivered undef again.
        #        The next call returned all time $spawned_pid.
        #    Hence we do nothing here and "hope" that some next call of reapChild follows.
        say("WARN: waitpid for $spawned_pid ($info) returned undef.");
        return 0, STATUS_OK;
    } elsif (0 == $waitpid_return) {
        # 2. 0 == Process is running
        # say("DEBUG: waitpid for $spawned_pid ($info) returned 0. Process is running.");
        return 0, STATUS_OK;
    } elsif ($spawned_pid == $waitpid_return) {
        # 3. $spawned_pid == The process was a zombie and we have just reaped.
        # say("DEBUG: Process $spawned_pid ($info) was reaped. Status was $child_exit_status.");
        return 1, $child_exit_status;
    } else {
        # 3. -1 == Defect in RQG mechanics because we should not try to reap
        #          - an already reaped process
        #          - a process which is not our child
        #          Both would point to a heavy mistake in bookkeeping.
        #    or
        #    other value != $spawned_pid == Unexpected behaviour of waitpid on current box
        say("ERROR: waitpid for $spawned_pid ($info) returned $waitpid_return which we cannot " .
            "handle. Will return STATUS_INTERNAL_ERROR.");
        Carp::cluck;
        return 0, STATUS_INTERNAL_ERROR;
    }

} # End sub reapChild

sub reapChildren {
    my $child;
    do {
        # Roughly from waitpid.html + edited
        # ----------------------------------
        # waitpid PID,FLAGS
        # waitpid -> only child processes count (grand children NOT)
        #            rqg.pl is child of rqg_batch.pl but has a different process group ID.
        #            auxpid in DBServer is child of rqg.pl and has same process group ID.
        #            main DB server process is child of auxpid and has same process group ID.
        # FLAG POSIX::WNOHANG set -> non blocking wait
        # PID set
        #     0 -> child process whose pgid is equal to that of the current process
        #     -1 -> wait for any child process no matter if same or other pgid
        #     some_int < -1 -> wait for any child process having a pgid -some_int
        # Return values if assigning WNOHANG
        # - pid of the deceased process    Only once next time 0.
        # - 0 if there are child processes matching PID but none have terminated yet.
        # - -1 if there is no such child process
        #   or on some systems, a return value of -1 could mean that child processes are
        #   being automatically reaped.
        # - undef     If ever only once and typical for some box under extreme load.
        #             Per experience the next waitpid call harvests the pid of the deceased process.
        # The status is returned in $?.
        $child = waitpid(-1, POSIX::WNOHANG);
        my $max_wait_time = 5;
        my $wait_end = Time::HiRes::time() + $max_wait_time;
        while (not defined $child and Time::HiRes::time() < $wait_end) {
            sleep 0.1;
            $child = waitpid(-1, POSIX::WNOHANG);
        }
        say("WARN: reapChildren : More as " . $max_wait_time . "s undef for waitpid got.")
            if not defined $child;
    } while $child > 0;
}

sub build_wrs {
# Just generate a frequent used sentence like "Will return status STATUS_SERVER_CRASHED(101)."
# Sample code sequence
#    my $status = STATUS_ENVIRONMENT_FAILURE;
#    say("ERROR: Dates and times are severly broken ..." . Auxiliary::build_wrs($status));
#    return $status;
#
    my ($status) = @_;
    return "Will return status " . status2text($status) . "($status).";
}

sub get_fs_type {
    my ($whatever_file) = @_;
    my $fs_type;
    if (not -e $whatever_file) {
        say("INTERNAL ERROR: Whatever file '$whatever_file' does not exist.");
        my $status = STATUS_INTERNAL_ERROR;
        safe_exit($status);
    }
    if (osWindows()) {
        return 'unknown';
    } else {
        my $cmd = "df --output=fstype " . $whatever_file . " | tail -1";
        $fs_type = `$cmd`;
        chomp $fs_type;
        return $fs_type;
    }
}

sub tweak_permissions {
# Purpose:
# Make whatever files readable and directories accessible for the group.
# Background: MariaDB executables ignore my   umask 002
# Hint:
# rr generates sometimes whatever mmap_hardlink*
#    /data/vardir/1630409747/<M>/1/rr/mysqld-0/mmap_hardlink_3_mariadbd
#    points than to some <basedir>/bin/mariadbd
# In case of running chmod on these hardlinks the following non nice effects could happen
# - Some other RQG worker running archiving in parallel could lament that files changed
#   during archiving.
# - When running   rr replay  rr can lament that binaries are modified or similar.
# Hence files with 'mmap_hardlink' in their name get excluded from chmod.
    my ($whatever_dir) = @_;
    if (not -e $whatever_dir or not -d $whatever_dir) {
        say("INTERNAL ERROR: Whatever directory '$whatever_dir' does not exist or " .
            "is not a directory.");
        return STATUS_INTERNAL_ERROR;
    }
    my $status = STATUS_OK;
    if (not osWindows()) {
        my $prt = $whatever_dir . "/chmod.prt";
        unlink $prt;
        my $cmd = "find " . $whatever_dir . " -follow -print | grep -v 'mmap_hardlink' | " .
                  "xargs --no-run-if-empty chmod g+rwX > $prt 2>&1";
        my $rc = system($cmd);
        $rc = $? >> 8;
        if ($rc != 0) {
            say("ERROR: ->" . $cmd . "<- failed with exit status $rc");
            sayFile($prt);
            $status =  STATUS_FAILURE;
        }
        unlink $prt;
    } else {
        # No idea
        $status = STATUS_OK;
    }
    return $status;
}

sub clean_workdir_preserve {
# Use case:
# Some RQG run is finished with some result of interest.
# Main goals:
# - move the rr traces from somewhere under /dev/shm to
#   their final destination (big permanent storage like HDD)
# - remove anything else except rqg* files and archives
#
# But the storage structure required for
# - keeping rr traces runnable
# - minimizing the total IO on slow storage devices
# is complicated and prone to mistakes when code is changed.

    my $who_am_i = Basics::who_am_i();
    # say("DEBUG: $who_am_i ---------- start");

    my ($workdir) = @_;
    # SAMPLE: /data/results/1653923445/3
    if (not -d $workdir) {
        say("ERROR: $who_am_i RQG workdir '$workdir' is missing or not a directory.");
        return STATUS_FAILURE;
    }

    if (not opendir(TOPDIR, $workdir)) {
        say("ERROR: $who_am_i Opening the directory '$workdir' failed: $!");
        return STATUS_FAILURE;
    }
    # system("find $workdir -follow | xargs ls -ld");
    while( (my $object = readdir(TOPDIR))) {
        my $more_object = $workdir . "/" . $object;
        if ($object eq '.' or $object eq '..' or -f $object) {
            # say("DEBUG: $who_am_i '$more_object' is point object or file. Omitting");
            # SAMPLES:
            # /data/results/1653923445/3/rqg.log
            # /data/results/1653923445/3/.
            next;
        }
        # say("DEBUG: $who_am_i Checking in TOPDIR ---------- $more_object\n");
        # describe_object($more_object);
        # say("DEBUG: $who_am_i '$more_object' is directory or symlink to directory.");
        my $final_path;
        if (-l $more_object) {
            # SAMPLE: /data/results/1653923445/3/1 -> /dev/shm/rqg/1653923445/3/1
            if (not -d $more_object) {
                unlink($more_object);
                # 2022-05-30 In the moment I assume that this should never show up.
                say("WARN: $who_am_i Symlink '$more_object' pointing to not existing directory deleted.");
                next;
            } else {
                $final_path = Cwd::abs_path($more_object);
                # SAMPLE: /dev/shm/rqg/1653923445/3/1
                unlink($more_object);
                # SAMPLE: /data/results/1653923445/3/1
                if (STATUS_OK != Basics::make_dir($more_object)) {
                    say("ERROR: $who_am_i Making a directory instead of symlimk '$more_object' failed.");
                    return STATUS_FAILURE;
                }
                # say("DEBUG: $who_am_i Symlink '$more_object' deleted and as directory recreated.");
            }
        } else {
            $final_path = $more_object;
        }
        # say("DEBUG: $who_am_i more_object '$more_object' final_path '$final_path'");
        # SAMPLE: more_object '/data/results/1653923445/3/1' final_path '/dev/shm/rqg/1653923445/3/1'

        if (not opendir(SUBDIR, $final_path)) {
            # SAMPLE: '/dev/shm/rqg/1653923445/3/1'
            say("ERROR: $who_am_i Opening the directory '$final_path' failed: $!");
            return STATUS_FAILURE;
        }
        while( (my $subobject = readdir(SUBDIR))) {
            # SAMPLES:
            # subobject   |  more_subobject
            # ------------+-------------------------------------------
            #         .   | /dev/shm/rqg/1653923445/3/1/.
            # mysql.err   | /dev/shm/rqg/1653923445/3/1/mysql.err
            #       tmp   | /dev/shm/rqg/1653923445/3/1/tmp
            #        rr   | /dev/shm/rqg/1653923445/3/1/rr
            my $more_subobject = $final_path . "/" . $subobject;
            # say("DEBUG: $who_am_i Checking in SUBDIR ---------- $more_subobject\n");
            # describe_object($more_subobject);
            if ($subobject eq '.' or $subobject eq '..') {
                # say("DEBUG: $who_am_i '$more_subobject' is point object. Omitting");
                next;
            }
            if(-f $more_subobject) {
                if (not unlink $more_subobject) {
                    say("ERROR: $who_am_i Processing subobjects. Removing File '$more_subobject' failed : $!.");
                    return STATUS_FAILURE;
                } else {
                    # say("INFO: $who_am_i Processing subobjects. File '$more_subobject' deleted.");
                }
                next;
            } elsif (-d $more_subobject) {
                if ($subobject ne 'rr') {
                    my $abs_object;
                    if (-l $more_subobject) {
                        # say("DEBUG: $who_am_i '$more_subobject' is a symlink pointing to a directory " .
                        #     "and not for use by rr.");
                        $abs_object = Cwd::abs_path($more_subobject);
                        unlink($more_subobject);
                        # say("DEBUG: $who_am_i Symlink '$more_subobject' pointing to a directory " .
                        #       "not for use by rr removed.");
                    } else {
                        $abs_object = $more_subobject;
                        # say("DEBUG: $who_am_i '$more_subobject' is a tree not for use by rr.");
                    }
                    if (STATUS_OK != Basics::remove_dir($abs_object)) {
                        say("ERROR: $who_am_i Removing the tree '$abs_object' failed.");
                        return STATUS_FAILURE;
                    } else {
                        # say("DEBUG: $who_am_i Tree '$abs_object' not for use by rr removed.");
                    }
                } else {
                    # SAMPLE: rr
                    # say("DEBUG: $who_am_i '$more_subobject' is for use by rr.");
                    # SAMPLE: /dev/shm/rqg/1653923445/3/1/rr
                    my $source = $more_subobject;
                    my $target = $more_object . "/" . $subobject;
                    # SAMPLE: /data/results/1653923445/3/1/rr
                    # The rr trace dir gets created no matter if we go with rr or not.
                    # Experimental:
                    if (not rmdir $source) {
                        # In case rr tracing was performed than this directory will be not empty.
                        # say("WARN: $who_am_i Removing '$source' failed : $!.");
                        # system("find $source -follow");
                    } else {
                        # say("DEBUG: $who_am_i Directory '$source' removed");
                        next;
                    }

                    if ($source eq $target) {
                        say("WARN: $who_am_i source equals the target '$target'. Omit moving data.");
                    } else {
                        if (STATUS_OK != Basics::move_dir_to_newdir($source, $target)) {
                            say("ERROR: $who_am_i Logical move '$source' to '$target' failed.");
                            return STATUS_FAILURE;
                        }
                        # say("DEBUG: $who_am_i Logical move '$source' to '$target'.");
                    }

                }
                next;
            } else {
                say("ERROR: $who_am_i Object '$more_subobject' cannot be handled.");
                system("ls -ld $more_subobject");
                return STATUS_FAILURE;
            }

        }
        closedir(SUBDIR);
        # say("DEBUG: Finished processing of '$more_object'.");

        # Experimental:
        # SAMPLE: /dev/shm/rqg/1654789418/3/1
        if (not rmdir $final_path) {
            say("ERROR: $who_am_i Removing '$final_path' failed : $!.");
            # FIXME: Leftover rr subdir !!
            system("ls -ld $final_path/*");
            # Observation 2022-09-02 (rare)
            # Removing ..../rr failed because its not empty
            return STATUS_FAILURE;
        } else {
            # say("DEBUG: $who_am_i Directory '$final_path' removed");
        }
    }
    closedir(TOPDIR);

    my $name_of_worker = File::Basename::basename($workdir);
    foreach my $tree (Local::get_rqg_fast_dir . "/" . $name_of_worker,
                      Local::get_rqg_slow_dir . "/" . $name_of_worker) {
        # In case the call of rqg.pl fails because of unknown parameter or
        # wrong value assigned than these trees will not exist.
        if(STATUS_OK != Basics::conditional_remove_dir($tree)) {
            say("ERROR: $who_am_i Removal of the tree '$tree' failed. : $!.");
            return STATUS_FAILURE;
        }
    }
    # system("find $workdir -follow | xargs ls -ld");
    tweak_permissions($workdir);

    # say("DEBUG: $who_am_i ---------- end");

    return STATUS_OK;
}


sub clean_workdir {
# Use case:
# A RQG worker (child forked by rqg_batch.pl) has
# 1. performed an RQG run (rqg.pl) via system
# 2. generated a verdict via system and the verdict is ignore*
# now to
# - preserve a few important files like the log of the RQG run (rqg.log)
# - clean up anything else.
# FIXME: Compare with "clean_workdir" and remove weaknesses.
#
    my $who_am_i = Basics::who_am_i();

    my ($workdir) = @_;
    if (not -d $workdir) {
        say("ERROR: $who_am_i RQG workdir '$workdir' is missing or not a directory.");
        return STATUS_FAILURE;
    }
    # system("find $workdir -follow | xargs ls -ld");

    # Free a lot storage space first.
    my $name_of_worker = File::Basename::basename($workdir);
    foreach my $tree (Local::get_rqg_fast_dir . "/" . $name_of_worker,
                      Local::get_rqg_slow_dir . "/" . $name_of_worker) {
        # In case the call of rqg.pl fails because of unknown parameter or
        # wrong value assigned than these trees will not exist.
        if(STATUS_OK != Basics::conditional_remove_dir($tree)) {
            say("ERROR: $who_am_i Removal of the tree '$tree' failed. : $!.");
            return STATUS_FAILURE;
        }
    }

    # SAMPLE: /data/results/1649954330/1
    if (not opendir(TOPDIR, $workdir)) {
        say("ERROR: $who_am_i Opening the directory '$workdir' failed: $!");
        return STATUS_FAILURE;
    }
    while( (my $object = readdir(TOPDIR))) {
        my $more_object = $workdir . "/" . $object;
        if ($object eq '.' or $object eq '..' or $object eq 'rqg.log' or
            $object =~ '^rqg_verdict\.' or $object =~ '^rqg_phase\.' ) {
            # say("DEBUG: $who_am_i '$more_object' is point object or an important file. Omitting");
            next;
        }
        if (-l $more_object or -f $more_object) {
            unlink($more_object);
            # say("DEBUG: $who_am_i $more_object (file or symlink) was removed.");
            next;
        }
        if (-d $more_object) {
            if (STATUS_OK != Basics::conditional_remove_dir($more_object)) {
                say("ERROR: $who_am_i removal of '$more_object' (directory) failed.");
                return STATUS_FAILURE;
            } else {
            #   say("DEBUG: $who_am_i '$more_object' (directory) was removed.");
            }
            next;
        }
        say("ALARM: $who_am_i Meeting unexpected objects.");
        # say("DEBUG: $who_am_i Checking ---------- $more_object\n");
        # describe_object($more_object);
        if (-d $more_object) {
            # say("DEBUG: $who_am_i '$more_object' is directory or symlink to directory.");
            if (not rmdir($more_object)) {
                say("ERROR: $who_am_i Removing '$more_object' (directory or symlink to directory) failed: $!");
                return STATUS_FAILURE;
            } else {
                # say("DEBUG: $who_am_i '$more_object' (directory or symlink to directory) was removed.");
            }
        } else {
            next;
        }
        my $final_path;
        if (-l $more_object) {
            # SAMPLE: /data/results/1651147111/1/1 -> /dev/shm/rqg/1651147111/1/1
            $final_path = Cwd::abs_path($more_object);
            if (not -d $final_path) {
                unlink($more_object);
                # say("DEBUG: $who_am_i Symlink '$more_object' pointing to not existing directory deleted.");
                next;
            } else {
                unlink($more_object);
                if (STATUS_OK != Basics::make_dir($more_object)) {
                    say("ERROR: $who_am_i Removing '$more_object' (directory or symlink to directory) failed: $!");
                    return STATUS_FAILURE;
                }
                # say("DEBUG: $who_am_i Symlink '$more_object' deleted and as directory recreated.");
            }
        } else {
            $final_path = $more_object;
        }

        # SAMPLE: /dev/shm/rqg/1651156052/1/1
        if (not opendir(SUBDIR, $final_path)) {
            say("ERROR: $who_am_i Opening the directory '$final_path' failed: $!");
            return STATUS_FAILURE;
        }
        while( (my $subobject = readdir(SUBDIR))) {
            my $more_subobject = $more_object . "/" . $subobject;
            # say("DEBUG: $who_am_i Checking ---------- $more_subobject\n");
            # describe_object($more_subobject);
            # SAMPLE: /data/results/1649954330/1/1/rr
            if ($subobject ne 'rr' and -l $more_subobject and -d $more_subobject) {
                # say("DEBUG: $who_am_i '$more_subobject' is a symlink pointing to a directory " .
                #     "and not for use by rr.");
                my $abs_object = Cwd::abs_path($more_subobject);
                unlink($more_subobject);
                if (STATUS_OK != Basics::remove_dir($abs_object)) {
                    return STATUS_FAILURE;
                }
                # say("DEBUG: $who_am_i Symlink '$more_subobject' pointing to tree " .
                #     "'$abs_object' including that tree removed.");
            }
            if ($subobject eq 'rr') {
                # say("DEBUG: $who_am_i '$more_subobject' is for use by rr.");
                # SAMPLE: /dev/shm/rqg/1651156052/1/1/rr
                my $source = $final_path . "/rr";
                # SAMPLE: /data/results/1651156052/1/1/rr
                my $target = Cwd::abs_path($more_subobject);
                if (STATUS_OK != Basics::move_dir_to_newdir($source, $target)) {
                    Carp::cluck("ERROR: Logical move '$source' to '$target' failed.");
                    return STATUS_FAILURE;
                }
            }

        }
        closedir(SUBDIR);
        # say("DEBUG: Finished processing of '$more_object'.");

    }
    closedir(TOPDIR);
    # say("DEBUG: Finished processing of '$workdir'.");

    # system("find $workdir -follow | xargs ls -ld");

    return STATUS_OK;
}


sub make_dbs_dirs {
# Build the infrastructure (storage area) required for on DB server.
    my ($vardir) = @_;

    # say("DEBUG: In make_dbs_dirs for ->$vardir<-");

    # Lets assume vardir is    /data/results/SINGLE_RQG/1
    # and what we need is the '1' at the end.
    my $name_for_dbs = File::Basename::basename($vardir);
    # FIXME: Implement or correct comment.
    # If
    # - '' than it should already exist.
    # - '<number>' or <1_clone> than it + symlink should be created.
    # say("DEBUG: name_for_dbs '$name_for_dbs'.");
    if ($name_for_dbs eq '') {
        say("ERROR: name_for_dbs '' caught");
        return STATUS_INTERNAL_ERROR;
    }

    if (STATUS_OK != remove_dbs_dirs($vardir)) {
        say("ERROR: remove_dbs_dirs('$vardir') failed.");
        return STATUS_FAILURE;
    }

    # Storage area for objects like
    # - mysql.err , mysql.log, boot.log,
    # - rr traces and backups of files/directories
    # All time tmpfs or similar. Hence $dbdir_fast can already exist. ?????????
    my $dbdir_fast = Local::get_rqg_fast_dir . "/" . $name_for_dbs;
    if (STATUS_OK != Basics::conditional_make_dir($dbdir_fast)) {
        return STATUS_FAILURE;
    }
    if (STATUS_OK != Basics::symlink_dir($dbdir_fast, $vardir)) {
        return STATUS_INTERNAL_ERROR;
    }
    foreach my $sub_dir ("/rr", "/fbackup") {
        my $extra_dir = $dbdir_fast . $sub_dir;
        if (STATUS_OK != Basics::make_dir($extra_dir)) {
            return STATUS_FAILURE;
        }
    }

    # Storage area for objects like
    # data and tmp dir of the dbserver
    my $dbdir = Local::get_dbdir() . "/" . $name_for_dbs;
    if (not -d $dbdir) {
        if (STATUS_OK != Basics::make_dir($dbdir)) {
            return STATUS_FAILURE;
        }
    }
    foreach my $sub_dir ("/data", "/tmp") {
        my $extra_dir = $dbdir . $sub_dir;
        if (STATUS_OK != Basics::make_dir($extra_dir)) {
            return STATUS_FAILURE;
        }
        my $symlink = $vardir . $sub_dir;
        if (not -d $symlink) {
            if (STATUS_OK != Basics::symlink_dir($extra_dir, $symlink)) {
                return STATUS_INTERNAL_ERROR;
            }
        }
    }

    return STATUS_OK;
}

sub remove_dbs_dirs {
# Remove the infrastructure (storage area) required for one DB server.
# Hint:
# RQG testing related files like rqg.log or an archive will be not affected
# except objects are placed wrong.
    my ($vardir) = @_;

    # say("DEBUG: In make_dbs_dirs for ->$vardir<-");

    # Lets assume vardir is    /data/results/SINGLE_RQG/1
    # and what we need is the '1' at the end.
    my $name_for_dbs = File::Basename::basename($vardir);
    # FIXME: Implement or correct comment.
    # If
    # - '' than it should already exist.
    # - '<number>' or <1_clone> than it + symlink should be created.
    # say("DEBUG: name_for_dbs '$name_for_dbs'.");
    if ($name_for_dbs eq '') {
        say("ERROR: name_for_dbs '' caught");
        return STATUS_INTERNAL_ERROR;
    }

    if (STATUS_OK != Basics::conditional_remove_dir($vardir)) {
        return STATUS_FAILURE;
    }

    # Storage area for objects like
    # - mysql.err , mysql.log, boot.log,
    # - rr traces and backups of files/directories
    my $dbdir_fast = Local::get_rqg_fast_dir . "/" . $name_for_dbs;
    if (STATUS_OK != Basics::conditional_remove_dir($dbdir_fast)) {
        return STATUS_FAILURE;
    }

    # Storage area for objects like
    # data and tmp dir of the dbserver
    my $dbdir = Local::get_dbdir() . "/" . $name_for_dbs;
    if (STATUS_OK != Basics::conditional_remove_dir($dbdir)) {
        return STATUS_FAILURE;
    }

    return STATUS_OK;
}

1;

