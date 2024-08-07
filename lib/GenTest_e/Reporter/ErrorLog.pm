# Copyright (c) 2008,2012 Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2018 MariaDB Coporration Ab.
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

package GenTest_e::Reporter::ErrorLog;

require Exporter;
@ISA = qw(GenTest_e::Reporter);

use strict;
use GenTest_e;
use GenTest_e::Reporter;
use GenTest_e::Constants;
use GenTest_e::CallbackPlugin;

sub report {
    if (defined $ENV{RQG_CALLBACK}) {
        return callbackReport(@_);
    } else {
        return nativeReport(@_);
    }
}


sub nativeReport {

   my $reporter = shift;

   # master.err-old is created when logs are rotated due to SIGHUP

   my $main_log = $reporter->serverVariable('log_error');
   if ($main_log eq '') {
      foreach my $errlog ('../log/master.err', '../mysql.err') {
         if (-f $reporter->serverVariable('datadir').'/'.$errlog) {
            $main_log = $reporter->serverVariable('datadir').'/'.$errlog;
            last;
         }
      }
   }

   say("INFO: Reporter 'ErrorLog' ------------------------------ Begin");
   # ML 2018-06-04 Observation
   # RQG runner --logfile=otto --> The output of the "system" calls is short visible
   # on screen but not in otto. RQG runner ... > otto 2>&1 works well.
   # This seems to be a result of the rather wild output redirecting.
   # Obviously the say* routines do not have that trouble.
   # So I stick to the provisoric fix to use sayFile.
   foreach my $log ($main_log, $main_log . '-old') {
      if ((-e $log) && (-s $log > 0)) {
      #  say("The last 2000 lines from $log ------------------------------ Begin");
         sayFile($log);
      #  system("tail -2000 $log | cut -c 1-4096");
      #  say("$log                          ------------------------------ End");
      }
   }
   say("INFO: Reporter 'ErrorLog' ------------------------------ End");
	
   return STATUS_OK;
}

sub callbackReport {
    my $output = GenTest_e::CallbackPlugin::run("lastLogLines");
    say("$output");
    ## Need some incident interface here in the output from
    ## javaPluginRunner
    return STATUS_OK, undef;
}

sub type {
	return REPORTER_TYPE_CRASH | REPORTER_TYPE_DEADLOCK ;
}

1;
