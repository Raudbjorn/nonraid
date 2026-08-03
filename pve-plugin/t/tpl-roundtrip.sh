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
# Not just "one block" but "after the FIRST anchor": landing after the second
# would load our script before pvemanagerlib.js defines the classes it needs,
# and the registration would silently no-op.
first_anchor=$(grep -n 'pvemanagerlib' "$tmp/twoanchors.tpl" | head -1 | cut -d: -f1)
block=$(grep -n 'BEGIN pve-nonraid-gui' "$tmp/twoanchors.tpl" | cut -d: -f1)
[ "$block" -eq "$((first_anchor + 1))" ] \
    || fail "block at line $block, expected $((first_anchor + 1)) (just after the first anchor)"

# A commented-out loader BEFORE the live one must not be taken for the anchor.
# Injecting there puts our script ahead of pvemanagerlib.js, where its own
# guard makes it a no-op: installed, and silently doing nothing.
cp "$pristine" "$tmp/work.tpl"
awk '/pvemanagerlib/ && !d { print "    <!-- <script src=\"/pve2/js/pvemanagerlib.js\"></script> -->"; d = 1 } { print }' \
    "$tmp/work.tpl" > "$tmp/deadanchor.tpl"
PVE_NONRAID_TPL="$tmp/deadanchor.tpl" PVE_NONRAID_VER=1.0.0 sh "$tool" apply >/dev/null
live=$(grep -n 'pvemanagerlib' "$tmp/deadanchor.tpl" | grep -v '<!--' | head -1 | cut -d: -f1)
block=$(grep -n 'BEGIN pve-nonraid-gui' "$tmp/deadanchor.tpl" | cut -d: -f1)
[ "$block" -eq "$((live + 1))" ] \
    || fail "block at line $block, expected $((live + 1)) (after the LIVE loader, not the commented one)"

# END before BEGIN passes any check that merely counts markers, and a range
# delete keyed off it takes the whole tail of the template with it.
cp "$pristine" "$tmp/work.tpl"
PVE_NONRAID_VER=1.0.0 sh "$tool" apply >/dev/null
b=$(grep -n 'BEGIN pve-nonraid-gui' "$tmp/work.tpl" | cut -d: -f1)
e=$(grep -n 'END pve-nonraid-gui' "$tmp/work.tpl" | cut -d: -f1)
bt=$(sed -n "${b}p" "$tmp/work.tpl")
et=$(sed -n "${e}p" "$tmp/work.tpl")
awk -v b="$b" -v e="$e" -v bt="$bt" -v et="$et" \
    'NR == b { print et; next } NR == e { print bt; next } { print }' \
    "$tmp/work.tpl" > "$tmp/swapped.tpl"
before=$(wc -l < "$tmp/swapped.tpl")
if PVE_NONRAID_TPL="$tmp/swapped.tpl" PVE_NONRAID_VER=2.0.0 sh "$tool" apply 2>/dev/null; then
    fail "apply accepted a template whose END precedes its BEGIN"
fi
[ "$(wc -l < "$tmp/swapped.tpl")" = "$before" ] || fail "misordered template was modified"

# Two markers on one line are two markers, however many lines match.
cp "$pristine" "$tmp/work.tpl"
PVE_NONRAID_VER=1.0.0 sh "$tool" apply >/dev/null
sed 's|\(<!-- BEGIN pve-nonraid-gui 1.0.0 -->\)|\1\1|' "$tmp/work.tpl" > "$tmp/doubled.tpl"
if PVE_NONRAID_TPL="$tmp/doubled.tpl" PVE_NONRAID_VER=2.0.0 sh "$tool" apply 2>/dev/null; then
    fail "apply accepted two BEGIN markers sharing one line"
fi

# A trailing space on the BEGIN marker must be read the same way everywhere.
# It used to defeat the version matcher only, so the block counted as "not
# applied" and a second one was injected on top of the first.
cp "$pristine" "$tmp/work.tpl"
PVE_NONRAID_VER=1.0.0 sh "$tool" apply >/dev/null
sed 's|\(<!-- BEGIN pve-nonraid-gui 1.0.0 -->\)|\1 |' "$tmp/work.tpl" > "$tmp/trailing.tpl"
PVE_NONRAID_TPL="$tmp/trailing.tpl" PVE_NONRAID_VER=1.0.0 sh "$tool" status | grep -q 'applied (1.0.0)' \
    || fail "status does not see a version marker with trailing whitespace"
PVE_NONRAID_TPL="$tmp/trailing.tpl" PVE_NONRAID_VER=2.0.0 sh "$tool" apply >/dev/null
[ "$(grep -c 'BEGIN pve-nonraid-gui' "$tmp/trailing.tpl")" = 1 ] \
    || fail "a second block was injected over one with trailing whitespace"
grep -q 'BEGIN pve-nonraid-gui 2.0.0' "$tmp/trailing.tpl" || fail "version not replaced"

# Markers with no loader between them are not an applied GUI, whatever the
# version says - otherwise a half-stripped block is accepted forever.
cp "$pristine" "$tmp/work.tpl"
PVE_NONRAID_VER=1.0.0 sh "$tool" apply >/dev/null
grep -v 'pve-nonraid-storage.js' "$tmp/work.tpl" > "$tmp/nopayload.tpl"
if PVE_NONRAID_TPL="$tmp/nopayload.tpl" PVE_NONRAID_VER=1.0.0 sh "$tool" apply 2>/dev/null; then
    fail "apply accepted a marker block with no loader inside it"
fi
PVE_NONRAID_TPL="$tmp/nopayload.tpl" sh "$tool" status | grep -q MALFORMED \
    || fail "status does not report a block with no loader"

# A symlinked template must be refused, not followed. 'cp -a' preserves a
# symlink, so the temp file would have been a second link to the same target
# and the truncation would have emptied the live template - which blanks the
# whole web UI, not just the Add menu.
cp "$pristine" "$tmp/real.tpl"
ln -sf "$tmp/real.tpl" "$tmp/link.tpl"
before=$(wc -c < "$tmp/real.tpl")
if PVE_NONRAID_TPL="$tmp/link.tpl" PVE_NONRAID_VER=1.0.0 sh "$tool" apply 2>/dev/null; then
    fail "apply followed a symlinked template"
fi
[ "$(wc -c < "$tmp/real.tpl")" = "$before" ] || fail "the symlink target was modified"
grep -q 'BEGIN pve-nonraid-gui' "$tmp/real.tpl" && fail "block injected through a symlink"

# A payload left at a different cache-busting version than the BEGIN marker
# names is not an applied GUI: browsers would keep serving the old script from
# cache while status reports the new version applied.
cp "$pristine" "$tmp/work.tpl"
PVE_NONRAID_VER=1.0.0 sh "$tool" apply >/dev/null
sed 's|?ver=1.0.0|?ver=0.9.9|' "$tmp/work.tpl" > "$tmp/wrongver.tpl"
PVE_NONRAID_TPL="$tmp/wrongver.tpl" PVE_NONRAID_VER=1.0.0 sh "$tool" status | grep -q MALFORMED \
    || fail "a payload at the wrong version was accepted as applied"

# An END marker embedded in an unrelated line must refuse, not delete the line.
cp "$pristine" "$tmp/work.tpl"
PVE_NONRAID_VER=1.0.0 sh "$tool" apply >/dev/null
sed 's|<!-- END pve-nonraid-gui -->|<span>x</span><!-- END pve-nonraid-gui -->|' \
    "$tmp/work.tpl" > "$tmp/embedded.tpl"
before=$(wc -l < "$tmp/embedded.tpl")
if PVE_NONRAID_TPL="$tmp/embedded.tpl" PVE_NONRAID_VER=1.0.0 sh "$tool" remove 2>/dev/null; then
    fail "remove accepted an END marker embedded in an unrelated line"
fi
[ "$(wc -l < "$tmp/embedded.tpl")" = "$before" ] || fail "the embedded-marker line was deleted"

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
