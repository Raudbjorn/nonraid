#!/usr/bin/perl
use strict;
use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/..";

use PVE::Storage::Custom::NonRAIDPlugin;

my $decide = \&{'PVE::Storage::Custom::NonRAIDPlugin::decide_start_action'};

is($decide->('STARTED', 1)->{action}, 'none', 'STARTED: nothing to do');
is($decide->('STARTED', 0)->{action}, 'none', 'STARTED: autostart flag irrelevant');

is($decide->('STOPPED', 1)->{action}, 'start', 'STOPPED: plain start');
is($decide->('', 1)->{action}, 'start', 'module not loaded: plain start (nmdctl modprobes)');
is($decide->(undef, 1)->{action}, 'start', 'undef state: plain start');

for my $state (qw(DISABLE_DISK RECON_DISK)) {
    my $d = $decide->($state, 1);
    is($d->{action}, 'start-degraded', "$state + autostart: degraded start");
    is($d->{assert}, $state, "$state: expected-state assertion passed through");

    $d = $decide->($state, 0);
    is($d->{action}, 'die', "$state without autostart: refused");
    like($d->{msg}, qr/nmdctl start \Q@{[lc $state]}\E/,
        "$state: refusal names the manual command");
}

for my $state (qw(NEW_ARRAY SWAP_DSBL ERROR:INVALID_EXPANSION ERROR:PARITY_NOT_BIGGEST)) {
    my $d = $decide->($state, 1);
    is($d->{action}, 'die', "$state: always refused, even with autostart");
    like($d->{msg}, qr/operator action/, "$state: message points at the operator");
}

done_testing();
