#  Copyright (c) 2021, 2022 MariaDB Corporation Ab.
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

package Basics;

# Rules of thumb
# --------------
# - Failures caused by wrong shape of calling sub like wrong number of parameters should
#   lead to exit with STATUS_INTERNAL_ERROR.
# - Other failures should rather lead to corresponding return values so that the caller
#   has a chance to fix a problem or clean up before aborting.
# - Carp::cluck in case of failure is very useful in case the sub is called in many RQG
#   components
#

use strict;
use File::Copy;  # basename
use File::Basename;
# use Cwd qw(getcwd);
use GenTest_e::Constants;
use Auxiliary;
use GenTest_e;

sub who_am_i {
    return (caller(1))[3]. ':';
}
sub who_called_me {
    # FIXME: Returns frequent undef
    return (caller(2))[3];
}

# Maybe define here
# STATUS_OK
# STATUS_FAILURE
# STATUS_INTERNAL_FAILURE
# But do not
# - pick statuses or subs from Gentest.pm
# - exit in any of the subs

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

sub make_dir {
    my ($dir) = @_;

    my $who_am_i = Basics::who_am_i;
    if (1 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: $who_am_i " .
                    " Exact one parameter(\$dir) needs to get assigned. " .
                    Basics::exit_status_text($status));
        safe_exit($status);
    }
    if (not defined $dir or $dir eq '') {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: $who_am_i \$dir is undef or ''. " .
                    Basics::exit_status_text($status));
        return STATUS_FAILURE;
    }
    if (not mkdir $dir) {
        my $status = STATUS_FAILURE;
        Carp::cluck("ERROR: $who_am_i Creating the directory '$dir' failed : $!.");
        return $status;
    } else {
        # say("INFO: The directory '$dir' was created.");
        return STATUS_OK;
    }
}

sub conditional_make_dir {
    my ($dir) = @_;
    if (1 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: " . Basics::who_am_i .
                    " Exact one parameter(dir) needs to get assigned. " .
                    Basics::exit_status_text($status));
        safe_exit($status);
    }
    if (not defined $dir or $dir eq '') {
        Carp::cluck("INTERNAL ERROR: \$dir is undef or ''.");
        return STATUS_FAILURE;
    }
    if (not -d $dir) {
        if (not mkdir $dir) {
            Carp::cluck("ERROR: Creating the directory '$dir' failed : $!.\n");
            return STATUS_FAILURE;
        } else {
            # say("INFO: The directory '$dir' was created.");
            return STATUS_OK;
        }
    }
}

sub conditional_remove__make_dir {
    my ($dir) = @_;
    if (1 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: " . Basics::who_am_i .
                    " Exact one parameter(dir) needs to get assigned. " .
                    Basics::exit_status_text($status));
        safe_exit($status);
    }
    if (not defined $dir or $dir eq '') {
        Carp::cluck("INTERNAL ERROR: \$dir is undef or ''.");
        return STATUS_FAILURE;
    }
    if (-d $dir) {
        if (not File::Path::rmtree($dir)) {
            say("ERROR: Removal of the already existing tree ->" . $dir . "<- failed. : $!.");
            return STATUS_FAILURE;
        }
        # Carp::cluck("DEBUG: Already existing tree ->" . $dir . "<- was removed.");
    }
    if (STATUS_OK != Basics::make_dir($dir)) {
        return STATUS_FAILURE;
    } else {
        return STATUS_OK;
    }
}

sub remove_dir {
# Remove means the complete tree.
    my ($dir) = @_;
    if (1 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: " . Basics::who_am_i .
                    " Exact one parameter(\$dir) needs to get assigned. " .
                    Basics::exit_status_text($status));
        safe_exit($status);
    }
    if (not defined $dir or $dir eq '') {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: \$dir is undef or ''. " .
                    Basics::exit_status_text($status));
        safe_exit($status);
    }
    if (not File::Path::rmtree($dir)) {
        Carp::cluck("ERROR: Removal of the already existing? tree ->" . $dir . "<- failed. : $!.");
        return STATUS_FAILURE;
    }
    # say("DEBUG: " . Basics::who_am_i . " Already existing tree ->" . $dir . "<- was removed.");
    return STATUS_OK;
}

sub conditional_remove_dir {
# Remove means the complete tree.
    my ($dir) = @_;
    if (1 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: " . Basics::who_am_i .
                    " Exact one parameter(\$dir) needs to get assigned. " .
                    Basics::exit_status_text($status));
        safe_exit($status);
    }
    if (not defined $dir or $dir eq '') {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: \$dir is undef or ''. " .
                    Basics::exit_status_text($status));
        safe_exit($status);
    }
    if (-e $dir) {
        if (STATUS_OK != remove_dir($dir)) {
            return STATUS_FAILURE;
        }
    }
    return STATUS_OK;
}

sub copy_dir_to_newdir {
    my ($source, $target) = @_;
    if (2 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: " . Basics::who_am_i .
                    " Exact two parameter(\$source,\$target) need to get assigned. " .
                    Basics::exit_status_text($status));
        safe_exit($status);
    }
    if (not defined $source or $source eq '' or not defined $target or $target eq '') {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: (\$source or \$target) is (undef or ''). " .
                    Basics::exit_status_text($status));
        safe_exit($status);
    }
    if (not -d $source) {
        my $status = STATUS_FAILURE;
        Carp::cluck("ERROR: Source directory '$source' does not exist or is not a directory.");
        return $status;
    }
    if (-e $target) {
        my $status = STATUS_FAILURE;
        Carp::cluck("ERROR: Target directory '$target' does already exist.");
        return $status;
    }
    my $rc;
    if (osWindows()) {
        $rc = system("xcopy \"$source\" \"$target\" /E /I /Q") >> 8;
    } else {
        $rc = system("cp -rL $source $target 2>dir_copy.err") >> 8;
    }
    # https://metacpan.org/pod/File::Copy::Recursive::Reduced
    # might be able to do the job.
    if ($rc != 0) {
        Carp::cluck("ERROR: Copying the directory '$source' including content to some new " .
                    "directory '$target' failed with RC: $rc");
        sayFile("dir_copy.err");
        unlink("dir_copy.err");
        return STATUS_FAILURE;
    } else {
        unlink("dir_copy.err");
        return STATUS_OK;
    }
}

sub rename_dir {
    # Requirement: Both are in the same filesystem.
    my ($source, $target) = @_;
    my $who_am_i = Basics::who_am_i();
    if (not move ($source, $target)) {
        # The move operation failed.
        Carp::cluck("ERROR: $who_am_i Moving the directory '$source' to '$target' failed : $!");
        return STATUS_FAILURE;
    } else {
        say("DEBUG: $who_am_i '$source' to '$target'.")
            if Auxiliary::script_debug("A5");
        return STATUS_OK;
    }
}

sub move_dir_to_newdir {
    # I assume here that the directories are in different filesystems.
    my ($source, $target) = @_;
    my $who_am_i = Basics::who_am_i();
    if (STATUS_OK != copy_dir_to_newdir($source, $target)) {
        return STATUS_FAILURE;
    }
    if (STATUS_OK != remove_dir($source)) {
        return STATUS_FAILURE;
    }
    # say("DEBUG: $who_am_i Directory '$source' moved to '$target'.");
    return STATUS_OK;
}

sub unify_path {
    my ($path) = @_;
    if (1 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: " . Basics::who_am_i .
                    " Exact one parameter(path) needs to get assigned. " .
                    Basics::exit_status_text($status));
        safe_exit($status);
    }
    if (not defined $path or $path eq '') {
        Carp::cluck("INTERNAL ERROR: \$path is undef or ''.");
        return STATUS_FAILURE;
    }
    unless ( $path =~ m,^/, or (osWindows() and $path =~ m,^[a-z]:[/\\],i) ) {
        $path = cwd() . "/" . $path;
    }
    # Replace the annoying '//' with '/'.
    $path =~ s/\/+/\//g;
    # Remove trailing /
    # $path =~ s/\/$//g;
    return $path;
}

sub make_file {
#
# Purpose
# -------
# Make a plain file.
# If text was assigned write it into the file.
#
# Return values
# -------------
# STATUS_OK      -- Success
# STATUS_FAILURE -- No success
#
    my ($my_file, $my_string) = @_;
    if (2 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: " . Basics::who_am_i .
                    " Exact two parameters(my_file, my_string) need to get assigned. " .
                    Basics::exit_status_text($status));
        safe_exit($status);
    }
    if (not defined $my_file or $my_file eq '') {
        Carp::cluck("INTERNAL ERROR: The value for the file name is undef.");
        return STATUS_FAILURE;
    }
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

sub append_string_to_file {

    my ($my_file, $my_string) = @_;
    if (2 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: " . Basics::who_am_i .
                    " Exact two parameters(my_file, my_string) need to get assigned. " .
                    Basics::exit_status_text($status));
        safe_exit($status);
    }
    if (not defined $my_file or $my_file eq '') {
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
    if (2 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: " . Basics::who_am_i .
                    " Exact two parameters(source_file, target_file) need to get assigned. " .
                    Basics::exit_status_text($status));
        safe_exit($status);
    }
    if (not defined $source_file or $source_file eq '') {
        Carp::cluck("INTERNAL ERROR: The value for the file name is undef.");
        return STATUS_FAILURE;
    }
    if (not defined $target_file or $target_file eq '') {
        Carp::cluck("INTERNAL ERROR: The value for the file name is undef.");
        return STATUS_FAILURE;
    }
    if (not -e $source_file) {
        Carp::cluck("ERROR: The source file '$source_file' does not exist.");
        return STATUS_FAILURE;
    }
    if (-e $target_file) {
        Carp::cluck("ERROR: The target file '$target_file' does already exist.");
        return STATUS_FAILURE;
    }
    system("sync -d $source_file");
    # Perl documentation claims that
    # - "File::Copy::move" is platform independent
    # - "rename" is not and might have probems accross filesystem boundaries etc.
    if (not move ($source_file , $target_file)) {
        # The move operation failed.
        Carp::cluck("ERROR: Copying '$source_file' to '$target_file' failed : $!");
        return STATUS_FAILURE;
    } else {
        say("DEBUG: Basics::rename_file '$source_file' to '$target_file'.")
            if Auxiliary::script_debug("A5");
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
    if (2 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: " . Basics::who_am_i .
                    " Exact two parameters(source_file, target_file) need to get assigned. " .
                    Basics::exit_status_text($status));
        safe_exit($status);
    }
    if (not defined $source_file or $source_file eq '') {
        Carp::cluck("INTERNAL ERROR: The value for the file name is undef.");
        return STATUS_FAILURE;
    }
    if (not defined $target_file or $target_file eq '') {
        Carp::cluck("INTERNAL ERROR: The value for the file name is undef.");
        return STATUS_FAILURE;
    }
    if (not -e $source_file) {
        Carp::cluck("ERROR: The source file '$source_file' does not exist.");
        return STATUS_FAILURE;
    }
    if (not File::Copy::copy($source_file, $target_file)) {
        Carp::cluck("ERROR: Copying '$source_file' to '$target_file' failed : $!");
        return STATUS_FAILURE;
    } else {
        say("DEBUG: Basics::copy_file '$source_file' to '$target_file'.")
            if Auxiliary::script_debug("A5");
        return STATUS_OK;
    }
}

sub get_process_family {
# Typical use case
# ----------------
# "tar" within the archiving routine laments that some file changed during archiving.
# So figure out which sibling or child processes exist even though they maybe should not.
    if (osWindows()) {
        return 'How to get_process_family on WIN?';
    } else {
        my $prgp =   getpgrp;
        my @wo   =   `ps -T -u \`id -u\` -o uid,pid,ppid,pgid,sid,args | grep $prgp | cut -c1-256`;
        my $return = "uid   pid   ppid   pgid   sid   args\n";
        foreach my $line (sort @wo) {
            if (not $line =~ m{ ps -T -u } and not $line =~ m{ grep } and
                not $line =~ m{ cut -c1-} ) {
                $return .= $line;
            }
        }
        return $return;
    }
}

sub symlink_dir {
    my ($source_dir, $symlink_dir) = @_;
    if (2 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: " . Basics::who_am_i .
                    " Exact two parameters(source_dir, symlink_dir) need to get assigned. " .
                    Basics::exit_status_text($status));
        safe_exit($status);
    }
    if (not defined $source_dir or $source_dir eq '') {
        Carp::cluck("INTERNAL ERROR: The value for the directory name is undef.");
        return STATUS_FAILURE;
    }
    if (not defined $symlink_dir or $symlink_dir eq '') {
        Carp::cluck("INTERNAL ERROR: The value for the symlink name is undef.");
        return STATUS_FAILURE;
    }
    if (not -d $source_dir) {
        Carp::cluck("ERROR: The source directory '$source_dir' does not exist or is not a directory.");
        return STATUS_FAILURE;
    }
    if (-e $symlink_dir) {
        Carp::cluck("ERROR: An object with the symlink name '$symlink_dir' does already exist.");
        return STATUS_FAILURE;
    }
    if (not symlink($source_dir, $symlink_dir)) {
        Carp::cluck("ERROR: Creating the symlink '$symlink_dir' pointing to '$source_dir' failed: $!");
        system("ls -ld $source_dir $symlink_dir");
        return STATUS_INTERNAL_ERROR;
    } else {
        say("DEBUG: The symlink '$symlink_dir' pointing to '$source_dir' has been created.");
        return STATUS_OK;
    }
}

# --------------------------------------------------------------------------------------------------

# *_status_text
# =============
# These routines serve for
# - standardize the phrase printed when returning some status or exiting with some status
# - give maximum handy information like status as text (the constant) and number.
# Example for the string returned:
#    Will exit with exit status STATUS_SERVER_CRASHED(101).
# Example of invocation:
# my $status = STATUS_SERVER_CRASHED;
# say("ERROR: All broken. " . Basics::exit_status_text($status));
# safe_exit($status);
#
use constant PHRASE_EXIT   =>           'exit with exit';
use constant PHRASE_RETURN =>           'return with';
use constant PHRASE_RETURN_RESULT =>    'return a result containing the';

sub _status_text {
    my ($status, $action) = @_;
    # The calling routine MUST already check that $status and $action are defined.
    my $snip;
    if      ($action eq 'exit'  ) {
        $snip = PHRASE_EXIT;
    } elsif ($action eq 'return') {
        $snip = PHRASE_RETURN;
    } elsif ($action eq 'return_containing') {
        $snip = PHRASE_RETURN;
    } else {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL EXIT_PHRASE ERROR: Don't know how to handle the action '$action'." .
                    "Will " . PHRASE_EXIT . " " . status2text($status) . "($status)");
        safe_exit($status);
    }
    return "Will $snip status " . status2text($status) . "($status).";
}

sub exit_status_text {
# Return a text like 'Will exit with exit status STATUS_SERVER_CRASHED(101)'
# Typical call:
# say("ERROR: <some text> " . Basics::exit_status_text($status));
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
# Purpose:
# Return a text like 'Will return with status STATUS_SERVER_CRASHED(101).'
# Typical call:
# say("ERROR: <some text> " . Basics::return_status_text($status));
    my ($status) = @_;
    if (not defined $status) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: The first parameter status is undef. " .
                    "Will " . PHRASE_EXIT . " " . status2text($status) . "($status).");
        safe_exit($status);
    }
    return _status_text($status, 'return');
}

sub return_rc_status_text {
# Purpose:
# Return a text like 'Will return a result containing the status STATUS_SKIP_RELOOP(7).'
#
# To be used by routines like "lib/GenTest_e/Executor/MySQL.pm" which return an object
# where the status is a component.
# Typical call:
# say("ERROR: <some text> " . Basics::return_rc_status_text($status));
    my ($status) = @_;
    if (not defined $status) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: The first parameter status is undef. " .
                    "Will " . PHRASE_EXIT . " " . status2text($status) . "($status).");
        safe_exit($status);
    }
    return _status_text($status, 'return_containing');
}
# --------------------------------------------------------------------------------------------------

# Routines for redirecting the output
# ===================================
# Ideas taken from
#    https://www.perlmonks.org/bare/?node_id=255129
#    https://www.perl.com/article/45/2013/10/27/How-to-redirect-and-restore-STDOUT/
# Typical use case
# ----------------
# The reporter Mariabackup_linux has to execute a rather long sequence of actions like
#     backup, prepare backupped data, start server on backupped data, check content
# several times per single RQG run.
# In case the sequence
# - passes
#   Than we do no more need any details of it. Just "We got a pass" is sufficient.
# - does not pass
#   Than we need a huge amount of detail because the reason for the trouble might be in
#       RQG code, DB server, Mariabackup(--backup or --prepare), environment, ...
# Hence the reporter
# - writes essential information about success and fail to STDOUT --> finally rqg.log
# - writes details per sequence into a file reporter.prt
# - dumps the content of reporter.prt to STDOUT if a sequence fails
# - deletes reporter.prt if a sequence passes
# The switching via direct_to_file and direct_to_stdout takes care that the RQG routine
# called by Mariabackup_linux writes into the right "object".
my $stdout_save;
my $stderr_save;
sub direct_to_file {
    my ($output_file) = @_;

    my $who_am_i = Basics::who_am_i();

    if (not open($stdout_save, ">&", STDOUT)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i : Getting STDOUT failed with '$!' " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }
    if (not open($stderr_save, ">&", STDERR)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i : Getting STDERR failed with '$!' " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }
    # say("DEBUG: $who_am_i : Redirecting all output to '$output_file'.");
    unlink ($output_file);
    if (not open(STDOUT, ">>", $output_file)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i : Opening STDOUT failed with '$!' " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }
    # Redirect STDERR to the log of the RQG run.
    if (not open(STDERR, ">>", $output_file)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i : Opening STDERR failed with '$!' " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }
}

sub direct_to_stdout {

    my $who_am_i = Basics::who_am_i();
    if (not defined $stdout_save or not $stderr_save) {
        my $status = STATUS_INTERNAL_ERROR;
        say("INTERNAL ERROR: $who_am_i If ever running 'direct_to_stdout' " .
            "than there must have been a 'direct_to_file' prior.");
        exit $status;
    }

    if (not open(STDOUT, ">&" , $stdout_save)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i : Opening STDOUT failed with '$!' " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }
    if (not open(STDERR, ">&" , $stderr_save)) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: $who_am_i : Opening STDERR failed with '$!' " .
            "Will exit with status " . status2text($status) . "($status)");
        exit $status;
    }
    close($stdout_save);
    close($stderr_save);
    # Experimental
    # Reason: Same second but messages somehow not in order
    $| = 1;
}

# --------------------------------------------------------------------------------------------------

# *fill* + dash_line
# ==================
# Routines used for printing tables with results and similar.
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


1;

