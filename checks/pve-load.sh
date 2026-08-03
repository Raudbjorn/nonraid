#!/bin/sh
# PVE tier: install the built packages through apt (resolving Depends against
# the real PVE repo baked into the image), load the plugin through
# PVE::Storage, pin the hook-name contract, and walk the template
# trigger/remove/purge lifecycle. Mirrors pve-plugin-tests' plugin-load and
# package-lifecycle jobs.
set -eu
# shellcheck source=checks/lib.sh
. "$(dirname "$0")/lib.sh"

# shellcheck disable=SC2016  # the script body expands inside the container
in_image '
    echo ">>> build both packages"
    (cd tools && dpkg-buildpackage -b -us -uc >/dev/null 2>&1)
    (cd pve-plugin && dpkg-buildpackage -b -us -uc -d >/dev/null 2>&1)

    echo ">>> install through apt, resolving Depends"
    install -D -m 0644 pve-plugin/t/fixtures/index.html.tpl.fixture \
        /usr/share/pve-manager/index.html.tpl
    apt-get install -y -qq --no-install-recommends \
        ./nonraid-tools_*.deb ./libpve-storage-nonraid-perl_*.deb >/dev/null 2>&1
    nmdctl --version
    /usr/share/pve-nonraid/pve-nonraid-gui status
    test "$(stat -c %a /usr/share/pve-manager/index.html.tpl)" = 644

    echo ">>> plugin loads through PVE::Storage (perl -c is a false negative)"
    perl -e "
        use PVE::Storage;
        my \$c = PVE::Storage::Plugin->lookup(q(nonraid)) or die qq(lookup failed\n);
        my \$v = \$c->api();
        die qq(api \$v out of range\n) if \$v < 9 || \$v > PVE::Storage::APIVER();
        die qq(parent no longer declares on_update_hook_full\n)
            if !PVE::Storage::Plugin->can(q(on_update_hook_full));
        die qq(plugin does not override on_update_hook_full\n)
            if \$c->can(q(on_update_hook_full)) == PVE::Storage::Plugin->can(q(on_update_hook_full));
        print qq(loaded nonraid, api=\$v\n);
    " 2>/dev/null

    echo ">>> trigger re-applies after the template is replaced"
    install -D -m 0644 pve-plugin/t/fixtures/index.html.tpl.fixture \
        /usr/share/pve-manager/index.html.tpl
    dpkg-trigger --by-package libpve-storage-nonraid-perl /usr/share/pve-manager/index.html.tpl
    dpkg --triggers-only libpve-storage-nonraid-perl >/dev/null 2>&1
    /usr/share/pve-nonraid/pve-nonraid-gui status | grep -q "^tpl: applied"

    echo ">>> DPKG_ROOT leaves the live template alone"
    cp /usr/share/pve-manager/index.html.tpl /tmp/before.tpl
    DPKG_ROOT=/target sh /var/lib/dpkg/info/libpve-storage-nonraid-perl.postrm remove >/dev/null 2>&1
    cmp -s /tmp/before.tpl /usr/share/pve-manager/index.html.tpl

    echo ">>> remove sweeps the tag, purge removes the backup"
    apt-get remove -y -qq libpve-storage-nonraid-perl >/dev/null 2>&1
    ! grep -q "BEGIN pve-nonraid-gui" /usr/share/pve-manager/index.html.tpl
    apt-get purge -y -qq libpve-storage-nonraid-perl >/dev/null 2>&1
    test ! -f /usr/share/pve-manager/index.html.tpl.pve-nonraid.bak
    echo "PVE LIFECYCLE OK"
'
