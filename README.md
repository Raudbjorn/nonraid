# NonRAID — personal fork

A fork of **[qvr/nonraid](https://github.com/qvr/nonraid)**, which is where the project
actually lives. For what NonRAID is, how to install it, the kernel support matrix and all
array management documentation, read
**[upstream's README](https://github.com/qvr/nonraid/blob/main/README.md)** — none of that
is duplicated here, because a stale copy is worse than no copy.

This file only covers what this fork changes.

> [!WARNING]
> Everything here is staged work, not a release. Upstream's own warning still applies in
> full: this is early-stage software and data loss is possible. Use at your own risk, and
> keep backups.

## What is different here

### `nmdctl` accepts `/dev/disk/by-id/...` paths

The driver is handed a bare device name and opens `/dev/<name>`. Import sites passed
`basename` of whatever path the caller gave, which is only correct for a path already under
`/dev`. A by-id symlink's basename exists nowhere in `/dev`, so `nmdctl create` reported
*"All disks imported successfully"* for every slot and left the array with **zero disks** —
no error anywhere.

Paths now resolve to the kernel name before reaching the driver, the availability check
compares resolved names, and `validate_device_path` compares device numbers rather than
trusting that a node by that name exists. By-id paths are the stable way to name disks and
the obvious choice on any array with more than a handful of drives.

### `nmdctl unassign` has an unattended path

`unassign` was the one destructive command with no way through under `-u`: the confirmation
prompt was unconditional, so an unattended caller's `read` consumed nothing and the
operation cancelled. It takes `-f`/`--force` now, and refuses explicitly under `-u` without
it rather than issuing a prompt nobody can answer.

Argument parsing is strict — a second positional or an unknown option is rejected, so
`nmdctl unassign 1 2 -f` no longer silently unassigns slot 1.

> [!NOTE]
> `-f` here skips the confirmation. On `create`/`add`/`replace` the same flag bypasses
> device availability validation. Same spelling, unrelated behaviour.

**Behaviour change:** `nmdctl -u unassign SLOT <<< "y"` used to work and now refuses. Add
`-f`.

### Builds on kernel 7.1

7.1 moved the xor code to `lib/raid/xor/` and replaced `xor_blocks()` with `xor_gen()`,
dropping `MAX_XOR_BLOCKS`. A version-gated shim in `md_nonraid/compat-xor.h`, force-included
from `md_nonraid/Makefile`, keeps the six call sites in `unraid.c` byte-identical to upstream.
It lives outside the vendored per-kernel directories so a vendor drop or a directory rename
cannot strand it.

On ≥ 7.1 the module gains a runtime dependency on `xor` (builtin before, modular now), so
`insmod` alone fails with unknown symbol `xor_gen`. `depmod` records that dependency in
`modules.dep` and `modprobe` reads it to load `xor` before the module, so the normal load
path — and DKMS, which runs `depmod` on install — is unaffected.

### Building with the Makefile

```bash
make modules                 # build the two .ko against the running kernel
make clean

make package                 # nonraid-dkms: native if possible, container otherwise
make package-native          # force the native path
make package-docker          # force the container path
make package-plugin          # libpve-storage-nonraid-perl (the PVE storage plugin)
make package DOCKER=podman   # podman instead of docker
```

**Artifacts land in `out/`.** `dpkg-buildpackage` writes to the *parent* of the source
tree by convention — which drops files outside the checkout where nothing tracks or
ignores them, and for a tree checked out directly under `/`, into the filesystem root.
`package-native` and `package-plugin` move their `.deb`, `.changes` and `.buildinfo` there
afterwards; `package-docker` does the same via a temporary directory - it bind-mounts a
`mktemp -d` directory into the container as `/out` (never `OUTDIR` itself, so the container
never gets write access to the real output location) and moves the built artifacts into
`OUTDIR` once the container exits. `out/` is gitignored. Override with `OUTDIR=/somewhere`.

They cannot simply be redirected at build time: `dpkg-genbuildinfo` and `dpkg-genchanges`
read the just-built `.deb` from `..` by the name `debian/files` records, so
`dh_builddeb --destdir` makes the build die with `cannot fstat file`.

`nonraid-tools` has **no make target** — build it directly, and its `.deb` lands in the
parent as usual:

```bash
cd tools && dpkg-buildpackage -b -us -uc
```

That is deliberate: its `debian/rules` runs `check-package-manifest` against `../`, and
refuses to build at all when `debian/changelog` disagrees with `VERSION=` in `tools/nmdctl`:

```
debian/rules:13: *** debian/changelog says 9.9.9 but tools/nmdctl VERSION= says 1.23.0;
run: dch -v 1.23.0-1.  Stop.
```

That mismatch is not hypothetical — a `1.0.0-1` changelog against a `1.23.0` tool is how
the plugin's dependency became unsatisfiable by the package built from its own tree. The systemd and udev copies debhelper expects
are committed under `tools/debian/`, so no synthesis step is needed — `checks/fast.sh`
guards them byte-wise against `tools/systemd` and `tools/udev`.

**Why `package` picks a path.** `debian/control` build-depends on `dh-sequence-dkms`, which
only Debian's `dh-dkms` ships, so a native `.deb` build cannot run elsewhere. `make package`
selects the native path only when the whole toolchain is present (checked with
`dpkg-checkbuilddeps`) and otherwise builds in a container. The native path is chosen
whenever `dpkg-checkbuilddeps` is satisfied and `dh`/`fakeroot` are present — that includes
Ubuntu and any Debian derivative with the build dependencies installed, not only Debian.
`package-native` and `package-docker` stay individually reachable either way, so forcing the
container path on a native-capable host works.

The packaging variables are probed only when a packaging goal was actually requested. This
file is installed into `/usr/src` and re-parsed on every DKMS build, so an unconditional
`dpkg-checkbuilddeps` would run on every module rebuild on hosts that have no dpkg at all.

The container image is defined in `packaging/docker/`, so the toolchain is a cached layer —
a repeat build is about a second rather than reinstalling every dependency.

`DEB_IMAGE` accepts a digest (`DEB_IMAGE=debian@sha256:…`) to pin the base image. Note that
this pins the base only: the image still runs `apt-get update` and installs unpinned
packages, so the toolchain versions inside it continue to drift. Pinning those too would
need a snapshot repository or an explicit version list in `DEB_BUILD_DEPS`.

## Testing

**GitHub Actions is deliberately disabled on this fork.** The scripts under `checks/` are
the CI, and the git hooks are what run them:

```bash
git config core.hooksPath .githooks   # once per clone

sh checks/fast.sh       # lint + every unit suite, ~12s, no containers
sh checks/debs.sh       # build all three packages in a container
sh checks/pve-load.sh   # apt install, plugin load, dpkg trigger/remove/purge
```

`pre-push` runs `fast.sh` always and the two container tiers when the push touches what
they cover; the first container run builds an image (~5 min), later ones take tens of
seconds. `NONRAID_PUSH_FAST=1 git push` skips the heavy tiers loudly, `--no-verify` skips
everything. `pre-commit` applies mechanical fixes (trailing whitespace, final newline,
exec bit on shebang scripts) and never touches the vendored driver copies.

The individual suites, if you want them directly:

```bash
shellcheck -x tools/nmdctl
cd tools && bats tests/
prove pve-plugin/t/
```

The workflow files under `.github/workflows/` are kept for parity and in case Actions is
ever enabled; each is stamped with a note saying the `checks/` script is the enforced
version. They cover the same ground plus what a push hook cannot: a DKMS module build on
Debian 12/13 and Ubuntu 24.04, and a loop-device array lifecycle (create, sync, write,
fail a disk, rebuild, verify) — both need kernel headers and root loop devices.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Short version: this is a personal fork, rules are
light. Anything destined for the actual project goes to
[qvr/nonraid](https://github.com/qvr/nonraid) under **their** contribution rules.

## License

GPL-2.0, same as upstream and the Linux kernel. See [LICENSE](LICENSE).

Unraid is a trademark of Lime Technology, Inc. Neither this fork nor the upstream project is
affiliated with Lime Technology.
