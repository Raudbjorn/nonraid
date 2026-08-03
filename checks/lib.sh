#!/bin/sh
# Shared plumbing for the local CI checks. These scripts ARE the CI: GitHub
# Actions is deliberately disabled on this fork, so what runs here, wired into
# .githooks/pre-push, is the only gate a push passes through.
# shellcheck disable=SC2034  # consumers use these

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "checks: not inside the repository" >&2
    exit 1
}

IMAGE="nonraid-checks:trixie"

need() {
    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 || {
            echo "checks: '$t' is required for this check and is not installed" >&2
            exit 1
        }
    done
}

# One prebuilt image instead of apt-get on every run: the toolchain plus the
# PVE repository (needed to resolve libpve-storage-perl) is ~5 minutes cold,
# and a pre-push hook that costs 5 minutes gets bypassed until it is deleted.
# With the image cached, the heavy checks run in tens of seconds.
ensure_image() {
    need docker
    docker image inspect "$IMAGE" >/dev/null 2>&1 && return 0
    echo ">>> building $IMAGE (one-time, ~5 min)" >&2
    docker build -t "$IMAGE" -f - "$ROOT" <<'DOCKERFILE'
FROM debian:13
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        build-essential debhelper fakeroot devscripts dh-dkms dkms \
        curl ca-certificates perl gdisk shellcheck mergerfs \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /usr/share/keyrings/proxmox-archive-keyring.gpg \
        https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg \
    && printf 'Types: deb\nURIs: http://download.proxmox.com/debian/pve\nSuites: trixie\nComponents: pve-no-subscription\nSigned-By: /usr/share/keyrings/proxmox-archive-keyring.gpg\n' \
        > /etc/apt/sources.list.d/pve.sources \
    && apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends libpve-storage-perl \
    && rm -rf /var/lib/apt/lists/*
DOCKERFILE
}

# Run a script in the image against a throwaway copy of the tree. The copy
# matters: dpkg-buildpackage writes into the source directory, and a check
# must not dirty the working tree it is checking.
in_image() {
    ensure_image
    docker run --rm -v "$ROOT:/src:ro" -w /work "$IMAGE" sh -ec '
        # tar, not cp -a: the source is a bind mount whose host filesystem
        # carries ACLs/xattrs the container cannot re-create, and cp -a treats
        # that as an error. Mode and content are all a build needs.
        mkdir /work/tree
        tar -C /src --exclude=.git -cf - . | tar -C /work/tree -xf -
        cd /work/tree
        '"$1"
}
