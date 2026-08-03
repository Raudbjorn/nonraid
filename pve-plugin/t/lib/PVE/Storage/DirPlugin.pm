package PVE::Storage::DirPlugin;

# Test stub for the parent class. The plugin uses 'use parent -norequire', so
# nothing loads DirPlugin during a unit-test run and every ->can() on the
# subclass warns about the unresolvable @ISA entry. Resolving the name is the
# whole job.
#
# Deliberately without behaviour: the plugin no longer calls path_is_mounted or
# config_aware_base_mkdir - pool identity goes through pool_is_ours() now - and
# a stub sub that nothing calls is only ever exercised by itself. What the
# plugin does reach through SUPER:: (check_config, activate_storage, status)
# belongs here the day a test actually calls it, added with that test.

use strict;
use warnings;

1;
