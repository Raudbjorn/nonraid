#!/usr/bin/perl
# SPDX-License-Identifier: AGPL-3.0-or-later
use strict;
use warnings;

use FindBin;
use Test::More;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/..";
use PVE::Storage;

my $P = 'PVE::Storage::Custom::NonRAIDPlugin';
my $fixtures = "$FindBin::Bin/fixtures";

sub text {
    my ($name) = @_;
    open(my $fh, '<', "$fixtures/$name") or die "open fixture: $!";
    return do { local $/; <$fh> };
}

sub nmdstat {
    return $P->can('parse_nmdstat_text')->(text('nmdstat-started-clean.txt'));
}

my $parse = $P->can('parse_mountinfo_text');
ok($parse, 'strict mountinfo parser is exposed for focused tests');

SKIP: {
    skip 'strict mountinfo parser is absent', 35 if !$parse;

    my $mounts = $parse->(text('mountinfo-clean.txt'));
    is(scalar(@{$mounts}), 3, 'all mountinfo records parse');
    is($mounts->[0]->{mountpoint}, '/mnt/disk1', 'mountpoint is decoded');
    is($mounts->[0]->{source}, '/dev/nmd1p1', 'source is decoded');

    my $escaped = $parse->("1 0 0:1 / /mnt/disk\\040one rw - btrfs /dev/mapper/a\\134b rw\n");
    is($escaped->[0]->{mountpoint}, '/mnt/disk one', 'octal space is unescaped');
    is($escaped->[0]->{source}, '/dev/mapper/a\\b', 'octal backslash is unescaped');

    for my $bad (
        ["1 - btrfs /dev/nmd1p1 rw\n", qr/malformed mountinfo line/, 'malformed record'],
        ["1 0 0:1 / /mnt/disk1 rw btrfs /dev/nmd1p1 rw\n", qr/missing separator/, 'missing separator'],
        ["1 0 0:1 / /mnt/disk\\999 rw - btrfs /dev/nmd1p1 rw\n", qr/invalid mountinfo escape/, 'invalid escape'],
    ) {
        my ($input, $pattern, $name) = @{$bad};
        my $ok = eval { $parse->($input); 1 };
        ok(!$ok, "$name is rejected");
        like($@, $pattern, "$name reports its reason");
    }

    my $st = nmdstat();
    my $assert_members = $P->can('assert_member_mounts');
    is_deeply($assert_members->($st, $mounts), ['/mnt/disk1', '/mnt/disk2'], 'ordinary members have exact ordered identities');

    my $luks = $parse->("36 25 0:32 / /mnt/disk1 rw - btrfs /dev/mapper/nmd1p1 rw\n37 25 0:33 / /mnt/disk2 rw - xfs /dev/nmd2p1 rw\n");
    is_deeply($assert_members->($st, $luks), ['/mnt/disk1', '/mnt/disk2'], 'exact LUKS mapper identity is accepted');
    my $zfs = $parse->("36 25 0:32 / /mnt/disk1 rw - zfs disk1 rw\n37 25 0:33 / /mnt/disk2 rw - zfs disk2 rw\n");
    is_deeply($assert_members->($st, $zfs), ['/mnt/disk1', '/mnt/disk2'], 'exact ZFS slot source is accepted');

    for my $case (
        ["36 25 0:32 / /mnt/disk1 rw - btrfs /dev/nmd2p1 rw\n37 25 0:33 / /mnt/disk2 rw - xfs /dev/nmd2p1 rw\n", qr/wrong source.*disk1/, 'wrong member source'],
        ["36 25 0:32 / /mnt/disk1 rw - tmpfs /dev/nmd1p1 rw\n37 25 0:33 / /mnt/disk2 rw - xfs /dev/nmd2p1 rw\n", qr/unsupported filesystem.*tmpfs/, 'foreign member filesystem'],
        ["36 25 0:32 / /mnt/disk1 rw - btrfs /dev/nmd1p1 rw\n", qr/missing mount.*disk2/, 'missing slot'],
        [text('mountinfo-clean.txt') . "61 25 0:32 / /elsewhere rw - btrfs /dev/nmd1p1 rw\n", qr/source.*mounted more than once/, 'duplicate source mount'],
        [text('mountinfo-clean.txt') . "62 25 0:60 / /mnt/disk3 rw - btrfs /dev/other rw\n", qr/unexpected fixed member mount.*disk3/, 'hidden extra branch'],
    ) {
        my ($input, $pattern, $name) = @{$case};
        my $ok = eval { $assert_members->($st, $parse->($input)); 1 };
        ok(!$ok, "$name fails closed");
        like($@, $pattern, "$name reports its reason");
    }

    local $PVE::Storage::Custom::NonRAIDPlugin::MOUNTINFO_PATH = "$fixtures/mountinfo-clean.txt";
    local $ENV{PROC_SELF_MOUNTINFO} = '/definitely/not/the/test-fixture';
    is(scalar(@{$P->can('read_mountinfo')->()}), 3, 'package path seam controls bounded mountinfo read');

    my %xattrs;
    for my $line (split(/\n/, text('mergerfs-xattrs-clean.txt'))) {
        next if $line eq '';
        my ($key, $value) = split(/=/, $line, 2);
        $xattrs{$key} = $value;
    }
    local $PVE::Storage::Custom::NonRAIDPlugin::GET_FATTR = sub {
        my ($path, $key) = @_;
        die "wrong control path\n" if $path ne '/mnt/pve/nrpool/.mergerfs';
        die "missing xattr $key\n" if !exists($xattrs{$key});
        return $xattrs{$key};
    };
    my $assert_pool = $P->can('assert_pool_identity');
    ok($assert_pool->('nrpool', '/mnt/pve/nrpool', ['/mnt/disk1', '/mnt/disk2'], $mounts), 'exact pool mount and xattrs are accepted');

    my @drift = (
        ['user.mergerfs.branches', '/mnt/disk2=RW:/mnt/disk1=RW', qr/branches/, 'branch order drift'],
        ['user.mergerfs.branches', '/mnt/disk1=RO:/mnt/disk2=RW', qr/branches/, 'branch mode drift'],
        ['user.mergerfs.branches', '/mnt/disk1=RW:/mnt/disk2=RW:/mnt/disk3=RW', qr/branches/, 'hidden xattr branch'],
        ['user.mergerfs.cache.files', 'on', qr/cache\.files/, 'cache drift'],
        ['user.mergerfs.category.create', 'ff', qr/category\.create/, 'create policy drift'],
        ['user.mergerfs.moveonenospc', 'true', qr/moveonenospc/, 'move-on-ENOSPC drift'],
        ['user.mergerfs.minfreespace', '4294967296', qr/minfreespace/, 'minimum-free drift'],
        ['user.mergerfs.fsname', 'mergerfs', qr/fsname/, 'fsname drift'],
    );
    for my $case (@drift) {
        my ($key, $bad, $pattern, $name) = @{$case};
        local $xattrs{$key} = $bad;
        my $ok = eval { $assert_pool->('nrpool', '/mnt/pve/nrpool', ['/mnt/disk1', '/mnt/disk2'], $mounts); 1 };
        ok(!$ok, "$name fails closed");
        like($@, $pattern, "$name reports its reason");
    }

    my @foreign = map { +{%{$_}} } @{$mounts};
    $foreign[2]->{fstype} = 'ext4';
    my $ok = eval { $assert_pool->('nrpool', '/mnt/pve/nrpool', ['/mnt/disk1', '/mnt/disk2'], \@foreign); 1 };
    ok(!$ok, 'foreign pool filesystem fails closed');
    like($@, qr/not an exact fuse\.mergerfs mount/, 'foreign pool reason is explicit');

    my @stale = map { +{%{$_}} } @{$mounts};
    $stale[2]->{source} = 'nonraid-old';
    $ok = eval { $assert_pool->('nrpool', '/mnt/pve/nrpool', ['/mnt/disk1', '/mnt/disk2'], \@stale); 1 };
    ok(!$ok, 'stale pool source fails closed');
    like($@, qr/wrong source/, 'stale pool source is explicit');
}

done_testing();
