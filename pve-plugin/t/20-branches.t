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

# ---- nodes is mandatory, and exactly one -----------------------------------
#
# PVE's schema makes 'nodes' optional; this plugin cannot. storage.cfg is
# cluster-wide but the driver holds one array per node with the superblock as
# a module parameter, so an unrestricted storage has every node contending for
# the same array and the same lock.
{
    my $cc = sub {
        my ($config, $create) = @_;
        my $err = '';
        eval { $P->check_config('nrpool', { %$config }, $create, 1) };
        $err = $@;
        return $err;
    };
    my $one = { 'testnode' => 1 };
    my $two = { 'testnode' => 1, 'othernode' => 1 };

    is($cc->({ path => '/mnt/pve/nrpool', nodes => $one }, 1), '',
        'create with exactly one node is accepted');
    like($cc->({ path => '/mnt/pve/nrpool' }, 1), qr/one node's hardware/,
        'create without nodes is refused');
    like($cc->({ path => '/mnt/pve/nrpool', nodes => $two }, 1),
        qr/exactly one node/, 'create naming two nodes is refused');
    like($cc->({ path => '/mnt/pve/nrpool', nodes => {} }, 1),
        qr/one node's hardware/, 'an empty nodes set is not a restriction');

    # Update: validated only when 'nodes' is being set, so a storage created
    # before this rule stays editable instead of becoming unparseable.
    is($cc->({ 'nonraid-super' => '/nonraid.dat' }, 0), '',
        'an update that does not touch nodes is left alone');
    like($cc->({ nodes => $two }, 0), qr/exactly one node/,
        'but an update that sets two nodes is refused');
    is($cc->({ nodes => $one }, 0), '',
        'and setting a single node is accepted');
}

done_testing();
