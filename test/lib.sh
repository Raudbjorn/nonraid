#!/bin/bash
# Shared settings for the loop-device test harness.
#
# Everything is overridable from the environment so the harness never writes to
# a path it was not told about. Defaults match the original scripts.
#
# shellcheck disable=SC2034  # these are consumed by the scripts that source this

WORKDIR="${NONRAID_TEST_WORKDIR:-/root/nonraid-test}"
DISK_COUNT="${NONRAID_TEST_DISKS:-4}"
SIZE_MB="${NONRAID_TEST_SIZE_MB:-256}"
BYID_PREFIX="${NONRAID_TEST_PREFIX:-virtdisk-}"
MOUNT_PREFIX="${NONRAID_TEST_MOUNT_PREFIX:-/mnt/disk}"
SUPERBLOCK_FILE="${NONRAID_TEST_SUPERBLOCK:-$WORKDIR/nonraid.dat}"

# Marker written next to the superblock. teardown refuses to delete anything it
# cannot prove this harness created - the original script removed /nonraid.dat
# unconditionally, which on a machine with a real array destroys the array
# configuration.
OWNED_MARKER="$WORKDIR/.nonraid-test-owned"

NMDCTL="${NMDCTL:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tools/nmdctl}"

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root (sudo)" >&2
        exit 1
    fi
}

require_cmd() {
    local missing=0
    for c in "$@"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            echo "Missing required command: $c" >&2
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || exit 1
}

# nmdctl is always invoked with the harness superblock, never the system one.
nmd() {
    "$NMDCTL" -s "$SUPERBLOCK_FILE" "$@"
}
