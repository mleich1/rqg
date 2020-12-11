# Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
# Copyright (c) 2013, Monty Program Ab.
# Copyright (c) 2018-2020 MariaDB Corporation Ab.
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

package GenTest::Generator::FromGrammar;

require Exporter;
@ISA = qw(GenTest::Generator GenTest);

use strict;
use GenTest::Constants;
use GenTest::Random;
use GenTest::Generator;
use GenTest::Grammar;
use GenTest::Grammar::Rule;
use GenTest::Stack::Stack;
use GenTest;
use Cwd;
use List::Util qw(shuffle); # For some grammars
use Time::HiRes qw(time);

use constant GENERATOR_MAX_OCCURRENCES  => 3500;
use constant GENERATOR_MAX_LENGTH       => 10000;

my $field_pos;
my $rqg_home = $ENV{'RQG_HOME'};
my $cwd      = cwd();

sub new {
    my $class     = shift;
    my $generator = $class->SUPER::new(@_);

    if (not defined $generator->grammar()) {
    #   say("DEBUG: Loading grammar file '" . $generator->grammarFile() . "' ...");
        $generator->[GENERATOR_GRAMMAR] = GenTest::Grammar->new(
            grammar_file    => $generator->grammarFile(),
            grammar_string  => $generator->grammarString()
        );
        return undef if not defined $generator->[GENERATOR_GRAMMAR];
    }

    if (not defined $generator->prng()) {
        $generator->[GENERATOR_PRNG] = GenTest::Random->new(
            seed           => $generator->[GENERATOR_SEED] || 0,
            varchar_length => $generator->[GENERATOR_VARCHAR_LENGTH]
        );
    }

    if (not defined $generator->maskLevel()) {
        $generator->[GENERATOR_MASK_LEVEL] = 1;
    }

    $generator->[GENERATOR_SEQ_ID]    = 0;
    $generator->[GENERATOR_RECONNECT] = 1;

    if (defined $generator->mask() and $generator->mask() > 0) {
        my $grammar = $generator->grammar();
        my $top     = $grammar->topGrammar($generator->maskLevel(),
                                         "thread" . $generator->threadId(),
                                         "query");
        my $maskedTop                          = $top->mask($generator->mask());
        $generator->[GENERATOR_MASKED_GRAMMAR] = $grammar->patch($maskedTop);
    }

    return $generator;
}

sub globalFrame {
   my ($self) = @_;
   $self->[GENERATOR_GLOBAL_FRAME] = GenTest::Stack::StackFrame->new()
        if not defined $self->[GENERATOR_GLOBAL_FRAME];
   return $self->[GENERATOR_GLOBAL_FRAME];
}

sub participatingRules {
   return $_[0]->[GENERATOR_PARTICIPATING_RULES];
}

#
# Generate a new query. We do this by iterating over the array containing grammar rules and expanding each grammar rule
# to one of its right-side components . We do that in-place in the array.
#
# Finally, we walk along the array and replace all lowercase keywords with literals and such.
#

sub next {

    # Original code harvesting a warning like
    #     Variable "$generator" will not stay shared
    # because the inner sub "expand" fiddles with $generator and $executors too.
    # my ($generator, $executors) = @_;
    our ($generator, $executors) = @_;

    # Suppress complaints "returns its argument for UTF-16 surrogate".
    # We already know that our UTFs in some grammars are ugly.
    no warnings 'surrogate';

    our $who_am_i = "GenTest::Generator::FromGrammar::next:";

    my $grammar = $generator->[GENERATOR_GRAMMAR];
    # my $grammar_rules = $grammar->rules();
    # Used in expand
    our $grammar_rules = $grammar->rules();

    # my $prng = $generator->[GENERATOR_PRNG];
    # Used in expand
    our $prng = $generator->[GENERATOR_PRNG];
    my %rule_invariants = ();


    my %rule_counters;
    # our because the inner sub "expand" fiddles with %invariants.
    our %invariants = ();

    our $last_field;
    our $last_table;
    our $last_database;

    my $stack = GenTest::Stack::Stack->new();
    my $global = $generator->globalFrame();

    # 2018-11-15 observation (mleich):
    # Masses of ... occured more than ... times. Possible endless loop in grammar. Aborting."
    # followed by extreme growth of memory consumption (> 6GB) of the corresponding perl process.
    #
    # There are two known reasons:
    # 1. The original/full grammar has already that defect.
    # 2. The original/full grammar has no defect and looks like
    #    rule1:
    #        rule2         |
    #        rule2 , rule1 ;
    #    Grammar simplification is running and tries in the moment to simplify the definition to
    #    rule1:
    #        rule2 , rule1 ;
    #
    # Given the facts that
    # - the extreme growth of memory consumption could be very dangerous for RQG and its tools
    #   but also the OS on the testing box
    # - users should be made aware of the defect in case its some non simplified grammar
    # I tended to let the RQG worker thread exit with STATUS_ENVIRONMENT_FAILURE.
    # And usually after a short time span the RQG runner exits with STATUS_ENVIRONMENT_FAILURE too.
    # And if "Possible endless loop in grammar." gets blacklisted than the corresponding grammar/
    # RQG result gets ignored.
    # The mountain of problems:
    # 1. Grammar simplification but also "masking" lead quite often to such defects in grammars.
    # 2. During grammar simplification such a grammar might replay the desired effect before
    #    one of the threads hits "Possible endless loop in grammar." etc.
    # 3. In case this "replay" is based on the current (most probably non defect) parent grammar
    #    than the grammar used during that run will be loaded for generating the next parent
    #    grammar. Caused by that we have now the defect for some rather more than less long time
    #    within parent grammars.
    # 4. Thinkable ways of handling that
    #    A) Print "Possible endless loop in grammar." + let the thread exit with
    #       STATUS_ENVIRONMENT_FAILURE.
    #       --> The RQG run aborts because STATUS_ENVIRONMENT_FAILURE >= STATUS_CRITICAL_FAILURE.
    #           Any already made investment (especially GenData) in resources for the run are lost.
    #    B) Print "Possible endless loop in grammar." + let the thread exit with a status
    #       < STATUS_CRITICAL_FAILURE.
    #       --> There is at least some chance that one of the remaining threads replays the
    #           desired out come.
    #           In case "Possible endless loop in grammar." is
    #           - blacklisted than again all already made (bigger than in A) investments are lost.
    #           - not blacklisted than already made investments are not lost.
    #             But most probably many if not all threads will exit because of the same reason
    #             soon. So B) is not far way better than A).
    #    C) Print "Possible endless loop in grammar." and let the thread go on with working.
    #       Free (reused by perl!) memory as much and as early as possible.
    #       Do not blacklist "Possible endless loop in grammar." and let threads finally exit with
    #       a status < STATUS_CRITICAL_FAILURE except something evil happened.
    # Half experimental solution:
    # Try to detect that problem as early as possible and react immediate with
    # 1. Warn about the possible endless loop in grammar
    # 2. Try to free as much memory (-> @sentence, @expansion) as possible
    # 3. Return undef which does not get interpreted as statement to be executed.
    # 4. Go on with the test and do not set a status because of the problem.
    #

    our $print_num = 0;
    sub print_sentence {
        my ($sentence_ptr) = @_;
        $print_num++;
        if (not defined $sentence_ptr) {
            say("WARNING: $who_am_i print_sentence: sentence_ptr is not defined");
        } else {
            # say("DEBUG: $who_am_i \@sentence has " . scalar @{$sentence_ptr} . " elements");
            # say("DEBUG: $who_am_i $print_num \@sentence: ->" . join(" ", @{$sentence_ptr}) . "<-");
        }
    }

    sub expand {
        # Warning:
        # Expand returns on
        # - success some not empty array
        # - failure some empty array
        #   The old solution was exiting with die or returning undef.
        #   The latter leads to
        #       @blabla = undef --> @blabla has one element and that is undef
        #

        my ($rule_counters, $rule_invariants, @sentence) = @_;

        # How to hunt a Perl warning like
        #     Deep recursion on subroutine "GenTest::Generator::FromGrammar::expand"
        #     at /work/RQG_mleich3/lib/GenTest/Generator/FromGrammar.pm line ....
        # --------------------------------------------------------------------------
        # The example code was used for analysis but needs to be deactivated.
        # Reason:
        # - "Deep recursion on subroutine" gets reportet as soon as a limit of 100 was exceeded.
        #   But we prefer to go with our own limit GENERATOR_MAX_OCCURRENCES.
        # - RQG aborts the test when observing STATUS_RSS_DOUBLED.
        #   This accelerated the analysis where I used the RQG test simplifier.
        #   But this harsh reaction does not fit well to RQG testing with certain grammars.
        #
        # local $SIG{__WARN__} = sub {
        #     my $message = shift;
        #     # Print like perl would print it without the SIG{__WARN__}.
        #     print($message . "\n");
        #     if ($message =~ /Deep recursion on subroutine/) {
        #         # Pick a status >= STATUS_CRITICAL_FAILURE which does not cause that Reporters
        #         # assume that they have to do further analysis.
        #         # Negative example:
        #         # STATUS_CRITICAL_FAILURE, STATUS_SERVER_CRASHED, STATUS_ALARM ...
        #         # Backtrace kicks in and waits a long timespan for the DB server process dying.
        #         # STATUS_RSS_DOUBLED does not fit to the problem but it causes a fine reaction.
        #         my $status = STATUS_RSS_DOUBLED;
        #         say("ERROR: We have just hit the perl warning. Will return STATUS_RSS_DOUBLED");
        #         exit $status;
        #     }
        # };

        # Comment (mleich1)
        # A sentence is an array of words and spaces.
        # They all together form a query which consists of one till several statements.

        my $item_nodash;   # FIXME: This variable belongs to old code and is currently unused.
                           # Is that right?

        # For debugging
        if (0) {
        #   foreach my $sentence_part (@sentence) {
        #       say("DEBUG: sentence_part ->$sentence_part<-");
        #   }
        #   say("DEBUG: sentence_end -------");
            print_sentence(\@sentence);

        }

        # Define some standard message because blacklist_patterns matching might need it.
        my $warn_message_part = "WARN: Possible endless loop in grammar. " .
                                "Will return an empty array.";

        if ($#sentence > GENERATOR_MAX_LENGTH) {
            say("WARN: $who_am_i Sentence is now longer than " .
                GENERATOR_MAX_LENGTH() . " symbols.\n" . $warn_message_part);
            @sentence = ();
            return ();
        }

        my $orig_item;
        for (my $pos = 0; $pos <= $#sentence; $pos++) {
            $orig_item = $sentence[$pos];

            # For debugging
            if (0) {
                say("DEBUG: orig_item ->$orig_item<-");
                print_sentence(\@sentence);
            }

            next if not defined $orig_item;
            next if $orig_item eq ' ';
            next if $orig_item eq uc($orig_item);

            my $item =      $orig_item;
            my $invariant = 0;
            my @expansion = ();

            if ($item =~ m{^([a-z0-9_]+)\[invariant\]}sio) {
                ($item, $invariant) = ($1, 1);    # $item is for example '_table'
                # say("DEBUG: invariant in ->" . $orig_item . "<-");
            }

            if (exists $grammar_rules->{$item}) {
                # $orig_item is an element of the array $sentence --> query.
                # $item which is a copy of $orig_item is a rule.
                # ....[invariant] counts as a rule.
                if (++($rule_counters->{$orig_item}) > GENERATOR_MAX_OCCURRENCES) {
                    say("WARN: $who_am_i Rule '$orig_item' occured more " .
                        "than " . GENERATOR_MAX_OCCURRENCES() . " times.\n" . $warn_message_part);
                    @sentence  = ();
                    return ();
                }

                if ($invariant) {
                    @{$rule_invariants->{$item}} = expand($rule_counters,$rule_invariants,($item)) unless defined $rule_invariants->{$item};
                    @expansion = @{$rule_invariants->{$item}};
                  # if ( 0 == scalar @expansion ) {
                  #     say("DEBUG: Empty array got 1.");
                  # }
                } else {
                    # say("DEBUG: item ->$item<-");
                    @expansion = expand($rule_counters,$rule_invariants,@{$grammar_rules->{$item}->[GenTest::Grammar::Rule::RULE_COMPONENTS]->[
                        $prng->uint16(0, $#{$grammar_rules->{$item}->[GenTest::Grammar::Rule::RULE_COMPONENTS]})
                    ]});
                }
                if ($generator->[GENERATOR_ANNOTATE_RULES]) {
                    @expansion = ("/* rule: $item */ ", @expansion);
                }
			} else {
                my $non_mangled_item;
				if (
					(substr($item,  0, 1) eq '{') &&
					(substr($item, -1, 1) eq '}')
				) {
                    # The "no strict" is because grammars could fiddle with undef perl variables.
					$item = eval("no strict;\n".$item);		# Code
					if ($@ ne '') {
						if ($@ =~ m{at .*? line}o) {
							say("ERROR: Internal grammar error: $@");
                            @sentence  = ();
                            @expansion = ();
							# the original code called here die()
                            return ();
						} else {
							say("WARN: $who_am_i Eval error of Perl snippet ->" . $item . "<- : $@");
							say("WARN: $who_am_i Will return an empty array.");
                            @sentence  = ();
                            @expansion = ();
                            return ();
						}
					}
				} elsif (substr($item, 0, 1) eq '$') {
					$item = eval("no strict;\n".$item.";\n");	# Variable
                    if ($@ ne '') {
                        say("WARN: $who_am_i Eval error of Perl snippet ->" . $item . "<- : $@");
                    }
				} else {

                    # Check for expressions such as _tinyint[invariant]
                    $invariant = 0; # Unclear if a $invariant == 1 from top would be good.
                    if ($orig_item =~ m{^(_[a-z_]*?)\[invariant\]$}sio) {
                        # say("DEBUG: invariant in ->" . $orig_item . "<-");
                        $non_mangled_item = $item;
                        if (exists $invariants{$item}) {
                            $item = $invariants{$item};
                            # say("DEBUG: orig_item ->$orig_item<- value found in invariant " .
                            #     "hash ->$item<-");
                        } else {
                            $invariants{$item} = $item;
                            # say("DEBUG: orig_item ->$orig_item<- value stored in invariant " .
                            #     "hash ->$item<-");
                        }
                        $invariant = 1;
                    }

                    # For debugging:
                    # print_sentence(\@sentence);

					my $field_type = (substr($item, 0, 1) eq '_' ? $prng->isFieldType(substr($item, 1)) : undef);

					if ($item eq '_letter') {
						$item = $prng->letter();
					} elsif ($item eq '_digit') {
						$item = $prng->digit();
					} elsif ($item eq '_positive_digit') {
						$item = $prng->positive_digit();
					} elsif ($item eq '_table') {
						my $tables = $executors->[0]->metaTables($last_database);
						$last_table = $prng->arrayElement($tables);
						$item = '`'.$last_table.'`';
					} elsif ($item eq '_hex') {
						$item = $prng->hex();
					} elsif ($item eq '_cwd') {
						$item = "'".$cwd."'";
					} elsif (
						($item eq '_tmpnam') ||
						($item eq '_tmpfile')
					) {
						# Create a new temporary file name and record it for unlinking at the next statement
						$generator->[GENERATOR_TMPNAM] = tmpdir()."gentest".abs($$).".tmp" if not defined $generator->[GENERATOR_TMPNAM];
						$item = "'".$generator->[GENERATOR_TMPNAM]."'";
						$item =~ s{\\}{\\\\}sgio if osWindows();	# Backslash-escape backslashes on Windows
					} elsif ($item eq '_tmptable') {
						$item = "tmptable".abs($$);
					} elsif ($item eq '_unix_timestamp') {
						$item = time();
					} elsif ($item eq '_pid') {
						$item = abs($$);
					} elsif ($item eq '_thread_id') {
						$item = $generator->threadId();
					} elsif ($item eq '_connection_id') {
						$item = $executors->[0]->connectionId();
					} elsif ($item eq '_current_user') {
						$item = $executors->[0]->currentUser();
					} elsif ($item eq '_thread_count') {
						$item = $ENV{RQG_THREADS};
					} elsif (($item eq '_database') || ($item eq '_db') || ($item eq '_schema')) {
						my $databases = $executors->[0]->metaSchemas();
						$last_database = $prng->arrayElement($databases);
						$item = '`'.$last_database.'`';
					} elsif ($item eq '_table') {
						my $tables = $executors->[0]->metaTables($last_database);
						$last_table = $prng->arrayElement($tables);
						$item = '`'.$last_table.'`';
					} elsif ($item eq '_basetable') {
						my $tables = $executors->[0]->metaBaseTables($last_database);
						$last_table = $prng->arrayElement($tables);
						$item = '`'.$last_table.'`';
					} elsif ($item eq '_view') {
						my $tables = $executors->[0]->metaViews($last_database);
						$last_table = $prng->arrayElement($tables);
						$item = '`'.$last_table.'`';
					} elsif ($item eq '_field') {
						my $fields = $executors->[0]->metaColumns($last_table, $last_database);
                        $last_field = $prng->arrayElement($fields);
						$item = '`'.$last_field.'`';
					} elsif ($item eq '_field_list') {
						my $fields = $executors->[0]->metaColumns($last_table, $last_database);
						$item = '`'.join('`,`', @$fields).'`';
					} elsif ($item eq '_field_count') {
						my $fields = $executors->[0]->metaColumns($last_table, $last_database);
						$item = $#$fields + 1;
					} elsif ($item eq '_field_next') {
						# Pick the next field that has not been picked recently and increment the $field_pos counter
						my $fields = $executors->[0]->metaColumns($last_table, $last_database);
						$item = '`'.$fields->[$field_pos++ % $#$fields].'`';
					} elsif ($item eq '_field_pk') {
						my $fields = $executors->[0]->metaColumnsIndexType('primary',$last_table, $last_database);
                        $last_field = $fields->[0];
						$item = '`'.$last_field.'`';
					} elsif ($item eq '_field_no_pk') {
						my $fields = $executors->[0]->metaColumnsIndexTypeNot('primary',$last_table, $last_database);
                        $last_field = $prng->arrayElement($fields);
						$item = '`'.$last_field.'`';
					} elsif (($item eq '_field_indexed') || ($item eq '_field_key')) {
						my $fields_indexed = $executors->[0]->metaColumnsIndexType('indexed',$last_table, $last_database);
                        $last_field = $prng->arrayElement($fields_indexed);
						$item = '`'.$last_field.'`';
					} elsif (($item eq '_field_unindexed') || ($item eq '_field_nokey')) {
						my $fields_unindexed = $executors->[0]->metaColumnsIndexTypeNot('indexed',$last_table, $last_database);
                        $last_field = $prng->arrayElement($fields_unindexed);
						$item = '`'.$last_field.'`';
					} elsif ($item eq '_field_int') {
						my $fields_int = $executors->[0]->metaColumnsDataType('int',$last_table, $last_database);
                        $last_field = $prng->arrayElement($fields_int);
						$item = '`'.$last_field.'`';
					} elsif (($item eq '_field_int_indexed') || ($item eq '_field_int_key')) {
						my $fields_int_indexed = $executors->[0]->metaColumnsDataIndexType('int','indexed',$last_table, $last_database);
                        $last_field = $prng->arrayElement($fields_int_indexed);
						$item = '`'.$last_field.'`';
					} elsif ($item eq '_field_char') {
						my $fields_char = $executors->[0]->metaColumnsDataType('char',$last_table, $last_database);
                        $last_field = $prng->arrayElement($fields_char);
						$item = '`'.$last_field.'`';
					} elsif (($item eq '_field_char_indexed') || ($item eq '_field_char_key')) {
						my $fields_char_indexed = $executors->[0]->metaColumnsDataIndexType('char','indexed',$last_table, $last_database);
                        $last_field = $prng->arrayElement($fields_char_indexed);
						$item = '`'.$last_field.'`';
					} elsif ($item eq '_collation') {
						my $collations = $executors->[0]->metaCollations();
						$item = '_'.$prng->arrayElement($collations);
					} elsif ($item eq '_collation_name') {
						my $collations = $executors->[0]->metaCollations();
						$item = $prng->arrayElement($collations);
					} elsif ($item eq '_charset') {
						my $charsets = $executors->[0]->metaCharactersets();
						$item = '_'.$prng->arrayElement($charsets);
					} elsif ($item eq '_charset_name') {
						my $charsets = $executors->[0]->metaCharactersets();
						$item = $prng->arrayElement($charsets);
					} elsif ($item eq '_data') {
						$item = $prng->file($rqg_home."/data");
					} elsif ( defined $field_type and
						(($field_type == FIELD_TYPE_NUMERIC) ||
						 ($field_type == FIELD_TYPE_BLOB))
					) {
						$item = $prng->fieldType($item);
					} elsif ($field_type) {
                        $item = substr($item,1);
						$item = $prng->fieldType($item);
						if (
							(substr($item, -1) eq '`') ||
							(substr($item, 0, 2) eq "b'") ||
							(substr($item, 0, 2) eq '0x')
						) {
							# Do not quote, quotes are already present or not needed
						} elsif (index($item, "'") > -1) {
							$item = '"'.$item.'"';
						} else {
							$item = "'".$item."'";
						}
					}

					# If the grammar initially contained a ` , restore it. This allows
					# The generation of constructs such as `table _digit` => `table 5`

					if (
						(substr($orig_item, -1) eq '`') &&
						(index($item, '`') == -1)
					) {
						$item = $item.'`';
					}

				}
				@expansion = ($item);

                if ($invariant) {
                    if (not exists $invariants{$non_mangled_item}) {
                        say("ALARM: invariant hash member ->" . $non_mangled_item .
                            "<- is missing.");
                    }
                    $invariants{$non_mangled_item} = $item;
                    $invariant = 0;
                }

			}
			splice(@sentence, $pos, 1, @expansion);

        }

        return @sentence;
    } # end of sub expand

	#
	# If a temporary file has been left from a previous statement, unlink it.
	#

   unlink($generator->[GENERATOR_TMPNAM]) if defined $generator->[GENERATOR_TMPNAM];
   $generator->[GENERATOR_TMPNAM] = undef;

   my $starting_rule;

   if(0) {
      say("DEBUG: In FromGrammar for " . $executors->[0]->role() .
          " GENERATOR_SEQ_ID : " . $generator->[GENERATOR_SEQ_ID] .
          " GENERATOR_RECONNECT : " . $generator->[GENERATOR_RECONNECT]);
   }

   # Design
   # ======
   # 1. "threadN_init" or "query_init" or  "thread_init"
   #    Run this
   #    - ONLY ONCE per test for
   #      - creating objects required from the begin on
   #        Example: SQL base tables
   #        Hint: I recommend to use "gendata_sql" for that instead.
   #      - setting Perl stuff
   #      == All stuff which cannot get lost when being disconnected from the server.
   #         Hint: Temporary tables get lost with the session!
   #    - direct after getting a connection first time for the current executor
   #    - before running other top-level rules
   #         "*_connect", "thread<n>", "query" or "thread"
   #    This does not need to prepare 100% of the required and/or optimal playground for running
   #    queries generated from  "thread<n>", "query" or "thread" later.
   # 2. "threadN_connect" or "query_connect" or  "thread_connect"
   #    Run this
   #    - ONCE per ANY connect for creating the required and/or optimal conditions for
   #      running later a mass of queries generated from the top-level rules
   #         "thread<n>", "query" or "thread"
   #      Typical content is anything which would get lost after some disconnect like
   #         SET @aux = 13; SET SESSION  lock_wait_timeout = 1;
   #    - never before the first "threadN_init" or "query_init" or  "thread_init"
   #      Bad example:
   #      SET lock_wait_timeout = 1;
   #      When running this direct after the first connect within the test and and before
   #      "*_init" than the "*_init" has significant chances to suffer from locking timeouts
   #      which is usually unwanted.
   #    - before the first query generated from the top-level rules
   #         "thread<n>", "query" or "thread"
   # 3. "thread<n>", "query" or "thread"
   #    Generate with this the mass of queries.
   #    Some previous
   #    - "threadN_init" or "query_init" or "thread_init
   #      executed once per test run
   #    - "threadN_connect" or "query_connect" or  "thread_connect"
   #      executed after the first connect and any reconnect
   #    should take care that the right environment for that mass of queries is met.
   if ($generator->[GENERATOR_SEQ_ID] == 0) {
      # This means that we have never run a top-level "*_init" rule.
      # So do this now in case there is such a rule.
      if (exists $grammar_rules->{"thread".$generator->threadId()."_init"}) {
         $starting_rule = "thread".$generator->threadId()."_init";
      } elsif (exists $grammar_rules->{"query_init"}) {
         $starting_rule = "query_init";
      }
   } elsif ($generator->[GENERATOR_RECONNECT] == 1) {
      # This means that we had just a connect and maybe a run of a  top-level "*_init" rule.
      # So in case there is a "*_connect" than run it now.
      if (exists $grammar_rules->{"thread".$generator->threadId()."_connect"}) {
         $starting_rule = "thread".$generator->threadId()."_connect";
      } elsif (exists $grammar_rules->{"thread_connect"}) {
         $starting_rule = "thread_connect";
      } elsif (exists $grammar_rules->{"query_connect"}) {
         $starting_rule = "query_connect";
      }
      # say("DEBUG: FromGrammar Setting GENERATOR_RECONNECT to 0");
      $generator->[GENERATOR_RECONNECT] = 0;
   }

	## Apply mask if any
	$grammar = $generator->[GENERATOR_MASKED_GRAMMAR] if defined $generator->[GENERATOR_MASKED_GRAMMAR];
	$grammar_rules = $grammar->rules();

   # FIXME: Couldn't we move that in some else part before the masking stuff?
	# If no init starting rule, we look for rules named "threadN" or "query" or "thread"

	if (not defined $starting_rule) {
		if (exists $grammar_rules->{"thread".$generator->threadId()}) {
			$starting_rule = $grammar_rules->{"thread".$generator->threadId()}->name();
		} else {
			$starting_rule = "query";
		}
	}

	my @sentence = expand(\%rule_counters,\%rule_invariants,($starting_rule));


	$generator->[GENERATOR_SEQ_ID]++;

	my $sentence = join ('', map { defined $_ ? $_ : '' } @sentence);

	# Remove extra spaces while we are here
	while ($sentence =~ s/\.\s/\./s) {};
	while ($sentence =~ s/\s([\.,])/$1/s) {};
	while ($sentence =~ s/\s\s/ /s) {};
	while ($sentence =~ s/(\W)(AVG|BIT_AND|BIT_OR|BIT_XOR|COUNT|GROUP_CONCAT|MAX|MIN|STD|STDDEV_POP|STDDEV_SAMP|STDDEV|SUM|VAR_POP|VAR_SAMP|VARIANCE) /$1$2/s) {};

	$generator->[GENERATOR_PARTICIPATING_RULES] = [ keys %rule_counters ];

	# If this is a BEGIN ... END block or alike, then send it to server without splitting.
	# If the semicolon is inside a string literal, ignore it.
	# Otherwise, split it into individual statements so that the error and the result set from each statement
	# can be examined

	if (
		# Stored procedures of all sorts
			(
				(index($sentence, 'CREATE') > -1 ) &&
				(index($sentence, 'BEGIN') > -1 || index($sentence, 'END') > -1)
			)
		or
		# MDEV-5317, anonymous blocks BEGIN NOT ATOMIC .. END
			(
				(index($sentence, 'BEGIN') > -1 ) &&
				(index($sentence, 'ATOMIC') > -1 ) &&
				(index($sentence, 'END') > -1 )
			)
		or
		# MDEV-5317, IF .. THEN .. [ELSE ..] END IF
			(
				(index($sentence, 'IF') > -1 ) &&
				(index($sentence, 'THEN') > -1 ) &&
				(index($sentence, 'END') > -1 )
			)
		or
		# MDEV-5317, CASE .. [WHEN .. THEN .. [WHEN .. THEN ..] [ELSE .. ]] END CASE
			(
				(index($sentence, 'CASE') > -1 ) &&
				(index($sentence, 'WHEN') > -1 ) &&
				(index($sentence, 'THEN') > -1 ) &&
				(index($sentence, 'END') > -1 )
			)
		or
		# MDEV-5317, LOOP .. END LOOP
			(
				(index($sentence, 'LOOP') > -1 ) &&
				(index($sentence, 'END') > -1 )
			)
		or
		# MDEV-5317, REPEAT .. UNTIL .. END REPEAT
			(
				(index($sentence, 'REPEAT') > -1 ) &&
				(index($sentence, 'UNTIL') > -1 ) &&
				(index($sentence, 'END') > -1 )
			)
		or
		# MDEV-5317, WHILE .. DO .. END WHILE
			(
				(index($sentence, 'WHILE') > -1 ) &&
				(index($sentence, 'DO') > -1 ) &&
				(index($sentence, 'END') > -1 )
			)
	) {
		return [ $sentence ];
	} elsif (index($sentence, ';') > -1) {

		my @sentences;

		# We want to split the sentence into separate statements, but we do not want
		# to split literals if a semicolon happens to be inside.
		# I am sure it could be done much smarter; feel free to improve it.
		# For now, we do the following:
		# - store and mask all literals (inside single or double quote marks);
		# - replace remaining semicolons with something expectedly unique;
		# - restore the literals;
		# - split the sentence, not by the semicolon, but by the unique substitution
		# Do not forget that there can also be escaped quote marks, which are not literal boundaries

		if (index($sentence, "'") > -1 or index($sentence, '"') > -1) {
			# Store literals in single quotes
			my @singles = ( $sentence =~ /(?<!\\)(\'.*?(?<!\\)\')/g );
			# Mask these literals
			$sentence =~ s/(?<!\\)\'.*?(?<!\\)\'/######SINGLES######/g;
			# Store remaining literals in double quotes
			my @doubles = ( $sentence =~ /(?<!\\)(\".*?(?<!\\)\")/g );
			# Mask these literals
			$sentence =~ s/(?<!\\)\".*?(?<!\\)\"/######DOUBLES######/g;
			# Replace remaining semicolons
			$sentence =~ s/;/######SEMICOLON######/g;

			# Restore literals in double quotes
			while ( $sentence =~ s/######DOUBLES######/$doubles[0]/ ) {
				shift @doubles;
			}
			# Restore literals in single quotes
			while ( $sentence =~ s/######SINGLES######/$singles[0]/ ) {
				shift @singles;
			}
			# split the sentence
			@sentences = split('######SEMICOLON######', $sentence);
		}
		else {
			@sentences = split (';', $sentence);
		}
		return \@sentences;
    } else {
		return [ $sentence ];
    }
} # End of sub next

1;
