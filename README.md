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
pkgs/            PKGBUILDs (omarchy-server, omarchy-server-settings,
                 omarchy-server-keyring, fwall), build.sh (Docker), test.sh
profile/server/  package list, addons, services, overlay (install/server/*,
                 settings) and patches applied on top of the upstream tree
iso/             build.sh + overlay/patches for the ISO --profile server
pocs/            lab scripts and measured results (QEMU/OVMF, cidata autoinstall)
docs/            technical docs: packaging.md, iso-server.md, screenshots/
```

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
omarchy-server-addon --list          # cli-tools dev docker editor fwall net-tools tailscale vm
omarchy-server-addon docker
pocs/lab/mkcidata.sh --profile server --addons docker    # or at install time
```

Measurements (package count, size, enabled units, listening sockets, setuid
binaries, root services) are in `pocs/server-install/README.md`, produced by
`pocs/server-install/surface.sh`.

Large artifacts (ISOs, VM disks, keys, build output) never enter the repo.
