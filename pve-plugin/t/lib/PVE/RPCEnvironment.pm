package PVE::RPCEnvironment;

# Test stub. $env is undef by default, which is the "no API environment"
# case (pvesm from a shell, and these tests) - the plugin skips the privilege
# check there. Set it to an object with get_user()/check() to exercise the
# check itself.

use strict;
use warnings;

our $env;

sub get { return $env; }

# A minimal stand-in: records what was asked and raises unless allowed.
package PVE::RPCEnvironment::Stub;

sub new {
    my ($class, %args) = @_;
    return bless { user => $args{user} // 'someone@pve', allow => $args{allow} // 0,
        checks => [] }, $class;
}
sub get_user { return $_[0]->{user}; }
sub check {
    my ($self, $user, $path, $privs) = @_;
    push @{ $self->{checks} }, { user => $user, path => $path, privs => $privs };
    die "Permission check failed ($path, " . join(',', @$privs) . ")\n"
        if !$self->{allow};
    return 1;
}

1;
