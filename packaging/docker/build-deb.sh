#!/bin/sh
# Build the nonraid-dkms .deb from a read-only source mount.
#
#   /src  read-only bind mount of the working tree
#   /out  directory the finished artifacts are written to
#
# OUT_UID/OUT_GID own the artifacts. Under rootful Docker the caller passes its
# real uid/gid, because container root would otherwise leave root-owned files on
# the host. Under rootless Docker or Podman the caller passes 0, since container
# root already maps to the invoking user and a real uid would map to a
# subordinate id the user cannot easily read or delete.
set -eu

: "${OUT_UID:=0}"
: "${OUT_GID:=0}"

[ -d /src ] || { echo "build-deb: /src is not mounted" >&2; exit 1; }
[ -d /out ] || { echo "build-deb: /out is not mounted" >&2; exit 1; }

# dh_install uses 'cp -a', which fails with ENODATA when it tries to write ACLs
# onto a bind mount, so the tree is copied out of /src before building.
#
# Build products are excluded as well: debian/rules stubs out dh_auto_clean and
# nonraid-dkms.install ships md_nonraid/ and raid6/ as whole directories, so a
# stale *.ko or *.o left by an earlier 'make modules' would be installed into
# /usr/src - the very directory DKMS then runs 'make modules' in.
mkdir -p /work
tar -C /src \
    --exclude=.git \
    --exclude='*.ko' \
    --exclude='*.o' \
    --exclude='.*.cmd' \
    --exclude=Module.symvers \
    --exclude=modules.order \
    -cf - . | tar -C /work -xf -

cd /work
dpkg-buildpackage -b -rfakeroot -us -uc

# dpkg-buildpackage writes to the parent of the source directory, i.e. /.
found=0
for f in /*.deb /*.changes /*.buildinfo; do
    [ -e "$f" ] || continue
    install -m 0644 -o "$OUT_UID" -g "$OUT_GID" "$f" /out/
    found=$((found + 1))
done

if [ "$found" -eq 0 ]; then
    echo "build-deb: dpkg-buildpackage produced no artifacts" >&2
    exit 1
fi
