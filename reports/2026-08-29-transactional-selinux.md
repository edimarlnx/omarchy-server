# Transactional updates under SELinux enforcing

**Date:** 2026-08-29
**Subject:** the two mechanisms that had only ever been measured apart, run on one machine: a fresh `--mac selinux` install taken to enforcing by the guarded command, then the transactional list and the SELinux list against it
**Result:** SELinux **45/45 permissive**. Transactional **28 passed, 6 failed** — four of the six are Secure Boot items this machine cannot answer, two are real. SELinux under the enforcing pass **55 passed, 4 failed**, all four traceable to what a transaction did to the machine. Three defects found and **two fixed and re-measured**; the third is open.

The headline is the one that was not expected: before the fixes, **a single
transaction unmounted the live machine's `/sys/fs/selinux`**, and the machine
then reported `getenforce` → `Disabled` while the kernel was still enforcing.

## Scope

One machine of the `server` profile, installed headless from the ISO below with
the `selinux` marker on its autoinstall drive and **no** Secure Boot — the
command the run was asked for is `lab up srvtxsel --mac selinux`. Secure Boot is
the reason four of the transactional failures are inapplicable rather than real,
and it is called out at each of them.

What this run set out to answer: does the transactional update path — a chroot
into a snapshot of `@`, a subvolume rename to select it, a rollback — still work
when the machine is enforcing, and does the machine come out of it still
enforcing and still labelled.

## Environment

| | |
|---|---|
| VM | `srvtxsel`, QEMU/KVM `q35`, 4 vCPU, 8 GiB RAM, 40 GiB virtio disk |
| Firmware | OVMF 4M, ordinary variable store (**no** Secure Boot) |
| ISO | `omarchy-2026.08.29-x86_64-server-local.iso` |
| ISO size | 2.9 GiB (3152297984 bytes) |
| ISO sha256 | `b12734034f2a5d0444108623c8a6460f83d74564ea4acf1b3797a9ab4846f333` |
| Autoinstall | `mkcidata.sh --profile server --mac selinux` |
| Installed | 229 packages, 1501.53 MiB |
| Kernel | 7.1.11-arch1-1 |
| Policy | `refpolicy-arch`, MLS disabled |
| Run | `2026-08-29T20:43:37-03:00` |

## Method

```bash
serverlab lab up srvtxsel --mac selinux
# the first boot of a fresh install has PID 1 in kernel_t, which the enforcing
# preflight refuses on purpose (docs/mac.md). One reboot, and then:
serverlab lab test srvtxsel --suite selinux --no-reboot     # permissive
sudo omarchy-server-selinux enforcing                       # the guarded command
serverlab lab test srvtxsel --suite transactional --no-collect --no-reboot
ENFORCE=1 pocs/server-install/acceptance-selinux.sh srvtxsel
serverlab lab down srvtxsel
```

Evidence: `pocs/server-install/reference/srvtxsel/`.

**One deviation from an ordinary run, and it matters when reading the numbers.**
The transactional list was run against a **hand-patched**
`/usr/bin/omarchy-server-transaction`: the fixes in §"Two defects, fixed" were
written, installed over the packaged file with `install -m 755`, and only then
measured. They are committed to the profile in this repository; no package
carrying them has been built or published yet.

## Results

| List | Mode | Result |
|---|---|---|
| `acceptance-selinux.sh` | permissive | **45 passed, 0 failed** |
| `acceptance-transactional.sh` | **enforcing** | **28 passed, 6 failed** |
| `acceptance-selinux.sh` `ENFORCE=1` | enforcing, after the transactions | **55 passed, 4 failed** |

The enforcing switch itself was taken by
`sudo omarchy-server-selinux enforcing` **without `--force`**: the preflight
passed on its own, as it is supposed to on a machine whose operator has the
administrative role (`selinux-enforcing-switch.txt`).

## The defect that mattered: a transaction unmounted `/sys/fs/selinux`

Measured before any fix, on a machine that had just been switched to enforcing,
with one `omarchy-server-transaction run --with tree --no-reboot`:

```
=== BEFORE ===
Enforcing
11 mounts under /sys
=== AFTER ===
Disabled
1 mount under /sys
--- /sys mounts lost ---
/sys/kernel/tracing  /sys/firmware/efi/efivars  /sys/fs/bpf  /sys/fs/cgroup
/sys/fs/fuse/connections  /sys/fs/pstore  /sys/fs/selinux  /sys/kernel/config
/sys/kernel/debug  /sys/kernel/security
--- selinuxfs present? ---
NOT MOUNTED
```

The kernel was still enforcing — nothing can turn SELinux off at runtime on this
kernel — but with `selinuxfs` gone, every userspace tool that asks
`is_selinux_enabled()` answers *no*: `getenforce` says `Disabled`, `sestatus`
says `disabled`, `id -Z` refuses. An operator reading those would conclude the
machine had silently lost its MAC, and the state persists until the next reboot.
`/sys/fs/cgroup` going with it is the same event and is arguably worse.

**Cause.** The transaction's mount tree lives in a directory `mktemp -d` makes
under `/run`. systemd leaves `/run` **shared**, and `mount_chroot` binds `/run`
back into the transaction so pacman can reach `/etc/resolv.conf`. That bind puts
the transaction's own mount tree into the host's peer group — the transaction
appears mirrored underneath itself — and the teardown's unmounts propagate out
of the mirror onto the live machine's mounts. The `--make-rslave` the script
already had on `$newroot/sys` and `$newroot/dev` does not cover this: the
propagation path is through `/run`, not through those.

## Two defects, fixed

`profile/server/overlay/runtime/bin/omarchy-server-transaction`:

**1. Nothing under the transaction may propagate out.** `mount_top` now marks
the transaction's top-level mount `--make-rslave`, and `mount_chroot` marks the
assembled chroot `--make-rslave` after the binds — `--rbind` of a shared mount
produces a peer of the original, so it has to be said again at the end rather
than once at the start. A slave still *sees* everything the host mounts; it
never sends an unmount back.

Re-measured, same command, same machine state:

```
=== BEFORE ===  Enforcing, 11 mounts under /sys
=== AFTER ===   Enforcing, 11 mounts under /sys
--- /sys mounts lost ---   (none)
--- selinuxfs ---          /sys/fs/selinux
```

and after the whole transactional list, three reboots and a rollback later, the
same eleven mounts are there and `getenforce` still says `Enforcing`
(`transactional-selinux-denials.txt`).

**2. The subvolume swap was refused, and reported as success.** The rename that
selects the new root happens in subvolume **5**, the top of the btrfs — the one
subvolume this machine never mounts in normal operation. It therefore carries no
`security.selinux` xattr and arrives as `unlabeled_t`:

```
avc: denied { rmdir } for comm="rmdir" name="machines" dev="vda2" ino=2
     scontext=staff_u:sysadm_r:sysadm_t tcontext=system_u:object_r:unlabeled_t
mv: cannot move '/run/omarchy-tx.ismFsK/@' to '…/@prev-20260829203232': Permission denied
Swapped in: @ is now the updated root, @prev-20260829203232 is what was running.
```

Two bugs in four lines. The rename is refused because not even `sysadm_t` may
rename inside an unlabeled directory — and then the command **printed the
success line anyway**: `swap_root` runs inside `prev=$(swap_root …)`, and
`set -e` does not reach out of a command substitution, so `mv`'s failure was
printed by `mv` and then contradicted by the script. A machine that had updated
nothing said it had.

Both are fixed. `mount_top` labels subvolume 5 `system_u:object_r:root_t` when
it finds it unlabeled — an xattr on that directory, so it is done once and every
later transaction finds it already there. Not a `context=` mount option:
SELinux mount options must agree across every mount of one superblock and this
filesystem is already mounted at `/`. And not `:s0`: the policy this profile
ships has MLS disabled and `chcon` refuses a context carrying a level it does
not know. `swap_root` now checks both renames, restores `@` if the second fails,
and the caller tests its status.

After the fix, from a fresh install whose top level was still `?`:

```
top-level label before: ? /run/p
Transaction succeeded (+0 MiB on the filesystem)
Swapped in: @ is now the updated root, @prev-20260829204205 is what was running.
```

## The six transactional failures

| # | Item | Verdict |
|---|---|---|
| 145 | the snapper snapshot taken before the transaction is in the record | **real, open** |
| 161 | a transaction that reinstalls the kernel rebuilds and re-signs the UKI | **real, open** |
| 204 | Secure Boot is still enforcing after a transactional kernel change | not applicable — `sbctl: command not found` |
| 211 | module signature enforcement survived it | not applicable — `sig_enforce=N`, set only by the Secure Boot addon |
| 215 | the cmdline is byte for byte the one the machine has always booted | not applicable — the expected string carries `lockdown=integrity module.sig_enforce=1` |
| 330 | the rolled-back root boots, with Secure Boot still enforcing | not applicable — same as 204 |

Four of the six are the price of running the list on a machine without Secure
Boot, which is what `--mac selinux` alone builds. They are not evidence about
this combination either way; the Secure Boot half of the transactional list was
green on `srvsb` in `reports/2026-08-29-transactional-updates.md` and nothing
here touches it.

### 145 — snapper does not survive a transaction

`.snapshots` belongs to the root subvolume, so it goes with the old root at the
swap. `swap_root` is supposed to re-create it in the new root and re-snapshot
each retained snapper snapshot. It does not:

```
$ snapper -c root list
 # | Type   | … | Description
 0 | single |   | current
$ snapper -c root create -d selinux-acceptance
IO Error (.snapshots is not a btrfs subvolume).
$ ls -Zd /.snapshots
ls: cannot access '/.snapshots': Permission denied
```

The re-creation is guarded by `rmdir "$snapdir" 2>/dev/null || true` followed by
`if [[ ! -e $snapdir ]] && btrfs subvolume create …`: a `.snapshots` that
survives as a non-empty **directory** fails the `rmdir`, fails the `[[ ! -e ]]`,
and the whole re-snapshot loop is skipped without a word. That reading is
consistent with everything measured, but it was not proved by a second run, and
**no AVC accompanies the failure** — so this is a transactional bug that
enforcing exposes rather than an SELinux one. It is left open deliberately: the
fix is a change to how `swap_root` handles `.snapshots`, and it deserves its own
measurement rather than being folded into this run.

### 161 — the kernel transaction did not change the UKI

`omarchy-server-transaction run --with linux` completed (`+326 MiB`), the
machine rebooted into it, `limine.conf` still records the hash of the file on
the ESP — and the UKI's b2sum is byte for byte what it was before. The same run
printed `could not delete /run/omarchy-tx…/@prev-…`, so the transaction's own
housekeeping was already unhappy. No AVC accompanies this one either. Open.

## The four SELinux failures, after the transactions

The enforcing list was run **after** the transactional list, on the root a
transaction produced. That ordering is deliberate — the enforcing list ends by
disabling SELinux, so nothing can follow it — and it is what makes these four
readable as *what a transaction did to the labels*:

| Item | What it says |
|---|---|
| every binary that needs libselinux reaches it | `/usr/lib/systemd/systemd` → `NO SELINUX`, although `pacman -Qq` confirms `systemd-selinux` and the other eight rebuilds are still the installed set |
| no file under /etc /usr /var has a label the policy disagrees with | exactly two: `/var/lib/machines` and `/var/lib/portables`, both `unlabeled_t` |
| a snapper snapshot can be taken | the §145 failure, seen from the other list |
| enforcing: something was denied under the workload | 17 AVC records, the deduplicated dump is in `transactional-selinux-denials.txt` |

The two unlabeled paths are the nested subvolumes the transaction re-creates
inside the chroot (`btrfs subvolume create` after an `rmdir`), where the policy
of the *running* kernel labels what pacman creates but nothing labels what the
script creates. They are a one-line `restorecon` away and they are the same
shape of gap as `.snapshots`: **the transaction creates subvolumes and does not
label them.**

The 17 denials are, after deduplication, almost entirely the harness rather than
the profile: ten `umount`/`mount` writes to the pipe the ssh session gives a
privileged command, five `systemd-tmpfiles` `getattr` on the two unlabeled
directories above, and the `iptables` read of `~/.lab-pw` that
`acceptance-selinux.sh` documents at length. Nothing in the set is a service
being refused something it needs.

## What this run proves, and what it does not

Proved:

* a fresh `--mac selinux` install reaches enforcing through the guarded command,
  with no `--force`, and is **still enforcing after three transactional reboots
  and a rollback**;
* the permissive SELinux list is unchanged at 45/45 on this ISO;
* with the two fixes, a transaction under enforcing completes, swaps the root,
  and leaves the live machine's mount table exactly as it found it.

Not proved:

* anything about **Secure Boot + SELinux + transactional** together. Four of the
  six transactional failures are that gap and closing it needs
  `lab up … --mac selinux --secboot`;
* that the two open defects (§145, §161) are absent on a machine that is *not*
  enforcing — they may well be transactional bugs this run merely happened to
  find;
* that the fixes hold from a **packaged** `omarchy-server`. They were measured
  from a file installed by hand; the package has not been rebuilt.

## Follow-ups

1. Build `omarchy-server` with the two fixes (`pkgrel` bump in
   `omarchy-server-pkgs`) and re-run this list from the ISO rather than from a
   hand-patched file.
2. `swap_root`: re-create `.snapshots` unconditionally and label every subvolume
   it creates. §145 and the two `unlabeled_t` paths are one repair.
3. Repeat with `--secboot`, which is the only way the four inapplicable items
   become evidence.
4. §161 — find out whether the kernel transaction rebuilds the UKI on a
   non-enforcing machine before deciding what it is.
