package PVE::INotify;

# Test stub. The plugin asks for the node it is running on to decide whether
# node-local device names belong to this machine; the tests set it directly.

use strict;
use warnings;

our $nodename = 'testnode';

sub nodename { return $nodename; }

1;
