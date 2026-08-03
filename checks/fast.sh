#!/bin/sh
# Fast tier: lint and unit suites, no containers, ~12s. Mirrors the
# 'nmdctl' and plugin-unit workflow jobs.
set -u
# shellcheck source=checks/lib.sh
. "$(dirname "$0")/lib.sh"
cd "$ROOT" || exit 1
need shellcheck perl prove bats node

fail=0
step() {
    name="$1"; shift
    printf '>>> %s ... ' "$name"
    if out=$("$@" 2>&1); then
        echo "ok"
    else
        echo "FAIL"
        printf '%s\n' "$out" | tail -20
        fail=1
    fi
}

step "shellcheck nmdctl"      shellcheck -x tools/nmdctl
step "shellcheck plugin bins" shellcheck -x pve-plugin/bin/pve-nonraid-gui pve-plugin/bin/pve-nonraid-teardown
step "shellcheck maintainer"  shellcheck -x pve-plugin/debian/postinst pve-plugin/debian/prerm pve-plugin/debian/postrm
step "shellcheck harness"     shellcheck -x test/lib.sh test/setup_disk.sh test/teardown_disk.sh test/mk_array.sh
step "shellcheck checks"      sh -c 'shellcheck -x checks/*.sh .githooks/pre-push'
step "bash -n nmdctl"         bash -n tools/nmdctl
step "node --check GUI js"    node --check pve-plugin/js/pve-nonraid-storage.js
step "perl syntax (stubbed)"  perl -c -I pve-plugin/t/lib -I pve-plugin pve-plugin/PVE/Storage/Custom/NonRAIDPlugin.pm
step "prove pve-plugin/t"     prove -q pve-plugin/t/
step "tpl-roundtrip"          sh pve-plugin/t/tpl-roundtrip.sh
step "teardown"               sh pve-plugin/t/teardown.sh
step "bats tools/tests"       sh -c 'cd tools && bats tests/'
# The debian/nonraid-tools.* files are COMMITTED COPIES of tools/systemd and
# tools/udev (so a bare dpkg-buildpackage works without synthesis). A copy that
# drifts ships a different unit than the tree says it does - the same failure
# class as the stale staged pve-nonraid-gui a reviewer caught in round two.
# shellcheck disable=SC2016  # deliberately quoted: expands inside sh -c
step "tools unit copies fresh" sh -c '
    for u in nonraid.service nonraid-parity-check.service \
             nonraid-parity-check.timer nonraid-notify.service nonraid-notify.timer; do
        cmp -s "tools/systemd/$u" "tools/debian/nonraid-tools.$u" || {
            echo "tools/debian/nonraid-tools.$u drifted from tools/systemd/$u" >&2
            exit 1
        }
    done
    cmp -s tools/udev/nonraid.udev tools/debian/nonraid-tools.nonraid.udev || {
        echo "tools/debian/nonraid-tools.nonraid.udev drifted from tools/udev/nonraid.udev" >&2
        exit 1
    }'

exit "$fail"
