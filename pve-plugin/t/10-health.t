#!/usr/bin/perl
use strict;
use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/..";

use PVE::Storage::DirPlugin;  # stub: satisfies the -norequire parent for ->can()
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
    my $d = $P->can('decide_start_action')->($st->{mdState}, 1, $h->{degraded});
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

# /proc/nmdstat can report a key with an empty value. It is defined, so '//'
# does not catch it, and every numeric comparison used to warn - once per
# pvestatd cycle, forever.
{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $st = load_fixture('nmdstat-empty-values.txt');
    my $h = $health->($st);

    is_deeply(\@warnings, [], 'empty counters produce no warnings');
    is($h->{degraded}, 0, 'empty counters read as zero, not as degraded');
    is($h->{rebuilding}, 0, 'empty mdResync reads as not rebuilding');
    is($h->{summary}, 'STARTED', 'summary stays clean');

    # data_slots already guarded empty values; an empty size must still drop
    # the slot rather than warn.
    is_deeply([$P->can('data_slots')->($st)], [1], 'slot with an empty size is dropped');
    is_deeply(\@warnings, [], 'data_slots stays warning-free too');
}

# Superblock identity: the driver holds one array per node, so a storage
# pointed at a different superblock must not adopt whatever is running.
{
    my $matches = $P->can('superblock_matches');
    ok($matches->({ sbName => '/nonraid.dat' }, '/nonraid.dat'), 'same path matches');
    ok($matches->({ sbName => '/nonraid.dat' }, '//nonraid.dat'), 'canonicalized before compare');
    ok(!$matches->({ sbName => '/nonraid.dat' }, '/srv/other.dat'), 'different superblock refused');
    ok($matches->({ sbName => '' }, '/nonraid.dat'), 'no live superblock: nothing to contradict');
    ok($matches->({}, '/nonraid.dat'), 'missing sbName: nothing to contradict');
}

# Member mounts must come from the array's own devices.
{
    my $ok = $P->can('member_source_ok');

    # The driver exposes exactly one partition per slot, and nmdctl names the
    # LUKS mapping after it (diskName.N is 'nmdNp1'). Anything else mounted at
    # a member's mountpoint would be unioned into a guest-writable pool.
    ok($ok->('/dev/nmd1p1', 1), 'the member device for its slot');
    ok(!$ok->('/dev/nmd1p2', 1), 'a different partition of the same slot rejected');
    ok(!$ok->('/dev/nmd1', 1), 'the whole-disk node rejected: members are partitions');
    ok(!$ok->('/dev/nmd11p1', 1), 'slot 11 is not slot 1');
    ok(!$ok->('/dev/nmd2p1', 1), 'member device for a different slot rejected');
    ok(!$ok->('/dev/sdz1', 1), 'foreign device rejected');
    ok(!$ok->(undef, 1), 'undef source rejected');

    # Device-mapper members are decided by the kernel's slave list, not by the
    # mapper's name: 'nmd1p1' does not end on a word boundary, so name-matching
    # rejected the real LUKS path, and any mapping whose name merely contained
    # the string passed.
    my $slaves = sub {
        my ($source) = @_;
        return ['nmd1p1'] if $source eq '/dev/mapper/nmd1p1';
        return ['nmd1p1'] if $source eq '/dev/mapper/anything-at-all';
        return ['sda1'] if $source eq '/dev/mapper/nmd1-decoy';
        return undef; # not a dm device
    };
    ok($ok->('/dev/mapper/nmd1p1', 1, $slaves), 'the real LUKS mapper path for its slot');
    ok($ok->('/dev/mapper/anything-at-all', 1, $slaves),
        'a differently-named mapping over the member is still the member');
    ok(!$ok->('/dev/mapper/nmd1-decoy', 1, $slaves),
        'a mapper whose name contains the member but is backed by something else');
    ok(!$ok->('/dev/mapper/nmd1p1', 2, $slaves), 'the right member, the wrong slot');
    ok(!$ok->('/dev/sdz1', 1, $slaves), 'a non-dm foreign device has no slaves to save it');
}

done_testing();
