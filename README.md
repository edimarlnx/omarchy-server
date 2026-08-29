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
                 omarchy-server-keyring), build.sh (Docker), test.sh
profile/server/  package list, addons, services, overlay (install/server/*,
                 settings) and patches applied on top of the upstream tree
iso/             build.sh + overlay/patches for the ISO --profile server
pocs/            lab scripts and measured results (QEMU/OVMF, cidata autoinstall)
docs/            technical docs: packaging.md, iso-server.md
```

## Upstream clones

Work clones live in `upstream/` (gitignored):

```bash
git clone https://github.com/basecamp/omarchy.git upstream/omarchy
git clone https://github.com/omacom-io/omarchy-iso.git upstream/omarchy-iso
```

Published Omarchy packages: `https://pkgs.omarchy.org/stable/x86_64/`
(`omarchy.db`). The upstream PKGBUILD repo is private, so the server packages
are rebuilt from the published package layout (see `docs/packaging.md`).

## Quick start

```bash
./pkgs/build.sh        # build the three packages into a local signed repo
./pkgs/test.sh         # install them in a clean archlinux container
./iso/build.sh         # build the ISO with the server profile
pocs/lab/mkcidata.sh --profile server --hostname omarchy-srv
pocs/lab/vm.sh srv create && pocs/lab/vm.sh srv start --iso <iso> --cidata <cidata.iso>
```

The base is deliberately small: enough to boot, update, snapshot, be reached by
ssh and be firewalled, and nothing else. What a machine needs on top comes from
an addon, bundled in the ISO's offline mirror but not installed:

```bash
omarchy-server-addon --list          # docker tailscale cli-tools dev editor net-tools vm
omarchy-server-addon docker
pocs/lab/mkcidata.sh --profile server --addons docker    # or at install time
```

Measurements (package count, size, enabled units, listening sockets, setuid
binaries, root services) are in `pocs/server-install/README.md`, produced by
`pocs/server-install/surface.sh`.

Large artifacts (ISOs, VM disks, keys, build output) never enter the repo.
