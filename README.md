# omarchy-server

> **Status: unofficial, under validation.** This is an independent experiment
> by a community member and is **not** an official Omarchy project, nor
> endorsed by its maintainers. Everything here is in a testing phase: package
> lists, patches, images and measurements can change or be dropped at any time.
> Do not use it on machines you care about. The upstream project lives at
> [omarchy.org](https://omarchy.org).

Lab for a headless **server profile** of [Omarchy](https://omarchy.org): the
same Arch base, package pipeline, Limine/UKI boot and btrfs+snapper layout as
the desktop edition, minus the desktop.

Everything here is derived from the public upstream repositories
(`basecamp/omarchy`, `omacom-io/omarchy-iso`) pinned at a known commit, plus
an overlay of server-specific files and small, reviewable patches. Nothing in
upstream is modified in place.

## Layout

```
pkgs/            build.sh (Docker) and test.sh for the packages; the signing key
profile/server/  package list, addons, services, overlay (install/server/*,
                 settings) and patches applied on top of the upstream tree
iso/             build.sh + overlay/patches for the ISO --profile server
pocs/            lab scripts and measured results (QEMU/OVMF, cidata autoinstall);
                 pocs/image/ builds and validates the cloud image, pocs/image/oci/
                 is the OCI import + demo-instance recipe
tools/serverlab/ the Go driver that runs all of the above in order (make serverlab)
docs/            technical docs: packaging.md, iso-server.md, secure-boot.md, mac.md,
                 transactional.md, cloud-image.md, serverlab.md, screenshots/
```

The **PKGBUILDs are not here**. They live in
[`omarchy-server-pkgs`](https://github.com/edimarlnx/omarchy-server-pkgs), the
public repository whose GitHub Actions workflow builds and signs the
`[omarchy-server]` pacman repository served from its `repo` release. Clone it
beside this one (`OMARCHY_PKGS_DIR` moves it):

```bash
git clone https://github.com/edimarlnx/omarchy-server-pkgs.git ../omarchy-server-pkgs
```

`pkgs/build.sh` and `iso/build.sh` read the PKGBUILDs from there and build them
against the **working tree** of `profile/server/`, which is what keeps editing
the overlay a fast loop. That repository carries its own vendored copy of
`profile/server/` (refreshed by its `scripts/sync-overlay.sh`) so CI needs
nothing from here.

## Upstream clones

Work clones live in `upstream/` (gitignored):

```bash
git clone https://github.com/basecamp/omarchy.git upstream/omarchy
git clone https://github.com/omacom-io/omarchy-iso.git upstream/omarchy-iso
```

The `fwall` addon package is built from the **tui-tools** checkout, expected
beside this repository (`../tui-tools`, or `TUI_TOOLS_DIR`):

```bash
git clone https://github.com/edimarlnx/tui-tools.git ../tui-tools
```

Published Omarchy packages: `https://pkgs.omarchy.org/stable/x86_64/`
(`omarchy.db`). The upstream PKGBUILD repo is private, so the server packages
are rebuilt from the published package layout (see `docs/packaging.md`).

## What it looks like

A headless install is recognisably Omarchy from the firmware handover to the
shell prompt, and none of it costs a package: the identity is configuration
files, one 30-line command and a 17 KB image.

**Bootloader** — Limine, branded, on the Tokyo Night palette, with a two second
menu so the machine can be caught on the way up.

![The Limine menu of an installed server](docs/screenshots/limine-menu.png)

**Console, before login** — `/etc/issue` with the Omarchy logo, the version,
the hostname, the tty and the machine's IPv4 address, drawn in the same palette
a oneshot unit applies to every VT.

![The login banner on tty1](docs/screenshots/console-issue.png)

**Console, after login** — the MOTD, rendered by fastfetch when the `cli-tools`
addon put it there and by the base itself when it did not.

![The message of the day after logging in](docs/screenshots/login-motd.png)

The serial console gets the same fields without the 81-column logo, which would
wrap on an 80-column line: `pocs/server-install/reference/serial-issue.txt`.

## Quick start

```bash
git clone https://github.com/edimarlnx/omarchy-server-pkgs.git ../omarchy-server-pkgs
make serverlab                          # bin/serverlab, the driver
./bin/serverlab doctor                  # what this host is still missing
./bin/serverlab all --profile server    # packages → ISO → install → acceptance → report
```

`serverlab` is a single static Go binary that owns no build logic: it runs the
same bash scripts, in the right order, with the right environment, and records
what happened. Each stage is also a command of its own, and each script is still
runnable by hand:

```bash
./bin/serverlab pkgs build && ./bin/serverlab pkgs test   # pkgs/build.sh, pkgs/test.sh
./bin/serverlab iso build                                 # iso/build.sh
./bin/serverlab lab up srv --profile server               # mkcidata + vm create/start/wait-ssh
./bin/serverlab lab test srv --suite base                 # collect + surface + acceptance + reboot
./bin/serverlab report srv                                # reports/YYYY-MM-DD-srv.md + the index row
```

`--dry-run` prints the plan without running anything. Each lab keeps its
settings, disk, ssh key and evidence in `pocs/lab/out-<name>/`, and every run
writes a log under `pocs/lab/runs/`. `docs/serverlab.md` is what it wraps, how
the report is generated from the evidence, and how a self-hosted runner calls
the same commands.

The base is deliberately small: enough to boot, update, snapshot, be reached by
ssh and be firewalled, and nothing else. What a machine needs on top comes from
an addon, bundled in the ISO's offline mirror but not installed:

```bash
omarchy-server-addon --list          # cli-tools dev docker editor fwall kexec net-tools secureboot tailscale vm
omarchy-server-addon docker
pocs/lab/mkcidata.sh --profile server --addons docker    # or at install time
```

An installed machine gets those from the signed `[omarchy-server]` repository,
which `omarchy-server-settings` enables by shipping
`/etc/pacman.d/omarchy-server.conf` and including it from every channel's
`pacman.conf`. `docs/packaging.md` §5 is how that works.

## Updating

`omarchy update` asks questions, and a headless machine has nobody to answer
them. `omarchy-server-update` is the entry point that does not: it runs the
whole update as root, where every `sudo` inside it is already authenticated,
with `OMARCHY_NONINTERACTIVE=1` so the steps that would prompt report and move
on instead.

```bash
sudo omarchy-server-update           # update now, nothing to answer
sudo omarchy-server-update enable    # daily timer, randomized, journal-only
sudo omarchy-server-update status
```

The timer ships **disabled**. It can also be turned on at install time by an
autoinstall drive carrying an `unattended-updates` file
(`mkcidata.sh --unattended-updates`). `journalctl -u omarchy-server-update` is
the record of a run. `docs/iso-server.md` §3.1 is what had to change and why.

### Restart what changed, reboot only when you must

An update that finishes leaves the machine running the code it just replaced.
Upstream asks "Linux kernel has been updated. Reboot?" and, with nobody to
answer, does nothing — right for a laptop that reboots at the next login, wrong
for a server nobody logs into for months. So the update does not end when
`omarchy-update` returns: `omarchy-server-update-restart` reads the pacman
transaction it just made and `/proc/<pid>/maps`, and splits the result three
ways.

```
restarted: sshd systemd-networkd systemd-resolved
deferred: dbus (the bus keeps its old process until a reboot)
reboot required: no
```

A service whose binary or libraries were unlinked from under it is restarted in
place. The bus, logind, the gettys and the update's own unit are on a deny-list
and reported instead. **Only** the running kernel no longer being an installed
kernel, or firmware, microcode, the initramfs, the bootloader or `glibc` moving,
sets the upstream `reboot-required` marker — and systemd is upgraded by
re-executing PID 1, not by rebooting. A kernel *reinstalled at the version the
machine is running* costs nothing, which is what makes an initramfs rebuild
under SELinux or a re-signed UKI a non-event.

When a reboot really is required, the `kexec` addon can take it without the
firmware:

```bash
sudo omarchy-server-addon kexec       # kexec-tools, one package
sudo omarchy-server-update --kexec    # or: omarchy-server-update kexec on
```

`omarchy-server-kexec` loads the **signed UKI** through `kexec_file_load(2)`,
which is the only route under this profile's `lockdown=integrity` and which
verifies the image's signature in the kernel. It is also where the keyring that
defeats module signing does not apply: kexec's verification accepts `.platform`,
where a firmware-`db` certificate lands. Measured against the firmware path in
`reports/2026-08-29-update-without-reboot.md`.

### Or update without touching the running system at all

An update that finishes is one thing; an update that *breaks* is another, and on
a headless machine the recovery is a snapper snapshot, a reboot and a manual
rollback. The transactional mode removes that case: the update runs inside a
writable btrfs snapshot of `/`, with the ESP, the package cache and `/var/log`
bound in, and the live root is never opened for writing. A failure costs a
`btrfs subvolume delete`. A success becomes the root at the next reboot.

```bash
sudo omarchy-server-update --transactional     # this run only
sudo omarchy-server-update transactional on    # and every run after it, timer included
sudo omarchy-server-update rollback            # boot the previous root again
```

The new root is selected by **renaming subvolumes** (`@`→`@prev-<ts>`,
`@tx-<ts>`→`@`), so the kernel command line, the UKI, `/etc/fstab` and every
pacman hook stay byte for byte what they were — which is what makes it safe
under Secure Boot and what makes rollback the same two renames backwards. The
mode ships off: a transaction is always a reboot.

`docs/transactional.md` is the design, the operator's guide, the rollback
procedure and the limitations, including why a fully immutable root is *not*
the next step. Measured in `reports/2026-08-29-transactional-updates.md`.

## Secure Boot

Optional, and off unless asked for. A machine can boot with Secure Boot
enforcing against keys **it generated for itself**: the Limine binary, its
removable fallback and the UKI are all signed by a `db` key that never existed
anywhere else, unsigned kernels and out-of-tree modules are refused
(`lockdown=integrity module.sig_enforce=1`, inside the signed UKI), and a
kernel upgrade re-signs the chain without anyone asking it to.

```bash
sudo omarchy-server-addon secureboot     # sbctl, keys, cmdline, signatures
sudo omarchy-server-secureboot enroll    # hand the keys to the firmware
sudo omarchy-server-secureboot status
```

At install time an autoinstall drive carrying a `secureboot` marker
(`mkcidata.sh --secureboot`) does all of it, enrollment included, when the
firmware is in Setup Mode. It costs exactly one package, and only on the
machines that asked: `sbctl`, which is what limine-entry-tool and mkinitcpio
already look for when they decide whether to sign what they just wrote.

**Known limitation, measured:** with `module.sig_enforce=1` the kernel only
trusts modules signed by its own build key or by a certificate in the `.machine`
keyring, which is fed by shim's MokList. A certificate enrolled in the firmware
`db` (what this profile does) lands in `.platform` and is *not* consulted for
modules, so out-of-tree modules (ZFS, DKMS drivers) do not load under this
setup. The options are a shim carrying the certificate, a kernel built with it,
or relaxing `module.sig_enforce` on those machines; none is implemented. See
`docs/secure-boot.md` §8 and `reports/2026-08-29-zfs-signed-module.md`.

`docs/secure-boot.md` is the design — own keys rather than upstream's
shim + MOK, where the keys live, which existing hook signs which binary, the
lab flow with an OVMF firmware in Setup Mode, and what the boundary does and
does not cover.

## Mandatory access control

Also optional, also off unless asked for, and delivered twice so the choice of
a default is not made here. Arch's stock kernel builds **both** SELinux and
AppArmor in and activates neither, because `CONFIG_LSM` is
`landlock,lockdown,yama,integrity,bpf`; naming one of them in `lsm=` on the
kernel command line is the whole kernel-side switch. No kernel is rebuilt.

```bash
sudo omarchy-server-addon apparmor      # one package from Arch, profiles in complain
sudo omarchy-server-addon selinux       # the reference policy, permissive
```

Both start in their logging mode — permissive / complain — so the machine is
measured before it starts refusing anything. `omarchy-server-selinux avc` and
`omarchy-server-apparmor denials` summarise what would have been refused;
`enforcing` / `enforce` is the second step. The two are mutually exclusive: the
kernel runs one major LSM, and each addon refuses to install over the other.

At install time an autoinstall drive carrying a `selinux` or `apparmor` marker
(`mkcidata.sh --mac selinux`) does it during the install, where the SELinux
filesystem relabel is cheap.

The cost is not symmetric, and that is the interesting part. AppArmor is one
package. SELinux is nineteen, eight of which **replace** core packages
(systemd, coreutils, util-linux, shadow, sudo, openssh, pam, pambase) because
Arch builds none of them against `libselinux` — and a policy with no userland
to set contexts is a policy that reports everything as allowed.

Measured on two VMs installed from the same ISO
(`reports/2026-08-29-mandatory-access-control.md`): AppArmor costs **2 packages
and 6 MiB**, reached enforce with **zero denials** under the whole workload and
came back from a reboot still confined — and covers **2 of the 146** profiles
Arch ships, which in practice means sshd and nothing else. SELinux costs **54
packages and 552 MiB**, puts init, sshd and the login session in three
different domains, and locked the operator out the first time it was set to
enforcing. That was root-caused to home directories created after the
install-time relabel; the fix is written and not yet re-run.

`docs/mac.md` is the design: the kernel facts, both package sets with the
reason for every inclusion and every omission, the `--ask=4` package-replacement
problem, the lockstep obligation the rebuild set creates, and what each route
actually confines on a headless machine.

## Cloud image

The ISO installs one machine. The other shape of the same profile is an
**image**: one qcow2, copied onto many machines, where nothing that makes a
machine itself may be baked in.

```bash
./bin/serverlab image build            # install a throwaway machine, strip it, convert it
./bin/serverlab image test             # boot it with a NoCloud seed and assert
./bin/serverlab image publish --yes    # upload it to a GitHub release
```

`image build` is deliberately not a separate build path: it is an ordinary
unattended install of this profile with the `cloud` addon and a throwaway
account, followed by `omarchy-server-generalize`. That command lives in the
profile rather than in the pipeline, because the machine is what knows where
its snapper store, its ESP and its btrfs top level are — and an operator who
built a golden machine by hand is entitled to the same one-liner:

```bash
sudo omarchy-server-generalize --yes --remove-user builder --poweroff
```

It removes the six things that become a shared secret the moment a disk is
copied — ssh host keys, the machine-id, the Secure Boot keys, the entropy seed
and sealed-credential secret, the build account, and the machine's logs,
snapshots and package cache — then takes `@factory`, a read-only btrfs snapshot
of the finished root beside `@`, and trims the filesystem so the conversion
produces a small image rather than a large one full of deleted files.

What replaces all of it is decided on the machine that boots the image, by two
agents with a clean split. **cloud-init** owns what the platform knows:
hostname, users, ssh keys, and growing the root into whatever boot volume it
was launched onto. **`omarchy-server-firstboot`** owns what no metadata service
can supply: the ssh host identity, and — on an image built `--secboot` — a
Secure Boot key set this machine generates and enrolls for itself, because an
image that shipped one would hand every machine that boots it the key that
signs the others' kernels.

The image carries **no account with a password and no default user with keys**.
`omarchy` exists as a name for a platform's metadata keys to land on; with no
keys in the metadata it is an account nobody can log into.

`docs/cloud-image.md` is the design, the full generalization list, how to boot
it on libvirt, Proxmox and OCI, what the OCI import flags are and why
(`--source-image-type QCOW2`, `--launch-mode PARAVIRTUALIZED`, and the image
capability schema declaring `Compute.Firmware = UEFI_64` without which the
image imports cleanly and never boots), and what the image does **not** cover.
`pocs/image/oci/` is the recipe for the demo box; both of its scripts refuse to
run without `--yes` and print the plan instead.

## Measurements

Measurements (package count, size, enabled units, listening sockets, setuid
binaries, root services) are in `pocs/server-install/README.md`, produced by
`pocs/server-install/surface.sh`.

**Reports** — `reports/` is the validation record while the profile is in its
testing phase: one report per run, with environment, method, results and the
raw evidence behind them.

Large artifacts (ISOs, VM disks, keys, build output) never enter the repo.
