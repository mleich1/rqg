#  Copyright (c) 2018 - 2022 MariaDB Corporation Ab.
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

use GenTest_e::Constants;
use GenTest_e;
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
# FIXME: measure
# average run          ~  300 MB
# rr for all processes ~ 2000 MB   roughly never used
# rr for bootstrap, start, restart with recovery  ~ 500MB
use constant SPACE_USED     => 300;   # <-- FIXME: measure
                                      # Problem: We could have temporary doubling or similar.
# Maximum storage space in MB required in vardir by a core (ASAN Build).
# AFAIR seen
# ASAN build   core ~ 2000 MB
# debug build  core ~  900 MB but rare also 1800 MB observed.
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

# Experiences
# -----------
# mem_total ~ Amount of RAM
# Generate/add a file of 1 GB size in /dev/shm   Changes in output of GNU free
# mem-free      - 1 GB
# mem-used      ~ no change
# buff/cache    + 1 GB
# mem_available - 1 GB
#
# Sysinfo ....
# memfree       - 1 GB
# buffers       + 1 GB
# cached        ~ no change
# realfree      ~ no change (Total size of memory is real free (memfree + buffers + cached).)
#               Hence realfree is not useful for the ResourceControl here because
#               1. It contains the data in vardir which was not moved to swap.
#               2. Given the fact that paging must be prevented in order to safe SSD lifetime
#                  - we need to estimate with all vardir content in real memory
#                  - ensure that paging does not happen.
#                    This is tried by disallowing the used swap space to grow.
#

# Frequent used variables
# -----------------------
# <what_ever>          -- actual value
# <what_ever>_init     -- actual value when rqg_batch.pl started.
# <what_ever>_consumed -- Amount consumed since start of rqg_batch.pl
#    <what_ever>_consumed = <what_ever>_free_init - <what_ever>_free
#    <what_ever>_consumed = <what_ever>_used - <what_ever>_used_init
my $mem_total;          # Amount of RAM in MB
my $mem_est_free_init;
my $mem_est_free;
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
my $pswpout;

my $parallel;
my $pcpu_count;
my $tcpu_count;

my $cpu_idle;
my $cpu_iowait;
my $cpu_system;
my $cpu_user;

my $lxs;   # All stuff of interest except CPU
my $lxs1;  # CPU only
our $lxs1_last_ts;

my $previous_load_status = '';
my $previous_estimation  = '';
my $previous_line        = '';
my $previous_worker      = 0;

# Resource control protocol types/bookkeeping types
use constant RC_NONE               => 'None';
use constant RC_BAD                => 'rc_bad';
use constant RC_CHANGE_1           => 'rc_change_1';
use constant RC_CHANGE_2           => 'rc_change_2';
use constant RC_CHANGE_3           => 'rc_change_3';
use constant RC_ALL                => 'rc_all';
use constant RC_DEFAULT            => RC_CHANGE_2;
use constant RC_ALLOWED_VALUE_LIST => [ RC_NONE, RC_BAD, RC_CHANGE_1, RC_CHANGE_2, RC_CHANGE_3, RC_ALL ];
my $rc_type;

my $book_keeping_file;
my $print = 0;

# Print the memory consumption of the process running rqg_batch
# -------------------------------------------------------------
# Failures within the code for the order management and especially the simplifier could tend to
# cause some dramatic or "endless" growth of memory consumption of the perl process running
# rqg_batch.pl.
# $rqg_batch_debug set to 1 causes printing `ps -p $$ --no-headers -o vsz,rsz,sz,size`
my $rqg_batch_debug = 0;

# If set to 1 than print the estimated values
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

    if ($rc_type eq RC_NONE) {
        say("WARN: Automatic ResourceControl is disabled. This is risky because increasing the " .
            "load is all time allowed.");
        my $nproc = `nproc`;
        if (not defined $nproc) {
            say("ERROR: The command 'nproc' gave some undef result.");
            safe_exit(STATUS_ENVIRONMENT_FAILURE);
        }
        chomp $nproc; # Remove the '\n'
        say("INFO: Number of CPU's reported by the OS (nproc): $nproc");
        my $workers_mid = int($nproc / 2);
        my $workers_min = int($nproc / 4);
        return LOAD_INCREASE, $workers_mid, $workers_min;
    } else {
        say("INFO: Automatic ResourceControl is enabled. Report type '$rc_type'.");
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
            "HINT:   1. Append '--resource_control=" . RC_NONE . "' to your call of rqg_batch.pl\n".
            "HINT:   2. Assign at begin a small value to the parameter 'parallel'\n"               .
            "HINT:   3. Observe the system behaviour during the rqg_batch run and raise "          .
            " the value assigned to 'parallel' slowly.\n");
            safe_exit(STATUS_ENVIRONMENT_FAILURE);
    }

    $book_keeping_file = $workdir . "/" . "resource.txt";
    if ($rc_type) {
        Batch::make_file($book_keeping_file, undef);
    }

    # The description was mostly taken from CPAN.
    $lxs = Sys::Statistics::Linux->new(
        sysinfo   => 1,
        # memtotal   -  The total size of memory.
        # swaptotal  -  The total size of swap space.
        # pcpucount  -  The total number of physical CPUs.
        # tcpucount  -  The total number of CPUs (cores, hyper threading). <== ?
        cpustats  => 0,
        # Except iowait and maybe idle not that important
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
        # memfree     -  Total size of free memory in kilobytes. Free RAM           <======
        # realfree    -  Total size of memory is real free (memfree + buffers + cached).
        #                This is not useful because space consumption in tmpfs is in cached as far
        #                as not already in swap.
        # cached      -  Total size of cached memory in kilobytes.                  <======
        # buffers     -  Total size of buffers used from memory in kilobytes.
        # swapused    -  Total size of swap space is used is kilobytes.             <======
        # swapusedper -  Total size of swap space is used in percent
        pgswstats => 1,
        # Not that important but maybe used later
        # FIXME maybe: Heavy paging seen in 2018 + most probably bad if towards SSD
        # pgpgin      -  Number of pages the system has paged in from disk per second.
        # pgpgout     -  Number of pages the system has paged out to disk per second.
        # pswpin      -  Number of pages the system has swapped in from disk per second.
        # pswpout     -  Number of pages the system has swapped out to disk per second.
        processes => 0,
        # Not that important but maybe used later
    );
    $lxs->init;
    $lxs1 = Sys::Statistics::Linux->new(
        sysinfo   => 0,
        # memtotal   -  The total size of memory.
        # swaptotal  -  The total size of swap space.
        # pcpucount  -  The total number of physical CPUs.
        # tcpucount  -  The total number of CPUs (cores, hyper threading). <== ?
        cpustats  => 1,
        # Except iowait and maybe idle not that important
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
        memstats  => 0,
        # memfree     -  Total size of free memory in kilobytes. Free RAM           <======
        # realfree    -  Total size of memory is real free (memfree + buffers + cached).
        #                This is not useful because space consumption in tmpfs is in cached as far
        #                as not already in swap.
        # cached      -  Total size of cached memory in kilobytes.                  <======
        # buffers     -  Total size of buffers used from memory in kilobytes.
        # swapused    -  Total size of swap space is used is kilobytes.             <======
        # swapusedper -  Total size of swap space is used in percent
        pgswstats => 0,
        # Not that important but maybe used later
        # FIXME maybe: Heavy paging seen in 2018 + most probably bad if towards SSD
        # pgpgin      -  Number of pages the system has paged in from disk per second.
        # pgpgout     -  Number of pages the system has paged out to disk per second.
        # pswpin      -  Number of pages the system has swapped in from disk per second.
        # pswpout     -  Number of pages the system has swapped out to disk per second.
        processes => 0,
        # Not that important but maybe used later
    );
    $lxs1->init;
    # Without $lxs1_last_ts < time() - 5 measure() will omit pulling the cpu load.
    # And than values stay undef and cause confusion when being printed.
    $lxs1_last_ts = 0;

    measure();

    $vardir_free_init   = $vardir_free;
    $workdir_free_init  = $workdir_free;
    $mem_est_free_init  = $mem_est_free;
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
    # -------------------------------------------------------------
    my $val;
    my $workers_min;
    my $workers_mid;
    # Bad case estimations
    # - The tests run temporary or permanent with two DB servers.
    # - The estimated share of workers produce a core.
    # - One worker cores anyway.
    # Lower the value if its too big.
    $val = int(($mem_est_free - SHARE_CORE * SPACE_CORE - SPACE_CORE) /
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
    # - The tests run all time with one DB server only.
    # - The estimated share of workers produce a core.
    # - One worker cores anyway.
    $val = int(($mem_est_free + SHARE_CORE * SPACE_CORE - SPACE_CORE) /
           (MEM_USED + SPACE_USED + SHARE_CORE * SPACE_CORE));
    say("DEBUG: workers_mid 1: $val");
    $workers_mid = $val;
    $val = int(($vardir_free + SHARE_CORE * SPACE_CORE - SPACE_CORE ) /
           (SPACE_USED + SHARE_CORE * SPACE_CORE));
    say("DEBUG: workers_mid 2: $val");
    if ($val < $workers_mid) {
        $workers_mid = $val;
    }
    say("DEBUG: workers_mid final: $workers_mid");

    if ($rc_type) {
        my $iso_ts = isoTimestamp();
        my $line =
          "$iso_ts ResourceControl type    : $rc_type\n"                                           .
          "$iso_ts vardir  '$vardir'  free : $vardir_free_init\n"                                  .
          "$iso_ts workdir '$workdir' free : $workdir_free_init\n"                                 .
          "$iso_ts memory total            : $mem_total\n"                                         .
          "$iso_ts memory real free        : $mem_est_free_init\n"                                 .
          "$iso_ts swap space total        : $swap_total\n"                                        .
          "$iso_ts swap space used         : $swap_used_init\n"                                    .
          "$iso_ts cpu cores (HT included) : $tcpu_count\n"                                        .
          "$iso_ts cpu idle - cpu iowait   : $cpu_idle - $cpu_iowait\n"                            .
          "$iso_ts parallel (est. min)     : $workers_min\n"                                       .
          "$iso_ts parallel (est. mid)     : $workers_mid\n"                                       .
          "$iso_ts return (to rqg_batch)   : $load_status, $workers_mid, $workers_min\n"           .
          "------------------------------------------------------------------------------------\n" .
          "$iso_ts Unit for memory and storage space is MB\n"                                      .
          "$iso_ts     *_consumed means amount lost since start of our rqg_batch run\n"            .
          "$iso_ts The distance between non cpu measurements depends on the needs of RQG Batch.\n" .
          "$iso_ts Minimal distance between cpu measurements: 5s\n"                                .
          "------------------------------------------------------------------------------------\n" .
          "$iso_ts worker , vardir_consumed - vardir_free , "                                      .
                   "workdir_consumed - workdir_free , "                                            .
                   "mem_consumed - mem_est_free , "                                                .
                   "swap_consumed - swap_free , "                                                  .
                   "cpu_idle - cpu_iowait = load_status\n";
        if ($rqg_batch_debug) {
            $line .= "$iso_ts     vsz - rsz - sz - size #### rqg_batch process\n";
        }
        $line .=   "---------------------------------------------------------------------------\n";
        Batch::append_string_to_file($book_keeping_file, $line);
    }
    return $load_status, $workers_mid, $workers_min;

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
    $mem_consumed      = $mem_est_free_init  - $mem_est_free;
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
    # $sr_U = $swap_free - SPACE_CORE;
    $sr_U = $mem_est_free + $swap_free - SPACE_CORE;
    # $sr_U = 0 if 0 == $swap_free;
    $mr_U = $mem_est_free - 0; # Basically no idea
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
    # One worker and the estimated fraction of the remaining worker dies with core at the same
    # point of time.
    # Important:
    # We must compute more than in the "give up" case (SPACE_CORE). Because otherwise we could get
    # $vardir_free < SPACE_CORE
    #     --> give_up criterion fulfilled
    # $vardir_free < SPACE_CORE
    #     $worker_active * SHARE_CORE < 1 and therefore rounded up to 1
    #     --> decrease criterion fulfilled
    # Checks of criterions is ordered give_up? --if no--> decrease? --if no--> keep? --> ...
    $vd_D = (1 + ($worker_active - 1) * SHARE_CORE)  * SPACE_CORE;
    $vr_D = $vardir_free - $vd_D;
    $sd_D = $vd_D;
    # $sr_D = $swap_free - $sd_D;
    $sr_D = $mem_est_free + $swap_free - $sd_D;
    # $sr_D = 0 if 0 == $swap_free;
    # All active workers finish with fail + archiving etc. and we would fall below the free space
    # threshold for the workdir. Some moderate decrease of activity till stop would be good.
    $wr_D = $workdir_free - $worker_active * SPACE_REMAIN + SPACE_FREE;
    # In case the already existing space consumption ($vardir_consumed + $mem_consumed + 8000)
    # and feared additional space consumption ($vd_D + 1000) exceeds the total amount of RAM
    # ($mem_total) than the OS will be forced to use more swap space that we do not want.
    $rd_D = $vd_D + $vardir_consumed + $mem_consumed + 8000 + 1000;
    $rr_D = $mem_total - $rd_D;
    $mr_D = $mem_est_free - 0; # Basically no idea

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
    # An additional RQG worker
    # - has his own space consumption even without crashing   maximum of (average,SPACE_USED)
    # - could crash with core
    # and all the other already active RQG workers could crash too.
    if ($worker_active > 0) {
        my $space_estimation = $vardir_consumed / $worker_active;
        $space_estimation = SPACE_USED if $space_estimation < SPACE_USED;
        $vd_K = $worker_active * SHARE_CORE * SPACE_CORE + SPACE_CORE
                + $space_estimation;
    } else {
        $vd_K = SPACE_CORE + SPACE_USED;
    }
    $vr_K = $vardir_free - $vd_K;

    # FIXME maybe refine:
    # Zero paging assumed $mem_consumed contains already the space consumption in tmpfs.
    # So an additional RQG worker eats in unfortunate scenario:
    #        ~ MEM_USED + $space_estimation + SPACE_CORE
    # An additional RQG worker needs some memory (tmpfs not counted).
    if ($worker_active > 0) {
        my $space_estimation = $vardir_consumed / $worker_active;
        $space_estimation = SPACE_USED if $space_estimation < SPACE_USED;
        $md_K = $mem_consumed / $worker_active + $space_estimation + SPACE_CORE;
    } else {
        $md_K = MEM_USED + SPACE_USED + SPACE_CORE;
    }
    $mr_K = $mem_est_free - $md_K;

    # Tried but not good because jumping from INCREASE without hitting KEEP between to DECREASE.
    # $sr_K = $sr_D;
    $sr_K = $sr_D - $md_K / 2;

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
            $info = "INFO: $info_m The free memory ($mem_est_free MB) $end_part";
            $load_status = LOAD_GIVE_UP;
#       } elsif (0 > $rr_U) {
#           $info_m = "G3";
#           $info = "INFO: $info_m The space consumption for the RAM ($mem_total MB) $end_part";
#           $load_status = LOAD_GIVE_UP;
        } elsif (0 > $sr_U) {
            $info_m = "G4";
            $info = "INFO: $info_m The free virtual memory (RAM+SWAP) $end_part";
            $load_status = LOAD_GIVE_UP;
        } elsif (0 > $wr_U) {
            $info_m = "G5";
            $info = "INFO: $info_m The free space in '$workdir' ($workdir_free MB) $end_part";
            $load_status = LOAD_GIVE_UP;
        } elsif ($swap_consumed > $swap_total / 20) {
            $info_m = "G6";
            $info = "INFO: $info_m 5% of total swap space consumed for testing. This is bad.";
            $load_status = LOAD_GIVE_UP;
        } elsif ($swap_used > $swap_total / 10) {
            $info_m = "G7";
            $info = "INFO: $info_m 10% of total swap space used. This is bad.";
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
            $info = "INFO: $info_m The free memory ($mem_est_free MB) $end_part";
            $load_status = LOAD_DECREASE;
#       } elsif (0 > $rr_D) {
#           $info_m = "D3";
#           $info = "INFO: $info_m The space consumption for the RAM ($mem_total MB) $end_part";
#           $load_status = LOAD_DECREASE;
        } elsif (0 > $sr_D) {
            $info_m = "D4";
            $info = "INFO: $info_m The free virtual memory (RAM+SWAP) $end_part";
            $load_status = LOAD_DECREASE;
        } elsif (0 > $wr_D) {
            $info_m = "D5";
            $info = "INFO: $info_m The free space in '$workdir' ($workdir_free MB) $end_part";
            $load_status = LOAD_DECREASE;
        } elsif (100 < int($pswpout)) {
            # FIXME maybe:
            # 100 < int($pswpout) --> LOAD_KEEP
            # 300 < int($pswpout) --> LOAD_DECREASE
            $info_m = "D6";
            $info = "INFO: $info_m Paging ($pswpout) has been observed. This $end_part";
            $load_status = LOAD_DECREASE;
        }
    }

    if (not defined $load_status) {
        my $end_part = "is not better than just sufficient.";
        if ($cpu_iowait > 20) {
            # We are most probably running on some slow device like HDD.
            # Adding some RQG run more will only increase CPU iowait and that does not make sense.
            $info_m = "K0";
            $info = "INFO: $info_m The value for CPU iowait $cpu_iowait is bigger than 20.";
            $load_status = LOAD_KEEP;
        } elsif (0 > $vr_K) {
            $info_m = "K1";
            $info = "INFO: $info_m The free space in '$vardir' ($vardir_free MB) $end_part";
            $load_status = LOAD_KEEP;
        } elsif (0 > $mr_K) {
            $info_m = "K2";
            $info = "INFO: $info_m The free memory ($mem_est_free MB) $end_part";
            $load_status = LOAD_KEEP;
#       } elsif (0 > $rr_K) {
#           $info_m = "K3";
#           $info = "INFO: $info_m The space consumption for the RAM ($mem_total MB) $end_part";
#           $load_status = LOAD_KEEP;
        } elsif (0 > $sr_K) {
            $info_m = "K4";
            $info = "INFO: $info_m The free virtual memory (RAM+SWAP) $end_part";
            $load_status = LOAD_KEEP;
        } elsif (0 > $wr_K) {
            $info_m = "K5";
            $info = "INFO: $info_m The free space in '$workdir' ($workdir_free MB) $end_part";
            $load_status = LOAD_KEEP;
        } elsif ($swap_consumed > $swap_total / 100) {
            $info_m = "K6";
            $info = "INFO: $info_m 1% of total swap space used consumed for testing. This $end_part";
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
                   $mem_consumed      . " - " . $mem_est_free  . " , " .
                   $swap_consumed     . " - " . $swap_free     . " , " .
                   $cpu_idle          . " - " . $cpu_iowait    . " = " .
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
        } elsif (RC_CHANGE_3 eq $rc_type and
                 ($previous_load_status ne $load_status or $previous_worker != $worker_active or
                  LOAD_GIVE_UP          eq $load_status or LOAD_DECREASE eq $load_status))      {
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
            Batch::append_string_to_file($book_keeping_file,
                "The overall state is bad. Some details -------------");
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

    $pswpout  = $stat->pgswstats->{pswpout};

    $pcpu_count = $stat->sysinfo->{pcpucount};
    $tcpu_count = $stat->sysinfo->{tcpucount};

    $swap_used    = int($stat->memstats->{swapused} / 1024);
    $mem_est_free = int(($stat->memstats->{memfree} + $stat->memstats->{cached}) / 1024);

    my $current_ts = time();
    # Only all 5s in order to avoid too flaky values.
    if ($current_ts >= $lxs1_last_ts + 5) {
        my $stat1 = $lxs1->get();
        $cpu_idle   = int($stat1->cpustats->{cpu}->{idle});
        # say("CPU: idle :   $cpu_idle");
        $cpu_iowait = int($stat1->cpustats->{cpu}->{iowait});
        # say("CPU: iowait : $cpu_iowait");
        $cpu_system = int($stat1->cpustats->{cpu}->{system});
        # say("CPU: system : $cpu_system");
        $cpu_user   = int($stat1->cpustats->{cpu}->{user});
        # say("CPU: user :   $cpu_user");
        $lxs1_last_ts = $current_ts;
    } else {
        # say("DEBUG: Generation of new CPU statistics omitted $current_ts -- $lxs1_last_ts");
    }

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

