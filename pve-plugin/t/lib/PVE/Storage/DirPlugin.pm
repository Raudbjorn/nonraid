package PVE::Storage::DirPlugin;

# Test stub for the parent class. The plugin uses 'use parent -norequire', so
# nothing loads DirPlugin during a unit-test run and every ->can()/->import()
# on the subclass warns about the unresolvable @ISA entry. Only the two subs
# the plugin actually calls are provided.

use strict;
use warnings;

use Cwd;

sub path_is_mounted {
    my ($mountpoint, $mountdata) = @_;
    my $real = Cwd::realpath($mountpoint) // $mountpoint;
    return scalar(grep { $_->[1] eq $real || $_->[1] eq $mountpoint } @$mountdata) ? 1 : 0;
}

sub config_aware_base_mkdir { return; }

1;
