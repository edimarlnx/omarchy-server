# omarchy-server

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
pocs/            lab scripts and measured results (QEMU/OVMF, cidata autoinstall)
docs/            technical docs: packaging.md, iso-server.md, secure-boot.md, screenshots/
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
./pkgs/build.sh        # build the packages into a local signed repo
./pkgs/test.sh         # install them in a clean archlinux container
./iso/build.sh         # build the ISO with the server profile
pocs/lab/mkcidata.sh --profile server
pocs/lab/vm.sh srv create && pocs/lab/vm.sh srv start --iso <iso> --cidata <cidata.iso>
```

The base is deliberately small: enough to boot, update, snapshot, be reached by
ssh and be firewalled, and nothing else. What a machine needs on top comes from
an addon, bundled in the ISO's offline mirror but not installed:

```bash
omarchy-server-addon --list          # cli-tools dev docker editor fwall net-tools secureboot tailscale vm
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

## Measurements

Measurements (package count, size, enabled units, listening sockets, setuid
binaries, root services) are in `pocs/server-install/README.md`, produced by
`pocs/server-install/surface.sh`.

**Reports** — `reports/` is the validation record while the profile is in its
testing phase: one report per run, with environment, method, results and the
raw evidence behind them.

Large artifacts (ISOs, VM disks, keys, build output) never enter the repo.
