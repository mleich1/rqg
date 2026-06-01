#!/usr/bin/perl
use strict;
use warnings;
use MIME::Base64 qw(encode_base64);

# Emit the derived verdict lists from a ready-for-use Verdict config (e.g. Verdict_tmp.cfg)
# in the exact order and byte content that lib/Verdict.pm produces, base64 encoded so the
# C++ matcher consumes patterns identical to what Perl's m{} would compile.
# Output lines: bs <b64status> | ws <b64status> | bp/wp/ip <b64info> <b64pattern>

my $cfg = shift or die "usage: verdict_dump.pl <verdict_config>\n";
open my $fh, '<', $cfg or die "open $cfg: $!";
local $/; my $content = <$fh>; close $fh;

our ($statuses_replay, $statuses_interest, $statuses_ignore,
     $patterns_replay, $patterns_interest, $patterns_ignore);
eval $content;
die "eval $cfg failed: $@" if $@;

sub b64 { return encode_base64($_[0] // '', ''); }

# Replicates Verdict.pm load: hash keyed by status/pattern, last assessment wins.
my (%status_assess, %pattern_assess, %pattern_info);
sub load_st { my ($a,$l)=@_; return unless defined $l; $status_assess{$_->[0]}=$a for @$l; }
sub load_pt { my ($a,$l)=@_; return unless defined $l;
  for (@$l) { my ($info,$pat)=@$_; $pattern_assess{$pat}=$a; $pattern_info{$pat}=$info; } }
load_st('ignore',$statuses_ignore); load_st('interest',$statuses_interest); load_st('replay',$statuses_replay);
load_pt('ignore',$patterns_ignore); load_pt('interest',$patterns_interest); load_pt('replay',$patterns_replay);

# hashes_to_lists: sort keys; statuses ignore->bs, replay->ws; patterns ignore->bp, replay->wp, interest->ip.
for my $s (sort keys %status_assess) { print "bs " . b64($s) . "\n" if $status_assess{$s} eq 'ignore'; }
for my $s (sort keys %status_assess) { print "ws " . b64($s) . "\n" if $status_assess{$s} eq 'replay'; }
my %code = (ignore=>'bp', replay=>'wp', interest=>'ip');
for my $want (qw(ignore replay interest)) {
  for my $p (sort keys %pattern_assess) {
    next unless $pattern_assess{$p} eq $want;
    print $code{$want} . " " . b64($pattern_info{$p}) . " " . b64($p) . "\n";
  }
}
