#!/bin/bash
# Create loop-backed virtual disks for testing NonRAID.
#
# Touches only files under $WORKDIR and the loop devices it creates. See lib.sh
# for the environment variables that override the defaults.
set -euo pipefail

# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_root
# btrfs-progs is checked rather than installed: a test helper should not mutate
# the host's package set behind the user's back.
require_cmd losetup sgdisk udevadm lsblk mkfs.btrfs

mkdir -p "$WORKDIR"
# Marks this WORKDIR as harness-owned so teardown will clean it up.
touch "$OWNED_MARKER"
cd "$WORKDIR"

echo ">>> [setup] $DISK_COUNT disks of ${SIZE_MB}MB in $WORKDIR"

for i in $(seq 1 "$DISK_COUNT"); do
    img="d$i"
    linkname="${BYID_PREFIX}$(printf '%03d' "$i")"
    new_image=0

    if [ ! -f "$img" ]; then
        echo "Creating $img (${SIZE_MB} MB)..."
        truncate -s "${SIZE_MB}M" "$img"
        new_image=1
    fi

    loop_dev=$(losetup -j "$img" | cut -d: -f1)
    if [ -z "$loop_dev" ]; then
        loop_dev=$(losetup -fP --show "$img")
    fi
    echo "Disk $i -> $loop_dev"

    # GPT, 32K-aligned, single partition to end of disk - the layout the driver
    # expects for a partition-based import.
    sgdisk -o -a 8 -n 1:32K:0 "$loop_dev" >/dev/null
    partprobe "$loop_dev" 2>/dev/null || true
    udevadm settle

    # Disks 3+ are data disks; 1 and 2 stay zeroed as parity.
    if [ "$i" -ge 3 ] && [ "$new_image" -eq 1 ]; then
        echo "Formatting ${loop_dev}p1 as btrfs..."
        mkfs.btrfs -f -L "data$((i - 2))" "${loop_dev}p1" >/dev/null
    fi

    # nmdctl resolves array members through /dev/disk/by-id
    ln -sf "$loop_dev" "/dev/disk/by-id/$linkname"
done

udevadm settle

echo
lsblk
echo
for l in /dev/disk/by-id/"${BYID_PREFIX}"*; do
    [ -e "$l" ] && printf '  %s -> %s\n' "$l" "$(readlink -f "$l")"
done
echo ">>> [setup] complete. Superblock will be $SUPERBLOCK_FILE"
