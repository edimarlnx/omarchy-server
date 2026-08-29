# Secure Boot with keys the machine generates for itself

**Date:** 2026-08-29
**Subject:** own-keys Secure Boot, enrolled during a headless install
**Result:** **24 passed, 0 failed** on VM `srvsb`, including a tampered module refused, a kernel reinstall that re-signed itself, and a reboot that came back enforcing

## Scope

An installed Omarchy Server can boot with Secure Boot **enforcing** against a
PK/KEK/db triplet generated on the target at install time. The Limine binary,
its removable fallback and the UKI are all signed by that `db` key; unsigned
kernels and out-of-tree modules are refused; a kernel upgrade re-signs the chain
without anyone asking it to.

It is opt-in, and it costs exactly one package (`sbctl`, an addon) on the
machines that ask.

## The route, and why

Upstream's plan for consumer machines is the **shim + MOK** track: a `shim`
signed by Microsoft's UEFI CA verifying a machine-local MOK, enrolled through
MokManager on first boot. That is right for a laptop whose firmware you do not
control. It is wrong here, and that same plan calls the alternative — "OEM / own
firmware keys" — out as a separate track. This is that track:

- **A server has no console user.** MokManager is a full-screen interactive
  program on tty0. A headless machine cannot answer it.
- **The firmware is ours.** A VM's OVMF, or a rack machine configured once
  during provisioning, will accept a platform key we choose.
- **Fewer moving parts.** No shim, no MOK database, no second loader stage, no
  dependence on a Microsoft-signed binary staying trusted. The chain is
  `firmware → Limine → UKI`, each link verified by a certificate in the
  firmware's own `db`.
- **The key is the machine's.** Nothing signs this edition centrally, so there is
  no fleet signing key to protect, leak or rotate. Every machine is its own CA;
  compromising one buys nothing anywhere else.

The honest cost: **the firmware has to be put into Setup Mode once**, which on
real hardware means a trip to the setup screen.

**Almost none of this is new code.** The Arch boot stack this profile already
runs has Secure Boot support built in and gated on one question — *are there
sbctl keys on this machine?* `limine-entry-tool` signs the Limine EFI binary
from its own `post.d` hook; mkinitcpio signs the UKI **on the temporary file,
before** `limine-entry-tool` copies it to the ESP and records its hash, so the
hash in `limine.conf` is the hash of the *signed* image; sbctl's `zz-sbctl.hook`
re-signs everything in its database after any transaction touching `boot/`. All
three check `sbctl setup --print-state`. **Creating the keys is the entire
switch**, so the profile ships no signing hook of its own.

That also settles the package question. `sbsigntools` is smaller, but `sbsign`
has no key store, no database and no integration with those hooks, which look
for `sbctl` by name. Choosing it would mean writing and maintaining three hooks
to replace code that already ships and is tested by everyone else running Arch
with Secure Boot. `sbctl` is 11 MiB of static Go binary — no daemon, no
listening socket, no setuid path.

## Environment

| | |
|---|---|
| VM | `srvsb`, QEMU/KVM `q35`, 4 vCPU, 8 GiB RAM, 40 GiB virtio disk |
| Firmware | OVMF 4M **secboot** variable store, put into Setup Mode before first boot |
| ISO | `omarchy-2026.08.29-x86_64-server-local.iso` |
| Installed | `omarchy-server 4.0.1-3`, kernel `7.1.11-arch1-1` |
| Autoinstall | `mkcidata.sh --profile server --secureboot --hostname srvsb` |
| Run | `2026-08-29T06:07:25-03:00` |

### The firmware trick

The distro's `OVMF_VARS_4M.secboot.qcow2` is **not** in Setup Mode: it ships with
Microsoft's PK, KEK and db already enrolled, so the firmware enforces from the
first boot. Two things are then impossible in one VM — the live ISO is unsigned
(upstream builds it with an unsigned GRUB), so the installer would not boot at
all; and `sbctl enroll-keys` would have nothing it is allowed to write.

`vm.sh <name> create --secboot` deletes the platform key from the variable store:

```bash
virt-fw-vars --inplace vars.qcow2 --delete PK
```

That is the file-level equivalent of the firmware setup screen's "reset to Setup
Mode". With no PK, OVMF reports `SetupMode=1`, enforces nothing, and accepts
unauthenticated writes to `PK`/`KEK`/`db`. `KEK`, `db` and `dbx` are left in
place: `enroll-keys` overwrites the first two, and Microsoft's revocation list in
`dbx` is worth keeping. `vm.sh` records the choice in `out/vm/<name>/secboot`,
because the secboot variable store only works against the secboot `CODE` image.

## Method

```bash
pocs/lab/mkcidata.sh --profile server --secureboot --hostname srvsb \
  --out pocs/lab/out-server-secboot
LAB_OUT=pocs/lab/out-server-secboot pocs/lab/vm.sh srvsb create --secboot
LAB_OUT=pocs/lab/out-server-secboot pocs/lab/vm.sh srvsb start \
  --iso iso/release/<iso> --cidata pocs/lab/out-server-secboot/cidata.iso
# when the install finishes, detach the media and boot the installed system
LAB_OUT=pocs/lab/out-server-secboot pocs/lab/vm.sh srvsb stop
LAB_OUT=pocs/lab/out-server-secboot pocs/lab/vm.sh srvsb start --iso /dev/null --cidata /dev/null
LAB_OUT=pocs/lab/out-server-secboot pocs/server-install/acceptance-secureboot.sh srvsb
```

The orchestrator patch does three things: it **prepends `secureboot` to the
requested addon list**, so the existing `install_addons` phase installs `sbctl`
from the offline mirror and sources the setup leaf — and lands **before**
`finalize_limine_boot`, which the cmdline drop-in requires; it exports
`OMARCHY_SECURE_BOOT` into the chroot; and it adds **one** phase,
`enroll_secure_boot`, after `validate_boot`.

Enrollment is a phase of its own, and last, because handing the firmware a
platform key is the moment it starts refusing what it cannot verify. Firmware
that is not in Setup Mode gets the instructions and a clean exit rather than a
failed install.

## Results — 24 passed, 0 failed

| Item | Key evidence line |
|---|---|
| firmware enforcing with our keys | `sbctl status`: `Setup Mode: ✓ Disabled`, `Secure Boot: ✓ Enabled`, `"installed": true` |
| the firmware's own variable agrees | `SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c` byte 4 = `1` |
| the kernel saw it at handover | `[ 0.004952] Secure boot enabled` |
| every EFI binary on the ESP is signed | `✓ /boot/EFI/BOOT/BOOTX64.EFI`, `✓ /boot/EFI/Linux/omarchy_linux.efi`, `✓ /boot/EFI/limine/limine_x64.efi` — `unsigned=0` |
| `limine.conf`'s recorded hash is the hash of the **signed** UKI | recorded `==` `b2sum(file)` |
| the booted cmdline carries the lockdown options | `lockdown=integrity module.sig_enforce=1` in `/proc/cmdline` |
| lockdown is in integrity mode | `none [integrity] confidentiality` |
| module signature enforcement is on | `sig_enforce=Y` |
| the drop-in appends, it does not replace | `KERNEL_CMDLINE[default]+=` in `omarchy-secureboot.conf`; the serial console survived on the cmdline |
| keys on `@`, never on the ESP | `PK`/`KEK`/`db` under `/var/lib/sbctl`, `esp-key-files=0` |
| key material is root-only | dirs `700`, `db.key` `400`, `ls` as the user → `Permission denied` |
| an unsigned module is refused | tampered `aegis128_aesni.ko`: `insmod: ERROR: … Key was rejected by service`; `dmesg: Loading of unsigned module is rejected` |
| stock in-tree modules still load | `modprobe dummy` → `loaded` |
| a kernel reinstall rebuilds **and** re-signs the UKI | `pacman -S linux`: mkinitcpio post hook `[sbctl] ✓ Signed`, then `✓ Signed /boot/EFI/limine/limine_x64.efi`, then `(5/5) Signing EFI binaries…`; the UKI hash changed |
| `limine.conf` still records the new signed UKI | `hash-ok` after the reinstall |
| `limine-snapper-sync` keeps the config consistent | snapshot entries added, branding above the first entry intact |
| it still boots enforcing afterwards | boot id `e39a0958…` → `6afbdbb4…`; `"secure_boot": true`, `[integrity]`, `sig_enforce=Y` |

**Nothing in that list is signed by code this profile owns.** The signatures
come from `limine-entry-tool`'s `sb_sign`, mkinitcpio's
`/usr/lib/initcpio/post/sbctl` and sbctl's `zz-sbctl.hook`.

### The cmdline, and why it is protected

`install/server/secureboot-server.sh` writes
`/etc/limine-entry-tool.d/omarchy-secureboot.conf` with
`KERNEL_CMDLINE[default]+=" lockdown=integrity module.sig_enforce=1"`. It sorts
after the profile's own defaults file, so limine-entry-tool reads it second and
appends rather than replacing.

`lockdown=integrity` matters because Arch builds the lockdown LSM in but ships it
**inactive**, so enabling Secure Boot does not by itself stop root from replacing
the running kernel. `integrity` closes `/dev/mem`, `kexec_load` of an unsigned
image, unsigned module loading, hibernation to an unverified image and direct
PCI/MSR access — but not `confidentiality`, which would take perf, kprobes and
much of BPF with it. Because the cmdline is embedded in the UKI and the UKI is
signed, **the cmdline is part of what Secure Boot protects**.

## Evidence

- [`../pocs/server-install/reference/acceptance-secureboot.txt`](../pocs/server-install/reference/acceptance-secureboot.txt) — the full run, `=== 24 passed, 0 failed ===`
- [`../docs/secure-boot.md`](../docs/secure-boot.md) — the design: what signs what, the keys, the cmdline, the install flow, the lab flow, the boundary, key rotation
- [`../docs/iso-server.md`](../docs/iso-server.md) §2.2 — why it needed only one new phase
- `pocs/server-install/acceptance-secureboot.sh`, `pocs/lab/vm.sh --secboot`, `pocs/lab/mkcidata.sh --secureboot`

## Findings and bugs

1. **`sbctl verify` exits 0 while reporting an unsigned file.** The first pass of
   the acceptance script checked `$?` and called an unsigned `BOOTX64.EFI` a
   pass. Both the script and `omarchy-server-secureboot` now parse the report for
   `is not signed`.
2. **The removable fallback is signed by nobody during an install.**
   `limine-entry-tool` signs only `limine_x64.efi`; `/EFI/BOOT/BOOTX64.EFI` is
   covered by sbctl's pacman hook, and **no transaction runs after
   `limine-install` writes it**. `omarchy-server-secureboot enroll` now signs the
   chain itself before verifying, which closes the gap wherever it appears
   (`sbctl sign` on an already-signed file is a no-op).
3. **`enroll` must pass `-i` (`--ignore-immutable`).** efivarfs sets the
   immutable attribute on every variable file that already exists. A store that
   entered Setup Mode with `KEK` and `db` still populated — exactly what OVMF's
   does when only the PK was cleared — has immutable `KEK` and `db` files, and
   sbctl refuses to touch them rather than clearing the flag itself. Replacing
   those two variables is precisely the operation being asked for.
4. **`sbctl create-keys` leaves the key directories `0755`** (the `.key`/`.pem`
   files themselves are `0400 root:root`). The setup leaf tightens every
   directory to `0700`, so the key material is not even enumerable by a local
   account.
5. **Also fixed alongside this work:** every content change must bump `pkgrel`,
   because the published release addresses assets by file name — republishing
   `4.0.1-1` with new content left installed machines seeing no update at all.

## Limitations

The boundary is: **only EFI binaries signed by this machine's `db` key run, and
the kernel command line is inside one of them.** Not held:

- **`limine.conf` is not verified.** It lives on a FAT partition anybody can
  mount. An attacker can edit it — change the default entry, point it at a
  different signed UKI, delete entries — but cannot make it boot something the
  firmware will not verify. Limine can enroll a hash of its config into its own
  signed binary; that is off here because `limine-snapper-sync` rewrites
  `limine.conf` whenever a snapshot appears or is cleaned up, outside the hook
  that would re-enroll the hash, and a mismatch at that point is a machine that
  will not boot unattended.
- **The live ISO is unsigned** and there is no way around it from here: it is
  built upstream with an unsigned GRUB, and signing a bootloader that then loads
  an unverified kernel from a squashfs is a chain worth nothing. Practically:
  install with the firmware in Setup Mode, or with Secure Boot disabled and
  enabled afterwards.
- **Nothing here measures anything.** This is signature verification, not
  attestation — no TPM PCR policy, no sealed secret. A signed but
  malicious-by-configuration system boots exactly as happily.
- **`enroll-keys --microsoft` widens `db`** by two CAs. The reason is option
  ROMs — the firmware on a plug-in NIC, RAID controller or GPU is signed by that
  CA and nothing else, and firmware that cannot verify it may refuse to
  initialise the device, which on a headless machine can mean no disk and no
  network. On hardware with no add-in cards, drop the flag.
- **Losing `/var/lib/sbctl` is recoverable but not silently.** The machine still
  boots (the firmware keeps the enrolled certificates), but nothing new can be
  signed, so the next kernel upgrade produces a UKI the firmware will refuse.
- **Out-of-tree modules are refused.** A DKMS module is built locally and
  unsigned, so `module.sig_enforce=1` rejects it. Pointing DKMS's `sign_tool` at
  `/var/lib/sbctl/keys/db/db.{key,pem}` and enrolling that certificate into the
  kernel's `machine` keyring is the fix, and is **not implemented**.
- One VM, one firmware implementation. Real hardware has not been tried.

## Next steps

- Sign DKMS modules with the `db` key, for the first out-of-tree module this
  profile meets.
- Try the flow on a physical machine, where Setup Mode is a firmware-screen
  action rather than a `virt-fw-vars` call.
