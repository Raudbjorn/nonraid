#!/bin/bash
# Create loop-backed virtual disks for testing NonRAID.
#
# Touches only: files under $WORKDIR, the loop devices it attaches to them, and
# /dev/disk/by-id symlinks it creates itself (required, because nmdctl resolves
# array members through by-id). Every link it creates is recorded so teardown
# removes exactly those and not a prefix-wide glob.
set -euo pipefail

# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_root
validate_config
# btrfs-progs is checked rather than installed: a test helper should not mutate
# the host's package set behind the user's back.
require_cmd losetup sgdisk udevadm lsblk mkfs.btrfs truncate partprobe blkid

# Claim WORKDIR exclusively. Reusing an arbitrary existing directory would let
# teardown delete pre-existing files that happen to match the image pattern.
if [ -e "$WORKDIR" ] && [ ! -e "$OWNED_MARKER" ]; then
    die "$WORKDIR exists but was not created by this harness (no $OWNED_MARKER); refusing to adopt it"
fi
mkdir -p "$WORKDIR"
touch "$OWNED_MARKER"
# Appended to, never truncated. The rest of this script is written to be re-run
# over an existing owned workdir - it skips images, partitioning and mkfs that
# are already there - and the by-id links from the previous run still exist. A
# truncated manifest would make the ownership check below reject them, and would
# also strand links from a run with a higher disk count.
touch "$OWNED_LINKS"
cd "$WORKDIR"

echo ">>> [setup] $DISK_COUNT disks of ${SIZE_MB}MB in $WORKDIR"

for i in $(seq 1 "$DISK_COUNT"); do
    img="d$i"
    linkname="${BYID_PREFIX}$(printf '%03d' "$i")"

    if [ ! -f "$img" ]; then
        echo "Creating $img (${SIZE_MB} MB)..."
        truncate -s "${SIZE_MB}M" "$img"
    fi

    # An image can be attached to more than one loop device. Picking one
    # arbitrarily means operating on whichever mapping happened to sort first -
    # possibly another process's - and everything below (partitioning, mkfs,
    # the by-id alias) would then be aimed at it. Ambiguity is refused.
    existing=$(losetup -j "$img" | cut -d: -f1)
    count=$(printf '%s\n' "$existing" | grep -c . || true)
    if [ "$count" -gt 1 ]; then
        die "$img is attached to $count loop devices ($(printf '%s' "$existing" | tr '\n' ' ')); detach the extras before re-running"
    fi
    loop_dev="$existing"
    if [ -z "$loop_dev" ]; then
        loop_dev=$(losetup -fP --show "$img")
    fi
    echo "Disk $i -> $loop_dev"

    # Partition only if there is no usable partition yet. Re-running setup must
    # not repartition an image that already carries a test array, and must not
    # skip an image left half-initialised by an interrupted earlier run.
    if [ ! -b "${loop_dev}p1" ]; then
        sgdisk -o -a 8 -n 1:32K:0 "$loop_dev" >/dev/null
        partprobe "$loop_dev" 2>/dev/null || true
        udevadm settle
    fi

    # Disks 3+ are data disks; 1 and 2 stay zeroed as parity. Decide from the
    # actual on-disk state, not from whether this run created the image - an
    # interruption between truncate and mkfs would otherwise skip formatting
    # permanently.
    if [ "$i" -ge 3 ] && [ -b "${loop_dev}p1" ] && ! blkid "${loop_dev}p1" >/dev/null 2>&1; then
        echo "Formatting ${loop_dev}p1 as btrfs..."
        mkfs.btrfs -f -L "data$((i - 2))" "${loop_dev}p1" >/dev/null
    fi

    # Never clobber an existing by-id alias: it could belong to a real disk.
    # -L as well as -e, or a dangling symlink (a real disk that is currently
    # detached) reads as absent and the ln -sf below silently repoints it.
    if { [ -e "/dev/disk/by-id/$linkname" ] || [ -L "/dev/disk/by-id/$linkname" ]; } &&
       ! grep -qxF "/dev/disk/by-id/$linkname" "$OWNED_LINKS" 2>/dev/null; then
        die "/dev/disk/by-id/$linkname already exists and is not ours; choose another NONRAID_TEST_PREFIX"
    fi
    # -f only after re-proving ownership. The check above already refuses a
    # link that is not ours, but an unconditional 'ln -sf' fallback would also
    # take anything that appeared in between - and the whole point of the
    # check is that this path can point at a real disk.
    if ! ln -s "$loop_dev" "/dev/disk/by-id/$linkname" 2>/dev/null; then
        grep -qxF "/dev/disk/by-id/$linkname" "$OWNED_LINKS" 2>/dev/null ||
            die "/dev/disk/by-id/$linkname appeared and is not ours; refusing to replace it"
        ln -sf "$loop_dev" "/dev/disk/by-id/$linkname"
    fi
    # Once each: a re-run repoints the same link and must not duplicate the entry.
    grep -qxF "/dev/disk/by-id/$linkname" "$OWNED_LINKS" 2>/dev/null || \
        echo "/dev/disk/by-id/$linkname" >> "$OWNED_LINKS"
done

udevadm settle

echo
lsblk
echo
while read -r l; do
    [ -e "$l" ] && printf '  %s -> %s\n' "$l" "$(readlink -f "$l")"
done < "$OWNED_LINKS"
echo ">>> [setup] complete. Superblock will be $SUPERBLOCK_FILE"
echo ">>> [setup] offsets recorded in $DISK_OFFSETS_FILE"
