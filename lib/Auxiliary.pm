#  Copyright (c) 2018, 2020 MariaDB Corporation Ab.
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
#   lib/GenTest.pm, lib/DBServer/DBServer.pm, maybe more.
#   There are various duplicate routines like sayFile, tmpdir, ....
# - search for string (pid or whatever) after pattern before line end in some file
# - move too MariaDB/MySQL specific properties/settings out
# It looks like Cwd::abs_path "cleans" ugly looking paths with superfluous
# slashes etc.. Check closer and use more often.
#


use strict;
use GenTest::Constants;
use GenTest;
use GenTest::Grammar;
use File::Copy;
use Cwd;

# use constant STATUS_OK         => 0;
use constant STATUS_FAILURE      => 1; # Just the opposite of STATUS_OK
use constant INTERNAL_TOOL_ERROR => 200;


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
        Carp::cluck("INTERNAL ERROR: script_debug_init : 1 Parameter (script_debug) is required.");
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
        exit INTERNAL_TOOL_ERROR;
    }
    if (not defined $script_debug_init) {
        Carp::cluck("INTERNAL ERROR: script debug was not initialized.");
        exit INTERNAL_TOOL_ERROR;
    }
    $pattern = '_' . $pattern . '_';
    if (($script_debug_value =~ /$pattern/) or ($script_debug_value eq '_all_')) {
        return 1;
    } else {
        return 0;
    }
}

our $rqg_home;
sub check_and_set_rqg_home {
    ($rqg_home) = @_;
    if (1 != scalar @_) {
        Carp::cluck("INTERNAL ERROR: Exact one parameter(rqg_home) needs to get assigned.");
        exit INTERNAL_TOOL_ERROR;
    } else {
        if (not defined $rqg_home) {
            Carp::cluck("INTERNAL ERROR: The value for rqg_home is undef.");
            exit INTERNAL_TOOL_ERROR;
        } else {
            if (not -d $rqg_home) {
                Carp::cluck("INTERNAL ERROR: rqg_home($rqg_home) does not exist or is not a directory.");
                exit INTERNAL_TOOL_ERROR;
            }
        }
    }
    say("DEBUG: rqg_home set to ->$rqg_home<-");
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
# INTERNAL_TOOL_ERROR -- Looks like error in RQG code
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
      return INTERNAL_TOOL_ERROR;
   }
   if (not defined $value_list_ref) {
      Carp::cluck("INTERNAL ERROR: The value_list is not defined.");
      return INTERNAL_TOOL_ERROR;
   }
   if (not defined $assigned_value or $assigned_value eq '') {
      Carp::cluck("ERROR: The value assigned to the parameter '$parameter' is not defined.");
      # ??? This might be also a error in the test config. -> User error
      return INTERNAL_TOOL_ERROR;
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


sub append_string_to_file {

    my ($my_file, $my_string) = @_;
    if (not defined $my_file) {
        Carp::cluck("INTERNAL ERROR: The value for the file name is undef.");
        return STATUS_FAILURE;
    }
    if (not defined $my_string) {
        Carp::cluck("INTERNAL ERROR: The string to be appended to the file '$my_file' is undef.");
        return STATUS_FAILURE;
    }
    if (not -f $my_file) {
        Carp::cluck("INTERNAL ERROR: The file '$my_file' does not exist or is no plain file.");
        return STATUS_FAILURE;
    }
    if (not open (MY_FILE, '>>', $my_file)) {
        say("ERROR: Open file '>>$my_file' failed : $!");
        return STATUS_FAILURE;
    }
    if (not print MY_FILE $my_string) {
        say("ERROR: Print to file '$my_file' failed : $!");
        return STATUS_FAILURE;
    }
    if (not close (MY_FILE)) {
        say("ERROR: Close file '$my_file' failed : $!");
        return STATUS_FAILURE;
    }
    return STATUS_OK;
}


sub make_file {
#
# Purpose
# -------
# Make a plain file.
#
# Return values
# -------------
# STATUS_OK      -- Success
# STATUS_FAILURE -- No success
#
    my ($my_file, $my_string) = @_;
    if (not open (MY_FILE, '>', $my_file)) {
        say("ERROR: Open file '>$my_file' failed : $!");
        return STATUS_FAILURE;
    }
    if (defined $my_string) {
        if (not print MY_FILE $my_string . "\n") {
            say("ERROR: Print to file '$my_file' failed : $!");
            return STATUS_FAILURE;
        }
    }
    if (not close (MY_FILE)) {
        say("ERROR: Close file '$my_file' failed : $!");
        return STATUS_FAILURE;
    }
    return STATUS_OK; # 0
}


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
    # say("DEBUG: Auxiliary::make_rqg_infrastructure workdir is '$workdir'");
    $workdir = Cwd::abs_path($workdir);
    if (not -d $workdir) {
        say("ERROR: RQG workdir '$workdir' is missing or not a directory.");
        return STATUS_FAILURE;
    }
    my $my_file;
    my $result;
    $my_file = $workdir . '/rqg.log';
    $result  = make_file ($my_file, undef);
    return $result if $result;
    $my_file = $workdir . '/rqg_phase.init';
    $result  = make_file ($my_file, undef);
    return $result if $result;
    $my_file = $workdir . '/rqg.job';
    $result  = make_file ($my_file, undef);
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
    say("DEBUG: We searched at various places below '$basedirectory' but '$name' was not found. " .
        "Will return undef.");
    return undef;
}


sub rename_file {
#
# Purpose
# -------
# Just rename a file.
# I hope that the operation within the filesystem is roughly atomic especially compared to
# writing into some file.
#
# Typical use case
# ----------------
# Signal the current phase of the RQG run and the final verdict.
#
# # Return values
# -------------
# STATUS_OK      -- Success
# STATUS_FAILURE -- No success
#

    my ($source_file, $target_file) = @_;
    if (not -e $source_file) {
        Carp::cluck("ERROR: The source file '$source_file' does not exist.");
        return STATUS_FAILURE;
    }
    if (-e $target_file) {
        Carp::cluck("ERROR: The target file '$target_file' does already exist.");
        return STATUS_FAILURE;
    }
    # Perl documentation claims that
    # - "File::Copy::move" is platform independent
    # - "rename" is not and might have probems accross filesystem boundaries etc.
    if (not move ($source_file , $target_file)) {
        # The move operation failed.
        Carp::cluck("ERROR: Copying '$source_file' to '$target_file' failed : $!");
        return STATUS_FAILURE;
    } else {
        say("DEBUG: Auxiliary::rename_file '$source_file' to '$target_file'.") if script_debug("A5");
        return STATUS_OK;
    }
}


sub copy_file {
# Typical use case
# ----------------
# One grammar replayed the desired outcome and we copy its to or over the best grammar ever had.
#   my $source = $workdir . "/" . $grammar_used;
#   my $target = $workdir . "/" . $best_grammar;

    my ($source_file, $target_file) = @_;
    if (not -e $source_file) {
        Carp::cluck("ERROR: The source file '$source_file' does not exist.");
        return STATUS_FAILURE;
    }
    if (not File::Copy::copy($source_file, $target_file)) {
        Carp::cluck("ERROR: Copying '$source_file' to '$target_file' failed : $!");
        return STATUS_FAILURE;
    } else {
        say("DEBUG: Auxiliary::copy_file '$source_file' to '$target_file'.") if script_debug("A5");
        return STATUS_OK;
    }
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
   # Set by RQG tool or extended RQG runner when running black white list matching.
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

    $result = Auxiliary::rename_file ($workdir . '/rqg_phase.' . $old_phase,
                                      $workdir . '/rqg_phase.' . $new_phase);
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
# See also the black and white list matching in Verdict.pm.
#
# The pattern list was empty.
# Example:
#    blacklist_statuses are not defined.
#    == We focus on blacklist_patterns only.
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
# 1. whitelist_statuses has an element with STATUS_SERVER_CRASHED and the RQG(GenTest) run
#    finished with that status.
# 2. whitelist_patterns has an element with '<signal handler called>' and the RQG log contains a
#    snip of a backtrace with that.
use constant MATCH_YES             => 'match_yes';
#
# The pattern list was not empty, none of the elements matched and nothing looks
# interesting at all.
# Example:
#    whitelist_statuses has an element with STATUS_SERVER_CRASHED and the RQG(GenTest) run
#    finished with some other status. But this other status is STATUS_OK.
use constant MATCH_NO              => 'match_no';
#
# The pattern list was not empty, none of the elements matched but the outcome looks interesting.
# Example:
#    whitelist_statuses has only one element like STATUS_SERVER_CRASHED and the RQG(GenTest) run
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
#    Whitelist matching : MATCH_NO_LIST_EMPTY -> MATCH_YES
#    Blacklist matching : MATCH_NO_LIST_EMPTY -> MATCH_NO
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
#    Whitelist matching : MATCH_NO_LIST_EMPTY -> MATCH_YES
#    Blacklist matching : MATCH_NO_LIST_EMPTY -> MATCH_NO
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
           return MATCH_YES, join(" , ", @match_info);
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
# $pattern_list           | List of pattern to search for within the text.
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
#    Whitelist matching : MATCH_NO_LIST_EMPTY -> MATCH_YES
#    Blacklist matching : MATCH_NO_LIST_EMPTY -> MATCH_NO
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
# - up to $search_var_size bytes read from the end of the file $file_to_read
# - '' if nothing found
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
    my  $cmd = "git --version 2>&1";
    my $return = `$cmd`;
    my $rc = $?;
    if ($rc == -1) {
        say("WARNING: '$cmd' failed to execute: $!");
        $git_supported = 0;
        return STATUS_OK;
    } elsif ($rc & 127) {
        say("WARNING: '$cmd' died with signal " . ($rc & 127));
        $git_supported = 0;
        return STATUS_ENVIRONMENT_FAILURE;
    } elsif (($rc >> 8) != 0) {
        say("WARNING: '$cmd' exited with value " . ($rc >> 8));
        $git_supported = 0;
        return STATUS_INTERNAL_ERROR;
    } else {
        say("DEBUG: '$cmd' exited with value " . ($rc >> 8));
        $git_supported = 1;
        return STATUS_OK;
    }
}


sub get_git_info {

    my ($directory, $parameter_name) = @_;

    if (not defined $directory) {
        # Ok, we are this time tolerant because $basedirs[2] etc. could be undef.
        return STATUS_OK;
    }
    if (not -e $directory) {
        say("ERROR: Auxiliary::get_git_info : The assigned '$directory' does not exist. " .
            "Will return STATUS_INTERNAL_ERROR");
        return STATUS_INTERNAL_ERROR;
    }
    if (not -d $directory) {
        say("ERROR: Auxiliary::get_git_info : The assigned '$directory' is not a directory. " .
            "Will return STATUS_INTERNAL_ERROR");
        return STATUS_INTERNAL_ERROR;
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
            "       Will return STATUS_ENVIRONMENT_FAILURE");
        return STATUS_ENVIRONMENT_FAILURE;
    }

    # git show --pretty='format:%D %H  %cI' -s
    # HEAD -> experimental, origin/experimental ce3c84fc53216162ef8cc9fdcce7aed24887e305  2018-05-04T12:39:45+02:00
    # %s would show the title of the last commit but that could be longer than wanted.
    my $cmd = "git show --pretty='format:%D %H %cI' -s 2>&1";
    my $val= `$cmd`;
    say("INFO: GIT on $parameter_name('$directory') $val");

    if (not chdir($cwd)) {
        say("ALARM: chdir to '$cwd' failed with : $!\n" .
            "       Will return STATUS_ENVIRONMENT_FAILURE");
        return STATUS_ENVIRONMENT_FAILURE;
    }

    return STATUS_OK;

    # Note:
    # The output for a directory not under control of git like
    #    Auxiliary::get_git_info('/', 'ROOT')   is
    #    ROOT('/') fatal: Not a git repository (or any of the parent directories): .git
    # and we should be able to live with that.

} # End sub get_git_info


sub get_basedir_info {

    my ($directory, $parameter_name) = @_;

    my $cmd;             # For commands run through system ...

    if (not defined $directory) {
        # Ok, we are this time tolerant because $basedirs[2] etc. could be undef.
        return STATUS_OK;
    }
    if (not -e $directory) {
        say("ERROR: Auxiliary::get_git_info : The assigned '$directory' does not exist. " .
            "Will return STATUS_INTERNAL_ERROR");
        return STATUS_INTERNAL_ERROR;
    }
    if (not -d $directory) {
        say("ERROR: Auxiliary::get_git_info : The assigned '$directory' is not a directory. " .
            "Will return STATUS_INTERNAL_ERROR");
        return STATUS_INTERNAL_ERROR;
    }

    my $cwd = Cwd::cwd();
    if (not chdir($directory))
    {
        say("ALARM: chdir to '$directory' failed with : $!\n" .
            "       Will return STATUS_ENVIRONMENT_FAILURE");
        return STATUS_ENVIRONMENT_FAILURE;
    }
    my $status = get_git_info($directory, $parameter_name);
    if (not chdir($cwd)) {
        say("ALARM: chdir to '$cwd' failed with : $!\n" .
            "       Will return STATUS_ENVIRONMENT_FAILURE");
        return STATUS_ENVIRONMENT_FAILURE;
    }

    my $build_prt = $directory . "/build.prt";
    if (-f $build_prt) {
        say("INFO: Protocol of build '$build_prt' detected. Extracting some data ...");
        my $val= Auxiliary::get_scrap_after_pattern($build_prt, 'GIT_SHOW: ');
        if (not defined $val) {
            return STATUS_ENVIRONMENT_FAILURE;
        } elsif ('' eq $val) {
            # No such string found. So do nothing
        } else {
            say("GIT_SHOW: $val");
        }
        # MD5SUM of bin_arch.tgz:
        my $md5_sum = Auxiliary::get_string_after_pattern($build_prt, "MD5SUM of bin_arch.tgz: ");
        say("MD5SUM of bin_arch.tgz: $md5_sum");
    } else {
        say("INFO: No protocol of build '$build_prt' found.");
    }

    return STATUS_OK;

} # End sub get_basedir_info


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
    my $cmd = "du -sk $directory | cut -f1";
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
        say("DEBUG: '$cmd' exited with value " . ($? >> 8));
        chomp $return; # Remove the '\n' at end.
        return $return;
    }
}

####################################################################################################

sub archive_results {

# FIXME:
# There seems to be no GNU tar for WIN. :(

    my ($workdir, $vardir) = @_;
    if (not -d $workdir) {
        say("ERROR: RQG workdir '$workdir' is missing or not a directory.");
        return STATUS_FAILURE;
    }
    if (not -d $vardir) {
        say("ERROR: RQG vardir '$vardir' is missing or not a directory.");
        return STATUS_FAILURE;
    }
    # Maybe check if some of the all time required/used files exist in order to be sure to have
    # picked the right directory.
    # We make a "cd $workdir"   first!
    my $archive     = $workdir . "/archive.tgz";
    my $archive_err = $workdir . "/rqg_arch.err";
    my $cmd;
    my $rc;
    my $status;
    $cmd  = "cd $workdir 2>rqg_arch.err";
    $cmd .= "; find rqg* $vardir         -print0 | xargs --null chmod g+rw  2>>$archive_err";
    # Even though using umask 002 the directories data/mysql and data/test lack often the 'x'.
    $cmd .= "; find rqg* $vardir -type d -print0 | xargs --null chmod g+x 2>>$archive_err";
    say("DEBUG: cmd : ->$cmd<-") if script_debug("A5");
    $rc = system($cmd);
    if ($rc != 0) {
        say("ERROR: Preparation for archiving '$cmd' failed with exit status " . ($? >> 8));
        sayFile($archive_err);
        return STATUS_FAILURE;
    }

    # FIXME/DECIDE:
    # - Use the GNU tar long options because the describe better what is done
    # h           --> --dereference     sql/mysqld is a symlink pointing on sql/mariadbd
    # c           --> --create
    # f <archive> --> --file <archive>
    # Whereas dereference looks "attractive"
    # - because it would materialize symlinks like sql/mysqld pointing on sql/mariadbd
    #   Fortunately mysqld/mariadbd does not need to get archived here.
    # its is rather fatal in the region of archiving rr traces
    #   because last_trace pointing to some mysqld-<n> which we archive too
    #   would get materialized.
    # Failing cmd for experimenting
    # $cmd = "cd $workdir ; tar csf $archive rqg* $vardir 2>$archive_err";
    #
    # Some thoughts about why not prepending a nice -19 to the tar command.
    # ---------------------------------------------------------------------
    # 1. Less elapsed time for tar with compression means shorter remaining lifetime for the
    #    voluminous data on vardir. The latter is usual on fast storage like tmpfs with
    #    limited storage space. And it is frequent a bottleneck for increasing the load.
    # 2. Not using nice -19 for some auxiliary task like archiving means also less CPU for
    #    for RQG runner, especially involved DB server. This increases the time required
    #    for any work phase. And that makes more capable to reveal phases where locks or
    #    similar are missing or wrong handled.
    $cmd = "cd $workdir 2>>$archive_err; tar czf $archive rqg* $vardir 2>>$archive_err";
    say("DEBUG: cmd : ->$cmd<-") if script_debug("A5");
    $rc = system($cmd);
    if ($rc != 0) {
        say("ERROR: The command for archiving '$cmd' failed with exit status " . ($? >> 8));
        sayFile($archive_err);
        return STATUS_FAILURE;
    } else {
        $status = STATUS_OK;
    }
    # We could get $archive_err even in case of archiver success because it might contain
    # messages like 'tar: Removing leading `/' from member names' etc.
    sayFile($archive_err) if script_debug("A5");
    unlink $archive_err;
    return STATUS_OK;
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

# get_run_id
# ==========
#
# Purpose
# -------
# Get a most probably unique id to be used for the vardirs and workdirs of RQG tools.
# In case all these tools call the current routine and use that id for the computation of their
# own workdirs and vardirs than collisions of the RQG runs managed with historic and concurrent
# RQG runs should be impossible within these directories.
# Of course neither the collisions on ports nor overuse of resources could be prevented by that.
#
# Number of seconds since the Epoch, 1970-01-01 00:00:00 +0000 (UTC) has many advantages
# because the time is monotonically increasing.
# The "sleep 1" is for the unlikely but in reality (unit tests etc.) met case that some run of
# the same or another RQG tool started and failed less than a second before.
# And so both runs calculated the same value.
#
sub get_run_id {
    sleep 1;
    return time();
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
# lib/GenTest/Constants.pm contains
# use constant DEFAULT_MTR_BUILD_THREAD          => 930; ## Legacy...
#

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
        $gendata = $rqg_home . "/" . $gendata if not $gendata =~ m {^/};
        # We run gendata with a ZZ grammar. So the value in $gendata is a file which must exist.
        if (not -f $gendata) {
            sayError("The file '$gendata' assigned to gendata does not exist or is no plain file.");
            # return undef;
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
            $file = $rqg_home . "/" . $file if not $file =~ m {^/};
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
                $file = $rqg_home . "/" . $file if not $file =~ m {^/};
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
                                Auxiliary::append_string_to_file($gendata_sql_file, $content)) {
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
            $file = $rqg_home . "/" . $file if not $file =~ m {^/};
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
                $file = $rqg_home . "/" . $file if not $file =~ m {^/};
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
                                Auxiliary::append_string_to_file($redefine_file, $content)) {
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
        $grammar_file = $rqg_home . "/" . $grammar_file if not $grammar_file =~ m {^/};
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

    my $grammar_obj = GenTest::Grammar->new(
        grammar_files => [ $grammar_file, ( @redefine_files ) ],
        grammar_flags => (defined $skip_recursive_rules ? GenTest::Grammar::GRAMMAR_FLAG_SKIP_RECURSIVE_RULES : undef )
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
            #   Auxiliary::make_file('k1', $grammar1);
            #   Auxiliary::make_file('k2', $grammar2);
            $grammar_obj          = $final_grammar_obj;
        }
    }
    my $grammar_string = $grammar_obj->toString;
    $grammar_file = $workdir . "/rqg.yy";
    if (STATUS_OK != Auxiliary::make_file($grammar_file, $grammar_string)) {
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
# - In case there is one element only and that consists of a comma separated list of sub elements
#   than split this list at the comma and make the sub elements to elements.
# - Eliminate duplicates.
# - Replace the value '' by 'None'.
# Return pointers to an array/list and to a hash with the final content.
#

    my ($rvt_array_ref) = @_;
    if (@_ != 1) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: unify_rvt_array : 1 Parameter (rvt_array_ref) is required.");
        safe_exit($status);
    }
    my @rvt_array;
    my %rvt_hash;
    if (defined $rvt_array_ref) {
        @rvt_array = @$rvt_array_ref;
        # In case of assignment style
        #    --reporter=Backtrace,ErrorLog <never --reporter=... again>
        # split at ',' into elements.
        if (0 == $#rvt_array and $rvt_array[0] =~ m/,/) {
            @rvt_array = split(/,/,$rvt_array[0]);
        }
    }
    foreach my $element (@rvt_array) {
        $element = "None" if $element eq '';
        $rvt_hash{$element} = 1;
    }
    @rvt_array = sort keys %rvt_hash;

    return \@rvt_array, \%rvt_hash;
}

# -----------------------------------------------------------------------------------
sub check_filter {
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

    $filter = $rqg_home . "/" . $filter if not $filter =~ m {^/};
    # It is very unlikey that a duplicate $workdir/rqg.ff makes sense.
    if (not -f $filter) {
        sayError("The file '$filter' assigned to --filter does not exist or is no plain file." .
                 " Will return undef.");
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
    } else {
        # say("DEBUG: which $command returned ->" . $return . "<-");
        return STATUS_OK;
    }
}


# Support for rr (https://rr-project.org/, https://github.com/mozilla/rr)
# -----------------------------------------------------------------------
# RR tracing variants
use constant RR_TYPE_DEFAULT            => 'Server';
use constant RR_TYPE_SERVER             => 'Server';
use constant RR_TYPE_EXTENDED           => 'Extended';
use constant RR_TYPE_RQG                => 'RQG';

use constant RR_TYPE_ALLOWED_VALUE_LIST => [
      RR_TYPE_SERVER, RR_TYPE_EXTENDED, RR_TYPE_RQG,
   ];

sub help_rr {
    print(
"HELP: About how and when to invoke the tool 'rr' (https://rr-project.org/)\n"                     .
"      --rr           Get the default which is '" . RR_TYPE_DEFAULT . "'.\n"                       .
"      --rr=" . RR_TYPE_SERVER . "\n"                                                              .
"           Supported by 'rqg_batch.pl' which passes this setting through to the RQG runner\n"     .
"           'rqg.pl'. No pass through to other RQG runners.\n"                                     .
"           Support by RQG runners: 'rqg.pl' only.\n"                                              .
"           Any start of a regular DBServer will be done by 'rr record .... mysqld ...'.\n"        .
"           Serious advantage: Small 'rr' traces like ~ 30 till 40 MB\n"                           .
"           Disadvantages:\n"                                                                      .
"           - No tracing of bootstrap, mariabackup or other processes being maybe of interest.\n"  .
"           - Interweaving of events in different traced processes not good visible.\n"            .
"      --rr=" . RR_TYPE_EXTENDED . "\n"                                                            .
"           Supported by 'rqg_batch.pl' which passes this setting through to the RQG runner\n"     .
"           'rqg.pl'. No pass through to other RQG runners as long as the do not support it.\n"    .
"           Any start of some essential program will be done by 'rr record ....'.\n"               .
"              Bootstrap, server starts, soon mariabackup --prepare ... .\n"                       .
"           Advantages:\n"                                                                         .
"           - Smaller 'rr' traces than with --rr=" . RR_TYPE_RQG . " ?? MB\n"                      .
"           - Cover more essential programs\n"                                                     .
"           Disadvantages:\n"                                                                      .
"           - No tracing of other processes being maybe of interest too.\n"                        .
"           - Interweaving of events in different traced processes not good visible.\n"            .
"      --rr=" . RR_TYPE_RQG . "\n"                                                                 .
"           Supported by 'rqg_batch.pl' only.\n"                                                   .
"           Call of the RQG runner like 'rr record perl <RQG runner> ...'.\n"                      .
"           Hence we get 'rr' tracing of that perl process and all his children etc.\n"            .
"           Advantages:\n"                                                                         .
"           - All processes being maybe of interest get traced.\n"                                 .
"             Good for: MariaDB replication, Galera, Mariabackup, certain RQG reporters\n"         .
"           - Interweaving of events in different processes will be good visible.\n"               .
"           - It works probably well for RQG runner != 'rqg.pl'.\n"                                .
"           Serious disadvantage: Huge 'rr' traces like 2.5 TB.\n"                                 .
"      Rules of thumb if assigning '--rr=" . RR_TYPE_RQG . "' to rqg_batch.pl\n"                   .
"      - Do that only if being sure to replay some bad effect with a few RQG runs only.\n"         .
"      - For the case that this does not hold because of whatever reason\n"                        .
"        - Assign an upper limit (--trials) for the number of RQG runs.\n"                         .
"        - Let rqg_batch.pl stop (--stop_on_replay) as soon as the first replay happened.\n"       .
"        - Have a config file with a corresponding huge amount of blacklist patterns.\n"           .
"          Blacklisted results will not get archived.\n"                                           .
"        - Observe the ongoing RQG runs and stop them in case too many archives get generated.\n"  .
"      - Avoid having rqg_batch.pl/rqg.pl vardirs located on a SSD and also paging to SSD.\n"      .
"      rqg_batch.pl --trials=<small number> --stop_on_replay <more options>.\n"                    .
"      Warnings if assigning '--rr=" . RR_TYPE_RQG . "' to rqg_batch.pl\n"                         .
"      1. 3000 RQG runs means ~ 7.5 TB 'rr' trace get written in the RQG vardir even if the\n"     .
"         results are not of interest and get not archived.\n"                                      .
"         And there will be a serious number of writes into server logs and data in addition.\n"   .
"         Hence vardirs on SSD are most probably dangerous for the lifetime of the SSD.\n"         .
"      2. Even having the vardirs on RAM based tmpfs and moving only compressed archives of RQG\n" .
"         results of interest on SSD could be dangerous for that SSD.\n"                           .
"         'rr' traces are nearly not compressible.\n"                                              .
"         3000 RQG runs with 10% ending in generation of some archive mean ~ 0.75 TB written.\n"
    );
}

sub search_in_file {
# Return:
# undef - $search_file does not exist or is not readable
# 0     - $search_file is ok, $pattern not found
# 1     - $search_file is ok, $pattern found
    my ($search_file, $pattern) = @_;

    my $who_am_i = "Auxiliary::search_in_file:";
    if (not -e $search_file) {
        Carp::cluck("ERROR: $who_am_i The file '$search_file' is missing. Will return undef.");
        return undef;
    }
    if (not osWindows()) {
        system ("sync $search_file");
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
    my $fname = shift;
    my $who_am_i = "new_get_pid_from_file:";
    if (not open(PID, $fname)) {
        say("ERROR: $who_am_i Could not open pid file '$fname' for reading, " .
            "Will return undef");
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
        say("DEBUG: value for \$pid is empty string. Will return undef.");
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
    if (STATUS_OK == find_external_command('pstree')) {
        my $pstree = `pstree --show-pids $start_pid`;
        say($pstree);
    }
}


1;

