# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright 2026 Sveinbjörn Geirsson

package PVE::Storage::Custom::NonRAIDPlugin;

use strict;
use warnings;
use Cwd qw(realpath);
use Digest::SHA qw(sha256_hex);
use File::ExtAttr ();
use PVE::Tools ();

use parent -norequire, 'PVE::Storage::DirPlugin';

our $VERSION = '0.1.0';

sub api {
    my $tested_api = 15;
    my $live_api = PVE::Storage::APIVER();
    my $live_age = PVE::Storage::APIAGE();

    die "nonraid plugin is not compatible with live PVE Storage API $live_api"
        . " (APIAGE $live_age); tested API is $tested_api\n"
        if $live_api != $tested_api;

    return $tested_api;
}

sub type {
    return 'nonraid';
}

sub properties {
    return {
        'nonraid-super' => {
            description => 'Literal absolute path to the NonRAID superblock file.',
            type => 'string',
            format => 'pve-storage-path',
        },
        'nonraid-degraded-autostart' => {
            description => 'Permit an explicitly degraded array to start automatically.',
            type => 'boolean',
            default => 0,
        },
    };
}

sub options {
    return {
        path => { fixed => 1 },
        'nonraid-super' => {},
        'nonraid-degraded-autostart' => { optional => 1 },
        nodes => {},
        disable => { optional => 1 },
        content => { optional => 1 },
        format => { fixed => 1 },
        preallocation => { fixed => 1 },
        'prune-backups' => { optional => 1 },
        'max-protected-backups' => { optional => 1 },
    };
}

sub plugindata {
    return {
        content => [{ images => 1, backup => 1 }, { images => 1 }],
        format => [{ qcow2 => 1 }, 'qcow2'],
        'sensitive-properties' => {},
    };
}

sub _check_path_syntax {
    my ($name, $path) = @_;

    die "$name must be an absolute path\n"
        if !defined($path) || $path !~ m{\A/};
    die "$name must not contain whitespace\n" if $path =~ /\s/;
    die "$name must not contain '..' path components\n"
        if $path =~ m{(?:\A|/)\.\.(?:/|\z)};
    die "$name must use a canonical literal spelling\n"
        if $path =~ m{//} || $path =~ m{(?:\A|/)\.(?:/|\z)}
        || ($path ne '/' && $path =~ m{/\z});

    return;
}

sub _pool_overlaps_member_mounts {
    my ($path) = @_;
    return 1 if $path eq '/' || $path eq '/mnt';
    return $path =~ m{\A/mnt/disk\d+(?:/|\z)} ? 1 : 0;
}

sub _check_super_identity {
    my ($path) = @_;

    _check_path_syntax('nonraid-super', $path);
    die "nonraid-super must already exist as a regular nonsymlink file\n"
        if -l $path || !-f $path;

    my $resolved = realpath($path);
    die "nonraid-super must use its literal resolved spelling and must not be a symlink\n"
        if !defined($resolved) || $resolved ne $path;

    return;
}

sub _node_list {
    my ($nodes) = @_;
    return () if !defined($nodes);
    return keys %{$nodes} if ref($nodes) eq 'HASH';
    die "nonraid nodes must be a node-list string or decoded node map\n" if ref($nodes);
    return split(/,/, $nodes, -1);
}

sub _check_one_node {
    my ($nodes) = @_;
    my @nodes = _node_list($nodes);
    die "nonraid storage must apply to exactly one node\n"
        if @nodes != 1 || !defined($nodes[0]) || $nodes[0] eq '';
    return $nodes[0];
}

sub check_config {
    my ($class, $section_id, $config, $create, $skip_schema_check) = @_;

    $config->{path} //= "/mnt/pve/$section_id" if $create;

    die "format must be qcow2\n"
        if defined($config->{format}) && $config->{format} ne 'qcow2';
    die "preallocation must be falloc\n"
        if defined($config->{preallocation}) && $config->{preallocation} ne 'falloc';

    if (defined($config->{path})) {
        _check_path_syntax('path', $config->{path});
        die "pool path overlaps fixed member mount paths /mnt/disk<N>\n"
            if _pool_overlaps_member_mounts($config->{path});
    }
    _check_super_identity($config->{'nonraid-super'})
        if defined($config->{'nonraid-super'});
    _check_one_node($config->{nodes}) if defined($config->{nodes});

    return $class->SUPER::check_config(
        $section_id,
        $config,
        $create,
        $skip_schema_check,
    );
}

sub get_identity {
    my ($class, $config) = @_;
    return $config->{'nonraid-super'};
}

sub _assert_node_available {
    my ($class, $storeid, $config) = @_;
    my $node = _check_one_node($config->{nodes});
    my $cluster_config = PVE::Storage::config();

    for my $other_id (keys %{ $cluster_config->{ids} // {} }) {
        next if $other_id eq $storeid;
        my $other = $cluster_config->{ids}->{$other_id};
        next if ($other->{type} // '') ne 'nonraid';
        my %other_nodes = map { $_ => 1 } _node_list($other->{nodes});
        die "nonraid storage '$other_id' already owns node '$node'\n"
            if $other_nodes{$node};
    }

    return;
}

sub on_add_hook {
    my ($class, $storeid, $config) = @_;
    $class->_assert_node_available($storeid, $config);
    return;
}

sub on_update_hook_full {
    my ($class, $storeid, $config, $update, $delete, $sensitive) = @_;
    my %prospective = %{$config};

    delete @prospective{@{ $delete // [] }};
    for my $key (keys %{$update}) {
        $prospective{$key} = $update->{$key};
    }
    for my $key (keys %{$sensitive}) {
        $prospective{$key} = $sensitive->{$key};
    }

    $class->_assert_node_available($storeid, \%prospective);
    return;
}

my $MAX_PROC_BYTES = 65_536;
my $BRANCH_RESERVE_BYTES = 1024 * 1024 * 1024;
my $MAX_SAFE_KIB = 9_007_199_254_740_991;

our $PROC_NMDSTAT_PATH = '/proc/nmdstat';
our $MOUNTINFO_PATH = '/proc/self/mountinfo';
our $GET_FATTR = sub { return File::ExtAttr::getfattr(@_) };

sub _read_bounded {
    my ($path, $label, $missing_is_undef) = @_;
    open(my $fh, '<', $path) or do {
        return undef if $missing_is_undef;
        die "cannot read $label '$path': $!\n";
    };
    binmode($fh);

    my $text = '';
    while (length($text) <= $MAX_PROC_BYTES) {
        my $read = sysread($fh, my $chunk, $MAX_PROC_BYTES + 1 - length($text));
        die "cannot read $label '$path': $!\n" if !defined($read);
        last if $read == 0;
        $text .= $chunk;
    }
    close($fh) or die "cannot close $label '$path': $!\n";
    die "$label exceeds $MAX_PROC_BYTES bytes\n" if length($text) > $MAX_PROC_BYTES;
    return $text;
}

sub parse_nmdstat_text {
    my ($text) = @_;
    $text //= '';
    die "nmdstat exceeds $MAX_PROC_BYTES bytes\n" if length($text) > $MAX_PROC_BYTES;

    my %state;
    my @lines = split(/\n/, $text, -1);
    pop @lines if @lines && $lines[-1] eq '';
    for my $line (@lines) {
        die "malformed nmdstat line\n" if $line eq '' || $line !~ /\A([^=]+)=(.*)\z/;
        my ($key, $value) = ($1, $2);
        die "malformed nmdstat key '$key'\n"
            if $key !~ /\A[A-Za-z][A-Za-z0-9]*(?:\.(\d+))?\z/;
        my $slot = $1;
        die "impossible slot $slot in nmdstat key '$key'\n"
            if defined($slot) && $slot > 29;
        die "duplicate key '$key' in nmdstat\n" if exists($state{$key});

        my $numeric = $key =~ /\A(?:mdNum[A-Za-z]*|mdResync(?:Corr|Pos|Size|Dt|Db)?|sbSyncErrs|sbSynced2?)\z/
            || $key =~ /\A(?:diskNumber|diskSize|diskState|rdevNumErrors)\.\d+\z/;
        my $signed = $key eq 'sbSyncExit';
        if ($value ne '' && (($numeric && $value !~ /\A\d+\z/) || ($signed && $value !~ /\A-?\d+\z/))) {
            die "nonnumeric nmdstat field '$key'\n";
        }
        $state{$key} = $value;
    }

    return \%state;
}

sub read_nmdstat {
    my $text = _read_bounded($PROC_NMDSTAT_PATH, 'nmdstat', 1);
    return undef if !defined($text);
    return parse_nmdstat_text($text);
}

sub nmdstat_num {
    my ($value) = @_;
    return ($value // '') =~ /\A\d+\z/ ? 0 + $value : 0;
}

sub data_slots {
    my ($state) = @_;
    my @slots;
    for my $key (keys %{$state // {}}) {
        next if $key !~ /\AdiskName\.(\d+)\z/;
        my $slot = 0 + $1;
        next if $slot == 0 || $slot == 29;
        next if ($state->{$key} // '') eq '';
        next if nmdstat_num($state->{"diskSize.$slot"}) <= 0;
        push @slots, $slot;
    }
    return sort { $a <=> $b } @slots;
}

sub mergerfs_branches {
    my ($state) = @_;
    return map { "/mnt/disk$_" } data_slots($state);
}

sub topology_fingerprint {
    my ($state) = @_;
    my @parts = ($state->{sbName} // '');
    for my $slot (data_slots($state)) {
        push @parts, map { defined($_) ? "$_" : '' } (
            $slot,
            $state->{"diskName.$slot"},
            $state->{"diskId.$slot"},
            $state->{"diskSize.$slot"},
            $state->{"rdevName.$slot"},
        );
    }
    my $framed = join('', map { length($_) . ':' . $_ } @parts);
    return sha256_hex($framed);
}

sub _mountinfo_unescape {
    my ($value) = @_;
    die "invalid mountinfo escape in '$value'\n"
        if $value =~ /\\(?!040|011|012|134)/;
    $value =~ s/\\(040|011|012|134)/chr(oct($1))/ge;
    return $value;
}

sub parse_mountinfo_text {
    my ($text) = @_;
    $text //= '';
    die "mountinfo exceeds $MAX_PROC_BYTES bytes\n" if length($text) > $MAX_PROC_BYTES;

    my @mounts;
    my @lines = split(/\n/, $text, -1);
    pop @lines if @lines && $lines[-1] eq '';
    for my $line (@lines) {
        die "malformed mountinfo line\n" if $line eq '';
        my @fields = split(/\s+/, $line);
        my ($separator) = grep { $fields[$_] eq '-' } 0 .. $#fields;
        die "mountinfo line missing separator\n" if !defined($separator);
        die "malformed mountinfo line\n" if $separator < 6 || @fields - $separator - 1 < 3;
        die "malformed mountinfo ids\n"
            if $fields[0] !~ /\A\d+\z/ || $fields[1] !~ /\A\d+\z/
            || $fields[2] !~ /\A\d+:\d+\z/;

        push @mounts, {
            id => 0 + $fields[0],
            parent => 0 + $fields[1],
            root => _mountinfo_unescape($fields[3]),
            mountpoint => _mountinfo_unescape($fields[4]),
            mount_options => $fields[5],
            fstype => $fields[$separator + 1],
            source => _mountinfo_unescape($fields[$separator + 2]),
            super_options => $fields[$separator + 3],
        };
    }
    return \@mounts;
}

sub read_mountinfo {
    my $text = _read_bounded($MOUNTINFO_PATH, 'mountinfo', 0);
    return parse_mountinfo_text($text);
}

sub assert_member_mounts {
    my ($state, $mounts) = @_;
    my @slots = data_slots($state);
    die "array has no live data slots\n" if !@slots;
    my %expected = map { ("/mnt/disk$_", $_) } @slots;

    for my $mount (@{$mounts}) {
        next if $mount->{mountpoint} !~ /\A\/mnt\/disk\d+\z/;
        die "unexpected fixed member mount '$mount->{mountpoint}'\n"
            if !exists($expected{$mount->{mountpoint}});
    }

    my %allowed_fs = map { ($_, 1) } qw(btrfs ext2 ext3 ext4 xfs zfs);
    my @branches;
    for my $slot (@slots) {
        my $mountpoint = "/mnt/disk$slot";
        my @at_target = grep { $_->{mountpoint} eq $mountpoint } @{$mounts};
        die "missing mount for data slot $slot at $mountpoint\n" if !@at_target;
        die "multiple mounts at fixed member mount $mountpoint\n" if @at_target != 1;
        my $mount = $at_target[0];
        die "unsupported filesystem '$mount->{fstype}' at $mountpoint\n"
            if !$allowed_fs{$mount->{fstype}};

        my $disk_name = $state->{"diskName.$slot"} // '';
        my $source_ok = $mount->{fstype} eq 'zfs'
            ? $mount->{source} eq "disk$slot"
            : ($mount->{source} eq "/dev/$disk_name"
                || $mount->{source} eq "/dev/mapper/$disk_name");
        die "wrong source '$mount->{source}' for data slot $slot at $mountpoint\n"
            if !$source_ok;

        my @same_source = grep { $_->{source} eq $mount->{source} } @{$mounts};
        die "source '$mount->{source}' is mounted more than once\n" if @same_source != 1;
        push @branches, $mountpoint;
    }
    return \@branches;
}

sub _xattr {
    my ($path, $key) = @_;
    my $value = eval { $GET_FATTR->($path, $key) };
    my $error = $@;
    die "cannot read mergerfs xattr '$key' from '$path': $error"
        if $error || !defined($value);
    return $value;
}

sub assert_pool_identity {
    my ($storeid, $path, $branches, $mounts) = @_;
    my @pool = grep { $_->{mountpoint} eq $path } @{$mounts};
    die "pool path '$path' is not mounted\n" if !@pool;
    die "pool path '$path' has multiple mounts\n" if @pool != 1;
    my $mount = $pool[0];
    die "pool path '$path' is not an exact fuse.mergerfs mount\n"
        if $mount->{fstype} ne 'fuse.mergerfs';
    die "pool path '$path' has wrong source '$mount->{source}'\n"
        if $mount->{source} ne "nonraid-$storeid";
    die "pool path '$path' is not mounted read-write\n"
        if !grep { $_ eq 'rw' } split(/,/, $mount->{mount_options});

    my $control = "$path/.mergerfs";
    my %expected = (
        'user.mergerfs.branches' => join(':', map { "$_=RW" } @{$branches}),
        'user.mergerfs.cache.files' => 'off',
        'user.mergerfs.category.create' => 'mfs',
        'user.mergerfs.moveonenospc' => 'false',
        'user.mergerfs.minfreespace' => "$BRANCH_RESERVE_BYTES",
        'user.mergerfs.fsname' => "nonraid-$storeid",
    );
    for my $key (sort keys %expected) {
        my $actual = _xattr($control, $key);
        die "mergerfs $key identity mismatch: expected '$expected{$key}', got '$actual'\n"
            if $actual ne $expected{$key};
    }
    return 1;
}

sub default_mergerfs_opts {
    my ($storeid) = @_;
    return "cache.files=off,category.create=mfs,moveonenospc=false,"
        . "minfreespace=1G,fsname=nonraid-$storeid";
}

sub nmdstat_health {
    my ($state, $accepted) = @_;
    my $array_state = $state->{mdState} // 'UNKNOWN';
    $array_state = 'UNKNOWN' if $array_state eq '';
    my $disabled = nmdstat_num($state->{mdNumDisabled});
    my $invalid = nmdstat_num($state->{mdNumInvalid});
    my $missing = nmdstat_num($state->{mdNumMissing});
    my $degraded = ($disabled || $invalid || $missing) ? 1 : 0;

    my $active = nmdstat_num($state->{mdResync});
    my $position = nmdstat_num($state->{mdResyncPos});
    my $size = nmdstat_num($state->{mdResyncSize});
    my $exit = ($state->{sbSyncExit} // '') =~ /\A-?\d+\z/ ? 0 + $state->{sbSyncExit} : 0;
    my $action = $state->{mdResyncAction} // '';
    my $resync_state = 'idle';
    $resync_state = 'accepted' if $accepted;
    $resync_state = 'completed' if $action ne '' && $size > 0 && $position >= $size && $exit == 0;
    $resync_state = 'paused' if !$active && $position > 0 && ($size == 0 || $position < $size);
    $resync_state = 'running' if $active > 0;
    $resync_state = 'failed' if $exit != 0;

    my $percentage;
    $percentage = sprintf('%.1f', 100 * $position / $size)
        if ($resync_state eq 'running' || $resync_state eq 'paused') && $size > 0;
    my $transition_key = join('|', $array_state, $degraded, $resync_state, $action, $exit);
    return {
        state => $array_state,
        degraded => $degraded,
        rebuilding => $resync_state eq 'running' ? 1 : 0,
        resync_state => $resync_state,
        resync_pct => $percentage,
        transition_key => $transition_key,
        summary => $transition_key,
    };
}

sub branch_usable_bytes {
    my ($branch) = @_;
    my $stats = PVE::Tools::df($branch, 2);
    die "cannot determine capacity for live branch '$branch'\n"
        if !$stats || !defined($stats->{avail}) || $stats->{avail} !~ /\A\d+(?:\.\d+)?(?:e[+-]?\d+)?\z/i;
    my $available = int($stats->{avail});
    return 0 if $available <= $BRANCH_RESERVE_BYTES;
    return $available - $BRANCH_RESERVE_BYTES;
}

sub _live_identity {
    my ($storeid, $config) = @_;
    my $state = read_nmdstat();
    die "NonRAID array is not loaded\n" if !$state;
    my $expected_super = $config->{'nonraid-super'} // '';
    die "live NonRAID superblock identity does not match '$expected_super'\n"
        if ($state->{sbName} // '') ne $expected_super;
    my $mounts = read_mountinfo();
    my $branches = assert_member_mounts($state, $mounts);
    assert_pool_identity($storeid, $config->{path}, $branches, $mounts);
    return ($state, $mounts, $branches);
}

sub _image_owner {
    my ($pool_path, $branches) = @_;
    my $allpaths = _xattr($pool_path, 'user.mergerfs.allpaths');
    my @owners = split(/\0/, $allpaths, -1);
    pop @owners if @owners && $owners[-1] eq '';
    die "image does not have exactly one live branch owner\n" if @owners != 1;

    my $owner_path = $owners[0];
    for my $branch (@{$branches}) {
        return $branch if $owner_path eq $branch || index($owner_path, "$branch/") == 0;
    }
    die "image does not have exactly one live branch owner\n";
}

sub alloc_image {
    my ($class, $storeid, $config, $vmid, $format, $name, $size_kib) = @_;
    die "allocation size must be a nonnegative integer in KiB\n"
        if !defined($size_kib) || $size_kib !~ /\A\d+\z/ || $size_kib > $MAX_SAFE_KIB;
    my $bytes = $size_kib * 1024;
    my (undef, undef, $branches) = _live_identity($storeid, $config);
    my $fits = grep { branch_usable_bytes($_) >= $bytes } @{$branches};
    die "no live branch can reserve $bytes bytes with the fixed 1 GiB reserve\n" if !$fits;

    my $volume = $class->SUPER::alloc_image(
        $storeid, $config, $vmid, $format, $name, $size_kib,
    );
    my $path = $class->filesystem_path($config, $volume);
    my $ok = eval { _image_owner($path, $branches); 1 };
    if (!$ok) {
        my $identity_error = $@ || "image ownership postcondition failed\n";
        my $cleanup_ok = eval {
            $class->SUPER::free_image($storeid, $config, $volume, 0, $format);
            1;
        };
        my $cleanup_error = $@;
        die $identity_error if $cleanup_ok;
        die $identity_error . "cleanup after ownership failure also failed: $cleanup_error";
    }
    return $volume;
}

sub volume_resize {
    my ($class, $config, $storeid, $volume, $new_size, $running, $snapname) = @_;
    die "resize size must be a nonnegative integer in bytes\n"
        if !defined($new_size) || $new_size !~ /\A\d+\z/;
    my (undef, undef, $branches) = _live_identity($storeid, $config);
    my $path = $class->filesystem_path($config, $volume, $snapname);
    my $owner = eval { _image_owner($path, $branches) };
    die "resize unsupported: " . ($@ || "image owner is unknown\n") if !defined($owner);

    my $current_size = $class->volume_size_info($config, $storeid, $volume, 10);
    die "resize unsupported: current virtual size is unavailable\n"
        if !defined($current_size) || $current_size !~ /\A\d+\z/;
    my $growth = $new_size > $current_size ? $new_size - $current_size : 0;
    die "owner branch '$owner' cannot reserve $growth bytes with the fixed 1 GiB reserve\n"
        if $growth && branch_usable_bytes($owner) < $growth;

    return $class->SUPER::volume_resize(
        $config, $storeid, $volume, $new_size, $running, $snapname,
    );
}

my %VOLUME_FEATURES;

sub volume_has_feature {
    my ($class, $config, $feature) = @_;
    return $VOLUME_FEATURES{$feature} // 0;
}

1;
