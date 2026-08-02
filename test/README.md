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

## Configuration

All overridable; defaults in brackets.

| Variable | Meaning |
|---|---|
| `NONRAID_TEST_WORKDIR` | image + superblock directory [`/root/nonraid-test`] |
| `NONRAID_TEST_DISKS` | number of disks [`4`] |
| `NONRAID_TEST_SIZE_MB` | size of each [`256`] |
| `NONRAID_TEST_PREFIX` | by-id symlink prefix [`virtdisk-`] |
| `NONRAID_TEST_MOUNT_PREFIX` | mount point prefix [`/mnt/disk`] |
| `NONRAID_TEST_SUPERBLOCK` | superblock path [`$WORKDIR/nonraid.dat`] |
| `NONRAID_TEST_OFFSET` | import offset in 512-byte sectors [`64`] |
| `NMDCTL` | nmdctl to test [`../tools/nmdctl`] |

## Safety

`setup_disk.sh` drops a `.nonraid-test-owned` marker in `$WORKDIR`, and `teardown_disk.sh`
refuses to delete anything without it. That guard exists because the version these were
adapted from removed `/nonraid.dat` unconditionally — on a machine with a real array, that
is the array configuration.

`--force` overrides the guard.

`setup_disk.sh` checks for `btrfs-progs` rather than installing it; a test helper should not
change the host's package set.

## Note

`mk_array.sh` creates the array with an explicit import offset, so a normal run also
exercises the offset path and its persistence in `/etc/nonraid/disk-offsets`. Set
`NONRAID_TEST_OFFSET=0` for a plain partition-based array.
