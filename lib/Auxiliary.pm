#  Copyright (c) 2018, MariaDB Corporation Ab.
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


use GenTest::Constants;
use GenTest;
use File::Copy;
use Cwd;

# use constant STATUS_OK       => 0;
use constant STATUS_FAILURE    => 1; # Just the opposite of STATUS_OK

my $script_debug = 0;

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
# Make an empty plain file.
#
# Return values
# -------------
# STATUS_OK      -- Success
# STATUS_FAILURE -- No success
#
    my ($my_file) = @_;
    if (not open (MY_FILE, '>', $my_file)) {
        say("ERROR: Open file '>$my_file' failed : $!");
        return STATUS_FAILURE;
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
    say("DEBUG: Auxiliary::make_rqg_infrastructure workdir is '$workdir'") if $script_debug;
    $workdir = Cwd::abs_path($workdir);
    if (not -d $workdir) {
        say("ERROR: RQG workdir '$workdir' is missing or not a directory.");
        return STATUS_FAILURE;
    }
    my $my_file;
    my $result;
    $my_file = $workdir . '/rqg.log';
    $result  = make_file ($my_file);
    return $result if $result;
    $my_file = $workdir . '/rqg_phase.init';
    $result  = make_file ($my_file);
    return $result if $result;
    $my_file = $workdir . '/rqg_verdict.init';
    $result  = make_file ($my_file);
    return $result if $result;
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
    say("DEBUG: Auxiliary::check_rqg_infrastructure workdir is '$workdir'") if $script_debug;
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
    $my_file = $workdir . '/rqg_verdict.init';
    if (not -e $my_file) {
        say("ERROR: RQG file '$my_file' is missing.");
        return STATUS_FAILURE;
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
      Carp::cluck("ERROR: Auxiliary::rename_file The source file '$source_file' does not exist.");
      return STATUS_FAILURE;
   }
   if (-e $target_file) {
      Carp::cluck("ERROR: Auxiliary::rename_file The target file '$target_file' does already exist.");
      return STATUS_FAILURE;
   }
   # Perl documentation claims that
   # - "File::Copy::move" is platform independent
   # - "rename" is not and might have probems accross filesystem boundaries etc.
   if (not move ($source_file , $target_file)) {
      # The move operation failed.
      Carp::cluck("ERROR: Auxiliary::rename_file '$source_file' to '$target_file' failed : $!");
      return STATUS_FAILURE;
   } else {
      say("DEBUG: Auxiliary::rename_file '$source_file' to '$target_file'.") if $script_debug;
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
        say("PHASE: $new_phase");
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
        Carp::confess("INTERNAL ERROR: Auxiliary::check_normalize_set_black_white_lists : " .
                      "five parameters are required.");
        # This accident could roughly only happen when coding RQG or its tools.
        # Already started servers need to be killed manually!
    }
    if (not defined $xstatus_prefix) {
        Carp::confess("INTERNAL ERROR: Auxiliary::check_normalize_set_black_white_lists : ".
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
        my $result = surround_quote_check($whitelist_statuses[0]);
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
        my $result = surround_quote_check($whitelist_patterns[0]);
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
        my $result = surround_quote_check($blacklist_statuses[0]);
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
        say("DEBUG: \$blacklist_patterns[1] ->" . $blacklist_patterns[1] . " <-") if $script_debug;
        # Optional splitting of first value is not supported if having more than one value.
        # So do nothing.
    } else {
        say("BEBUG: \$blacklist_patterns[0] ->" . $blacklist_patterns[0] . "<-") if $script_debug;
        my $result = surround_quote_check($blacklist_patterns[0]);
        say("Result of surround_quote_check : $result") if $script_debug;
        if      ('no quote protection' eq $result) {
            # The value comes most probably from a config file.
            # So nothing to do.
        } elsif ('bad quotes' eq $result) {
            $failure_met = 1;
        } elsif ('single quote protection' eq $result or 'double quote protection' eq $result) {
            # The value is well formed and comes from a command line?
            say("Sending blacklist_patterns to input_to_list");
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


sub black_white_lists_to_option_string {
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
    if (not $bw_lists_set) {
        Carp::cluck("INTERNAL ERROR: black_white_lists_to_option_string was called before " .
                    "the call of check_normalize_set_black_white_lists.");
    }

    sub give_value_list {
        my (@input)      = @_;
        my $has_elements = 0;
        my $result;
        foreach my $element (@input) {
            if (defined $element) {
                if ($has_elements) {
                    # Non first element, so with <comma><element>
                    $result = $result . ",\\'$element\\'";
                } else {
                    $result = "\\'$element\\'";
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
    my $option_string = ' ';
    $result = give_value_list (@whitelist_statuses) ;
    if (defined $result) {
        $option_string = $option_string . ' --whitelist_statuses="' . $result . '"';
    }
    $result = give_value_list (@whitelist_patterns) ;
    if (defined $result) {
        $option_string = $option_string . ' --whitelist_patterns="' . $result . '"';
    }
    $result = give_value_list (@blacklist_statuses) ;
    if (defined $result) {
        $option_string = $option_string . ' --blacklist_statuses="' . $result . '"';
    }
    $result = give_value_list (@blacklist_patterns) ;
    if (defined $result) {
        $option_string = $option_string . ' --blacklist_patterns="' . $result . '"';
    }

    return $option_string;
} # End of sub black_white_lists_to_option_string

use constant RQG_VERDICT_INIT               => 'init';
                 # Initial value == Up till now no analysis started or finished.
use constant RQG_VERDICT_REPLAY             => 'replay';
                 # White list match. No black list match.
use constant RQG_VERDICT_INTEREST           => 'interest';
                 # No white list match. No black list match.
use constant RQG_VERDICT_IGNORE             => 'ignore';
                 # Black list match or run was stopped intentionally or similar.
use constant RQG_VERDICT_ALLOWED_VALUE_LIST => [
        RQG_VERDICT_INIT, RQG_VERDICT_REPLAY, RQG_VERDICT_INTEREST, RQG_VERDICT_IGNORE
    ];


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
    }

    say("DEBUG: file_to_search_in '$file_to_search_in") if $script_debug;

    # RQG logs could be huge and even the memory on testing boxes is limited.
    # So we push in maximum the last 100000000 bytes of the log into $content.
    my $content = Auxiliary::getFileSlice($file_to_search_in, 100000000);
    if (not defined $content) {
        say("FIXME: No content got. Handle that");
        return undef;
    } else {
        say("DEBUG: Auxiliary::getFileSlice got content : ->$content<-") if $script_debug;
    }

    my $cut_position;
    $cut_position = index($content, Auxiliary::MATCHING_START);
    if ($cut_position >= 0) {
        $content = substr($content, $cut_position);
        say("DEBUG: cut_position : $cut_position") if $script_debug;
    }

    $cut_position = index($content, Auxiliary::MATCHING_END);
    if ($cut_position >= 0) {
        $content = substr($content, 0, $cut_position);
        say("DEBUG: cut_position : $cut_position") if $script_debug;
    }

    my $p_match;
    my $maybe_match    = 1;
    my $maybe_interest = 1;

    $p_match = Auxiliary::status_matching($content, \@blacklist_statuses   ,
                                          $status_prefix, 'MATCHING: Blacklist statuses', 1);
    # Note: Hitting Auxiliary::MATCH_UNKNOWN would be not nice.
    #       But its acceptable compared to Auxiliary::MATCH_YES.
    if ($p_match eq Auxiliary::MATCH_YES) {
        $maybe_match    = 0;
        $maybe_interest = 0;
    }

    say("DEBUG: maybe_interest : $maybe_interest, maybe_match : $maybe_match") if $script_debug;
    $p_match = Auxiliary::content_matching ($content, \@blacklist_patterns ,
                                           'MATCHING: Blacklist text patterns', 1);
    if ($p_match eq Auxiliary::MATCH_YES) {
        $maybe_match    = 0;
        $maybe_interest = 0;
    }
    say("DEBUG: maybe_interest : $maybe_interest, maybe_match : $maybe_match") if $script_debug;

    # At this point we could omit checking in case $maybe_match = 0.
    # But there might be some interest to know if the whitelist stuff was hit too.
    # So we run it here in any case too.
    $p_match = Auxiliary::status_matching($content, \@whitelist_statuses   ,
                                          $status_prefix, 'MATCHING: Whitelist statuses', 1);
    # Note: Hitting Auxiliary::MATCH_UNKNOWN is not acceptable because it would
    #       degenerate runs of the grammar simplifier.
    if ($p_match ne Auxiliary::MATCH_YES) {
        $maybe_match    = 0;
    }
    $p_match = Auxiliary::content_matching ($content, \@whitelist_patterns ,
                                            'MATCHING: Whitelist text patterns', 1);
    if ($p_match ne Auxiliary::MATCH_YES and $p_match ne Auxiliary::MATCH_NO_LIST_EMPTY) {
        $maybe_match    = 0;
    }
    say("DEBUG: maybe_interest : $maybe_interest, maybe_match : $maybe_match") if $script_debug;
    my $verdict = Auxiliary::RQG_VERDICT_INIT;
    if ($maybe_match) {
        $verdict = Auxiliary::RQG_VERDICT_REPLAY;
    } elsif ($maybe_interest) {
        $verdict = Auxiliary::RQG_VERDICT_INTEREST;
    } else {
        $verdict = Auxiliary::RQG_VERDICT_IGNORE;
    }
    return $verdict;

} # End of sub sub calculate_verdict


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
        Carp::confess("INTERNAL ERROR: Auxiliary::status_matching : Five parameters " .
                      "are required.");
        # This accident could roughly only happen when coding RQG or its tools.
        # Already started servers need to be killed manually!
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
    say("DEBUG: pattern_prefix ->$pattern_prefix<-") if $script_debug;

    if (not defined $pattern_prefix or $pattern_prefix eq '') {
        # Its an internal error or (rather) misuse of routine.
        Carp::cluck("INTERNAL ERROR: pattern_prefix is not defined or empty");
    }
    if (not defined $content or $content eq '') {
        # Its an internal error or (rather) misuse of routine.
        Carp::cluck("INTERNAL ERROR: content is not defined or empty");
    }
    if (not defined $message_prefix or $message_prefix eq '') {
        # Its an internal error or (rather) misuse of routine.
        Carp::cluck("INTERNAL ERROR: message_prefix is not defined or empty");
    }

    # Count the number of pattern matches thanks to the 'g'.
    my $pattern_prefix_found = () = $content =~ m{$pattern_prefix}gs;
    if ($pattern_prefix_found > 1) {
        Carp::cluck("INTERNAL ERROR: pattern_prefix matched $pattern_prefix_found times.");
    } elsif ($pattern_prefix_found == 0) {
        say("INFO: status_matching : The pattern_prefix '$pattern_prefix' was not found. " .
            "Assume aborted RQG run and will return MATCH_UNKNOWN.");
        return MATCH_UNKNOWN;
    } else {
        say("DEBUG: status_matching : The pattern_prefix '$pattern_prefix' was " .
            "found once.") if $script_debug;
    }

    my $no_pattern = 1;
    my $match      = 0;
    foreach my $pattern (@{$pattern_list}) {
        last if not defined $pattern;
        $no_pattern = 0;
        my $search_pattern;
        my $message;
        say("DEBUG: Pattern to check ->$pattern<-") if $script_debug;
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
        say("ERROR: Auxiliary::set_rqg_verdict from '$initial_verdict' to '$verdict' failed.");
        return STATUS_FAILURE;
    } else {
        say("DEBUG: Auxiliary::set_rqg_verdict from '$initial_verdict' to " .
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
        say("ERROR: Auxiliary::get_rqg_verdict : RQG workdir '$workdir' " .
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
    say("ERROR: Auxiliary::get_rqg_verdict : No RQG verdict file in directory '$workdir' found. " .
        "Will return undef.");
    return undef;
}

# ----------

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
        Carp::cluck("INTERNAL ERROR: Auxiliary::input_to_list : One Parameter " .
                    "(input) is required. Will return undef.");
        # This accident could roughly only happen when coding RQG or its tools.
        # Already started servers need to be killed manually!
    }
    my (@input) = @_;

    my $quote_val;
    print_list("DEBUG: input_to_list initial value ", @input) if $script_debug;

    if ($#input != 0) {
        say("DEBUG: input_to_list : The input does not consist of one element. " .
            "Will return that input.") if $script_debug;
        return \@input;
    }
    if (not defined $input[0]) {
        say("DEBUG: input_to_list : \$input[0] is not defined. " .
            "Will return the input.") if $script_debug;
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
            $failure_met = 1;
            say("INTERNAL ERROR: surround_quote_check returned '$result' which is not supported." .
                "Will return undef.");
            return undef;
        }
    }

    my $separator = $quote_val . ',' . $quote_val;
    if ($input[0] =~ m/$separator/) {
        say("DEBUG: -->" . $separator . "<-- in input found. Splitting required.") if $script_debug;
        # Remove the begin and end quote first.
        $input[0] = substr($input[0], 1, length($input[0]) - 2) if 1 == length($quote_val);
        @input = split(/$separator/, $input[0]);
    } else {
        say("DEBUG: -->$separator<-- not in input found.") if $script_debug;
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
# or abort with confess if the routine is used wrong.
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
        Carp::confess("INTERNAL ERROR: Auxiliary::getFileSlice : 2 Parameters (file_to_read, " .
                      "search_var_size) are required.");
        # This accident could roughly only happen when coding RQG or its tools.
        # Already started servers need to be killed manually!
    }

    if (not defined $file_to_read) {
        Carp::confess("INTERNAL ERROR: \$file_to_read is not defined. Will return undef.");
        return undef;
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


sub get_git_info {
    my ($directory) = @_;

    # Code just for testing the current routine
    # say("Auxiliary::get_git_info() ---");
    # Auxiliary::get_git_info();
    # say("Auxiliary::get_git_info(undef) ---");
    # Auxiliary::get_git_info(undef);
    # say("Auxiliary::get_git_info('/tmp/does_not_exist') ---");
    # Auxiliary::get_git_info('/tmp/does_not_exist');
    # say("Auxiliary::get_git_info($0) ---");
    # Auxiliary::get_git_info($0);
    # say("Auxiliary::get_git_info('/tmp') ---");
    # Auxiliary::get_git_info('/tmp');
    #

    my $cmd ;             # For commands run through system ...
    my $result ;          # For the return of system ...
    my $git_output_file ; # For the output of git commands
    my $fail = 0;
    if (not defined $directory) {
        say("ERROR: Auxiliary::get_git_info : No parameter or undef was assigned. " .
            "Will return STATUS_INTERNAL_ERROR");
        return STATUS_INTERNAL_ERROR;
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
    $git_output_file = $cwd . "/rqg-git-version-info." . $$;
    $cmd = "git --version > $git_output_file 2>&1";
    $result = system($cmd) >> 8;
    # my $cmd = "nogit --version > $git_output_file";
    #   sh: 1: nogit: not found
    # 127 PGM does not exist
    # my $cmd = "git --version > /";
    #   sh: 1: cannot create /: Is a directory
    #   2 Create failed because of directory there
    # my $cmd = "git --version > /27";
    #   sh: 1: cannot create /27: Permission denied
    #   2 Create failed because of permission
    # my $cmd = "git --whatever_version > $git_output_file";
    #   Unknown option: --whatever_version
    # 129 PGM denies service/wrong used
    # Be in some directory like '/tmp' which is not controlled by GIT
    #   fatal: Not a git repository (or any of the parent directories): .git
    # 128 No GIT deriectory
    if ($result != STATUS_OK) {
        if ($result == 127) {
            say("INFO: GIT binary not found. Will return STATUS_OK");
            unlink($git_output_file);
            return STATUS_OK;
        } else {
            say("ERROR: Trouble with GIT or similar. Will return STATUS_INTERNAL_ERROR");
            sayFile($git_output_file);
            unlink($git_output_file);
            return STATUS_INTERNAL_ERROR;
        }
    }
    unlink($git_output_file);
    if (not chdir($directory))
    {
        say("ALARM: chdir to '$directory' failed with : $!\n" .
            "       Will return STATUS_ENVIRONMENT_FAILURE");
        return STATUS_ENVIRONMENT_FAILURE;
    }
#   my $cmd = "git branch  > $git_output_file 2>&1";
#   system($cmd);
#   my $cmd = "git show -s >> $git_output_file 2>&1";
#   system($cmd);
    # git show --pretty='format:%D %H  %cI' -s
    # HEAD -> experimental, origin/experimental ce3c84fc53216162ef8cc9fdcce7aed24887e305  2018-05-04T12:39:45+02:00
    # %s would show the title of the last commit but that could be longer than wanted.
    $cmd = "git show --pretty='format:%D %H %cI' -s > $git_output_file 2>&1";
    system ($cmd);
    sayFile ($git_output_file);
    unlink ($git_output_file);

    chdir($cwd);
    return STATUS_OK;
} # End sub get_git_info


####################################################################################################
# Certain constant related to whatever kinds of replication
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
    say("DEBUG: cmd : ->$cmd<-") if $script_debug;
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
                "created.") if $script_debug;
        } else {
            say("ERROR: make_multi_runner_infrastructure : Creating the general workdir " .
                "$snip_all '$general_workdir' failed: $!. Will return undef.");
            return undef;
        }
    }

    my $workdir = $general_workdir . "/" . $run_id;
    # Note: In case there is already a directory '$workdir' than we just fail in mkdir.
    if (mkdir $workdir) {
        say("DEBUG: The workdir $snip_current '$workdir' created.") if $script_debug;
    } else {
        say("ERROR: Creating the workdir $snip_current '$workdir' failed: $!.\n " .
            "This directory must not exist in advance!\n" .
            "Will exit with STATUS_ENVIRONMENT_FAILURE");
        exit STATUS_ENVIRONMENT_FAILURE;
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
            say("DEBUG: The general vardir $snip_all '$general_vardir' created.") if $script_debug;
        } else {
            say("ERROR: make_multi_runner_infrastructure : Creating the general vardir " .
                "$snip_all '$general_vardir' failed: $!. Will return undef.");
            return undef;
        }
    }
    my $vardir = $general_vardir . "/" . $run_id;
    # Note: In case there is already a directory '$vardir' than we just fail in mkdir.
    if (mkdir $vardir) {
        say("DEBUG: The vardir $snip_current '$vardir' created.") if $script_debug;
    } else {
        say("ERROR: Creating the vardir $snip_current '$vardir' failed: $!.\n " .
            "This directory must not exist in advance!\n" .
            "Will exit with STATUS_ENVIRONMENT_FAILURE");
        exit STATUS_ENVIRONMENT_FAILURE;
    }

    # Convenience feature
    # -------------------
    # Make a symlink so that the last workdir used by some tool performing multiple RQG runs like
    #    combinations.pl, bughunt.pl, simplify_grammar.pl
    # is easier found.
    # Creating the symlink might fail on some OS (see perlport) but should not abort our run.
    unlink($symlink_name);
    my $symlink_exists = eval { symlink($workdir, $symlink_name) ; 1 };

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


sub bw_lists_help {
    say("The status matching accepts strings starting with 'STATUS_' only.\n"             .
        "The supported values are in lib/GenTest/Constants.pm.\n"                         .
        "The status matching will not check the input against this file.\n"               .
        "STATUS_ANY matches any status != STATUS_OK\n\n"                                  .
        "The text pattern matching is restricted to a region starting with\n"             .
        "    " . MATCHING_START . "\n"                                                    .
        "end ending with\n"                                                               .
        "    " . MATCHING_END   . "\n"                                                    .
        "Comma has to be used as separator between different values.\n"                   .
        "Also using single quotes around the values is highly recommended because "       .
        "otherwise meachnisms might split at the wrong position.\n")                      ;
    bw_list_help_example();
}

sub bw_list_help_example {
    say("Example for command line:\n"                                                     .
        "   ... --blacklist_statuses=\"'STATUS_OK','STATUS_ENVIRONMENT_FAILURE'\" ... \n" .
        "Example for config file:\n"                                                      .
        "   whitelist_statuses => [\n"                                                    .
        "       \'STATUS_SERVER_CRASHED\',\n"                                             .
        "       \'STATUS_ANY_ERROR\',\n"                                                  .
        "   ],\n");
}


sub surround_quote_check {
    my ($input) = @_;
    say("surround_quote_check: Input is ->" . $input . "<-") if $script_debug;
    return 'empty' if not defined $input;
    if      (substr($input,  0, 1) eq "'" and substr($input, -1, 1) eq "'") {
        say("DEBUG: The input is surrounded by single quotes. Assume " .
            "'single quote protection'.") if $script_debug;
        return 'single quote protection';
    } elsif (substr($input,  0, 1) eq '"' and substr($input, -1, 1) eq '"') {
        say("DEBUG: The input is surrounded by double quotes. Assume " .
            "'double quote protection'.") if $script_debug;
        return 'double quote protection';
    } elsif (substr($input,  0, 1) ne "'" and substr($input, -1, 1) ne "'" and
             substr($input,  0, 1) ne '"' and substr($input, -1, 1) ne '"') {
        say("DEBUG: The input is not surrounded by single or double quotes. Assume " .
            "'no quote protection'.") if $script_debug;
        return 'no quote protection';
    } else {
        say("ERROR: Either begin and end with single or double quote or both without quotes.");
        say("ERROR: The input was -->" . $input . "<--");
        say("ERROR: Will return 'bad quotes'.");
        return 'bad quotes';
    }
}

1;

