#!/usr/bin/perl
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright 2026 Sveinbjörn Geirsson

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir tempfile);
use FindBin;
use Test::More;

use lib "$FindBin::Bin/lib", "$FindBin::Bin/..";
use PVE::Storage;

my $plugin = PVE::Storage::Plugin->lookup('nonraid');
BAIL_OUT('nonraid plugin did not register') if !defined($plugin);

sub config_dies_like {
    my ($config, $create, $pattern, $name) = @_;
    my $ok = eval {
        $plugin->check_config('nrpool', $config, $create, 0);
        1;
    };
    ok(!$ok, $name);
    like($@, $pattern, "$name reports its reason");
}

my ($super_fh, $super_path) = tempfile();
close($super_fh);

{
    my $config = {
        'nonraid-super' => $super_path,
        nodes => 'node-a',
        content => 'images,backup',
        format => 'qcow2',
        preallocation => 'falloc',
    };
    my $checked = $plugin->check_config('nrpool', $config, 1, 0);
    is($checked->{path}, '/mnt/pve/nrpool', 'create defaults the pool path');
    is($checked->{format}, 'qcow2', 'required qcow2 format is retained');
    is($checked->{preallocation}, 'falloc', 'required falloc preallocation is retained');
    is_deeply($checked->{nodes}, { 'node-a' => 1 }, 'one-node scope is decoded');
    is($plugin->get_identity($checked), $super_path, 'identity is the literal configured super path');
}

config_dies_like(
    {
        'nonraid-super' => $super_path,
        content => 'images',
        format => 'qcow2',
        preallocation => 'falloc',
    },
    1,
    qr/missing value for required option 'nodes'/,
    'nodes is mandatory',
);
config_dies_like(
    { 'nonraid-super' => $super_path, nodes => 'node-a,node-b' },
    1,
    qr/exactly one node/,
    'multiple nodes are rejected',
);
config_dies_like(
    { 'nonraid-super' => $super_path, nodes => '' },
    1,
    qr/exactly one node/,
    'empty node scope is rejected',
);

config_dies_like(
    {
        'nonraid-super' => $super_path,
        nodes => 'node-a',
        preallocation => 'falloc',
    },
    1,
    qr/missing value for required option 'format'/,
    'format is mandatory',
);
config_dies_like(
    {
        'nonraid-super' => $super_path,
        nodes => 'node-a',
        format => 'qcow2',
    },
    1,
    qr/missing value for required option 'preallocation'/,
    'preallocation is mandatory',
);

for my $case (
    ['relative/pool', qr/absolute/, 'relative pool path'],
    ['/mnt/pve/../disk1', qr/\.\./, 'parent traversal in pool path'],
    ['/mnt/pve/nr pool', qr/whitespace/, 'whitespace in pool path'],
    ['/', qr/overlap/, 'root pool overlapping every member'],
    ['/mnt', qr/overlap/, 'member parent used as pool'],
    ['/mnt/disk1', qr/overlap/, 'member path used as pool'],
    ['/mnt/disk1/pool', qr/overlap/, 'pool nested under member'],
) {
    my ($path, $pattern, $name) = @{$case};
    config_dies_like(
        { path => $path, 'nonraid-super' => $super_path, nodes => 'node-a' },
        1,
        $pattern,
        $name,
    );
}

for my $case (
    ['relative/super', qr/absolute/, 'relative super path'],
    ['/tmp/nonraid ../super', qr/whitespace/, 'whitespace in super path'],
    ['/tmp/nonraid/../super', qr/\.\./, 'parent traversal in super path'],
    ['/tmp/nonraid-super-does-not-exist', qr/must already exist/, 'missing super file'],
) {
    my ($super, $pattern, $name) = @{$case};
    config_dies_like(
        { 'nonraid-super' => $super, nodes => 'node-a' },
        1,
        $pattern,
        $name,
    );
}

{
    my $dir = tempdir(CLEANUP => 1);
    my $real = File::Spec->catfile($dir, 'real-super');
    open(my $fh, '>', $real) or die "open $real: $!";
    close($fh);
    my $link = File::Spec->catfile($dir, 'linked-super');
    symlink($real, $link) or die "symlink $link: $!";
    config_dies_like(
        { 'nonraid-super' => $link, nodes => 'node-a' },
        1,
        qr/literal resolved spelling|symlink/,
        'symlinked super identity is rejected',
    );
}

config_dies_like(
    {
        'nonraid-super' => $super_path,
        nodes => 'node-a',
        format => 'raw',
    },
    1,
    qr/format must be qcow2/,
    'manual raw format is rejected',
);
config_dies_like(
    {
        'nonraid-super' => $super_path,
        nodes => 'node-a',
        preallocation => 'off',
    },
    1,
    qr/preallocation must be falloc/,
    'manual weak preallocation is rejected',
);

{
    local $PVE::Storage::CONFIG = {
        ids => {
            existing => { type => 'nonraid', nodes => { 'node-a' => 1 } },
            directory => { type => 'dir', nodes => { 'node-a' => 1 } },
        },
    };
    local $PVE::Storage::CONFIG_READS = 0;
    my $ok = eval {
        $plugin->on_add_hook(
            'new',
            { type => 'nonraid', 'nonraid-super' => $super_path, nodes => { 'node-a' => 1 } },
        );
        1;
    };
    ok(!$ok, 'second nonraid section on the same node is rejected');
    like($@, qr/already owns node 'node-a'/, 'duplicate add identifies the owner and node');
    is($PVE::Storage::CONFIG_READS, 1, 'add hook reads current cluster storage config');
}

{
    local $PVE::Storage::CONFIG = {
        ids => {
            existing => { type => 'nonraid', nodes => { 'node-a' => 1 } },
            directory => { type => 'dir', nodes => { 'node-b' => 1 } },
        },
    };
    my $ok = eval {
        $plugin->on_add_hook(
            'new',
            { type => 'nonraid', 'nonraid-super' => $super_path, nodes => { 'node-b' => 1 } },
        );
        1;
    };
    ok($ok, 'different node and non-nonraid overlap are accepted');
}

{
    local $PVE::Storage::CONFIG = {
        ids => {
            current => {
                type => 'nonraid',
                path => '/mnt/pve/current',
                'nonraid-super' => $super_path,
                nodes => { 'node-a' => 1 },
                format => 'qcow2',
                preallocation => 'falloc',
            },
            other => { type => 'nonraid', nodes => { 'node-b' => 1 } },
        },
    };
    local $PVE::Storage::CONFIG_READS = 0;
    my $ok = eval {
        $plugin->on_update_hook_full(
            'current',
            $PVE::Storage::CONFIG->{ids}->{current},
            { nodes => { 'node-b' => 1 } },
            [],
            {},
        );
        1;
    };
    ok(!$ok, 'update cannot move a section onto another nonraid owner');
    like($@, qr/already owns node 'node-b'/, 'duplicate update identifies the owner and node');
    is($PVE::Storage::CONFIG_READS, 1, 'update hook reads current cluster storage config');
}

{
    local $PVE::Storage::CONFIG = {
        ids => {
            current => {
                type => 'nonraid',
                path => '/mnt/pve/current',
                'nonraid-super' => $super_path,
                nodes => { 'node-a' => 1 },
                format => 'qcow2',
                preallocation => 'falloc',
            },
        },
    };
    local $PVE::Storage::CONFIG_READS = 0;
    my $ok = eval {
        $plugin->on_update_hook_full(
            'current',
            $PVE::Storage::CONFIG->{ids}->{current},
            { disable => 1 },
            undef,
            {},
        );
        1;
    };
    ok($ok, 'ordinary update accepts PVE missing-delete undef');
    is($@, '', 'ordinary update has no hidden delete-list error');
    is($PVE::Storage::CONFIG_READS, 1, 'ordinary update still checks current ownership');
}

done_testing();
