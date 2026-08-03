#!/usr/bin/perl
# The gate that decides whether a disk may be handed to nmdctl create/add.
# Everything downstream of it writes to the disk immediately, so each refusal
# gets a test and each reason has to name what to do about it.
use strict;
use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/..";

use PVE::Storage::DirPlugin;
use PVE::Storage::Custom::NonRAIDPlugin;

my $P = 'PVE::Storage::Custom::NonRAIDPlugin';
my $blockers = $P->can('disk_blockers');
my $fixtures = "$FindBin::Bin/fixtures";

sub live_array {
    local $ENV{PROC_NMDSTAT} = "$fixtures/nmdstat-started-clean.txt";
    return $P->can('read_nmdstat')->();
}

# A blank disk: no filesystem, no partitions, nothing mounted, not a member.
{
    my $free = { name => 'vdf', type => 'disk' };
    is_deeply($blockers->($free, live_array()), [], 'a blank disk has no blockers');
}

# The case that matters most: never offer a live array member for wiping.
# The clean fixture has rdevName.0=sda1, .1=sdb1, .2=sdc1.
{
    my $st = live_array();
    my $member = { name => 'sdb', type => 'disk' };
    my $b = $blockers->($member, $st);
    like($b->[0], qr/already in this array as data slot 1/, 'member named with its slot');

    my $parity = $blockers->({ name => 'sda', type => 'disk' }, $st);
    like($parity->[0], qr/already in this array as parity P/, 'parity disk named as parity');

    # The partition name itself, not just the disk, must be recognised.
    my $bypart = $blockers->({ name => 'sdb1', type => 'part' }, $st);
    like($bypart->[0], qr/already in this array/, 'member matched by partition name too');
}

# Mounted, and mounted-via-a-partition: both must refuse, and say where.
{
    my $b = $blockers->({ name => 'vdf', type => 'disk', mountpoint => '/srv' }, undef);
    like($b->[0], qr{mounted at /srv}, 'a mounted disk says where');

    $b = $blockers->({
        name => 'vdf', type => 'disk',
        children => [{ name => 'vdf1', type => 'part', mountpoint => '/srv/data' }],
    }, undef);
    like($b->[0], qr{vdf1 is mounted at /srv/data}, 'a mounted partition is named');
}

# A holder - LVM, dm-crypt, MD, Ceph - is somebody else's lifecycle.
{
    my $b = $blockers->({
        name => 'vdf', type => 'disk',
        children => [{ name => 'pve-root', type => 'lvm' }],
    }, undef);
    like($b->[0], qr/pve-root \(lvm\) holds it/, 'a holder is named with its type');
}

# Partitions alone are a blocker: this is the "wipe it first" case.
{
    my $b = $blockers->({
        name => 'vdf', type => 'disk',
        children => [
            { name => 'vdf1', type => 'part' },
            { name => 'vdf2', type => 'part' },
        ],
    }, undef);
    is_deeply($b, ['2 partition(s)'], 'partitions are the only blocker, and counted');
}

{
    my $b = $blockers->({ name => 'vdf', type => 'disk', fstype => 'ext4' }, undef);
    like($b->[0], qr/holds a ext4 filesystem/, 'a bare filesystem blocks');
    is_deeply($blockers->(undef, undef), ['device not found'], 'a missing device blocks');
}

# ---- argv construction ----------------------------------------------------

{
    my $specs = $P->can('build_assign_specs');
    is_deeply(
        [$specs->(['/dev/sda'], ['/dev/sdb', '/dev/sdc'], 1)],
        ['P:/dev/sda', '1:/dev/sdb', '2:/dev/sdc'],
        'single parity plus data slots from 1',
    );
    is_deeply(
        [$specs->(['/dev/sda', '/dev/sdz'], ['/dev/sdb'], 1)],
        ['P:/dev/sda', 'Q:/dev/sdz', '1:/dev/sdb'],
        'the second parity disk is Q, not a data slot',
    );
    # Adding to a live array must continue after the slots already in use.
    is_deeply(
        [$specs->([], ['/dev/sdd'], 4)],
        ['4:/dev/sdd'],
        'data-only assignment starts at the given slot',
    );
    eval { $specs->(['/dev/a', '/dev/b', '/dev/c'], [], 1) };
    like($@, qr/at most two parity/, 'a third parity disk is refused');
    eval { $specs->([], ['/dev/a'], 29) };
    like($@, qr/no free data slot/, 'slot 29 is Q, not a data slot');
}

{
    my $next = $P->can('next_free_slot');
    # The clean fixture occupies slots 1 and 2.
    is($next->(live_array()), 3, 'next free slot follows the occupied ones');
    is($next->({}), 1, 'an empty array starts at slot 1');
}

done_testing();
