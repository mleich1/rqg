#  Copyright (c) 2020, 2022 MariaDB Corporation Ab.
#  Copyright (c) 2023, 2026 MariaDB plc
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

package Runtime;

use base 'Exporter';

@EXPORT = qw(
           RUNTIME_FACTOR_RR
           RUNTIME_FACTOR_VALGRIND
);

# Purpose:
# Hold constants and maybe later subs which are specific to the behaviour of
# RQG at runtime.

use strict;
use Auxiliary;
use GenTest_e;
use Basics;
use Local;
use GenTest_e::Constants;

use constant RUNTIME_FACTOR_RR                   => 2;
use constant RUNTIME_FACTOR_VALGRIND             => 2;

use constant CONNECT_TIMEOUT                     => 45;
    # 30s was once too small for monstrous load and debug+ASAN build.

our $runtime_factor = 1.0;
sub set_runtime_factor_rr {
    $runtime_factor = RUNTIME_FACTOR_RR;
}
sub set_runtime_factor_valgrind {
    $runtime_factor = RUNTIME_FACTOR_VALGRIND;
}

sub get_runtime_factor {
    return $runtime_factor;
}

sub get_connect_timeout {
    return $runtime_factor * CONNECT_TIMEOUT;
}

# Support for the use of rr (https://rr-project.org/, https://github.com/mozilla/rr)
# ----------------------------------------------------------------------------------
# RR tracing variants
use constant RR_OFF            => '';
use constant RR_ON             => 'rr record';
use constant RR_NOT_SET        => undef;

our $rr;
our $rr_rules = 0;
# $rr_rules is used for deciding if
# - a SIGKILL of the server is acceptable or not (lib/DBServer_e/MySQL/MySQLd.pm)
# - the RR related runtimefactor has to be used for adjusting timeouts.
our $valgrind;
our $valgrind_options;

sub check_and_set_rr_valgrind {
    ($rr, $valgrind, $valgrind_options, my $batch_tool) = @_;
                                        # 1 -- rqg_batch.pl ist the caller
                                        # 0 -- rqg.pl ist the caller

    my $who_am_i = Basics::who_am_i;

    if (4 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: $who_am_i : Four parameters " .
                    "are required.");
        return $status;
    }

    # In case the caller is rqg_batch.pl than basically pass through of options.
    $rr = RR_NOT_SET if not defined $rr;
    say("DEBUG: $who_am_i Before mapping rr is not defined") if not defined $rr;
    say("DEBUG: $who_am_i Before mapping rr is ->" . $rr . "<-") if defined $rr;

    if (not defined $rr) {
        # Is valid. Do nothing.
    } elsif (RR_OFF eq $rr) {
        # Is valid. Do nothing.
    } elsif (RR_ON eq substr($rr, 0, (length RR_ON))) {
        # Is valid. Do nothing.
        $rr_rules = 1;
    } else {
        say("ERROR: The value assigned to the parameter 'rr' ->" . $rr . "<- is not supported.");
        help_rr();
        my $status =    STATUS_ENVIRONMENT_FAILURE;
        return $status;
    }

    say("DEBUG: $who_am_i After mapping rr is not defined") if not defined $rr;
    say("DEBUG: $who_am_i After mapping rr is ->" . $rr . "<-") if defined $rr;

    my $already_under_rr = $ENV{RUNNING_UNDER_RR};
    if (defined $already_under_rr) {
        say("INFO: The environment variable RUNNING_UNDER_RR is set. " .
            "This means the complete RQG run (-> all processes) are under the control of 'rr'.");
        if ((defined $rr and RR_OFF ne $rr) or defined $valgrind) {
            say("ERROR: $who_am_i 'rqg.pl' should invoke 'rr' and/or 'valgrind' even though " .
                "already running under control of 'rr'. This is not supported.");
            my $status =    STATUS_ENVIRONMENT_FAILURE;
            return $status;
        }
        $rr_rules = 1;
    }

    if (defined $rr and RR_OFF ne $rr) {
        my $status;
        if (not osLinux()) {
            say("ERROR: $who_am_i 'rr' on some OS != Linux is not supported.");
            $status =   STATUS_ENVIRONMENT_FAILURE;
            return $status;
        }
        if (defined $valgrind) {
            say("ERROR: $who_am_i RQG should invoke 'rr' and 'valgrind'. This is not supported.");
            $status =   STATUS_ENVIRONMENT_FAILURE;
            return $status;
        }
        if (STATUS_OK != Auxiliary::find_external_command("rr")) {
            $status =   STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: $who_am_i The external binary 'rr' is required but was not found.");
            return $status;
        }
        say("INFO: The DB server and certain other programs will run under 'rr'.");
        my $rr_options_add = Local::get_rr_options_add();
        if (defined $rr and RR_OFF ne $rr and defined $rr_options_add) {
            $rr = $rr . $rr_options_add;
            say("INFO: rr set to ->" . $rr . "<-");
        }
    }

    if (defined $valgrind and osWindows()) {
        say("ERROR: $who_am_i 'valgrind' is not supported on Windows.");
        my $status =    STATUS_ENVIRONMENT_FAILURE;
        return $status;
    }

    if (defined $rr and RR_OFF ne $rr) {
        my $status =    STATUS_OK;
        if (STATUS_OK != Auxiliary::find_external_command("rr")) {
            $status =   STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: $who_am_i The external binary 'rr' is required but was not found.");
            return $status;
        }
        say("INFO: The DB server and mariabackup will run under 'rr'.");
    }
    if($rr_rules) {
        Runtime::set_runtime_factor_rr;
    }

    if (defined $valgrind) {
        if (STATUS_OK == Auxiliary::find_external_command("valgrind")) {
            Runtime::set_runtime_factor_valgrind;
            say("INFO: Running under 'valgrind' is enabled.");
        } else {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: $who_am_i valgrind is required but was not found.");
            return $status;
        }
        if (defined $valgrind_options) {
            say("INFO: valgrind options ->" . $valgrind_options . "<-");
        }
    } else {
        if (defined $valgrind_options) {
            say("WARN: Setting valgrind_options('$valgrind_options') to undef because " .
                "'valgrind' is not defined.");
            $valgrind_options = undef;
        }
    }
    return STATUS_OK;
}

sub get_rr {
    return $rr;
}
sub get_rr_rules {
    return $rr_rules;
}
sub get_valgrind {
    return $valgrind;
}
sub get_valgrind_options {
    return $valgrind_options;
}

sub help_rr {
    print(
"HELP: About how and when to invoke the tool 'rr' (https://rr-project.org/)\n\n"                   .
"      Advantages of rr tracing:\n"                                                                .
"      - Debugging of bad effects becomes far way faster (Factor in average > ~10)\n"              .
"      - rr traces (~ 30 till 50 MB) are far way smaller than core files (~ 0.5 till 1 GB)\n"      .
"      Disadvantages of rr tracing:\n"                                                             .
"      - rr tracing reduces the throughput by ~ 50%\n"                                             .
"      - the likelihood to replay some bad effect drops in average to ~ 1/3 of without rr.\n"      .
"      - some bad effects will not replay at all\n"                                                .
"      - certain InnoDB options are not compatible with using 'rr'\n\n"                            .
"      Switch rr tracing for DB server (bootstrap+regular start) + mariadbbackup on.\n"            .
"      --rr='rr record <opts>'\n"                                                                  .
"      Switch rr tracing off if its already enabled.\n"                                            .
"      --rr=''\n"                                                                                  .
"      Do not switch any maybe already existing setting for rr tracing.\n"                         .
"      --rr\n"                                                                                     .
"      In order to get optimal results you might need to add certain rr options\n"                 .
"      like for example\n"                                                                         .
"      --rr='rr record --wait --chaos'\n\n"                                                        .
"      There are also rr options which might be required in order to avoid incompatibilities between\n".
"      - rr and MariadB\n"                                                                         .
"      - rr and your local hardware\n"                                                             .
"      They all should be kept in the file local.cfg. The RQG runner will process them.\n\n"       .
"      There is some overriding mechanism within the RQG batch tool\n"                             .
"                RQG batch tool (rqg_batch.pl)              |        RQG runner (rqg.pl)\n"        .
"      'dices' based on         | call                      | finally uses              | rr tracing\n" .
"      config file content      | contains                  |                           | is\n"    .
"      -------------------------+---------------------------+---------------------------+-----------\n".
"      --rr='rr record <opts1>' | --rr='rr record <opts2>'  | --rr='rr record <opts2+>' |   ON\n"  .
"      --rr=''                  | --rr='rr record <opts2>'  | --rr='rr record <opts2+>' |   ON\n"  .
"      --rr                     | --rr='rr record <opts2>'  | --rr='rr record <opts2+>' |   ON\n"  .
"      --rr='rr record <opts1>' | --rr=''                   | --rr                      |   OFF\n" .
"      --rr=''                  | --rr=''                   | --rr                      |   OFF\n" .
"      --rr                     | --rr=''                   | --rr                      |   OFF\n" .
"      --rr='rr record <opts1>' | --rr                      | --rr='rr record <opts1+>' |   ON\n"  .
"      --rr=''                  | --rr                      | --rr                      |   OFF\n" .
"      --rr                     | --rr                      | --rr                      |   OFF\n"
    );
}

1;

