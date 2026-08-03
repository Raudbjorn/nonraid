#!/bin/sh
# Package tier: build all three Debian packages from a clean copy of the tree
# and sanity-check what came out. Mirrors the tools-debian workflow, the
# package job in ci.yml, and pve-plugin-tests' build step.
set -eu
# shellcheck source=checks/lib.sh
. "$(dirname "$0")/lib.sh"

# shellcheck disable=SC2016  # the script body expands inside the container
in_image '
    echo ">>> nonraid-dkms"
    dpkg-buildpackage -b -us -uc -d >/dev/null 2>&1
    test -f ../nonraid-dkms_*.deb

    echo ">>> nonraid-tools (bare build: units are committed, rules checks the manifest)"
    VERSION=$(grep "^VERSION=" tools/nmdctl | cut -d= -f2 | tr -d "\"")
    test -n "$VERSION"
    cd tools && dpkg-buildpackage -b -us -uc >/dev/null 2>&1 && cd ..
    deb=$(ls nonraid-tools_*.deb | head -1)
    dpkg-deb -I "$deb" | grep -q "Version: $VERSION-1"

    echo ">>> libpve-storage-nonraid-perl"
    cd pve-plugin && dpkg-buildpackage -b -us -uc -d >/dev/null 2>&1 && cd ..
    test -f libpve-storage-nonraid-perl_*.deb
    echo "all three packages built: $(ls *.deb ../*.deb 2>/dev/null | xargs -n1 basename | tr "\n" " ")"
'
