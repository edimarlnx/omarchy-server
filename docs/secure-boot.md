# Secure Boot with the machine's own keys

An installed Omarchy Server can boot with Secure Boot **enforcing**, where every
EFI binary in the chain is signed by a key that machine generated for itself,
unsigned kernels and out-of-tree modules are refused, and a kernel upgrade
leaves it that way without anyone touching it.

This is opt-in. It costs one package (`sbctl`, an addon), one drop-in on the
kernel cmdline and one enrollment step at the firmware. The base install does
not carry any of it.

```bash
sudo omarchy-server-addon secureboot     # keys, cmdline, signatures
sudo omarchy-server-secureboot enroll    # hand the keys to the firmware
sudo omarchy-server-secureboot status    # what the firmware and kernel say
```

---

## 1. Two roads, and why this one

Upstream's `plans/consumer-secure-boot.md` describes the **shim + MOK** path:
ship a `shim` signed by Microsoft's UEFI CA, have it verify a machine-local MOK,
and enroll that MOK through MokManager on first boot. That is the right design
for a consumer laptop whose firmware you do not control and whose owner will
never open the firmware setup screen. It costs a Microsoft signature on the
shim, a second verification layer, and a blue MokManager screen that somebody
has to click through at the console.

That upstream plan calls the alternative — "OEM / own firmware keys" — out as a
separate track. This is that track, and for a server it is the better one:

- **A server has no console user.** MokManager is a full-screen interactive
  program on tty0. A headless machine cannot answer it.
- **The firmware is ours.** A VM's OVMF, or a rack machine whose BIOS we
  configure once during provisioning, will happily accept a platform key we
  choose. There is nobody to ask permission from.
- **Fewer moving parts.** No shim, no MOK database, no second bootloader stage,
  and no dependence on a Microsoft-signed binary staying trusted. The chain is
  `firmware → Limine → UKI`, and each link is verified by a certificate in the
  firmware's own `db`.
- **The key is the machine's.** Nothing signs Omarchy Server centrally, so
  there is no signing key to protect, leak or rotate across a fleet. Every
  machine is its own CA; compromising one buys nothing anywhere else.

The cost is honest and worth naming: **the firmware has to be put into Setup
Mode once**, which on real hardware means a trip to the setup screen (§6).

---

## 2. What actually signs what

Almost nothing here is new code. The Arch boot stack this profile already runs
has Secure Boot support built into it, gated on one condition: *are there sbctl
keys on this machine?*

| Binary | Written by | Signed by |
| --- | --- | --- |
| `/boot/EFI/limine/limine_x64.efi` | `limine-install` | `sb_sign()` in `/usr/lib/limine/limine-common-functions`, called from `enroll_config`, which runs as `/etc/boot/hooks/post.d/90-limine-enroll-config` at the end of every `limine-install` |
| `/boot/EFI/Linux/omarchy_linux.efi` (the UKI) | `mkinitcpio --uki` via `limine-mkinitcpio-install` | `/usr/lib/initcpio/post/sbctl`, run by mkinitcpio on the temporary file **before** limine-entry-tool copies it to the ESP |
| `/boot/EFI/BOOT/BOOTX64.EFI` (removable fallback) | `limine-install` | `sbctl sign-all` from `zz-sbctl.hook` |
| anything else in sbctl's database | — | `sbctl sign-all -g`, `zz-sbctl.hook`, `PostTransaction` |

Every one of those checks `sbctl setup --print-state --json` and does nothing
when it comes back `"installed": false`. So **creating the keys is the switch**.
`install/server/secureboot-server.sh` creates them and gets out of the way; the
profile ships no signing hook of its own, because writing one would mean
duplicating three that already work.

Two ordering facts make this hold together, and both are worth knowing before
changing anything here:

1. **The UKI is signed before its hash is recorded.** `limine-mkinitcpio-install`
   builds the UKI into `$TMP_DIR`, mkinitcpio's sbctl post-hook signs it there,
   and only then does `limine-entry-tool --add-uki` copy it to the ESP and write
   `path: boot():/EFI/Linux/omarchy_linux.efi#<blake2b>` into `limine.conf`. The
   hash in the config is therefore the hash of the *signed* image. Sign the UKI
   after that point and the hash no longer matches (this profile sets
   `hash_mismatch_panic: no`, so it would warn and boot rather than panic — but
   it would be wrong).
2. **The removable fallback is nobody's job until a transaction happens.**
   `limine-entry-tool` signs only the primary `limine_x64.efi`; `/EFI/BOOT/
   BOOTX64.EFI` is covered by `sbctl sign-all` from `zz-sbctl.hook`, which
   fires on pacman transactions. During an install nothing installs a package
   after `limine-install` writes it, so it would stay unsigned —
   `omarchy-server-secureboot enroll` signs the chain itself before verifying,
   which is what closes that gap.
3. **`enroll_config` re-signs the Limine binary every time.** It restores
   `limine_x64.efi` from `limine_x64.bak` whenever the two differ — which they
   always do once we have signed it — and then calls `sb_sign` again. So the
   signature survives package upgrades without anyone tracking it.

### Why `sbctl` and not `sbsign`

The owner's premise is fewer packages, and `sbsigntools` is the smaller
dependency. It is still the wrong choice here. `sbsign` signs a file; it has no
key store, no database of what is meant to be signed, and no integration with
the two hooks above — which look for `sbctl` specifically, by name. Choosing
`sbsign` would mean writing and maintaining a pacman hook, a mkinitcpio post
hook and a limine post hook to re-implement code that already ships and is
already tested by everyone else running Arch with Secure Boot.

`sbctl` is 11 MiB of static Go binary, no daemon, no listening socket, no setuid
path, and it lands **only on machines that asked for Secure Boot**, because it
is an addon (`profile/server/addons/secureboot.packages`) and not part of the
core package list.

---

## 3. Keys

`sbctl create-keys` generates the full triplet on the target, at install time:

```
/var/lib/sbctl/GUID
/var/lib/sbctl/keys/PK/PK.key   PK.pem      platform key
/var/lib/sbctl/keys/KEK/KEK.key KEK.pem     key exchange key
/var/lib/sbctl/keys/db/db.key   db.pem      the one that signs binaries
```

- **Generated per machine, never shipped.** No private key is in a package, in
  this repository, on the ISO or on the ESP. Two servers installed from the same
  ISO have unrelated keys.
- **Root only.** sbctl writes the `.key`/`.pem` files `0400 root:root` but
  leaves the directories `0755`; `secureboot-server.sh` tightens every directory
  in the tree to `0700`, so the key material is not even enumerable by a local
  account.
- **On `@`, not on the ESP.** `/var/lib` is on the btrfs root subvolume, so the
  keys are covered by snapshots and by the `@factory` snapshot, and a FAT
  partition that any OS can mount never holds them.
- **Backups matter.** Lose `/var/lib/sbctl` and the machine can still boot (the
  firmware keeps the enrolled certificates), but nothing new can be signed —
  the next kernel upgrade produces a UKI the firmware will refuse. Recovery is
  Setup Mode plus a fresh `keys` + `sign` + `enroll` cycle.

---

## 4. Kernel command line

`install/server/secureboot-server.sh` writes
`/etc/limine-entry-tool.d/omarchy-secureboot.conf`:

```
KERNEL_CMDLINE[default]+=" lockdown=integrity module.sig_enforce=1"
```

It is a separate file from the profile's `omarchy-defaults.conf` and sorts after
it, so limine-entry-tool reads it second and the `+=` appends to the server
cmdline rather than replacing it. It exists only on machines that ran the addon.

**`lockdown=integrity`** — Arch builds the lockdown LSM in and lists it in
`CONFIG_LSM`, but ships it inactive (`CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE=y`), so
enabling Secure Boot does *not* by itself stop root from replacing the running
kernel. `integrity` closes the paths that would let it: `/dev/mem`,
`kexec_load` of an unsigned image, unsigned module loading, hibernation to an
unverified image, direct PCI/MSR access. Not `confidentiality`, which also
blocks reading kernel memory and takes perf, kprobes and much of BPF with it —
tools a server actually uses.

**`module.sig_enforce=1`** — states the module rule explicitly rather than
inheriting it from lockdown, so it holds on any boot. Arch signs its in-tree
modules with an ephemeral build-time key whose public half is compiled into the
kernel, so the stock module set loads normally; see §8 for out-of-tree modules.

Because the cmdline is embedded in the UKI, and the UKI is signed, **the
cmdline is part of what Secure Boot protects**. That is the point of the UKI
here, and it is what makes the boundary in §7 defensible.

---

## 5. Install-time flow

The autoinstall drive carries a `secureboot` marker file
(`pocs/lab/mkcidata.sh --secureboot`); `omarchy-cidata-load` copies it to
`/root`, and `OMARCHY_SECURE_BOOT=1` in the live environment does the same job.
The orchestrator (`iso/patches/0010-orchestrator-secure-boot.patch`) then:

1. **prepends `secureboot` to the requested addon list**, so the existing
   `install_addons` phase installs `sbctl` from the ISO's offline mirror and
   sources `install/server/secureboot-server.sh`. That phase runs *before*
   `finalize_limine_boot`, which is required: the cmdline drop-in has to exist
   before the UKI that embeds it is built;
2. **exports `OMARCHY_SECURE_BOOT`** into the chroot environment beside
   `OMARCHY_PROFILE` and `OMARCHY_UNATTENDED_UPDATES`;
3. adds one phase, **`enroll_secure_boot`, after `validate_boot`**, which runs
   `omarchy-server-secureboot enroll` in the target.

Enrollment is last on purpose. Handing the firmware a platform key is the moment
it starts refusing everything it cannot verify, so it happens only after the
boot chain has been written, signed and validated — and `enroll` itself runs
`sbctl verify` first and refuses to enroll into a chain that is not fully
signed. A machine whose firmware is not in Setup Mode is not an install failure:
the command prints the firmware steps and exits 0, leaving an install that is
signed and ready.

```
run_system_finalizer          keys? no. cmdline? no. (base setup)
install_addons                → secureboot: sbctl, keys, cmdline drop-in
stage_provisioning_state
finalize_limine_boot          → limine-update: UKI built + SIGNED, limine EFI SIGNED
run_chroot_finalizer …
validate_boot
enroll_secure_boot            → sbctl verify, then sbctl enroll-keys --microsoft
create_factory_snapshot
```

### Two things `enroll` does that are easy to miss

**It signs before it verifies.** See §2, point 2: the removable fallback would
otherwise still be unsigned at that point in the install. `sbctl sign` on an
already-signed file is a no-op, so this costs nothing and closes the gap
wherever it appears.

**It passes `-i` (`--ignore-immutable`).** efivarfs sets the immutable
attribute on every variable file that already exists, as a guard against
`rm -rf /sys` taking the firmware's configuration with it. A variable store
that entered Setup Mode with `KEK` and `db` still populated — which is exactly
what OVMF's does when only the PK was cleared (§6) — therefore has immutable
`KEK` and `db` files, and sbctl refuses to touch them rather than clearing the
flag itself (`You need to chattr -i files in efivarfs`). Replacing those two
variables is precisely the operation being asked for, so the guard is not
protecting anything the command has not already decided to do.

Also worth knowing when reading the code: **`sbctl verify` exits 0 even when it
has just reported an unsigned file**. Its report is what carries the answer
(one `✗ … is not signed` line per file), which is why both the command and the
acceptance script parse it instead of checking `$?`.

### `--microsoft`

`enroll-keys --microsoft` puts Microsoft's UEFI CA into `db` alongside the
machine's own certificate. The reason is option ROMs: the firmware on a plug-in
NIC, RAID controller or GPU is signed by that CA and nothing else, and firmware
that cannot verify it may refuse to initialise the device — on a headless
machine that can mean no disk and no network. The cost is explicit: those CAs
can also vouch for a third-party shim, which is a loader we do not control. On
hardware with no add-in cards (a VM, for instance), drop it:

```bash
sudo sbctl enroll-keys        # no --microsoft: only this machine's db
```

---

## 6. Lab flow (QEMU/OVMF)

The distro's `OVMF_VARS_4M.secboot.qcow2` is **not** in Setup Mode: it ships
with Microsoft's PK, KEK and db already enrolled, so the firmware enforces from
the first boot. Two things are then impossible in one VM — the live ISO is
unsigned (upstream builds it with an unsigned GRUB), so the installer would not
boot at all; and `sbctl enroll-keys` would have nothing it is allowed to write.

`vm.sh <name> create --secboot` fixes both by deleting the platform key from the
variable store:

```bash
virt-fw-vars --inplace vars.qcow2 --delete PK
```

That is the file-level equivalent of the firmware setup screen's "erase all
Secure Boot variables" / "reset to Setup Mode". With no PK, OVMF reports
`SetupMode=1`, enforces nothing, and accepts unauthenticated writes to
`PK`/`KEK`/`db`. `KEK`, `db` and `dbx` are left in place: `enroll-keys`
overwrites the first two and Microsoft's revocation list in `dbx` is worth
keeping. (`virt-fw-vars` is `python-virt-firmware` on Arch, `virt-firmware` on
Fedora. `EnrollDefaultKeys.efi` shipped beside the OVMF images does the opposite
job — it *adds* the default keys — and is not what this needs.)

So the lab installs with a Secure Boot **firmware** that is not yet
**enforcing**, enrolls during the install, and enforces from the next boot:

```bash
# 1. cidata that asks for Secure Boot
pocs/lab/mkcidata.sh --profile server --secureboot \
  --hostname srvsb --out pocs/lab/out-server-secboot

# 2. a VM whose firmware is in Setup Mode
LAB_OUT=pocs/lab/out-server-secboot pocs/lab/vm.sh srvsb create --secboot
LAB_OUT=pocs/lab/out-server-secboot pocs/lab/vm.sh srvsb start \
  --iso iso/release/<iso> --cidata pocs/lab/out-server-secboot/cidata.iso

# 3. when the install finishes: detach the ISO and boot the installed system.
#    Secure Boot is now ENFORCING, and the unsigned ISO would be refused.
LAB_OUT=pocs/lab/out-server-secboot pocs/lab/vm.sh srvsb stop
LAB_OUT=pocs/lab/out-server-secboot pocs/lab/vm.sh srvsb start --iso /dev/null --cidata /dev/null

# 4. acceptance
LAB_OUT=pocs/lab/out-server-secboot pocs/server-install/acceptance-secureboot.sh srvsb
```

`vm.sh` records the choice in `out/vm/<name>/secboot`, because OVMF's secboot
variable store only works against the secboot `CODE` image and pairing them
wrongly boots a firmware that cannot see its own variables.

**The live ISO is unsigned.** There is no way around that from here: it is
built upstream with an unsigned GRUB, and signing it would mean signing a
bootloader that then loads an unverified kernel from a squashfs — a chain worth
nothing. The practical consequences:

- install with the firmware in Setup Mode (as above), or with Secure Boot
  disabled and enabled afterwards;
- to re-run the installer on a machine that is already enforcing, clear the PK
  (`omarchy-server-secureboot` cannot do this; it is a firmware-screen action)
  or disable Secure Boot for the length of the install.

---

## 7. What this does and does not protect

**The boundary is: only EFI binaries signed by this machine's `db` key run, and
the kernel command line is inside one of them.**

Held:

- an attacker with the disk in their hand cannot swap in their own kernel,
  initramfs or bootloader — the firmware refuses to execute an unsigned image;
- they cannot append `init=/bin/sh` or drop `lockdown=` from the cmdline, because
  the cmdline is baked into the signed UKI and limine ignores the `cmdline:` in
  `limine.conf` for a UKI entry;
- root on the running system cannot load an unsigned module or kexec an
  unsigned kernel (`lockdown=integrity`, `module.sig_enforce=1`);
- a kernel upgrade cannot silently produce an unsigned UKI: the same hooks that
  build it sign it.

Not held:

- **`limine.conf` is not verified.** It lives on a FAT partition anybody can
  mount and limine reads it as-is. An attacker can edit it — change the default
  entry, point it at a different signed UKI, delete entries. What they cannot do
  is make it boot something the firmware will not verify. Limine *can* enroll a
  hash of its config into its own signed binary
  (`ENABLE_ENROLL_LIMINE_CONFIG=yes`), which would close this; it is off here
  because `limine-snapper-sync` rewrites `limine.conf` whenever a snapshot
  appears or is cleaned up, outside the hook that would re-enroll the hash, and
  a mismatch at that point is a machine that will not boot unattended. Revisit
  if snapshot entries are ever turned off.
- **The initramfs is not separately verified** — it does not need to be, it is
  inside the signed UKI. But this also means every initramfs rebuild is a
  re-signature; a machine whose keys are gone (§3) cannot produce a bootable one.
- **The live ISO is unsigned** (§6).
- **Nothing here measures anything.** This is signature verification, not
  attestation. There is no TPM PCR policy and no sealed secret; a signed but
  malicious-by-configuration system boots exactly as happily. LUKS with a TPM2
  policy is a separate piece of work that would build on this one.
- **`--microsoft` widens `db`** by two CAs (§5).

---

## 8. Out-of-tree modules

`module.sig_enforce=1` refuses any module whose signature the kernel cannot
verify against its built-in or platform keyring. Arch's in-tree modules are
signed at build time with an ephemeral key compiled into that kernel, so they
load. A DKMS module — ZFS being the case this profile will meet first — is built
locally and is unsigned, so it will not.

The fix is to sign it with the same `db` key the firmware already trusts, by
pointing DKMS's `sign_tool` at `/var/lib/sbctl/keys/db/db.{key,pem}` so every
rebuild signs its output, and enrolling that certificate into the kernel's
`machine` keyring (Arch builds `CONFIG_INTEGRITY_MACHINE_KEYRING`, which accepts
`db` certificates from the firmware). That is **not implemented here** — see the
handover note in the ZFS work.

---

## 9. Rotating to a different key later

Nothing in this design assumes the key stays machine-local forever. To move a
fleet onto one organisational signing key:

1. put the new certificate in `db` — `sbctl enroll-keys --append` with the new
   cert, or re-enroll the whole set from a firmware in Setup Mode;
2. re-sign the chain with the new key: replace `/var/lib/sbctl/keys/db/` with
   the organisational pair (`sbctl import-keys`), then
   `sudo omarchy-server-secureboot sign`;
3. reboot, confirm with `omarchy-server-secureboot status`, and only then remove
   the old certificate from `db`.

Keeping both certificates in `db` across the transition is what makes it safe to
do without a console: at every point in the sequence there is a key in `db` that
matches what is currently on the ESP. `sbctl rotate-keys` automates the same
sequence when the firmware is reachable in Setup Mode.

---

## 10. Reference

- `profile/server/addons/secureboot.packages` — the addon (`sbctl`)
- `profile/server/overlay/runtime/install/server/secureboot-server.sh` — keys,
  cmdline drop-in, sbctl database
- `profile/server/overlay/runtime/install/server/addons/secureboot.sh` — the
  addon leaf that sources it
- `profile/server/overlay/runtime/bin/omarchy-server-secureboot` — `status`,
  `enroll`, `sign`, `keys`
- `iso/patches/0010-orchestrator-secure-boot.patch` — cidata marker, chroot env,
  addon injection, `enroll_secure_boot` phase
- `pocs/lab/vm.sh --secboot`, `pocs/lab/mkcidata.sh --secureboot`
- `pocs/server-install/acceptance-secureboot.sh` — the acceptance run
- upstream `plans/consumer-secure-boot.md` — the shim + MOK track this is not
