# Packaging the server profile

The three profile packages (`omarchy-server-keyring`, `omarchy-server-settings`,
`omarchy-server`) are built, signed and tested in a clean Arch container. The
`tui-tools` terminal UIs used to be built here too; they now come from the
signed repository the tools publish themselves (§2.4).

---

## 1. Layout of the published packages (reverse engineered)

The upstream PKGBUILD repository is private, so the layout was read from the
binaries published at `https://pkgs.omarchy.org/stable/x86_64/` (downloaded
into `pkgs/scratch/`, gitignored): `omarchy-4.0.1-1`,
`omarchy-settings-4.0.1-1`, `omarchy-keyring-20251027-1`.

### 1.1 `omarchy-keyring` (6.6 KB)

```
usr/share/pacman/keyrings/omarchy.gpg       exported public key (ed25519)
usr/share/pacman/keyrings/omarchy-trusted   "<fingerprint>:4:"
usr/share/pacman/keyrings/omarchy-revoked   empty
```

The `.INSTALL` is the `archlinux-keyring` standard: `post_install` calls
`post_upgrade`, which runs `pacman-key --populate omarchy` **if** the keyring
is already initialized, and prints instructions otherwise. Paths are relative
(`usr/bin/pacman-key`) because the scriptlet runs chrooted into the
transaction's `$root`, which is how it works inside the ISO install chroot.

The published key is `Omarchy <pkgs@omarchy.org>`, ed25519, ownertrust `4`
(full). The `-trusted` file is what grants the trust level without an
interactive prompt; `-revoked` must exist even when empty.

### 1.2 `omarchy-settings` (724 KB compressed, 1.3 MB installed, 419 files)

Three blocks:

| Block | Content |
|---|---|
| `usr/share/omarchy/` | `default/` (the repo's `default/` tree), `config/`, `applications/`, `etc-overrides/`, `icon.png`, `icon.txt`, `logo.svg`, `logo.txt` |
| `etc/` | system configuration (straight copy of the repo's `etc/`) + `etc/skel/.config/*` seeded from `config/` + `etc/skel/.local/...` |
| misc `usr/` | `usr/lib/systemd/user/*.service` (11 session units), `usr/lib/systemd/zram-generator.conf.d/90-omarchy.conf`, `usr/lib/environment.d/`, `hicolor` icons, fonts, plymouth and sddm themes, `usr/share/uwsm/env.d/10-omarchy`, and **three binaries** (`omarchy-debug`, `omarchy-debug-idle`, `omarchy-upload-log`) |

Details only visible in the binary:

- **`etc-overrides/` is synthesized by the PKGBUILD**; it does not exist in the
  public repo. `security-faillock.conf` ← `etc/security/faillock.conf`,
  `nsswitch.conf` ← `etc/nsswitch.conf`, `plymouth-plymouthd.conf` ←
  `etc/plymouth/plymouthd.conf`, `cups-cups-browsed.conf` ←
  `etc/cups/cups-browsed.conf`, `dot.bashrc` ← `default/bashrc` (byte
  identical), `os-release` is **generated** (`BUILD_ID`/`VERSION_ID` = pkgver).
- The `.INSTALL` copies those overrides to `/etc/...` on every install/upgrade,
  destructively and on purpose (the upstream comment assumes it).
  `/etc/skel/.bashrc` is **not** a package file: the scriptlet writes it.
- `etc/snapper/config-templates/omarchy` ← `default/snapper/root`, identical.
- `zram-generator.conf` goes to `usr/lib/systemd/zram-generator.conf.d/`, not
  `/etc`, although the `.PKGINFO` `backup=` still lists
  `etc/systemd/zram-generator.conf` (dead entry in the upstream PKGBUILD).
- `depends`: `bash curl gum hicolor-icon-theme plymouth`.
  `conflicts=(omarchy-settings-dev)`.
- 27 `backup=` entries, all under `/etc`.

### 1.3 `omarchy` (120 MB compressed, 126 MB installed)

```
usr/share/omarchy/bin        427 commands
usr/share/omarchy/install    setup scripts
usr/share/omarchy/migrations 86 migrations
usr/share/omarchy/shell      2.1 MB (Quickshell)
usr/share/omarchy/themes     120 MB  ← 95% of the package
usr/share/omarchy/version    the repo's `version` file
usr/bin/omarchy-*            427 files
usr/share/libalpm/hooks/     3 hooks
etc/skel/.local/state/omarchy/migrations/*.sh   86 EMPTY files
```

Findings that shape our package:

1. **`/usr/bin/omarchy-*` are copies, not symlinks.** `tar -tvf` shows regular
   files with the same size as those in `usr/share/omarchy/bin`, with distinct
   inodes after extraction (not hardlinks). 2.2 MB duplicated. We use
   **symlinks** to `/usr/share/omarchy/bin/<cmd>`.
2. **`themes/` is the package.** 120 of 126 MB. Without it the runtime fits in
   under 500 KB.
3. **The migrations in `/etc/skel` are empty stubs**, one per migration, so a
   new user does not re-run history. `omarchy-provision-user` uses the file's
   presence as the marker.
4. **The pacman hooks come from `default/libalpm/hooks/`** but are installed
   into `/usr/share/libalpm/hooks/` by the **runtime** package, not the
   settings (although settings also ships the copy under
   `/usr/share/omarchy/default/libalpm/`). Three hooks:
   `00-omarchy-update-guard.hook` (useful on a server) and two Hyprland reloads.
5. **`version` inside the package says `4.0.0.alpha`** while `pkgver` is
   `4.0.1`: the PKGBUILD copies the checkout's file without rewriting it. It
   breaks nothing because `omarchy-version` reads **pacman**, not the file.
6. No `.INSTALL`.
7. 13 commands of the `dev` checkout (468b511) are not in 4.0.1: 3 belong to
   settings (`omarchy-debug`, `omarchy-debug-idle`, `omarchy-upload-log`) and
   10 are newer than the release.

### 1.4 How `pacman-key --populate` consumes the keyring

`pacman-key --populate <name>` looks for
`/usr/share/pacman/keyrings/<name>.gpg`, imports everything, applies the
ownertrusts from `<name>-trusted` (`fingerprint:level:`, one per line) and
revokes what is listed in `<name>-revoked`. All three files must exist.

---

## 2. The packages

The PKGBUILDs are **not in this repository**. They live in
[`omarchy-server-pkgs`](https://github.com/edimarlnx/omarchy-server-pkgs) under
`pkgbuilds/<pkg>/`, cloned beside this checkout (`OMARCHY_PKGS_DIR` moves it),
because the same files are what GitHub Actions builds the published
`[omarchy-server]` repository from, and a PKGBUILD kept in two places is a
PKGBUILD that disagrees with itself. `pkgs/build.sh` and `iso/build.sh` read
them from there. See §5.

All three build the profile. Common source: the fork
`https://github.com/edimarlnx/omarchy.git`, branch `server`, **pinned** at
commit `468b511249b1a341311c46f5a7cf81aa5bc5af92`, plus
`profile/server/overlay/` packed as a source tarball. A builder that already
has a checkout exports `OMARCHY_SRC` and the PKGBUILD reads that instead
(`git+file://`), which is what `pkgs/build.sh` does with its read-only bind
mount at `/src/omarchy` and what the ISO builder does at `/omarchy-source`: no
network, and never the ambient state of a working tree.

### 2.0 Versioning: bump `pkgrel` on every content change

**Every change to what a package contains bumps its `pkgrel`.** `pkgver`
tracks the upstream Omarchy release the profile is built against, so it stays
put for as long as the pinned commit does; `pkgrel` is the only field left that
says "this is a different package from the one you have".

This is not bookkeeping. The CI workflow publishes into a GitHub release whose
assets are addressed **by file name**, and the file name is
`<name>-<pkgver>-<pkgrel>-<arch>.pkg.tar.zst`. Rebuilding with the same version
republishes the same asset name: `repo-add` records the same version in
`omarchy-server.db`, `pacman -Syu` on an installed machine compares versions,
finds them equal, and reports nothing to do. The new content is on the server
and will never be installed. That has already happened once, to
`omarchy-server` and `omarchy-server-settings` at `4.0.1-1`, which is why both
now start at `4.0.1-2`.

Nothing in the toolchain can detect this for you — a package with new contents
and an old version is a perfectly valid package. The rules:

- changed anything under `profile/server/` (the overlay tarball) → bump
  `omarchy-server` **and** `omarchy-server-settings`, since the same tarball is
  a source of both;
- changed a `PKGBUILD`'s `package()`, `depends`, or the pinned `_commit` → bump
  that package;
- moved `pkgver` → reset `pkgrel` to `1`;
- test assertions never hard-code the version: `pkgs/test.sh` reads it back
  from `pacman -Q omarchy-server`, so a bump needs no edit there.

### 2.1 `omarchy-server-keyring` (3.7 KB)

Same layout as `omarchy-keyring`. The key packaged today is a **lab** key:
`pkgs/keys/gen-lab-key.sh` generates an ed25519 key without passphrase in
`pkgs/keys/` (gitignored, and private) and exports `.gpg` + `-trusted` +
`-revoked` into the keyring PKGBUILD directory **in the `omarchy-server-pkgs`
checkout**, where those three public files are committed: CI has to be able to
build the keyring package from a checkout of that repository alone. Current
fingerprint: `792739C447F15D9172C59F8F4398BBFF2AE89B1A`.

**Switching to a real key** means: generate offline, export the public part
over those three files, bump `pkgver` (a date), put the private key in the
`PACMAN_GPG_KEY` secret of `omarchy-server-pkgs` and rebuild. Nothing else
references the key material. The rotation ORDER matters and is written down in
that repository's README: a machine already installed trusts only the old key,
so the package that teaches it the new one has to be signed by the old one.

### 2.2 `omarchy-server-settings` (65 KB compressed, 145 KB installed)

`provides=(omarchy-settings=4.0.1)`, `conflicts=(omarchy-settings omarchy-settings-dev)`,
`depends=(bash curl)`; `plymouth` and `hicolor-icon-theme` are gone, and `gum`
moved to `omarchy-server`, where the commands that prompt with it live.

Ships: `default/{bash,bashrc,gpg,pacman,snapper,agents,libalpm,limine,systemd}`
(subset), `config/{btop,git,lazygit,tmux,starship.toml,omarchy/hooks}`, a
4-file `etc-overrides/`, `/etc` with 34 files, `/etc/skel/.config`, and
`usr/lib/systemd/zram-generator.conf.d/90-omarchy.conf`.

Overlay replacements (`profile/server/overlay/settings/`); each file explains
why in its own header:

| File | Change |
|---|---|
| `etc/limine-entry-tool.d/omarchy-defaults.conf` | no `quiet splash …`, no `initramfs_async=0`, with `console=ttyS0,115200 console=tty0`, no `resume=` |
| `default/limine/limine.conf` | `timeout: 0` (was commented out, so limine's 5 s default applied) |
| `etc/mkinitcpio.conf.d/omarchy_hooks.conf` | no `plymouth` hook, no NVIDIA/kms block |
| `etc/systemd/system/system.slice.d/10-oomd.conf` | replaces the session `app.slice.d/10-oomd.conf`; without it `systemd-oomd` is enabled but structurally unable to kill anything |
| `zram-generator/90-omarchy.conf` | `zram-size = ram / 2` |
| `etc-overrides/nsswitch.conf` | no `mdns_minimal` (Avahi/nss-mdns are gone) |
| `etc/fastfetch/config.jsonc` | MOTD without gpu/display/wm/de/terminal/theme; with shell and local ip |
| `etc/profile.d/omarchy-path.sh` | explicit `OMARCHY_PATH` export |
| `etc/omarchy-profile` | `server` marker read by `omarchy-apply-system` |
| `etc/profile.d/omarchy-motd.sh` | prints the login banner once per login shell |
| `etc/issue.net` | two plain lines, for an admin who wants an ssh `Banner` |
| `etc/systemd/system/serial-getty@.service.d/10-omarchy-issue.conf` | points agetty at `/etc/issue.serial` on the serial line |

Generated in `package()` rather than taken from the overlay:
`etc/pacman.d/omarchy-server.conf`, the `[omarchy-server]` repository
definition, plus an `Include` for it appended to each of the three channel
templates `default/pacman/pacman-{stable,rc,edge}.conf` (§5).

The three Docker configuration files upstream installs into `/etc`
(`docker/daemon.json`, `systemd/resolved.conf.d/20-docker-dns.conf`,
`systemd/system/docker.service.d/no-block-boot.conf`) ship as **defaults**
under `usr/share/omarchy/default/docker/` instead. Docker is an addon here, and
`20-docker-dns.conf` is not inert without it: `DNSStubListenerExtra=172.17.0.1`
makes systemd-resolved open a second DNS listener on a bridge address that does
not exist. `install/server/addons/docker.sh` copies all three into `/etc` when
the addon goes on.

Also generated in `package()`: `etc-overrides/os-release` and
`etc-overrides/issue` (see §2.5), plus `etc/issue.serial`.

Dropped entirely: `default/{hypr,plymouth,sddm,uwsm,themed,fonts,chromium,
firefox,audio,wireplumber,applications,omarchy,tensaku,voxtype,xcompose,
xdg-terminal-exec,environment.d,nautilus-python,udev,wayland-sessions,
alacritty,foot,ghostty,fontconfig}`, the 11 user units, the 3
`system-sleep` hooks, icons, fonts, plymouth/sddm themes, `usr/share/uwsm/`,
`etc/{sddm.conf.d,plymouth,cups,NetworkManager,modprobe.d,logind.conf.d}`,
`etc/systemd/system/plocate-updatedb.service.d/ac-only.conf`,
`etc/mkinitcpio.conf.d/thunderbolt_module.conf`,
`etc/sudoers.d/{omarchy-asdcontrol,omarchy-dns}`.

> Note: `etc/sudoers.d/omarchy-dns` (NOPASSWD for
> `omarchy-dns Cloudflare|Google|DHCP`) is left out even though the
> `omarchy-dns` command is packaged. It is a sudoers rule for a graphical
> network panel toggle; on a server it is unused surface. Trivial to bring
> back if the ISO's `configure_dns_resolver` phase turns out to need it.

### 2.3 `omarchy-server` (448 KB compressed, 1.21 MB installed)

`provides=(omarchy)`, `conflicts=(omarchy omarchy-dev)`,
`depends=(omarchy-server-keyring omarchy-server-settings=4.0.1 limine
limine-mkinitcpio-hook limine-snapper-sync snapper btrfs-progs gum
pacman-contrib)`; the 8 graphics/audio deps and
`ttf-jetbrains-mono-nerd-basic` are gone, `btrfs-progs` is in. `docker`,
`ufw`, `yay` and `tailscale` are `optdepends`.

The remaining runtime dependencies were audited against the commands a server
actually runs — `update-*`, `pkg-*`, `version*`, `channel-*`, `snapshot`,
`setup-security-*`, `migrate`, `apply-system`, `provision-*`,
`refresh-{pacman,limine,config}` — and against `install/server/*.sh`:

| Dependency | Verdict | Why |
|---|---|---|
| `gum` | kept | `omarchy-update-confirm` and `omarchy-update-restart` prompt with it, so a plain interactive `omarchy-update` needs it. `omarchy-update -y` does not. |
| `pacman-contrib` | kept | `paccache`, in `omarchy-update-pkg-prune` and in `install/server/prune-pkg-cache-server.sh`. |
| `git` | → optdepends | Six call sites: `omarchy-update-dev` and `omarchy-channel-set` are the dev-channel checkout path, and `omarchy-version`, `omarchy-version-branch` and `omarchy-update-available` all wrap it in `2>/dev/null \|\| true` version probes. `omarchy-server-addon dev` installs it. |
| `jq` | → optdepends | Used by `omarchy-cmd-terminal-cwd`, which needs a terminal, and by nothing on the update or install path. |
| `perl` | dropped | Four commands: `theme-bg-current`, `menu-input`, `menu-select`, `games-retro-install`. All graphical. |
| `fakeroot` | dropped | One command, `omarchy-upgrade-to-quattro`, a one-off desktop migration. Its real consumer is `makepkg`, which comes with the `dev` addon. |

`expac` was audited at the same time and is not in the core package list
either: the only shipped consumer is `omarchy-debug`, which belongs to the
desktop settings package. The lab scripts that used it to add up installed
sizes now read them out of `pacman -Qi`.

Ships: `bin/` (442), `install/` (including `install/server/`), `migrations/`
(92), `version` (rewritten with `pkgver`, unlike upstream), 442 symlinks in
`/usr/bin`, 92 migration stubs in `/etc/skel`, only
`00-omarchy-update-guard.hook`, and one system unit,
`/usr/lib/systemd/system/omarchy-tty-palette.service`.

Three commands are this profile's own, added to `bin/` before the `/usr/bin`
symlink loop so they are linked like any other: `omarchy-server-addon`,
`omarchy-tty-palette` and `omarchy-server-motd` (all three in §2.5). The unit
lives in this package rather than in the settings one because the command it
runs is here, and a unit whose `ExecStart` belongs to another package is a
dependency waiting to be forgotten.

Not shipped: `themes/` (120 MB), `shell/` (Quickshell), `applications/`,
`manual/`, `docs/`, `plans/`, `test/`, `agents/` (the relevant
`default/agents/skills` comes with settings).

**All 440 commands are packaged.** Curating 428 binaries carries its own risk
with no meaningful size gain (2.2 MB total); a desktop command simply fails
when called. Groups that only make sense with a graphical session, by prefix:
`theme-` (31), `hyprland-` (24), `launch-` (23), `menu-` (14), `plymouth-`
(7), `audio-` (9), `capture-` (8), `brightness-` (5), `webapp-` (5),
`voxtype-` (5), `notification-` (6), `restart-` (16, almost all session
components), `toggle-` (13, same), plus `omarchy-shell*`,
`omarchy-screensaver`, `omarchy-system-lock`,
`omarchy-refresh-{hyprland,sddm,plymouth,applications}` and most of `hw-` (27)
and `remove-` (26). Useful on a server: `update-*`, `pkg-*`, `version*`,
`channel-*`, `snapshot`, `setup-security-*`, `migrate`, `apply-system`,
`provision-*`, `cmd-*`, `dev-*`, `refresh-{pacman,limine,config}`.

#### Patches (`profile/server/overlay/patches/`, applied in `prepare()`)

| Patch | Size | What it does |
|---|---|---|
| `0001-apply-system-server-profile.patch` | 2.0 KB (27 lines added) | `omarchy-apply-system` reads the profile from `$OMARCHY_PROFILE` or `/etc/omarchy-profile`; when `server`, it sources `install/server/all.sh` instead of `config/all.sh` + `omarchy-apply-hardware` + `login/all.sh` + `post-install/all.sh`. The desktop path is unchanged. |
| `0002-server-package-name.patch` | 1.8 KB | `omarchy-version`, `omarchy-update-available` and `omarchy-channel-current` recognize `omarchy-server` / `omarchy-server-settings`. |

Patch 0002 matters because `provides=omarchy` does not answer
`pacman -Q omarchy`; without it `omarchy-version` exits 1 with no output on a
server.

> Patch 0001 also diverts `login/all.sh` and `post-install/all.sh`, not only
> `config/all.sh` and `omarchy-apply-hardware`. `login/all.sh` only calls
> `sddm.sh`, which edits `/etc/pam.d/sddm` (absent), and `post-install/pacman.sh`
> sources `hardware/pacman.sh` besides the `cups-browsed` block. The two
> equivalent steps live inside `install/server/all.sh`
> (`post-install-pacman-server.sh`, `udev.sh`, `localdb.sh`), so nothing is lost.

#### `install/server/` (overlay)

`all.sh` (orchestrates) and the leaf scripts, following
`agents/skills/install-scripts.md` (no shebang, no `exit`, sourced through
`run_logged`, paths via `$OMARCHY_INSTALL`):

- `increase-lockout-limit-server.sh`: faillock in `system-auth`, without the
  three `sed`s on `/etc/pam.d/sddm-autologin`.
- `ssh-command-path-server.sh`: `PATH` line in `pam_env.conf` without the
  `mise` shims, **plus** `OMARCHY_PATH DEFAULT=/usr/share/omarchy` (see §4).
- `sshd-hardening-server.sh`: writes
  `/etc/ssh/sshd_config.d/10-omarchy-server.conf` with
  `PasswordAuthentication no`, `KbdInteractiveAuthentication no`,
  `PermitRootLogin no`, `PermitEmptyPasswords no`, and validates the result
  with `sshd -G`. Upstream has no equivalent: on the desktop,
  `omarchy-setup-security-sshd` is what turns sshd on and the owner runs it by
  hand. Here sshd is enabled unconditionally at install time, so the hardening
  has to be part of the install. That command stays useful for the half this
  does not do — authorizing keys — and its `ufw limit 22/tcp` matches what
  `firewall-server.sh` already wrote.
- `network-server.sh`: replaces upstream's `hardware/network.sh`, which exists
  to retire systemd-networkd in favour of NetworkManager. Keeps archinstall's
  `20-ethernet.network` when it is there, writes an equivalent DHCP
  `.network` for `en*`/`eth*` when it is not, points `/etc/resolv.conf` at
  resolved's stub, and masks `systemd-networkd-wait-online`. The resolv.conf
  symlink is skipped when the path is a mount point, which is what it is
  inside the ISO's install chroot (`arch-chroot` bind-mounts the live
  environment's file so the chroot has DNS); the ISO writes the symlink from
  outside in its `configure_dns_resolver` phase.
- `limine-branding-server.sh`: copies the Limine wallpaper from
  `default/limine/limine-wallpaper.png` to the ESP, whose mount point it reads
  out of `ESP_PATH` in `/etc/default/limine`. Best-effort: Limine skips a
  wallpaper it cannot read instead of panicking, so a machine whose ESP is full
  boots without the image rather than not at all.
- `enable-services-server.sh`: `set-default multi-user.target`, enables
  `sshd`, `systemd-networkd`, `systemd-resolved`, `systemd-timesyncd`,
  `linux-modules-cleanup`, `systemd-oomd`, `serial-getty@ttyS0`,
  `omarchy-tty-palette`; masks the
  plymouth, sddm, cups, avahi, bluetooth and power-profiles units and disables
  `snapper-timeline.timer`. No `NetworkManager` and no `docker.socket` — the
  `docker` addon enables the latter.
- `firewall-server.sh`: deny-in/allow-out, `ufw limit 22/tcp`, `ENABLED=yes` +
  `systemctl enable ufw`. The Docker rules and the `ufw-docker install` shim
  moved to `install/server/addons/docker.sh`; the LocalSend rules are gone.
- `post-install-pacman-server.sh`: restores the channel's
  `pacman.conf`/`mirrorlist`; no `cups-browsed` block, no
  `source hardware/pacman.sh`.
- `prune-pkg-cache-server.sh`: `paccache -rk1` + `-ruk0` at the end, so the
  `@factory` snapshot is taken without the install cache.

#### Addons (`install/server/addons/` + `bin/omarchy-server-addon`)

The core list is small enough to be useless for some machines on purpose, so
the profile needs a supported way to add things back. An addon is a package
list plus an optional setup leaf:

```
profile/server/addons/<name>.packages          the packages
profile/server/overlay/runtime/install/server/addons/<name>.sh   optional setup
```

Both end up in the runtime package under `install/server/addons/`, and
`pkgs/build.sh` packs `profile/server/addons/` into the same overlay tarball as
the rest, because the ISO builder reads those `.packages` files directly to
fill the offline mirror. One source of truth, two consumers.

`omarchy-server-addon <name>` reads the list, installs it and sources the leaf.
It re-execs under sudo rather than sprinkling `sudo` through the setup, so the
leaf runs as root exactly the way `install/server/*.sh` does during the ISO
install. `OMARCHY_ADDON_PACMAN_CONF` points it at another `pacman.conf`, which
is how the ISO's `install_addons` phase makes it consume the offline mirror.
Online it runs `pacman -Syu --needed`, not `-Sy` + `-S`: a fresh install has
empty sync databases (it ran off the ISO's mirror) and pulling one package into
an unrefreshed system is the partial upgrade Arch warns about.

| Addon | Packages | Setup leaf |
|---|---|---|
| `docker` | docker, docker-compose, docker-buildx, ufw-docker, lazydocker | the three `/etc` drop-ins, the two `allow-docker-dns` ufw rules, the `ufw-docker install` shim, `docker.socket` |
| `tailscale` | tailscale | enables `tailscaled.service` |
| `cli-tools` | bat, btop, dua-cli, eza, fastfetch, fd, fzf, lazygit, ripgrep, tldr, tmux, zoxide | — |
| `dev` | base-devel, git, yay, mise-bin | — |
| `editor` | omarchy-nvim | seeds `~/.config/nvim` for existing users |
| `net-tools` | inotify-tools, rsync, socat, unzip, whois | — |
| `tui-tools` | the 14 tui-tools terminal UIs | preflight: configures `[tui-tools]` and pins its signing key |
| `vm` | qemu-guest-agent | enables `qemu-guest-agent.service` |

`tui-tools` is the addon whose packages are in no Arch repository: they come
from `https://pkgs.tui.tools/arch/$arch`, signed by the tools' own key. A
machine gets them from the ISO's offline mirror (`mkcidata.sh --addons
tui-tools`), where `iso/build.sh` put them after checking every signature, or
over the network from that repository, which the addon's preflight configures
with `SigLevel = Required` after verifying the key's fingerprint against the
one pinned in the profile.

---

### 2.4 `tui-tools`, the addon that is not built here

Fourteen terminal UIs from the [`tui-tools`](https://github.com/tui-tools)
organization, one repository each: `tui-firewall` drives the firewall this
profile already configures, `tui-systemd` drives the units and reads their
journal, `tui-secure` reviews the machine's security posture, and so on. Each
is a single static Go binary that shells out to the tool the machine already
has, previews the exact command line of every change and keeps no state of its
own — no daemon, no listening socket. None is in the core: a headless machine
does not need a TUI to boot, and the core list is what it needs to boot.

Until 2026-08-29 two of them, `tui-firewall` and `tui-systemd`, were built from
source here and served out of `[omarchy-server]`. They are not any more. The
tools publish their own signed pacman repository, and rebuilding somebody
else's releases to hand them to a user is a maintenance debt with no upside —
two PKGBUILDs to keep in step with upstream tags, a Go toolchain in the builder,
and a version in the ISO that nobody could reproduce from a signed source.

What this profile owns instead is **which key a machine ends up trusting**:

| Aspect | Choice |
|---|---|
| Repository | `[tui-tools]`, `Server = https://pkgs.tui.tools/arch/$arch` |
| `SigLevel` | `Required TrustedOnly` — the repository signs its database and every package, and there is no reason to accept less |
| Key | `767CFB33 7B01F32F FC073F3F 389120B2 77E4FB44`, **vendored** at `install/server/addons/tui-tools.pubkey.asc` and pinned by fingerprint in the preflight |
| Where it is set up | `install/server/addons/tui-tools.preflight.sh`, which runs BEFORE the packages are installed — on an installed machine there is nowhere else to fetch them from |
| Offline install | `iso/build.sh` downloads the packages, verifies each one against that key and drops them into `<pkgs-checkout>/prebuilt/`, so the addon also works on a machine that has never seen the network |
| Failure mode | a bad or unreachable key is fatal on an installed machine; during an install off the offline mirror it is reported and the install continues, because the packages are already on the medium |

The fingerprint is checked before `pacman-key --add`: adding a downloaded key
without that check would trust whatever the network handed over.

---

### 2.5 Identity, at zero new packages

A stock Arch install with `omarchy-server` on it looks like a stock Arch
install: Limine's default menu, `Arch Linux \r (\l)` on the console, no MOTD.
The owner's constraint was that fixing that must not add a package, because a
package is attack surface. Everything below is configuration, one 30-line
command, one 40-line renderer and a 17 KB image.

| Where | What | Shipped by |
|---|---|---|
| Bootloader | `interface_branding: Omarchy Server`, `timeout: 2`, Tokyo Night palette, `wallpaper: boot():/limine-wallpaper.png` | `default/limine/limine.conf` + `limine-branding-server.sh` |
| Console, before login | `/etc/issue`: the logo in Tokyo Night green, the version, hostname, tty, IPv4 | `etc-overrides/issue` (scriptlet) |
| Serial console | the same fields without the logo | `etc/issue.serial` + a `serial-getty@.service.d` drop-in |
| Every VT | the Tokyo Night palette, applied before getty | `omarchy-tty-palette` + its oneshot unit |
| After login | the MOTD | `etc/profile.d/omarchy-motd.sh` → `omarchy-server-motd` |
| Everywhere | `NAME`, `PRETTY_NAME`, `ID`, `ANSI_COLOR`, `LOGO` | `etc-overrides/os-release` |

### The bootloader

`/boot/limine.conf` is a copy of `default/limine/limine.conf`: the ISO
installer writes it (`_write_limine_defaults` reads the template out of the
target) and `omarchy-refresh-limine` rewrites it from the same file.
`limine-entry-tool` and `limine-snapper-sync` only add and remove entries below
it, so everything above the first entry survives every regeneration — which is
why the branding belongs in the template and not in an edit of the ESP's copy.
The acceptance list checks that after `limine-snapper-sync` has run.

`timeout` went from 0 to 2: at 0 the menu is only reachable by holding a key
during the loader's startup, which is not a thing anyone does on a machine they
are not standing in front of. Two seconds costs exactly two seconds of boot
(measured: loader 0.67 s → 2.6-2.8 s, total 4.8 → 6.7-7.0 s).

Two things about the wallpaper were found by looking at the screen rather than
by reading the documentation, and both fail **silently**:

1. **`term_background` is `TTRRGGBB`, and a six-digit value means opaque.**
   `term_background: 1a1b26` paints an opaque panel over the whole terminal
   area and the wallpaper never appears, with no error anywhere. `80000000`
   lets it through at half strength, which keeps the menu text as legible as it
   is on a flat background.
2. **`wallpaper_style: centered` crops an image larger than the framebuffer.**
   The artwork is 1920x1080 and a VM console is commonly 1280x800. `stretched`
   (the default) is right for a wordmark on a flat field.

The image itself is an 8-bit truecolor PNG. Limine reads BMP, PNG, JPEG and
QOI, and skips a wallpaper it cannot read instead of panicking — which is what
makes `limine-branding-server.sh` safe to be best-effort, and also what makes
every mistake above look identical from the outside.

### The console

`/etc/issue` is owned by the `filesystem` package, so it travels through
`etc-overrides/` and the install scriptlet, the same route `os-release` takes.
It is generated in `package()` from the upstream `logo.txt`, with **literal ESC
bytes**: agetty copies an issue file out verbatim except for its own backslash
sequences, and `\e` is not one of them. `\S{VERSION_ID}`, `\n`, `\l` and `\4`
are, and agetty expands them into the version, the hostname, the tty and the
first IPv4 address.

The logo is 81 columns, 83 with the two-column indent. That is right for a
video console (an installed machine comes up well past 128 columns) and wrong
for a serial line, where 80 columns is the contract and every row of the logo
would wrap by one character. So the serial console gets `/etc/issue.serial` —
the same fields, no art — through a `serial-getty@.service.d` drop-in that adds
`--issue-file` to agetty's command line. Evidence for both:
`pocs/server-install/reference/console.png` and `.../serial-issue.txt`.

`/etc/issue.net` ships as two plain lines with no escapes, and nothing enables
it: an ssh `Banner` is an owner's decision, not a default. Adding
`Banner /etc/issue.net` to `/etc/ssh/sshd_config.d/` is the whole of it.

### The palette

`omarchy-tty-palette` writes the sixteen `\e]P<n><rrggbb>` sequences the Linux
console uses to redefine its colour table, to `/dev/tty1` through `/dev/tty6`.
The values are upstream's, lifted from `omarchy-provision-owner`'s
`set_tokyo_night_colors`, which is what the desktop's first-boot form uses; the
palette matches the bootloader's `term_palette`.

`omarchy-tty-palette.service` is a oneshot, `After=systemd-vconsole-setup` so
its font and keymap work is not undone, `Before=getty.target` so the login
banner is drawn in the palette rather than repainted a moment later, and
`ConditionPathExists=/dev/tty1` so a machine with no video console skips it
instead of failing. It deliberately never touches `/dev/ttyS0`: on a serial
line the terminal at the other end owns its own colours, and the escape would
be printed as garbage into whatever is logging the port.

### The MOTD

Upstream wires no MOTD at all — on the desktop the identity comes from the
session, and fastfetch is something the user runs by hand. `/etc/profile.d/
omarchy-motd.sh` runs `omarchy-server-motd` once per interactive login shell
(guarded on `$-`, on `[ -t 1 ]` and on a marker variable, so `sudo -i` inside a
login shell does not print it twice, and `ssh host command`, scp and sftp never
reach it).

`omarchy-server-motd` execs `fastfetch` when it is installed — that is what
`/etc/fastfetch/config.jsonc` is written for, and the `cli-tools` addon brings
it in. fastfetch is **not** in the core, and a base install that shows nothing
at login is exactly the problem this is here to fix, so the same fields are
rendered from what `base` already has: bash, coreutils, procps-ng, iproute2 and
pacman. OS (`PRETTY_NAME`), host, kernel, uptime, packages, pending updates,
memory and the first global IPv4 address.

Pending updates come from `pacman -Qu`, a query against the sync database
already on disk. `checkupdates` would be more current and would download a
database to say so, which is not something to do on every login of a machine
that may be on a metered link. The fastfetch config asks the same question the
same way.

The terminal width comes from `stty size </dev/tty`, not from `$COLUMNS` or
`tput cols`: this runs out of `/etc/profile`, before bash has necessarily set
the variable, and on a fresh VT `$TERM` may not be set either. Below 83 columns
the logo is dropped for the wordmark alone.

### `os-release`

```
NAME="Omarchy Server"
PRETTY_NAME="Omarchy Server 4.0.1"
ID=omarchy-server
ID_LIKE="omarchy arch"
ANSI_COLOR="0;32"
LOGO=omarchy
```

`PRETTY_NAME` carries the version because it is what every tool that greets a
human prints: the MOTD, `hostnamectl`, ssh banners, monitoring agents.
`ANSI_COLOR` is the plain `0;32` rather than a 24-bit green, because it is read
by consoles that may have no truecolor — and slot 32 is the one
`omarchy-tty-palette` paints Tokyo Night green into anyway.

---

## 2.6 The SELinux package set

The `selinux` addon needs nineteen packages that exist in no Arch repository.
They are built by `omarchy-server-pkgs/scripts/build-selinux.sh`, which is a
second, separate build path from `scripts/build.sh` for three reasons: the
sources are somebody else's PKGBUILDs, the builds are real compiles rather than
`arch=any` file bundles, and one of them is systemd.

```bash
cd ../omarchy-server-pkgs
./scripts/build-selinux.sh                 # every package in the manifest
./scripts/build-selinux.sh libselinux      # one
```

Nothing is vendored. `pkgbuilds/selinux.manifest` holds the pinned upstream
commit of [`archlinuxhardened/selinux`](https://github.com/archlinuxhardened/selinux),
the build order, and a paragraph per package saying why it is in the set —
followed by a paragraph per package saying why the ones that are not, are not.
The script clones that commit, applies whatever is in
`pkgbuilds/selinux-overrides/`, and builds into `out/selinux/`. Packages whose
exact `pkgver-pkgrel` file names are already there are skipped, so an
interrupted run resumes; `OMARCHY_SELINUX_FORCE=1` rebuilds.

Three things differ from `scripts/build.sh` and each has a reason:

- **Privileges are dropped with `setpriv`, not `su`.** This build installs
  `pam-selinux` over the container's own pam, because `systemd-selinux` builds
  against it. Dropping privileges through a PAM stack in the middle of being
  replaced is not a risk worth taking; `setpriv` is a direct setuid/setgid and
  never opens a PAM session.
- **Dependencies are installed as root, not by `makepkg -s`.** `makepkg -s`
  shells out to `sudo`, which is the same problem, and half of what these
  PKGBUILDs depend on exists in no repository because an earlier package in the
  list built it. `pacman -T` reports what is still unsatisfied; anything the
  sync databases do not know is one of those and is already installed.
- **`PATH` includes `/usr/bin/vendor_perl`.** `po4a`, a makedepend of
  `util-linux-selinux`, installs there. Without it meson reports
  `Program po4a found: NO` and fails a build with the package installed —
  which is exactly how that line came to be written down.

The two shared halves live in `scripts/gnupg-builder.sh`, sourced by both build
scripts, so the signing key is prepared the same way in both.

### Lockstep with Arch

Eight of the nineteen `provides=`/`conflicts=` a core Arch package. That
creates a standing obligation: **if the rebuild is behind Arch, installing it
is a downgrade**, delivered silently through `provides=`.

At the pinned commit, seven of the eight matched Arch exactly and one did not:
`openssh-selinux` was 10.4p1-3 against Arch's 10.5p1-1. Installing it would
have downgraded the one daemon this profile exposes to the network. So
`pkgbuilds/selinux-overrides/openssh-selinux/` carries Arch's current `openssh`
PKGBUILD with the four SELinux changes archlinuxhardened makes — the name,
`libselinux` in `depends`, `conflicts`/`provides`, and `--with-selinux` — and
nothing else. A second override, `libselinux`, backports the one-line upstream
fix that lets 3.10 build against Python 3.14.

Checking that by hand does not scale. What a pipeline adopting this needs is a
job that, for each `*-selinux` package, compares its `pkgver` to the Arch
package of the same name and fails when the rebuild is behind:

```bash
# The check, in the form it would take. Not yet wired into CI.
for pkg in coreutils cronie dbus findutils iproute2 logrotate openssh \
           pam pambase psmisc shadow sudo systemd util-linux; do
  ours=$(sed -n 's/^pkgver=//p' "$tree/$pkg-selinux/PKGBUILD")
  theirs=$(pacman -Si "$pkg" | awk '/^Version/ { print $3 }')
  [[ $theirs == "$ours"-* ]] || echo "BEHIND: $pkg-selinux $ours vs $theirs"
done
```

That job is the largest piece of unfinished work in this route, and
`docs/mac.md` §3 says so in the same words.

### Where they end up

Two places, and neither is `[omarchy-server]` yet:

- `out/selinux/` — where `iso/build.sh` copies them from, into
  `<pkgs-checkout>/prebuilt/`, which `iso/patches/0011` drops into the ISO's
  offline mirror. That is how `omarchy-server-addon selinux` works on a machine
  that has never seen the network.
- `scripts/publish.sh` does **not** publish them today. Nineteen packages, one
  of them a full systemd, is a different release cadence from four `arch=any`
  file bundles, and pushing them into the same `repo` release without first
  solving the lockstep check above would ship a downgrade to every installed
  machine the first time upstream falls behind.

---

## 3. Build and test

```bash
./pkgs/build.sh                 # every package
./pkgs/build.sh omarchy-server  # just one
./pkgs/test.sh                  # install in a clean Arch container and verify
```

`build.sh` runs everything in an `archlinux:latest` container as user
`builder` (the same design the GitHub Actions workflow in `omarchy-server-pkgs`
uses), with `upstream/omarchy` mounted read-only at `/src/omarchy` and
`OMARCHY_SRC` pointing the PKGBUILDs at it. Gitignored outputs:
`pkgs/out/` (packages + `.sig`) and `pkgs/repo/`
(`omarchy-server.db.tar.gz`/`.files` signed with `repo-add --sign`).

> `makepkg --nodeps` is used instead of `makepkg -s`. The three packages are
> `arch=any` with no compile step, and their `depends` include each other plus
> five packages that only exist in the `[omarchy]` repo. Installing ~200 MiB of
> runtime dependencies adds nothing to the build. The only real `makedepends`,
> `git`, is installed in the image.

`test.sh` starts another clean container, adds `[omarchy]` (for
`limine-mkinitcpio-hook`, `limine-snapper-sync`, `ufw-docker`, `tzupdate`,
`yay`) and `[omarchy-server]` with `SigLevel = Required DatabaseOptional` /
`Server = file:///repo`, bootstraps the trust anchor and runs
`pacman -Sy omarchy-server`. The equivalent test against the repository as it
is actually served — over HTTP, with a hostile mirror on the other side of the
same run — is `scripts/verify.sh` in `omarchy-server-pkgs` (§5).

**Trust anchor bootstrap**: the keyring package is signed by the very key it
delivers, so it cannot verify itself (the same problem as
`archlinux-keyring`). `test.sh` solves it by extracting the `.gpg` from inside
the package, running `pacman-key --add` + `--lsign-key`, and only then
installing the package with full verification. On a real install the
equivalent step is the ISO's offline mirror, which pacman reads with
`SigLevel = Optional TrustAll`.

### Results (2026-08-29, re-run after the `tui-*` rename)

80 assertions, all PASS. Measured in the container:

| Item | Value |
|---|---|
| `omarchy-server` | 543 KB compressed / **1.49 MiB** installed (upstream `omarchy`: 120 MB / 126 MB) |
| `omarchy-server-settings` | 66 KB / **145 KiB** (upstream: 724 KB / 1.3 MB) |
| `omarchy-server-keyring` | 3.7 KB / 295 B |
| `tui-firewall` (addon, not installed by the base) | 1.5 MB / **3.70 MiB** |
| `tui-systemd` (addon, not installed by the base) | 1.8 MB / **4.28 MiB** |
| Dependency closure | **193 packages**, **739 MiB** installed |
| Graphical packages present | none (`hyprland sddm pipewire quickshell plymouth wireplumber uwsm gnome-keyring xdg-desktop-portal-hyprland`) |

The 193 packages / 739 MiB are the `archlinux:latest` image plus the closure of
`omarchy-server`, **not** an installed machine. The dependency audit above is
what moved it from 203 / 849 MiB: dropping `git`, `jq`, `perl` and `fakeroot`
from `depends` takes ten packages and 110 MiB out of every install that only
wanted the runtime. A real install of the full profile measures 220 packages /
1402 MiB (`pocs/server-install/README.md`).

Beyond the assertions the container inherited, the suite now also checks that
the base stays lean — no `git`/`jq`/`perl`/`fakeroot` in `Depends On`, no
docker, no tailscale, no NetworkManager, no compiler, the Docker drop-ins under
`/usr/share` rather than `/etc` — that the sshd hardening and the `ufw limit`
rule are in the shipped scripts, and that every addon list and
`omarchy-server-addon` itself are packaged and behave.

An `== [omarchy-server] repository wiring ==` block covers §5 as bytes on disk:
the shipped `/etc/pacman.d/omarchy-server.conf` (section, `SigLevel`, `Server`),
the `Include` in all three channel templates, the `backup=` entry, and that the
install scriptlet leaves an inline definition alone instead of duplicating the
section.

An `== identity ==` block covers §2.5 as bytes on disk: the `os-release` values,
the branding and `wallpaper` lines in `limine.conf`, the wallpaper file and the
install leaf that copies it, `/etc/issue` (logo, `\S{VERSION_ID}`, an ESC byte)
against `/etc/issue.serial` (no logo) and the drop-in that points agetty at it,
`/etc/issue.net` carrying no escapes, the palette unit and command with the
serial console explicitly untouched, and the login banner both wired and
rendering. An `== tui-firewall ==` block installs the addon package in the
container and checks the static binary, `--version`, the ufw-pinned
configuration, the licence and that it replaces the old `fwall` package; an
`== tui-systemd ==` block does the same for the other tool.

What **cannot** be verified in a container and is checked in the VM install:
`systemctl enable/mask`, `ufw`, `ufw-docker install`, `mkinitcpio`/UKI,
`snapper`, `paccache` on a real `@pkg`, the serial console and booting into
`multi-user.target`. During `pacman -Sy` the limine hook already complains
(`FAT32 boot partition not found`), expected without an ESP.

---

## 4. `OMARCHY_PATH` audit

`grep` over the 440 commands in `bin/`:

- **67** reference `$OMARCHY_PATH`.
- **14** carry a `${OMARCHY_PATH:-/usr/share/omarchy}` fallback, including
  every entry point called by systemd or by the ISO: `omarchy-apply-system`,
  `omarchy-apply-hardware`, `omarchy-provision-user`,
  `omarchy-provision-owner`, `omarchy-migrate`, `omarchy-version`.
- **53** use `$OMARCHY_PATH` with no default.

Who covers what:

| Execution path | Coverage |
|---|---|
| login shell (`bash -l`, interactive ssh) | `/etc/profile.d/omarchy.sh` → `default/bash/env-bootstrap`, plus the overlay's `omarchy-path.sh` |
| non-login interactive shell | `/etc/skel/.bashrc` → `env-bootstrap` |
| `ssh host omarchy-…` (no shell at all) | **was the gap**; now `pam_env.conf` (`ssh-command-path-server.sh`) |
| systemd units | the binaries called by units have their own fallback (see above), so **no `Environment=OMARCHY_PATH=` was needed** |
| uwsm session | does not exist on the server |

Unit audit: the only units with `ExecStart` packaged by `omarchy-settings` are
the 11 **user** units, all dropped in the server profile. The two system units
(`omarchy-provision-owner.service`,
`omarchy-system-factory-reset-finish.service`) live in `install/provisioning/`
and call `omarchy-provision-owner` (fallback on line 17) and
`omarchy-system-factory-reset-finish` (does not use `OMARCHY_PATH`).

Of the 53 without fallback, the ones relevant to a server are
`omarchy-channel-set`, `omarchy-channel-current`, `omarchy-refresh-pacman`,
`omarchy-refresh-limine`, `omarchy-refresh-config`, `omarchy-snapshot`,
`omarchy-update-available`, `omarchy-update-dev`, `omarchy-reinstall-pkgs`,
`omarchy-dns`, `omarchy-provision-first-run`. All work over non-interactive
ssh thanks to the `pam_env` line. The other 42 are theme, plymouth, sddm,
hyprland, chromium, GUI app installers and the like.

Candidate upstream proposal: replacing `$OMARCHY_PATH` with
`${OMARCHY_PATH:-/usr/share/omarchy}` in those 53 commands makes the whole
runtime usable outside a session; a mechanical, risk-free change.

---

## 5. How the remote repository works

The profile's packages are served from the **assets of a single GitHub
release** of
[`edimarlnx/omarchy-server-pkgs`](https://github.com/edimarlnx/omarchy-server-pkgs),
tagged `repo`. The tag never moves; every build replaces the assets under it.
That gives pacman a stable base URL:

```
[omarchy-server]
SigLevel = Required DatabaseOptional
Server = https://github.com/edimarlnx/omarchy-server-pkgs/releases/download/repo
```

The idea is not new — the upstream Omarchy ISO already carries
`Server = https://github.com/NoaHimesaka1873/arch-mact2-mirror/releases/download/release`
for the MacBook T2 repository. A GitHub release is a flat, cacheable,
CDN-backed file host that costs nothing to run, which is the entire job
description of a pacman mirror.

### What is in the release

| Asset | Why |
|---|---|
| `<pkg>-<ver>-<arch>.pkg.tar.zst` + `.sig` | the packages and their detached signatures |
| `omarchy-server.db.tar.gz` / `.files.tar.gz` + `.sig` | the database `repo-add --sign` produced |
| `omarchy-server.db` / `.files` + `.sig` | **real copies** of the two above |

The last row is the one detail that a naive upload gets wrong. `repo-add`
leaves `omarchy-server.db` as a **symlink** to `omarchy-server.db.tar.gz`, and
`$repo.db` is the exact name pacman asks the mirror for. A release asset cannot
be a symlink, so `scripts/publish.sh` publishes those two as copies.

`publish.sh` also fetches the currently published database before adding this
run's packages to it, so a build that rebuilt one package does not strand the
other three, and it deletes a package asset only once the database has stopped
referencing it.

### The three pieces on the client

1. **`omarchy-server-keyring`** puts the repository's public key in
   `/usr/share/pacman/keyrings/` and its `.install` runs
   `pacman-key --populate omarchy-server`, which is what makes
   `SigLevel = Required` mean something rather than merely say something. The
   runtime package depends on it (§2.3), so it cannot be skipped.
2. **`omarchy-server-settings`** ships `/etc/pacman.d/omarchy-server.conf` with
   the section above, and appends `Include = /etc/pacman.d/omarchy-server.conf`
   to each of `default/pacman/pacman-{stable,rc,edge}.conf`. The definition
   lives in its own file precisely because `/etc/pacman.conf` is **rewritten
   wholesale** by `omarchy-refresh-pacman` and by
   `install/server/post-install-pacman-server.sh`; a repository definition that
   a channel switch deletes is a repository that disappears at the worst
   moment.
3. **The install scriptlet** adds that `Include` to a `/etc/pacman.conf` that
   is already in place, because an ordinary `omarchy-update` never rewrites
   that file from the template. It refuses to do so in two cases: when
   `pacman.conf` has no `[omarchy]` section — which is how the live ISO's
   offline configuration looks inside the target chroot, and adding a remote
   repository there would send every remaining offline install to GitHub — and
   when an `[omarchy-server]` section is already defined inline.

`omarchy-server-addon <name>` needs nothing else: it already runs
`pacman -Syu --needed`, so the refresh is what pulls the current database out
of the release. It now says so when the repository is missing, instead of
letting pacman answer "target not found".

The ISO's offline mirror is unaffected and still reads with
`SigLevel = Optional TrustAll` (`configs/pacman-offline.conf`), which is right:
its integrity is the ISO's, and pacstrap verifies against the *live* keyring,
not the target's.

### The build

`.github/workflows/publish.yml` runs on every push to `main` and on manual
dispatch, in an `archlinux:latest` container. It imports `PACMAN_GPG_KEY`
(ASCII-armored private key, with `PACMAN_GPG_PASSPHRASE` optional) into a
throwaway GnuPG home, runs `scripts/build.sh`, then `scripts/publish.sh` with
the `GITHUB_TOKEN`. Only the public half of the key is committed, in
`pkgbuilds/omarchy-server-keyring/`.

The key in place today is the **lab** key (§2.1). Replacing it is four steps,
written down in that repository's README.

### Verified end to end, 2026-08-29

`scripts/verify.sh` builds the repository locally (`build.sh` +
`publish.sh --local`), serves `repo/` over **HTTP** to a clean `archlinux`
container and puts it through the real client path. 13 assertions, all PASS:

| | |
|---|---|
| transport | the database is fetched over HTTP |
| bootstrap | the key is read out of the keyring package, locally signed, the package installed under verification, `pacman-key --populate omarchy-server` |
| install | `pacman -Sy` syncs `omarchy-server.db`; `tui-firewall` and `omarchy-server` install with `SigLevel = PackageRequired` in force |
| client wiring | the installed `/etc/pacman.d/omarchy-server.conf` carries the real `Server` line |
| **hostile mirror** | the same repository re-served with `tui-firewall` signed by a **freshly generated stranger's key** and the database rebuilt so every checksum agrees → pacman refuses it (`required key missing from keyring`) and nothing installs |
| **unsigned** | the same package with its `.sig` removed → pacman refuses to complete the transaction and nothing installs |

The hostile-mirror case is the one that matters. A checksum proves nothing
about a database an attacker just rewrote; the signature is the only thing
between the machine and that mirror, and this is the test that says so out
loud. The download cache and the previously synced database signature are both
cleared before it runs, or the test would be verifying the copy it already
trusts.

### What is left

Publishing itself: the release does not exist until the first push of
`omarchy-server-pkgs` runs the workflow. Until then a machine that has the
repository configured simply finds nothing to sync from it, and the ISO's
offline mirror carries the packages exactly as before.
