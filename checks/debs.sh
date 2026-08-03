#!/bin/sh
# Package tier: build all three Debian packages from a clean copy of the tree
# and sanity-check what came out. Mirrors the tools-debian workflow, the
# package job in ci.yml, and pve-plugin-tests' build step.
set -eu
# shellcheck source=checks/lib.sh
. "$(dirname "$0")/lib.sh"

# shellcheck disable=SC2016  # the script body expands inside the container
in_image '
    # Through the documented targets, not a bare dpkg-buildpackage: they are
    # what the README tells people to run, and they collect artifacts into
    # out/ instead of scattering them into the parent of the checkout (which
    # for a tree directly under / means the filesystem root).
    echo ">>> nonraid-dkms (make package-native)"
    make package-native >/dev/null 2>&1

    echo ">>> libpve-storage-nonraid-perl (make package-plugin)"
    make package-plugin >/dev/null 2>&1

    echo ">>> nonraid-tools (bare build: units are committed, rules checks the manifest)"
    VERSION=$(grep "^VERSION=" tools/nmdctl | head -1 | cut -d= -f2 | tr -d "\"")
    test -n "$VERSION"
    cd tools && dpkg-buildpackage -b -us -uc >/dev/null 2>&1 && cd ..
    deb=$(ls ../nonraid-tools_*.deb nonraid-tools_*.deb 2>/dev/null | head -1)
    dpkg-deb -I "$deb" | grep -q "Version: $VERSION-1"

    # Nothing may land outside the tree: that is the whole point of OUTDIR.
    for stray in ../nonraid-dkms_*.deb ../libpve-storage-nonraid-perl_*.deb; do
        [ -e "$stray" ] && { echo "artifact escaped to the parent: $stray" >&2; exit 1; }
    done

    test -f out/nonraid-dkms_*.deb
    test -f out/libpve-storage-nonraid-perl_*.deb
    echo "artifacts in out/: $(ls out/ | tr "\n" " ")"
    echo "plus nonraid-tools: $(basename "$deb")"
'
