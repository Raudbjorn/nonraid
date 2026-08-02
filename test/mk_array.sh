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
require_cmd losetup

OFFSET="${NONRAID_TEST_OFFSET:-64}"

if [ "$DISK_COUNT" -lt 3 ]; then
    echo "Need at least 3 disks (P, Q and one data disk); have $DISK_COUNT" >&2
    exit 1
fi

byid() { echo "/dev/disk/by-id/${BYID_PREFIX}$(printf '%03d' "$1")"; }

# P and Q take slots 0 and 29; data disks start at slot 1.
layout=("P:$(byid 1):${BYID_PREFIX}001:$OFFSET" "Q:$(byid 2):${BYID_PREFIX}002:$OFFSET")
for i in $(seq 3 "$DISK_COUNT"); do
    layout+=("$((i - 2)):$(byid "$i"):${BYID_PREFIX}$(printf '%03d' "$i"):$OFFSET")
done

echo ">>> [mk_array] creating array: ${layout[*]}"
nmd create --force "${layout[@]}"

echo ">>> [mk_array] starting"
nmd -u start new_array

echo ">>> [mk_array] parity sync"
nmd -u check recon
while ! grep -q "mdResync=0" /proc/nmdstat; do sleep 2; done

echo ">>> [mk_array] mounting"
nmd -u mount "$MOUNT_PREFIX"

echo ">>> [mk_array] status"
nmd --no-color status

echo ">>> [mk_array] complete"
