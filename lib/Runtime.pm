#  Copyright (c) 2020, 2022 MariaDB Corporation Ab.
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

package Runtime;

use base 'Exporter';

@EXPORT = qw(
           RUNTIME_FACTOR_RR
           RUNTIME_FACTOR_VALGRIND
);

# Purpose:
# Hold constants and maybe later subs which are specific to the behaviour of RQG at runtime.
#

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

# Support for rr (https://rr-project.org/, https://github.com/mozilla/rr)
# -----------------------------------------------------------------------
our $rr;
our $rr_options;
our $rr_rules = 0;
# $rr_rules is used for deciding if
# - a SIGKILL of the server is acceptable or not (lib/DBServer_e/MySQL/MySQLd.pm)
# - the RR related runtimefactor has to be used for adjusting timeouts.
our $valgrind;
our $valgrind_options;

sub check_and_set_rr_valgrind {
    ($rr, $rr_options, $valgrind, $valgrind_options, my $batch_tool) = @_;
                                                     # 1 -- rqg_batch.pl ist the caller
                                                     # 0 -- rqg.pl ist the caller

    my $who_am_i = Basics::who_am_i;

    if (5 != scalar @_) {
        my $status = STATUS_INTERNAL_ERROR;
        Carp::cluck("INTERNAL ERROR: $who_am_i : Five parameters " .
                    "are required.");
        return $status;
    }

    my $already_under_rr = $ENV{RUNNING_UNDER_RR};
    if (defined $already_under_rr) {
        say("INFO: The environment variable RUNNING_UNDER_RR is set. " .
            "This means the complete RQG run (-> all processes) are under the control of 'rr'.");
        if (defined $rr or defined $valgrind) {
            say("ERROR: $who_am_i 'rqg.pl' should invoke 'rr' or 'valgrind' even though already " .
                "running under control of 'rr'. This is not supported.");
            my $status = STATUS_ENVIRONMENT_FAILURE;
            return $status;
        }
        $rr_rules = 1;
    }

    if (defined $rr and not osLinux()) {
        say("ERROR: $who_am_i 'rr' on some OS != Linux is not supported.");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        return $status;
    }

    if (defined $valgrind and osWindows()) {
        say("ERROR: $who_am_i 'valgrind' is not supported on Windows.");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        return $status;
    }

    if (defined $rr and defined $valgrind) {
        say("ERROR: $who_am_i 'rqg.pl' should invoke 'rr' and 'valgrind'. This is not supported.");
        my $status = STATUS_ENVIRONMENT_FAILURE;
        return $status;
    }

    if (defined $rr) {
        my $status = STATUS_OK;
        if (STATUS_OK != Auxiliary::find_external_command("rr")) {
            $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: $who_am_i The external binary 'rr' is required but was not found.");
            return $status;
        }
        say("INFO: The DB server and mariabackup will run under 'rr'.");
        $rr_rules = 1;
        my $rr_options_add = Local::get_rr_options_add();
        if (defined $rr_options) {
            say("INFO: rr_options ->" . $rr_options . "<-");
            $rr_options .= " " . $rr_options_add . " " if defined $rr_options_add;
        } else {
            $rr_options  = " " . $rr_options_add . " " if defined $rr_options_add;
        }
    } else {
        if (defined $rr_options) {
            say("WARN: Setting rr_options('$rr_options') to undef because 'rr' is not defined.");
            $rr_options = undef;
        }
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
sub get_rr_options {
    return $rr_options;
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
"HELP: About how and when to invoke the tool 'rr' (https://rr-project.org/)\n"                     .
"      --rr\n"                                                                                     .
"           Supported by 'rqg_batch.pl' which passes this setting through to the RQG runner "      .
"'rqg.pl'\n"                                                                                       .
"           No pass through to other RQG runners.\n"                                               .
"           Any start of a DBServer (normal start but also bootstrap) or mariabackup will be "     .
"done like\n"                                                                                      .
"               'rr record .... mysqld ...'.\n"                                                    .
"           and the generation of core files will be avoided.\n"                                   .
"           Advantages:\n"                                                                         .
"           - Debugging of bad effects becomes far way faster (Factor in average > ~10)\n"         .
"           - rr traces (~ 30 till 50 MB) are far way smaller than core files (~ 0.5 till 1 GB)\n" .
"           Disadvantages:\n"                                                                      .
"           - rr tracing reduces the throughput by ~ 50%\n"                                        .
"           - the likelihood to replay some bad effect drops in average to ~ 1/3 of without rr.\n" .
"           - some bad effects will not replay at all\n"                                           .
"           - certain InnoDB options are not compatible with using 'rr'\n"                         .
"      --rr_options=<value>\n"                                                                     .
"           A list of rr related options like\n"                                                   .
"               --wait --chaos\n"                                                                  .
"           which gets added to the rr invocation like\n"                                          .
"               rr <options set by RQG> <options set via commandline or config file> ... "         .
"<to be traced program>\n\n"                                                                       .
"           Certain rr related options get set in local.cfg .\n"
    );
}

1;
