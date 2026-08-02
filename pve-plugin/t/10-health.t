#!/usr/bin/perl
use strict;
use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/..";

use PVE::Storage::Custom::NonRAIDPlugin;

my $P = 'PVE::Storage::Custom::NonRAIDPlugin';
my $fixtures = "$FindBin::Bin/fixtures";

sub load_fixture {
    my ($name) = @_;
    local $ENV{PROC_NMDSTAT} = "$fixtures/$name";
    return $P->can('read_nmdstat')->();
}

my $health = \&{"${P}::nmdstat_health"};

{
    my $h = $health->(load_fixture('nmdstat-started-clean.txt'));
    is($h->{state}, 'STARTED', 'clean: state');
    is($h->{degraded}, 0, 'clean: not degraded');
    is($h->{rebuilding}, 0, 'clean: not rebuilding');
    is($h->{summary}, 'STARTED', 'clean: bare summary');
}

{
    my $h = $health->(load_fixture('nmdstat-started-degraded.txt'));
    is($h->{degraded}, 1, 'degraded: flagged');
    like($h->{summary}, qr/DEGRADED\(disabled=1/, 'degraded: summary names the cause');
}

{
    my $h = $health->(load_fixture('nmdstat-rebuilding.txt'));
    is($h->{rebuilding}, 1, 'rebuilding: flagged');
    is($h->{resync_pct}, '50.0', 'rebuilding: percentage computed');
    like($h->{summary}, qr/RESYNC:recon P/, 'rebuilding: summary names the action');
    unlike($h->{summary}, qr/50/, 'rebuilding: summary is progress-stable (no percentage)');
}

# The fresh-create quirk: counters lie until the module is reloaded. Health
# may flag degraded (advisory), but nothing that gates start/online is
# allowed to consult the counters - the start decision for STARTED is 'none'.
{
    my $st = load_fixture('nmdstat-fresh-create-quirk.txt');
    my $h = $health->($st);
    is($h->{degraded}, 1, 'quirk: counters flag degraded (advisory only)');
    my $d = $P->can('decide_start_action')->($st->{mdState}, 1);
    is($d->{action}, 'none', 'quirk: STARTED array is never restarted because of counters');
}

# resync size 0 must not divide by zero
{
    my $st = load_fixture('nmdstat-started-clean.txt');
    $st->{mdResync} = 100;
    $st->{mdResyncSize} = 0;
    my $h = $health->($st);
    is($h->{rebuilding}, 1, 'size 0: still rebuilding');
    is($h->{resync_pct}, undef, 'size 0: no percentage, no division by zero');
}

done_testing();
