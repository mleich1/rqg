#  Copyright (c) 2020 MariaDB Corporation Ab.
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

use constant RUNTIME_FACTOR_RR                   => 1.5;
use constant RUNTIME_FACTOR_VALGRIND             => 2;

use constant CONNECT_TIMEOUT                     => 45;
    # 30s ist to small for monstrous load and debug+ASAN build.
    # 40s ist to small for monstrous load and debug+ASAN build + connect to server on backupped data

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

1;
