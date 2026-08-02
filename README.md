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
dropping `MAX_XOR_BLOCKS`. A version-gated shim in `md_nonraid/6.12/md_unraid.h` keeps the
six call sites in `unraid.c` byte-identical to upstream.

On ≥ 7.1 the module gains a runtime dependency on `xor` (builtin before, modular now):
`insmod` alone fails with unknown symbol `xor_gen`, while `modprobe`/`depmod` resolve it, so
DKMS is unaffected.

### `make package` works off Debian

`debian/control` build-depends on `dh-sequence-dkms`, which only Debian's `dh-dkms` ships,
so a native `.deb` build cannot run elsewhere. `make package` now selects the native path
only when the whole toolchain is present (checked with `dpkg-checkbuilddeps`), and otherwise
builds in a container:

```bash
make package                 # native where the full toolchain is present, container otherwise
make package-native          # force the native path
make package-docker          # force the container path
make package DOCKER=podman   # podman instead of docker
```

The native path is chosen whenever `dpkg-checkbuilddeps` is satisfied and `dh`/`fakeroot`
are present — that includes Ubuntu and any Debian derivative with the build dependencies
installed, not only Debian.

The container image is defined in `packaging/docker/`, so the toolchain is a cached layer —
a repeat build is about a second rather than reinstalling every dependency.

`DEB_IMAGE` accepts a digest (`DEB_IMAGE=debian@sha256:…`) to pin the base image. Note that
this pins the base only: the image still runs `apt-get update` and installs unpinned
packages, so the toolchain versions inside it continue to drift. Pinning those too would
need a snapshot repository or an explicit version list in `DEB_BUILD_DEPS`.

## Testing

```bash
shellcheck -x tools/nmdctl
cd tools && bats tests/
```

`.github/workflows/ci.yml` runs both, plus a guard that packaging variables stay out of
`make modules`. Upstream's heavier DKMS build matrix, integration lifecycle and
package-publishing workflows are not carried here — see upstream if you need them.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Short version: this is a personal fork, rules are
light. Anything destined for the actual project goes to
[qvr/nonraid](https://github.com/qvr/nonraid) under **their** contribution rules.

## License

GPL-2.0, same as upstream and the Linux kernel. See [LICENSE](LICENSE).

Unraid is a trademark of Lime Technology, Inc. Neither this fork nor the upstream project is
affiliated with Lime Technology.
