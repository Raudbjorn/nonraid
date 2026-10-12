# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright 2026 Sveinbjörn Geirsson

package PVE::Storage::DirPlugin;

use strict;
use warnings;

our @ISA = ('PVE::Storage::Plugin');
our ($ALLOC_IMAGE_CB, $FILESYSTEM_PATH_CB, $FREE_IMAGE_CB);
our ($VOLUME_RESIZE_CB, $VOLUME_SIZE_INFO_CB);


sub check_config {
    my ($class, $section_id, $config, $create, $skip_schema_check) = @_;
    my $options = $class->options();

    for my $key (keys %{$config}) {
        next if $key eq 'type';
        die "unexpected property '$key'\n" if !exists($options->{$key});
        die "can't change value of fixed parameter '$key'\n"
            if !$create && $options->{$key}->{fixed};
    }

    if ($create) {
        for my $key (keys %{$options}) {
            next if $options->{$key}->{optional};
            die "missing value for required option '$key'\n"
                if !defined($config->{$key});
        }
    }

    my $checked = { type => $class->type(), %{$config} };
    if (defined($checked->{nodes}) && !ref($checked->{nodes})) {
        $checked->{nodes} = {
            map { $_ => 1 } split(/,/, $checked->{nodes}, -1),
        };
    }
    return $checked;
}

sub alloc_image {
    die "alloc_image test callback is not configured\n" if !$ALLOC_IMAGE_CB;
    return $ALLOC_IMAGE_CB->(@_);
}

sub filesystem_path {
    die "filesystem_path test callback is not configured\n" if !$FILESYSTEM_PATH_CB;
    return $FILESYSTEM_PATH_CB->(@_);
}

sub free_image {
    die "free_image test callback is not configured\n" if !$FREE_IMAGE_CB;
    return $FREE_IMAGE_CB->(@_);
}

sub volume_resize {
    die "volume_resize test callback is not configured\n" if !$VOLUME_RESIZE_CB;
    return $VOLUME_RESIZE_CB->(@_);
}

sub volume_size_info {
    die "volume_size_info test callback is not configured\n" if !$VOLUME_SIZE_INFO_CB;
    return $VOLUME_SIZE_INFO_CB->(@_);
}

sub register {
    my ($class) = @_;
    return PVE::Storage::_register($class);
}

1;
