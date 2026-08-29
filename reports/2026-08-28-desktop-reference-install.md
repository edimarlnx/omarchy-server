# Desktop reference install

**Date:** 2026-08-28
**Subject:** stock Omarchy 4.0.1 desktop, installed unattended from a `cidata` drive
**Result:** baseline established — 942 packages, 8.08 GiB installed, 12.2 s boot

## Scope

Before anything could be called "the server profile", there had to be a number
to compare against. This run installs the **official, unmodified** Omarchy
4.0.1 ISO into a VM with no keyboard, and measures everything the server
profile would later claim to reduce: package count, installed size, boot time,
enabled units, disk layout.

Nothing in this repository is exercised here except the lab scripts. The ISO is
the published one, the installer is upstream's, the only local input is the
autoinstall drive.

## Environment

| | |
|---|---|
| ISO | `omarchy-4.0.1.iso`, downloaded from upstream, `sha256` verified against the published file |
| VM | QEMU/KVM `q35`, 4 vCPU, 8 GiB RAM, 40 GiB virtio disk |
| Firmware | OVMF 4M, **without** Secure Boot |
| Network | user-mode, ssh forwarded to localhost |
| Autoinstall | `cidata` drive from `mkcidata.sh --profile desktop` — no interactive configurator was reached at any point |
| VM name | `ref`; a qcow2 snapshot named `reference` was taken after collection, so the disk can be reused without reinstalling |

## Method

```bash
pocs/lab/mkcidata.sh --profile desktop
pocs/lab/vm.sh ref create --disk-gb 40
pocs/lab/vm.sh ref start --iso pocs/lab/out/omarchy-4.0.1.iso \
                         --cidata pocs/lab/out/cidata.iso
pocs/lab/vm.sh ref wait-ssh
```

Collection ran over ssh with the key the `cidata` drive installed, and wrote
`pocs/lab/reference/`. Install timings come from the installer's own
`/run/omarchy-install/state.json`, copied out as `install-timing.json`.

## Results

| Metric | Value |
|---|---|
| Orchestrator, 14 phases | **97.5 s** total; `Installing Arch + Omarchy` alone **87.2 s**, from the ISO's offline mirror |
| Packages (`pacman -Qq`) | **942** — 159 explicit, 783 dependencies (the installer expected 943) |
| Installed size | **8079.57 MiB** (8.08 GiB) |
| Used on `/` | **14 GiB** (`df`), which includes the install package cache in `@pkg` |
| Boot | **12.150 s** = firmware 0.574 + **loader 6.376** + kernel 0.976 + userspace 4.221 |
| Kernel | `7.1.9-arch1-2` |
| Default target | `graphical.target` (sddm) |
| `os-release` | `NAME="Omarchy"`, `PRETTY_NAME="Omarchy"`, `ID=omarchy` |
| `omarchy-version` | `4.0.1-1` |

**Storage layout.** 2 GiB vfat ESP on `/boot`; btrfs with `compress=zstd:3` and
subvolumes `@`, `@home`, `@log`, `@pkg`, `swap`, `.snapshots`, `@factory`, plus
`var/lib/machines` and `var/lib/portables`. Snapper config `root`,
`NUMBER_LIMIT=5`, `TIMELINE_CREATE=no`. 7.7 GiB zram.

**Enabled units.** `NetworkManager` + `NetworkManager-dispatcher`,
`systemd-resolved`, `systemd-timesyncd`, `sshd`, `ufw`, `docker.socket`,
`systemd-oomd`, `limine-snapper-sync`, `linux-modules-cleanup`,
`snapper-cleanup.timer`, and the desktop set: **`sddm`, `cups` (+`cups-browsed`,
`cups.path`, `cups.socket`), `avahi-daemon`, `bluetooth`,
`power-profiles-daemon`**.

**Biggest packages.** libreoffice 421 MiB, chromium 416, electron43 333,
noto-fonts-cjk 299, qt6-webengine 282, clang 254, gcc 221, llvm 131+164,
linux 148, qemu-user-static 135, webkit2gtk 134, omarchy 121.

## Evidence

- [`../pocs/lab/reference/README.md`](../pocs/lab/reference/README.md) — the collected summary
- [`../pocs/lab/reference/install-timing.json`](../pocs/lab/reference/install-timing.json) — 14 phases with elapsed times
- [`../pocs/lab/reference/packages-all.txt`](../pocs/lab/reference/packages-all.txt), [`packages-explicit.txt`](../pocs/lab/reference/packages-explicit.txt), [`packages-deps.txt`](../pocs/lab/reference/packages-deps.txt), [`packages-biggest.txt`](../pocs/lab/reference/packages-biggest.txt), [`size.txt`](../pocs/lab/reference/size.txt)
- [`../pocs/lab/reference/services-enabled.txt`](../pocs/lab/reference/services-enabled.txt), [`user-services-enabled.txt`](../pocs/lab/reference/user-services-enabled.txt)
- [`../pocs/lab/reference/boot-time.txt`](../pocs/lab/reference/boot-time.txt), [`boot.txt`](../pocs/lab/reference/boot.txt), [`storage.txt`](../pocs/lab/reference/storage.txt), [`system.txt`](../pocs/lab/reference/system.txt), [`logs.txt`](../pocs/lab/reference/logs.txt)

## Findings

1. **The loader is half the boot.** 6.376 s of 12.150 s is limine sitting at its
   menu timeout. Nothing in the package set can improve that, and nothing in the
   package set is to blame for it either — a fact that mattered later, when the
   server profile's boot time was compared against this one.
2. **`sshd` is already enabled by upstream** when the `cidata` drive carries an
   `authorized_keys` file: the installer's "Configuring SSH access" phase does
   it. A headless install over `cidata` is therefore the natural upstream path,
   not a deviation from it.
3. **14 GiB used against 8.08 GiB installed.** The difference is the install
   package cache under `@pkg`, which upstream leaves in place.
4. **`@factory` plus `limine-snapper-sync` are already the rollback baseline**,
   and they are profile-independent.

## Limitations

- One VM, one run. Boot times on this host carry noise of roughly a second
  between consecutive boots, which is worth remembering before reading small
  boot-time differences as regressions.
- `size.txt` reports two different things on two lines: `8079.57 MiB total
  installed` is the sum over `pacman -Qi`, and `17G /` is a `du` of the
  filesystem including snapshot and cache overhead. The `df` figure, 14 GiB, is
  the one quoted above and the one comparable to later runs.
- The collector used for this directory is **not** the same script as
  `pocs/server-install/collect.sh`, so file layouts differ between the two
  reference directories. Comparisons across them are field by field.

## Next steps

- Reuse the `reference` qcow2 snapshot rather than reinstalling, so the baseline
  cannot drift with the upstream mirror.
- Take the same measurements from a server install and compare package count,
  size, listeners and root services.
