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
use JSON::PP;

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
        # Write-only actions, not state. PVE has no extension point for
        # per-plugin node actions, so these ride in on the storage create/update
        # hooks and are deleted before the config is written - they never
        # persist. Named 'create' because that is what they do to the disks.
        'nonraid-create-parity' => {
            description => "Build a NEW array on storage creation, using these"
                . " whole disks as parity (P, then Q). DESTROYS their contents."
                . " Refused if an array already exists.",
            type => 'string',
            format => 'string-list',
        },
        'nonraid-create-data' => {
            description => "Data disks for the array built by"
                . " nonraid-create-parity. DESTROYS their contents.",
            type => 'string',
            format => 'string-list',
        },
        'nonraid-wipe-disks' => {
            description => "Erase all filesystem and partition signatures on"
                . " these block devices. DESTROYS their contents. Refuses"
                . " members of the running array, mounted disks, and anything"
                . " held by LVM, ZFS, MD or Ceph.",
            type => 'string',
            format => 'string-list',
        },
        'nonraid-unmount-disks' => {
            description => "Unmount these block devices, so they can be wiped"
                . " and assigned. Refuses anything held by LVM, ZFS, MD or"
                . " Ceph, and any member of the running array.",
            type => 'string',
            format => 'string-list',
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
        'nonraid-create-parity' => { optional => 1 },
        'nonraid-create-data' => { optional => 1 },
        'nonraid-wipe-disks' => { optional => 1 },
        'nonraid-unmount-disks' => { optional => 1 },
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
# Mountpoints this must never unmount, whatever the operator asked for. The
# kernel refuses '/' because it is busy, but that is luck, not a guarantee: a
# quiet /boot/efi or /var would unmount cleanly and take the system with it.
sub system_mountpoint {
    my ($mp) = @_;
    return 0 if !defined($mp) || $mp eq '';
    return 1 if $mp eq '/';
    for my $dir (qw(/boot /usr /var /etc /proc /sys /dev /run /lib /bin /sbin)) {
        return 1 if $mp eq $dir || index($mp, "$dir/") == 0;
    }
    return 0;
}

# Disk assignment gate
#
# A disk may only be handed to 'nmdctl create'/'add' once nothing else claims
# it, because both commands write to it immediately. The rules are deliberately
# strict and stated as reasons rather than a boolean: the UI shows the reason,
# and the operator needs to know whether the answer is "unmount it", "wipe it"
# or "that is already in this array".
#
# Split pure/impure so the rules are testable against fixtures: this half takes
# a parsed lsblk entry plus /proc/nmdstat and returns why not, if not.
sub disk_blockers {
    my ($entry, $st) = @_;
    my @blockers;

    return ['device not found'] if !$entry;

    my $name = $entry->{name} // '';

    # Already a member of this array - the most important case to name
    # explicitly, or an operator could "wipe" a live member. Slot 0 is P and
    # 29 is Q; rdevName is the physical partition, so compare on its disk.
    if ($st) {
        for my $key (keys %$st) {
            next if $key !~ /^rdevName\.(\d+)$/;
            my $slot = $1;
            my $rdev = $st->{$key} // '';
            next if $rdev eq '';
            # rdevName is e.g. 'vde1'; strip the partition to get the disk.
            my $disk = $rdev;
            $disk =~ s/p?\d+$//;
            if ($disk eq $name || $rdev eq $name) {
                my $role = $slot == 0 ? 'parity P'
                    : $slot == 29 ? 'parity Q'
                    : "data slot $slot";
                push @blockers, "already in this array as $role";
                last;
            }
        }
    }

    push @blockers, "mounted at $entry->{mountpoint}"
        if defined($entry->{mountpoint}) && $entry->{mountpoint} ne '';
    push @blockers, "holds a $entry->{fstype} filesystem"
        if defined($entry->{fstype}) && $entry->{fstype} ne '';

    my @children = @{ $entry->{children} // [] };
    for my $child (@children) {
        my $ctype = $child->{type} // '';
        if (defined($child->{mountpoint}) && $child->{mountpoint} ne '') {
            push @blockers, "$child->{name} is mounted at $child->{mountpoint}";
        } elsif ($ctype ne 'part') {
            # A non-partition child is a holder: LVM, dm-crypt, MD, a Ceph OSD.
            # Undoing those is the business of the tool that made them.
            push @blockers, "$child->{name} ($ctype) holds it";
        }
    }
    my @parts = grep { ($_->{type} // '') eq 'part' } @children;
    push @blockers, scalar(@parts) . " partition(s)" if @parts;

    return \@blockers;
}

# 'nmdctl create'/'add' take slot:device:id. Build that from a validated set,
# so the argv is testable without touching a disk.
sub build_assign_specs {
    my ($parity, $data, $first_slot) = @_;
    my @specs;
    my @p = @{ $parity // [] };
    die "at most two parity disks (P and Q)\n" if scalar(@p) > 2;
    push @specs, "P:$p[0]" if defined $p[0];
    push @specs, "Q:$p[1]" if defined $p[1];
    my $slot = $first_slot // 1;
    for my $dev (@{ $data // [] }) {
        die "no free data slot left (1..28)\n" if $slot > 28;
        push @specs, "$slot:$dev";
        $slot++;
    }
    return @specs;
}

# Lowest unused data slot, so 'add' extends an array rather than overwriting.
sub next_free_slot {
    my ($st) = @_;
    my %used = map { $_ => 1 } data_slots($st);
    for my $slot (1 .. 28) {
        return $slot if !$used{$slot};
    }
    return undef;
}

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

# Disk actions
#
# These run from the storage create/update hooks, which hold the cluster-wide
# storage config lock - so everything here must return promptly. nmdctl create,
# start and check all return as soon as the driver accepts the command; the
# parity build then runs in the kernel. Nothing here waits for it.

sub _lsblk_entry {
    my ($dev) = @_;
    my $json = '';
    eval {
        run_command(
            ['/usr/bin/lsblk', '-J', '-o', 'NAME,TYPE,FSTYPE,MOUNTPOINT', $dev],
            timeout => 15,
            outfunc => sub { $json .= shift },
            errfunc => sub { },
        );
    };
    return undef if $@ || $json eq '';
    my $decoded = eval { JSON::PP::decode_json($json) };
    return undef if !$decoded;
    return $decoded->{blockdevices}->[0];
}

# Every device named by an action goes through the gate first, and the error
# lists every reason for every device rather than dying on the first - an
# operator fixing three disks should not have to discover them one at a time.
my sub require_assignable {
    my ($devs, $st) = @_;
    my @problems;
    for my $dev (@$devs) {
        die "'$dev' is not an absolute device path\n" if $dev !~ m{^/dev/[\w/-]+$};
        my $blockers = disk_blockers(_lsblk_entry($dev), $st);
        push @problems, "$dev: " . join(', ', @$blockers) if @$blockers;
    }
    die "refusing to touch these disks:\n  " . join("\n  ", @problems) . "\n"
        if @problems;
}

my sub unmount_disks {
    my ($storeid, $devs, $st) = @_;

    for my $dev (@$devs) {
        die "'$dev' is not an absolute device path\n" if $dev !~ m{^/dev/[\w/-]+$};
        my $entry = _lsblk_entry($dev)
            or die "'$dev': device not found\n";

        # Only unmounting. A holder - LVM, ZFS, MD, a Ceph OSD - is undone by
        # the tool that created it, and guessing at that from here is how an
        # unrelated pool gets destroyed.
        my @children = @{ $entry->{children} // [] };
        for my $child (@children) {
            my $ctype = $child->{type} // '';
            die "'$dev' is held by $child->{name} ($ctype); release it with the"
                . " tool that created it (LVM, ZFS, Ceph, mdadm) first\n"
                if $ctype ne 'part';
        }

        # An array member must never be unmounted this way: it would pull a
        # live filesystem out from under the pool.
        my $blockers = disk_blockers($entry, $st);
        for my $b (@$blockers) {
            die "'$dev' is $b\n" if $b =~ /already in this array/;
        }

        my @points = grep { defined($_) && $_ ne '' }
            ($entry->{mountpoint}, map { $_->{mountpoint} } @children);

        # Checked before anything is unmounted, so a disk carrying both a data
        # filesystem and a system one is refused outright rather than half done.
        for my $mp (@points) {
            die "'$dev' carries the system mountpoint '$mp'; refusing to"
                . " unmount it\n" if system_mountpoint($mp);
        }

        if (!@points) {
            syslog('info', "storage $storeid: '$dev' is not mounted, nothing to do");
            next;
        }
        for my $mp (@points) {
            syslog('warning', "storage $storeid: unmounting '$mp' ($dev) on request");
            run_command(['/bin/umount', $mp], timeout => 60,
                errmsg => "could not unmount '$mp'");
        }
    }
}

# Wiping goes through here rather than straight to PVE's /disks/wipedisk,
# which is the obvious implementation and the wrong one: that endpoint knows
# nothing about NonRAID, and a live array member looks exactly like a spare to
# it - not mounted (the driver's /dev/nmdNp1 is), no holder, just partitions.
# Wiping one destroys a member beneath the parity layer. So membership is
# checked here first, and only then is the disk wiped.
my sub wipe_disks {
    my ($storeid, $devs, $st) = @_;

    for my $dev (@$devs) {
        die "'$dev' is not an absolute device path\n" if $dev !~ m{^/dev/[\w/-]+$};
        my $entry = _lsblk_entry($dev)
            or die "'$dev': device not found\n";

        # Partitions are why one wipes, so they are not a blocker here. Every
        # other reason still is.
        my @fatal = grep { !/^\d+ partition/ } @{ disk_blockers($entry, $st) };
        die "refusing to wipe '$dev': " . join(', ', @fatal) . "\n" if @fatal;

        syslog('warning', "storage $storeid: wiping '$dev' on request"
            . " - its contents are being destroyed");
        # -a takes every signature on the device, the partition table included.
        run_command(['/sbin/wipefs', '-a', $dev], timeout => 120,
            errmsg => "wiping '$dev' failed");
        eval { run_command(['/usr/bin/udevadm', 'trigger', $dev], timeout => 30) };
    }
}

my sub create_array {
    my ($storeid, $scfg, $parity, $data) = @_;

    die "nonraid-create-parity needs at least one disk\n" if !@$parity;
    die "nonraid-create-data needs at least one disk\n" if !@$data;

    my $st = read_nmdstat();

    # One array per node - the superblock is a module parameter - so building
    # one on top of a loaded array would take its disks with it.
    if ($st && (($st->{mdState} // '') ne '' || nmdstat_num($st->{mdNumDisks}) > 0)) {
        die "an array is already loaded (state '" . ($st->{mdState} // '?')
            . "', superblock '" . ($st->{sbName} // '?') . "'); stop and unassign"
            . " it with nmdctl before building a new one\n";
    }

    my %seen;
    for my $dev (@$parity, @$data) {
        die "'$dev' listed twice\n" if $seen{$dev}++;
    }
    require_assignable([@$parity, @$data], $st);

    my @specs = build_assign_specs($parity, $data, 1);
    my $super = _scfg_super($scfg);
    syslog('warning', "storage $storeid: creating a NonRAID array on $super"
        . " with " . join(' ', @specs) . " - this destroys their contents");

    run_command([$NMDCTL, '-u', '-s', $super, 'create', '--force', @specs],
        timeout => 300, errmsg => 'creating the NonRAID array failed');

    # A freshly created array sits in NEW_ARRAY, which activation refuses by
    # design. Start it here so the storage this hook is creating can actually
    # come up; the parity build the driver then begins runs in the kernel, so
    # this returns without holding the storage lock for it.
    run_command([$NMDCTL, '-u', '-v', '-s', $super, 'start', 'NEW_ARRAY'],
        timeout => 300, errmsg => 'starting the new array failed');
    run_command([$NMDCTL, '-u', '-s', $super, 'check', 'recon'],
        timeout => 60, errmsg => 'starting the parity build failed');

    syslog('warning', "storage $storeid: array created and started;"
        . " parity is building - watch it with 'nmdctl status'");
}

# Actions are consumed here and deleted from the config, so they never persist.
my sub run_disk_actions {
    my ($storeid, $scfg, $target) = @_;

    my $unmount = $target->{'nonraid-unmount-disks'};
    my $wipe = $target->{'nonraid-wipe-disks'};
    my $parity = $target->{'nonraid-create-parity'};
    my $data = $target->{'nonraid-create-data'};

    delete $target->{'nonraid-unmount-disks'};
    delete $target->{'nonraid-wipe-disks'};
    delete $target->{'nonraid-create-parity'};
    delete $target->{'nonraid-create-data'};

    # Ordered the way the operator works: free it, clear it, then use it.
    unmount_disks($storeid, [PVE::Tools::split_list($unmount)], read_nmdstat())
        if defined($unmount) && $unmount ne '';

    wipe_disks($storeid, [PVE::Tools::split_list($wipe)], read_nmdstat())
        if defined($wipe) && $wipe ne '';

    if ((defined($parity) && $parity ne '') || (defined($data) && $data ne '')) {
        create_array(
            $storeid, $scfg,
            [PVE::Tools::split_list($parity // '')],
            [PVE::Tools::split_list($data // '')],
        );
    }
}

sub on_add_hook {
    my ($class, $storeid, $scfg, %param) = @_;
    run_disk_actions($storeid, $scfg, $scfg);
    return undef;
}

sub on_update_hook_full {
    my ($class, $storeid, $scfg, $update, $delete, $sensitive) = @_;
    # Building an array under an existing storage would need the array stopped,
    # which means stopping every guest on it - not something to do from a
    # config edit. Unmounting is fine.
    die "nonraid-create-* only applies when creating a storage; to extend an"
        . " existing array use 'nmdctl add', which needs the array stopped\n"
        if defined($update->{'nonraid-create-parity'})
        || defined($update->{'nonraid-create-data'});
    run_disk_actions($storeid, $scfg, $update);
    return undef;
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
