#!/bin/sh
# Round-trip test for bin/pve-nonraid-gui against a representative
# index.html.tpl. Runs with a synthesized fixture by default; pass the path
# to a real pve-manager index.html.tpl to test against the genuine article.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
tool="$here/../bin/pve-nonraid-gui"
pristine="${1:-$here/fixtures/index.html.tpl.fixture}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cp "$pristine" "$tmp/work.tpl"
export PVE_NONRAID_TPL="$tmp/work.tpl"

fail() { echo "FAIL: $1" >&2; exit 1; }

PVE_NONRAID_VER=1.0.0 sh "$tool" apply >/dev/null
grep -q 'BEGIN pve-nonraid-gui 1.0.0' "$tmp/work.tpl" || fail "block not injected"
# The block must sit directly after the pvemanagerlib line.
grep -A1 'pvemanagerlib' "$tmp/work.tpl" | grep -q 'BEGIN pve-nonraid-gui' \
    || fail "block not anchored after pvemanagerlib"

cp "$tmp/work.tpl" "$tmp/after1.tpl"
PVE_NONRAID_VER=1.0.0 sh "$tool" apply >/dev/null
cmp -s "$tmp/work.tpl" "$tmp/after1.tpl" || fail "re-apply not idempotent"

PVE_NONRAID_VER=1.1.0 sh "$tool" apply >/dev/null
[ "$(grep -c 'BEGIN pve-nonraid-gui' "$tmp/work.tpl")" = 1 ] \
    || fail "version bump left more than one block"
grep -q 'BEGIN pve-nonraid-gui 1.1.0' "$tmp/work.tpl" || fail "version not replaced"

PVE_NONRAID_VER=1.1.0 sh "$tool" status | grep -q 'applied (1.1.0)' || fail "status: applied"
PVE_NONRAID_VER=2.0.0 sh "$tool" status | grep -q 'stale' || fail "status: stale"

PVE_NONRAID_VER=1.1.0 sh "$tool" remove >/dev/null
cmp -s "$tmp/work.tpl" "$pristine" || fail "remove is not byte-identical to pristine"
PVE_NONRAID_VER=1.1.0 sh "$tool" remove >/dev/null || fail "second remove not a no-op"

# A restructured template (anchor gone) must fail loudly but recoverably.
sed 's/pvemanagerlib/RENAMED/' "$pristine" > "$tmp/noanchor.tpl"
if PVE_NONRAID_TPL="$tmp/noanchor.tpl" PVE_NONRAID_VER=1.0.0 sh "$tool" apply 2>/dev/null; then
    fail "apply succeeded without anchor"
fi

# pveproxy reads this template as www-data. A restrictive umask (an admin
# running apply by hand) must not leave it unreadable - that would blank the
# entire web UI, not just the Add-menu entry.
cp "$pristine" "$tmp/work.tpl"
chmod 644 "$tmp/work.tpl"
( umask 077; PVE_NONRAID_VER=1.0.0 sh "$tool" apply >/dev/null )
mode=$(stat -c '%a' "$tmp/work.tpl")
[ "$mode" = "644" ] || fail "apply under umask 077 changed the template mode to $mode"
( umask 077; PVE_NONRAID_VER=1.0.0 sh "$tool" remove >/dev/null )
mode=$(stat -c '%a' "$tmp/work.tpl")
[ "$mode" = "644" ] || fail "remove under umask 077 changed the template mode to $mode"

# A malformed block (BEGIN without END) must not be "removed" - the range
# delete would take the rest of the template with it.
cp "$pristine" "$tmp/work.tpl"
PVE_NONRAID_VER=1.0.0 sh "$tool" apply >/dev/null
grep -v 'END pve-nonraid-gui' "$tmp/work.tpl" > "$tmp/broken.tpl"
before=$(wc -l < "$tmp/broken.tpl")
if PVE_NONRAID_TPL="$tmp/broken.tpl" PVE_NONRAID_VER=2.0.0 sh "$tool" apply 2>/dev/null; then
    fail "apply accepted a template with an unterminated block"
fi
[ "$(wc -l < "$tmp/broken.tpl")" = "$before" ] || fail "malformed template was modified"
PVE_NONRAID_TPL="$tmp/broken.tpl" sh "$tool" status | grep -q MALFORMED \
    || fail "status does not report a malformed block"

# Only the first anchor gets a block, so a second (or commented-out) loader
# line cannot produce duplicates.
cp "$pristine" "$tmp/work.tpl"
awk '{ print } /pvemanagerlib/ && !d { print "    <!-- " $0 " -->"; d = 1 }' \
    "$tmp/work.tpl" > "$tmp/twoanchors.tpl"
PVE_NONRAID_TPL="$tmp/twoanchors.tpl" PVE_NONRAID_VER=1.0.0 sh "$tool" apply >/dev/null
[ "$(grep -c 'BEGIN pve-nonraid-gui' "$tmp/twoanchors.tpl")" = 1 ] \
    || fail "two anchor matches produced more than one block"

# A missing template is a diagnosis, not a crash.
PVE_NONRAID_TPL="$tmp/gone.tpl" sh "$tool" status | grep -q 'tpl: MISSING' \
    || fail "status on a missing template should report it"
if PVE_NONRAID_TPL="$tmp/gone.tpl" sh "$tool" apply 2>/dev/null; then
    fail "apply on a missing template should fail"
fi

# No temp files left behind anywhere above.
leftovers=$(find "$tmp" -name '*.tmp.*' | wc -l)
[ "$leftovers" = 0 ] || fail "$leftovers temp file(s) left behind"

echo "tpl-roundtrip: OK"
