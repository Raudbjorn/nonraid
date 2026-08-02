#!/usr/bin/perl
use strict;
use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/..";

use PVE::Storage::Custom::NonRAIDPlugin;

my $decide = \&{'PVE::Storage::Custom::NonRAIDPlugin::decide_start_action'};

is($decide->('STARTED', 1, 0)->{action}, 'none', 'STARTED: nothing to do');
is($decide->('STARTED', 0, 1)->{action}, 'none', 'STARTED: flags irrelevant');

is($decide->('STOPPED', 1, 0)->{action}, 'start', 'STOPPED clean: plain start');
is($decide->('', 1, 0)->{action}, 'start', 'module not loaded: plain start');
is($decide->(undef, 1, 0)->{action}, 'start', 'undef state: plain start');

# E2E-found: a degraded array that was stopped reports STOPPED, not
# DISABLE_DISK, so the fail-stop gate must consult the degraded flag or
# autostart=0 silently restarts a degraded array through the plain path.
{
    my $d = $decide->('STOPPED', 1, 1);
    is($d->{action}, 'start-degraded', 'STOPPED degraded + autostart: degraded start');
    is($d->{assert}, undef, 'STOPPED degraded: no state assertion (STOPPED is normal)');

    $d = $decide->('STOPPED', 0, 1);
    is($d->{action}, 'die', 'STOPPED degraded without autostart: refused');
    like($d->{msg}, qr/degraded/, 'refusal names the degradation');
    like($d->{msg}, qr/nmdctl start/, 'refusal names the manual command');
}

for my $state (qw(DISABLE_DISK RECON_DISK)) {
    my $d = $decide->($state, 1, 1);
    is($d->{action}, 'start-degraded', "$state + autostart: degraded start");
    is($d->{assert}, $state, "$state: expected-state assertion passed through");

    $d = $decide->($state, 0, 1);
    is($d->{action}, 'die', "$state without autostart: refused");
    like($d->{msg}, qr/nmdctl start \Q@{[lc $state]}\E/,
        "$state: refusal names the manual command");
}

for my $state (qw(NEW_ARRAY SWAP_DSBL ERROR:INVALID_EXPANSION ERROR:PARITY_NOT_BIGGEST)) {
    my $d = $decide->($state, 1, 0);
    is($d->{action}, 'die', "$state: always refused, even with autostart");
    like($d->{msg}, qr/operator action/, "$state: message points at the operator");
}

done_testing();
