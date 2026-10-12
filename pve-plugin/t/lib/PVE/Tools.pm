# SPDX-License-Identifier: AGPL-3.0-or-later
package PVE::Tools;

# Test stub for the PVE helpers reached by the focused plugin contract.

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(lock_file df);

our @lock_call_log;
our $DF_CB;


sub lock_file {
    my ($file, $timeout, $code, @param) = @_;
    push @lock_call_log, { file => $file, timeout => $timeout };
    my $res = eval { $code->(@param) };
    return $res;
}

sub df {
    die "df test callback is not configured\n" if !$DF_CB;
    return $DF_CB->(@_);
}

1;