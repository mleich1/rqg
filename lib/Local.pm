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

package Local;

use strict;
use GenTest::Constants;
use Auxiliary;
use GenTest;
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
our $vardir_type;
our $rqg_fast_dir;
our $rqg_slow_dir;
our $vardir;

sub check_and_set_local_config {

    ($major_runid, $minor_runid, $vardir_type, my $batch) = @_;
    if (4 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: " . Basics::who_am_i .
                    " Exact four parameters(major_runid, minor_runid, vardir_type, batch) need " .
                    "to get assigned. " . Auxiliary::exit_status_text($status));
        safe_exit($status);
    }
    # Variants
    # --------
    # major_runid | minor_runid | batch     | allowed
    # ------------+-------------+-----------+-------------------------------------------------------
    #         def |         def | undef|0   | no
    # ------------+-------------+-----------+-------------------------------------------------------
    #         def |         def |       1   | yes
    #                                       | RQG run with assigned runid (->minor_runid) initiated
    #                                       | by rqg_batch.pl
    # ------------+-------------+-----------+-------------------------------------------------------
    #         def |       undef | undef|0|1 | no
    # ------------+-------------+-----------+-------------------------------------------------------
    #       undef |         def | undef|0   | yes RQG run stand alone or RQG Batch run with assigned runid.
    # ------------+-------------+-----------+-------------------------------------------------------
    #       undef |         def |       1   | no
    # ------------+-------------+-----------+-------------------------------------------------------
    #       undef |       undef | undef|0   | yes RQG run stand alone or RQG Batch run without assigned runid.
    # ------------+-------------+-----------+-------------------------------------------------------
    #       undef |       undef |   1       | no
    #
    # Roughly
    # - If major_runid defined than the corresponding subdirectory must already exist.
    # - If major_runid not defined than it has no impact at all.
    # - If minor_runid not defined and set to timestamp or already defined than the corresponding
    #   subdirectory must be (re)creatable.

    if (not defined $minor_runid) {
        # Number of seconds since the Epoch, 1970-01-01 00:00:00 +0000 (UTC) has many advantages
        # compared to fixed or user defined value because the time is monotonically increasing.
        # The "sleep 1" is for the unlikely but in reality (unit tests etc.) met case that some run
        # of the same or another RQG tool like rqg_batch.pl started and failed less than a
        # second before. And so both runs calculated the same value and that made trouble.
        sleep 1;
        $minor_runid = time();
        say("INFO: runid was undef and has been set to $minor_runid");
    }

    our $local_config = $rqg_home . "/local.cfg";

    my $fast_fs_type;
    my $slow_fs_type;
    if (not -e $local_config) {
        my $status = STATUS_ENVIRONMENT_FAILURE;
        say("ERROR: The local config file '$local_config' does not exist. " .
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

        sub check_dir {
            my ($dir, $text) = @_;
            if (not -d $dir) {
                if (STATUS_OK != Basics::conditional_make_dir($dir, $text)) {
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
            check_dir($rqg_fast_dir, "Per file '$local_config' a directory '$rqg_fast_dir' should exist.");
        }
        if (defined $major_runid) {
            $rqg_fast_dir = Basics::unify_path($rqg_fast_dir . "/" . $major_runid);
            check_dir($rqg_fast_dir, "The directory '$rqg_fast_dir' should already exist.");
        }
        $rqg_fast_dir = Basics::unify_path($rqg_fast_dir . "/" . $minor_runid);
        check_dir($rqg_fast_dir, "The directory '$rqg_fast_dir' should already exist.");
        my $fast_fs_type = Auxiliary::get_fs_type($rqg_fast_dir);

        if (not defined $rqg_slow_dir) {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: The variable \$rqg_slow_dir is undef. " . $message_correct .
                Auxiliary::exit_status_text($status));
            safe_exit($status);
        } else {
            $rqg_slow_dir = Basics::unify_path($rqg_slow_dir);
            check_dir($rqg_slow_dir, "Per file '$local_config' a directory '$rqg_slow_dir' should exist.");
        }
        if (defined $major_runid) {
            $rqg_slow_dir = Basics::unify_path($rqg_slow_dir . "/" . $major_runid);
            check_dir($rqg_slow_dir, "The directory '$rqg_slow_dir' should already exist.");
        }
        $rqg_slow_dir = Basics::unify_path($rqg_slow_dir . "/" . $minor_runid);
        check_dir($rqg_slow_dir, "The directory '$rqg_slow_dir' should already exist.");
        my $slow_fs_type = Auxiliary::get_fs_type($rqg_slow_dir);

        if (not defined $binarch_dir) {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: The variable \$binarch_dir is undef. " .
                Auxiliary::exit_status_text($status));
            safe_exit($status);
        } else {
            check_dir($binarch_dir, "Per file '$local_config' a directory '$binarch_dir' should exist.");
        }
        $binarch_dir = Basics::unify_path($binarch_dir);

        if (not defined $results_dir) {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: The variable \$results_dir is undef. " .
                Auxiliary::exit_status_text($status));
            safe_exit($status);
        } else {
            check_dir($results_dir, "Per file '$local_config' a directory '$results_dir' should exist.");
        }
        if (defined $major_runid) {
            $results_dir = Basics::unify_path($results_dir . "/" . $major_runid);
            check_dir($results_dir, "The directory '$results_dir' should already exist.");
        }
        $results_dir = Basics::unify_path($results_dir . "/" . $minor_runid);
        if (not defined $batch or 0 == $batch) {
            if (STATUS_OK != Basics::conditional_remove__make_dir($results_dir)) {
                my $status = STATUS_ENVIRONMENT_FAILURE;
                safe_exit($status);
            }
        } else {
            check_dir($results_dir, "The directory '$results_dir' should already exist.");
        }

        if (not defined $build_thread) {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: The variable \$binarch_dir is undef. " . $message_correct .
                Auxiliary::exit_status_text($status));
            safe_exit($status);
        }

        if (not defined $vardir_type) {
            $vardir_type = DBDIR_TYPE_FAST;
            say("INFO: The value for vardir_type was undef. Changing it to the default '" .
                $vardir_type . "'.");
        }
        my $result = Auxiliary::check_value_supported ('vardir_type', DBDIR_TYPE_LIST,
                                                       $vardir_type);

        if ($result != STATUS_OK) {
            help_vardir_type();
            my $status = STATUS_ENVIRONMENT_FAILURE;
            safe_exit($status);
        } else {
            if      (DBDIR_TYPE_FAST eq $vardir_type) {
                $rqg_rr_add = '';
                $vardir = $rqg_fast_dir;
            } elsif (DBDIR_TYPE_SLOW eq $vardir_type) {
                $rqg_rr_add = $rqg_slow_dbdir_rr_add;
                $vardir = $rqg_slow_dir;
            }
        }

        my $replacement = $major_runid;
        $replacement = '<undef --> not used>' if not defined $major_runid;
        say("---------------------------------------------------------\n" .
            "Local Properties after processing '$local_config' and parameters assigned\n"          .
            "INFO: major_runid           : '$replacement'\n"                                       .
            "INFO: minor_runid           : '$minor_runid'\n"                                       .
            "INFO: vardir_type           : '$vardir_type'\n"                                       .
            "INFO: rqg_fast_dir          : '$rqg_fast_dir' -- fs_type observed: $fast_fs_type \n"  .
            "INFO: rqg_slow_dir          : '$rqg_slow_dir' -- fs_type observed: $slow_fs_type \n"  .
            "INFO: rqg_slow_dbdir_rr_add : '$rqg_slow_dbdir_rr_add'\n"                             .
            "INFO: rr_options_add        : '$rr_options_add'\n"                                    .
            "INFO: rqg_rr_add            : '$rqg_rr_add'\n"                                        .
            "INFO: binarch_dir           : '$binarch_dir'\n"                                       .
            "INFO: results_dir           : '$results_dir'\n"                                       .
            "INFO: vardir                : '$vardir'\n"                                            .
            "INFO: build_thread          : '$build_thread'\n"                                      .
            "---------------------------------------------------------")                           ;
    }
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
    my ($vardir_type) = @_;
    if (1 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: script_debug_init : 1 Parameter (vardir_type) is required.");
        safe_exit($status);
    };
    if (not defined $vardir_type) {
        $vardir_type = DBDIR_TYPE_FAST;
        say("INFO: The value for vardir_type was undef. Changing it to the default '" .
            $vardir_type . "'.");
    }
    my $comp_vardir;
    my $result = Auxiliary::check_value_supported ('vardir_type', DBDIR_TYPE_LIST, $vardir_type);
    if ($result != STATUS_OK) {
        return undef;
    } else {
        if      (DBDIR_TYPE_FAST eq $vardir_type) {
            $comp_vardir = $rqg_fast_dir;
        } elsif (DBDIR_TYPE_SLOW eq $vardir_type) {
            $comp_vardir = $rqg_slow_dir;
        }
    }
    # say("DEBUG: comp_vardir ->" . $comp_vardir . "<-");
    return $comp_vardir;
}
sub get_vardir {
    return $vardir;
}

sub get_vardir_type {
    return $vardir_type;
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

sub help_local {
    print
    "The file local.cfg\n" .
    "- is required and gets processed by rqg_batch.pl and rqg.pl.\n"             .
    "- serves for describing properties of the local box.\n"                     .
    "Please copy local_template.cfg to local.cfg and adjust the values there.\n" ;
}

sub help_vardir_type {

   say("\nHELP about the RQG run option 'vardir_type'.\n"                                          .
       "Supported values: " . Auxiliary::list_values_supported(DBDIR_TYPE_LIST) . "\n"             .
       "Default value:    '" . DBDIR_TYPE_FAST . "'\n\n"                                           .
       "Based on the type provided and the content of the file 'local.cfg' RQG will calculate "    .
       "some corresponding var directory.\n"                                                       .
       "      The vardirs of all database servers will be created as sub directories within "      .
       "that directory.\n"                                                                         .
       "      Also certain dumps, temporary files (variable tmpdir in RQG code) etc. will be "     .
       "placed there.\n"                                                                           .
       "      RQG tools and the RQG runners feel 'free' to destroy or create the vardir whenever " .
       "they want.\n\n"                                                                            .
       "The recommendation is to assign some 'vardir_type' which leads to using some filesystem "  .
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
       "   - Filesystems on SSD and especially HDD are usually huge.\n"                            .
       "   Disadvantages:\n"                                                                       .
       "   - In average less throughput and/or all CPU cores not heavy loaded gives in average "   .
       "less good results.\n"                                                                      .
       "   - In case the final device is a SSD than some risk to wear it out soon.\n\n"            .
       "Recommendation for RQG Batch:\n"                                                           .
       "   Have within the batch config file a section assigning something like\n"                 .
       "   9 times vardir_type' " . DBDIR_TYPE_FAST . "' and one time '" . DBDIR_TYPE_SLOW."'\n\n" .
       "Why is it no more supported to set the vardir<n> for the DB servers within the RQG call?\n".
       "   - Maximum safety against concurrent activity of other RQG and MTR tests could be\n"     .
       "     only ensured if the RQG run uses vardirs for servers which are specific to the\n"     .
       "     RQG run. Just assume the ugly case that concurrent tests create/destroy/modify\n"     .
       "     in <release>/mysql-test/var.\n"                                                       .
       "   - Creating/Archiving/Removing only one directory 'vardir' only is easier.");
}

1;