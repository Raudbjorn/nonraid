package PVE::SafeSyslog;

# Test stub. Records syslog calls.

use strict;
use warnings;

use Exporter 'import';
our @EXPORT = qw(syslog);

our @log;

sub syslog {
    push @log, [@_];
}

1;
