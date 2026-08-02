package PVE::Tools;

# Test stub. Records run_command invocations instead of executing them.

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(run_command file_get_contents file_set_contents);

our @run_command_log;
our $run_command_hook;

sub run_command {
    my ($cmd, %param) = @_;
    push @run_command_log, $cmd;
    return $run_command_hook->($cmd, %param) if $run_command_hook;
    return 0;
}

sub lock_file {
    my ($file, $timeout, $code, @param) = @_;
    my $res = eval { $code->(@param) };
    return $res;
}

1;
