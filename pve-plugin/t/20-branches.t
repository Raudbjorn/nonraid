#!/usr/bin/perl
use strict;
use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/..";

use PVE::Storage::Custom::NonRAIDPlugin;

my $P = 'PVE::Storage::Custom::NonRAIDPlugin';
my $fixtures = "$FindBin::Bin/fixtures";

my $data_slots = \&{"${P}::data_slots"};
my $branches = \&{"${P}::mergerfs_branches"};

sub load_fixture {
    my ($name) = @_;
    local $ENV{PROC_NMDSTAT} = "$fixtures/$name";
    return $P->can('read_nmdstat')->();
}

{
    my $st = load_fixture('nmdstat-started-clean.txt');
    is_deeply([$data_slots->($st)], [1, 2], 'clean fixture: data slots 1 and 2');
    is_deeply(
        [$branches->($st, '/mnt/disk')],
        ['/mnt/disk1', '/mnt/disk2'],
        'branches from prefix',
    );
}

# Slot 0 (P) and 29 (Q) are never data slots, even with a name and size set.
{
    my $st = {
        'diskName.0' => 'nmd0p1', 'diskSize.0' => 100,
        'diskName.29' => 'nmd29p1', 'diskSize.29' => 100,
        'diskName.5' => 'nmd5p1', 'diskSize.5' => 100,
    };
    is_deeply([$data_slots->($st)], [5], 'parity slots excluded');
}

# Empty name or zero size excludes a slot.
{
    my $st = {
        'diskName.1' => '', 'diskSize.1' => 100,
        'diskName.2' => 'nmd2p1', 'diskSize.2' => 0,
        'diskName.3' => 'nmd3p1', 'diskSize.3' => 100,
    };
    is_deeply([$data_slots->($st)], [3], 'empty name and zero size excluded');
}

# Numeric ordering, not lexical: 2 before 10.
{
    my $st = {
        'diskName.10' => 'nmd10p1', 'diskSize.10' => 100,
        'diskName.2' => 'nmd2p1', 'diskSize.2' => 100,
    };
    is_deeply([$data_slots->($st)], [2, 10], 'numeric slot ordering');
    is_deeply(
        [$branches->($st, '/mnt/d')],
        ['/mnt/d2', '/mnt/d10'],
        'branch list keeps numeric order',
    );
}

{
    my $opts = $P->can('default_mergerfs_opts')->('nrpool');
    like($opts, qr/fsname=nonraid-nrpool/, 'fsname carries the storage id');
    like($opts, qr/cache\.files=off/, 'O_DIRECT-compatible cache mode');
    like($opts, qr/moveonenospc=true/, 'moveonenospc enabled');
    # E2E-found bug: minfreespace above the smallest branch makes every
    # create fail with ENOSPC; pin the default at 1G so it cannot silently
    # creep back up to mergerfs's 4G default.
    like($opts, qr/minfreespace=1G/, 'minfreespace stays below small branches');
}

done_testing();
