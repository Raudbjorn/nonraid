# SPDX-License-Identifier: AGPL-3.0-or-later
package File::ExtAttr;

use strict;
use warnings;

our $GETFATTR_CB;

sub getfattr {
    die "File::ExtAttr::getfattr test callback is not configured\n" if !$GETFATTR_CB;
    return $GETFATTR_CB->(@_);
}

1;
