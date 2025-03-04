# Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
# Copyright (C) 2016-2022 MariaDB Corporation Ab.
# Copyright (C) 2023 MariaDB Corporation plc
# Use is subject to license terms.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301
# USA

package GenTest_e::ReporterManager;

@ISA = qw(GenTest_e);

use strict;
use Basics;
use GenTest_e;
use GenTest_e::Constants;
use GenTest_e::Reporter;

use constant MANAGER_REPORTERS    => 0;
1;

sub new {
# "new" itself does not seem to cause running a connect.
    my $class = shift;
    my $manager = $class->SUPER::new({
        reporters => MANAGER_REPORTERS
    }, @_);

    $manager->[MANAGER_REPORTERS] = [];

    return $manager;
}

sub monitor {
    my ($manager, $desired_type) = @_;

    my $who_am_i =   Basics::who_am_i();
    my $max_result = STATUS_OK;

    foreach my $reporter (@{$manager->reporters()}) {
        if ($reporter->type() & $desired_type) {
            # In case we have already exceeded $reporter->testEnd() than it might look good to
            # abort running the current sequence of reporters.
            # But this leads to serious problems (2023-02) like
            # 1. The periodic reporting process stops with STATUS_OK.
            # 2. The server hangs somehow but the reporter "Deadlock" is no more running.
            #    Hence we do not get further information if connects are possible or connections
            #    are stalled.
            # 3. Depending on the situation we harvest quite unspecific exit statuses or statuses
            #    which do not point to the real reason of the problem.
            # Please keep the disabled code.
            # my $test_end = $reporter->testEnd();
            # last if defined $test_end and $test_end <= time();
            my $reporter_result = $reporter->monitor();
            $max_result = $reporter_result if $reporter_result > $max_result;
            if ($reporter_result != STATUS_OK) {
                say("INFO: $who_am_i Reporter '" . $reporter->name() .
                    "' reported $reporter_result ");
                # What follows is not required in case the reporter itself exits.
                # This is valid 2020-12 but maybe not in all reporters or whatever.
                if (STATUS_SERVER_KILLED == $reporter_result or
                    STATUS_SERVER_DEADLOCKED == $reporter_result) {
                    # The server was just now target of SIGKILL or SIGSEGV or maybe SIGABRT.
                    # Hence the remaining periodic reporters would observe effects of that
                    # and probably report some misleading status.
                    say("INFO: $who_am_i Omitting all other reporters because of that.");
                    last;
                }
            }
        }
    }
    # say("DEBUG: $who_am_i Will return the (maximum) status $max_result");
    return $max_result;
}

sub report {
# This will get executed at the end of the phase GenTest_e after all RQG threads
# have already finished.
    my ($manager, $desired_type) = @_;

    my $who_am_i =   Basics::who_am_i();

    my $max_result = STATUS_OK;
    my @incidents;

    foreach my $reporter (@{$manager->reporters()}) {
        if ($reporter->type() & $desired_type) {
            my @reporter_results =  $reporter->report();
            my $reporter_result =   shift @reporter_results;
            push @incidents, @reporter_results if $#reporter_results > -1;
            say("DEBUG: $who_am_i Reporter '" . $reporter->name() . "' reported $reporter_result.");
            if ($reporter_result >= STATUS_CRITICAL_FAILURE) {
               say("ERROR: $who_am_i Reporter '" . $reporter->name() .
                   "' reported $reporter_result ");
            }
            $max_result = $reporter_result if $reporter_result > $max_result;
        }
    }
    return $max_result, @incidents;
}

sub addReporter {
    my ($manager, $reporter, $params) = @_;

    my $who_am_i = Basics::who_am_i();
    if (ref($reporter) eq '') {
        my $reporter_name = $reporter;
        my $module = "GenTest_e::Reporter::" . $reporter;
        eval "use $module";
        if ('' ne $@) {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: $who_am_i Loading Reporter '$module' failed : $@");
            say("ERROR: $who_am_i " . Basics::return_status_text($status));
            return $status;
        }
        $reporter = $module->new(%$params, 'name' => $reporter_name);
        if (not defined $reporter) {
            my $status = STATUS_ENVIRONMENT_FAILURE;
            say("ERROR: $who_am_i Reporter '$module' could not be added. " .
                Basics::return_status_text($status));
            return $status;
        } else {
            say("INFO: Reporter '$reporter_name' added.");
        }
    }

    push @{$manager->[MANAGER_REPORTERS]}, $reporter;
    return STATUS_OK;
}

sub reporters {
    return $_[0]->[MANAGER_REPORTERS];
}

1;
