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

# A fake nmdctl with a per-subcommand exit code, so a test can make one step
# fail while the others succeed - "every call fails" would not distinguish
# "stop failed" from "the teardown stopped after the first failure".
# Usage: make_nmdctl [unmount_rc] [stop_rc]
make_nmdctl() {
    cat > "$tmp/nmdctl" <<EOF
#!/bin/sh
echo "\$@" >> "$tmp/nmdctl.log"
case "\$*" in
    *unmount*) exit ${1:-0} ;;
    *stop*)    exit ${2:-0} ;;
esac
exit 0
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
make_nmdctl 0 0
: > "$tmp/array.running"
cat > "$tmp/mounts" <<'EOF'
/dev/nmd1p1 /mnt/disk1 xfs rw 0 0
EOF
run || fail "clean teardown should exit 0"
[ ! -e "$tmp/array.running" ] || fail "clean teardown must remove the marker"
grep -qx -- "-u unmount" "$tmp/nmdctl.log" || fail "nmdctl unmount not called"
grep -qx -- "-u stop" "$tmp/nmdctl.log" || fail "nmdctl stop not called"

# --- only nmdctl stop fails -> marker kept, still exits 0 -------------------
# The unmount succeeds here, so this isolates the stop failure rather than
# testing a teardown in which everything failed.
make_nmdctl 0 1
: > "$tmp/array.running"
run || fail "failed teardown must still exit 0"
[ -e "$tmp/array.running" ] || fail "failed teardown must keep the marker"
grep -q "nmdctl stop failed" "$tmp/err" || fail "stop failure not reported"
grep -q "nmdctl unmount failed" "$tmp/err" && fail "unmount reported as failed but it succeeded"
grep -q "teardown incomplete" "$tmp/err" || fail "incomplete teardown not reported"
grep -qx -- "-u stop" "$tmp/nmdctl.log" || fail "stop was never attempted"

# --- only nmdctl unmount fails -> stop is still attempted -------------------
make_nmdctl 1 0
: > "$tmp/array.running"
run || fail "failed unmount must still exit 0"
grep -q "nmdctl unmount failed" "$tmp/err" || fail "unmount failure not reported"
grep -qx -- "-u stop" "$tmp/nmdctl.log" || fail "stop skipped after unmount failed"
[ -e "$tmp/array.running" ] || fail "failed teardown must keep the marker"

# --- an unmountable pool keeps the marker too -------------------------------
make_nmdctl 0 0
: > "$tmp/array.running"
mkdir -p "$tmp/pool"
cat > "$tmp/mounts" <<EOF
nonraid-nrpool $tmp/pool fuse.mergerfs rw 0 0
EOF
run || fail "busy pool must still exit 0"
[ -e "$tmp/array.running" ] || fail "busy pool must keep the marker"
grep -q "could not unmount" "$tmp/err" || fail "unmount failure not reported"

# --- a pool that stayed mounted stops the teardown there --------------------
# mergerfs pins every branch it unions, so tearing the layers below it down
# while a pool is up cannot succeed; attempting it anyway only obscures which
# failure was the real one.
grep -q "skipping member unmount and array stop" "$tmp/err" \
    || fail "lower-layer teardown not skipped while a pool is mounted"
[ -s "$tmp/nmdctl.log" ] && fail "nmdctl was called with a pool still mounted"

# --- an unreadable mount table is not "no pools" ----------------------------
# This is the one that matters: if the two collapse, a degraded system removes
# the unclean-shutdown marker having never looked at a single mountpoint.
make_nmdctl 0 0
: > "$tmp/array.running"
PVE_NONRAID_MOUNTS="$tmp/does-not-exist" PVE_NONRAID_NMDCTL="$tmp/nmdctl" \
    PVE_NONRAID_MARKER="$tmp/array.running" sh "$script" 2>"$tmp/err" \
    || fail "unreadable mount table must still exit 0"
[ -e "$tmp/array.running" ] || fail "unreadable mount table must keep the marker"
grep -q "cannot read the mount table" "$tmp/err" || fail "unreadable mount table not reported"
[ -s "$tmp/nmdctl.log" ] && fail "nmdctl was called without knowing what is mounted"

# --- glob characters in a mountpoint must not be expanded -------------------
# /proc/mounts escapes whitespace but not '*', '?' or brackets, so an unquoted
# expansion would match unrelated local paths instead.
make_nmdctl 0 0
: > "$tmp/array.running"
mkdir -p "$tmp/star"
: > "$tmp/star/decoy"
cat > "$tmp/mounts" <<EOF
nonraid-nrpool $tmp/star/* fuse.mergerfs rw 0 0
EOF
run || fail "glob mountpoint must still exit 0"
grep -q "could not unmount pool $tmp/star/\*" "$tmp/err" \
    || fail "mountpoint was glob-expanded (got: $(cat "$tmp/err"))"

# --- nested pools come down deepest first -----------------------------------
# Taking /proc/mounts order would hit the parent first, get EBUSY, and never
# come back to the child.
make_nmdctl 0 0
: > "$tmp/array.running"
mkdir -p "$tmp/nest/inner"
cat > "$tmp/mounts" <<EOF
nonraid-outer $tmp/nest fuse.mergerfs rw 0 0
nonraid-inner $tmp/nest/inner fuse.mergerfs rw 0 0
EOF
run || fail "nested pools must still exit 0"
order=$(grep -o "could not unmount pool $tmp/nest[^ ]*" "$tmp/err" | head -2)
first=$(echo "$order" | head -1)
[ "$first" = "could not unmount pool $tmp/nest/inner" ] \
    || fail "parent unmounted before child (order: $order)"

# --- a mountpoint containing whitespace is decoded, not split ---------------
make_nmdctl 0 0
: > "$tmp/array.running"
mkdir -p "$tmp/two words"
cat > "$tmp/mounts" <<EOF
nonraid-nrpool $tmp/two\040words fuse.mergerfs rw 0 0
EOF
run || fail "escaped mountpoint must still exit 0"
grep -q "could not unmount pool $tmp/two words" "$tmp/err" \
    || fail "\\040 not decoded into a single path (got: $(cat "$tmp/err"))"

# --- a foreign mergerfs pool is left alone ----------------------------------
make_nmdctl 0 0
: > "$tmp/array.running"
mkdir -p "$tmp/other"
cat > "$tmp/mounts" <<EOF
somethingelse $tmp/other fuse.mergerfs rw 0 0
EOF
run || fail "foreign pool run should exit 0"
grep -q "could not unmount" "$tmp/err" && fail "foreign mergerfs pool must not be touched"
[ ! -e "$tmp/array.running" ] || fail "no pools of ours: marker should be removed"

echo "teardown: OK"
