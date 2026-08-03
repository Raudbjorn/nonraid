#!/bin/sh
# Offline test for bin/pve-nonraid-teardown: a fake /proc/mounts, a fake
# nmdctl, and a marker file in a temp dir. Covers the property that matters -
# the marker survives a failed teardown - without needing an array.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../bin/pve-nonraid-teardown"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# A fake nmdctl that succeeds or fails on demand and records its arguments.
make_nmdctl() {
    cat > "$tmp/nmdctl" <<EOF
#!/bin/sh
echo "\$@" >> "$tmp/nmdctl.log"
exit ${1:-0}
EOF
    chmod +x "$tmp/nmdctl"
    : > "$tmp/nmdctl.log"
}

# umount is called on real paths, so the pools in the fake /proc/mounts point
# at directories that are not mounted - umount fails, which is the "busy pool"
# case. For the success case there are no pools at all.
run() { PVE_NONRAID_MOUNTS="$tmp/mounts" PVE_NONRAID_NMDCTL="$tmp/nmdctl" \
        PVE_NONRAID_MARKER="$tmp/array.running" sh "$script" 2>"$tmp/err"; }

# --- clean teardown: no pools, nmdctl succeeds -> marker removed ------------
make_nmdctl 0
: > "$tmp/array.running"
cat > "$tmp/mounts" <<'EOF'
/dev/nmd1p1 /mnt/disk1 xfs rw 0 0
EOF
run || fail "clean teardown should exit 0"
[ ! -e "$tmp/array.running" ] || fail "clean teardown must remove the marker"
grep -qx -- "-u unmount" "$tmp/nmdctl.log" || fail "nmdctl unmount not called"
grep -qx -- "-u stop" "$tmp/nmdctl.log" || fail "nmdctl stop not called"

# --- nmdctl stop fails -> marker kept, still exits 0 ------------------------
make_nmdctl 1
: > "$tmp/array.running"
run || fail "failed teardown must still exit 0"
[ -e "$tmp/array.running" ] || fail "failed teardown must keep the marker"
grep -q "teardown incomplete" "$tmp/err" || fail "failure not reported on stderr"
# Every step is attempted even after the first failure.
grep -qx -- "-u stop" "$tmp/nmdctl.log" || fail "stop skipped after unmount failed"

# --- an unmountable pool keeps the marker too -------------------------------
make_nmdctl 0
: > "$tmp/array.running"
mkdir -p "$tmp/pool"
cat > "$tmp/mounts" <<EOF
nonraid-nrpool $tmp/pool fuse.mergerfs rw 0 0
EOF
run || fail "busy pool must still exit 0"
[ -e "$tmp/array.running" ] || fail "busy pool must keep the marker"
grep -q "could not unmount" "$tmp/err" || fail "unmount failure not reported"

# --- a mountpoint containing whitespace is decoded, not split ---------------
make_nmdctl 0
: > "$tmp/array.running"
mkdir -p "$tmp/two words"
cat > "$tmp/mounts" <<EOF
nonraid-nrpool $tmp/two\040words fuse.mergerfs rw 0 0
EOF
run || fail "escaped mountpoint must still exit 0"
grep -q "could not unmount pool $tmp/two words" "$tmp/err" \
    || fail "\\040 not decoded into a single path (got: $(cat "$tmp/err"))"

# --- a foreign mergerfs pool is left alone ----------------------------------
make_nmdctl 0
: > "$tmp/array.running"
mkdir -p "$tmp/other"
cat > "$tmp/mounts" <<EOF
somethingelse $tmp/other fuse.mergerfs rw 0 0
EOF
run || fail "foreign pool run should exit 0"
grep -q "could not unmount" "$tmp/err" && fail "foreign mergerfs pool must not be touched"
[ ! -e "$tmp/array.running" ] || fail "no pools of ours: marker should be removed"

echo "teardown: OK"
