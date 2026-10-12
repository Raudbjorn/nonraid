# SPDX-License-Identifier: AGPL-3.0-or-later
package Cwd;

# Test stub for Cwd. Only the symbols Task 4 reaches are implemented:
# realpath() and abs_path() return the input unchanged so check_config's
# canonical-path rejection can be exercised without touching the filesystem.

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(realpath abs_path);

sub realpath { return $_[0]; }
sub abs_path { return $_[0]; }

1;