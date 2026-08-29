# Transactional updates, and the case against an immutable root

**Date:** 2026-08-29
**Subject:** a time-boxed spike: `omarchy-server-update --transactional` built and measured on a Secure Boot machine, and a feasibility verdict on a read-only `/`
**Result:** **63 passed, 0 failed** on VM `srvsb` — 34 of them the new transactional list

## Scope

One machine of the `server` profile with Secure Boot enforcing against keys it
generated for itself, installed headless from the ISO below by an autoinstall
`cidata` drive.

Two questions, one of which was built and one of which was only costed:

* **Mode A, transactional updates** — an update that never writes to the
  running root. Built, shipped in `omarchy-server` 4.0.1-9 and put through a
  new acceptance list of 34 items. §"How the new root is selected" is the
  mechanism and why it beat the two alternatives; `docs/transactional.md` is
  the design and the operator's guide.
* **Mode B, an immutable root** — a read-only `/` with writable `/etc` and
  `/var`. Not built. §"Mode B" is the verdict, the list of changes it would
  need and the reason the answer is *not now*.

The Secure Boot acceptance list is in this report as well, unchanged from the
run that installed this machine: it is the baseline the transactional work had
to leave intact, and every item in it was re-checked after a transaction
rebuilt and re-signed the UKI.

## Environment

| | |
|---|---|
| VM | `srvsb`, QEMU/KVM `q35`, 4 vCPU, 8 GiB RAM, 40 GiB virtio disk |
| Firmware | OVMF 4M **secboot** variable store, put into Setup Mode before the first boot |
| ISO | `omarchy-2026.08.29-x86_64-server-local.iso` |
| ISO size | 2.9 GiB (3149234176 bytes) |
| ISO sha256 | `0d91fb501b97188c6559a11a84c595dc08307fcf4fa252805058eba0f88dae8f` |
| Autoinstall | `mkcidata.sh --profile server --secureboot` |
| Run | `2026-08-29T15:41:15-03:00` |

## Method

```bash
serverlab pkgs build && serverlab pkgs test
serverlab iso build --profile server
serverlab lab up srvsb --profile server --secboot --iso omarchy-2026.08.29-x86_64-server-local.iso
serverlab lab test srvsb --suite all

# the transactional list, which no install-time marker implies and which is
# therefore never part of `--suite all`: it reboots the machine three times.
serverlab pkgs build omarchy-server        # 4.0.1-9, carrying the new command
# … the package installed into the VM with `pacman -U`, then:
serverlab lab test srvsb --suite transactional
serverlab report srvsb

# what those run underneath:
#   pocs/lab/mkcidata.sh --profile server --secureboot
#   pocs/lab/vm.sh srvsb create|start|wait-ssh
#   pocs/server-install/collect.sh|surface.sh|acceptance*.sh|reboot-check.sh srvsb
```

`collect.sh` and `surface.sh` run **before** the acceptance lists: the
acceptance workload installs the `docker` addon and then runs an update, both
of which change the package set the measurements record. `reboot-check.sh`
runs last, because it takes the VM down.

Every transactional run started from the same disk: `vm.sh srvsb snapshot
pristine` was taken before any of this and restored between passes, so the
34 items were re-run four times against a machine in exactly the state the
installer left it in.

## Results

### Acceptance — Secure Boot

**29 passed, 0 failed.** Full evidence in [`acceptance-secureboot.txt`](../pocs/server-install/reference/srvsb/acceptance-secureboot.txt).

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 1 | sbctl reports Secure Boot enabled with our keys | **PASS** | `Vendor Keys:	microsoft` |
| 2 | sbctl says the firmware is out of setup mode | **PASS** | `}` |
| 3 | sbctl owns the installed keys | **PASS** | `}` |
| 4 | the SecureBoot EFI variable reads 1 | **PASS** | `1` |
| 5 | the kernel saw secure boot at handover | **PASS** | `[    0.004422] Secure boot enabled` |
| 6 | every EFI binary on the ESP is signed | **PASS** | `unsigned=0` |
| 7 | the Limine binary, the fallback and the UKI are all in the signed set | **PASS** | `✓ /boot/EFI/limine/limine_x64.efi is signed` |
| 8 | limine.conf points at the UKI and its recorded hash matches the file | **PASS** | `hash-ok` |
| 9 | the cmdline the kernel booted with carries the lockdown options | **PASS** | `root=PARTUUID=e616c218-2b85-4f0b-ba64-6d6dfebf204b zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs  lo…` |
| 10 | lockdown is in integrity mode | **PASS** | `none [integrity] confidentiality` |
| 11 | module signature enforcement is on | **PASS** | `Y` |
| 12 | the cmdline drop-in appends to the profile defaults | **PASS** | `KERNEL_CMDLINE[default]+=" lockdown=integrity module.sig_enforce=1"` |
| 13 | the serial console survived on the cmdline | **PASS** | `root=PARTUUID=e616c218-2b85-4f0b-ba64-6d6dfebf204b zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs  lo…` |
| 14 | the keys are on the root filesystem, not on the ESP | **PASS** | `esp-key-files=0` |
| 15 | no account but root can read the key material | **PASS** | `ls: cannot open directory '/var/lib/sbctl': Permission denied` |
| 16 | an unsigned module is refused | **PASS** | `[   16.941203] Loading of unsigned module is rejected` |
| 17 | a stock in-tree module still loads | **PASS** | `UKI before the kernel reinstall: ea4013187e2ef0a7c665c0c52926df6b…` |
| 18 | reinstalling the kernel rebuilds the UKI | **PASS** | `uki-rebuilt` |
| 19 | the rebuilt UKI is signed | **PASS** | `unsigned=0` |
| 20 | limine.conf still records the hash of the rebuilt, signed UKI | **PASS** | `hash-ok` |
| 21 | limine-snapper-sync left the config consistent | **PASS** | `boot id after:  df778488-71ed-4be1-a2d5-128fbad0a401` |
| 22 | the machine actually rebooted | **PASS** | `boot_id fa333730-c197-4698-900f-9b5f0023ad08 -> df778488-71ed-4be1-a2d5-128fbad0a401` |
| 23 | the machine came back with Secure Boot still enforcing | **PASS** | `7.1.11-arch1-1` |
| 24 | and it is still refusing unsigned modules | **PASS** | `=== kexec ===` |
| 25 | the kexec addon installs kexec-tools and finds the signed UKI | **PASS** | `lockdown: none [integrity] confidentiality` |
| 26 | kexec_file_load refuses the UKI and accepts the kernel inside it | **PASS** | `[    6.835773] Lockdown: kexec: kexec of unsigned images is restricted; see man kernel_lockdown.7` |
| 27 | and it was the unpacked UKI that the kernel took | **PASS** | `kexec reboot: downtime 2s \| client 5s (10s resolution) \| boot_id 2517cf8b-7170-4395-8c53-b75304334ab3 -> 2174…` |
| 28 | both reboot paths came back, and were measured | **PASS** | `kexec reboot: downtime 2s \| client 5s (10s resolution) \| boot_id 2517cf8b-7170-4395-8c53-b75304334ab3 -> 2174…` |
| 29 | lockdown and module signing survived the kexec | **PASS** | `7.1.11-arch1-1` |

### Acceptance — transactional updates

**34 passed, 0 failed.** Full evidence in [`acceptance-transactional.txt`](../pocs/server-install/reference/srvsb/acceptance-transactional.txt).

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 1 | the transaction command is installed and owned by the runtime package | **PASS** | `/usr/bin/omarchy-server-transaction is owned by omarchy-server 4.0.1-9` |
| 2 | the mode defaults to in-place | **PASS** | `transactional=0` |
| 3 | turning it on writes the config the timer reads | **PASS** | `TRANSACTIONAL=1` |
| 4 | the kexec toggle and the mode toggle coexist in the config | **PASS** | `both=2` |
| 5 | the unattended timer runs the entry point that reads the mode | **PASS** | `ExecStart=/usr/bin/omarchy-server-update run` |
| 6 | the machine starts on @, with no transaction recorded | **PASS** | `saved boot files: none` |
| 7 | omarchy-server-update --transactional routes to a transaction, with no restart classifier | **PASS** | `filesystem Used before the userspace transaction: 1639776256 bytes` |
| 8 | a transaction that installs a package leaves the live root untouched | **PASS** | `error: package 'tree' was not found` |
| 9 | the swap happened: @ is the new root and the old one is kept | **PASS** | `saved boot files: /boot/omarchy-tx/prev` |
| 10 | the machine is still running the OLD root and says so | **PASS** | `saved boot files: /boot/omarchy-tx/prev` |
| 11 | the cost of the transaction is measured | **PASS** | `delta:       1888256 bytes (1 MiB)` |
| 12 | the machine reboots into the new root | **PASS** | `round trip 69s` |
| 13 | after the reboot the root subvolume is @ again | **PASS** | `saved boot files: /boot/omarchy-tx/prev` |
| 14 | and the package the transaction installed is there | **PASS** | `tree 2.3.2-1` |
| 15 | the snapper snapshot taken before the transaction is in the record | **PASS** | `2 \| single \|       \| Sat Aug 29 16:17:30 2026 \| root \| number  \| 4.0.1-9     \|` |
| 16 | the machine is reachable, firewalled and running its services | **PASS** | `UKI before the kernel transaction: 9c10cb42403aacc02acfefc1cc8d7cce…` |
| 17 | a transaction that reinstalls the kernel rebuilds and re-signs the UKI | **PASS** | `uki-rebuilt` |
| 18 | the UKI the transaction wrote is signed by this machine's key | **PASS** | `unsigned=0` |
| 19 | limine.conf records the hash of the signed UKI the transaction wrote | **PASS** | `hash-ok` |
| 20 | the machine reboots into the kernel the transaction built | **PASS** | `round trip 10s` |
| 21 | Secure Boot is still enforcing after a transactional kernel change | **PASS** | `7.1.11-arch1-1` |
| 22 | module signature enforcement survived it | **PASS** | `Y` |
| 23 | the cmdline is byte for byte the one the machine has always booted | **PASS** | `root=PARTUUID=e616c218-2b85-4f0b-ba64-6d6dfebf204b zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs  lo…` |
| 24 | a transaction whose hook fails leaves nothing behind | **PASS** | `exit=1` |
| 25 | no transaction subvolume survived the failure | **PASS** | `saved boot files: /boot/omarchy-tx/prev` |
| 26 | the failed package is not installed on the live root | **PASS** | `error: package 'cowsay' was not found` |
| 27 | the ESP is byte for byte what it was before the failed transaction | **PASS** | `esp-unchanged` |
| 28 | the machine is still healthy after the failed transaction | **PASS** | `7.1.11-arch1-1` |
| 29 | there is a previous root to roll back to | **PASS** | `saved boot files: /boot/omarchy-tx/prev` |
| 30 | rollback swaps the previous root back in and reboots | **PASS** | `round trip 11s` |
| 31 | the machine is running @ again, and the failed root is kept as @failed-* | **PASS** | `saved boot files: /boot/omarchy-tx/prev` |
| 32 | the rolled-back root boots, with Secure Boot still enforcing | **PASS** | `Y` |
| 33 | the machine is reachable and its services are up after the rollback | **PASS** | `Status: active` |
| 34 | pruning removes the roots beyond the keep count | **PASS** | `saved boot files: /boot/omarchy-tx/prev` |

## How the new root is selected

This is the decision the whole mode turns on, and two of the three candidates
were ruled out by facts about *this* profile rather than by preference.

**`btrfs subvolume set-default` — ruled out.** The kernel command line carries
`rootflags=subvol=@` explicitly. It is in `/etc/kernel/cmdline`, in
`/etc/default/limine`, and in every entry `limine-entry-tool` generates. An
explicit `subvol=` always wins over the filesystem's default subvolume, so
setting the default changes nothing at all.

**Pointing the limine entry at the new subvolume — ruled out.** It works, and
`limine-snapper-sync` already does exactly this for snapshot entries
(`rootflags=subvol=/@/.snapshots/N/snapshot`), so the path is proven. What
makes it wrong here is the maintenance: the subvolume name would have to be
written into `/etc/kernel/cmdline`, `/etc/default/limine` and `limine.conf` on
every single transaction, and all three of those files are regenerated by a
pacman hook *inside* the transaction that is trying to change them. It also
makes the boot configuration drift by one name per update, which is the thing
that has to stay boring on a machine nobody logs into.

One thing this route is **not** blocked by, and the run says so: the UKI on
this profile carries no embedded `.cmdline` section, so the command line
limine passes is the command line the kernel gets, Secure Boot or not. That is
worth writing down on its own — it means the `lockdown=integrity
module.sig_enforce=1` this profile relies on lives in `limine.conf` on the ESP
and not inside the signature. `docs/secure-boot.md` does not currently say so.

**Renaming subvolumes — chosen.**

```
@          ->  @prev-<ts>      the root that was running
@tx-<ts>   ->  @               the root the transaction built
```

The command line, the UKI, `/etc/fstab` and every hook stay byte for byte what
they were — item 23 of the acceptance list checks precisely that. Nothing about
the boot path changes, so nothing about the boot path can regress, and the
signed chain is untouched under Secure Boot. Rollback is the same two renames
in the other direction, which is the property that matters at 03:00.

### What renaming does not carry, and what was done about it

**Nested subvolumes.** A btrfs snapshot is not recursive. `.snapshots`,
`var/lib/machines` and `var/lib/portables` are subvolumes nested inside `@`, so
they arrive in the transaction as empty directories. `.snapshots` is the record
of every snapper snapshot the machine has, so the swap re-creates it in the new
root and re-snapshots each retained snapper snapshot into it — read-only
reflinks, so it is metadata only. The other two are empty by definition and are
simply re-created as subvolumes.

**The ESP.** `/boot` is one vfat partition shared by every root, so the
mkinitcpio and sbctl hooks that run inside the transaction overwrite the UKI
the *currently running* kernel boots from. Fine going forward, fatal going
backwards. So the pre-transaction UKI and `limine.conf` are copied to
`/boot/omarchy-tx/prev/` before the transaction starts; a failed transaction
restores them immediately (item 27: the ESP is byte for byte what it was), and
a rollback restores them before swapping the names back. They were signed when
they were saved, so nothing has to be re-signed on the way out.

**Atomicity.** The two renames are two syscalls with nothing between them, and
btrfs has no atomic rename pair. For the width of that window the filesystem has
no subvolume called `@`, and losing power inside it drops the next boot into the
initramfs emergency shell. The repair is one line — mount `subvolid=5` and
`mv @prev-<ts> @` — and it is in `docs/transactional.md`. Every alternative
that closes the window trades it for a boot configuration that changes on every
update, which is a much larger surface for the same machine to get wrong.

## What one transaction costs

Measured on the machine itself, each shape run from the same filesystem state
(rolled back and pruned between runs). Raw output in
[`transaction-cost.txt`](../pocs/server-install/reference/srvsb/transaction-cost.txt).

| Transaction | Wall clock | Filesystem `Used` delta | ESP delta |
|---|---|---|---|
| nothing to upgrade | 3 s | +1.2 MiB | 0 |
| one small package (`tree`) | 3 s | +1.3 MiB | 0 |
| kernel reinstall (`linux`, full initramfs + UKI + sbctl signature) | 8–12 s | +173 MiB | 0 |

The floor is the snapshot itself: a reflinked copy of `@` costs metadata only,
and the ~1.2 MiB is pacman's database sync, not the root filesystem. The kernel
number is the honest ceiling for a routine update — a new `/usr/lib/modules`
tree and a new 38 MiB UKI staged through `/tmp`, held twice for as long as
`@prev-<ts>` is retained. `keep=1` is the default, so the steady-state cost of
the mode is *one* previous root.

The ESP does not grow: the saved copy under `/boot/omarchy-tx/prev/` replaces
the previous saved copy rather than accumulating, and the UKI is written in
place. `/boot` on this profile is 2 GiB with 150 MiB in use.

Reboots, measured by boot id round trip: **10–11 s** on this VM. The first one
in the acceptance run reads 69 s, which is the restore-from-snapshot boot and
not a transaction cost.

## Interplay

**Secure Boot — clean.** The sbctl keys live at `/var/lib/sbctl`, which is on
the root subvolume and therefore inside the transaction; the ESP is the same
partition either side. So `mkinitcpio` builds the UKI inside the chroot, the
`sbctl` post hook signs it there with the same key, `limine-entry-tool` writes
the entry with the hash of the signed file, and the machine boots it. Items
17–22: the UKI was rebuilt, `sbctl verify` reports zero unsigned binaries,
`limine.conf` records the hash of the file on disk, and after the reboot
`secure_boot: true`, lockdown and `module.sig_enforce=1` are all still in force.
Nothing was signed by hand and no key left the machine.

**The restart classifier — bypassed, by design and by test.** In-place mode
ends with `omarchy-server-update-restart`, which reads the pacman transaction
and `/proc/<pid>/maps` and restarts what is running replaced code. In
transactional mode there is nothing to classify: no file under the running root
moved, so no process is running replaced code. Item 7 asserts the absence —
zero `restarted:` / `deferred:` / `reboot required:` lines — rather than
trusting the code path. A transaction is always a reboot; that is the trade.

**The unattended timer — same entry point.** `ExecStart` is
`/usr/bin/omarchy-server-update run`, which reads `/etc/omarchy-server-update.conf`,
so `omarchy-server-update transactional on` configures the timer too (items 3–5).
The two toggles in that file are written key by key, because a whole-file
rewrite would have dropped whichever of `KEXEC` and `TRANSACTIONAL` was set
first — item 4 exists because the first implementation did exactly that.

**SELinux — not run.** See the limitations.

## Mode B — an immutable root

**Verdict: not now.** Not because it does not work, but because on this profile
it buys almost nothing that mode A has not already bought, and it costs an
installer change that every existing machine would need reinstalling to get.

What it would take, concretely:

1. **`@var` as its own subvolume**, in the `btrfs` list of the archinstall
   config the installer consumes (`pocs/lab/mkcidata.sh`, and the ISO
   configurator that writes the same JSON). Without it, `/var/lib`, `/var/tmp`
   and `/var/lib/sbctl` are on the read-only root. `@log` and `@pkg` already
   exist and would become children of it or stay as they are.
2. **A writable `/etc`**, either an overlayfs upper on `/var` or its own
   subvolume. An overlay is what makes rollback of `/etc` follow rollback of
   `/usr`, which is the property worth having; it is also one more thing
   between a rescue shell and the file it needs to fix.
3. **`/usr/local`, `/opt`, `/srv`, `/root`** all move or become symlinks into
   `/var`. `/opt` is not hypothetical: the `docker` addon puts containerd's
   state under `/opt/containerd`.
4. **Every write path goes through mode A.** `omarchy-server-addon`, a one-off
   `pacman -S`, a `sbctl enroll` that writes `/var/lib/sbctl` — the first two
   need the transaction chroot, which mode A already provides
   (`omarchy-server-transaction run --with PKG`).
5. **SELinux relabelling** on a read-only root cannot be done in place; it
   becomes another transaction.

What it would buy: a root that a compromised service cannot write to. What it
would not buy: any of the update safety, because that is what mode A is. And
what it would cost beyond the list above is the thing this profile is built to
avoid — a headless machine where the recovery procedure is longer than "ssh in
and edit the file".

The one piece of mode B worth taking on its own is **`.snapshots` as a
top-level `@snapshots` subvolume** mounted by fstab, which is the openSUSE
layout. It would remove the re-snapshot loop in the swap, make snapper's record
survive every root change for free, and make booting a snapshot show the other
snapshots. That is an installer change with a migration, and it is the natural
follow-up to this spike.

No prototype was built. `btrfs property set / ro true` on the live VM was
considered and dropped: it measures what breaks in a configuration nobody would
ship (no writable `/etc`, no `@var`), so the failures it produces would not be
the failures mode B would have.

### Attack surface

| Metric | Value |
|---|---|
| Packages installed | **224** |
| Explicitly installed | **22** |
| Installed as a dependency | **202** |
| Installed size (MiB) | **1416** |
| `linux-firmware` (MiB) | **408** |
| Enabled unit files | **21** |
| Masked unit files | **13** |
| Listening sockets (`ss -ltnup`) | **6** |
| setuid/setgid binaries | **17** |
| Services running as root | **9** |

### Reboot survival

The machine came back over ssh after `systemctl reboot`.

| | |
|---|---|
| Verdict | rebooted: boot time moved from 2026-08-29 15:42:05 to 2026-08-29 15:42:14 |
| ssh | ssh answered 0s after the reboot request |
| Boot | Startup finished in 647ms (firmware) + 2.717s (loader) + 930ms (kernel) + 2.646s (userspace) = 6.941s |
| Failed units | 0 loaded units listed. |

## Evidence

- [`acceptance-secureboot.txt`](../pocs/server-install/reference/srvsb/acceptance-secureboot.txt) — the acceptance run, raw
- [`acceptance-transactional.txt`](../pocs/server-install/reference/srvsb/acceptance-transactional.txt) — the acceptance run, raw
- [`surface.txt`](../pocs/server-install/reference/srvsb/surface.txt) — the attack-surface measurements, raw
- [`reboot-check.txt`](../pocs/server-install/reference/srvsb/reboot-check.txt) — the reboot survival check
- [`packages-all.txt`](../pocs/server-install/reference/srvsb/packages-all.txt) — the package list of the installed machine
- [`boot-time.txt`](../pocs/server-install/reference/srvsb/boot-time.txt) — boot timing
- [`omarchy-install.log`](../pocs/server-install/reference/srvsb/omarchy-install.log) — the install log of the orchestrator

## Limitations

_The tables above were written by `serverlab report` from the evidence files
listed above._ They are the run; what the run does **not** prove belongs here.

**SELinux was not exercised.** The plan was a second pass on the `srvsel` lab.
That machine turned out to be in the half-configured state the mandatory-access
-control work left it in — the SELinux packages and `/etc/selinux/config` are
there and set to enforcing, but `/etc/limine-entry-tool.d/omarchy-lsm-selinux.conf`
is absent, so `lsm=selinux` never reached the kernel and `sestatus` reports
`disabled`. Fixing that is the open item in
[the mandatory access control report](2026-08-29-mandatory-access-control.md),
not this one, and it was not worth spending the spike's remaining time on. So
the SELinux claims in `docs/transactional.md` are reasoned, not measured: a
btrfs snapshot shares the metadata of the subvolume it was taken from, `security.*`
xattrs included, so no relabel is implied; `/boot` and `/var/log` are bind
mounts of the live objects, so their labels cannot change; and files pacman
*creates* inside the chroot are labelled by the policy loaded in the running
kernel, which is the same situation an in-place update is already in. **That
enforcing survives a transactional kernel update is untested.**

**The rollback was proved against a kernel reinstall, not a kernel downgrade.**
Arch had nothing newer than the installed set on the day of the run
(`pacman -Qu` was empty), so every transaction was driven by `--with` —
`tree` for a userspace change, `linux` for a kernel change. A reinstall
rebuilds the initramfs and the UKI and re-signs them, which is the whole
mechanism, but both roots ended up carrying kernel `7.1.11-arch1-1`. A rollback
across two different kernel *versions* would additionally prove that the
restored UKI matches the restored `/usr/lib/modules`, and it has not been run.

**The atomicity window was reasoned about, not induced.** No run pulled the
power between the two renames. The repair procedure in `docs/transactional.md`
is written from the mechanism, not from having needed it.

**Nothing here has run on hardware.** One QEMU/KVM VM, OVMF firmware, a virtio
disk, user-mode networking. The wall-clock numbers are host-dependent — an
8 s kernel transaction is a laptop NVMe with the package already in `@pkg`, not
a small VPS pulling 38 MiB over its uplink.

**Two bugs the run found, both fixed and both re-tested from a clean disk:**

* `pacman`'s free-space check aborted every transaction with `could not
  determine root mount point /` until the transaction's root was bind-mounted
  onto itself. That is the one line `arch-chroot` exists for.
* The command's own top-level mount lives under `/run`, so binding `/run`
  recursively into the chroot copied the transaction into itself and left a
  mount tree that could not be unwound. A non-recursive `--bind` is correct
  here: nothing under `/run` that an update needs is a mount of its own.

And one behaviour worth knowing rather than fixing: `snapper create` reported
`Server-side plugin '/usr/lib/snapper/plugins/10-limine-snapper-sync' failed`
on one run out of many, when transactions were driven back to back with no
reboot between them. The transaction continued without a snapper snapshot, said
so, and the swap and rollback were unaffected. It has not been root-caused.
