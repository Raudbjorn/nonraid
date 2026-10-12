#!/usr/bin/perl
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright 2026 Sveinbjörn Geirsson

use strict;
use warnings;

use FindBin;
use IPC::Open3;
use Symbol qw(gensym);
use Test::More;

use lib "$FindBin::Bin/lib", "$FindBin::Bin/..";
use PVE::Storage;

sub run_loader {
    my ($apiver, $apiage) = @_;
    local $ENV{PVE_TEST_APIVER} = $apiver;
    local $ENV{PVE_TEST_APIAGE} = $apiage;

    my $stderr = gensym;
    my $pid = open3(
        undef,
        my $stdout,
        $stderr,
        $^X,
        '-I', "$FindBin::Bin/lib",
        '-I', "$FindBin::Bin/..",
        '-MPVE::Storage',
        '-e',
        'my $plugin = PVE::Storage::Plugin->lookup("nonraid");'
            . ' print "core=", PVE::Storage::APIVER(),'
            . ' " plugin=", ($plugin // "absent"), "\\n";',
    );
    my $out = do { local $/; <$stdout> };
    my $err = do { local $/; <$stderr> };
    waitpid($pid, 0);
    return ($? >> 8, $out, $err);
}

my $plugin = PVE::Storage::Plugin->lookup('nonraid');
ok(defined($plugin), 'PVE::Storage registers nonraid through its custom loader');

SKIP: {
    skip 'custom plugin did not register', 13 if !defined($plugin);

    is($plugin, 'PVE::Storage::Custom::NonRAIDPlugin', 'registered class is exact');
    is($plugin->api(), 15, 'plugin accepts the live tested API exactly');
    is($plugin->type(), 'nonraid', 'storage type is explicit');
    is($plugin->VERSION(), '0.1.0', 'plugin version is explicit');

    my $properties = $plugin->properties();
    is_deeply(
        [sort keys %{$properties}],
        [qw(nonraid-degraded-autostart nonraid-super)],
        'only globally unique NonRAID properties are declared',
    );
    is($properties->{'nonraid-super'}->{type}, 'string', 'superblock identity is a string');
    is($properties->{'nonraid-super'}->{format}, 'pve-storage-path', 'superblock identity is absolute-path formatted');
    is($properties->{'nonraid-degraded-autostart'}->{type}, 'boolean', 'degraded consent is boolean');
    is($properties->{'nonraid-degraded-autostart'}->{default}, 0, 'degraded autostart defaults off');

    is_deeply(
        $plugin->options(),
        {
            path => { fixed => 1 },
            'nonraid-super' => {},
            'nonraid-degraded-autostart' => { optional => 1 },
            nodes => {},
            disable => { optional => 1 },
            content => { optional => 1 },
            format => { fixed => 1 },
            preallocation => { fixed => 1 },
            'prune-backups' => { optional => 1 },
            'max-protected-backups' => { optional => 1 },
        },
        'options are a complete narrow local-only map',
    );

    is_deeply(
        $plugin->plugindata(),
        {
            content => [{ images => 1, backup => 1 }, { images => 1 }],
            format => [{ qcow2 => 1 }, 'qcow2'],
            'sensitive-properties' => {},
        },
        'plugin advertises exactly images, backup, and qcow2',
    );

    {
        package PVE::Storage::Custom::NonRAIDPropertyCollision;
        our @ISA = ('PVE::Storage::DirPlugin');
        sub type { return 'nonraid-collision'; }
        sub properties { return { 'nonraid-super' => { type => 'string' } }; }
    }
    my $registered = eval {
        PVE::Storage::Custom::NonRAIDPropertyCollision->register();
        1;
    };
    ok(!$registered, 'global property name cannot be registered twice');
    like($@, qr/property 'nonraid-super' is already registered/, 'property collision is explicit');
}

{
    my ($exit, $out, $err) = run_loader(15, 6);
    is($exit, 0, 'tested API loader exits cleanly');
    like($out, qr/^core=15 plugin=PVE::Storage::Custom::NonRAIDPlugin$/m, 'tested API registers plugin');
    is($err, '', 'tested API emits no custom-loader warning');
}

{
    my ($exit, $out, $err) = run_loader(14, 6);
    is($exit, 0, 'older API mismatch does not kill core PVE::Storage');
    like($out, qr/^core=14 plugin=absent$/m, 'older API skips the custom plugin');
    like(
        $err,
        qr/live PVE Storage API 14.*APIAGE 6.*tested API is 15/,
        'older API warning names live and tested interfaces',
    );
}

{
    my ($exit, $out, $err) = run_loader(19, 8);
    is($exit, 0, 'future API mismatch does not kill core PVE::Storage');
    like($out, qr/^core=19 plugin=absent$/m, 'future API skips the custom plugin');
    like(
        $err,
        qr/live PVE Storage API 19.*APIAGE 8.*tested API is 15/,
        'future API warning names live and tested interfaces',
    );
}

done_testing();
