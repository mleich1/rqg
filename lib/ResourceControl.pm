#  Copyright (c) 2018, MariaDB Corporation Ab.
#  Use is subject to license terms.
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

package ResourceControl;

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
# Hint:
# All variables which get direct accessed by routines from other packages like
#     push @Batch::try_queue, $order_id_now;
# need to be defined with 'our'.
# Otherwise we get a warning like
#     Name "Batch::try_queue" used only once: possible typo at ./rqg_batch.pl line 1766.
# , NO abort and no modification of the queue defined here.
# Alternative solution:
# Define with 'my' and the routines from other packages call some routine from here which
# does the required manipulation.


use strict;

use GenTest::Constants;
use GenTest;
use File::Copy;
use Cwd;
use Auxiliary;
use Batch;


# The recommendations given by ResourceControl
# --------------------------------------------
# Starting some additional RQG worker would be acceptable.
use constant LOAD_INCREASE  => 'load_increase';
# Starting some additional RQG worker is not recommended but stopping one RQG worker is
# not required.
use constant LOAD_KEEP      => 'load_keep';
# Stopping one RQG worker is highly recommended.
use constant LOAD_DECREASE  => 'load_decrease';
# Stopping all RQG worker is highly recommended.
use constant LOAD_GIVE_UP   => 'load_give_up';
# Required functionality not available.
use constant LOAD_UNKNOWN   => 'load_unknown';

# Storage space unit used for calculations is MB
use constant SPACE_UNIT     => 1048576;
#
# Storage space in MB required in workdir for RQG log + archive for one failing RQG run.
use constant SPACE_REMAIN   => 100;
# Storage space in MB which should stay unused in workdir
use constant SPACE_FREE     => 10000;
#
# Storage space in MB required in vardir by one ongoing RQG run without core.
use constant SPACE_USED     => 300;
# Storage space in MB required in vardir by a core (ASAN Build).
use constant SPACE_CORE     => 3000;
# Share of RQG actual runs which could start to end with core in parallel.
use constant SHARE_CORE     => 0.1;


use constant VARDIR_FREE   => 0;
use constant WORKDIR_FREE  => 1;
use constant MEM_REAL_FREE => 2;
use constant SWAP_USED_PER => 3;


my $df_available;
my $sys_available;

BEGIN {
    # Ubuntu: libfilesys-df-perl
    if (not defined (eval "require Filesys::Df")) {
        say("WARNING: Couldn't load Module Filesys::Df $@");
        $df_available = 0;
    } else {
        $df_available = 1;
    }
    # Ubuntu: libsys-statistics-linux-perl
    if (not defined (eval "require Sys::Statistics::Linux")) {
        say("WARNING: Couldn't load Module Sys::Statistics::Linux $@");
        $sys_available = 0;
    } else {
        $sys_available = 1;
    }
}


my $vardir;
my $vardir_free_init;
my $workdir;
my $workdir_free_init;
my $mem_real_free_init;
my $parallel;
my $cpu_free_init;
my $lxs;
my $book_keeping = 0;
my $book_keeping_file;
my $print = 0;


sub init {
    ($workdir, $vardir, my $parallel_assigned, $book_keeping) = @_;
    Carp::cluck("DEBUG: ResourceControl::init") if Auxiliary::script_debug("R2");

    if (not defined $vardir) {
        Carp::cluck("INTERNAL ERROR: vardir is undef.");
        return LOAD_GIVE_UP, undef;
    }
    if (not -d $vardir) {
        Carp::cluck("INTERNAL ERROR: vardir '$vardir' does not exist or is not a directory.");
        return LOAD_GIVE_UP, undef;
    }
    if (not defined $workdir) {
        Carp::cluck("INTERNAL ERROR: workdir is undef.");
        return LOAD_GIVE_UP, undef;
    }
    if (not -d $workdir) {
        Carp::cluck("INTERNAL ERROR: workdir '$workdir' does not exist or is not a directory.");
        return LOAD_GIVE_UP, undef;
    }
    if (not defined $parallel_assigned) {
        Carp::cluck("INTERNAL ERROR: parallel is undef.");
        return LOAD_GIVE_UP, undef;
    }

    if (not $df_available) {
        say("INFO: ResourceControl regarding storage space usage is not available.");
        if (not osWindows()) {
            say("HINT: Please install the perl module 'Filesys::Df'.");
        }
    }
    if (not $sys_available) {
        say("INFO: ResourceControl regarding cpu/vm usage/etc. is not available.");
        if (not osWindows()) {
            say("HINT: Please install the perl module 'Sys::Statistics::Linux'.");
        }
        if (0 == $parallel_assigned) {
            say("ERROR: Proposing a good maximum value for 'parallel' is impossible because " .
                "the rqg_batch ResourceControl is not available.");
            return LOAD_GIVE_UP, undef;
        } else {
            return LOAD_UNKNOWN, undef;
        }
    } else {
        # The description was mostly taken from CPAN.
        $lxs = Sys::Statistics::Linux->new(
            sysinfo   => 1,
            # memtotal   -  The total size of memory.
            # swaptotal  -  The total size of swap space.
            # pcpucount  -  The total number of physical CPUs.
            # tcpucount  -  The total number of CPUs (cores, hyper threading). <== ?
            cpustats  => 0,
            # Not that important but maybe used later
            # user    -  Percentage of CPU utilization at the user level.
            # nice    -  Percentage of CPU utilization at the user level with nice priority.
            # system  -  Percentage of CPU utilization at the system level.
            # idle    -  Percentage of time the CPU is in idle state.
            # total   -  Total percentage of CPU utilization.
            # Statistics with kernels >= 2.6 give in addition
            # iowait  -  Percentage of time the CPU is in idle state because an I/O operation
            #            is waiting to complete.
            # irq     -  Percentage of time the CPU is servicing interrupts.
            # softirq -  Percentage of time the CPU is servicing softirqs.
            # steal   -  Percentage of stolen CPU time, which is the time spent in other
            #            operating systems when running in a virtualized environment (>=2.6.11).
            memstats  => 1,
            # realfree    -  Total size of memory is real free (memfree + buffers + cached).   <======
            # swapused    -  Total size of swap space is used is kilobytes.                    <======
            # swapusedper -  Total size of swap space is used in percent                       <======
            pgswstats => 0,
            # Not that important but maybe used later
            # pgpgin      -  Number of pages the system has paged in from disk per second.
            # pgpgout     -  Number of pages the system has paged out to disk per second.
            # pswpin      -  Number of pages the system has swapped in from disk per second.
            # pswpout     -  Number of pages the system has swapped out to disk per second.
            processes => 0,
            # Not that important but maybe used later
        );
    }

    my $nproc = `nproc`;
    if (not defined $nproc) {
        say("ERROR: The command 'nproc' gave some undef result.");
        return LOAD_GIVE_UP, undef;
    }
    chomp $nproc; # Remove the '\n'
    my $parallel_estimated = int ( 1.5 * $nproc );
    if (0 == $parallel_assigned) {
        $parallel = $parallel_estimated;
        say("INFO: The maximum number of parallel RQG runs was not defined(0 assigned). " .
            "Setting it to $parallel.");
    } else {
        $parallel = $parallel_assigned;
    }

    $book_keeping_file = $workdir . "/" . "resource.txt";
    if ($book_keeping) {
        Batch::make_file($book_keeping_file,undef);
    }

    my @return = measure();
    my $vardir_free        = $return[VARDIR_FREE];
    my $workdir_free       = $return[WORKDIR_FREE];
    my $mem_real_free      = $return[MEM_REAL_FREE];
    my $swap_used_per      = $return[SWAP_USED_PER];

    $vardir_free_init   = $vardir_free;
    $workdir_free_init  = $workdir_free;
    $mem_real_free_init = $mem_real_free;

    $print = 0; # Only now 'report' should not write into the bookkeeping file.
    my $load_status = report(0);
    $print = $book_keeping;

    if (LOAD_INCREASE ne $load_status) {
        say("ERROR: ResourceControl::init : We are at begin of some rqg_batch run and the " .
            "resource consumption is already too bad. Sorry");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        Batch::emergency_exit($status);
    }

    # Preload data into variables belonging to the std output
    my $worker_active = 0;
    my $vardir_used   = 0;
    my $workdir_used  = 0;
    if ($book_keeping) {
        my $iso_ts = isoTimestamp();
        my $val  = mem_usage();
        my $line = "$iso_ts vardir  '$vardir'  free : $vardir_free_init\n"                         .
                   "$iso_ts workdir '$workdir' free : $workdir_free_init\n"                        .
                   "$iso_ts memory real free        : $mem_real_free_init\n"                       .
                   "$iso_ts swap space used percent : $swap_used_per\n"                                .
                   "$iso_ts nproc                   : $nproc\n"                                    .
                   "$iso_ts parallel (assigned)     : $parallel_assigned\n"                        .
                   "$iso_ts parallel (estimated)    : $parallel_estimated\n"                       .
                   "$iso_ts parallel (used)         : $parallel\n"                                 .
                   "$iso_ts return (to rqg_batch)   : $load_status, $parallel\n"                   .
                   "$iso_ts Title1 : worker - vardir_used - vardir_free - workdir_used - workdir_free - mem_used - mem_free\n" .
                   "$iso_ts          *_used means consumed since initialization of our rqg_batch run\n"                        .
                   "$iso_ts          Assumption: Consumed by RQG runs rqg_batch has started.\n"    .
                   "$iso_ts Title2 : vsz - rsz - sz - size\n"                                      .
                   "---------------------------------------------------------------------------\n" .
                   "$iso_ts $worker_active, " .  # There is in the moment no active worker.
                       int($vardir_used)  . " - " . int($vardir_free)  . " - " .
                       int($workdir_used) . " - " . int($workdir_free) . " - " .
                       int($mem_real_free). " - " . int($swap_used_per)    . " - " .
                       $load_status       . "\n"  .
                  "$iso_ts  $val";
        Batch::append_string_to_file($book_keeping_file, $line);
    }
    return $load_status, $parallel;

    # Return an estimation
    # - when to start with delaying
    # - How many test in max in parallel
    # - if loadcontrol impossible
    #   missing Filesys::Df
}

sub report {
    my ($worker_active) = @_;

    # A call with functionality like 'du' is missing because
    # - a corresponding Perl module is not part of the "standard" Ubuntu install
    # - I fear using 'du' from OS level is too slow
    # So we go with the estimation that the diff between current free space and free space at init
    # time is caused by space consumption of our rgq_batch run.
    my @return = measure();
    my $vardir_free        = $return[VARDIR_FREE];
    my $workdir_free       = $return[WORKDIR_FREE];
    my $mem_real_free      = $return[MEM_REAL_FREE];
    my $swap_used_per      = $return[SWAP_USED_PER];

    my $vardir_used  = $vardir_free_init  - $vardir_free;
    my $workdir_used = $workdir_free_init - $workdir_free;

    # Setting $load_status = LOAD_GIVE_UP serves basically three purposes
    # a) prevent that one possible bad event (one RQG test dies with core) leads to losing the
    #    control over the testing box (no more acceptable response times, OS crash etc.)
    # b) catch the cases where the rules of thumb in ResourceControl combined with how rqg_batch
    #    uses ResourceControl were not able to prevent that we reached a dangerous situation
    # c) catch the cases where the user should take care of the state (cleanup , what runs in
    #    parallel etc.) of his testing box.
    my $load_status;
    if      (defined $vardir_free and $vardir_free < SPACE_CORE) {
            # One worker dies with core and we would hit no more space in filesystem.
        say("INFO: (1) The free space in '$vardir' ($vardir_free MB) is dangerous small.");
        $load_status = LOAD_GIVE_UP;
    } elsif (defined $workdir_free and $workdir_free < SPACE_FREE) {
            # We are below the free space threshould for a rqg_batch run in general.
        say("INFO: (2) The free space in '$workdir' ($workdir_free MB) is dangerous small.");
        $load_status = LOAD_GIVE_UP;
    } elsif (defined $mem_real_free and $mem_real_free < SPACE_CORE) {
            # One worker dies with core and we would start to use the swap space.
        say("INFO: (3) The real free memory ($mem_real_free MB) is dangerous small.");
        $load_status = LOAD_GIVE_UP;

    # Setting $load_status = LOAD_DECREASE serves to prevent that we reach the state where we
    # - must set LOAD_GIVE_UP and abort the rqg_batch run
    # - start to use the swap space serious which is assumed to be bad if
    #   - using an SSD for it (danger SSD Lifetime?)
    #   - using an HDD which than means the response time of the testing box might become huge
    # This is done by assuming that some estimated fraction of ongoing RQG runs dies with core
    # at roughly the same point of time.
    } elsif (defined $vardir_free and $vardir_free < $worker_active * SHARE_CORE * SPACE_CORE) {
            # The estimated fraction of workers die with core at the same point of time and
            # we would hit no more space in filesystem.
        say("INFO: (1) The free space in '$vardir' ($vardir_free MB) is critical small.");
        $load_status = LOAD_DECREASE;
    } elsif (defined $workdir_free and $workdir_free < $worker_active * SPACE_REMAIN + SPACE_FREE) {
            # All active workers finish with fail + archiving etc. and we would fall below the
            # free space threshould.
        say("INFO: (2) The free space in '$workdir' ($workdir_free MB) is critical small.");
        $load_status = LOAD_DECREASE;
    } elsif (defined $mem_real_free and $mem_real_free < $worker_active * SHARE_CORE * SPACE_CORE) {
            # The estimated fraction of workers die with core at the same point of time and
            # we would start to use the swap space.
        say("INFO: (3) The real free memory ($mem_real_free MB) is critical small.");
        $load_status = LOAD_DECREASE;
    } elsif (defined $swap_used_per and $swap_used_per > 15) {
            # We have started to use the swap and that should not happen.
        $load_status = LOAD_DECREASE;
        say("INFO: (4) Swap space used ($swap_used_per %) > 15 %.");

    # Setting $load_status = LOAD_KEEP serves to prevent that we start some additional RQG run
    # which than maybe leads to the state that we must set LOAD_DECREASE and stop one RQG run.
    } elsif ($worker_active > 0   and
             defined $vardir_free and
             $vardir_free < (1 + $worker_active) * SHARE_CORE * SPACE_CORE
                            + $vardir_used / $worker_active ) {
        # An additional RQG worker raises the space consumption.
        say("INFO: (1) The free space in '$vardir' ($vardir_free MB) is not better than sufficient.");
        $load_status = LOAD_KEEP;
    } elsif ($worker_active > 0   and
             defined $vardir_free and
             $vardir_free < SPACE_CORE + $vardir_used / $worker_active ) {
        # An additional RQG worker could consume the usual amount of space and than die with core.
        say("INFO: (2) The free space in '$vardir' ($vardir_free MB) is not better than sufficient.");
        $load_status = LOAD_KEEP;
    } elsif (defined $workdir_free and
             $workdir_free < (1 + $worker_active) * SPACE_REMAIN + SPACE_FREE) {
        # All die with the usual amount of remainings.
        say("INFO: (3) The free space in '$workdir' ($workdir_free MB) is not better than sufficient.");
        $load_status = LOAD_KEEP;
    } elsif ($worker_active > 0   and
             defined $mem_real_free and
             $mem_real_free < (1 + $worker_active) * SHARE_CORE * SPACE_CORE
                               + $vardir_used / $worker_active ) {
        # An additional RQG worker raises the memory consumption and we do not want to use swap.
        say("INFO: (4) The real free memory ($mem_real_free MB) is not better than sufficient.");
        $load_status = LOAD_KEEP;
    } elsif ($worker_active > 0   and
             defined $mem_real_free and
             $mem_real_free < SPACE_CORE + $vardir_used / $worker_active ) {
        # An additional RQG worker raises the memory consumption and we do not want to use swap.
        say("INFO: (5) The real free memory ($mem_real_free MB) is not better than sufficient.");
        $load_status = LOAD_KEEP;

    # Either we
    # - do not know enough (not defined variables because of missing functionality) and are forced
    #   to just hope that all will work well
    # - the checks above did not reveal trouble
    } else {
        $load_status = LOAD_INCREASE;
    }

    if($print) {
        my $iso_ts = isoTimestamp();
        my $val = mem_usage();
        my $line = "$iso_ts $worker_active, " .
                       int($vardir_used)  . " - " . int($vardir_free)  . " - " .
                       int($workdir_used) . " - " . int($workdir_free) . " - " .
                       int($mem_real_free). " - " . int($swap_used_per)    . " - " .
                       $load_status       . "\n"  .
                   "$iso_ts  $val";
        Batch::append_string_to_file($book_keeping_file, $line);
    }
    return $load_status;
}

sub measure {

    my @return;
    if ($df_available) {
        my $ref;
        $ref = Filesys::Df::df($vardir, SPACE_UNIT);  # Default output is 1M blocks
        if(defined($ref)) {
            # bavail == Free space which the current user would be allowed to occupy.
            $return[VARDIR_FREE] = $ref->{bavail};
        } else {
            say("ERROR: df for '$vardir' failed.");
            my $status = STATUS_ENVIRONMENT_FAILURE;
            Batch::emergency_exit($status);
        }
        $ref = Filesys::Df::df($workdir, SPACE_UNIT);
        if(defined($ref)) {
            $return[WORKDIR_FREE] = $ref->{bavail};
        } else {
            say("ERROR: df for '$workdir' failed.");
            my $status = STATUS_ENVIRONMENT_FAILURE;
            Batch::emergency_exit($status);
        }
    } else {
        $return[VARDIR_FREE]  = undef;
        $return[WORKDIR_FREE] = undef;
    }
    if ($sys_available) {
        my $stat = $lxs->get();
        my $memstats  = $stat->memstats;
        $return[MEM_REAL_FREE]  = $stat->memstats->{realfree} / 1024;
        $return[SWAP_USED_PER]  = $stat->memstats->{swapusedper};
    } else {
        $return[MEM_REAL_FREE]  = undef;
        $return[SWAP_USED_PER]  = undef;
    }
    return @return;

}

sub mem_usage {

    if ($book_keeping) {
        my $iso_ts = isoTimestamp();
        return `ps -p $$ --no-headers -o vsz,rsz,sz,size`;
    }
}

1;


