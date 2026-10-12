# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

NonRAID is a fork of UnRAID's GPL'd `md_unraid` kernel driver, repackaged as a DKMS module plus a bash management tool (`nmdctl`). It provides UnRAID-style arrays (1-2 parity disks, per-disk independent filesystems, mixed disk sizes) outside the commercial UnRAID product.

Two kernel modules are built:
- `md-nonraid.ko` (module name `md_nonraid`, alias `nonraid`) — the array driver, from `md_nonraid/`
- `nonraid6_pq.ko` — a private copy of `lib/raid6` with UnRAID's `xor_syndrome` patch, from `raid6/`. It exists so the stock `raid6_pq` module stays untouched and unconflicted.

Unlike upstream UnRAID (which *replaces* the kernel's `md` driver and patches `raid6_pq` in-tree), NonRAID is self-contained and installs as DKMS without patching the kernel.

## Branch architecture (important)

Driver source is **not** developed on `main`. Three branch families:

| Branch | Contains | Role |
|---|---|---|
| `upstream` | `vendor/drivers/md/*.c`, `vendor/*.patch` | Pristine GPL drops extracted from UnRAID firmware releases. History = one commit per UnRAID release. |
| `nonraid-6.1`, `nonraid-6.6`, `nonraid-6.12`, `nonraid-6.18` | `md_nonraid/{md_unraid.c,md_unraid.h,unraid.c}` | NonRAID's rebranding + crash-fix patches rebased on top of the matching `upstream` vendor drop. One branch per supported kernel range. |
| `main` | everything else | DKMS packaging, `nmdctl`, docs, CI. Vendors the driver branches into `md_nonraid/<ver>/`. |

**`md_nonraid/6.1/`, `md_nonraid/6.6/`, `md_nonraid/6.12/` on `main` are copies** (each has a `README.md` saying so). A driver fix generally belongs on the `nonraid-6.X` branch and is then copied to `main` — check with the maintainer before landing driver changes directly on `main`.

Which copy gets compiled is decided by `md_nonraid/Makefile` from `KVERSION`: `> 6.8` → `6.12/`, `>= 6.5` → `6.6/`, else `6.1/`. Kernels 6.9 and 6.10 are unsupported. Note the comparison is `major > 6 OR (major == 6 AND minor > 8)`, so kernel 7.x already routes to the newest branch.

Intra-branch kernel differences are handled with `LINUX_VERSION_CODE >= KERNEL_VERSION(x,y,z)` guards (`<linux/version.h>` is already included by `md_unraid.h`). There is no autoconf; adding one is explicitly out of scope per README "Plans".

## Build & test

```bash
make modules           # build both .ko against $(uname -r); passes CONFIG_UBSAN=n
make clean
make package           # dpkg-buildpackage -b (DKMS source package)
```

`CONFIG_UBSAN=n` is deliberate: Ubuntu/Debian kernels enable UBSAN and the UnRAID code trips array-index-out-of-bounds warnings on every array operation (see DEVELOPMENT.md).

Full DKMS cycle, matching CI and the README's manual-install path:

```bash
DKMS_VERSION=$(grep "^PACKAGE_VERSION=" dkms.conf | cut -d= -f2)
sudo mkdir -p /usr/src/nonraid-dkms-$DKMS_VERSION
sudo cp -r md_nonraid/ raid6/ dkms.conf Makefile /usr/src/nonraid-dkms-$DKMS_VERSION/
sudo dkms install nonraid-dkms/$DKMS_VERSION -k "$(uname -r)"
```

Build log on failure: `/var/lib/dkms/nonraid-dkms/$DKMS_VERSION/build/make.log`.

### nmdctl tests

```bash
cd tools
bats tests/                                        # all
bats tests/test_nmdctl_basic.bats -f "pattern"     # single test by name regex
shellcheck -x tools/nmdctl                         # CI gate
bash -n tools/nmdctl                               # CI gate
```

The bats suite sources `nmdctl` and stubs out the root/driver-touching functions (`check_root`, `run_nmd_command`, `get_nmdstat_value`, …), then feeds a mock `/proc/nmdstat` via the `PROC_NMDSTAT` env var — `nmdctl` reads that variable instead of hardcoding the path precisely so tests can run unprivileged. Keep new driver-facing code behind a similarly overridable seam.

### Integration testing

Upstream's `.github/workflows/dkms-integration-tests.yml` (not carried in this fork) is the reference recipe for exercising the driver end to end without hardware: four 1 GiB sparse files → `losetup -fP` → `sgdisk -o -a 8 -n 1:32K:0` → symlink the loop devices into `/dev/disk/by-id/` (needed because `nmdctl` resolves members by disk ID) → `nmdctl create --force` → `start new_array` → `check recon` → mkfs/mount/write. It then walks the full lifecycle: `add` + `check clear`, `unassign`, wipe a member with `dd`, `start disable_disk` and md5-verify the emulated (parity-reconstructed) reads, then `replace` + `start recon_disk` + `check recon` and md5-verify again. Reproduce it locally when touching parity, import, or slot-management paths.

## Driver interface

The driver is procfs-only, no ioctls, no automation of its own — every disk must be re-imported into the correct slot on each module load:

- Write commands to `/proc/nmdcmd` (`import`, `start`, `stop`, `check`, `set`) — man page in `docs/nmdcmd.8`
- Read state from `/proc/nmdstat` (`key=value` text) — man page in `docs/nmdstat.5`
- Superblock path is a module parameter: `modprobe md-nonraid super=/nonraid.dat`
- Array members appear as `/dev/nmdXp1` where X is the slot number

Both man pages are LLM-generated from driver source and described as "mostly correct" — verify against the source before trusting a detail. `docs/manual-management.md` documents the raw command sequences and known driver quirks; it is the authoritative reference for what `nmdctl` is doing underneath.

`tools/nmdctl` (~4.9k lines of bash, requires bash 4+ for associative arrays) is a thin but opinionated wrapper over that interface: it collects `/proc/nmdstat` into associative arrays, then renders through pluggable formatters (`format_human_output`, `format_prometheus_output`, `format_json_output`, `format_terse_output`). Adding a status field usually means touching a `collect_*` function plus all four formatters.

## Versioning

CI derives package versions by grepping the source, so these strings are the single source of truth:
- DKMS/module: `PACKAGE_VERSION=` in `dkms.conf`
- Tool: `VERSION=` in `tools/nmdctl`

Two independent Debian packages: `debian/` builds `nonraid-dkms`, `tools/debian/` builds `nonraid-tools` (nmdctl + systemd units + udev rule).

Kernel support matrix lives in README.md and should be updated when a `nonraid-6.X` branch's range changes.

## Contribution rules (from CONTRIBUTING.md)

- **Do not generate PR or issue descriptions with AI.** These must be written by the human contributor in their own words.
- AI-assisted code is allowed, but AI-generated parts must be disclosed in the PR description.
- Avoid AI-generated verbose documentation prose; the docs have a deliberately terse existing style — match it.
- Separate pull requests for separate changes; discuss large changes in an issue first.
- Keep driver diffs minimal — the whole point is that `nonraid-6.X` branches stay rebasable onto new `upstream` vendor drops.
