#  Copyright (c) 2021, 2022 MariaDB Corporation Ab.
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

package Local;

use strict;
use Basics;
use GenTest_e::Constants;
use Auxiliary;
use GenTest_e;
use File::Copy;
use Cwd;

use constant DBDIR_TYPE_FAST => 'fast';
use constant DBDIR_TYPE_SLOW => 'slow';
use constant DBDIR_TYPE_LIST => [ DBDIR_TYPE_FAST, DBDIR_TYPE_SLOW ];

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
                Carp::cluck("INTERNAL ERROR: rqg_home($rqg_home) does not exist or is not a directory.");
                exit STATUS_INTERNAL_ERROR;
            } else {
                # Just for the case that some component needs that but has absolute no or no
                # convenient enough access to the package Local.pm
                $ENV{'RQG_HOME'} = $rqg_home;
            }
        }
    }
    say("DEBUG: rqg_home set to ->$rqg_home<-");
}

our $rr_options_add;
our $rqg_slow_dbdir_rr_add;
our $rqg_rr_add;
our $results_dir;
our $binarch_dir;
our $build_thread;
our $major_runid;
our $minor_runid;
our $dbdir_type;
our $dbdir_fs_type;
our $rqg_fast_dir;
our $rqg_slow_dir;
our $vardir;
our $dbdir;

sub check_and_set_local_config {

    ($major_runid, $minor_runid, $dbdir_type, my $batch) = @_;
    my $who_am_i = Basics::who_am_i;

    if (4 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: $who_am_i" .
                    " Exact four parameters(major_runid, minor_runid, dbdir_type, batch) need " .
                    "to get assigned. " . Auxiliary::exit_status_text($status));
        safe_exit($status);
    }
    # Variants
    # --------
    # major_runid | minor_runid | batch   | allowed |
    # ------------+-------------+---------+-------------------------------------------------------
    #           * |           * |   undef | no      | rqg_batch.pl replaces the undef with 2
    #                                               | rqg.pl replaces the undef with 0 or 1
    #                                               | check_and_set_local_config aborts if undef
    # ------------+-------------+---------+-------------------------------------------------------
    #         def |         def |     0|1 | no      |
    # ------------+-------------+---------+-------------------------------------------------------
    #         def |         def |       2 | yes     | RQG run with assigned major_runid and
    #                                               | minor_runid initiated by rqg_batch.pl.
    # ------------+-------------+---------+-------------------------------------------------------
    #         def |       undef |       * | no
    # ------------+-------------+---------+-------------------------------------------------------
    #       undef |         def |       0 | yes     | RQG run stand alone with assigned
    #                                               | minor_runid.
    # ------------+-------------+---------+-------------------------------------------------------
    #       undef |         def |       1 | no
    # ------------+-------------+---------+-------------------------------------------------------
    #       undef |       undef |       0 | yes     | RQG run stand alone with to be calculated
    #                                               | minor_runid.
    # ------------+-------------+---------+-------------------------------------------------------
    #       undef |       undef |       1 | no
    # ------------+-------------+-----------+-------------------------------------------------------
    #       undef |       undef |       2 | yes     | rqg_batch.pl
    #
    # Roughly
    # - If major_runid defined than the corresponding subdirectory must already exist.
    # - If major_runid not defined than it has no impact at all.
    # - If minor_runid not defined and set to timestamp or already defined than the corresponding
    #   subdirectory must be (re)creatable.
    #
    # The value assigned to batch is influenced but not identical to the call parameter --batch.

    if (not defined $batch) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: $who_am_i" .
                    " The variable \$batch is undef. " . Auxiliary::exit_status_text($status));
        safe_exit($status);
    } else {
        say("DEBUG: $who_am_i The variable \$batch is ->$batch<-");
    }
    if (not defined $minor_runid) {
        # Number of seconds since the Epoch, 1970-01-01 00:00:00 +0000 (UTC) has many advantages
        # compared to some fixed or user defined value because the time is monotonically increasing.
        # The "sleep 1" is for the unlikely but in reality (unit tests etc.) met case that some run
        # of the same or another RQG tool like rqg_batch.pl started and failed less than a
        # second before. And so both runs calculated the same value and that made trouble.
        sleep 1;
        $minor_runid = time();
        say("INFO: runid was undef and has been set to $minor_runid");
    }

    our $local_config =          $rqg_home . "/local.cfg";
    our $local_config_template = $rqg_home . "/local_template.cfg";

    my $fast_fs_type;
    my $slow_fs_type;
    if (not -e $local_config) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: The local config file '$local_config' does not exist.\n" .
            "INFO:  Please copy '" . $local_config_template . "' to '" . $local_config . "'.\n" .
            "INFO:  And than adjust the content of '" . $local_config . "' to your needs. " .
            Auxiliary::exit_status_text($status));
        safe_exit($status);
    } else {
        if (not open (CONF, $local_config)) {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: Unable to open the local config file '$local_config': $! " .
                Auxiliary::exit_status_text($status));
            safe_exit($status);
        }
        read(CONF, my $config_text, -s $local_config);
        close(CONF);

        eval ($config_text);
        if ($@) {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: Unable to load the local config file '$local_config': " .
                $@ . ' ' . Auxiliary::exit_status_text($status));
            safe_exit($status);
        }

        my $message_correct = "Please correct the file '$local_config'. ";
        if (not defined $rr_options_add) {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: The variable \$rr_options_add is undef. " . $message_correct .
                Auxiliary::exit_status_text($status));
            safe_exit($status);
        }

        if (not defined $build_thread) {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: The variable \$build_thread is undef. " . $message_correct .
                Auxiliary::exit_status_text($status));
            safe_exit($status);
        }

        sub check_dir {
            my ($dir) = @_;
            if (not -d $dir) {
                if (STATUS_OK != Basics::conditional_make_dir($dir)) {
                    my $status = STATUS_ENVIRONMENT_FAILURE;
                    safe_exit($status);
                }
            }
        }

        if (not defined $rqg_fast_dir) {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: The variable \$rqg_fast_dir is undef. " . $message_correct .
                Auxiliary::exit_status_text($status));
            safe_exit($status);
        } else {
            $rqg_fast_dir = Basics::unify_path($rqg_fast_dir);
            # local.cfg has already checked that this directory exists.
        }
        my $fast_fs_type = Auxiliary::get_fs_type($rqg_fast_dir);

        if (not defined $rqg_slow_dir) {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: The variable \$rqg_slow_dir is undef. " . $message_correct .
                Auxiliary::exit_status_text($status));
            safe_exit($status);
        } else {
            $rqg_slow_dir = Basics::unify_path($rqg_slow_dir);
            # local.cfg has already checked that this directory exists.
        }
        my $slow_fs_type = Auxiliary::get_fs_type($rqg_slow_dir);

        if ($rqg_fast_dir eq $rqg_slow_dir) {
            say("ERROR: '$rqg_fast_dir' and '$rqg_slow_dir' are equal which is bad " .
                "for the functional coverage. Abort");
            safe_exit(STATUS_ENVIRONMENT_FAILURE);
        }

        if ($fast_fs_type eq $slow_fs_type and $slow_fs_type eq 'tmpfs'
            and $rqg_fast_dir =~ m{\/dev\/shm\/}) {
            say("ERROR: rqg_fast_dir '$rqg_fast_dir' and rqg_slow_dir '$rqg_slow_dir' are of " .
                "type 'tmpfs'. This is bad for the functional coverage. Abort");
            safe_exit(STATUS_ENVIRONMENT_FAILURE);
        }

        if (defined $major_runid) {
            $rqg_fast_dir = Basics::unify_path($rqg_fast_dir . "/" . $major_runid);
            check_dir($rqg_fast_dir);
            $rqg_slow_dir = Basics::unify_path($rqg_slow_dir . "/" . $major_runid);
            check_dir($rqg_slow_dir);
        }
        $rqg_fast_dir = Basics::unify_path($rqg_fast_dir . "/" . $minor_runid);
        Basics::conditional_remove__make_dir($rqg_fast_dir);
        $rqg_slow_dir = Basics::unify_path($rqg_slow_dir . "/" . $minor_runid);
        Basics::conditional_remove__make_dir($rqg_slow_dir);

        if (not defined $binarch_dir) {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: The variable \$binarch_dir is undef. " .
                Auxiliary::exit_status_text($status));
            safe_exit($status);
        }
        $binarch_dir = Basics::unify_path($binarch_dir);

        if (not defined $results_dir) {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: The variable \$results_dir is undef. " .
                Auxiliary::exit_status_text($status));
            safe_exit($status);
        }
        if (defined $major_runid) {
            $results_dir = Basics::unify_path($results_dir . "/" . $major_runid);
            check_dir($results_dir);
        }
        $results_dir = Basics::unify_path($results_dir . "/" . $minor_runid);
        if (0 == $batch) {
            # $build_thread stays unchanged.
            if (STATUS_OK != Basics::conditional_remove__make_dir($results_dir)) {
                my $status = STATUS_ENVIRONMENT_FAILURE;
                safe_exit($status);
            }
        } else {
            $build_thread = $build_thread + $minor_runid - 1;
            check_dir($results_dir);
        }

        if (not defined $dbdir_type and 2 != $batch) {
            $dbdir_type = DBDIR_TYPE_FAST;
            say("INFO: The value for dbdir_type was undef. Changing it to the default '" .
                $dbdir_type . "'.");
        }
        if (defined $dbdir_type) {
            my $result = Auxiliary::check_value_supported ('dbdir_type', DBDIR_TYPE_LIST,
                                                           $dbdir_type);
            if ($result != STATUS_OK) {
                help_dbdir_type();
                my $status = STATUS_ENVIRONMENT_FAILURE;
                safe_exit($status);
            } else {
                if      (DBDIR_TYPE_FAST eq $dbdir_type) {
                    $rqg_rr_add =    '';
                    $vardir =        $rqg_fast_dir;
                    $dbdir  =        $rqg_fast_dir;
                    $dbdir_fs_type = $fast_fs_type;
                } elsif (DBDIR_TYPE_SLOW eq $dbdir_type) {
                    $rqg_rr_add =    $rqg_slow_dbdir_rr_add;
                    $vardir =        $rqg_slow_dir;
                    $dbdir  =        $rqg_slow_dir;
                    $dbdir_fs_type = $slow_fs_type;
                }
            }
        } else {
            my $val = 'undef == decided later by the RQG runner';
            $rqg_rr_add =    $val;
            $vardir =        $val;
            $dbdir  =        $val;
            $dbdir_fs_type = $val;
            $dbdir_type =    $val;
        }

        my $replacement = $major_runid;
        $replacement = '<undef --> not used>' if not defined $major_runid;
        my $message = "Local Properties after processing '$local_config' and parameters assigned";
        say(Auxiliary::dash_line(length($message)) . "\n"                                          .
            $message . "\n"                                                                        .
            "INFO: major_runid           : '$replacement'\n"                                       .
            "INFO: minor_runid           : '$minor_runid'\n"                                       .
            "INFO: dbdir_type            : '$dbdir_type'\n"                                        .
            "INFO: dbdir                 : '$dbdir'        -- fs_type observed: $dbdir_fs_type\n"  .
            "INFO: rqg_fast_dir          : '$rqg_fast_dir' -- fs_type observed: $fast_fs_type\n"   .
            "INFO: rqg_slow_dir          : '$rqg_slow_dir' -- fs_type observed: $slow_fs_type\n"   .
            "INFO: rqg_slow_dbdir_rr_add : '$rqg_slow_dbdir_rr_add'\n"                             .
            "INFO: rr_options_add        : '$rr_options_add'\n"                                    .
            "INFO: rqg_rr_add            : '$rqg_rr_add'\n"                                        .
            "INFO: binarch_dir           : '$binarch_dir'\n"                                       .
            "INFO: results_dir           : '$results_dir'\n"                                       .
            "INFO: vardir                : '$vardir'\n"                                            .
            "INFO: build_thread          : '$build_thread'\n"                                      .
            Auxiliary::dash_line(length($message)))                                                ;
    }
    # For debugging
    # system("ls -ld /dev/shm/rqg*/* /data/rqg/* /data/results/*");
    # system("ls -ld /dev/shm/rqg*/SINGLE_RQG/* /data/rqg/SINGLE_RQG/* /data/results/SINGLE_RQG/*");
} # End sub check_and_set_local_config

sub get_rqg_home {
# Used by lib/Auxiliary.pm only.
    return $rqg_home;
}

sub get_runid {
    return $major_runid, $minor_runid;
}
sub get_rqg_fast_dir {
    # To be used by rqg_batch.pl
    return $rqg_fast_dir;
}
sub get_rqg_slow_dir {
    # To be used by rqg_batch.pl
    return $rqg_slow_dir;
}

sub get_vardir_per_type {
    # To be used by rqg_batch.pl
    my ($dbdir_type) = @_;
    if (1 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: script_debug_init : 1 Parameter (dbdir_type) is required.");
        safe_exit($status);
    };
    if (not defined $dbdir_type) {
        $dbdir_type = DBDIR_TYPE_FAST;
        say("INFO: The value for dbdir_type was undef. Changing it to the default '" .
            $dbdir_type . "'.");
    }
    my $comp_vardir;
    my $result = Auxiliary::check_value_supported ('dbdir_type', DBDIR_TYPE_LIST, $dbdir_type);
    if ($result != STATUS_OK) {
        return undef;
    } else {
        if      (DBDIR_TYPE_FAST eq $dbdir_type) {
            $comp_vardir = $rqg_fast_dir;
        } elsif (DBDIR_TYPE_SLOW eq $dbdir_type) {
            $comp_vardir = $rqg_slow_dir;
        }
    }
    # say("DEBUG: comp_vardir ->" . $comp_vardir . "<-");
    return $comp_vardir;
}
sub get_vardir {
    return $vardir;
}
sub get_dbdir {
    return $dbdir;
}

sub get_dbdir_type {
    return $dbdir_type;
}

sub get_dbdir_fs_type {
    return $dbdir_fs_type;
}

sub get_rr_options_add {
    return $rr_options_add;
}

sub get_binarch_dir {
    return $binarch_dir;
}

sub get_results_dir {
    return $results_dir;
}

sub get_rqg_rr_add {
    return $rqg_rr_add;
}

sub get_build_thread {
    return $build_thread;
}

sub help_local {
    print
    "The file local.cfg\n" .
    "- is required and gets processed by rqg_batch.pl and rqg.pl.\n"             .
    "- serves for describing properties of the local box.\n"                     .
    "Please copy local_template.cfg to local.cfg and adjust the values there.\n" ;
}

sub help_dbdir_type {

   say("\nHELP about the RQG run option 'dbdir_type'.\n"                                           .
       "Supported values: " . Auxiliary::list_values_supported(DBDIR_TYPE_LIST) . "\n"             .
       "Default value:    '" . DBDIR_TYPE_FAST . "'\n\n"                                           .
       "Based on the type provided and the content of the file 'local.cfg' RQG will calculate "    .
       "some corresponding var directory.\n"                                                       .
       "      The vardirs of all database servers will be created as sub directories within "      .
       "that directory.\n"                                                                         .
       "      RQG tools and the RQG runners feel 'free' to destroy or create the vardir whenever " .
       "they want.\n\n"                                                                            .
       "The recommendation is to assign some 'dbdir_type' which leads to using some filesystem "   .
       "which satisfies your needs.\n"                                                             .
       "'" . DBDIR_TYPE_FAST . "':\n"                                                              .
       "   Advantage:\n"                                                                           .
       "   The higher throughput and/or all CPU cores heavy loaded gives in average "              .
       "better (more issues replayed) results.\n"                                                  .
       "   Disadvantages:\n"                                                                       .
       "   - This setting causes most probably that a filesystem of type 'tmpfs' gets used.\n"     .
       "     Bugs occuring on other types like 'ext4' only cannot get replayed.\n"                 .
       "     Fortunately such bugs are rare.\n"                                                    .
       "   - Filesystems of type 'tmpfs' are usually quite small.\n"                               .
       "'" . DBDIR_TYPE_SLOW . "':\n"                                                              .
       "   Advantages:\n"                                                                          .
       "   - Most probably coverage for some filesystem type which is more likely used"            .
       " for production than 'tmpfs'.\n"                                                           .
       "   - Filesystems on SSD and especially HDD are usually huge except you assign some RAM"    .
       " based filesystem."                                                                        .
       "   Disadvantages:\n"                                                                       .
       "   - In average less throughput and/or all CPU cores not heavy loaded gives in average "   .
       "less good results except you assign some RAM based filesystem.\n"                          .
       "   - In case the final device is a SSD than some risk to wear it out soon.\n\n"            .
       "Recommendation for RQG Batch:\n"                                                           .
       "   Have within the batch config file a section assigning something like\n"                 .
       "   Variant 1\n"                                                                            .
       "   batch config file         | corresponding entry in local.cfg\n"                         .
       "   3 times dbdir_type' " . DBDIR_TYPE_FAST . "' | /dev/shm/rqg (tmpfs)\n"                  .
       "   7 times dbdir_type' " . DBDIR_TYPE_SLOW . "' | /dev/shm/rqg_ext4 (ext4 with image in tmpfs)\n" .
       "   Variant 2\n"                                                                            .
       "   batch config file         | corresponding entry in local.cfg\n"                         .
       "   9 times dbdir_type' " . DBDIR_TYPE_FAST . "' | /dev/shm/rqg (tmpfs)\n"                  .
       "   1 time  dbdir_type' " . DBDIR_TYPE_SLOW . "' | /data/rqg (ext4 located on HDD or SSD)\n\n");
}

1;
