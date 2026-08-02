#!/bin/bash
# Build a NonRAID array on the loop devices created by setup_disk.sh.
#
# Uses dual parity (P + Q) plus the remaining disks as data. Members are named
# by their /dev/disk/by-id symlinks, and imported at an explicit offset so this
# also exercises the offset path.
set -euo pipefail

# shellcheck source=test/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_root
validate_config
require_cmd losetup

OFFSET="$TEST_OFFSET"

byid() { echo "/dev/disk/by-id/${BYID_PREFIX}$(printf '%03d' "$1")"; }

# P and Q take slots 0 and 29; data disks start at slot 1.
layout=("P:$(byid 1):${BYID_PREFIX}001:$OFFSET" "Q:$(byid 2):${BYID_PREFIX}002:$OFFSET")
for i in $(seq 3 "$DISK_COUNT"); do
    layout+=("$((i - 2)):$(byid "$i"):${BYID_PREFIX}$(printf '%03d' "$i"):$OFFSET")
done

# Every member is checked before any of them reaches the driver: `create
# --force` below skips nmdctl's availability validation, so a prefix colliding
# with real host links would otherwise import real disks at an offset.
for i in $(seq 1 "$DISK_COUNT"); do
    require_owned_link "$(byid "$i")"
done

echo ">>> [mk_array] creating array: ${layout[*]}"
nmd create --force "${layout[@]}"

echo ">>> [mk_array] starting"
nmd -u start new_array

echo ">>> [mk_array] parity sync"
nmd -u check recon
wait_resync_idle 600

echo ">>> [mk_array] mounting"
nmd -u mount "$MOUNT_PREFIX"

echo ">>> [mk_array] status"
nmd --no-color status

echo ">>> [mk_array] complete"
