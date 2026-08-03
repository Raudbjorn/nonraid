#!/usr/bin/perl
# The command-issuing layer: what argv actually reaches nmdctl/mergerfs, and
# which situations refuse before touching anything. Everything here runs
# against the PVE stubs in t/lib and /proc/nmdstat fixtures - no array needed.
use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/..";

use PVE::Tools;
use PVE::ProcFSTools;
use PVE::Storage::DirPlugin;  # stub: satisfies the -norequire parent for ->can()
use PVE::Storage::Custom::NonRAIDPlugin;

my $P = 'PVE::Storage::Custom::NonRAIDPlugin';
my $fixtures = "$FindBin::Bin/fixtures";

# _ensure_pool_mounted mkpaths the pool path before mounting, so it has to be
# somewhere this test may create.
my $tmp = tempdir(CLEANUP => 1);
my $POOL = "$tmp/nrpool";

sub with_fixture {
    my ($name, $code) = @_;
    local $ENV{PROC_NMDSTAT} = "$fixtures/$name";
    return $code->();
}

sub reset_commands {
    @PVE::Tools::run_command_log = ();
    $PVE::Tools::run_command_hook = undef;
}

# The nmdctl capability probe is filtered out: it fires at most once per boot
# and says nothing about the orchestration these assertions are about. It has
# its own coverage below.
sub cmds {
    return [grep { $_ !~ /nmdctl --version$/ }
        map { join(' ', @$_) } @PVE::Tools::run_command_log];
}

my $scfg = {
    path => $POOL,
    'nonraid-super' => '/nonraid.dat',
};

# ---- start policy -> argv -------------------------------------------------

# A stopped clean array: import first, then a plain start (no state assertion).
{
    reset_commands();
    local $PVE::Tools::run_command_hook = sub {
        my ($cmd) = @_;
        # after 'import' the array is up; after 'start' it is STARTED
        $ENV{PROC_NMDSTAT} = "$fixtures/nmdstat-started-clean.txt"
            if $cmd->[-1] eq 'start';
        return 0;
    };
    my $started = with_fixture('nmdstat-stopped.txt', sub {
        return $P->can('_ensure_array_started')->('nrpool', $scfg, $P->can('read_nmdstat')->());
    });
    is($started, 1, 'stopped clean array: reports it started the array');
    is_deeply(
        cmds(),
        [
            '/usr/bin/nmdctl -u -s /nonraid.dat import',
            '/usr/bin/nmdctl -u -v -s /nonraid.dat start',
        ],
        'stopped clean: import then plain start, superblock passed through',
    );
}

# DISABLE_DISK with autostart on: the expected-state assertion must be argv,
# because nmdctl -u refuses an abnormal-state start without it.
{
    reset_commands();
    local $PVE::Tools::run_command_hook = sub {
        my ($cmd) = @_;
        $ENV{PROC_NMDSTAT} = "$fixtures/nmdstat-started-degraded.txt"
            if grep { $_ eq 'DISABLE_DISK' } @$cmd;
        return 0;
    };
    my $warned = '';
    local $SIG{__WARN__} = sub { $warned .= $_[0] };
    with_fixture('nmdstat-disable-disk.txt', sub {
        $P->can('_ensure_array_started')->('nrpool', $scfg, $P->can('read_nmdstat')->());
    });
    like(
        cmds()->[-1],
        qr/start DISABLE_DISK$/,
        'degraded start asserts the expected state as the last argument',
    );
    like($warned, qr/degraded/i, 'degraded start warns into the task log');
}

# Operator-only states must refuse BEFORE import: import mutates member state,
# and the refusal promises nothing was touched.
{
    reset_commands();
    my $err = '';
    with_fixture('nmdstat-new-array.txt', sub {
        eval {
            $P->can('_ensure_array_started')->('nrpool', $scfg, $P->can('read_nmdstat')->());
        };
        $err = $@;
    });
    like($err, qr/operator action/, 'NEW_ARRAY refused');
    is_deeply(cmds(), [], 'NEW_ARRAY: refused without running import');
}

# A different array being loaded must never be adopted.
{
    reset_commands();
    my $err = '';
    with_fixture('nmdstat-started-clean.txt', sub {
        eval {
            $P->can('_ensure_array_started')
                ->('nrpool', { %$scfg, 'nonraid-super' => '/srv/other.dat' },
                    $P->can('read_nmdstat')->());
        };
        $err = $@;
    });
    like($err, qr/different NonRAID array/, 'foreign superblock refused');
    is_deeply(cmds(), [], 'foreign superblock: nothing issued');
}

# ---- member mounting ------------------------------------------------------

{
    reset_commands();
    $P->can('_ensure_members_mounted')->({ %$scfg, 'nonraid-disk-prefix' => '/mnt/d' });
    is_deeply(cmds(), ['/usr/bin/nmdctl -u mount /mnt/d'], 'mount passes the prefix');

    reset_commands();
    $P->can('_ensure_members_mounted')->($scfg);
    is_deeply(cmds(), ['/usr/bin/nmdctl -u mount /mnt/disk'], 'mount defaults the prefix');
}

# ---- pool mounting --------------------------------------------------------

# /proc/mounts entries are [device, mountpoint, fstype, ...].
sub member_mounts {
    return [
        ['/dev/nmd1p1', '/mnt/disk1', 'xfs'],
        ['/dev/nmd2p1', '/mnt/disk2', 'xfs'],
    ];
}

{
    reset_commands();
    local $PVE::ProcFSTools::mounts = member_mounts();
    with_fixture('nmdstat-started-clean.txt', sub {
        $P->can('_ensure_pool_mounted')->('nrpool', $scfg);
    });
    is_deeply(
        cmds(),
        ['/usr/bin/mergerfs -o cache.files=off,category.create=mfs,moveonenospc=true,'
            . "minfreespace=1G,fsname=nonraid-nrpool /mnt/disk1:/mnt/disk2 $POOL"],
        'pool mount: branches from the live array, defaults carry the fsname',
    );
}

# An operator override must not be able to drop the fsname: the shutdown unit
# and the activation fast path both identify the pool by it.
{
    reset_commands();
    local $PVE::ProcFSTools::mounts = member_mounts();
    with_fixture('nmdstat-started-clean.txt', sub {
        $P->can('_ensure_pool_mounted')
            ->('nrpool', { %$scfg, 'nonraid-mergerfs-opts' => 'cache.files=partial' });
    });
    like(cmds()->[0], qr/-o cache\.files=partial,fsname=nonraid-nrpool /,
        'custom options keep the identifying fsname appended');
}

{
    reset_commands();
    local $PVE::ProcFSTools::mounts = [['/dev/nmd1p1', '/mnt/disk1', 'xfs']];
    my $err = '';
    with_fixture('nmdstat-started-clean.txt', sub {
        eval { $P->can('_ensure_pool_mounted')->('nrpool', $scfg) };
        $err = $@;
    });
    like($err, qr{member disk\(s\) not mounted: /mnt/disk2}, 'missing member refused');
    is_deeply(cmds(), [], 'missing member: no mergerfs invocation');
}

# A foreign filesystem mounted where a member belongs must not be unioned in.
{
    reset_commands();
    local $PVE::ProcFSTools::mounts = [
        ['/dev/nmd1p1', '/mnt/disk1', 'xfs'],
        ['/dev/sdz1', '/mnt/disk2', 'ext4'],
    ];
    my $err = '';
    with_fixture('nmdstat-started-clean.txt', sub {
        eval { $P->can('_ensure_pool_mounted')->('nrpool', $scfg) };
        $err = $@;
    });
    like($err, qr{not backed by the array.*/dev/sdz1}, 'foreign member mount refused');
    is_deeply(cmds(), [], 'foreign member: no mergerfs invocation');
}

# Foreign filesystem at the pool path itself.
{
    reset_commands();
    local $PVE::ProcFSTools::mounts =
        [@{ member_mounts() }, ['/dev/sdz1', $POOL, 'ext4']];
    my $err = '';
    with_fixture('nmdstat-started-clean.txt', sub {
        eval { $P->can('_ensure_pool_mounted')->('nrpool', $scfg) };
        $err = $@;
    });
    like($err, qr/occupied by a foreign filesystem/, 'foreign fs at the path refused');
    is_deeply(cmds(), [], 'foreign fs at path: no mergerfs invocation');
}

# Another storage's mergerfs pool at our path is equally not ours.
{
    reset_commands();
    local $PVE::ProcFSTools::mounts =
        [@{ member_mounts() }, ['nonraid-other', $POOL, 'fuse.mergerfs']];
    my $err = '';
    with_fixture('nmdstat-started-clean.txt', sub {
        eval { $P->can('_ensure_pool_mounted')->('nrpool', $scfg) };
        $err = $@;
    });
    like($err, qr/belonging to another storage/, "another storage's pool refused");
}

# Our own pool already mounted: idempotent, no second mount.
{
    reset_commands();
    local $PVE::ProcFSTools::mounts =
        [@{ member_mounts() }, ['nonraid-nrpool', $POOL, 'fuse.mergerfs']];
    with_fixture('nmdstat-started-clean.txt', sub {
        $P->can('_ensure_pool_mounted')->('nrpool', $scfg);
    });
    is_deeply(cmds(), [], 'already mounted: no-op');
}

# ---- pool identity --------------------------------------------------------

{
    my $ours = [['nonraid-nrpool', $POOL, 'fuse.mergerfs']];
    ok($P->can('pool_is_ours')->('nrpool', $scfg, $ours), 'our pool recognised');
    ok(!$P->can('pool_is_ours')->('other', $scfg, $ours), 'fsname must match the storage id');
    ok(
        !$P->can('pool_is_ours')
            ->('nrpool', $scfg, [['/dev/sdz1', $POOL, 'ext4']]),
        'a foreign filesystem at the path is not our pool',
    );
    ok(!$P->can('pool_is_ours')->('nrpool', $scfg, []), 'nothing mounted is not our pool');
}

# ---- bookkeeping: independently retryable ---------------------------------
#
# Marker and unit registration are separate steps because they fail separately,
# and the fast path retries whichever is missing - without that, one transient
# failure (a full /var, systemd busy for a moment) would persist for as long as
# the array stayed up, since every later activation short-circuits before
# reaching them.

{
    my $bk = tempdir(CLEANUP => 1);
    local $ENV{PVE_NONRAID_RUN_DIR} = "$bk/run";
    local $ENV{PVE_NONRAID_MARKER} = "$bk/var/array.running";
    local $ENV{PVE_NONRAID_SYSTEMD_UNITS} = "$bk/units";

    reset_commands();
    ok($P->can('_ensure_marker')->('nrpool'), 'the marker is created');
    ok(-e "$bk/var/array.running", 'and it is where it says it is');

    # Unit not running: systemd has no invocation record for it.
    reset_commands();
    ok($P->can('_ensure_unit_registered')->('nrpool'), 'unit registration succeeds');
    like(
        join(' ', @{ cmds() }),
        qr{systemctl start --no-block pve-nonraid\.service},
        'systemctl start is issued with --no-block',
    );

    # Unit running: systemd's invocation symlink is what proves it, so the
    # settled state costs stats rather than a fork.
    mkdir "$bk/units";
    symlink('deadbeef', "$bk/units/invocation:pve-nonraid.service") or die $!;
    reset_commands();
    $P->can('_ensure_bookkeeping')->('nrpool');
    is_deeply(cmds(), [], 'settled state costs stats, not a fork');

    # THE case a stamp could not express: an operator stops the unit by hand.
    # A stamp would still be there and the teardown would stay unregistered
    # for the rest of the boot; the invocation record is gone, so the next
    # cycle re-registers it.
    unlink "$bk/units/invocation:pve-nonraid.service";
    reset_commands();
    $P->can('_ensure_bookkeeping')->('nrpool');
    like(
        join(' ', @{ cmds() }),
        qr{systemctl start --no-block pve-nonraid\.service},
        'a manually stopped unit is re-registered on the next activation',
    );
}

{
    # A failed registration must be reported so the next activation retries.
    my $bk = tempdir(CLEANUP => 1);
    local $ENV{PVE_NONRAID_RUN_DIR} = "$bk/run";
    local $ENV{PVE_NONRAID_MARKER} = "$bk/var/array.running";
    local $ENV{PVE_NONRAID_SYSTEMD_UNITS} = "$bk/units";

    reset_commands();
    $PVE::Tools::run_command_hook = sub { die "systemd is busy\n" };
    my @warnings;
    my $ok = do {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        $P->can('_ensure_unit_registered')->('nrpool');
    };
    ok(!$ok, 'a failed unit start is reported, not swallowed');
    like(join('', @warnings), qr/pve-nonraid\.service/, 'and it is warned about');

    reset_commands();
    ok($P->can('_ensure_unit_registered')->('nrpool'), 'the retry goes through');
}

# ---- the correcting-parity debt is paid from BOTH paths -------------------
{
    my $bk = tempdir(CLEANUP => 1);
    local $ENV{PVE_NONRAID_RUN_DIR} = "$bk/run";
    local $ENV{PVE_NONRAID_MARKER} = "$bk/var/array.running";
    local $ENV{PVE_NONRAID_SYSTEMD_UNITS} = "$bk/units";
    mkdir "$bk/units";
    symlink('deadbeef', "$bk/units/invocation:pve-nonraid.service") or die $!;
    mkdir "$bk/var";

    # A debt recorded earlier, with the array already up: the slow path will
    # never run again, so the fast path has to be what pays it.
    open(my $fh, '>', "$bk/var/array.running.correct-pending") or die $!;
    close($fh);

    reset_commands();
    $P->can('_ensure_bookkeeping')->('nrpool', $scfg);
    like(join(' ', @{ cmds() }), qr/check correct/,
        'a pending correction is started from the fast path');
    ok(!-e "$bk/var/array.running.correct-pending",
        'and the debt is cleared once the check starts');

    # A check that cannot be started stays owed.
    open($fh, '>', "$bk/var/array.running.correct-pending") or die $!;
    close($fh);
    reset_commands();
    $PVE::Tools::run_command_hook = sub { die "driver busy\n" };
    do {
        local $SIG{__WARN__} = sub { };
        $P->can('_ensure_bookkeeping')->('nrpool', $scfg);
    };
    ok(-e "$bk/var/array.running.correct-pending",
        'a check that would not start is still owed');
}

{
    # An unwritable marker directory is surfaced and retried, never silently
    # accepted: a missing marker makes the next crash look like a clean stop.
    my $bk = tempdir(CLEANUP => 1);
    local $ENV{PVE_NONRAID_RUN_DIR} = "$bk/run";
    local $ENV{PVE_NONRAID_MARKER} = "$bk/blocked/array.running";
    open(my $fh, '>', "$bk/blocked") or die $!; # a file where a directory belongs
    close($fh);

    my @warnings;
    my $ok = do {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        $P->can('_ensure_marker')->('nrpool');
    };
    ok(!$ok, 'an unwritable marker path is a failure');
    like(join('', @warnings), qr/could not write/, 'and it says so');
}

# ---- refusal backoff ------------------------------------------------------
#
# A STOPPED array's degradedness is only knowable after an import, so refusing
# one costs an import - and the array stays STOPPED, so pvestatd would pay it
# again every cycle forever.

{
    my $bk = tempdir(CLEANUP => 1);
    local $ENV{PVE_NONRAID_RUN_DIR} = "$bk/run";
    local $ENV{PVE_NONRAID_MARKER} = "$bk/var/array.running";
    my $degraded = { path => $POOL, 'nonraid-super' => '/nonraid.dat',
        'nonraid-degraded-autostart' => 0 };

    reset_commands();
    my $err = '';
    with_fixture('nmdstat-stopped-degraded.txt', sub {
        eval { $P->can('_ensure_array_started')->('nrpool', $degraded, $P->can('read_nmdstat')->()) };
        $err = $@;
    });
    like($err, qr/degraded/, 'a degraded STOPPED array with autostart off is refused');
    like(join(' ', @{ cmds() }), qr/import/, 'the first refusal did cost an import');

    reset_commands();
    my $again = '';
    with_fixture('nmdstat-stopped-degraded.txt', sub {
        eval { $P->can('_ensure_array_started')->('nrpool', $degraded, $P->can('read_nmdstat')->()) };
        $again = $@;
    });
    is($again, $err, 'the cached refusal is the same refusal');
    is_deeply(cmds(), [], 'and the second cycle imports nothing');

    # Clearing it is what lets a repaired array start again without waiting out
    # the backoff.
    $P->can('_clear_refusal')->('nrpool');
    reset_commands();
    with_fixture('nmdstat-stopped-degraded.txt', sub {
        eval { $P->can('_ensure_array_started')->('nrpool', $degraded, $P->can('read_nmdstat')->()) };
    });
    like(join(' ', @{ cmds() }), qr/import/, 'once cleared, it tries again');
}

# ---- nmdctl capability probe ----------------------------------------------

{
    my $ok = $P->can('nmdctl_version_ok');
    is($ok->('nmdctl version 1.23.0'), 1, '1.23.0 is new enough');
    is($ok->('nmdctl version 1.23'), 1, 'a two-component 1.23 is new enough');
    is($ok->('nmdctl version 2.0.0'), 1, 'a newer major is new enough');
    is($ok->('nmdctl version 1.22.9'), 0, '1.22.9 is refused');
    # The bound that a dpkg version comparison gets wrong: dpkg orders 1.4.0
    # ABOVE 1.23, which is why this is checked numerically instead.
    is($ok->('nmdctl version 1.4.0'), 0, '1.4.0 is older than 1.23, not newer');
    is($ok->('a fork with its own banner'), undef, 'unparseable is not a verdict');
}

{
    my $bk = tempdir(CLEANUP => 1);
    local $ENV{PVE_NONRAID_RUN_DIR} = "$bk/run";
    local $ENV{PVE_NONRAID_MARKER} = "$bk/var/array.running";

    reset_commands();
    $PVE::Tools::run_command_hook = sub {
        my ($cmd, %param) = @_;
        $param{outfunc}->('nmdctl version 1.22.0') if $param{outfunc};
        return 0;
    };
    my $err = '';
    with_fixture('nmdstat-stopped.txt', sub {
        eval { $P->can('_ensure_array_started')->('nrpool', $scfg, $P->can('read_nmdstat')->()) };
        $err = $@;
    });
    like($err, qr/nonraid-tools is too old/, 'an old nmdctl is refused');
    is_deeply(cmds(), [], 'and nothing else was issued');
    ok(!-e "$bk/run/nmdctl-checked", 'a failed probe is not stamped as passed');
}

# ---- pool identity: the branch manifest ------------------------------------
#
# fsname proves WHOSE pool is mounted, not what is in it. A pool mounted
# before a slot changed keeps its fsname and would sail through the fast path
# unioning a stale member set.
{
    my $bk = tempdir(CLEANUP => 1);
    local $ENV{PVE_NONRAID_RUN_DIR} = "$bk/run";
    my $ours = [['nonraid-nrpool', $POOL, 'fuse.mergerfs']];

    my $st = with_fixture('nmdstat-started-clean.txt', sub {
        return $P->can('read_nmdstat')->();
    });

    # No manifest yet (a pool that predates this check): adopt, do not remount.
    ok($P->can('pool_is_ours')->('nrpool', $scfg, $ours, $st),
        'a pool with no manifest is adopted rather than refused');
    ok(-e "$bk/run/pool-nrpool.branches", 'and the live branch set is recorded');

    # Recorded and unchanged: still ours.
    is($P->can('pool_manifest_matches')->('nrpool', $scfg, $st), 1,
        'the adopted manifest matches the array it was taken from');
    ok($P->can('pool_is_ours')->('nrpool', $scfg, $ours, $st),
        'and the fast path still accepts it');

    # The array gains a slot while the pool stays mounted.
    my $grown = with_fixture('nmdstat-started-clean.txt', sub {
        my $x = $P->can('read_nmdstat')->();
        $x->{'diskName.3'} = 'nmd3p1';
        $x->{'diskSize.3'} = '1000000';
        return $x;
    });
    is($P->can('pool_manifest_matches')->('nrpool', $scfg, $grown), 0,
        'a changed slot set no longer matches the manifest');
    ok(!$P->can('pool_is_ours')->('nrpool', $scfg, $ours, $grown),
        'so the fast path refuses the stale pool');
}

{
    # And the slow path must not silently accept it either - without this the
    # refusal above would fall into the already-mounted early return.
    my $bk = tempdir(CLEANUP => 1);
    local $ENV{PVE_NONRAID_RUN_DIR} = "$bk/run";
    mkdir "$bk/run";
    open(my $fh, '>', "$bk/run/pool-nrpool.branches") or die $!;
    # A pool built when slot 9 existed and slot 2 did not. The clean fixture's
    # live array is slots 1+2, so this manifest is genuinely stale.
    print {$fh} "/mnt/disk1\n/mnt/disk9\n";
    close($fh);

    reset_commands();
    local $PVE::ProcFSTools::mounts =
        [@{ member_mounts() }, ['nonraid-nrpool', $POOL, 'fuse.mergerfs']];
    my $err = '';
    # ...against a fixture whose live array has different members.
    with_fixture('nmdstat-started-clean.txt', sub {
        eval { $P->can('_ensure_pool_mounted')->('nrpool', $scfg) };
        $err = $@;
    });
    like($err, qr/built from a different set of members/,
        'the slow path refuses a stale pool instead of returning silently');
    like($err, qr/systemctl stop pve-nonraid/, 'and names how to clear it');
    is_deeply(cmds(), [], 'nothing was mounted over the top of it');
}

done_testing();
