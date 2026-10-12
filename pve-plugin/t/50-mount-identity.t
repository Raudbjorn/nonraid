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
my $GiB = 1024 * 1024 * 1024;

my %base_xattrs = (
    'user.mergerfs.branches' => '/mnt/disk1=RW:/mnt/disk2=RW',
    'user.mergerfs.cache.files' => 'off',
    'user.mergerfs.category.create' => 'mfs',
    'user.mergerfs.moveonenospc' => 'false',
    'user.mergerfs.minfreespace' => "$GiB",
    'user.mergerfs.fsname' => 'nonraid-nrpool',
);

sub configure_live {
    my (%args) = @_;
    local $PVE::Storage::Custom::NonRAIDPlugin::PROC_NMDSTAT_PATH = "$fixtures/nmdstat-started-clean.txt";
    local $PVE::Storage::Custom::NonRAIDPlugin::MOUNTINFO_PATH = "$fixtures/mountinfo-clean.txt";
    local $PVE::Storage::Custom::NonRAIDPlugin::GET_FATTR = sub {
        my ($path, $key) = @_;
        return $args{allpaths}->($path) if $key eq 'user.mergerfs.allpaths';
        die "missing test xattr $key\n" if !exists($base_xattrs{$key});
        return $base_xattrs{$key};
    };
    return $args{code}->();
}

my $capacity = $P->can('branch_usable_bytes');
ok($capacity, 'branch capacity helper is exposed for focused tests');

SKIP: {
    skip 'branch capacity helpers are absent', 29 if !$capacity;

    local $PVE::Tools::DF_CB = sub {
        my ($path, $timeout) = @_;
        is($timeout, 2, 'branch stat uses bounded PVE timeout');
        return { total => 10 * $GiB, used => 7 * $GiB, avail => 3 * $GiB };
    };
    is($capacity->('/mnt/disk1'), 2 * $GiB, 'fixed 1 GiB reserve is subtracted from byte-normalized avail');

    local $PVE::Tools::DF_CB = sub { return { total => $GiB, used => $GiB, avail => $GiB - 1 } };
    is($capacity->('/mnt/disk1'), 0, 'capacity floors at zero below the reserve');

    my $opts = $P->can('default_mergerfs_opts')->('nrpool');
    is($opts, 'cache.files=off,category.create=mfs,moveonenospc=false,minfreespace=1G,fsname=nonraid-nrpool', 'immutable mergerfs safety options are exact');

    my $scfg = {
        type => 'nonraid',
        path => '/mnt/pve/nrpool',
        'nonraid-super' => '/nonraid.dat',
        nodes => { 'node-a' => 1 },
        format => 'qcow2',
        preallocation => 'falloc',
    };
    my @parent_alloc;
    local $PVE::Storage::DirPlugin::ALLOC_IMAGE_CB = sub {
        push @parent_alloc, [@_];
        return '100/vm-100-disk-0.qcow2';
    };
    local $PVE::Storage::DirPlugin::FILESYSTEM_PATH_CB = sub {
        my ($class, $config, $volname) = @_;
        return "$config->{path}/images/$volname";
    };
    local $PVE::Storage::DirPlugin::FREE_IMAGE_CB = sub { die "cleanup not expected\n" };

    local $PVE::Tools::DF_CB = sub {
        my ($path) = @_;
        die "aggregate pool space consulted\n" if $path eq $scfg->{path};
        return { total => 10 * $GiB, used => 8.5 * $GiB, avail => 1.5 * $GiB };
    };
    my $ok = eval {
        configure_live(
            allpaths => sub { die "owner xattr must not be read before allocation\n" },
            code => sub { $P->alloc_image('nrpool', $scfg, 100, 'qcow2', undef, 2 * 1024 * 1024) },
        );
        1;
    };
    ok(!$ok, 'aggregate free cannot admit an image that fits no live branch');
    like($@, qr/no live branch can reserve 2147483648 bytes/, 'allocation rejection uses KiB-to-byte conversion');
    is(scalar(@parent_alloc), 0, 'impossible reservation fails before parent creation');

    local $PVE::Tools::DF_CB = sub {
        my ($path) = @_;
        return { total => 10 * $GiB, used => 8.75 * $GiB, avail => 1.25 * $GiB }
            if $path eq '/mnt/disk1';
        return { total => 10 * $GiB, used => 8 * $GiB, avail => 2 * $GiB }
            if $path eq '/mnt/disk2';
        die "aggregate pool space consulted\n";
    };
    my $vol = configure_live(
        allpaths => sub {
            my ($path) = @_;
            is($path, '/mnt/pve/nrpool/images/100/vm-100-disk-0.qcow2', 'postcondition checks the created pool path');
            return '/mnt/disk2/images/100/vm-100-disk-0.qcow2';
        },
        code => sub { $P->alloc_image('nrpool', $scfg, 100, 'qcow2', undef, 256 * 1024) },
    );
    is($vol, '100/vm-100-disk-0.qcow2', 'successful parent allocation result is preserved');
    is(scalar(@parent_alloc), 1, 'parent allocation runs exactly once after admission');

    my @cleanup;
    local $PVE::Storage::DirPlugin::FREE_IMAGE_CB = sub { push @cleanup, [@_]; return };
    $ok = eval {
        configure_live(
            allpaths => sub { return "/mnt/disk1/images/100/vm-100-disk-0.qcow2\0/mnt/disk2/images/100/vm-100-disk-0.qcow2" },
            code => sub { $P->alloc_image('nrpool', $scfg, 100, 'qcow2', undef, 256 * 1024) },
        );
        1;
    };
    ok(!$ok, 'multi-owner partial allocation fails its postcondition');
    like($@, qr/exactly one live branch owner/, 'multi-owner failure is explicit');
    is(scalar(@cleanup), 1, 'postcondition failure delegates cleanup exactly once');
    is($cleanup[0]->[3], '100/vm-100-disk-0.qcow2', 'cleanup receives the allocated volume');

    my @resize;
    local $PVE::Storage::DirPlugin::VOLUME_SIZE_INFO_CB = sub { return 512 * 1024 * 1024 };
    local $PVE::Storage::DirPlugin::VOLUME_RESIZE_CB = sub { push @resize, [@_]; return 'parent-result' };
    local $PVE::Tools::DF_CB = sub {
        my ($path) = @_;
        return { total => 10 * $GiB, used => 8.7 * $GiB, avail => 1.3 * $GiB }
            if $path eq '/mnt/disk1';
        die "resize consulted non-owner branch '$path'\n";
    };
    $ok = eval {
        configure_live(
            allpaths => sub { return '/mnt/disk1/images/100/vm-100-disk-0.qcow2' },
            code => sub { $P->volume_resize($scfg, 'nrpool', '100/vm-100-disk-0.qcow2', 900 * 1024 * 1024, 0, undef) },
        );
        1;
    };
    ok(!$ok, 'resize growth exceeding owner branch capacity is rejected');
    like($@, qr/owner branch.*cannot reserve.*406847488 bytes/, 'resize rejection reports exact byte delta');
    is(scalar(@resize), 0, 'rejected resize never reaches parent');

    local $PVE::Tools::DF_CB = sub { return { total => 10 * $GiB, used => 8 * $GiB, avail => 2 * $GiB } };
    my $result = configure_live(
        allpaths => sub { return '/mnt/disk1/images/100/vm-100-disk-0.qcow2' },
        code => sub { $P->volume_resize($scfg, 'nrpool', '100/vm-100-disk-0.qcow2', 700 * 1024 * 1024, 0, undef) },
    );
    is($result, 'parent-result', 'admitted resize preserves parent return');
    is(scalar(@resize), 1, 'admitted resize delegates exactly once');

    $ok = eval {
        configure_live(
            allpaths => sub { return "/mnt/disk1/images/100/vm-100-disk-0.qcow2\0/mnt/disk2/images/100/vm-100-disk-0.qcow2" },
            code => sub { $P->volume_resize($scfg, 'nrpool', '100/vm-100-disk-0.qcow2', 700 * 1024 * 1024, 0, undef) },
        );
        1;
    };
    ok(!$ok, 'ambiguous image ownership makes resize unsupported');
    like($@, qr/resize unsupported.*exactly one live branch owner/, 'ambiguous resize error is explicit');
}

done_testing();
