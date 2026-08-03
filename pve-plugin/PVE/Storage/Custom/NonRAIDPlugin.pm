package PVE::Storage::Custom::NonRAIDPlugin;

# Proxmox VE storage plugin: exposes a NonRAID array as directory-backed
# storage. On activation it starts the array (nmdctl), mounts the member
# disks and unions them into a mergerfs pool at the configured path.
#
# All array state is read from /proc/nmdstat directly (see docs/nmdstat.5);
# nmdctl output is never parsed, only its exit codes are used.

use strict;
use warnings;

use Cwd;
use File::Path qw(make_path);
use File::Spec;

use PVE::ProcFSTools;
use PVE::SafeSyslog;
use PVE::Tools qw(run_command);

# The parent must not be use'd: PVE::Storage loads every base plugin before
# scanning Custom/, and pulling DirPlugin in here creates a compile cycle
# through PVE::GuestImport::OVF. Because of this, `perl -c` on this file is a
# false negative; the real check is loading it through PVE::Storage.
use parent -norequire, 'PVE::Storage::DirPlugin';

our $VERSION = '0.1.0';

my $NMDCTL = '/usr/bin/nmdctl';
my $MERGERFS = '/usr/bin/mergerfs';
my $ARRAY_RUNNING_FILE = '/var/lib/nonraid/array.running';
my $HEALTH_DIR = '/run/pve-nonraid';

my $DEFAULT_SUPER = '/nonraid.dat';
my $DEFAULT_DISK_PREFIX = '/mnt/disk';

# Configuration

sub api {
    my $tested = 15;
    my ($apiver, $apiage) = eval { (PVE::Storage::APIVER(), PVE::Storage::APIAGE()) };
    return $tested if !defined($apiver); # standalone (unit tests)
    return $apiver if $apiver <= $tested;
    return $tested if $apiver - $apiage <= $tested;
    return 12;
}

sub type {
    return 'nonraid';
}

sub plugindata {
    return {
        content => [
            {
                images => 1,
                rootdir => 1,
                vztmpl => 1,
                iso => 1,
                backup => 1,
                snippets => 1,
                none => 1,
                import => 1,
            },
            { images => 1, rootdir => 1 },
        ],
        # qcow2 default: the array has no snapshot layer of its own, so qcow2
        # is the only way to get VM snapshots.
        format => [{ raw => 1, qcow2 => 1, vmdk => 1 }, 'qcow2'],
        'sensitive-properties' => {},
    };
}

sub properties {
    return {
        'nonraid-super' => {
            description => "NonRAID superblock file (passed to nmdctl -s).",
            type => 'string',
            format => 'pve-storage-path',
            default => $DEFAULT_SUPER,
        },
        'nonraid-disk-prefix' => {
            description => "Mount prefix for array member disks;"
                . " data slot N is mounted at <prefix>N.",
            type => 'string',
            format => 'pve-storage-path',
            default => $DEFAULT_DISK_PREFIX,
        },
        'nonraid-degraded-autostart' => {
            description => "Start the array even when it is degraded"
                . " (a disk is disabled or being reconstructed).",
            type => 'boolean',
            default => 1,
        },
        'nonraid-mergerfs-opts' => {
            description => "Override the mergerfs mount options for the pool.",
            type => 'string',
        },
    };
}

sub options {
    return {
        path => { fixed => 1 },
        'nonraid-super' => { optional => 1 },
        'nonraid-disk-prefix' => { optional => 1 },
        'nonraid-degraded-autostart' => { optional => 1 },
        'nonraid-mergerfs-opts' => { optional => 1 },
        nodes => { optional => 1 },
        disable => { optional => 1 },
        content => { optional => 1 },
        'content-dirs' => { optional => 1 },
        format => { optional => 1 },
        'create-subdirs' => { optional => 1 },
        'prune-backups' => { optional => 1 },
        'max-protected-backups' => { optional => 1 },
        bwlimit => { optional => 1 },
        preallocation => { optional => 1 },
        'snapshot-as-volume-chain' => { optional => 1, fixed => 1 },
    };
}

sub check_config {
    my ($self, $sectionId, $config, $create, $skipSchemaCheck) = @_;

    $config->{path} = "/mnt/pve/$sectionId" if $create && !$config->{path};

    my $opts = $self->SUPER::check_config($sectionId, $config, $create, $skipSchemaCheck);

    # Validated on update too: a prefix accepted by 'pvesm set' but rejected by
    # 'pvesm add' would only surface later, as a mount failure during
    # activation.
    my $prefix = $opts->{'nonraid-disk-prefix'};
    die "nonraid-disk-prefix must be an absolute path without a trailing slash\n"
        if defined($prefix) && $prefix !~ m|^/.*[^/]$|;

    return $opts;
}

# Pure helpers (unit-tested; no PVE dependencies in their bodies)

sub parse_nmdstat_text {
    my ($text) = @_;
    my $st = {};
    for my $line (split(/\n/, $text // '')) {
        $st->{$1} = $2 if $line =~ /^([^=]+)=(.*)$/;
    }
    return $st;
}

# PROC_NMDSTAT is the same override seam nmdctl and its test suite use.
sub read_nmdstat {
    my $path = $ENV{PROC_NMDSTAT} // '/proc/nmdstat';
    open(my $fh, '<', $path) or return undef;
    my $text = do { local $/; <$fh> };
    close($fh);
    return parse_nmdstat_text($text);
}

# Data slots only: 0 is P and 29 is Q, neither carries a filesystem.
sub data_slots {
    my ($st) = @_;
    my @slots;
    for my $key (keys %$st) {
        next if $key !~ /^diskName\.(\d+)$/;
        my $slot = $1;
        next if $slot == 0 || $slot == 29;
        next if ($st->{$key} // '') eq '';
        next if nmdstat_num($st->{"diskSize.$slot"}) <= 0;
        push @slots, $slot;
    }
    my @sorted = sort { $a <=> $b } @slots;
    return @sorted;
}

sub mergerfs_branches {
    my ($st, $prefix) = @_;
    return map { $prefix . $_ } data_slots($st);
}

# cache.files=off keeps O_DIRECT working so qemu cache=none is usable;
# category.create=mfs keeps each image whole on one branch; moveonenospc
# migrates a growing image instead of failing the guest with ENOSPC.
# minfreespace must stay below the smallest branch or every create fails
# with ENOSPC (mergerfs's own 4G default bricks arrays of small disks);
# 1G is enough because images grow after creation and moveonenospc covers
# growth, not minfreespace.
sub default_mergerfs_opts {
    my ($storeid) = @_;
    return "cache.files=off,category.create=mfs,moveonenospc=true,"
        . "minfreespace=1G,fsname=nonraid-$storeid";
}

# Health signals for logging only. mdNumInvalid/mdNumDisabled are known to be
# bogus right after array creation until the module is reloaded, so nothing
# gates online/offline on them - that decision uses mdState alone.
# /proc/nmdstat can carry a key with an empty value ('mdNumDisabled='), which
# is defined - so '//' does not catch it and every numeric comparison warns,
# once per pvestatd cycle. data_slots guards for the same reason.
sub nmdstat_num {
    my ($v) = @_;
    return ($v // '') =~ /^\d+$/ ? $v + 0 : 0;
}

sub nmdstat_health {
    my ($st) = @_;
    my $state = $st->{mdState} // 'UNKNOWN';
    $state = 'UNKNOWN' if $state eq '';
    my $disabled = nmdstat_num($st->{mdNumDisabled});
    my $invalid = nmdstat_num($st->{mdNumInvalid});
    my $missing = nmdstat_num($st->{mdNumMissing});
    my $degraded = ($disabled > 0 || $invalid > 0 || $missing > 0) ? 1 : 0;
    my $rebuilding = nmdstat_num($st->{mdResync}) > 0 ? 1 : 0;

    my $pct;
    my $resync_size = nmdstat_num($st->{mdResyncSize});
    if ($rebuilding && $resync_size > 0) {
        $pct = sprintf("%.1f", 100 * nmdstat_num($st->{mdResyncPos}) / $resync_size);
    }

    # The summary must stay stable while a resync makes progress - it is the
    # transition-detection key, and including the percentage would produce a
    # syslog line every pvestatd cycle.
    my $summary = $state;
    $summary .= " DEGRADED(disabled=$disabled invalid=$invalid missing=$missing)"
        if $degraded;
    $summary .= " RESYNC:" . ($st->{mdResyncAction} // '?') if $rebuilding;

    return {
        state => $state,
        degraded => $degraded,
        rebuilding => $rebuilding,
        resync_pct => $pct,
        summary => $summary,
    };
}

# $degraded comes from nmdstat_health() AFTER the members are imported.
# It matters because a degraded array that was stopped reports plain STOPPED,
# not DISABLE_DISK - mdState alone cannot carry the fail-stop decision.
sub decide_start_action {
    my ($state, $autostart, $degraded) = @_;
    $state //= '';

    return { action => 'none' } if $state eq 'STARTED';

    if ($state eq 'DISABLE_DISK' || $state eq 'RECON_DISK') {
        return { action => 'start-degraded', assert => $state } if $autostart;
        return {
            action => 'die',
            msg => "array is in state $state and nonraid-degraded-autostart is disabled;"
                . " inspect with 'nmdctl status' and start manually with"
                . " 'nmdctl start " . lc($state) . "'\n",
        };
    }

    if ($state eq '' || $state eq 'STOPPED') {
        return { action => 'start' } if !$degraded;
        return { action => 'start-degraded' } if $autostart;
        return {
            action => 'die',
            msg => "array is degraded and nonraid-degraded-autostart is disabled;"
                . " inspect with 'nmdctl status' and start manually with 'nmdctl start'\n",
        };
    }

    # NEW_ARRAY, SWAP_DSBL, ERROR:* - all require an operator ceremony that a
    # storage plugin must never perform on its own.
    return {
        action => 'die',
        msg => "array state '$state' requires operator action;"
            . " see 'nmdctl status' and the NonRAID manual-management docs\n",
    };
}

# Orchestration
#
# These are package subs rather than lexical ones purely so the unit tests can
# reach them; the leading underscore marks them private. They are the layer
# that builds argv and issues commands, which is exactly the layer worth
# asserting on.

sub _scfg_super {
    my ($scfg) = @_;
    return $scfg->{'nonraid-super'} // $DEFAULT_SUPER;
}

sub _scfg_disk_prefix {
    my ($scfg) = @_;
    return $scfg->{'nonraid-disk-prefix'} // $DEFAULT_DISK_PREFIX;
}

sub _pool_fsname {
    my ($storeid) = @_;
    return "nonraid-$storeid";
}

# abs_path returns undef for a path that does not exist yet (a superblock the
# driver has not created), so fall back to lexical canonicalization.
sub canon_path {
    my ($p) = @_;
    return undef if !defined($p) || $p eq '';
    my $real = eval { Cwd::abs_path($p) };
    return $real if defined($real) && $real ne '';
    return File::Spec->canonpath($p);
}

# The driver takes its superblock as a module parameter, so exactly one array
# is loaded per node. A storage configured for a different superblock must
# refuse rather than serve whichever array happens to be running: the members,
# and therefore the data, would be someone else's.
sub superblock_matches {
    my ($st, $super) = @_;
    my $live = $st->{sbName} // '';
    return 1 if $live eq ''; # driver reports none - nothing to contradict
    my $a = canon_path($live) // $live;
    my $b = canon_path($super) // $super;
    return $a eq $b ? 1 : 0;
}

# nmdctl mounts data slot N from /dev/nmd<N>p1, or from a device-mapper node
# carrying the same name for LUKS members.
sub member_source_ok {
    my ($source, $slot) = @_;
    return 0 if !defined($source);
    return 1 if $source =~ m{^/dev/nmd\Q$slot\E(p\d+)?$};
    return 1 if $source =~ m{^/dev/mapper/.*\bnmd\Q$slot\E\b};
    return 0;
}

sub mount_entry_for {
    my ($mountpoint, $mountdata) = @_;
    my $real = Cwd::realpath($mountpoint) // $mountpoint;
    my ($entry) = grep { $_->[1] eq $real || $_->[1] eq $mountpoint } @$mountdata;
    return $entry;
}

# "Is the pool at $path the one this storage mounted?" - not merely "is
# something mounted there". Used by the activation fast path and by status(),
# so a foreign filesystem at the path can never be served as array content.
sub pool_is_ours {
    my ($storeid, $scfg, $mountdata) = @_;
    my $entry = mount_entry_for($scfg->{path}, $mountdata)
        or return 0;
    return 0 if $entry->[2] ne 'fuse.mergerfs';
    return $entry->[0] eq _pool_fsname($storeid) ? 1 : 0;
}

sub _ensure_array_started {
    my ($storeid, $scfg, $st) = @_;

    my $super = _scfg_super($scfg);
    my $state = $st ? ($st->{mdState} // '') : '';

    if ($st) {
        die "a different NonRAID array is loaded (superblock '$st->{sbName}',"
            . " this storage is configured for '$super'); the driver holds one"
            . " array per node\n"
            if !superblock_matches($st, $super);
    }
    return 0 if $state eq 'STARTED';

    # Operator-only states are refused before importing anything: import
    # mutates member state, and the refusal promises that nothing was touched.
    my $autostart = $scfg->{'nonraid-degraded-autostart'} // 1;
    if ($state ne '' && $state ne 'STOPPED') {
        my $pre = decide_start_action($state, $autostart, $st ? nmdstat_health($st)->{degraded} : 0);
        die $pre->{msg} if $pre->{action} eq 'die';
    }

    # Import loads the module if needed, and only with members imported do the
    # degraded counters mean anything. Idempotent - imported slots are skipped.
    run_command(
        [$NMDCTL, '-u', '-s', $super, 'import'],
        timeout => 120,
        errmsg => "NonRAID disk import failed",
    );
    $st = read_nmdstat()
        or die "cannot read /proc/nmdstat after import - module did not load?\n";
    $state = $st->{mdState} // '';

    die "a different NonRAID array is loaded (superblock '$st->{sbName}',"
        . " this storage is configured for '$super')\n"
        if !superblock_matches($st, $super);

    my $health = nmdstat_health($st);
    my $decision = decide_start_action($state, $autostart, $health->{degraded});

    return 0 if $decision->{action} eq 'none';
    die $decision->{msg} if $decision->{action} eq 'die';

    my $cmd = [$NMDCTL, '-u', '-v', '-s', $super, 'start'];
    if ($decision->{action} eq 'start-degraded') {
        my $why = $decision->{assert} // "degraded ($health->{summary})";
        syslog('warning', "storage $storeid: NonRAID array is $why"
            . " - starting DEGRADED, redundancy is compromised");
        warn "WARNING: starting NonRAID array in degraded state\n";
        push @$cmd, $decision->{assert} if defined($decision->{assert});
    }
    run_command($cmd, timeout => 300, errmsg => "NonRAID array start failed");

    my $new = read_nmdstat();
    my $new_state = $new ? ($new->{mdState} // 'unknown') : 'unknown';
    die "array did not reach STARTED (state: $new_state)\n" if $new_state ne 'STARTED';
    return 1;
}

sub _ensure_members_mounted {
    my ($scfg) = @_;
    # Idempotent: nmdctl skips mounted slots, creates mountpoints, and handles
    # LUKS members and /etc/nonraid/fstab option overrides itself.
    run_command(
        [$NMDCTL, '-u', 'mount', _scfg_disk_prefix($scfg)],
        timeout => 120,
        errmsg => 'mounting NonRAID member disks failed',
    );
}

# The fsname is plugin-owned state, not decoration: pool_is_ours() and the
# teardown in pve-nonraid.service both identify pools by it. Appending it
# after any operator override means a custom option string cannot silently
# orphan the pool at shutdown (mergerfs takes the last occurrence).
sub build_mergerfs_opts {
    my ($storeid, $scfg) = @_;
    my $opts = $scfg->{'nonraid-mergerfs-opts'};
    return default_mergerfs_opts($storeid) if !defined($opts) || $opts eq '';
    return "$opts,fsname=" . _pool_fsname($storeid);
}

sub _ensure_pool_mounted {
    my ($storeid, $scfg) = @_;

    my $path = $scfg->{path};
    my $mountdata = PVE::ProcFSTools::parse_proc_mounts();

    if (my $entry = mount_entry_for($path, $mountdata)) {
        die "'$path' is already occupied by a foreign filesystem"
            . " ($entry->[0], type $entry->[2])\n"
            if $entry->[2] ne 'fuse.mergerfs';
        die "'$path' holds a mergerfs pool belonging to another storage"
            . " ($entry->[0])\n"
            if $entry->[0] ne _pool_fsname($storeid);
        return;
    }

    my $st = read_nmdstat()
        or die "cannot read /proc/nmdstat - is the md-nonraid module loaded?\n";

    # The branch list is derived from the live array, never from a glob: a
    # glob silently includes foreign directories under the prefix and, worse,
    # silently omits a member whose mount failed.
    my $prefix = _scfg_disk_prefix($scfg);
    my @slots = data_slots($st);
    die "array reports no data disks\n" if !@slots;

    my (@branches, @missing, @foreign);
    for my $slot (@slots) {
        my $branch = $prefix . $slot;
        push @branches, $branch;
        my $entry = mount_entry_for($branch, $mountdata);
        if (!$entry) {
            push @missing, $branch;
        } elsif (!member_source_ok($entry->[0], $slot)) {
            # Something other than the array's own member device is mounted
            # where slot N belongs - unioning it would take foreign data into
            # the pool and expose it as array content.
            push @foreign, "$branch ($entry->[0])";
        }
    }
    die "member disk(s) not mounted: @missing\n" if @missing;
    die "member mount(s) not backed by the array: @foreign\n" if @foreign;

    make_path($path);
    run_command(
        [$MERGERFS, '-o', build_mergerfs_opts($storeid, $scfg), join(':', @branches), $path],
        timeout => 60,
        errmsg => 'mergerfs pool mount failed',
    );

    # Member mounts are not re-checked per status() cycle on purpose: once the
    # pool is up mergerfs holds every branch busy, so a member cannot be
    # unmounted from under it, and the check would fork on pvestatd's path.
}

sub _post_start_bookkeeping {
    my ($storeid, $scfg, $started, $unclean) = @_;

    # Same handshake nonraid.service uses: a leftover state file means the
    # previous shutdown never tore the array down cleanly.
    if ($started && $unclean) {
        syslog('warning', "storage $storeid: unclean shutdown detected"
            . " - starting correcting parity check");
        eval {
            run_command(
                [$NMDCTL, '-u', '-s', _scfg_super($scfg), 'check', 'correct'],
                timeout => 60,
            );
        };
        warn "could not start parity check: $@" if $@;
    }

    # Written on every activation, not only the one that started the array: an
    # array brought up by hand still needs the marker, or a later crash looks
    # like a clean stop and parity is never re-checked. A failure here is
    # surfaced rather than swallowed for the same reason.
    make_path('/var/lib/nonraid');
    if (open(my $fh, '>', $ARRAY_RUNNING_FILE)) {
        close($fh);
    } else {
        syslog('warning', "storage $storeid: cannot write $ARRAY_RUNNING_FILE ($!)"
            . " - an unclean shutdown will not be detected");
        warn "could not write $ARRAY_RUNNING_FILE: $!\n";
    }

    # The unit's ExecStop is the ordered teardown (pools -> members -> array);
    # its ExecStart activates enabled storages for onboot guests. --no-block
    # is required, not cosmetic: when the unit itself is what triggered this
    # activation, a blocking start would wait on the job that is running us.
    eval {
        run_command(['/usr/bin/systemctl', 'start', '--no-block', 'pve-nonraid.service'],
            timeout => 15);
    };
    warn "could not start pve-nonraid.service: $@" if $@;
}

sub _log_health_transition {
    my ($storeid, $health) = @_;

    my $file = "$HEALTH_DIR/$storeid.health";
    my $prev = '';
    if (open(my $fh, '<', $file)) {
        $prev = <$fh> // '';
        chomp $prev;
        close($fh);
    }
    return if $prev eq $health->{summary};

    make_path($HEALTH_DIR);
    if (open(my $fh, '>', $file)) {
        print $fh "$health->{summary}\n";
        close($fh);
    }

    my $msg = "storage $storeid: array health changed:"
        . " '" . ($prev || 'unknown') . "' -> '$health->{summary}'";
    $msg .= " ($health->{resync_pct}%)" if defined($health->{resync_pct});
    syslog($health->{degraded} ? 'warning' : 'notice', $msg);
}

# Storage implementation

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $st = read_nmdstat();
    $cache->{mountdata} //= PVE::ProcFSTools::parse_proc_mounts();

    # Fast path: pvestatd activates every enabled storage on each cycle, so
    # the already-running case must not fork. "Up" means our array is running
    # and our pool - identified by fsname, not merely "something mounted
    # there" - is at the path; anything else takes the slow path, which
    # validates and fails loudly.
    my $up = $st
        && ($st->{mdState} // '') eq 'STARTED'
        && superblock_matches($st, _scfg_super($scfg))
        && pool_is_ours($storeid, $scfg, $cache->{mountdata});

    if (!$up) {
        PVE::Tools::lock_file("/run/lock/pve-nonraid-$storeid.lck", 10, sub {
            $st = read_nmdstat(); # re-check under the lock
            my $unclean = -e $ARRAY_RUNNING_FILE;
            my $started = _ensure_array_started($storeid, $scfg, $st);
            _ensure_members_mounted($scfg);
            _ensure_pool_mounted($storeid, $scfg);
            _post_start_bookkeeping($storeid, $scfg, $started, $unclean);
        });
        die "unable to activate storage '$storeid' - $@" if $@;
        $cache->{mountdata} = PVE::ProcFSTools::parse_proc_mounts();
    }

    return $class->SUPER::activate_storage($storeid, $scfg, $cache);
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $st = read_nmdstat();
    # undef = storage offline, not an error (the NFS-plugin idiom). A degraded
    # but STARTED array stays online - emulated reads are what parity is for;
    # degradation is surfaced through the transition log below.
    return undef if !$st || ($st->{mdState} // '') ne 'STARTED';
    return undef if !superblock_matches($st, _scfg_super($scfg));

    # Same identity test as the activation fast path: reporting df numbers for
    # a foreign filesystem that happens to sit at the path would be worse than
    # reporting the storage offline.
    $cache->{mountdata} //= PVE::ProcFSTools::parse_proc_mounts();
    return undef if !pool_is_ours($storeid, $scfg, $cache->{mountdata});

    _log_health_transition($storeid, nmdstat_health($st));

    return $class->SUPER::status($storeid, $scfg, $cache);
}

# deactivate_storage stays the inherited no-op on purpose: it fires per-guest
# with no refcounting, while the array and pool are node-global. Teardown
# belongs to pve-nonraid.service at shutdown, or to the operator.

1;
