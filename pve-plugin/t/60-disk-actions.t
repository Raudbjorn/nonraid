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

my $scfg = { path => '/mnt/pve/nrpool', 'nonraid-super' => '/nonraid.dat' };

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
    like($@, qr{carries the system mountpoint '/'}, 'the OS disk is refused');
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

done_testing();
