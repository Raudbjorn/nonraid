#!/usr/bin/perl
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright 2026 Sveinbjörn Geirsson

use strict;
use warnings;

use FindBin;
use Test::More;

use lib "$FindBin::Bin/lib", "$FindBin::Bin/..";
use PVE::Storage;

my $plugin = PVE::Storage::Plugin->lookup('nonraid');
BAIL_OUT('nonraid plugin did not register') if !defined($plugin);

my $config = {
    type => 'nonraid',
    path => '/mnt/pve/nrpool',
    format => 'qcow2',
    preallocation => 'falloc',
};

for my $feature (qw(snapshot clone template copy sparseinit rename resize unknown-feature)) {
    for my $snapname (undef, 'snap1') {
        for my $running (0, 1) {
            my $supported = $plugin->volume_has_feature(
                $config,
                $feature,
                'nrpool',
                '100/vm-100-disk-0.qcow2',
                $snapname,
                $running,
                { valid_target_formats => ['qcow2'] },
            );
            is(
                $supported,
                0,
                "$feature denied for "
                    . (defined($snapname) ? 'snapshot' : 'current')
                    . ($running ? ' running' : ' stopped'),
            );
        }
    }
}

done_testing();
