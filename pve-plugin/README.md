# NonRAID storage plugin for Proxmox VE

Storage type `nonraid` for Proxmox VE 9: on activation the plugin starts the
NonRAID array (`nmdctl start`, degraded states included unless disabled),
mounts the member disks and unions them into a mergerfs pool at the storage
`path`. Array state is read from `/proc/nmdstat` only.

## Install

```sh
make package-plugin           # from the repo root, on Debian
apt install ./libpve-storage-nonraid-perl_*.deb
```

Requires `nonraid-tools` (>= 1.23), `mergerfs` and a working `nonraid-dkms`
module for the running kernel.

## Use

```sh
pvesm add nonraid nrpool --nodes $(hostname) --content images,backup
```

The pool path defaults to `/mnt/pve/<storage id>`. Options:

| option | default | |
|---|---|---|
| `nonraid-super` | `/nonraid.dat` | superblock file (`nmdctl -s`) |
| `nonraid-disk-prefix` | `/mnt/disk` | member mounts (`<prefix><slot>`) |
| `nonraid-degraded-autostart` | `yes` | start DISABLE_DISK/RECON_DISK arrays |
| `nonraid-mergerfs-opts` | computed | mergerfs `-o` override |

Always set `--nodes`: `storage.cfg` is cluster-wide, the array is not.

The storage stays online while the array is degraded (emulated reads);
transitions are syslogged. `NEW_ARRAY`, `SWAP_DSBL` and `ERROR:*` states are
never started automatically. With `nonraid-degraded-autostart 0` a degraded
array is not started either; the activation error names the manual command.
Note that a freshly created array reports bogus disabled/invalid counters
until the module is reloaded, which with autostart disabled reads as
degraded - reload (or leave autostart on) after creating an array.

Before any manual array ceremony (`unassign`, `replace`, `stop`), run
`pvesm set <id> --disable 1` first: pvestatd re-activates - and therefore
restarts - the array every cycle, and will fight the maintenance. Re-enable
when done.

Stop order: guests, then `umount <pool>`, `nmdctl unmount`, `nmdctl stop`.
`pve-nonraid.service` (started by the plugin) encodes exactly that for node
shutdown. **Enable it (`systemctl enable pve-nonraid`) when guests on a
nonraid storage use onboot**: qemu-server's cloud-init regeneration stats the
cloudinit volume before anything has activated the storage on a cold boot,
and the first `qm start` fails once with "disk image already exists"; the
enabled unit activates the storages before pve-guests runs. If
`nonraid.service` from nonraid-tools is enabled, set `AUTOMOUNT=no` in
`/etc/default/nonraid` and let the plugin mount.

## Web UI

The package injects a script tag into `/usr/share/pve-manager/index.html.tpl`
(pve-manager has no storage-plugin extension point) which adds NonRAID to the
Add Storage menu. A dpkg file trigger re-applies it after pve-manager
upgrades; `pve-nonraid-gui status` shows the current state. If injection
fails the plugin is unaffected — use `pvesm`.

Without the GUI script loaded, clicking Edit on an existing nonraid storage
throws `no editor registered for storage type: nonraid` (that click only).

## Kernel upgrades

The plugin cannot start the array if DKMS has no module for the running
kernel. Keep the matching `proxmox-headers-*` installed and check
`dkms status` after kernel upgrades.

## Tests

```sh
prove pve-plugin/t/                 # pure helpers, no PVE needed
sh pve-plugin/t/tpl-roundtrip.sh    # GUI injection round-trip
```

`perl -c` on the plugin is a false negative (compile cycle through the
DirPlugin parent); CI loads it through `PVE::Storage` on real PVE 9 packages.

Verified end to end on a PVE 9.2.6 node (kernel 6.14.11-9-pve, nonraid-dkms
1.3.2, mergerfs 2.40.2, 4-disk virtio array): plugin-driven start/mount/pool
from a cold array; degraded autostart with parity-emulated reads (md5-clean
through mergerfs); the fail-stop refusal; a full unassign/replace/RECON_DISK
rebuild; a guest with `cache=none,aio=native` qcow2 on the pool surviving
reboots with data intact, plus qcow2 snapshot/rollback; ordered shutdown
teardown; the dpkg trigger on a pve-manager reinstall; the Add/Edit dialogs
in a real browser; a purge/reinstall cycle (config and running guests
survive, `pvesm` degrades to an "unsupported type" warning); and the same
stack rebooted onto PVE's default kernel line - 7.0.14-8-pve with
nonraid-dkms 1.4.0 - with the array, pool, guest and all payloads intact.

Parity-check impact, measured on that rig (virtual disks - deltas are
directional only): guest streaming reads dropped ~40% while the check ran,
direct writes ~10%, and 4k fsync latency was unchanged. Untested:
multi-node clusters.
