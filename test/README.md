# Loop-device test harness

Throwaway helpers for exercising NonRAID end to end without hardware. Adapted from
[iiLaurens' `backup` branch](https://github.com/iiLaurens/nonraid/tree/backup).

They operate **only** on loop devices backed by files under `$WORKDIR`, and on a superblock
inside that directory — never `/nonraid.dat`. Nothing here touches a real disk.

```bash
sudo ./test/setup_disk.sh      # create loop disks + /dev/disk/by-id symlinks
sudo ./test/mk_array.sh        # create, start, parity-sync and mount the array
sudo ./test/teardown_disk.sh   # unwind everything
```

`sudo` resets the environment by default (`env_reset`), so the `NONRAID_TEST_*`
overrides below are **discarded** by a plain `sudo ./test/...`. Pass them through
`sudo env` on every step, or they silently revert to the defaults:

```bash
sudo env NONRAID_TEST_WORKDIR=/var/tmp/nr NONRAID_TEST_DISKS=5 ./test/setup_disk.sh
sudo env NONRAID_TEST_WORKDIR=/var/tmp/nr NONRAID_TEST_DISKS=5 ./test/mk_array.sh
sudo env NONRAID_TEST_WORKDIR=/var/tmp/nr NONRAID_TEST_DISKS=5 ./test/teardown_disk.sh
```

## Configuration

All overridable; defaults in brackets.

| Variable | Meaning |
|---|---|
| `NONRAID_TEST_WORKDIR` | image + superblock directory [`/root/nonraid-test`] |
| `NONRAID_TEST_DISKS` | number of disks [`4`] |
| `NONRAID_TEST_SIZE_MB` | size of each [`256`] |
| `NONRAID_TEST_PREFIX` | by-id symlink prefix, `[A-Za-z0-9][A-Za-z0-9._-]*` [`virtdisk-`] |
| `NONRAID_TEST_MOUNT_PREFIX` | mount point prefix, absolute with a non-empty final component [`/mnt/disk`] |
| `NONRAID_TEST_SUPERBLOCK` | superblock path [`$WORKDIR/nonraid.dat`] |
| `NONRAID_TEST_OFFSET` | import offset in 512-byte sectors [`64`] |
| `NONRAID_TEST_OFFSETS_FILE` | offset records path, must be inside `$WORKDIR` [`$WORKDIR/disk-offsets`] |
| `NMDCTL` | nmdctl to test [`../tools/nmdctl`] |

## Limits

- The offset an array member is imported at bounds only where its data region
  **starts**. There is no way to express where it ends: the size is always
  computed to the end of the physical device. On a partitioned disk that means
  an offset import covers the tail of the device, including a secondary GPT.
- `nmdctl replace` has no offset argument and does not record one, so a member of
  an offset-based array cannot be repaired with it.

## Safety

`setup_disk.sh` drops a `.nonraid-test-owned` marker in `$WORKDIR`, and `teardown_disk.sh`
refuses to delete anything without it. That guard exists because the version these were
adapted from removed `/nonraid.dat` unconditionally — on a machine with a real array, that
is the array configuration.

`--force` overrides the guard.

`setup_disk.sh` checks for `btrfs-progs` rather than installing it; a test helper should not
change the host's package set.

It also writes symlinks into `/dev/disk/by-id/`, which is unavoidable — `nmdctl`
resolves array members through that directory. Each link it creates is recorded
in `.nonraid-test-links`, and teardown removes exactly those rather than
globbing the prefix. It refuses to overwrite a link it does not already own.

Offsets are written to `$WORKDIR/disk-offsets` rather than the system
`/etc/nonraid/disk-offsets`. The harness sets `DISK_OFFSETS_FILE` outright rather than
honouring an inherited value, because that variable is nmdctl's own override and teardown
deletes whatever it points at. So a harness run leaves no entries in real array
state.

## Note

`mk_array.sh` creates the array with an explicit import offset, so a normal run also
exercises the offset path and its persistence in `$WORKDIR/disk-offsets`. Set
`NONRAID_TEST_OFFSET=0` for a plain partition-based array.
