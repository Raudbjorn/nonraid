#!/usr/bin/perl
# The hooks that actually touch disks. Every refusal is asserted to happen
# BEFORE any command is issued - a validation that fires after nmdctl has
# already written to a disk is not a validation.
use strict;
use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/..";

use PVE::Tools;
use PVE::ProcFSTools;
use PVE::Storage::DirPlugin;
use PVE::INotify;
use PVE::RPCEnvironment;
use PVE::Storage::Custom::NonRAIDPlugin;

my $P = 'PVE::Storage::Custom::NonRAIDPlugin';
my $fixtures = "$FindBin::Bin/fixtures";

# lsblk is shelled out to; feed it canned answers per device.
my %LSBLK;
sub stub_lsblk {
    %LSBLK = @_;
    no warnings 'redefine';
    *PVE::Storage::Custom::NonRAIDPlugin::_lsblk_entry = sub {
        my ($dev) = @_;
        return $LSBLK{$dev};
    };
}

sub reset_commands {
    @PVE::Tools::run_command_log = ();
    $PVE::Tools::run_command_hook = undef;
}
sub cmds { return [map { join(' ', @$_) } @PVE::Tools::run_command_log]; }

# Disk actions are node-scoped: device names are node-local, so the hooks
# refuse unless the storage names the node serving the request.
my $scfg = { path => '/mnt/pve/nrpool', 'nonraid-super' => '/nonraid.dat',
    nodes => { $PVE::INotify::nodename => 1 } };

# --- creating an array -----------------------------------------------------

# The happy path: two blank disks, no array loaded.
{
    reset_commands();
    stub_lsblk(
        '/dev/sdb' => { name => 'sdb', type => 'disk' },
        '/dev/sdc' => { name => 'sdc', type => 'disk' },
    );
    local $ENV{PROC_NMDSTAT} = "$fixtures/does-not-exist"; # no module loaded
    my $target = {
        %$scfg,
        'nonraid-create-parity' => '/dev/sdb',
        'nonraid-create-data' => '/dev/sdc',
    };
    $P->on_add_hook('nrpool', $target);

    is_deeply(
        cmds(),
        [
            '/usr/bin/nmdctl -u -s /nonraid.dat create --force P:/dev/sdb 1:/dev/sdc',
            '/usr/bin/nmdctl -u -v -s /nonraid.dat start NEW_ARRAY',
            '/usr/bin/nmdctl -u -s /nonraid.dat check recon',
        ],
        'create, then start, then begin the parity build',
    );
    ok(!exists $target->{'nonraid-create-parity'}, 'the action does not persist');
    ok(!exists $target->{'nonraid-create-data'}, 'neither does the data list');
    is($target->{path}, '/mnt/pve/nrpool', 'real config keys are untouched');
}

# An array is already loaded: refuse, because the driver holds one per node.
{
    reset_commands();
    stub_lsblk('/dev/sdb' => { name => 'sdb', type => 'disk' });
    local $ENV{PROC_NMDSTAT} = "$fixtures/nmdstat-started-clean.txt";
    eval {
        $P->on_add_hook('nrpool', {
            %$scfg,
            'nonraid-create-parity' => '/dev/sdb',
            'nonraid-create-data' => '/dev/sdc',
        });
    };
    like($@, qr/an array is already loaded/, 'refuses to build over a live array');
    is_deeply(cmds(), [], 'and issues nothing');
}

# A disk that is not clean is refused, with every reason, before anything runs.
{
    reset_commands();
    stub_lsblk(
        '/dev/sdb' => { name => 'sdb', type => 'disk' },
        '/dev/sdc' => {
            name => 'sdc', type => 'disk',
            children => [{ name => 'sdc1', type => 'part', mountpoint => '/srv' }],
        },
    );
    local $ENV{PROC_NMDSTAT} = "$fixtures/does-not-exist";
    eval {
        $P->on_add_hook('nrpool', {
            %$scfg,
            'nonraid-create-parity' => '/dev/sdb',
            'nonraid-create-data' => '/dev/sdc',
        });
    };
    like($@, qr{/dev/sdc:.*mounted at /srv}, 'names the disk and the reason');
    like($@, qr/1 partition/, 'and every reason, not just the first');
    is_deeply(cmds(), [], 'nothing issued when a disk is refused');
}

{
    reset_commands();
    stub_lsblk('/dev/sdb' => { name => 'sdb', type => 'disk' });
    local $ENV{PROC_NMDSTAT} = "$fixtures/does-not-exist";
    eval {
        $P->on_add_hook('nrpool', {
            %$scfg,
            'nonraid-create-parity' => '/dev/sdb',
            'nonraid-create-data' => '/dev/sdb',
        });
    };
    like($@, qr{'/dev/sdb' listed twice}, 'the same disk cannot be parity and data');
    is_deeply(cmds(), [], 'nothing issued');

    reset_commands();
    eval {
        $P->on_add_hook('nrpool', {
            %$scfg, 'nonraid-create-parity' => 'sdb; rm -rf /',
            'nonraid-create-data' => '/dev/sdc',
        });
    };
    like($@, qr/not an absolute device path/, 'a non-device path is refused');
    is_deeply(cmds(), [], 'nothing issued');
}

# Extending a live array needs it stopped, so the update hook refuses.
{
    reset_commands();
    eval {
        $P->on_update_hook_full('nrpool', $scfg,
            { 'nonraid-create-data' => '/dev/sdd' }, undef, {});
    };
    like($@, qr/only applies when creating a storage/, 'no array building on update');
    is_deeply(cmds(), [], 'nothing issued');
}

# --- unmounting ------------------------------------------------------------

{
    reset_commands();
    stub_lsblk('/dev/sdc' => {
        name => 'sdc', type => 'disk',
        children => [
            { name => 'sdc1', type => 'part', mountpoint => '/srv/one' },
            { name => 'sdc2', type => 'part', mountpoint => '/srv/two' },
        ],
    });
    local $ENV{PROC_NMDSTAT} = "$fixtures/does-not-exist";
    my $target = { 'nonraid-unmount-disks' => '/dev/sdc' };
    $P->on_update_hook_full('nrpool', $scfg, $target, undef, {});
    is_deeply(
        cmds(),
        ['/bin/umount /srv/one', '/bin/umount /srv/two'],
        'every mountpoint on the disk is unmounted',
    );
    ok(!exists $target->{'nonraid-unmount-disks'}, 'the action does not persist');
}

# A holder is somebody else's lifecycle - refuse rather than guess.
{
    reset_commands();
    stub_lsblk('/dev/sdc' => {
        name => 'sdc', type => 'disk',
        children => [{ name => 'pve-data', type => 'lvm' }],
    });
    local $ENV{PROC_NMDSTAT} = "$fixtures/does-not-exist";
    eval {
        $P->on_update_hook_full('nrpool', $scfg,
            { 'nonraid-unmount-disks' => '/dev/sdc' }, undef, {});
    };
    like($@, qr/held by pve-data \(lvm\)/, 'refuses a held disk');
    like($@, qr/tool that created it/, 'and says whose job it is');
    is_deeply(cmds(), [], 'nothing unmounted');
}

# Never unmount a member out from under the running pool.
{
    reset_commands();
    stub_lsblk('/dev/sdb' => {
        name => 'sdb', type => 'disk',
        children => [{ name => 'sdb1', type => 'part', mountpoint => '/mnt/disk1' }],
    });
    local $ENV{PROC_NMDSTAT} = "$fixtures/nmdstat-started-clean.txt";
    eval {
        $P->on_update_hook_full('nrpool', $scfg,
            { 'nonraid-unmount-disks' => '/dev/sdb' }, undef, {});
    };
    like($@, qr/already in this array/, 'an array member is refused');
    is_deeply(cmds(), [], 'nothing unmounted');
}

# The OS disk reached the actual umount on the rig and was only stopped by the
# kernel saying "target is busy" - luck, not a guarantee. A quiet /boot/efi
# would have unmounted cleanly.
{
    my $sys = $P->can('system_mountpoint');
    ok($sys->('/'), 'root is a system mountpoint');
    ok($sys->('/boot/efi'), 'so is anything under /boot');
    ok($sys->('/var'), 'and /var');
    ok(!$sys->('/mnt/disk1'), 'a data mountpoint is not');
    ok(!$sys->('/srv/backups'), 'nor /srv');
    ok(!$sys->(undef), 'undef is not');

    reset_commands();
    stub_lsblk('/dev/sda' => {
        name => 'sda', type => 'disk',
        children => [
            { name => 'sda1', type => 'part', mountpoint => '/' },
            { name => 'sda2', type => 'part', mountpoint => '/boot/efi' },
        ],
    });
    local $ENV{PROC_NMDSTAT} = "$fixtures/does-not-exist";
    eval {
        $P->on_update_hook_full('nrpool', $scfg,
            { 'nonraid-unmount-disks' => '/dev/sda' }, undef, {});
    };
    like($@, qr{it is the system mountpoint '/'}, 'the OS disk is refused');
    is_deeply(cmds(), [], 'and nothing is unmounted, not even the EFI partition');
}

# A disk carrying both a data and a system mountpoint is refused whole, so a
# partial unmount cannot leave the system half torn down.
{
    reset_commands();
    stub_lsblk('/dev/sdc' => {
        name => 'sdc', type => 'disk',
        children => [
            { name => 'sdc1', type => 'part', mountpoint => '/srv/data' },
            { name => 'sdc2', type => 'part', mountpoint => '/var' },
        ],
    });
    local $ENV{PROC_NMDSTAT} = "$fixtures/does-not-exist";
    eval {
        $P->on_update_hook_full('nrpool', $scfg,
            { 'nonraid-unmount-disks' => '/dev/sdc' }, undef, {});
    };
    like($@, qr{system mountpoint '/var'}, 'refused for the system mount');
    is_deeply(cmds(), [], 'the data mountpoint is not unmounted either');
}

# --- wiping -----------------------------------------------------------------

# The reason wipe does not go straight to PVE's /disks/wipedisk: to that
# endpoint a live array member is indistinguishable from a spare - not mounted
# (the driver's nmdNp1 is), no holder, just partitions. The clean fixture has
# rdevName.1=sdb1, so /dev/sdb is data slot 1.
{
    reset_commands();
    stub_lsblk('/dev/sdb' => {
        name => 'sdb', type => 'disk',
        children => [{ name => 'sdb1', type => 'part' }],
    });
    local $ENV{PROC_NMDSTAT} = "$fixtures/nmdstat-started-clean.txt";
    eval {
        $P->on_update_hook_full('nrpool', $scfg,
            { 'nonraid-wipe-disks' => '/dev/sdb' }, undef, {});
    };
    like($@, qr/refusing to wipe .*already in this array as data slot 1/,
        'a live array member is never wiped');
    is_deeply(cmds(), [], 'and nothing runs');
}

# Partitions are the reason to wipe, so they must not block it.
{
    reset_commands();
    stub_lsblk('/dev/sdz' => {
        name => 'sdz', type => 'disk',
        children => [{ name => 'sdz1', type => 'part' }, { name => 'sdz2', type => 'part' }],
    });
    local $ENV{PROC_NMDSTAT} = "$fixtures/does-not-exist";
    my $target = { 'nonraid-wipe-disks' => '/dev/sdz' };
    $P->on_update_hook_full('nrpool', $scfg, $target, undef, {});
    like(cmds()->[0], qr{^/sbin/wipefs -a /dev/sdz$}, 'a partitioned spare is wiped');
    ok(!exists $target->{'nonraid-wipe-disks'}, 'the action does not persist');
}

# Everything else still blocks.
{
    reset_commands();
    stub_lsblk('/dev/sdz' => {
        name => 'sdz', type => 'disk',
        children => [{ name => 'sdz1', type => 'part', mountpoint => '/srv' }],
    });
    local $ENV{PROC_NMDSTAT} = "$fixtures/does-not-exist";
    eval {
        $P->on_update_hook_full('nrpool', $scfg,
            { 'nonraid-wipe-disks' => '/dev/sdz' }, undef, {});
    };
    like($@, qr{refusing to wipe.*mounted at /srv}, 'a mounted disk is not wiped');
    is_deeply(cmds(), [], 'nothing runs');

    reset_commands();
    stub_lsblk('/dev/sdz' => {
        name => 'sdz', type => 'disk',
        children => [{ name => 'vg0', type => 'lvm' }],
    });
    eval {
        $P->on_update_hook_full('nrpool', $scfg,
            { 'nonraid-wipe-disks' => '/dev/sdz' }, undef, {});
    };
    like($@, qr/refusing to wipe.*vg0 \(lvm\) holds it/, 'a held disk is not wiped');
    is_deeply(cmds(), [], 'nothing runs');
}

# Nothing mounted is a no-op, not an error: the UI may ask blindly.
{
    reset_commands();
    stub_lsblk('/dev/sdz' => { name => 'sdz', type => 'disk' });
    local $ENV{PROC_NMDSTAT} = "$fixtures/does-not-exist";
    $P->on_update_hook_full('nrpool', $scfg,
        { 'nonraid-unmount-disks' => '/dev/sdz' }, undef, {});
    is_deeply(cmds(), [], 'an unmounted disk needs no umount');
}

# --- node scoping ----------------------------------------------------------
#
# storage.cfg is cluster-wide but device names are node-local, and POST/PUT
# /storage is served by whichever node the client is talking to. The GUI makes
# the gap sharp: it lists the disks of the node in the Nodes field and then
# submits to a cluster endpoint with no node at all.

{
    reset_commands();
    stub_lsblk('/dev/sdb' => { name => 'sdb', type => 'disk' });
    local $ENV{PROC_NMDSTAT} = "$fixtures/does-not-exist";

    # Aimed at another node: the disks named are not this machine's.
    eval {
        $P->on_add_hook('nrpool', {
            %$scfg,
            nodes => { 'someothernode' => 1 },
            'nonraid-wipe-disks' => '/dev/sdb',
        });
    };
    like($@, qr/served by 'testnode'/, 'a wipe aimed at another node is refused');
    like($@, qr/device names are node-local/, 'and the reason is named');
    is_deeply(cmds(), [], 'nothing was issued');

    # No restriction at all: nothing says which machine these disks are.
    eval {
        $P->on_add_hook('nrpool', {
            path => '/mnt/pve/nrpool',
            'nonraid-wipe-disks' => '/dev/sdb',
        });
    };
    like($@, qr/no 'nodes' restriction/, 'an unrestricted storage is refused');
    is_deeply(cmds(), [], 'nothing was issued');

    # Named, and this is the sole node: allowed through to the gate.
    reset_commands();
    eval {
        $P->on_add_hook('nrpool', {
            %$scfg,
            nodes => { 'testnode' => 1 },
            'nonraid-wipe-disks' => '/dev/sdb',
        });
    };
    is($@, '', 'a storage that names only this node proceeds');
    like(join(' ', @{ cmds() }), qr{wipefs -a /dev/sdb}, 'and the wipe ran');

    # A legacy multi-node restriction that HAPPENS to include this node used
    # to pass the gate, which meant the same config authorised the identical
    # wipe on every OTHER node it named too - device names are node-local, so
    # "wipe /dev/sdb" means a different disk on each. check_config leaves
    # such configs editable (no flag day for what's already on disk), so the
    # hook itself has to fail closed on them.
    reset_commands();
    eval {
        $P->on_add_hook('nrpool', {
            %$scfg,
            nodes => { 'testnode' => 1, 'anothernode' => 1 },
            'nonraid-wipe-disks' => '/dev/sdb',
        });
    };
    like($@, qr/names more than one node/,
        'a legacy multi-node restriction is refused even though it names this node');
    is_deeply(cmds(), [], 'and the wipe did not run');
}

{
    # An update may not repoint 'nodes' elsewhere and authorise itself against
    # the value still on disk.
    reset_commands();
    stub_lsblk('/dev/sdb' => { name => 'sdb', type => 'disk' });
    local $ENV{PROC_NMDSTAT} = "$fixtures/does-not-exist";
    eval {
        $P->on_update_hook_full('nrpool', $scfg,
            { nodes => { 'someothernode' => 1 }, 'nonraid-wipe-disks' => '/dev/sdb' },
            undef, {});
    };
    like($@, qr/served by 'testnode'/, 'the resulting config is what is checked');
    is_deeply(cmds(), [], 'nothing was issued');
}

# --- authorization ---------------------------------------------------------
#
# These properties ride in on POST/PUT /storage, which needs only
# Datastore.Allocate on /storage. PVE gates the equivalent physical operation
# (/nodes/{node}/disks/wipedisk) far higher - its API entry carries no
# permissions block at all, making it root@pam only.

{
    reset_commands();
    stub_lsblk('/dev/sdb' => { name => 'sdb', type => 'disk' });
    local $ENV{PROC_NMDSTAT} = "$fixtures/does-not-exist";

    local $PVE::RPCEnvironment::env =
        PVE::RPCEnvironment::Stub->new(user => 'storageadmin@pve', allow => 0);
    eval {
        $P->on_add_hook('nrpool', { %$scfg, 'nonraid-wipe-disks' => '/dev/sdb' });
    };
    like($@, qr/Permission check failed/, 'a caller without Sys.Modify is refused');
    is_deeply(cmds(), [], 'nothing was issued');
    my $asked = $PVE::RPCEnvironment::env->{checks}->[0];
    is($asked->{path}, '/nodes/testnode', 'the check is against this node');
    is_deeply($asked->{privs}, ['Sys.Modify'], 'and asks for Sys.Modify');
}

{
    reset_commands();
    stub_lsblk('/dev/sdb' => { name => 'sdb', type => 'disk' });
    local $ENV{PROC_NMDSTAT} = "$fixtures/does-not-exist";
    local $PVE::RPCEnvironment::env =
        PVE::RPCEnvironment::Stub->new(user => 'root@pam', allow => 1);
    eval {
        $P->on_add_hook('nrpool', { %$scfg, 'nonraid-wipe-disks' => '/dev/sdb' });
    };
    is($@, '', 'a caller with Sys.Modify proceeds');
    like(join(' ', @{ cmds() }), qr{wipefs -a /dev/sdb}, 'and the wipe ran');
}

# --- unmount must not reach another storage --------------------------------
#
# run_disk_actions goes unmount -> wipe in one pass, and wipe_disks re-reads
# lsblk. So a single call naming the same disk in both lists could unmount
# another PVE storage's filesystem, observe the disk is no longer mounted, and
# wipe it - with guests on it. Each step's own guard was right; the sequence
# walked between them. The unmount guard is what closes it.
{
    my $refusal = $P->can('unmount_refusal');
    my $paths = { '/mnt/pve/otherstore' => 'otherstore', '/srv/backups' => 'bkp' };

    is($refusal->('/mnt/data', $paths), undef, 'an unrelated mountpoint is fine');
    like($refusal->('/mnt/pve/otherstore', $paths), qr/belongs to the configured storage/,
        "another storage's own path is refused");
    like($refusal->('/mnt/pve/otherstore/images', $paths), qr/'otherstore'/,
        'and so is anything beneath it');
    like($refusal->('/srv/backups', $paths), qr/'bkp'/,
        'a storage mounted outside /mnt/pve is refused too');
    like($refusal->('/', $paths), qr/system mountpoint/, 'system paths still refused');
    is($refusal->('/mnt/pve/otherstore-not-really', $paths), undef,
        'a path that merely shares a prefix is not a child');
}

{
    # End to end through the hook, with the storage config stubbed.
    reset_commands();
    no warnings 'redefine';
    local *PVE::Storage::Custom::NonRAIDPlugin::configured_storage_paths =
        sub { return { '/mnt/pve/otherstore' => 'otherstore' } };
    use warnings 'redefine';

    stub_lsblk('/dev/sdd' => {
        name => 'sdd', type => 'disk',
        children => [{ name => 'sdd1', type => 'part', mountpoint => '/mnt/pve/otherstore' }],
    });
    local $ENV{PROC_NMDSTAT} = "$fixtures/does-not-exist";
    eval {
        $P->on_update_hook_full('nrpool', $scfg,
            { 'nonraid-unmount-disks' => '/dev/sdd', 'nonraid-wipe-disks' => '/dev/sdd' },
            undef, {});
    };
    like($@, qr/belongs to the configured storage 'otherstore'/,
        "unmount+wipe in one call cannot launder another storage's disk");
    is_deeply(cmds(), [], 'and neither the umount nor the wipefs ran');
}

# The module loaded with nothing assigned: mdState=STOPPED, mdNumDisks=0, no
# slots. Every other fixture has disks, so this state - a fresh modprobe -
# had no coverage, and the "already loaded, stop and unassign it" refusal used
# to fire here with advice about an array that does not exist.
{
    reset_commands();
    stub_lsblk(
        '/dev/sdb' => { name => 'sdb', type => 'disk' },
        '/dev/sdc' => { name => 'sdc', type => 'disk' },
    );
    local $ENV{PROC_NMDSTAT} = "$fixtures/nmdstat-loaded-empty.txt";
    eval {
        $P->on_add_hook('nrpool', {
            %$scfg,
            'nonraid-create-parity' => '/dev/sdb',
            'nonraid-create-data' => '/dev/sdc',
        });
    };
    is($@, '', 'a loaded-but-empty module does not block array creation');
    like(join(' ', @{ cmds() }), qr/create --force/,
        'and the create actually runs');
}

done_testing();
