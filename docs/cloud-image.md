# The cloud image

An ISO installs one machine. An image is the other shape of the same profile:
one artifact, copied onto many machines, where **nothing that makes a machine
itself may be baked in**. This document is what that costs, how the artifact is
built and validated, how to boot it on libvirt, Proxmox and OCI, and what
Secure Boot and SELinux do on the first boot of a machine that was copied
rather than installed.

The commands:

```bash
serverlab image build                 # install a throwaway machine, strip it, convert it
serverlab image test                  # boot the result with a NoCloud seed and assert
serverlab image publish --yes         # upload it to a GitHub release of this repository
```

They own no logic. The leaves are `pocs/lab/mkcidata.sh` and `pocs/lab/vm.sh`
(the ordinary install path), `pocs/image/{generalize,convert,mkseed}.sh` and
`pocs/server-install/acceptance-cloud.sh`.

---

## 1. Why an image is not a disk copy

Six things on an installed machine become a shared secret or a collision the
moment its disk is duplicated:

| | On a copied disk | Consequence |
|---|---|---|
| ssh host keys | identical on every machine | any holder of the image can impersonate every machine booted from it |
| `/etc/machine-id` | identical | systemd journal ids, DHCP client ids and `systemd-id128` derived secrets collide |
| Secure Boot PK/KEK/db | identical private keys | any machine from the image can sign a kernel the others' firmware trusts |
| `random-seed`, `credential.secret` | identical | the entropy pool starts at the same place; sealed credentials are readable across machines |
| the build account | present, with a password | a known credential on every machine |
| snapshots, logs, package cache | the build machine's | the image carries the build host's history, and gigabytes of it |

`omarchy-server-generalize` removes all six. What replaces them is decided on
the machine that boots the image, by two agents with a clean split:

* **cloud-init** owns what the *platform* knows: hostname, users, ssh
  authorized keys, the size of the root filesystem.
* **`omarchy-server-firstboot`** owns what no metadata service can supply: the
  ssh host identity, the entropy seed, the machine's own Secure Boot keys, and
  the boot entry's machine-id tag (§7.1 — the least obvious of the six, and the
  only one whose absence broke a feature rather than leaking a secret).

There is a seventh thing, and it is the one the first version of this pipeline
got wrong four different ways: **a script that says it removed something is not
evidence that it did**. Every claim in the table above is asserted against the
built artifact — by `acceptance-cloud.sh` on a booted machine, and by reading the
qcow2 directly with `guestfish` before it is ever booted.
`reports/2026-08-29-cloud-image.md` lists the four defects that found their way
into an image the build had already reported as successful.

---

## 2. The `cloud` addon

Three packages (`profile/server/addons/cloud.packages`) and one setup leaf
(`install/server/cloud-server.sh`):

| Package | Why |
|---|---|
| `cloud-init` | the agent |
| `cloud-guest-utils` | `growpart`, which cloud-init shells out to. Without it a 40 GiB image presents itself as 40 GiB on a 200 GiB boot volume |
| `qemu-guest-agent` | graceful stop and host-side freeze/thaw, which is what a hypervisor's "stop instance" and its volume backups go through |

The leaf writes one file, `/etc/cloud/cloud.cfg.d/05-omarchy-server.cfg`, and
enables the units. Four decisions in it are worth reading twice.

**The datasource list is closed:** `NoCloud, ConfigDrive, OpenStack, Oracle,
Ec2, None`. cloud-init's default is to probe everything it ships, which on a
machine with none of them is boot time spent looking for metadata services that
are not there. `None` is last so a machine with no metadata at all finishes its
boot instead of failing a unit.

**No user is baked in.** The default user is `omarchy`, `lock_passwd: true`,
with no `authorized_keys` of its own. It is a *name for the platform's metadata
keys to land on* — Ec2 and Oracle both hand cloud-init a key list and no user
name — not an account. With no keys in the metadata it is an account nobody can
log into: no password, no key, and sshd refuses password authentication anyway.

**cloud-init does not write network configuration.** The profile already owns
`/etc/systemd/network/20-wired.network` (DHCP on any wired link,
`install/server/network-server.sh`), and two sources writing networkd files is
how a machine comes up with an address on one boot and not the next. The cost
is real and is recorded in §8: a platform handing out a **static** address
through its metadata is not honoured.

**Growth is on**: `growpart` grows the partition, `resize_rootfs` runs
`btrfs filesystem resize max /`. The assertion in the acceptance list is on the
*filesystem* size, because a grown partition under an unresized filesystem is
the failure mode worth catching.

---

## 3. What `serverlab image build` does

```
mkcidata.sh --profile server --user imgbuild --addons cloud [--mac …] [--secureboot]
vm.sh create/start                                  ← the ordinary install, unattended
vm.sh wait-ssh                                      ← the install finished
pocs/image/generalize.sh   → omarchy-server-generalize --yes --remove-user imgbuild --poweroff
pocs/image/convert.sh      → qemu-img convert -c -O qcow2  + .sha256
```

A cloud image is **an ordinary install of this profile plus the removal of
everything personal**, not a separate build path that could drift from it. That
is the single most important property of this pipeline: the machine in the
image is the machine `serverlab lab test` measures.

### The build account, and the road not taken

The upstream ISO supports a `defer-provisioning` install that bakes **no**
credentials at all and finishes the user setup on the first boot. That would be
the more elegant source for an image, and it is not used, for a reason that is
written down in `docs/iso-server.md` §7 item 1: `omarchy-provision-owner`'s
setup form is still `gum`-only on this profile, so a deferred install has no
non-interactive source of answers and would sit on a prompt nobody can see.
cloud-init is the non-interactive source that path is waiting for, and wiring
the two together is a follow-up, not a prerequisite — because a throwaway
account that is provably removed reaches the same end state through a path that
exists today.

"Provably" is doing work in that sentence: `acceptance-cloud.sh` asserts by name
that `imgbuild` does not exist, that root's shadow field is `!` and not a hash,
that no `.lab-pw`, `.lab-sudo` or `sudoers.d` entry for it survived, and that
the image's journal does not mention it.

### The generalization list

In order, as `omarchy-server-generalize` does it:

| Step | What |
|---|---|
| cloud-init | `cloud-init clean --logs --seed`, then `rm -rf /var/lib/cloud` — without it the image's first boot is cloud-init's *second* and no once-per-instance module runs |
| machine-id | truncated to **empty**, not deleted: systemd reads an empty file as "first boot, generate one" |
| entropy | `/var/lib/systemd/credential.secret`, `/var/lib/dbus/machine-id` (the random seed is a special case; see below) |
| ssh | every `/etc/ssh/ssh_host_*` |
| first-boot marker | `/var/lib/omarchy/firstboot-done` |
| Secure Boot | `/var/lib/sbctl` deleted; `/var/lib/omarchy/firstboot-secureboot` written so the first boot knows to make new ones |
| SELinux | `/.autorelabel` touched (see §6) |
| root's password | **replaced with `!`**, not prefixed with it: `usermod -L` leaves the original hash recoverable from `/etc/shadow` by anyone holding the image |
| root | `/root/.ssh`, `/root/.bash_history`, caches |
| pacman | the entire package cache and the sync databases |
| snapper | every snapshot in every config |
| hostname | reset to `omarchy-server` |
| **detached phase** | every account with a uid ≥ 1000 and its home and sudoers drop-ins, `wtmp`/`btmp`/`lastlog`, the journal, the random seed, `@factory`, `fstrim -av`, poweroff |

Three of those rows are there because the first build of this pipeline shipped
an image without them, and inspecting the artifact rather than trusting the
script is what found all three:

* **`root` carried the autoinstall drive's password hash.** An image is a public
  artifact; a hash in it is a credential every machine from the image shares and
  a console login accepts.
* **An account nobody asked for survived.** The installer creates an `omarchy`
  owner account alongside the one the autoinstall drive names, so removing "the
  build account" removed one of two. `--remove-all-users` is the honest form of
  the intent — an image ships *no* account — and it is what the pipeline passes.
  Its sudoers drop-in survived too, because the installer names it
  `02_<user>` and the removal was guessing at prefixes.
* **`/var/lib/systemd/random-seed` came back after being deleted.**
  `systemd-random-seed.service` saves the pool to that file when it is *stopped*,
  which is part of every shutdown — including the one that ends the image build.
  The fix is in two places: the detached phase stops the unit and then deletes
  the file, and `omarchy-server-firstboot` replaces it on the first boot
  regardless. Worth keeping in proportion: systemd does not *credit* entropy from
  the seed file unless `SYSTEMD_RANDOM_SEED_CREDIT` says so, so a shared seed is
  untidy rather than dangerous — but "untidy" is not what an image should be.

The split into two phases is not cosmetic: the second phase deletes the account
the caller's ssh session is logged in as, so it runs as a transient systemd
unit (`systemd-run --unit=omarchy-server-generalize-finish`) outside that
session's cgroup. It is also why `@factory` is taken there — a snapshot taken
in phase 1 would contain the build account.

`fstrim` before the conversion is what makes `qemu-img convert -c` worth
anything: without it every package file the install downloaded and the
generalize deleted is still in the image as data nothing references.

### `@factory`

A read-only btrfs snapshot of the finished root, at the **top level beside
`@`**, which is where this profile's transactional update path already lives.
It is the state every machine from this image starts from, and going back to it
is the same pair of subvolume renames a transactional rollback is — which is
what makes it safe under a signed boot chain. `pocs/image/oci/reset.md` writes
the procedure out.

---

## 4. What `serverlab image test` does

```
mkseed.sh --hostname omarchy-cloud-test --user demo   → a NoCloud seed ISO
vm.sh create --from-image <qcow2> --disk-gb 40        → a copy, grown
vm.sh start --cidata seed.iso                         → no install ISO
acceptance-cloud.sh + surface.sh + reboot-check.sh
```

The seed is a `cidata`-labelled ISO carrying `user-data` and `meta-data`. Note
the label collision, deliberate on both sides: Omarchy's autoinstall drive and
cloud-init's NoCloud drive are both labelled `cidata`. They never meet — one is
read by the ISO's installer, the other by an installed machine's cloud-init —
and using the label cloud-init documents is what makes the seed work on any
cloud-init, not only ours.

The disk is deliberately **bigger than the image**, because closing that gap is
growpart's entire job.

There is no lab password anywhere in this suite, and that is a result rather
than an omission: the image ships no account with a password, so the only
account on the machine is the one cloud-init created, with a key and `NOPASSWD`
sudo. `sudo -n` either works or the machine is not what it claims to be.

The reboot check is not a formality here either — cloud-init must **not** redo
its once-per-instance work, and the machine must come back with the identity
its first boot gave it rather than a second one.

`serverlab report <name>` writes the run up from the evidence like any other
lab; the report labels the medium `Image` rather than `ISO` and the
provisioning row `NoCloud seed` rather than `Autoinstall`.

---

## 5. Booting it

### libvirt / QEMU (NoCloud)

```bash
./pocs/image/mkseed.sh --hostname box1 --user me --key ~/.ssh/id_ed25519.pub --out /tmp/seed
qemu-img convert -O qcow2 omarchy-server-<date>-x86_64.qcow2 /var/lib/libvirt/images/box1.qcow2
qemu-img resize /var/lib/libvirt/images/box1.qcow2 60G

virt-install --name box1 --memory 4096 --vcpus 2 \
  --boot uefi --os-variant archlinux \
  --disk /var/lib/libvirt/images/box1.qcow2,bus=virtio \
  --disk /tmp/seed/seed.iso,device=cdrom \
  --network network=default,model=virtio \
  --graphics none --console pty,target_type=serial --import
```

`--boot uefi` is required: the image has no MBR and no BIOS boot path. The
serial console is already configured on the guest side
(`console=ttyS0,115200` in the profile's cmdline, `serial-getty@ttyS0` enabled),
so `virsh console box1` shows the boot.

### Proxmox

Proxmox has first-class cloud-init support, which is easier than a seed ISO:

```bash
qm create 900 --name omarchy-server --memory 4096 --cores 2 \
    --net0 virtio,bridge=vmbr0 --serial0 socket --bios ovmf --machine q35
qm importdisk 900 omarchy-server-<date>-x86_64.qcow2 local-lvm
qm set 900 --scsihw virtio-scsi-pci --virtio0 local-lvm:vm-900-disk-0
qm set 900 --efidisk0 local-lvm:0,efitype=4m,pre-enrolled-keys=0
qm set 900 --ide2 local-lvm:cloudinit --boot order=virtio0
qm set 900 --ciuser me --sshkeys ~/.ssh/id_ed25519.pub --ipconfig0 ip=dhcp
qm resize 900 virtio0 +20G
qm start 900
```

`pre-enrolled-keys=0` matters if the image was built `--secboot`: see §6.
Convert the template to a Proxmox template (`qm template 900`) and every clone
is a new machine with its own identity, which is exactly the property the
generalization bought.

### OCI

`pocs/image/oci/` is the recipe; §7 is the reasoning.

---

## 5.1 The machine-id is in more places than `/etc/machine-id`

Two of them, and both matter on an image.

**The ESP is keyed by it.** `limine-snapper-sync` keeps its snapshot history and
copies of past UKIs under `/boot/<machine-id>/limine_history/`. A new machine-id
means a new tree, so the build machine's is dead weight — dead weight containing
that machine's kernel images. Generalization removes it, reading the id before
truncating `/etc/machine-id`.

**The boot entry is tagged with it.** `limine.conf` writes
`comment: machine-id=<id> order-priority=50` on every OS entry, and *this one
cannot be removed during generalization*: it is the entry the image boots from.

The consequence is not cosmetic, and it is the defect this pipeline shipped
before anyone looked. `limine-snapper-sync` attaches snapshot entries to the OS
entry carrying the **running** machine's id. On a machine from the image there
is none — so the sync ran, reported success, wrote its history, and produced no
snapshot entries at all. `snapper list` showed the snapshots present and
correct; the boot menu offered no rollback. Silently.

The fix is a handover: generalization records the old id in
`/var/lib/omarchy/firstboot-limine`, and `omarchy-server-firstboot` runs
`limine-update` — which regenerates the initramfs and the UKI and writes an entry
for the machine it is actually running on — and then removes the build machine's
entry by id. It runs **after** the Secure Boot keys are created, because the UKI
it writes has to be signed with the keys this machine now owns.

That is also the largest part of what a first boot costs: tens of seconds of
`mkinitcpio`, once, before sshd starts.

## 6. Secure Boot and SELinux on a first boot

### Secure Boot

**The keys are not in the image.** A shared image carrying a PK/KEK/db triplet
would hand every machine that boots it the private key that signs the others'
kernels, which is the opposite of what Secure Boot is for.

So an image built with `--secboot` ships: `sbctl`, the
`lockdown=integrity module.sig_enforce=1` cmdline drop-in inside the UKI, an
ESP whose binaries are signed by keys that **no longer exist**, and a marker.
On the first boot `omarchy-server-firstboot`:

1. sources `install/server/secureboot-server.sh` — creates a PK/KEK/db on
   *this* machine and re-signs the ESP binaries with it;
2. runs `omarchy-server-secureboot enroll`, which verifies the chain and then
   writes the PK — but only if the firmware is in **Setup Mode**;
3. removes the marker on success, and **keeps** it on failure, so a machine
   whose firmware was not ready tries again rather than silently giving up.

A machine whose firmware already owns a PK gets a chain signed with its own
keys, an unenrolled key set, and a journal entry saying exactly what to do:

```
firstboot: the firmware did not accept an enrollment.
           The chain is signed with this machine's keys; put the
           firmware into Setup Mode and run:
               sudo omarchy-server-secureboot enroll
```

**This is why the image must not be launched as an OCI Shielded Instance with
Secure Boot on.** OCI's shielded firmware enforces against Oracle's key set and
gives the tenant no way to enroll a PK, so a UKI signed by a machine-local key
is a UKI that firmware refuses — the instance would import, launch and never
boot. The same is true of any firmware that ships Microsoft's keys and no
Setup Mode: the honest answer there is either the shim + MOK route this profile
deliberately does not take (`docs/secure-boot.md`) or Secure Boot off.

Between them that means: `--secboot` images are for hardware and for
hypervisors whose firmware variable store you control (libvirt with a fresh
`OVMF_VARS`, Proxmox with `pre-enrolled-keys=0`). The image for a cloud is the
one without it.

### SELinux images

Measured end to end in `reports/2026-08-29-cloud-image-selinux.md`: a
`--mac selinux` image, booted from a NoCloud seed, **68 passed / 0 failed with
zero AVC denials on either boot**, and enforcing reached over ssh through the
guard.

**The image ships `SELINUX=permissive`.** Not because enforcing does not work —
a second image with that one line changed came up enforcing from its first
instruction, cloud-init and all, with zero denials — but because an image is
copied onto platforms this lab has not seen, and a machine that fails to
provision because of a policy gap is usually a machine with no console to fix it
from. Permissive turns that case into a denial list. The switch is one command
and a **two-way door**, measured on the machine the image produced:

```bash
sudo omarchy-server-selinux avc          # what would have been refused, after a day of the real workload
sudo omarchy-server-selinux enforcing    # passes its own preflight on the FIRST boot; no --force
sudo omarchy-server-selinux permissive   # and back again, from the same ssh session
```

An operator who wants enforcing baked in edits the artifact — the report's
"An image that ships enforcing" section has the `guestfish` recipe and the
measurement behind it.

#### What the first boot does, and what it costs

| | Unit | What it does | Cost |
|---|---|---|---|
| 1 | cloud-init | hostname, the account the metadata names, its home and keys, growpart + `btrfs filesystem resize` | ~1 s |
| 2 | `omarchy-server-firstboot` | ssh host keys, entropy seed, `limine-update` (mkinitcpio + UKI) | 3.6 s |
| 3 | `omarchy-server-selinux-relabel` | `restorecon -R -F /` on the `/.autorelabel` generalization left | 0.9 s |
| 4 | `systemd-user-sessions`, `sshd` | logins are possible from here | — |

The relabel is ordered **after cloud-init** and before any login. That matters
because of the failure it prevents: `reports/2026-08-29-mandatory-access-control.md`
records an operator locked out of an enforcing machine, root-caused to a home
directory created after the install-time relabel. On an image that is the normal
case — *every* account is created by cloud-init, on the first boot, after the
artifact was labelled. Without the ordering the two units were unordered against
each other and the outcome was a race that happened to come out right.

`init` is already `init_t` on boot 1, unlike a fresh install (which needs a
reboot first, because PID 1 only transitions if `/usr/lib/systemd/systemd`
already carried `init_exec_t`). The build machine relabelled `/usr` before the
artifact was taken, so the image starts with a complete label set — which is why
`enforcing` passes its preflight on the very first boot.

#### The denials this cost, and what closed them

Eleven, none of which an installed machine ever produces. Four are worth naming
here because of how they fail rather than how they are fixed:

* **`growpart` is behind a boolean.** refpolicy gates cloud-init's read of the
  block device behind `cloudinit_growpart`, which ships **off**. Enforcing with
  it off: `cloud-init status` still says `done`, only `--long` carries
  `('growpart', PermissionError(13, …))`, and the machine sits on the image's
  40 GiB inside whatever volume it was launched onto. `selinux-server.sh` now
  writes `booleans.local` with it on, the same way it writes `seusers.local` and
  `file_contexts.local`, and the acceptance asserts it.
* **mkinitcpio inside a service.** `depmod` cannot reach the build root when
  mkinitcpio runs from a unit (`initrc_tmp_t`), so `firstboot`'s `limine-update`
  reported "errors were encountered during the build" and wrote no UKI. That is
  the §11.5 failure of the mandatory-access-control report on its other path —
  and the same path a **daily update timer** takes to install a kernel.
* **Queries that answer less instead of failing.** `systemctl --failed` printed
  an empty table, `sudo btrfs subvolume list /` over a non-interactive ssh
  printed nothing and exited 0, `ss -ltnup` listed no sockets, and
  `cloud-init status` reported `error` on a perfectly provisioned machine. Each
  reads as good news.
* **cloud-init's locale module is off.** `cc_locale` regenerates a locale this
  install already set, and letting it would have cost cloud-init a general read
  of `/usr`, write access to `/usr/lib/locale` and `systemd-localed` the right to
  execute from `/usr/bin`. `locale: false` in the profile's `cloud.cfg` is the
  cheaper answer, and the trade is the same one the network block makes.

`qemu-guest-agent` has no domain of its own in refpolicy and runs as `initrc_t`.
It works — ping, `guest-get-osinfo` and a freeze/thaw driven from the host all
answer with zero denials under enforcing, which is the path a hypervisor's
volume backup takes — but it is not confined, and writing it a domain is
unfinished work.

#### Running the suite

```bash
serverlab image test <name> --image <qcow2> --disk-gb 40            # as shipped: permissive
serverlab image test <name> --image <qcow2> --disk-gb 40 --enforce  # and taken to enforcing
```

`--mac` is read off the image's file name, so a SELinux image is never tested as
though it had no MAC. The list is `pocs/server-install/acceptance-cloud-selinux.sh`;
it needs no lab password, because the image ships no account with one.

---

## 7. OCI

Four files in `pocs/image/oci/`, and both scripts refuse to run without
`--yes`, printing the plan instead.

| File | What |
|---|---|
| `make-demo-key.sh` | generates `out/demo-guest_ed25519{,.pub}` (gitignored) and prints the 1Password block |
| `import.sh` | upload → `image import from-object` → wait AVAILABLE → capability schema |
| `launch-demo.sh` | NSG (22/tcp only) + instance with cloud-init user-data |
| `dns.md`, `reset.md` | the A record, and the three ways to reset the demo |

### The flags, and why each one

**`--source-image-type QCOW2`.** OCI's custom-image import accepts QCOW2 and
VMDK. QCOW2 is what `qemu-img` already produced, it compresses, and it is what
every other target in this document consumes. A VMDK export would be the same
bytes without the compression.

**`--launch-mode PARAVIRTUALIZED`.** The launch mode decides which virtual
hardware the instance is given. `EMULATED` presents an IDE disk and an E1000 NIC
to an image whose drivers are unknown; `PARAVIRTUALIZED` presents virtio-blk and
virtio-net, which is exactly what this image was built and tested on
(`pocs/lab/vm.sh` boots it with `virtio-blk-pci` and `virtio-net-pci`) and what
its initramfs carries. `NATIVE` is for images built with the OCI paravirtualized
drivers and their metadata, which are not shipped here.

**An image capability schema declaring `Compute.Firmware = UEFI_64`.** This is
the step an import that "worked" will have skipped, and the resulting image
imports cleanly and never boots. OCI decides an instance's firmware from the
**image's** capability schema; an imported image has none until one is created
for it, and the default is BIOS. This image boots a UKI through Limine on an
ESP — there is no MBR and no BIOS boot path at all — so BIOS firmware finds
nothing bootable and the console shows a boot loop with no output.

The schema also pins `Compute.LaunchMode`, `Storage.BootVolumeType` and
`Network.AttachmentType` to `PARAVIRTUALIZED`, so a later launch cannot quietly
select emulated hardware.

The global schema **version name** is discovered at runtime
(`oci compute global-image-capability-schema-version list`) rather than
hard-coded: it is a `OCI_x.y.z` string in some tenancies and a UUID in others.

**No `Compute.SecureBootSupported`.** See §6. If a future image is ever built
against a shim carrying a certificate Oracle's firmware trusts, this is the
capability to add, together with `Compute.MeasuredBootSupported` and
`Compute.TrustedPlatformModuleSupported`, and only then does
`--is-secure-boot-enabled` on the launch become anything but a brick.

### The shape

x86_64, non-negotiable: this is an x86_64 Arch install with an x86_64 UKI, so
the Ampere A1 shapes are not an option however cheap they are.
`VM.Standard.E5.Flex` at 2 OCPU / 8 GB is the default and `VM.Standard.E4.Flex`
the fallback in regions without E5. Both were confirmed present in the target
region.

### What the scripts refuse to create

No VCN, no subnet, no internet gateway, no route table, no DNS record. Those
are the tenancy's shape, they outlive the demo, and a script in a lab
repository that can write into them is a script that can take something else
down. `launch-demo.sh` requires an existing **public** subnet OCID.

---

## 8. What this does not cover

* **Static addressing from metadata.** cloud-init's network rendering is off
  (§2), so a platform that hands out a static address, a secondary VNIC or an
  IPv6 prefix through its metadata is not honoured. Every cloud this image
  targets uses DHCP for the primary VNIC. Turning the renderer back on means
  removing the profile's own `20-wired.network` in the same change.
* **Secure Boot on a cloud.** §6. `--secboot` images are for firmware whose
  variable store you control.
* **Anything outside `@`.** `@factory` resets the root subvolume. `/home`
  (`@home`) and `/var/log` (`@log`) are separate subvolumes and survive it;
  `reset.md` says what to do about that.
* **A signed image.** The release asset carries a `.sha256` and nothing else.
  A detached signature by the same key that signs `[omarchy-server]` is the
  obvious next step and is not done.
* **Multi-architecture.** x86_64 only.
* **No cloud has been touched.** Everything measured is QEMU/KVM with OVMF and a
  NoCloud seed. `pocs/image/oci/` is written and reviewed and has never been run:
  no object uploaded, no image imported, no capability schema created, no
  instance launched. The UEFI_64 claim in §7 is reasoning from OCI's documented
  behaviour and from this image having no BIOS boot path, not an observation.
* **`--secboot` has not been built as an image.** The first-boot path is written
  and its skip-when-absent behaviour is measured; the image itself is the next
  run. `--mac selinux` no longer belongs in this list — see §6 and
  `reports/2026-08-29-cloud-image-selinux.md`.
* **Secure Boot and SELinux together.** Still no machine has had both, image or
  install.

`reports/2026-08-29-cloud-image.md` is the measured record of the base image: 65
passed, 1 failed (the failure is a base-list check about the installer's default
hostname, which an image is *supposed* to override), plus the four defects the
run found. `reports/2026-08-29-cloud-image-selinux.md` is the SELinux one: 68
passed, 0 failed, zero denials on either boot, and eleven policy gaps closed
before it got there.
