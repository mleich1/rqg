# Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
# Copyright (c) 2018, MariaDB Corporation Ab.
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

package GenTest_e::Generator;

# For the sake of simplicity, all GENERATOR_* properties are defined here
# even though most of them would pertain only to GenTest_e::Generator::FromGrammar

require Exporter;

@ISA = qw(Exporter GenTest_e);

@EXPORT = qw(
   GENERATOR_GRAMMAR_FILE
   GENERATOR_GRAMMAR_STRING
   GENERATOR_GRAMMAR
   GENERATOR_SEED
   GENERATOR_PRNG
   GENERATOR_TMPNAM
   GENERATOR_THREAD_ID
   GENERATOR_SEQ_ID
   GENERATOR_MASK
   GENERATOR_MASK_LEVEL
   GENERATOR_VARCHAR_LENGTH
   GENERATOR_MASKED_GRAMMAR
   GENERATOR_GLOBAL_FRAME
   GENERATOR_PARTICIPATING_RULES
   GENERATOR_ANNOTATE_RULES
   GENERATOR_RECONNECT
);

use strict;

use constant GENERATOR_GRAMMAR_FILE        => 0;
use constant GENERATOR_GRAMMAR_STRING      => 1;
use constant GENERATOR_GRAMMAR             => 2;
use constant GENERATOR_SEED                => 3;
use constant GENERATOR_PRNG                => 4;
use constant GENERATOR_TMPNAM              => 5;
use constant GENERATOR_THREAD_ID           => 6;
use constant GENERATOR_SEQ_ID              => 7;
use constant GENERATOR_MASK                => 8;
use constant GENERATOR_MASK_LEVEL          => 9;
use constant GENERATOR_VARCHAR_LENGTH      => 10;
use constant GENERATOR_MASKED_GRAMMAR      => 11;
use constant GENERATOR_GLOBAL_FRAME        => 12;
use constant GENERATOR_PARTICIPATING_RULES => 13;       # Stores the list of rules used in the last generated query
use constant GENERATOR_ANNOTATE_RULES      => 14;
use constant GENERATOR_RECONNECT           => 15;       # For FromGrammar

sub new {
   my $class = shift;
   my $generator = $class->SUPER::new({
      'grammar_file'      => GENERATOR_GRAMMAR_FILE,
      'grammar_string'    => GENERATOR_GRAMMAR_STRING,
      'grammar'           => GENERATOR_GRAMMAR,
      'seed'              => GENERATOR_SEED,
      'prng'              => GENERATOR_PRNG,
      'thread_id'         => GENERATOR_THREAD_ID,
      'mask'              => GENERATOR_MASK,
      'mask_level'        => GENERATOR_MASK_LEVEL,
      'varchar_length'    => GENERATOR_VARCHAR_LENGTH,
      'annotate_rules'    => GENERATOR_ANNOTATE_RULES
   }, @_);

   return $generator;
}

sub prng {
   return $_[0]->[GENERATOR_PRNG];
}

sub grammar {
   return $_[0]->[GENERATOR_GRAMMAR];
}

sub grammarFile {
   return $_[0]->[GENERATOR_GRAMMAR_FILE];
}

sub grammarString {
   return $_[0]->[GENERATOR_GRAMMAR_STRING];
}

sub threadId {
   return $_[0]->[GENERATOR_THREAD_ID];
}

sub seqId {
   return $_[0]->[GENERATOR_SEQ_ID];
}

sub mask {
   return $_[0]->[GENERATOR_MASK];
}

sub maskLevel {
   return $_[0]->[GENERATOR_MASK_LEVEL];
}

sub maskedGrammar {
   return $_[0]->[GENERATOR_MASKED_GRAMMAR];
}

sub setSeed {
   $_[0]->[GENERATOR_SEED] = $_[1];
   $_[0]->[GENERATOR_PRNG]->setSeed($_[1]) if defined $_[0]->[GENERATOR_PRNG];
}

sub setThreadId {
   $_[0]->[GENERATOR_THREAD_ID] = $_[1];
}

sub reconnect {
    return $_[0]->[GENERATOR_RECONNECT];
}

sub setReconnect {
   # Required for the following case:
   # Thread<n> lost his connection from "natural" reason. -> STATUS_SKIP_RELOOP.
   # So we connect again but have to take care that the queries generated from the
   # top level rules "thread<n>", "query" and "thread" later meet the required and/or
   # optimal environment. And this environment would be created by running the
   # query from the top-level rules "*_connect".
   # So a setReconnect(1) "tells" the FromGrammar to use a "*_connect" as starting rule
   # if it exists.
   $_[0]->[GENERATOR_RECONNECT] = $_[1];
}

1;
