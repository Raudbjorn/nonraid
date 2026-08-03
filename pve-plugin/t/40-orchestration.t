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

sub cmds { return [map { join(' ', @$_) } @PVE::Tools::run_command_log]; }

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

    reset_commands();
    ok($P->can('_ensure_marker')->('nrpool'), 'the marker is created');
    ok(-e "$bk/var/array.running", 'and it is where it says it is');

    reset_commands();
    ok($P->can('_ensure_unit_registered')->('nrpool'), 'unit registration succeeds');
    like(
        join(' ', @{ cmds() }),
        qr{systemctl start --no-block pve-nonraid\.service},
        'systemctl start is issued with --no-block',
    );

    reset_commands();
    $P->can('_ensure_bookkeeping')->('nrpool');
    is_deeply(cmds(), [], 'settled state costs two stats, not a fork');
}

{
    # A failed registration must not leave the stamp behind: the retry on the
    # next activation is the entire point of recording it.
    my $bk = tempdir(CLEANUP => 1);
    local $ENV{PVE_NONRAID_RUN_DIR} = "$bk/run";
    local $ENV{PVE_NONRAID_MARKER} = "$bk/var/array.running";

    reset_commands();
    $PVE::Tools::run_command_hook = sub { die "systemd is busy\n" };
    my @warnings;
    my $ok = do {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        $P->can('_ensure_unit_registered')->('nrpool');
    };
    ok(!$ok, 'a failed unit start is reported, not swallowed');
    ok(!-e "$bk/run/unit-started", 'no stamp is left behind to suppress the retry');
    like(join('', @warnings), qr/pve-nonraid\.service/, 'and it is warned about');

    # Retry succeeds once systemd is willing.
    reset_commands();
    ok($P->can('_ensure_unit_registered')->('nrpool'), 'the retry goes through');
    ok(-e "$bk/run/unit-started", 'and now it is stamped');
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

done_testing();
