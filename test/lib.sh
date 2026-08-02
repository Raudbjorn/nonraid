#!/bin/bash
# Shared settings and safety checks for the loop-device test harness.
#
# Everything is overridable from the environment, so every override is validated
# here rather than trusted. The harness runs as root and deletes things; an
# empty or out-of-tree value would turn a cleanup glob into a system-wide one.
#
# shellcheck disable=SC2034  # consumed by the scripts that source this

set -uo pipefail

WORKDIR="${NONRAID_TEST_WORKDIR:-/root/nonraid-test}"
DISK_COUNT="${NONRAID_TEST_DISKS:-4}"
SIZE_MB="${NONRAID_TEST_SIZE_MB:-256}"
BYID_PREFIX="${NONRAID_TEST_PREFIX:-virtdisk-}"
MOUNT_PREFIX="${NONRAID_TEST_MOUNT_PREFIX:-/mnt/disk}"
SUPERBLOCK_FILE="${NONRAID_TEST_SUPERBLOCK:-$WORKDIR/nonraid.dat}"
TEST_OFFSET="${NONRAID_TEST_OFFSET:-64}"

# Keep the harness's offset records out of the host's real array state.
# nmdctl defaults this to /etc/nonraid/disk-offsets; mk_array.sh imports at a
# nonzero offset, so without this the harness writes entries into the real file
# and teardown - which deletes this path - would destroy the offsets of a live
# array.
#
# Deliberately not `${DISK_OFFSETS_FILE:-...}`: DISK_OFFSETS_FILE is nmdctl's
# own override, so anyone pointing it at the system file for normal use would
# have that value inherited here and deleted on teardown. The harness sets it
# outright, and its own override is validated below like every other one.
OFFSETS_FILE="${NONRAID_TEST_OFFSETS_FILE:-$WORKDIR/disk-offsets}"
export DISK_OFFSETS_FILE="$OFFSETS_FILE"

# Written by setup_disk.sh. teardown refuses to delete anything without it, and
# it also lists exactly which by-id links and images this run created, so
# cleanup never works from a prefix-wide glob.
OWNED_MARKER="$WORKDIR/.nonraid-test-owned"
OWNED_LINKS="$WORKDIR/.nonraid-test-links"

NMDCTL="${NMDCTL:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tools/nmdctl}"

die() { echo "$*" >&2; exit 1; }

require_root() {
    [ "$EUID" -eq 0 ] || die "Please run as root (sudo)"
}

require_cmd() {
    local missing=0 c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || { echo "Missing required command: $c" >&2; missing=1; }
    done
    [ "$missing" -eq 0 ] || exit 1
}

# Reject configuration that would make a cleanup glob dangerous. Called by every
# script before it touches anything.
validate_config() {
    [ -n "$WORKDIR" ]      || die "NONRAID_TEST_WORKDIR must not be empty"
    [ -n "$SUPERBLOCK_FILE" ] || die "NONRAID_TEST_SUPERBLOCK must not be empty"

    # The prefix becomes a filename directly under /dev/disk/by-id and a line in
    # the ownership manifest, so non-emptiness is not enough: a value containing
    # a slash escapes that directory entirely, and whitespace or a newline
    # corrupts the line-based manifest that teardown reads back.
    [ -n "$BYID_PREFIX" ] || die "NONRAID_TEST_PREFIX must not be empty: cleanup would match every by-id link on the host"
    [[ "$BYID_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
        die "NONRAID_TEST_PREFIX ('$BYID_PREFIX') must be a plain name prefix: [A-Za-z0-9][A-Za-z0-9._-]*"

    # Mount points are formed as ${MOUNT_PREFIX}<slot>, so the prefix must be an
    # absolute path with a non-empty final component - '/' or '/mnt/' would put
    # the harness's rmdir loop on directories it never created.
    [ -n "$MOUNT_PREFIX" ] || die "NONRAID_TEST_MOUNT_PREFIX must not be empty: cleanup would rmdir every empty directory in \$PWD"
    case "$MOUNT_PREFIX" in
        /*/?*) ;;
        *) die "NONRAID_TEST_MOUNT_PREFIX ('$MOUNT_PREFIX') must be an absolute path with a non-empty final component" ;;
    esac
    if [[ "$MOUNT_PREFIX" =~ [[:space:]] ]]; then
        die "NONRAID_TEST_MOUNT_PREFIX ('$MOUNT_PREFIX') must not contain whitespace"
    fi

    case "$WORKDIR" in
        /|/dev|/etc|/usr|/var|/home|/boot|/root) die "refusing to use $WORKDIR as the test workdir" ;;
        /*) ;;
        *) die "NONRAID_TEST_WORKDIR must be an absolute path" ;;
    esac

    [[ "$DISK_COUNT" =~ ^[0-9]+$ ]] || die "NONRAID_TEST_DISKS must be a number"
    # Slot 0 is P and slot 29 is Q, so data slots are 1..28: at most 30 members.
    [ "$DISK_COUNT" -ge 3 ] || die "need at least 3 disks (P, Q and one data disk)"
    [ "$DISK_COUNT" -le 30 ] || die "at most 30 disks (P + Q + 28 data slots)"

    # The superblock and the offsets file must live inside the directory this
    # harness owns, or teardown would delete files it did not create - a real
    # /nonraid.dat, or the offsets of a live array.
    local wd_real
    wd_real=$(readlink -m "$WORKDIR")
    require_inside_workdir "$wd_real" "$SUPERBLOCK_FILE" NONRAID_TEST_SUPERBLOCK
    require_inside_workdir "$wd_real" "$OFFSETS_FILE" NONRAID_TEST_OFFSETS_FILE
}

# Usage: require_inside_workdir <resolved workdir> <path> <variable name>
require_inside_workdir() {
    local wd_real="$1" path="$2" varname="$3" resolved
    [ -n "$path" ] || die "$varname must not be empty"
    resolved=$(readlink -m "$path")
    case "$resolved/" in
        "$wd_real"/*) ;;
        *) die "$varname ($resolved) must be inside NONRAID_TEST_WORKDIR ($wd_real)" ;;
    esac
}

# Refuse a /dev/disk/by-id link this harness did not create.
#
# mk_array.sh hands its members to `create --force`, which skips nmdctl's own
# device-availability check, so running it against a prefix that happens to
# match real host links would import real disks. Ownership is proven three
# ways rather than assumed from the prefix: setup_disk.sh's marker exists, the
# link is in the manifest that setup wrote, and the link resolves to a loop
# device whose backing file is inside WORKDIR.
require_owned_link() {
    local link="$1" target backing backing_real wd_real

    [ -e "$OWNED_MARKER" ] ||
        die "$OWNED_MARKER not found: run setup_disk.sh first (this is not a workdir the harness created)"
    [ -f "$OWNED_LINKS" ] ||
        die "$OWNED_LINKS not found: run setup_disk.sh first"
    grep -qxF "$link" "$OWNED_LINKS" ||
        die "$link is not one of the links setup_disk.sh created - refusing to hand it to the driver"

    target=$(readlink -f "$link") || die "$link does not resolve"
    [ -b "$target" ] || die "$link does not resolve to a block device (got '$target')"

    backing=$(losetup --raw -n -O BACK-FILE "$target" 2>/dev/null | head -1)
    [ -n "$backing" ] || die "$link ($target) is not a loop device"

    wd_real=$(readlink -m "$WORKDIR")
    backing_real=$(readlink -m "$backing")
    case "$backing_real/" in
        "$wd_real"/*) ;;
        *) die "$link is backed by $backing_real, outside $wd_real" ;;
    esac
}

# nmdctl always runs against the harness superblock, never the system one.
nmd() {
    "$NMDCTL" -s "$SUPERBLOCK_FILE" "$@"
}

# Wait for a resync to start, bounded.
#
# `nmdctl check` returns as soon as the driver accepts the command, and
# /proc/nmdstat can still report mdResync=0 at that moment. Without this, a
# following wait_resync_idle matches on its first poll and the caller proceeds -
# mounting and checksumming an array that never synced.
wait_resync_started() {
    local timeout="${1:-60}" waited=0
    while true; do
        [ -r /proc/nmdstat ] || die "/proc/nmdstat is not readable - is the module loaded?"
        grep -q "mdResync=0" /proc/nmdstat || return 0
        sleep 1
        waited=$((waited + 1))
        [ "$waited" -ge "$timeout" ] && die "resync never started within ${timeout}s"
    done
}

# Wait for the driver to report no resync in progress, bounded.
# A bare `while ! grep -q ...` turns an unreadable /proc/nmdstat into a
# successful loop condition and spins forever.
#
# Waits for the operation to start first, so this cannot return success against
# a resync that has not begun.
wait_resync_idle() {
    local timeout="${1:-600}" waited=0
    wait_resync_started
    while true; do
        [ -r /proc/nmdstat ] || die "/proc/nmdstat is not readable - is the module loaded?"
        grep -q "mdResync=0" /proc/nmdstat && return 0
        sleep 2
        waited=$((waited + 2))
        [ "$waited" -ge "$timeout" ] && die "timed out after ${timeout}s waiting for resync to finish"
    done
}
