#!/usr/bin/perl
use strict;
use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/..";

use PVE::Storage::Custom::NonRAIDPlugin;

my $P = 'PVE::Storage::Custom::NonRAIDPlugin';
my $fixtures = "$FindBin::Bin/fixtures";

# parse_nmdstat_text
{
    my $st = $P->can('parse_nmdstat_text')->("mdState=STARTED\nsbName=/nonraid.dat\n");
    is($st->{mdState}, 'STARTED', 'simple key=value');
    is($st->{sbName}, '/nonraid.dat', 'path value');

    $st = $P->can('parse_nmdstat_text')->("diskId.1=WDC_WD40=weird=id\n");
    is($st->{'diskId.1'}, 'WDC_WD40=weird=id', 'only the first = delimits');

    $st = $P->can('parse_nmdstat_text')->("diskName.0=\n");
    is($st->{'diskName.0'}, '', 'empty value preserved');

    $st = $P->can('parse_nmdstat_text')->('');
    is_deeply($st, {}, 'empty text -> empty hash');

    $st = $P->can('parse_nmdstat_text')->(undef);
    is_deeply($st, {}, 'undef text -> empty hash');

    $st = $P->can('parse_nmdstat_text')->("garbage line no equals\nmdState=STOPPED\n");
    is($st->{mdState}, 'STOPPED', 'garbage lines skipped');
}

# read_nmdstat via the PROC_NMDSTAT seam
{
    local $ENV{PROC_NMDSTAT} = "$fixtures/nmdstat-started-clean.txt";
    my $st = $P->can('read_nmdstat')->();
    is($st->{mdState}, 'STARTED', 'read_nmdstat reads the seam path');
    is($st->{'diskName.1'}, 'nmd1p1', 'disk fields present');

    local $ENV{PROC_NMDSTAT} = "$fixtures/does-not-exist";
    is($P->can('read_nmdstat')->(), undef, 'missing file -> undef (module not loaded)');
}

# api() standalone (no PVE::Storage loaded)
is($P->api(), 15, 'api() returns tested version standalone');
is($P->type(), 'nonraid', 'type');

# schema consistency: every nonraid-* option is declared in properties,
# and no property is missing from options.
{
    my $props = $P->properties();
    my $opts = $P->options();
    for my $key (grep { /^nonraid-/ } keys %$opts) {
        ok(exists $props->{$key}, "option $key declared in properties");
    }
    for my $key (keys %$props) {
        ok(exists $opts->{$key}, "property $key listed in options");
    }
    is($opts->{path}->{fixed}, 1, 'path is fixed');
    ok(!exists $opts->{shared}, 'shared deliberately not offered');
    ok(!exists $opts->{is_mountpoint}, 'is_mountpoint deliberately not offered');
}

# plugindata shape
{
    my $pd = $P->plugindata();
    is($pd->{format}->[1], 'qcow2', 'default format is qcow2');
    ok($pd->{content}->[0]->{images}, 'images content supported');
    is_deeply($pd->{'sensitive-properties'}, {}, 'sensitive-properties declared empty');
}

done_testing();
