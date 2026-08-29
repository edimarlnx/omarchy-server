# The cloud image, built and booted

**Date:** 2026-08-29
**Subject:** one qcow2 generalized from an ordinary install, launched onto a 40 GiB disk with a NoCloud seed and nothing else
**Result:** **65 passed, 1 failed** on VM `cloudtest`

## Scope

One machine of the `server` profile, **launched from the cloud image below** onto a
40 GiB disk it was not built on, told about itself by nothing but a NoCloud
seed, and then asked whether it had become a machine of its own: the metadata
applied, nothing of the build machine left, the root grown into the disk, and
still recognisably Omarchy Server afterwards.

## Environment

| | |
|---|---|
| VM | `cloudtest`, QEMU/KVM `q35`, 4 vCPU, 8 GiB RAM, 40 GiB virtio disk |
| Firmware | OVMF 4M without Secure Boot |
| Image | `omarchy-server-2026-08-29-x86_64.qcow2` |
| Image size | 1.1 GiB (1227358208 bytes) |
| Image sha256 | `a2748ecc069ee328f56c30a8b813913d259332a181fe7aa3a8138b1b1bffc186` |
| NoCloud seed | `mkseed.sh --hostname omarchy-cloud-test --user demo` |
| Run | `2026-08-29T17:32:19-03:00` |

## Method

```bash
serverlab image build --mac ''
serverlab image test cloudtest --image omarchy-server-2026-08-29-x86_64.qcow2 --disk-gb 40
serverlab report cloudtest

# what those run underneath:
#   pocs/lab/mkcidata.sh --profile server --user imgbuild --addons cloud
#   pocs/image/generalize.sh + pocs/image/convert.sh
#   pocs/image/mkseed.sh --hostname omarchy-cloud-test --user demo
#   pocs/lab/vm.sh cloudtest create --from-image <image> --disk-gb 40
#   pocs/server-install/acceptance-cloud.sh|surface.sh|reboot-check.sh cloudtest
```

`collect.sh` and `surface.sh` run **before** the acceptance lists: the
acceptance workload installs the `docker` addon and then runs an update, both
of which change the package set the measurements record. `reboot-check.sh`
runs last, because it takes the VM down.

## Results

### Acceptance — the base install

**43 passed, 1 failed.** Full evidence in [`acceptance.txt`](../pocs/server-install/reference/cloudtest/acceptance.txt).

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 1 | default target is multi-user.target | **PASS** | `multi-user.target` |
| 2 | no sddm/hyprland/pipewire/plymouth installed | **PASS** | `graphical=0` |
| 3 | docker is absent from the base | **PASS** | `extras=0` |
| 4 | ssh with the cidata key works | **PASS** | `logged in as demo@omarchy-cloud-test from 10.0.2.2 47264 10.0.2.15 22` |
| 5 | password authentication is refused | **PASS** | `demo@localhost: Permission denied (publickey).` |
| 6 | root cannot log in over ssh | **PASS** | `PermitEmptyPasswords no` |
| 7 | networkd brought the link up by DHCP | **PASS** | `enp0s3 10.0.2.15/24` |
| 8 | resolved answers through the stub resolver | **PASS** | `dns-ok` |
| 9 | sudo works with the lab password | **PASS** | `root` |
| 10 | ufw is active and rate-limits 22 | **PASS** | `22/tcp (v6)                LIMIT IN    Anywhere (v6)              # omarchy-sshd` |
| 11 | nothing listens except ssh | **PASS** | `[::]:22` |
| 12 | factory snapshot exists and snapper is configured | **PASS** | `root` |
| 13 | /boot/limine.conf lists snapshot entries once a snapshot exists | **PASS** | `cmdline: root=PARTUUID=eddadfc4-5246-459d-80d8-e71ca2f644ae zswap.enabled=0 rootflags=subvol=/@/.snapshots/1/…` |
| 14 | pacman -Qq \| wc -l in 150-260 | **PASS** | `in-range` |
| 15 | installed size and disk used < 3 GB | **PASS** | `under-3g` |
| 16 | boot to ssh under 20 s | **PASS** | `under-20s` |
| 17 | /proc/cmdline has console=ttyS0 and no quiet/splash/resume | **PASS** | `cmdline-ok` |
| 18 | zram active | **PASS** | `/dev/zram0 partition 3.9G   0B  100` |
| 19 | /etc/omarchy-profile is server | **PASS** | `server` |
| 20 | omarchy-version reports the profile release (4.0.1-N) | **PASS** | `4.0.1-10` |
| 21 | the hostname defaults to omarchy when cidata gives none | **FAIL** | `wrong-hostname` |
| 22 | os-release identifies the edition | **PASS** | `LOGO=omarchy` |
| 23 | /etc/issue carries the logo, the version and the machine fields | **PASS** | `issue-ok` |
| 24 | the serial console gets its own logo-free issue | **PASS** | `serial-issue-ok` |
| 25 | the VT palette unit ran and left the serial console alone | **PASS** | `palette-ok` |
| 26 | /boot/limine.conf is branded, waits 2 s and points at the wallpaper | **PASS** | `wallpaper_style: stretched` |
| 27 | the wallpaper is on the ESP | **PASS** | `/boot/limine-wallpaper.png: PNG image data, 1920 x 1080, 8-bit/color RGB, non-interlaced` |
| 28 | the login banner prints the machine identity | **PASS** | `ip        10.0.2.15/24` |
| 29 | the banner is wired into every login shell | **PASS** | `motd-wired` |
| 30 | fwall is not in the base | **PASS** | `fwall-absent` |
| 31 | omarchy-server-addon docker installs and runs a container | **PASS** | `To generate this message, Docker took the following steps:` |
| 32 | the docker addon opens only the container DNS stub | **PASS** | `2` |
| 33 | the update timer ships disabled and toggles | **PASS** | `shipped=disabled enabled=enabled disabled=disabled` |
| 34 | the free-space check uses the server threshold | **PASS** | `37G` |
| 35 | omarchy-server-update runs non-interactively to completion | **PASS** | `rc=0` |
| 36 | the unattended update pruned the cache and took a snapshot | **PASS** | `root,/,2,no,no,single,,2026-08-29 17:32:36,root,,number,4.0.1-10,` |
| 37 | no prompt was rendered during the unattended update | **PASS** | `no reboot was required` |
| 38 | the update reported restarts, deferrals and a reboot verdict | **PASS** | `3` |
| 39 | a userspace-only transaction restarts services and requires no reboot | **PASS** | `marker=absent` |
| 40 | sshd is restarted by openssh's own alpm hooks, before the classifier sees it | **PASS** | `verdict=restarted-by-the-package` |
| 41 | an ssh session survives the sshd restart it triggers | **PASS** | `same-shell=yes still-connected=yes` |
| 42 | a firmware upgrade sets the reboot-required marker | **PASS** | `marker=set` |
| 43 | a kernel transaction sets the reboot marker only when the kernel moved | **PASS** | `verdict=reinstall-no-reboot` |
| 44 | kexec is an addon, absent from the base | **PASS** | `apparmor cli-tools cloud dev docker editor fwall kexec net-tools secureboot selinux-tools selinux tailscale vm` |

### Acceptance — the cloud image, booted from a NoCloud seed

**22 passed, 0 failed.** Full evidence in [`acceptance-cloud.txt`](../pocs/server-install/reference/cloudtest/acceptance-cloud.txt).

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 1 | cloud-init finished its run | **PASS** | `exit=0` |
| 2 | the datasource is one of the five this image declares | **PASS** | `datasource_list: [ NoCloud, ConfigDrive, OpenStack, Oracle, Ec2, None ]` |
| 3 | hostname came from the metadata | **PASS** | `omarchy-cloud-test` |
| 4 | the user the seed named exists, with its key and passwordless sudo | **PASS** | `sudo-n-ok` |
| 5 | the build account is gone | **PASS** | `demo` |
| 6 | root carries no password | **PASS** | `root L 2026-08-29 -1 -1 -1 -1` |
| 7 | no build credentials anywhere on the image | **PASS** | `leftovers=0` |
| 8 | machine-id was generated on this machine | **PASS** | `5b08a83112af46099b9a3c188f9b2f36` |
| 9 | ssh host keys were regenerated at first boot | **PASS** | `count=3` |
| 10 | the first-boot unit ran and said what it did | **PASS** | `marker: 2026-08-29T17:31:50-03:00` |
| 11 | the image's journal mentions nothing of the build machine | **PASS** | `build_user_mentions=0` |
| 12 | growpart + btrfs resize filled the 40 GiB disk | **PASS** | `root_gib=38` |
| 13 | growpart and resizefs are in the cloud-init log, not assumed | **PASS** | `2026-08-29 20:31:48,189 - handlers.py[DEBUG]: finish: init-network/config-resizefs: SUCCESS: config-resizefs …` |
| 14 | os-release, issue and MOTD still say Omarchy | **PASS** | `[2mhost     [0m omarchy-cloud-test` |
| 15 | profile marker and version survived | **PASS** | `omarchy-server-settings 4.0.1-4` |
| 16 | the update entry point works on a machine nobody logs into | **PASS** | `Triggers: ● omarchy-server-update.service` |
| 17 | the firewall is up and rate-limits ssh | **PASS** | `22/tcp (v6)                LIMIT IN    Anywhere (v6)              # omarchy-sshd` |
| 18 | sshd still refuses passwords and root | **PASS** | `KbdInteractiveAuthentication no` |
| 19 | no failed units | **PASS** | `failed=0` |
| 20 | the boot is still a server's boot | **PASS** | `124ms ufw.service` |
| 21 | @factory is present beside @ | **PASS** | `factory=1` |
| 22 | the package cache shipped empty | **PASS** | `0	/var/cache/pacman/pkg` |

### Attack surface

| Metric | Value |
|---|---|
| Packages installed | **250** |
| Explicitly installed | **24** |
| Installed as a dependency | **226** |
| Installed size (MiB) | **1428** |
| `linux-firmware` (MiB) | **408** |
| Enabled unit files | **27** |
| Masked unit files | **13** |
| Listening sockets (`ss -ltnup`) | **6** |
| setuid/setgid binaries | **16** |
| Services running as root | **10** |

### Reboot survival

The machine came back over ssh after `systemctl reboot`.

| | |
|---|---|
| Verdict | rebooted: boot time moved from 2026-08-29 17:31:44 to 2026-08-29 17:32:05 |
| ssh | ssh answered 0s after the reboot request |
| Boot | Startup finished in 762ms (firmware) + 2.749s (loader) + 781ms (kernel) + 3.123s (userspace) = 7.416s |
| Failed units | 0 loaded units listed. |

## Evidence

- [`acceptance.txt`](../pocs/server-install/reference/cloudtest/acceptance.txt) — the acceptance run, raw
- [`acceptance-cloud.txt`](../pocs/server-install/reference/cloudtest/acceptance-cloud.txt) — the acceptance run, raw
- [`surface.txt`](../pocs/server-install/reference/cloudtest/surface.txt) — the attack-surface measurements, raw
- [`reboot-check.txt`](../pocs/server-install/reference/cloudtest/reboot-check.txt) — the reboot survival check

## The one failure, and why it is the right one

`the hostname defaults to omarchy when cidata gives none` is a check from the
**base** list, which was written for a machine installed from an autoinstall
drive: it asserts that an install given no hostname is called `omarchy`. This
machine is called `omarchy-cloud-test`, because the NoCloud seed said so and a
cloud image taking its name from its metadata is the entire point.

It is left failing rather than skipped. A base check that a cloud image cannot
satisfy is a fact about the difference between an install and an image, and
hiding it behind a suite-aware exception would make the base list quietly mean
two different things.

## What this run found

Four defects, all of them in code written for this pipeline, and all four found
by **inspecting the artifact** rather than by reading the script that produced
it. Each one shipped in an image that the build reported as successful.

### 1. `root` carried the autoinstall drive's password hash

`mkcidata.sh` sets `root_enc_password`, and generalization did not touch it. The
first image built by this pipeline contained a 106-character SHA-512 hash for
root — a credential shared by every machine that would ever boot it, which a
console login or a single-user boot would accept.

Fixed by replacing the field outright (`usermod -p '!'`) rather than by
`usermod -L`, which prefixes the existing hash with `!` and leaves the original
readable in `/etc/shadow` to anyone holding the image. Asserted by
`root carries no password`.

### 2. An account nobody asked for survived

The build was told `--user imgbuild` and generalization removed `imgbuild`. The
image shipped with a second account, `omarchy`, created by the installer as the
profile's owner account: locked, with no home directory and no keys, but an
account in a public artifact all the same — and with its sudoers drop-in
`/etc/sudoers.d/02_imgbuild` still in place for the account that *was* removed,
because the removal was guessing at the prefix the installer uses.

Fixed with `--remove-all-users`, which is the honest form of the intent (an
image ships *no* account) and which also catches whatever a future installer
creates that nobody predicted. The sudoers removal now matches `<user>` and
`[0-9][0-9]_<user>` exactly.

The first attempt at that fix used a glob, `/etc/sudoers.d/*<user>`, and on the
account the installer happens to call `omarchy` it deleted the profile's own
`omarchy-passwd-tries` and `omarchy-tzupdate` — a fix that silently removed two
pieces of the profile. That one was caught by the same inspection, one round
later.

### 3. `/var/lib/systemd/random-seed` came back after being deleted

`systemd-random-seed.service` writes the pool to that file when it is *stopped*,
which is part of every shutdown — including the shutdown that ends the image
build. A file deleted in the middle of generalization is a file that exists
again in the artifact, identical on every machine booted from it.

Fixed in two places: the detached phase stops the unit before deleting the file,
and `omarchy-server-firstboot` replaces it on the first boot regardless.

Worth keeping in proportion. systemd does not *credit* entropy from the seed
file unless `SYSTEMD_RANDOM_SEED_CREDIT` says so, so a shared seed was untidy
rather than dangerous. It is listed here because "untidy" is not a property an
image should have, and because the failure mode — a deletion that undoes itself
at shutdown — is one that would repeat for anything else saved on stop.

### 4. The boot entry kept the build machine's machine-id, and snapshots vanished

This is the one that was not cosmetic.

`limine.conf` tags every OS entry with the machine-id of the machine that wrote
it (`comment: machine-id=<id> order-priority=50`). An image carries the build
machine's tag, and it cannot be removed during generalization: it is the entry
the image boots from.

`limine-snapper-sync` writes its history under the **running** machine's id
(`/boot/<machine-id>/limine_history/`) and attaches snapshot entries to the OS
entry carrying that id. On a machine from the image there is no such entry, so
the sync ran, reported success, wrote its history, and produced no snapshot
entries at all — which means a machine booted from the image had **no rollback
from the boot menu**, silently, while `snapper list` showed the snapshots
present and correct.

The base list caught it (`/boot/limine.conf lists snapshot entries once a
snapshot exists`, which passes on every installed lab in
`pocs/server-install/reference/`). Running `limine-update` by hand on the
machine produced the entries immediately, which is what identified the cause.

Fixed by handing the old machine-id to the first boot: generalization writes
`/var/lib/omarchy/firstboot-limine`, and `omarchy-server-firstboot` runs
`limine-update` (regenerating the initramfs and the UKI, after the Secure Boot
keys exist so the new UKI is signed with them) and then removes the build
machine's entry by id. The journal of the run above shows both steps.

Generalization also now removes `/boot/<machine-id>/`, the build machine's boot
history — which on this build was empty, but on a golden machine generalized
after months of use is a directory of that machine's past kernel images.

## What this run does not prove

- **No cloud was touched.** Every measurement here is QEMU/KVM with OVMF and a
  NoCloud seed. The OCI path in `pocs/image/oci/` is written and reviewed but
  has never been executed: no object was uploaded, no image imported, no
  capability schema created, no instance launched. In particular the claim that
  an imported image without a `Compute.Firmware = UEFI_64` capability schema
  will not boot is reasoning from OCI's documented behaviour and from this
  image having no BIOS boot path at all, **not** an observation.
- **Secure Boot was not exercised.** This image was built without `--secboot`,
  so `omarchy-server-firstboot`'s key-generation and enrollment path did not
  run. What is measured is that the path is skipped cleanly when the marker is
  absent. The `--secboot` image, and whether a machine booted from it comes up
  enforcing against keys it made for itself, is the obvious next run.
- **SELinux was not exercised either.** `--mac selinux` images should come up
  enforcing after a first-boot relabel, and the relabel unit is the one already
  measured in `reports/2026-08-29-mandatory-access-control.md`. That it works
  from an image — where *every* home directory is created after the labelling,
  which is precisely the case that locked an operator out in that report — is
  asserted by design here and not by a run.
- **One growth case, not the interesting one.** The image is a 40 GiB layout
  grown onto a 40 GiB disk: `growpart` had a 2 GiB ESP and a backup GPT header
  to work around and the root came out at 38 GiB, which is the resize working.
  A 200 GiB boot volume, which is what OCI would actually hand it, was not
  tried.
- **The install is not the slow part any more.** `wait-ssh` returns about a
  minute after the VM starts, because the ISO installs from its own offline
  mirror over virtio on KVM. That is a property of this host and this ISO, not
  a claim about installs in general.
- **Boot time includes a first boot that does more.** The 7.4 s above is the
  *second* boot. The first boot of a machine from this image additionally
  generates four ssh host key pairs, reseeds, and rebuilds the initramfs and the
  UKI through `limine-update` — tens of seconds, once, before sshd starts.
- **The reboot check measured a reboot, not a re-provision.** cloud-init
  correctly did not redo its once-per-instance work, which is what the unchanged
  hostname and account after the reboot show. A machine cloned *from this
  machine* — a new instance-id — was not tried.
