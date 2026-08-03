#!/usr/bin/perl
# The systemd unit carries load-bearing behaviour that no Perl path can
# assert, so it is checked as configuration. These are not style rules: each
# one is a way the ordered teardown stops happening.
use strict;
use warnings;

use Test::More;
use FindBin;

my $unit_file = "$FindBin::Bin/../systemd/pve-nonraid.service";
open(my $fh, '<', $unit_file) or die "cannot read $unit_file: $!";
my $unit = do { local $/; <$fh> };
close($fh);

my ($exec_start) = $unit =~ /^ExecStart=(.*)$/m;
ok(defined($exec_start), 'the unit has an ExecStart');

# '-' turns a non-zero EXIT into success. It does NOT turn a systemd
# start-timeout into success: a unit whose ExecStart times out is failed, and
# a failed unit does not run ExecStop - so an array mounted moments earlier
# would silently lose its ordered teardown for the rest of the boot. The
# user-space bound is what guarantees ExecStart always exits on its own.
like($exec_start, qr/^-/, 'an activation failure does not fail the unit');
like($exec_start, qr{/timeout\s}, 'pvesm is bounded in user space, not only by systemd');
like($exec_start, qr{pvesm status}, 'and what it bounds is the activation call');

# -k is required, not optional: without it a pvesm that ignores SIGTERM is
# never killed and the bound is decorative. Both durations must be positive.
my ($kill_after, $bound) = $exec_start =~ m{/timeout\s+-k\s+(\d+)\s+(\d+)};
ok(defined($kill_after) && $kill_after > 0, 'timeout has a positive kill-after');
ok(defined($bound) && $bound > 0, 'the user-space bound is a positive number');

my ($start_timeout) = $unit =~ /^TimeoutStartSec=(\d+)$/m;
ok(defined($start_timeout), 'TimeoutStartSec is set, not left at systemd 90s default');

# The backstop has to outlast the FULL timeout sequence, not just its first
# phase: GNU timeout waits $bound, sends TERM, then waits another $kill_after
# before SIGKILL. Comparing against $bound alone leaves a window in which
# systemd fails the unit first - and a failed unit does not run ExecStop.
cmp_ok($bound + $kill_after, '<', $start_timeout,
    "timeout's full sequence (${bound}s + ${kill_after}s) fires before"
    . " TimeoutStartSec (${start_timeout}s)");

like($unit, qr/^ExecStop=.*pve-nonraid-teardown$/m, 'teardown is the ExecStop');
# Ordering alone would let pve-guests start while pvesm was still running;
# Type=oneshot is what makes Before= wait for ExecStart to finish.
like($unit, qr/^Type=oneshot$/m, 'guests wait for activation to complete');
like($unit, qr/^RemainAfterExit=yes$/m, 'oneshot stays active so ExecStop runs at shutdown');
like($unit, qr/^Before=pve-guests\.service$/m, 'guests stop before the storage goes away');

done_testing();
