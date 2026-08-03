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

# lsblk nests, and the layout that matters is two levels down: disk -> part ->
# LVM/dm-crypt/MD. Looking only at direct children saw a bare 'part' and said
# "1 partition(s)" - which wipe_disks drops as the very reason one wipes, so a
# disk whose partition carried a mounted root LV arrived at wipefs with no
# blockers at all.
{
    my $nested = sub {
        my ($leaf) = @_;
        return { name => 'vdx', type => 'disk',
            children => [{ name => 'vdx1', type => 'part', children => [$leaf] }] };
    };
    my $fatal = sub {
        # What wipe_disks sees: everything except the partition count.
        return [grep { !/^\d+ partition/ } @{ $blockers->($_[0], undef) }];
    };

    my $mounted_lv = $nested->({ name => 'pve-root', type => 'lvm', mountpoint => '/' });
    like($blockers->($mounted_lv, undef)->[0], qr{pve-root is mounted at /},
        'a mounted LV two levels down is seen');
    ok(scalar @{ $fatal->($mounted_lv) }, 'and it survives the wipe filter');

    my $bare_pv = $nested->({ name => 'pve-data', type => 'lvm' });
    like($blockers->($bare_pv, undef)->[0], qr/pve-data \(lvm\) holds it/,
        'an unmounted LVM holder two levels down is seen');
    ok(scalar @{ $fatal->($bare_pv) }, 'and it survives the wipe filter');

    my $deep = $nested->({ name => 'cr', type => 'crypt',
        children => [{ name => 'cr-lv', type => 'lvm', mountpoint => '/srv' }] });
    my $b = $blockers->($deep, undef);
    like(join('; ', @$b), qr/cr \(crypt\) holds it/, 'the crypt layer is named');
    like(join('; ', @$b), qr{cr-lv is mounted at /srv}, 'and so is what sits on it');

    # The one case that must still be wipeable: a plain partition table.
    my $plain = { name => 'vdx', type => 'disk',
        children => [{ name => 'vdx1', type => 'part' }, { name => 'vdx2', type => 'part' }] };
    is_deeply($fatal->($plain), [], 'a plain partition table is still wipeable');
    is_deeply($blockers->($plain, undef), ['2 partition(s)'],
        'and the count stays top-level, describing the partition table');
}

# Member matching derives the disk from rdevName, and a blind s/p?\d+$// also
# eats the trailing digits of whole-device names.
{
    my %fixture = (
        'nvme0n1p1' => 'nvme0n1',
        'mmcblk0p2' => 'mmcblk0',
        'sdb1' => 'sdb',
        'vde2' => 'vde',
        'nvme0n1' => 'nvme0n1',
        'mmcblk0' => 'mmcblk0',
    );
    for my $rdev (sort keys %fixture) {
        my $disk = $fixture{$rdev};
        my $st = { 'rdevName.1' => $rdev, 'diskName.1' => 'nmd1p1' };
        my $b = $blockers->({ name => $disk, type => 'disk' }, $st);
        like($b->[0] // '', qr/already in this array/,
            "rdevName '$rdev' is recognised as belonging to disk '$disk'");
    }
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

# Realistic whole-disk layouts, run through the gate exactly as wipe_disks
# sees it. Every one of these is a disk somebody could pick in the dialog.
{
    my $wipe_fatal = sub {
        return [grep { !/^\d+ partition/ && !/holds a .* filesystem$/ }
            @{ $blockers->($_[0], undef) }];
    };

    # PVE's default installer layout: the running root is an LV two levels
    # down, and the disk itself has neither mountpoint nor fstype.
    my $pve_root = { name => 'sda', type => 'disk', children => [
        { name => 'sda2', type => 'part', fstype => 'vfat' },
        { name => 'sda3', type => 'part', fstype => 'LVM2_member', children => [
            { name => 'pve-swap', type => 'lvm', fstype => 'swap' },
            { name => 'pve-root', type => 'lvm', fstype => 'ext4', mountpoint => '/' },
        ] },
    ] };
    ok(scalar @{ $wipe_fatal->($pve_root) }, 'the PVE root disk is never wipeable');
    like(join('; ', @{ $blockers->($pve_root, undef) }), qr{pve-root is mounted at /},
        'and the mounted LV is what it names');

    # The same disk with the ESP not mounted - what saved the case above was a
    # coincidence of the installer's layout, not a guard.
    my $esp_unmounted = { name => 'sda', type => 'disk', children => [
        { name => 'sda3', type => 'part', fstype => 'LVM2_member', children => [
            { name => 'pve-root', type => 'lvm', fstype => 'ext4', mountpoint => '/' },
        ] },
    ] };
    ok(scalar @{ $wipe_fatal->($esp_unmounted) },
        'still refused with nothing mounted from the ESP');

    # A ZFS vdev with the pool EXPORTED has no children and no mountpoint at
    # all: a bare zfs_member signature on a partition. This is the layout that
    # gets past mountpoint checks, holder-type checks and child recursion
    # alike, because there is nothing assembled to find.
    my $zfs_exported = { name => 'sdb', type => 'disk', children => [
        { name => 'sdb1', type => 'part', fstype => 'zfs_member' },
        { name => 'sdb9', type => 'part' },
    ] };
    like(join('; ', @{ $blockers->($zfs_exported, undef) }),
        qr/sdb1 carries a zfs_member signature/, 'an exported ZFS vdev is recognised');
    ok(scalar @{ $wipe_fatal->($zfs_exported) }, 'and refused');

    for my $sig (qw(LVM2_member linux_raid_member crypto_LUKS ceph_bluestore)) {
        my $e = { name => 'sdc', type => 'disk',
            children => [{ name => 'sdc1', type => 'part', fstype => $sig }] };
        ok(scalar @{ $wipe_fatal->($e) }, "a bare $sig signature is fatal to a wipe");
    }

    # The other direction: an ordinary filesystem is precisely what wipefs is
    # for. Refusing it left a disk formatted with no partition table refused by
    # BOTH wipe and assign - a dead end in the funnel, with the operator sent
    # to the shell to run the command this feature exists to replace.
    my $bare_fs = { name => 'sdz', type => 'disk', fstype => 'btrfs' };
    is_deeply($wipe_fatal->($bare_fs), [], 'a bare-formatted disk is wipeable');
    is_deeply($blockers->($bare_fs, undef), ['holds a btrfs filesystem'],
        'but not assignable until it has been');

    my $ext4_parts = { name => 'sdx', type => 'disk', children => [
        { name => 'sdx1', type => 'part', fstype => 'ext4' },
        { name => 'sdx2', type => 'part', fstype => 'ext4' },
    ] };
    is_deeply($wipe_fatal->($ext4_parts), [], 'unmounted data partitions are wipeable');
    like(join('; ', @{ $blockers->($ext4_parts, undef) }), qr/sdx1 holds a ext4/,
        'and each one is named, not reported twice as the same sentence');
}

done_testing();
