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

sub fixture_text {
    my ($name) = @_;
    open(my $fh, '<', "$fixtures/$name") or die "open fixture: $!";
    return do { local $/; <$fh> };
}

my $parse = $P->can('parse_nmdstat_text');
ok($parse, 'strict nmdstat parser is exposed for focused tests');


    my $clean = $parse->(fixture_text('nmdstat-started-clean.txt'));
    is($clean->{mdState}, 'STARTED', 'clean state parses');
    is_deeply([$P->can('data_slots')->($clean)], [1, 2], 'only ordered live data slots remain');

    my $empty = eval { $parse->(fixture_text('nmdstat-empty-values.txt')) };
    is($@, '', 'transient empty numeric values are tolerated');
    is_deeply([$P->can('data_slots')->($empty)], [1], 'empty member size drops the slot without warning');

    for my $case (
        ["mdState=STARTED\nmdState=STOPPED\n", qr/duplicate key/, 'duplicate key'],
        ["mdState STARTED\n", qr/malformed nmdstat line/, 'missing equals'],
        ["diskSize.1=abc\n", qr/nonnumeric.*diskSize\.1/, 'nonnumeric slot field'],
        ["mdNumInvalid=nope\n", qr/nonnumeric.*mdNumInvalid/, 'nonnumeric counter'],
        ["rdevSize.1=bad\n", qr/nonnumeric.*rdevSize\.1/, 'nonnumeric emitted device size'],
        ["rdevOffset.1=bad\n", qr/nonnumeric.*rdevOffset\.1/, 'nonnumeric emitted device offset'],
        ["rdevReads.1=bad\n", qr/nonnumeric.*rdevReads\.1/, 'nonnumeric emitted read counter'],
        ["rdevWrites.1=bad\n", qr/nonnumeric.*rdevWrites\.1/, 'nonnumeric emitted write counter'],
        ["rdevNumber.1=bad\n", qr/nonnumeric.*rdevNumber\.1/, 'nonnumeric emitted device number'],
        ["diskName.30=nmd30p1\n", qr/impossible slot 30/, 'slot above 29'],
    ) {
        my ($text, $pattern, $name) = @{$case};
        my $ok = eval { $parse->($text); 1 };
        ok(!$ok, "$name is rejected");
        like($@, $pattern, "$name reports its reason");
    }

    my $oversized = "mdState=" . ('X' x (65 * 1024));
    my $ok = eval { $parse->($oversized); 1 };
    ok(!$ok, 'oversized nmdstat is rejected');
    like($@, qr/exceeds 65536 bytes/, 'oversized input reports the fixed bound');

    for my $required (qw(diskId.1 rdevName.1)) {
        my %incomplete = %{$clean};
        delete $incomplete{$required};
        my $complete = eval { my @slots = $P->can('data_slots')->(\%incomplete); 1 };
        ok(!$complete, "live topology missing $required is rejected");
        like($@, qr/live slot 1.*\Q$required\E/, "missing $required reports the incomplete slot");
    }

    my $path = "$fixtures/nmdstat-started-clean.txt";
    local $PVE::Storage::Custom::NonRAIDPlugin::PROC_NMDSTAT_PATH = $path;
    local $ENV{PROC_NMDSTAT} = '/definitely/not/the/test-fixture';
    my $read = $P->can('read_nmdstat')->();
    is($read->{sbName}, '/nonraid.dat', 'package path seam controls the bounded read');

    my $fingerprint = $P->can('topology_fingerprint');
    my %reordered;
    $reordered{$_} = $clean->{$_} for reverse sort keys %{$clean};
    is($fingerprint->($clean), $fingerprint->(\%reordered), 'fingerprint ignores hash insertion order');
    my %wrong_super = (%{$clean}, sbName => '/other.dat');
    isnt($fingerprint->($clean), $fingerprint->(\%wrong_super), 'fingerprint binds the live superblock');
    my %wrong_member = (%{$clean}, 'diskId.2' => 'OTHER');
    isnt($fingerprint->($clean), $fingerprint->(\%wrong_member), 'fingerprint binds every ordered member tuple');
    like($fingerprint->($clean), qr/\A[0-9a-f]{64}\z/, 'fingerprint is SHA-256 hex');

    my $health = $P->can('nmdstat_health');
    my $fresh = $health->({ %{$clean}, mdNumDisabled => 1 });
    is($fresh->{degraded}, 1, 'fresh-array counter quirk remains advisory health data');
    is($fresh->{state}, 'STARTED', 'advisory counter does not rewrite live state');

    my $accepted_context = { accepted => 1, baseline_synced2 => 100 };
    my $accepted = $health->({ %{$clean}, mdResyncAction => 'check P' }, $accepted_context);
    is($accepted->{resync_state}, 'accepted', 'submitted idle operation remains accepted');
    my $running_a = $health->({ %{$clean}, mdResync => 100, mdResyncPos => 10, mdResyncSize => 100, mdResyncAction => 'check P' });
    my $running_b = $health->({ %{$clean}, mdResync => 100, mdResyncPos => 80, mdResyncSize => 100, mdResyncAction => 'check P' });
    is($running_a->{resync_state}, 'running', 'active resync is running');
    is($running_a->{transition_key}, $running_b->{transition_key}, 'progress percentage never enters transition key');
    isnt($running_a->{resync_pct}, $running_b->{resync_pct}, 'display progress may change independently');
    is($health->({ %{$clean}, mdResync => 0, mdResyncPos => 50, mdResyncSize => 100, mdResyncAction => 'check P' })->{resync_state}, 'paused', 'partial idle resync is paused');
    is(
        $health->(
            {
                %{$clean},
                mdResync => 0,
                mdResyncPos => 0,
                mdResyncSize => 100,
                mdResyncAction => 'check P',
                sbSynced2 => 101,
                sbSyncExit => 0,
            },
            $accepted_context,
        )->{resync_state},
        'completed',
        'advanced completion timestamp marks the real idle post-completion snapshot',
    );
    is(
        $health->(
            {
                %{$clean},
                mdResync => 0,
                mdResyncPos => 0,
                mdResyncSize => 100,
                mdResyncAction => 'check P',
                sbSyncExit => -5,
            },
            $accepted_context,
        )->{resync_state},
        'failed',
        'nonzero sync exit is failed',
    );

    my $stopped = $health->($parse->(fixture_text('nmdstat-stopped.txt')));
    is($stopped->{state}, 'STOPPED', 'stopped state passes through unchanged');
    like($stopped->{transition_key}, qr/\ASTOPPED\|/, 'stopped state participates in the transition key');
    is($health->({ mdState => '' })->{state}, 'UNKNOWN', 'empty state normalizes to UNKNOWN');
    is($health->({})->{state}, 'UNKNOWN', 'missing state normalizes to UNKNOWN');

done_testing();
