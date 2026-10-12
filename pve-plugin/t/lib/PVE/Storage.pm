# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright 2026 Sveinbjörn Geirsson

package PVE::Storage;

use strict;
use warnings;

our $APIVER = $ENV{PVE_TEST_APIVER} // 15;
our $APIAGE = $ENV{PVE_TEST_APIAGE} // 6;
our $CONFIG = { ids => {} };
our $CONFIG_READS = 0;

my %plugins;
my %property_owner;

sub APIVER { return $APIVER; }
sub APIAGE { return $APIAGE; }
sub config {
    $CONFIG_READS++;
    return $CONFIG;
}

sub _register {
    my ($class) = @_;
    my $type = $class->type();
    die "duplicate storage type '$type'\n" if exists($plugins{$type});

    for my $property (keys %{ $class->properties() }) {
        die "property '$property' is already registered by $property_owner{$property}\n"
            if exists($property_owner{$property});
        $property_owner{$property} = $class;
    }

    $plugins{$type} = $class;
    return;
}

sub _lookup {
    my ($type) = @_;
    return $plugins{$type};
}

require PVE::Storage::DirPlugin;

my $module = 'PVE::Storage::Custom::NonRAIDPlugin';
my $file = 'PVE/Storage/Custom/NonRAIDPlugin.pm';
eval {
    require $file;
    die "not derived from PVE::Storage::Plugin\n" if !$module->isa('PVE::Storage::Plugin');
    die "does not provide an api() method\n" if !$module->can('api');
    my $version = $module->api();
    die "implements an API version newer than current ($version > " . APIVER . ")\n"
        if $version > APIVER;
    my $minimum = APIVER - APIAGE;
    die "API version too old, please update the plugin ($version < $minimum)\n"
        if $version < $minimum;
    $module->register();
};
warn "could not load custom storage plugin $module: $@" if $@;

package PVE::Storage::Plugin;

use strict;
use warnings;

sub register {
    my ($class) = @_;
    return PVE::Storage::_register($class);
}

sub lookup {
    my ($class, $type) = @_;
    return PVE::Storage::_lookup($type);
}

1;
