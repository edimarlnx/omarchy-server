# Packaging the server profile

The three packages (`omarchy-server-keyring`, `omarchy-server-settings`,
`omarchy-server`) are built, signed and tested in a clean Arch container.

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

## 2. The three server packages

PKGBUILDs in `pkgs/pkgbuilds/`. Common source: the upstream checkout
**pinned** at commit `468b511249b1a341311c46f5a7cf81aa5bc5af92`, consumed as
`git+file:///src/omarchy#commit=...` (read-only bind mount in the container),
plus `profile/server/overlay/` packed as a source tarball by `build.sh`. Once a
GitHub fork is used, the URL changes and the mount goes away; that is the only
line to change (`OMARCHY_GIT_URL`).

### 2.1 `omarchy-server-keyring` (3.7 KB)

Same layout as `omarchy-keyring`. The key packaged today is a **lab** key:
`pkgs/keys/gen-lab-key.sh` generates an ed25519 key without passphrase in
`pkgs/keys/` (gitignored) and exports `.gpg` + `-trusted` + `-revoked` into the
PKGBUILD directory. Current fingerprint:
`792739C447F15D9172C59F8F4398BBFF2AE89B1A`.

**Switching to a real key** means: generate offline, export the public part,
replace the three files, bump `pkgver` (a date) and rebuild. Nothing else in
the repository references the key material.

### 2.2 `omarchy-server-settings` (52 KB compressed, 124 KB installed)

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

The three Docker configuration files upstream installs into `/etc`
(`docker/daemon.json`, `systemd/resolved.conf.d/20-docker-dns.conf`,
`systemd/system/docker.service.d/no-block-boot.conf`) ship as **defaults**
under `usr/share/omarchy/default/docker/` instead. Docker is an addon here, and
`20-docker-dns.conf` is not inert without it: `DNSStubListenerExtra=172.17.0.1`
makes systemd-resolved open a second DNS listener on a bridge address that does
not exist. `install/server/addons/docker.sh` copies all three into `/etc` when
the addon goes on.

Also generated in `package()`: `etc-overrides/os-release` with
`ID=omarchy-server`, `ID_LIKE="omarchy arch"`.

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

### 2.3 `omarchy-server` (435 KB compressed, 1.24 MB installed)

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

Ships: `bin/` (440), `install/` (including `install/server/`), `migrations/`
(92), `version` (rewritten with `pkgver`, unlike upstream), 440 symlinks in
`/usr/bin`, 92 migration stubs in `/etc/skel`, and only
`00-omarchy-update-guard.hook`.

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
- `enable-services-server.sh`: `set-default multi-user.target`, enables
  `sshd`, `systemd-networkd`, `systemd-resolved`, `systemd-timesyncd`,
  `linux-modules-cleanup`, `systemd-oomd`, `serial-getty@ttyS0`; masks the
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
| `vm` | qemu-guest-agent | enables `qemu-guest-agent.service` |

---

## 3. Build and test

```bash
./pkgs/build.sh                 # all three packages
./pkgs/build.sh omarchy-server  # just one
./pkgs/test.sh                  # install in a clean Arch container and verify
```

`build.sh` runs everything in an `archlinux:latest` container as user
`builder` (the same design as a future GitHub Actions workflow), with
`upstream/omarchy` mounted read-only at `/src/omarchy`. Gitignored outputs:
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
`pacman -Sy omarchy-server`.

**Trust anchor bootstrap**: the keyring package is signed by the very key it
delivers, so it cannot verify itself (the same problem as
`archlinux-keyring`). `test.sh` solves it by extracting the `.gpg` from inside
the package, running `pacman-key --add` + `--lsign-key`, and only then
installing the package with full verification. On a real install the
equivalent step is the ISO's offline mirror, which pacman reads with
`SigLevel = Optional TrustAll`.

### Results (2026-08-29)

42 assertions, all PASS. Measured in the container:

| Item | Value |
|---|---|
| `omarchy-server` | 442 KB compressed / **1.25 MiB** installed (upstream `omarchy`: 120 MB / 126 MB) |
| `omarchy-server-settings` | 52 KB / **124 KiB** (upstream: 724 KB / 1.3 MB) |
| `omarchy-server-keyring` | 3.7 KB / 295 B |
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

## 5. What changes with a real key and a GitHub fork

| Today (local) | Later |
|---|---|
| lab key in `pkgs/keys/` (no passphrase, on disk) | key generated offline; only the public part enters `omarchy-server-keyring`; the private key lives in GitHub Actions secrets or on encrypted disk |
| `source=(git+file:///src/omarchy#commit=468b511…)` | `source=(git+https://github.com/<fork>/omarchy.git#commit=…)`, branch `server`; the bind mount and `OMARCHY_GIT_URL` go away |
| overlay packed as a tarball by `build.sh` | same, or the overlay moves into the fork itself |
| `Server = file:///repo` | `Server = https://github.com/edimarlnx/omarchy-server-pkgs/releases/download/repo` |
| local `build.sh` in Docker | the same script called by a GitHub Actions workflow |
| trust anchor via `pacman-key --add` in the test | `/etc/pacman.d/omarchy-server.conf` included in the ISO's `pacman.conf`, with the keyring coming from the offline mirror |

Pending: **nothing** today delivers `/etc/pacman.d/omarchy-server.conf` or
includes the repo in `pacman.conf`. The packaged
`default/pacman/pacman-{stable,rc,edge}.conf` are upstream's, without an
`[omarchy-server]` section. That comes with the signed remote repository.
