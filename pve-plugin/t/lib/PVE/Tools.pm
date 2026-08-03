package PVE::Tools;

# Test stub. Records run_command invocations instead of executing them.

use strict;
use warnings;

# Only what the plugin imports. Exporting names with no sub behind them puts
# an undefined subroutine one call away, and hides it in the export list.
use Exporter 'import';
our @EXPORT_OK = qw(run_command);

our @run_command_log;
our $run_command_hook;

sub run_command {
    my ($cmd, %param) = @_;
    push @run_command_log, $cmd;
    return $run_command_hook->($cmd, %param) if $run_command_hook;
    return 0;
}

# Not exported: the plugin calls this fully qualified, like the real one.
# Runs the callback inline - the lock itself is not what these tests exercise.
sub lock_file {
    my ($file, $timeout, $code, @param) = @_;
    my $res = eval { $code->(@param) };
    return $res;
}

1;
