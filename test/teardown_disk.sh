#!/bin/bash
# Tear down the loop-device test setup created by setup_disk.sh.
#
# Refuses to touch anything it cannot prove this harness created, and refuses to
# delete backing state until the array is verifiably stopped and every loop it
# owns is detached. Exits non-zero on incomplete cleanup so a caller can retry.
set -uo pipefail

# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_root
validate_config

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

if [ ! -e "$OWNED_MARKER" ] && [ "$FORCE" -eq 0 ]; then
    echo "Refusing to tear down: $OWNED_MARKER not found." >&2
    echo "  $WORKDIR was not created by setup_disk.sh, so its contents and" >&2
    echo "  $SUPERBLOCK_FILE are not this harness's to delete." >&2
    echo "  Re-run with --force if you are certain." >&2
    exit 1
fi

failed=0

echo "=== unmounting ==="
nmd -u umount "$MOUNT_PREFIX" >/dev/null 2>&1 && echo "  unmounted" || echo "  nothing to unmount"

echo "=== stopping array ==="
nmd -u stop >/dev/null 2>&1 && echo "  stopped" || echo "  stop returned non-zero"

# A failed stop must not be read as "was not running". Verify from the driver
# before deleting anything: destroying the superblock under a live array would
# leave it running with no way to reproduce its configuration.
if [ -r /proc/nmdstat ] && grep -q "mdState=STARTED" /proc/nmdstat; then
    if [ "$FORCE" -eq 0 ]; then
        echo "Refusing to continue: the array is still STARTED." >&2
        echo "  Stop it before tearing down, or re-run with --force." >&2
        exit 1
    fi
    echo "  WARNING: array still STARTED, continuing because --force" >&2
fi

echo "=== unloading modules ==="
modprobe -r md_nonraid 2>/dev/null && echo "  md_nonraid unloaded" || echo "  md_nonraid not loaded / busy"
modprobe -r nonraid6_pq 2>/dev/null && echo "  nonraid6_pq unloaded" || echo "  nonraid6_pq not loaded / busy"

echo "=== detaching loop devices and removing the by-id links we created ==="
if [ -f "$OWNED_LINKS" ]; then
    while read -r link; do
        [ -n "$link" ] || continue
        if [ -e "$link" ]; then
            target=$(readlink -f "$link")
            if [ -b "$target" ]; then
                if losetup -d "$target" 2>/dev/null; then
                    echo "  detached $target"
                else
                    echo "  could not detach $target (busy?)" >&2
                    failed=1
                fi
            fi
            rm -f "$link"
        fi
    done < "$OWNED_LINKS"
else
    echo "  no link manifest; skipping (nothing proven ours)"
fi

echo "=== sweeping loops still backed by $WORKDIR ==="
while read -r dev backing; do
    [ -n "$dev" ] || continue
    case "$backing" in
        "$WORKDIR"/*)
            if losetup -d "$dev" 2>/dev/null; then
                echo "  detached $dev ($backing)"
            else
                echo "  could not detach $dev ($backing)" >&2
                failed=1
            fi
            ;;
    esac
    # --raw -O is stable output; parsing `losetup -a` breaks on parens in paths.
done < <(losetup --raw -n -O NAME,BACK-FILE 2>/dev/null)

# Backing images and the provenance marker are only removed once every loop we
# own is gone. Deleting them while a loop is still attached leaves a busy loop
# pointing at a deleted file and destroys the evidence needed to retry.
if [ "$failed" -ne 0 ]; then
    echo "=== incomplete: leaving images, superblock and marker in place for retry ===" >&2
    exit 1
fi

echo "=== removing superblock and offsets ==="
rm -f "$SUPERBLOCK_FILE" && echo "  removed $SUPERBLOCK_FILE"
rm -f "$DISK_OFFSETS_FILE" && echo "  removed $DISK_OFFSETS_FILE"

echo "=== removing images ==="
for img in "$WORKDIR"/d[0-9]*; do
    [ -e "$img" ] || continue
    rm -f "$img" && echo "  removed $img"
done
rm -f "$OWNED_MARKER" "$OWNED_LINKS"
rmdir "$WORKDIR" 2>/dev/null && echo "  removed $WORKDIR" || echo "  $WORKDIR not empty, left in place"

echo "=== removing empty mountpoints ==="
for d in "${MOUNT_PREFIX}"*; do
    [ -d "$d" ] || continue
    rmdir "$d" 2>/dev/null && echo "  removed $d"
done

udevadm settle 2>/dev/null

echo "=== done ==="
echo "  loops still backed by workdir: $(losetup --raw -n -O BACK-FILE 2>/dev/null | grep -cF "$WORKDIR")"
