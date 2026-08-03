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
# A live pool always has a mergerfs process holding it; the plugin reads the
# branch list out of that process rather than trusting a record of its own.
sub fake_mergerfs {
    my ($procdir, $pid, $fsname, $branches, $mp) = @_;
    mkdir "$procdir/$pid";
    open(my $c, '>', "$procdir/$pid/comm") or die $!;
    print {$c} "mergerfs\n";
    close($c);
    open(my $f, '>', "$procdir/$pid/cmdline") or die $!;
    print {$f} join("\0", '/usr/bin/mergerfs', '-o', "fsname=$fsname",
        $branches, $mp) . "\0";
    close($f);
    return $procdir;
}

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

# Our own pool already mounted, with the branches the array implies:
# idempotent, no second mount.
{
    reset_commands();
    my $pd = tempdir(CLEANUP => 1);
    fake_mergerfs($pd, 301, 'nonraid-nrpool', '/mnt/disk1:/mnt/disk2', $POOL);
    local $ENV{PVE_NONRAID_PROC} = $pd;
    local $PVE::ProcFSTools::mounts =
        [@{ member_mounts() }, ['nonraid-nrpool', $POOL, 'fuse.mergerfs']];
    with_fixture('nmdstat-started-clean.txt', sub {
        $P->can('_ensure_pool_mounted')->('nrpool', $scfg);
    });
    is_deeply(cmds(), [], 'already mounted: no-op');
}

# ---- pool identity --------------------------------------------------------

{
    my $pd = tempdir(CLEANUP => 1);
    fake_mergerfs($pd, 302, 'nonraid-nrpool', '/mnt/disk1:/mnt/disk2', $POOL);
    local $ENV{PVE_NONRAID_PROC} = $pd;
    my $st = with_fixture('nmdstat-started-clean.txt', sub {
        return $P->can('read_nmdstat')->();
    });

    my $ours = [['nonraid-nrpool', $POOL, 'fuse.mergerfs']];
    ok($P->can('pool_is_ours')->('nrpool', $scfg, $ours, $st), 'our pool recognised');
    ok(!$P->can('pool_is_ours')->('other', $scfg, $ours, $st),
        'fsname must match the storage id');
    ok(
        !$P->can('pool_is_ours')
            ->('nrpool', $scfg, [['/dev/sdz1', $POOL, 'ext4']], $st),
        'a foreign filesystem at the path is not our pool',
    );
    ok(!$P->can('pool_is_ours')->('nrpool', $scfg, [], $st),
        'nothing mounted is not our pool');
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

# ---- pool identity: observed branches, never assumed ----------------------
#
# fsname proves whose pool is mounted, not what is in it. The answer has to be
# read out of the running mergerfs process: recording what we INTENDED to
# mount cannot answer the question for a pool we did not mount, and adopting
# the expected set as the observed set certifies a guess as a fact.
{
    my $procdir = tempdir(CLEANUP => 1);
    local $ENV{PVE_NONRAID_PROC} = $procdir;

    my $st = with_fixture('nmdstat-started-clean.txt', sub {
        return $P->can('read_nmdstat')->();
    });
    my $ours = [['nonraid-nrpool', $POOL, 'fuse.mergerfs']];

    # Nothing running: the mount cannot be inspected, so it is not accepted.
    is($P->can('mounted_pool_branches')->('nrpool', $scfg), undef,
        'no mergerfs process means the branch set is unknown');
    ok(!$P->can('pool_is_ours')->('nrpool', $scfg, $ours, $st),
        'and an uninspectable pool is refused, not assumed fine');

    # The real thing, with the branches the live array implies.
    fake_mergerfs($procdir, 101, 'nonraid-nrpool', '/mnt/disk1:/mnt/disk2', $POOL);
    is_deeply($P->can('mounted_pool_branches')->('nrpool', $scfg),
        ['/mnt/disk1', '/mnt/disk2'], 'the branches are read from the process');
    ok($P->can('pool_is_ours')->('nrpool', $scfg, $ours, $st),
        'a pool whose branches match the array is ours');

    # A process for a DIFFERENT storage at a different path is not ours.
    fake_mergerfs($procdir, 102, 'nonraid-other', '/mnt/disk1:/mnt/disk2', '/mnt/pve/other');
    is_deeply($P->can('mounted_pool_branches')->('nrpool', $scfg),
        ['/mnt/disk1', '/mnt/disk2'], "another storage's pool is not confused for ours");

    # The array grew while the pool stayed up: the mount is now stale.
    my $grown = with_fixture('nmdstat-started-clean.txt', sub {
        my $x = $P->can('read_nmdstat')->();
        $x->{'diskName.3'} = 'nmd3p1';
        $x->{'diskSize.3'} = '1000000';
        return $x;
    });
    is($P->can('pool_branches_match')->('nrpool', $scfg, $grown), 0,
        'a pool missing a new member no longer matches');
    ok(!$P->can('pool_is_ours')->('nrpool', $scfg, $ours, $grown),
        'so the fast path refuses it');
}

{
    # The slow path must not silently accept what the fast path refused -
    # without this the refusal falls into the already-mounted early return.
    my $procdir = tempdir(CLEANUP => 1);
    local $ENV{PVE_NONRAID_PROC} = $procdir;
    fake_mergerfs($procdir, 201, 'nonraid-nrpool', '/mnt/disk1:/mnt/disk9', $POOL);

    reset_commands();
    local $PVE::ProcFSTools::mounts =
        [@{ member_mounts() }, ['nonraid-nrpool', $POOL, 'fuse.mergerfs']];
    my $err = '';
    with_fixture('nmdstat-started-clean.txt', sub {
        eval { $P->can('_ensure_pool_mounted')->('nrpool', $scfg) };
        $err = $@;
    });
    like($err, qr/built from a different set of members/,
        'the slow path refuses a stale pool instead of returning silently');
    like($err, qr{/mnt/disk9}, 'and names what is actually mounted');
    is_deeply(cmds(), [], 'nothing was mounted over the top of it');
}

{
    # A pool we cannot inspect at all: refuse with an actionable message
    # rather than serving it.
    my $procdir = tempdir(CLEANUP => 1);
    local $ENV{PVE_NONRAID_PROC} = $procdir;
    reset_commands();
    local $PVE::ProcFSTools::mounts =
        [@{ member_mounts() }, ['nonraid-nrpool', $POOL, 'fuse.mergerfs']];
    my $err = '';
    with_fixture('nmdstat-started-clean.txt', sub {
        eval { $P->can('_ensure_pool_mounted')->('nrpool', $scfg) };
        $err = $@;
    });
    like($err, qr/cannot inspect/, 'an uninspectable pool is refused');
    is_deeply(cmds(), [], 'and nothing is mounted over it');
}

# ---- the correction debt must not vanish -----------------------------------
# _record_correction_debt is now called BEFORE the array is started or the
# pool is mounted (see activate_storage), so a false return has to fail
# activation with nothing yet mutated - not merely warn once the array is
# already serving. A directory conflict, not chmod, blocks the write here: a
# permission bit is a no-op for root, which is exactly who runs this in the
# package's real DPKG_ROOT-free path, and the fast tier should catch this
# regression under either.
{
    my $bk = tempdir(CLEANUP => 1);
    open(my $blocker, '>', "$bk/blocker") or die $!;
    close($blocker); # a plain file where the marker's directory must go
    local $ENV{PVE_NONRAID_MARKER} = "$bk/blocker/array.running";

    reset_commands();
    my @warnings;
    my $ok = do {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        $P->can('_record_correction_debt')->('nrpool', 1);
    };
    ok(!$ok, 'an unrecordable correction debt reports failure');
    like(join('', @warnings), qr/correcting-check debt/, 'and says so');
    ok(!-e "$bk/blocker/array.running.correct-pending", 'no debt file was created');
    is_deeply(cmds(), [], 'and no check was silently skipped as if paid');

    # Retry once the obstruction is gone: the SAME debt, recorded on the next
    # activation attempt, the way pvestatd would actually retry it.
    unlink("$bk/blocker") or die $!;
    mkdir("$bk/blocker") or die $!;
    reset_commands();
    my $ok2 = $P->can('_record_correction_debt')->('nrpool', 1);
    ok($ok2, 'the retried call records the debt once the path is writable');
    ok(-e "$bk/blocker/array.running.correct-pending",
        'the pending file now exists, so _ensure_correction will pay it');
}

# Nothing to record: a clean shutdown ($unclean = 0) is always a no-op
# success, even against the same unwritable path above.
{
    my $bk = tempdir(CLEANUP => 1);
    open(my $blocker, '>', "$bk/blocker") or die $!;
    close($blocker);
    local $ENV{PVE_NONRAID_MARKER} = "$bk/blocker/array.running";
    my $ok = $P->can('_record_correction_debt')->('nrpool', 0);
    ok($ok, 'a clean shutdown records nothing and cannot fail on it');
}

# ---- nonraid-tools' own unit must stand aside ------------------------------
# A host upgraded from before the two units learned to coexist can still have
# nonraid.service active (ConditionPathExists only ever gated a future
# start). Reusing the "invocation:" liveness stat rather than forking
# systemctl keeps this cheap on every activation, not only the first.
{
    my $bk = tempdir(CLEANUP => 1);
    local $ENV{PVE_NONRAID_SYSTEMD_UNITS} = "$bk/units";
    mkdir "$bk/units";
    symlink('deadbeef', "$bk/units/invocation:nonraid.service") or die $!;

    reset_commands();
    my $err = '';
    eval { $P->can('_refuse_if_legacy_unit_active')->('nrpool') };
    $err = $@;
    like($err, qr/nonraid\.service/, 'refuses while the legacy unit is active');
    like($err, qr/disable --now nonraid\.service/, 'and says how to stop it');
    is_deeply(cmds(), [], 'nothing was issued before the refusal');
}

# The plugin's own unit being active does not trip this - only nonraid.service
# (nonraid-tools') does; they are two different invocation files.
{
    my $bk = tempdir(CLEANUP => 1);
    local $ENV{PVE_NONRAID_SYSTEMD_UNITS} = "$bk/units";
    mkdir "$bk/units";
    symlink('deadbeef', "$bk/units/invocation:pve-nonraid.service") or die $!;

    reset_commands();
    eval { $P->can('_refuse_if_legacy_unit_active')->('nrpool') };
    is($@, '', 'pve-nonraid.service being active does not refuse activation');
}

# Neither unit active: the ordinary case, no refusal.
{
    my $bk = tempdir(CLEANUP => 1);
    local $ENV{PVE_NONRAID_SYSTEMD_UNITS} = "$bk/units";
    mkdir "$bk/units";
    eval { $P->can('_refuse_if_legacy_unit_active')->('nrpool') };
    is($@, '', 'no legacy unit active: nothing to refuse');
}

done_testing();
