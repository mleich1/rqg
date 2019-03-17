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
# n > 1 -- les important and/or more frequent
# If admit that this
# - concept is rather experimental
# - the digits used in the modules rather arbitrary.
#
my %script_debug_hash;
my $script_debug_init;
sub script_debug_init {
    my ($script_debug_array_ref) = @_;
    if (@_ != 1) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: script_debug_init : 1 Parameter (script_debug_ref) is required.");
        safe_exit($status);
    }
    my @script_debug_array;
    if (defined $script_debug_array_ref) {
        @script_debug_array = @$script_debug_array_ref;
        if (0 == $#script_debug_array and $script_debug_array[0] =~ m/,/) {
            @script_debug_array = split(/,/,$script_debug_array[0]);
        }
    }
    foreach my $element (@script_debug_array) {
        if ($element eq '') {
            say("WARN: script_debug element '' omitted. In case you want all debug messages " .
                "assign '_all_'.");
            next;
        }
        $script_debug_hash{$element} = 1;
    }
    my $string = join(",", sort keys %script_debug_hash);
    say("INFO: script_debug : $string");
    $script_debug_init = 1;
    return $string;
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
    if (exists $script_debug_hash{'_all_'}) {
        return 1;
    } else {
        foreach my $sdp_element (keys %script_debug_hash) {
            if ($pattern =~ /$sdp_element/) { 
                return 1;
            }
        }
        return 0;
    }
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
# Make an plain file.
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
        if (not print MY_FILE $my_string) {
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
   say("DEBUG: We searched at various places below 'basedirectory' but '$name' was not found. " .
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
   # Set by RQG runner when checking the parameters etc.
   # RQG tool point of view:
   # - Up till now nothing important or valuable done. == Roughly no loss if stopped.
   # - Ressouce use of the runner is negligible. == Roughly no win if stopped.
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
   # - The storage space used by the remainings of the RQG run are minimal
   #   for the options given.
   #   Compressed archive + non compressed RQG log + a few small files.
   #   Data which could be freed was freed. (Especially destroy the vardir of the RQG runner).
   # - There is a verdict about the RQG run.
   # - To be done by the tool: Move these remainings to an appropriate directory.
   # - GenData + GenTest + ... done == Serious loss if stuff about a failing run gets thrown away.
# Notes about the wording used
# ----------------------------
# Resource use: Storage space (especially RQG vardir) + Virtual memory + current CPU load.
# Will killing this RQG runner including his DB servers etc. + throwing vardir and workdir away
# - free many currently occupied and usually critical resources -- "win if stopped"
# - destroy a lot historic investments                           -- "loss if stopped"
#      Here I mean: We invested CPU's/RAM/storage space not available for other stuff etc.
# Background:
# Some smart tool managing multiple RQG tests in parallel and one after the other should
# maximize how the available resources are exploited in order to minimize the time elapsed
# for one testing round. This leads to some serious increased risk to overload the available
# resources and to end up with valueless test results up till OS crash.
# So in case trouble on the testing box is just ahead (assume tmpfs full) or to be feared soon
# the smart tool might decide to stop certain RQG runs and to rerun them later.
#

use constant RQG_PHASE_ALLOWED_VALUE_LIST => [
      RQG_PHASE_INIT, RQG_PHASE_START, RQG_PHASE_START, RQG_PHASE_GENDATA, RQG_PHASE_GENTEST,
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
        if ($content =~ m{$pattern}s) {
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
# MATCH_UNKNOWN           | $pattern_prefix was not found.
# ('match_unknown)        |
# ------------------------+---------------------------------------------
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
            if ($content =~ m{$search_pattern}s) {
                if ($debug) { say("$message no match"); };
            } else {
                if ($debug) { say("$message match"); };
                $match   = 1;
            }
        } else {
            $search_pattern = $pattern_prefix . $pattern;
            $message = "$message_prefix, element '$search_pattern' :";
            if ($content =~ m{$search_pattern}s) {
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
        return MATCH_NO_LIST_EMPTY;
    } else {
        if ($match) {
            return MATCH_YES;
        } else {
            return MATCH_NO;
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

# -----------------------------------------------------------------------------------

my $git_supported;
sub get_git_info {

    my ($directory, $parameter_name) = @_;

    my $cmd;             # For commands run through system ...

    if (not defined $git_supported) {
        # For experimenting/debugging
        ## -> failed to execute
        # $cmd = "nogit --version 2>&1";
        ## -> exited with value 2
        # $cmd = "git --version 2>&1 > /";
        ## -> exited with value 129
        # $cmd = "git --caramba 2>&1";
        ## -> DEBUG: ... exited with value 0 but messages 'cannot open .... Permission denied'
        # $cmd = "fdisk -l 2>&1";
          $cmd = "git --version 2>&1";
        my $return = `$cmd`;
        if ($? == -1) {
            say("WARNING: '$cmd' failed to execute: $!");
            $git_supported = 0;
            return STATUS_FAILURE;
        } elsif ($? & 127) {
            say("WARNING: '$cmd' died with signal " . ($? & 127));
            $git_supported = 0;
            return STATUS_FAILURE;
        } elsif (($? >> 8) != 0) {
            say("WARNING: '$cmd' exited with value " . ($? >> 8));
            $git_supported = 0;
            return STATUS_FAILURE;
        } else {
            say("DEBUG: '$cmd' exited with value " . ($? >> 8));
            $git_supported = 1;
        }
    } elsif (0 == $git_supported) {
        return STATUS_FAILURE;
    }

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
    # git show --pretty='format:%D %H  %cI' -s
    # HEAD -> experimental, origin/experimental ce3c84fc53216162ef8cc9fdcce7aed24887e305  2018-05-04T12:39:45+02:00
    # %s would show the title of the last commit but that could be longer than wanted.
    $cmd = "git show --pretty='format:%D %H %cI' -s 2>&1";
    my $val= `$cmd`;
    say("GIT: $parameter_name('$directory') $val");
    chdir($cwd);
    return STATUS_OK;


    # Note:
    # The output for    Auxiliary::get_git_info1('/', 'ROOT')   is
    #    ROOT('/') fatal: Not a git repository (or any of the parent directories): .git
    # and we should be able to live with that.

} # End sub get_git_info


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
    # Maybe check if some of the all time required/used files exists in order to be sure to have
    # picked the right directory.
    # We make a   "cd $workdir"   first!
    my $archive     = "archive.tgz";
    my $archive_err = "rqg_arch.err";

    my $status;
    # FIXME/DECIDE:
    # - Use the GNU tar long options bacuse the describe better what is done
    # Failing cmd for experimenting
    # my $cmd = "cd $workdir ; tar csf $archive rqg* $vardir 2>$archive_err";

    my $cmd = "cd $workdir ; tar czf $archive rqg* $vardir 2>$archive_err";
    say("DEBUG: cmd : ->$cmd<-") if script_debug("A5");
    my $rc = system($cmd);
    if ($rc != 0) {
        say("ERROR: The command for archiving '$cmd' failed with exit status " . ($? >> 8));
        sayFile($archive_err);
        $status = STATUS_FAILURE;
    } else {
        $status = STATUS_OK;
    }
    # We could get $archive_err even in case of archiver success because it might contain
    # messages like 'tar: Removing leading `/' from member names' etc.
    unlink $archive_err;
    return $status;
}

sub help_rqg_home {
    print(
"HELP: About the RQG home directory used and the RQG tool/runner called.\n"                        .
"      In order to ensure the consistency of the RQG tool/runner called and the ingredients\n"     .
"      picked from the libraries only two variants for the call are supported.\n"                  .
"      a) The current working directory is whereever.\n"                                           .
"         The environment variable RQG_HOME is set and pointing to the top level directory\n"      .
"         of some RQG install.\n"                                                                  .
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

sub make_multi_runner_infrastructure {
#
# Purpose
# -------
# Make the infrastructure required by some RQG tool managing a batch of RQG runs.
# This is
# - the workdir
# - the vardir
# - a symlink pointing to the workdir
# of the current batch of RQG runs.
#
# Input values
# ------------
# $workdir    == The workdir of/for historic, current and future runs of RQG batches.
#                The workdir of the *current* RQG run will be created as subdirectory of this.
#                The name of the subdirectory is derived from $runid.
#                undef assigned: Use <current working directory of the process>/storage
# $vardir     == The vardir of/for historic, current and future runs of RQG batches.
#                The vardir of the *current* RQG run will be created as subdirectory of this.
#                The name of the subdirectory is derived from $runid.
#                Something assigned: Just get that
#                undef assigned: Use <workdir of the current batch run>/vardir
#                batch RQG run.
# $run_id     == value to be used for making the *current* workdir/vardir of the RQG batch run
#                unique in order to avoid clashes with historic, parallel or future runs.
#                undef assigned:
#                   Call Auxiliary::get_run_id and get
#                   Number of seconds since the Epoch, 1970-01-01 00:00:00 +0000 (UTC).
#                   This is recommended for users calling the RQG batch run tool manual or
#                   through home grown scripts.
#                something assigned:
#                   Just get that.
#                   The caller, usully some other RQG tool, has to take care that clashes with
#                   historic, parallel or future runs cannot happen.
# $symlink_name == Name of the symlink to be created within the current working directory of the
#                  process and pointing to the workder of the current RQG batch run.
#
# Return values
# -------------
# success -- $workdir, $vardir for the *current* RQG batch run
#            Being unable to create the symlink does not get valuated as failure.
# failure -- undef
#

    my ($general_workdir, $general_vardir, $run_id, $symlink_name) = @_;

    my $snip_all     = "for batches of RQG runs";
    my $snip_current = "for the current batch of RQG runs";

    $run_id = Auxiliary::get_run_id() if not defined $run_id;

    if (not defined $general_workdir or $general_workdir eq '') {
        $general_workdir = cwd() . '/rqg_workdirs';
        say("INFO: The general workdir $snip_all was not assigned. " .
            "Will use the default '$general_workdir'.");
    } else {
        $general_workdir = Cwd::abs_path($general_workdir);
    }
    if (not -d $general_workdir) {
        # In case there is a plain file with the name '$general_workdir' than we just fail in mkdir.
        if (mkdir $general_workdir) {
            say("DEBUG: The general workdir $snip_all '$general_workdir' " .
                "created.") if script_debug("A5");
        } else {
            say("ERROR: make_multi_runner_infrastructure : Creating the general workdir " .
                "$snip_all '$general_workdir' failed: $!. Will return undef.");
            return undef;
        }
    }

    my $workdir = $general_workdir . "/" . $run_id;
    # Note: In case there is already a directory '$workdir' than we just fail in mkdir.
    if (mkdir $workdir) {
        say("DEBUG: The workdir $snip_current '$workdir' created.") if script_debug("A5");
    } else {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Creating the workdir $snip_current '$workdir' failed: $!.\n " .
            "This directory must not exist in advance! " . Auxiliary::exit_status_text($status));
        safe_exit($status);
    }

    if (not defined $general_vardir or $general_vardir eq '') {
        $general_vardir = cwd() . '/rqg_vardirs';
        say("INFO: The general vardir $snip_all was not assigned. " .
            "Will use the default '$general_vardir'.");
    } else {
        $general_vardir = Cwd::abs_path($general_vardir);
    }
    if (not -d $general_vardir) {
        # In case there is a plain file with the name '$general_vardir' than we just fail in mkdir.
        if (mkdir $general_vardir) {
            say("DEBUG: The general vardir $snip_all '$general_vardir' created.") if script_debug("A5");
        } else {
            say("ERROR: make_multi_runner_infrastructure : Creating the general vardir " .
                "$snip_all '$general_vardir' failed: $!. Will return undef.");
            return undef;
        }
    }
    my $vardir = $general_vardir . "/" . $run_id;
    # Note: In case there is already a directory '$vardir' than we just fail in mkdir.
    if (mkdir $vardir) {
        say("DEBUG: The vardir $snip_current '$vardir' created.") if script_debug("A5");
    } else {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Creating the vardir $snip_current '$vardir' failed: $!.\n " .
            "This directory must not exist in advance! " . Auxiliary::exit_status_text($status));
        safe_exit($status);
    }

    # Convenience feature
    # -------------------
    # Make a symlink so that the last workdir used by some tool performing multiple RQG runs like
    #    combinations.pl, bughunt.pl, simplify_grammar.pl
    # is easier found.
    # Creating the symlink might fail on some OS (see perlport) but should not abort our run.
    unlink($symlink_name);
    my $symlink_exists = eval { symlink($workdir, $symlink_name) ; 1 };

    my $result_file  = $workdir . "/result.txt";
    if (STATUS_OK != Auxiliary::make_file($result_file, undef)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: Creating the result file '$result_file' failed. " .
            Auxiliary::exit_status_text($status));
        safe_exit($status);
    }
    say("DEBUG: The result (summary) file '$result_file' was created.") if script_debug("A5");

    # In case we have a combinations vardir without absolute path than ugly things happen:
    # Real life example:
    # vardir assigned to combinations.pl :
    #    comb_storage/1525794903
    # vardir planned by combinations.pl for the RQG test and created if required
    #    comb_storage/1525794903/current_1
    # vardir1 computed by combinations.pl for the first server + assigned to the RQG run
    #    comb_storage/1525794903/current_1
    # The real vardir used by the first server is finally
    #    /work_m/MariaDB/bld_asan/comb_storage/1525794903/current_1/1
    #
    # The solution is to make the path to the vardir absolute (code taken from MTR).
    unless ( $vardir =~ m,^/, or (osWindows() and $vardir =~ m,^[a-z]:[/\\],i) ) {
        $vardir= cwd() . "/" . $vardir;
    }
    unless ( $workdir =~ m,^/, or (osWindows() and $workdir =~ m,^[a-z]:[/\\],i) ) {
        $workdir= cwd() . "/" . $workdir;
    }
    say("INFO: Final workdir  : '$workdir'\n" .
        "INFO: Final vardir   : '$vardir'");
    return $workdir, $vardir;
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

    if ($content=~ s|.*$pattern([a-zA-Z0-9_/\.]+).*|$1|s) {
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
        # We run gendata with a ZZ grammar. So the value in $gendata is a file which must exist.
        if (not -f $gendata) {
            sayError("The file '$gendata' assigned to gendata does not exist or is no plain file.");
            return undef;
            help();
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
        Auxiliary::print_list("DEBUG: Initial gendata_sql_files files ", @gendata_sql_files);
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
        Auxiliary::print_list("DEBUG: Initial redefine_files files ", @redefine_files);
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
    say("Per my (mleich) experiences 'random' is optimal for bug hunting.");
}


# FIXME: Maybe move from the Simplifier to here.
# Adaptive FIFO
#

# Conversion routine for 100M etc.
#

# Check if basedir contains a mysqld and clients


1;

