#!/bin/bash
# Tear down the loop-device test setup created by setup_disk.sh.
#
# Refuses to touch anything it cannot prove this harness created. The original
# version removed /nonraid.dat unconditionally, which on a machine running a
# real array deletes the array configuration.
set -uo pipefail

# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_root

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

if [ ! -e "$OWNED_MARKER" ] && [ "$FORCE" -eq 0 ]; then
    echo "Refusing to tear down: $OWNED_MARKER not found." >&2
    echo "  $WORKDIR was not created by setup_disk.sh, so its contents and" >&2
    echo "  $SUPERBLOCK_FILE are not this harness's to delete." >&2
    echo "  Re-run with --force if you are certain." >&2
    exit 1
fi

echo "=== unmounting ==="
nmd -u umount "$MOUNT_PREFIX" 2>/dev/null && echo "  unmounted" || echo "  nothing to unmount"

echo "=== stopping array ==="
nmd -u stop 2>/dev/null && echo "  stopped" || echo "  not running"

echo "=== unloading modules ==="
modprobe -r md_nonraid 2>/dev/null && echo "  md_nonraid unloaded" || echo "  md_nonraid not loaded / busy"
modprobe -r nonraid6_pq 2>/dev/null && echo "  nonraid6_pq unloaded" || echo "  nonraid6_pq not loaded / busy"

echo "=== removing superblock ==="
if [ -f "$SUPERBLOCK_FILE" ]; then
    rm -f "$SUPERBLOCK_FILE" && echo "  removed $SUPERBLOCK_FILE"
else
    echo "  $SUPERBLOCK_FILE not present"
fi

echo "=== detaching loop devices and removing by-id symlinks ==="
for link in /dev/disk/by-id/"${BYID_PREFIX}"*; do
    [ -e "$link" ] || continue
    target=$(readlink -f "$link")
    echo "  $link -> $target"
    if [ -b "$target" ]; then
        losetup -d "$target" 2>/dev/null && echo "    detached" || echo "    could not detach (busy?)"
    fi
    rm -f "$link"
done

echo "=== sweeping leftover loops backed by $WORKDIR ==="
while read -r dev backing; do
    [ -n "$dev" ] || continue
    case "$backing" in
        "$WORKDIR"/*)
            echo "  detaching $dev ($backing)"
            losetup -d "$dev" 2>/dev/null || echo "    failed"
            ;;
    esac
done < <(losetup -a | sed 's/:.*(\(.*\))$/ \1/')

echo "=== removing images ==="
for img in "$WORKDIR"/d[0-9]*; do
    [ -e "$img" ] || continue
    rm -f "$img" && echo "  removed $img"
done
rm -f "$OWNED_MARKER"
rmdir "$WORKDIR" 2>/dev/null && echo "  removed $WORKDIR" || echo "  $WORKDIR not empty, left in place"

echo "=== removing empty mountpoints ==="
for d in "${MOUNT_PREFIX}"*; do
    [ -d "$d" ] || continue
    rmdir "$d" 2>/dev/null && echo "  removed $d"
done

udevadm settle 2>/dev/null

echo "=== done ==="
losetup -a | grep -c "$WORKDIR" | xargs echo "  loops left backed by workdir:"
left=0
for l in /dev/disk/by-id/"${BYID_PREFIX}"*; do
    [ -e "$l" ] && left=$((left + 1))
done
echo "  by-id symlinks left: $left"
