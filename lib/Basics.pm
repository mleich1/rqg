#  Copyright (c) 2021 MariaDB Corporation Ab.
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
#   lead to exit with STATUS_INTERNAL_ERROR
# - Other failures should rather lead to corresponding return values so that the caller
#   has a chance to fix a problem or clean up before aborting.
# - Carp::cluck in case of failure is very useful in case the sub is called in many RQG
#   components
#

use strict;
use File::Copy;  # basename
use File::Basename;
use Cwd;
use GenTest::Constants;
use Auxiliary;
use GenTest;

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
    if (1 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: " . Basics::who_am_i .
                    " Exact one parameter(dir) needs to get assigned. " .
                    Auxiliary::exit_status_text($status));
        safe_exit($status);
    }
    if (not defined $dir) {
        Carp::cluck("INTERNAL ERROR: \$dir is undef.");
        return STATUS_FAILURE;
    }
    if (not mkdir $dir) {
        my $status = STATUS_FAILURE;
        Carp::cluck("ERROR: Creating the directory '$dir' failed : $!.");
        return $status;
    } else {
        say("INFO: The directory '$dir' was created.");
        return STATUS_OK;
    }
}

sub conditional_make_dir {
    my ($dir, $text) = @_;
    if (2 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: " . Basics::who_am_i .
                    " Exact two parameters(dir, text) need to get assigned. " .
                    Auxiliary::exit_status_text($status));
        safe_exit($status);
    }
    $text = ' ' if not defined $text;
    if (not defined $dir or $dir eq '') {
        Carp::cluck("INTERNAL ERROR: \$dir is undef.");
        return STATUS_FAILURE;
    }
    if (not -d $dir) {
        if (not mkdir $dir) {
            Carp::cluck("ERROR: Creating the directory '$dir' failed : $!.\n" . $text);
            return STATUS_FAILURE;
        } else {
            say("INFO: The directory '$dir' was created.");
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
                    Auxiliary::exit_status_text($status));
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
        say("DEBUG: Already existing tree ->" . $dir . "<- was removed.");
    }
    if (STATUS_OK != Basics::make_dir($dir)) {
        return STATUS_FAILURE;
    } else {
        return STATUS_OK;
    }
}


sub unify_path {
    my ($path) = @_;
    if (1 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: " . Basics::who_am_i .
                    " Exact one parameter(path) needs to get assigned. " .
                    Auxiliary::exit_status_text($status));
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
                    Auxiliary::exit_status_text($status));
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
                    Auxiliary::exit_status_text($status));
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
                    Auxiliary::exit_status_text($status));
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
                    Auxiliary::exit_status_text($status));
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

1;

