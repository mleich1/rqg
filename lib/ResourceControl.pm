#  Copyright (c) 2018, 2019 MariaDB Corporation Ab.
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

use strict;

use GenTest::Constants;
use GenTest;
use File::Copy;
use Cwd;
use Auxiliary;
use Batch;


# The recommendations given by ResourceControl via return value
# -------------------------------------------------------------
# Starting some additional RQG worker would be acceptable. The final decision is done by the caller.
use constant LOAD_INCREASE  => 'load_increase';
# Starting some additional RQG worker is not recommended but stopping one RQG worker is
# not required.
use constant LOAD_KEEP      => 'load_keep';
# Stopping RQG workers till the problem has disappeared is highly recommended.
use constant LOAD_DECREASE  => 'load_decrease';
# Stopping all RQG worker is highly recommended.
use constant LOAD_GIVE_UP   => 'load_give_up';
# Required functionality not available.
use constant LOAD_UNKNOWN   => 'load_unknown';

# Storage space unit used for calculations is MB
use constant SPACE_UNIT     => 1048576;

# Basic guesses
# -------------
# Maximum storage space in MB required in workdir for RQG log + archive for one failing RQG run.
use constant SPACE_REMAIN   => 100;
# Storage space in MB which should stay unused in workdir
use constant SPACE_FREE     => 10000;
#
# Maximum storage space in MB required in vardir by one ongoing RQG run without core.
use constant SPACE_USED     => 300;   # <-- FIXME: measure
# Maximum storage space in MB required in vardir by a core (ASAN Build).
use constant SPACE_CORE     => 3000;  # <-- FIXME: measure
# Maximum share of RQG runs where an end with core is assumed.
use constant SHARE_CORE     => 0.1;
# Maximum memory consumption of a RQG run (ASAN build) (space in vardir ignored)
use constant MEM_USED       => 800;
# Archive of ASAN BUILD run with core (up to) 500
# vardir of ASAN BUILD run with core (up to) 1800 (core 1500)

my $module_missing = 0;

BEGIN {
    # Ubuntu: libfilesys-df-perl
    # Ubuntu: libsys-statistics-linux-perl
    foreach my $module ('Filesys::Df', 'Sys::Statistics::Linux') {
        if (not defined (eval "require $module")) {
           say("WARNING: ResourceControl: Couldn't load Module '$module' $@");
           $module_missing++;
        }
    }
}

# Frequent used variables
# -----------------------
# <what_ever>          -- actual value
# <what_ever>_init     -- actual value when rqg_batch.pl started.
# <what_ever>_consumed -- Amount consumed since start of rqg_batch.pl
#    <what_ever>_consumed = <what_ever>_free_init - <what_ever>_free
#    <what_ever>_consumed = <what_ever>_used - <what_ever>_used_init
my $mem_total;          # Amount of RAM in MB
my $mem_real_free_init;
my $mem_real_free;
my $mem_consumed;

my $vardir;             # Path to that directory
my $vardir_free_init;
my $vardir_free;
my $vardir_consumed;

my $workdir;            # Path to that directory
my $workdir_free_init;
my $workdir_free;
my $workdir_consumed;

my $swap_total;
my $swap_used_init;
my $swap_used;
my $swap_free;
my $swap_consumed;

my $parallel;
my $pcpu_count;
my $tcpu_count;

my $lxs;

my $previous_load_status = '';
my $previous_estimation  = '';
my $previous_line        = '';
my $previous_worker      = 0;

# Resource control types, bookkeeping types
use constant RC_NONE               => 'None';
use constant RC_BAD                => 'rc_bad';
use constant RC_CHANGE_1           => 'rc_change_1';
use constant RC_CHANGE_2           => 'rc_change_2';
use constant RC_ALL                => 'rc_all';
use constant RC_DEFAULT            => RC_CHANGE_2;
use constant RC_ALLOWED_VALUE_LIST => [ RC_NONE, RC_BAD, RC_CHANGE_1, RC_CHANGE_2, RC_ALL ];
my $rc_type;

my $book_keeping_file;
my $print = 0;

# Print the memory consumption of the process running rqg_batch
# -------------------------------------------------------------
# Failures within the code for the order management and especially the simplifier could tend
# to cause some dramatic growth of memory consumption.
my $rqg_batch_debug = 0;

# Print the estimated values
my $resource_control_debug = 0;

sub init {
    ($rc_type, $workdir, $vardir) = @_;

    if (3 != scalar @_) {
        Carp::cluck("INTERNAL ERROR: ResourceControl::init: 4 parameters " .
                    "(rc_type, workdir, vardir) are required");
        safe_exit(STATUS_INTERNAL_ERROR);
    }
    say("DEBUG: ResourceControl::init at begin") if Auxiliary::script_debug("L2");

    if (not defined $rc_type) {
        $rc_type = RC_DEFAULT;
        say("INFO: ResourceControl type was not assigned. Assuming the default '$rc_type'.");
    }
    my $result = Auxiliary::check_value_supported (
                    'type', RC_ALLOWED_VALUE_LIST, $rc_type);
    if ($result != STATUS_OK) {
        Carp::cluck("ERROR: The ResourceControl type '$rc_type' is not supported. Abort");
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }

    if ($rc_type eq RC_NONE) {
        say("WARN: Automatic ResourceControl is disabled. This is risky because increasing the " .
            "load is all time allowed.");
        return LOAD_INCREASE, undef, undef;
    } else {
        say("INFO: Automatic ResourceControl is enabled. Report type '$rc_type'.");
    }

    if (not defined $vardir) {
        Carp::cluck("INTERNAL ERROR: vardir is undef.");
        safe_exit(STATUS_INTERNAL_ERROR);
    }
    if (not -d $vardir) {
        Carp::cluck("INTERNAL ERROR: vardir '$vardir' does not exist or is not a directory.");
        safe_exit(STATUS_INTERNAL_ERROR);
    }
    if (not defined $workdir) {
        Carp::cluck("INTERNAL ERROR: workdir is undef.");
        safe_exit(STATUS_INTERNAL_ERROR);
    }
    if (not -d $workdir) {
        Carp::cluck("INTERNAL ERROR: workdir '$workdir' does not exist or is not a directory.");
        safe_exit(STATUS_INTERNAL_ERROR);
    }

    if ($module_missing) {
        say("ERROR: ResourceControl::init: Required functionality is missing.\n"                   .
            "HINT: Please\n"                                                                       .
            "HINT: - RECOMMENDED\n"                                                                .
            "HINT:   Use a box with Linux OS and install the perl modules\n"                       .
            "HINT:      'Filesys::Df' and 'Sys::Statistics::Linux'\n"                              .
            "HINT:   Example for Ubuntu 17.10:\n"                                                  .
            "HINT:      sudo apt-get install libfilesys-df-perl libsys-statistics-linux-perl\n"    .
            "HINT: or\n"                                                                           .
            "HINT: - more or less RISKY\n"                                                         .
            "HINT:   1. Append '--no_resource_control' to your call of rqg_batch.pl\n"             .
            "HINT:   2. Assign at begin a small value to the parameter 'parallel'\n"               .
            "HINT:   3. Observe the system behaviour during the rqg_batch run and raise "          .
            "HINT:      the value assigned to 'parallel' slowly.");
    }

    # The description was mostly taken from CPAN.
    $lxs = Sys::Statistics::Linux->new(
        sysinfo   => 1,
        # memtotal   -  The total size of memory.
        # swaptotal  -  The total size of swap space.
        # pcpucount  -  The total number of physical CPUs.
        # tcpucount  -  The total number of CPUs (cores, hyper threading). <== ?
        cpustats  => 0,    # Does not work well from unknown reason
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
        # swapusedper -  Total size of swap space is used in percent
        pgswstats => 0,
        # Not that important but maybe used later
        # FIXME: Heavy paging seen + bad for the SSD
        # pgpgin      -  Number of pages the system has paged in from disk per second.
        # pgpgout     -  Number of pages the system has paged out to disk per second.
        # pswpin      -  Number of pages the system has swapped in from disk per second.
        # pswpout     -  Number of pages the system has swapped out to disk per second.
        processes => 0,
        # Not that important but maybe used later
    );
    $lxs->init;

    measure();

#   my $nproc = `nproc`;
#   if (not defined $nproc) {
#       say("ERROR: The command 'nproc' gave some undef result.");
#       return LOAD_GIVE_UP, undef;
#   }
#   chomp $nproc; # Remove the '\n'

    $book_keeping_file = $workdir . "/" . "resource.txt";
    if ($rc_type) {
        Batch::make_file($book_keeping_file, undef);
    }


    $vardir_free_init   = $vardir_free;
    $workdir_free_init  = $workdir_free;
    $mem_real_free_init = $mem_real_free;
    $swap_used_init     = $swap_used;

    $print = 0; # Only now 'report' should not write into the bookkeeping file.
    my $load_status = report(0);
    $print = $rc_type;

    if (LOAD_INCREASE ne $load_status) {
        say("ERROR: ResourceControl::init : We are at begin of some rqg_batch run and the " .
            "resource consumption is already too bad. Sorry");
        ask_tool();
        safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }

    # Preload data into variables belonging to the std output
    my $worker_active = 0;
    my $vardir_used   = 0;
    my $workdir_used  = 0;

    # Estimations regarding the safe and average number of workers.
    # ------------------------------------------------------------------------------
    my $val;
    my $workers_min;
    my $workers_mid;
    # Worst case estimations
    # Lower the value if its too big.
    # RAM - 12000 = $workers * (2 * (MEM_USED + SPACE_USED) + SHARE_CORE * SPACE_CORE)
    #               - SHARE_CORE * SPACE_CORE + SPACE_CORE;
    $val = int(($mem_total - 12000 + SHARE_CORE * SPACE_CORE - SPACE_CORE) /
           (2 * (MEM_USED + SPACE_USED) + SHARE_CORE * SPACE_CORE));
    say("DEBUG: workers_min 1: $val");
    $workers_min = $val;
    # vardir_free > $workers * (2 * SPACE_USED + SHARE_CORE * SPACE_CORE)
    #               - SHARE_CORE * SPACE_CORE + SPACE_CORE;
    $val = int(($vardir_free + SHARE_CORE * SPACE_CORE - SPACE_CORE ) /
           (2 * SPACE_USED + SHARE_CORE * SPACE_CORE));
    say("DEBUG: workers_min 2: $val");
    if ($val < $workers_min) {
        $workers_min = $val;
    }
    say("DEBUG: workers_min final: $workers_min");

    # --------------
    # Average case estimations
    # RAM - 10 GB = $workers * (MEM_USED + SPACE_USED + SHARE_CORE * SPACE_CORE);
    #               - SHARE_CORE * SPACE_CORE + SPACE_CORE;
    $val = int(($mem_total - 10000 + SHARE_CORE * SPACE_CORE - SPACE_CORE) /
           (MEM_USED + SPACE_USED + SHARE_CORE * SPACE_CORE));
    say("DEBUG: workers_mid 1: $val");
    $workers_mid = $val;
    # vardir_free > $workers * (SHARE_CORE * SPACE_CORE + SPACE_USED);
    $val = int(($vardir_free + SHARE_CORE * SPACE_CORE - SPACE_CORE ) /
           (SPACE_USED + SHARE_CORE * SPACE_CORE));
    say("DEBUG: workers_mid 2: $val");
    if ($val < $workers_mid) {
        $workers_mid = $val;
    }
    say("DEBUG: workers_mid final: $workers_mid");

    if ($rc_type) {
        my $iso_ts = isoTimestamp();
        my $line = "$iso_ts ResourceControl type    : $rc_type\n"                                  .
                   "$iso_ts vardir  '$vardir'  free : $vardir_free_init\n"                         .
                   "$iso_ts workdir '$workdir' free : $workdir_free_init\n"                        .
                   "$iso_ts memory total            : $mem_total\n"                                .
                   "$iso_ts memory real free        : $mem_real_free_init\n"                       .
                   "$iso_ts swap space total        : $swap_total\n"                               .
                   "$iso_ts swap space used         : $swap_used_init\n"                           .
                   "$iso_ts cpu cores (HT included) : $tcpu_count\n"                               .
                   "$iso_ts parallel (est. min)     : $workers_min\n"                              .
                   "$iso_ts parallel (est. mid)     : $workers_mid\n"                              .
                   "$iso_ts return (to rqg_batch)   : $load_status, $workers_mid, $workers_min\n"  .
                   "---------------------------------------------------------------------------\n" .
                   "$iso_ts     *_consumed means amount lost since start of our rqg_batch run\n"   .
                   "$iso_ts worker , vardir_consumed - vardir_free , "                             .
                                    "workdir_consumed - workdir_free , "                           .
                                    "mem_consumed - mem_real_free , "                              .
                                    "swap_consumed - swap_free = load_status\n";
        if ($rqg_batch_debug) {
            $line .= "$iso_ts     vsz - rsz - sz - size #### rqg_batch process\n";
        }
        $line .=   "---------------------------------------------------------------------------\n" .
                   "$iso_ts $worker_active, " .  # There is in the moment no active worker.
                       $vardir_used   . " - " . $vardir_free   . " - " .
                       $workdir_used  . " - " . $workdir_free  . " - " .
                       $mem_real_free . " - " . $swap_used . " - " .
                       $load_status       . "\n";
        if ($rqg_batch_debug) {
            my $val  = mem_usage();
            $line .= "$iso_ts  $val";
        }
        Batch::append_string_to_file($book_keeping_file, $line);
    }
    return $load_status, $workers_mid, $workers_min;

    # Return an estimation
    # - when to start with delaying
    # - How many test in max in parallel
    # ??
}


sub report {
    my ($worker_active) = @_;

    if ($rc_type eq RC_NONE) {
        return LOAD_INCREASE;
    }

    # A call with functionality like 'du' is missing because
    # - a corresponding Perl module is not part of the "standard" Ubuntu install
    # - I fear using 'du' from OS level is too slow
    # So we go with the estimation that the diff between current free space and free space at init
    # time is caused by space consumption of our rgq_batch run.
    measure();

    $vardir_consumed   = $vardir_free_init   - $vardir_free;
    $workdir_consumed  = $workdir_free_init  - $workdir_free;
    $mem_consumed      = $mem_real_free_init - $mem_real_free;
    $swap_consumed     = $swap_used          - $swap_used_init;
    $swap_free         = $swap_total         - $swap_used;

    # Setting $load_status = LOAD_GIVE_UP serves basically three purposes
    # a) prevent that one possible bad event (one RQG test dies with core) leads to losing the
    #    control over the testing box (no more acceptable response times, OS crash etc.)
    # b) catch the cases where the rules of thumb in ResourceControl combined with how rqg_batch
    #    uses ResourceControl were not able to prevent that we reached a dangerous situation
    # c) catch the cases where the user should take care of the state (cleanup , what runs in
    #    parallel etc.) of his testing box.
    my $vr_U;
    my $mr_U;
    my $rr_U;
    my $sr_U;
    my $wr_U;
    my $rd_U;
    #
    # One worker dies with core and we would hit no more space in filesystem.
    $vr_U = $vardir_free - SPACE_CORE;
    # We are below the free space threshold for a rqg_batch run in general.
    $wr_U = $workdir_free - SPACE_FREE;
    # One worker dies with core which has to be placed in tmpfs. The current virtual memory
    # usage forces to put stuff (parts of running programs and/or parts of vardir occupied
    # by files) with a size like that core into the swap. And there is not enough free.
    $sr_U = $swap_free - SPACE_CORE;
    $sr_U = 0 if 0 == $swap_free;
    $mr_U = $mem_real_free - 0; # Basically no idea
    # 8000 MB is a guess based on
    #     RQG on skylake01, swap space use started to grow and
    #     192 GB - ($vardir_consumed + $mem_consumed) = 8000 MB.
    $rd_U = $vardir_consumed + $mem_consumed + 8000;
    $rr_U = $mem_total - $rd_U;

#----------------------

    # Setting $load_status = LOAD_DECREASE serves to prevent that we reach the state where we
    # - must set LOAD_GIVE_UP and abort the rqg_batch run
    # - start to use the swap space serious which is assumed to be bad if
    #   - using an SSD for it (danger for SSD lifetime?)
    #   - using an HDD which than means the response time of the testing box might become huge
    # This is done by assuming that some estimated fraction of ongoing RQG runs dies with core
    # at roughly the same point of time.
    #
    my $vr_D;
    my $mr_D;
    my $rr_D;
    my $sr_D;
    my $wr_D;
    my $vd_D;
    my $rd_D;
    my $sd_D;
    # The estimated fraction of workers or at least one dies with core at the same point of time.
    $vd_D = $worker_active * SHARE_CORE * SPACE_CORE;
    if ($vd_D < SPACE_CORE) {
        $vd_D = SPACE_CORE;
    }
    $vr_D = $vardir_free - $vd_D;
    $sd_D = $vd_D;
    $sr_D = $swap_free - $sd_D;
    $sr_D = 0 if 0 == $swap_free;
    # All active workers finish with fail + archiving etc. and we would fall below the free space
    # threshold for the workdir. Some moderate decrease of activity till stop would be good.
    $wr_D = $workdir_free - $worker_active * SPACE_REMAIN + SPACE_FREE;
    # In case the already existing space consumption ($vardir_consumed + $mem_consumed + 8000)
    # and feared additional space consumption ($vd_D + 1000) exceeds the total amount of RAM
    # ($mem_total) than the OS will be forced to use more swap space that we do not want.
    $rd_D = $vd_D + $vardir_consumed + $mem_consumed + 8000 + 1000;
    $rr_D = $mem_total - $rd_D;
    $mr_D = $mem_real_free - 0; # Basically no idea

#----------------------

    # Setting $load_status = LOAD_KEEP serves to prevent that we start some additional RQG run
    # which than maybe leads to the state that we must set LOAD_DECREASE and stop one RQG run.
    #
    my $vr_K;
    my $mr_K;
    my $rr_K;
    my $sr_K;
    my $wr_K;
    my $vd_K;
    my $wd_K;
    my $md_K;
    my $rd_K;
    # An additional RQG worker has
    # - his own space consumption even without crashing
    # - similar risk to crash with core
    # and all the other already active RQG workers could crash too.
    if ($worker_active > 0) {
        $vd_K = $worker_active * SHARE_CORE * SPACE_CORE + SPACE_CORE
                + $vardir_consumed / $worker_active;
    } else {
        $vd_K = SPACE_CORE + SPACE_USED;
    }
    $vr_K = $vardir_free - $vd_K;

    # An additional RQG worker needs some memory (tmpfs not counted).
    if ($worker_active > 0) {
        $md_K = $mem_consumed / $worker_active;
    } else {
        $md_K = MEM_USED;
    }
    $mr_K = $mem_real_free - $md_K;

    $sr_K = $sr_D; # Have no good idea.
    $sr_K = 0 if 0 == $swap_free;

    # In case the estimated space consumed in memory ($md_K) and the estimated space in vardir
    # ($vd_K) exceeds the total amount of RAM ($mem_total) than we will maybe
    # a) (there is swap space at all) forced to use more swap space what we do not want
    # or
    # b) (no swap space at all) the OS starts to kill processes what we must avoid with all means.
    # 8000 MB is a guess based on
    #     RQG on skylake01, swap space use started to grow and
    #     192 GB - ($vardir_consumed + $mem_consumed) = 8000 MB.
    $rd_K = $md_K + $vd_K + $vardir_consumed + $mem_consumed + 10000;
    $rr_K = $mem_total - $rd_K;

    # All worker finish with the usual amount of remainings.
    $wd_K = (1 + $worker_active) * SPACE_REMAIN + SPACE_FREE; # ????
    $wr_K = $workdir_free - $wd_K;

    my $estimation =
    "DEBUG: Estimation for vardir           : ".int($vr_U)." , ".int($vr_D)." , ".int($vr_K)."\n".
    "DEBUG: Estimation for RAM/avoid paging : ".int($rr_U)." , ".int($rr_D)." , ".int($rr_K)."\n".
    "DEBUG: Estimation for memory           : ".int($mr_U)." , ".int($mr_D)." , ".int($mr_K)."\n".
    "DEBUG: Estimation for swapspace        : ".int($sr_U)." , ".int($sr_D)." , ".int($sr_K)."\n".
    "DEBUG: Estimation for workdir          : ".int($wr_U)." , ".int($wr_D)." , ".int($wr_K)."\n";

    my $load_status;
    my $info_m = '';
    my $info   = '';
    if (not defined $load_status) {
        my $end_part = "is dangerous small.";
        if      (0 > $vr_U) {
            $info_m = "G1";
            $info = "INFO: $info_m The free space in '$vardir' ($vardir_free MB) $end_part";
            $load_status = LOAD_GIVE_UP;
        } elsif (0 > $mr_U) {
            $info_m = "G2";
            $info = "INFO: $info_m The free memory ($mem_real_free MB) $end_part";
            $load_status = LOAD_GIVE_UP;
        } elsif (0 > $rr_U) {
            $info_m = "G3";
            $info = "INFO: $info_m The space consumption for the RAM ($mem_total MB) $end_part";
            $load_status = LOAD_GIVE_UP;
        } elsif (0 > $sr_U) {
            $info_m = "G4";
            $info = "INFO: $info_m The free swap ($swap_free MB) $end_part";
            $load_status = LOAD_GIVE_UP;
        } elsif (0 > $wr_U) {
            $info_m = "G5";
            $info = "INFO: $info_m The free space in '$workdir' ($workdir_free MB) $end_part";
            $load_status = LOAD_GIVE_UP;
        }
    }

    if (not defined $load_status) {
        my $end_part = "is critical.";
        if      (0 > $vr_D) {
            $info_m = "D1";
            $info = "INFO: $info_m The free space in '$vardir' ($vardir_free MB) $end_part";
            $load_status = LOAD_DECREASE;
        } elsif (0 > $mr_D) {
            $info_m = "D2";
            $info = "INFO: $info_m The free memory ($mem_real_free MB) $end_part";
            $load_status = LOAD_DECREASE;
        } elsif (0 > $rr_D) {
            $info_m = "D3";
            $info = "INFO: $info_m The space consumption for the RAM ($mem_total MB) $end_part";
            $load_status = LOAD_DECREASE;
        } elsif (0 > $sr_D) {
            $info_m = "D4";
            $info = "INFO: $info_m The free swap ($swap_free MB) $end_part";
            $load_status = LOAD_DECREASE;
        } elsif (0 > $wr_D) {
            $info_m = "D5";
            $info = "INFO: $info_m The free space in '$workdir' ($workdir_free MB) $end_part";
            $load_status = LOAD_DECREASE;
        }
    }

    if (not defined $load_status) {
        my $end_part = "is not better than just sufficient.";
        if      (0 > $vr_K) {
            $info_m = "K1";
            $info = "INFO: $info_m The free space in '$vardir' ($vardir_free MB) $end_part";
            $load_status = LOAD_KEEP;
        } elsif (0 > $mr_K) {
            $info_m = "K2";
            $info = "INFO: $info_m The free memory ($mem_real_free MB) $end_part";
            $load_status = LOAD_KEEP;
        } elsif (0 > $rr_K) {
            $info_m = "K3";
            $info = "INFO: $info_m The space consumption for the RAM ($mem_total MB) $end_part";
            $load_status = LOAD_KEEP;
        } elsif (0 > $sr_K) {
            $info_m = "K4";
            $info = "INFO: $info_m The free swap ($swap_free MB) $end_part";
            $load_status = LOAD_KEEP;
        } elsif (0 > $wr_K) {
            $info_m = "K5";
            $info = "INFO: $info_m The free space in '$workdir' ($workdir_free MB) $end_part";
            $load_status = LOAD_KEEP;
        }
    }

    # Either we
    # - do not know enough (not defined variables because of missing functionality) and are forced
    #   to just hope that all will work well
    # - the checks above did not reveal trouble
    if (not defined $load_status) {
        $load_status = LOAD_INCREASE;
    } else {
        say($info) if Auxiliary::script_debug("L2");
    }

    my $iso_ts = isoTimestamp();
    my $line = "$iso_ts $worker_active , " .
                   $vardir_consumed   . " - " . $vardir_free   . " , " .
                   $workdir_consumed  . " - " . $workdir_free  . " , " .
                   $mem_consumed      . " - " . $mem_real_free . " , " .
                   $swap_consumed     . " - " . $swap_free     . " = " .
                   $load_status       . " $info_m\n";
    if ($rqg_batch_debug) {
        my $val  = mem_usage();
        $line .= "$iso_ts  $val";
    }

    if($print) {
        if      (RC_CHANGE_1 eq $rc_type and
                $previous_load_status ne $load_status) {
                Batch::append_string_to_file($book_keeping_file, $previous_line);
                Batch::append_string_to_file($book_keeping_file, $line);
                if ($resource_control_debug) {
                    Batch::append_string_to_file($book_keeping_file, $estimation);
                }
        } elsif (RC_CHANGE_2 eq $rc_type and
                 ($previous_load_status ne $load_status or $previous_worker != $worker_active)) {
                Batch::append_string_to_file($book_keeping_file, $previous_line);
                Batch::append_string_to_file($book_keeping_file, $line);
                if ($resource_control_debug) {
                    Batch::append_string_to_file($book_keeping_file, $estimation);
                }
        } elsif (RC_BAD eq $rc_type and
                 (LOAD_GIVE_UP eq $load_status or LOAD_DECREASE eq $load_status)) {
                Batch::append_string_to_file($book_keeping_file, $line);
                if ($resource_control_debug) {
                    Batch::append_string_to_file($book_keeping_file, $estimation);
                }
        } elsif (RC_ALL eq $rc_type) {
                Batch::append_string_to_file($book_keeping_file, $line);
                if ($resource_control_debug) {
                    Batch::append_string_to_file($book_keeping_file, $estimation);
                }
        } else {
                # Print nothing
        }
        if (LOAD_GIVE_UP eq $load_status) {
            ask_tool();
        }
    }
    $previous_load_status = $load_status;
    $previous_estimation  = $estimation;
    $previous_line        = $line;
    $previous_worker      = $worker_active;
    return $load_status;
}

sub measure {

        my $ref;
        $ref = Filesys::Df::df($vardir, SPACE_UNIT);  # Default output is 1M blocks
        if(defined($ref)) {
            # bavail == Free space which the current user would be allowed to occupy.
            $vardir_free = int($ref->{bavail});
        } else {
            say("ERROR: df for '$vardir' failed.");
            my $status = STATUS_ENVIRONMENT_FAILURE;
            Batch::emergency_exit($status);
        }
        $ref = Filesys::Df::df($workdir, SPACE_UNIT);
        if(defined($ref)) {
            $workdir_free = int($ref->{bavail});
        } else {
            say("ERROR: df for '$workdir' failed.");
            my $status = STATUS_ENVIRONMENT_FAILURE;
            Batch::emergency_exit($status);
        }
        my $stat = $lxs->get();
        # my $sysinfo   = $stat->sysinfo;
        # 32817156 kB
        $mem_total = $stat->sysinfo->{memtotal};
        # Cut the appended " kB" away.
        $mem_total =~ s{ kB$}{}mi;
        if (not defined (eval "$mem_total + 1")) {
            Carp::cluck("INTERNAL ERROR: mem_total($mem_total) is not numeric.");
            my $status = STATUS_INTERNAL_ERROR;
            Batch::emergency_exit($status);
        }
        $mem_total  = int($mem_total  / 1024);

        $swap_total = $stat->sysinfo->{swaptotal};
        # Cut the appended " kB" away.
        $swap_total =~ s{ kB$}{}mi;
        if (not defined (eval "$swap_total + 1")) {
            Carp::cluck("INTERNAL ERROR: swap_total($swap_total) is not numeric.");
            my $status = STATUS_INTERNAL_ERROR;
            Batch::emergency_exit($status);
        }
        $swap_total = int($swap_total / 1024);

        $pcpu_count = $stat->sysinfo->{pcpucount};
        $tcpu_count = $stat->sysinfo->{tcpucount};

        # my $memstats  = $stat->memstats;
        $mem_real_free = int($stat->memstats->{realfree} / 1024);
        $swap_used     = int($stat->memstats->{swapused} / 1024);

}

sub mem_usage {
    my $iso_ts = isoTimestamp();
    return `ps -p $$ --no-headers -o vsz,rsz,sz,size`;
}

sub ask_tool {
    system("free");
    system("df -vk");
    system("ps -elf");
}

1;


