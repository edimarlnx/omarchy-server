# Server packages: reverse-engineered layout, build and container test

**Date:** 2026-08-28 (first build and test), assertion suite grown through 2026-08-29
**Subject:** `omarchy-server-keyring`, `omarchy-server-settings`, `omarchy-server`, and later the `fwall` addon package
**Result:** all four build reproducibly and install in a clean Arch container — **66 assertions, 0 failures** in the final run

## Scope

The upstream PKGBUILD repository is private. To ship a server edition at all,
the published packages had to be taken apart and their layout reproduced: what
files go where, what the install scriptlets do, what the dependencies really
are. This report covers that reverse engineering, the resulting packages, and
the container test that proves they install and behave.

It does **not** cover the ISO or any VM install; those are separate.

## Environment

| | |
|---|---|
| Build | `archlinux:latest` container, work done as user `builder` |
| Sources | fork `github.com/edimarlnx/omarchy.git`, branch `server`, pinned at commit `468b511249b1a341311c46f5a7cf81aa5bc5af92`, plus `profile/server/overlay/` packed as a source tarball |
| Local checkout | bind-mounted read-only at `/src/omarchy`, reached through `OMARCHY_SRC` — no network, and never the ambient state of a working tree |
| `fwall` source | `github.com/edimarlnx/tui-tools.git` at a pinned commit, mounted at `/src/tui-tools`, reached through `FWALL_SRC` |
| Reference binaries | `omarchy-4.0.1-1`, `omarchy-settings-4.0.1-1`, `omarchy-keyring-20251027-1`, downloaded from `https://pkgs.omarchy.org/stable/x86_64/` |

## Method

```bash
./pkgs/build.sh                  # all packages, signed, into pkgs/out/ + pkgs/repo/
./pkgs/build.sh omarchy-server   # one
./pkgs/test.sh                   # clean container: install and verify
```

`build.sh` signs with the lab key and runs `repo-add --sign`. `test.sh` starts a
second clean container, adds `[omarchy]` (for `limine-mkinitcpio-hook`,
`limine-snapper-sync`, `ufw-docker`, `tzupdate`, `yay`) and `[omarchy-server]`
with `SigLevel = Required DatabaseOptional` over `file:///repo`, bootstraps the
trust anchor and runs `pacman -Sy omarchy-server`.

`makepkg --nodeps` is deliberate: the packages are `arch=any` with no compile
step and their `depends` include each other plus packages that only exist in
`[omarchy]`. Where a real `makedepends` exists — the Go toolchain `fwall`
needs — it is installed explicitly, and only for the runs that build `fwall`.

## What the published layout turned out to be

**`omarchy-keyring` (6.6 KB)** — three files under
`usr/share/pacman/keyrings/`: the exported public key, a `-trusted` file
carrying `<fingerprint>:4:`, and an empty `-revoked` that must exist anyway. Its
`.INSTALL` is the `archlinux-keyring` standard and uses relative paths, because
the scriptlet runs chrooted into the transaction's root — which is exactly how
it works inside an ISO install chroot.

**`omarchy-settings` (724 KB compressed, 1.3 MB installed, 419 files)** — three
blocks: `usr/share/omarchy/`, a straight copy of the repo's `etc/`, and
miscellaneous `usr/`. Two details are visible only in the binary:
`etc-overrides/` **does not exist in the public repo** — the PKGBUILD
synthesizes it, and `os-release` in it is generated from `pkgver`; and
`/etc/skel/.bashrc` is not a package file at all, the scriptlet writes it.

**`omarchy` (120 MB compressed, 126 MB installed)** — `themes/` is 120 of the
126 MB. `/usr/bin/omarchy-*` are **copies** of the files in
`usr/share/omarchy/bin`, not symlinks or hardlinks: 2.2 MB duplicated. The
`/etc/skel` migrations are empty stubs, one per migration, used as markers. The
`version` file inside the package says `4.0.0.alpha` while `pkgver` is `4.0.1`,
which breaks nothing because `omarchy-version` reads pacman rather than the file.

## Results

Measured in the container (final run, 2026-08-29):

| Package | Compressed | Installed | Upstream equivalent |
|---|---|---|---|
| `omarchy-server` | 448 KB | **1.21 MiB** | `omarchy`: 120 MB / 126 MB |
| `omarchy-server-settings` | 65 KB | **145 KiB** | `omarchy-settings`: 724 KB / 1.3 MB |
| `omarchy-server-keyring` | 3.7 KB | 295 B | `omarchy-keyring`: 6.6 KB |
| `fwall` (addon, not in the base) | 1.5 MB | **3.7 MiB** | — |

| Dependency closure | Value |
|---|---|
| Packages in the container after installing `omarchy-server` | **193** |
| Installed size | **739 MiB** |
| Graphical packages present | **none** (`hyprland sddm pipewire quickshell plymouth wireplumber uwsm gnome-keyring xdg-desktop-portal-hyprland`) |

The closure started at 203 packages / 849 MiB. A dependency audit against the
commands a server actually runs moved `git` and `jq` to `optdepends` and dropped
`perl` and `fakeroot` outright, taking ten packages and 110 MiB out of every
install that only wanted the runtime. `expac` was audited at the same time and
kept out; the lab scripts that used it now read sizes from `pacman -Qi`.

**Assertion count over time.** The suite started at **25** assertions covering
little more than "it installs and the files are there". It grew to **42** with
the lean-base checks (no compiler, no docker, no NetworkManager, the Docker
drop-ins under `/usr/share` rather than `/etc`, the sshd hardening and the
`ufw limit` rule present in the shipped scripts, every addon list packaged), to
**61** with the identity and `fwall` blocks, and to **66** with the
`[omarchy-server]` repository-wiring block. **The final figure is 66, all
passing.**

Those last blocks check, as bytes on disk: the `os-release` values; the branding
and `wallpaper` lines in `limine.conf`; `/etc/issue` (logo, `\S{VERSION_ID}`, a
literal ESC byte) against `/etc/issue.serial` (no logo) and the `serial-getty`
drop-in; the palette unit with the serial console explicitly untouched; the
shipped `/etc/pacman.d/omarchy-server.conf` and the `Include` in all three
channel templates; and, for `fwall`, the static binary, `--version`, the
ufw-pinned configuration and the licence.

## Evidence

- [`../docs/packaging.md`](../docs/packaging.md) — §1 the reverse-engineered layout, §2 the packages, §3 build and test with the full result table
- `pkgs/build.sh`, `pkgs/test.sh` — the two entry points
- The PKGBUILDs themselves live in the `omarchy-server-pkgs` repository (see the repository report), not here

## Findings and bugs

1. **The trust anchor cannot verify itself.** The keyring package is signed by
   the very key it delivers — the same chicken-and-egg as `archlinux-keyring`.
   `test.sh` breaks it by extracting the `.gpg` from inside the package,
   `pacman-key --add` + `--lsign-key`, and only then installing the package under
   full verification.
2. **`provides=omarchy` does not answer `pacman -Q omarchy`.** Without a runtime
   patch, `omarchy-version` exits 1 with no output on a server.
3. **`makepkg --nodeps` installs nothing at all**, including makedepends a
   package genuinely needs. Building `fwall` failed until each PKGBUILD's
   `makedepends` were read out of `makepkg --printsrcinfo` and installed.
4. **`zram-generator.conf` is shipped to `/usr/lib`, but the upstream `.PKGINFO`
   still lists `etc/systemd/zram-generator.conf` under `backup=`** — a dead
   entry in the upstream PKGBUILD, reproduced here only as a note.
5. **Every content change must bump `pkgrel`.** This was learned the hard way
   later, from the published repository, and is recorded in that report; it is
   repeated here because it is a packaging rule, not a hosting one.

## Limitations

- A container is not a machine. `systemctl enable/mask`, `ufw`,
  `ufw-docker install`, `mkinitcpio`/UKI generation, `snapper`, `paccache`
  against a real `@pkg`, the serial console and booting into
  `multi-user.target` cannot be tested here and are covered by the VM installs.
- During `pacman -Sy` in the container the limine hook complains
  `FAT32 boot partition not found`. Expected: there is no ESP.
- The 193 packages / 739 MiB figure is the `archlinux:latest` image plus the
  closure, **not** an installed machine. A real install measures 220 packages /
  1402 MiB.
- The key in the keyring package is a lab key. Swapping in a real one is
  documented but has not been done.

## Next steps

- Build an ISO that installs these packages, and measure a real machine.
- Publish the packages somewhere an installed machine can reach.
