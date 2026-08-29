# ISO with the `server` profile

`iso/build.sh` produces an Omarchy ISO that installs the server profile
(runtime `omarchy-server`, settings `omarchy-server-settings`, no compositor,
no audio, no display manager) from **the local sources of this repository**,
without touching the clones under `upstream/`.

Install results and the acceptance checks of the headless install are in
`pocs/server-install/reference/README.md`.

---

## 1. How the build works

```bash
./iso/build.sh                     # server profile (default in this repo)
./iso/build.sh --debug             # OMARCHY_INSTALL_DEBUG=1 inside the ISO
./iso/build.sh --fresh             # discard the scratch copy first
./iso/build.sh --profile desktop   # stock ISO, for diffing
```

The clones under `upstream/` are **read-only and gitignored**; nothing is edited
there. The script:

1. copies `upstream/omarchy-iso` to `iso/scratch/omarchy-iso/` (gitignored) and
   runs `git reset --hard` on every build, so every build starts from pristine
   upstream and a patch that stops applying fails loudly instead of piling up;
2. initializes the `archiso` submodule;
3. overlays `iso/overlay/` (whole files; empty today) and applies
   `iso/patches/*.patch` (changes to upstream files);
4. assembles `iso/scratch/pkgs/` = `pkgs/pkgbuilds/` + `profile/<profile>/` +
   the overlay tarballs that `pkgs/build.sh` also generates. That directory is
   the second argument of `--local-source`;
5. runs `bin/omarchy-iso-make` **from the copy** with
   `--profile server --local-source upstream/omarchy iso/scratch/pkgs`.

The ISO lands in `iso/release/` (gitignored) with its `.sha256` next to it.

### What `--local-source` does (upstream)

`bin/omarchy-iso-make` bind-mounts the two checkouts read-only into the
builder container (`/omarchy-source` and `/omarchy-pkgs`) and forces
`OMARCHY_ISO_REF=local`, `OMARCHY_MIRROR=edge`. `builder/build-iso.sh` then
calls `builder/build-omarchy-packages.sh`, which copies
`/omarchy-pkgs/pkgbuilds/<pkg>` to a work dir, runs `makepkg` as user
`builder` with `OMARCHY_SRC=/omarchy-source` exported, and drops the
`.pkg.tar.zst` straight into the ISO's **offline mirror**. Packages built this
way are excluded from the online `pacman -Syw` and re-added to the prune
keep-set (`builder/prune-offline-mirror.sh`).

That is why the PKGBUILDs honor `OMARCHY_SRC`:

```bash
: "${OMARCHY_GIT_URL:=file://${OMARCHY_SRC:-/src/omarchy}}"
```

`/src/omarchy` remains the path used by `pkgs/build.sh`; inside the ISO
container the same checkout is at `/omarchy-source`. No other PKGBUILD change
was needed.

---

## 2. ISO patches (`iso/patches/`)

| Patch | File | What it does |
|---|---|---|
| `0001-iso-make-profile-flag.patch` | `bin/omarchy-iso-make` | Adds `--profile <name>` (default `desktop`), passes `OMARCHY_PROFILE` into the container, suffixes the ISO name with the profile and **splits the offline mirror cache per profile** (otherwise each build would prune the other's cache and re-download everything). |
| `0002-build-iso-profile-package-lists.patch` | `builder/build-iso.sh` | The core of the profile. A named profile lives in `/omarchy-pkgs/profile/<name>/` and provides `archinstall.packages` and `omarchy-<name>.packages`; the `server` profile points the targets at `omarchy-server`/`omarchy-server-settings`, leaves the nvim target **empty** and declares `omarchy-server-keyring` as an extra locally built package. Writes `/usr/share/omarchy-iso/profile` into the airootfs. Generalizes the three places that named the targets literally (`all_packages`, the local build filter, the prune keep-set) into a `local_package_names` list that drops empty names. Widens the package-count sanity range (600-2000 → 150-2000 outside desktop). **Bundles the profile's addons**: upstream's "other" list is what lands in the offline mirror without being installed, which is exactly what an addon is, so `profile/<name>/addons/*.packages` are concatenated into it. |
| `0003-build-packages-optional-and-extra-targets.patch` | `builder/build-omarchy-packages.sh` | Makes the nvim target optional and accepts `OMARCHY_EXTRA_PACKAGES`; replaces `${VAR:=default}` with `${VAR=default}` (a name **deliberately exported empty** was being resurrected by `:=`, the first build failure); adds `git config --system --add safe.directory` for both mounts, because the PKGBUILDs consume the checkout through a `git+file://` source and git refuses repositories owned by another user. |
| `0004-orchestrator-server-profile.patch` | `orchestrator/phases_impl.py` | Reads the profile (`OMARCHY_PROFILE` → `/root/profile` from cidata → `/usr/share/omarchy-iso/profile`). With `server`: skips `configure_hibernation` (no swapfile, no `resume=`) and `configure_login` (no display manager); drops `base-devel` and `git` from the early bootstrap packages, which is where a compiler would otherwise enter the install regardless of the package lists; writes `/etc/omarchy-profile` into the target **before** `run_system_finalizer`; exports `OMARCHY_PROFILE` into the `arch-chroot` env; does not install nvim/luarocks when the nvim target is empty; prefers `install/<profile>/omarchy-provision-owner.service` over the stock unit; runs `ufw limit 22/tcp` instead of `ufw allow ssh` in `configure_ssh_access`; and adds the `install_addons` phase. |
| `0005-cidata-profile-and-addons.patch` | `usr/local/bin/omarchy-cidata-load` | Accepts `profile` and `addons` files on the `cidata` drive, next to the other optional inputs, so one ISO can install another profile without a rebuild and an autoinstall can name the optional package sets to apply. |
| `0006-orchestrator-addons-phase.patch` | `orchestrator/main.py` | Registers `install_addons` in the phase list, right after `Configuring system`. |

### `ufw limit` instead of `ufw allow`

`configure_ssh_access` used to run `ufw allow ssh` unconditionally. UFW keeps
one rule per (port, protocol, direction), so that call would have **replaced**
the rate-limited rule `install/server/firewall-server.sh` writes a few phases
earlier with a permissive one. The patch makes the phase agree with the profile
instead of fighting it, and relaxes the assertion that follows: a `limit` rule
records a jump to `ufw-user-limit-accept` rather than a direct
`--dport 22 -j ACCEPT`, so the check is that port 22 was recorded at all.

### The `install_addons` phase

Reads `/root/addons` (one name per line, validated against
`[a-z0-9][a-z0-9-]*` because each becomes an argument to a command run as root
in the target), then for each name runs `omarchy-server-addon <name>` in the
chroot with `OMARCHY_ADDON_PACMAN_CONF` pointing at a copy of the live
environment's offline `pacman.conf`. That copy is removed when the phase ends,
so the installed system is left pointing at the online mirrors, exactly as
`post-install-pacman-server.sh` left it.

It runs right after `run_system_finalizer`, and therefore **before**
`finalize_limine_boot` (an addon whose packages trigger an initramfs rebuild is
still followed by the final UKI build) and before `create_factory_snapshot` (so
the addons are part of what a factory reset restores). The package cache is
pruned again afterwards, the same way the system setup prunes it, so the
factory snapshot is still taken on a clean disk.

No patch touches `SigLevel`: `[omarchy]` stays `Optional TrustAll` as upstream
and the offline mirror stays `Never` (a signed repository of our own is a
separate step).

## 3. Runtime patches (`profile/server/overlay/patches/`)

Applied in `prepare()` of `omarchy-server`:

| Patch | What it does |
|---|---|
| `0001-apply-system-server-profile.patch` | `omarchy-apply-system` runs `install/server/all.sh` instead of `config/all.sh` + `omarchy-apply-hardware` + `login/all.sh` + `post-install/all.sh`. |
| `0002-server-package-name.patch` | `omarchy-version`, `omarchy-update-available` and `omarchy-channel-current` recognize `omarchy-server`. |
| `0003-provision-user-server-profile.patch` | `omarchy-provision-user` server path: no `xdg-user-dirs-update`, no GTK bookmarks, no `omarchy-refresh-applications`/`xdg-settings`/`xdg-mime`, and `install/server/user-all.sh` (only `git.sh`) instead of `install/user/all.sh`. Keeps the agent-skill symlinks and the `--first-install` migration marking. Without it the "Finalizing user" phase dies on the first missing command. |
| `0004-provision-owner-server-profile.patch` | Neutralizes the first boot of a `defer-provisioning` install: no framebuffer greeter (which **blocks** on `read </dev/tty`), no VT palette, no SDDM `configure_login`/autologin, and no interactive retry that would `exec /bin/bash` on a tty1 nobody sees. |

---

## 4. First-boot audit (`omarchy-provision-owner`)

All 1129 lines were read. This path only runs on a **`defer-provisioning`**
install (marker `/var/lib/omarchy/provisioning/pending`), which the headless
install does **not** use: the `cidata` drive carries `user_credentials.json`.
Findings and treatment anyway:

| Finding | Lines | Treatment |
|---|---|---|
| `greeter_screen` blocks on `read -r -t 0.2 _ </dev/tty` inside `while true` | 434-577 (553) | skipped in the server profile (patch 0004) |
| VT palette / `setfont` / `stty size </dev/tty` / `ttfx` animation | 68-244, 513-524 | skipped; `ttfx` is not even installed |
| `configure_login` writes `/var/lib/sddm/state.conf` and `/etc/sddm.conf.d/autologin.conf`, `chown sddm:sddm` | 758-773 | `return 0` in the server profile |
| `install_autologin_once_cleanup` creates a unit in `graphical.target.wants/` | 783-801 | no longer reachable (only called by `configure_login`) |
| retry with `gum confirm` and `exec /bin/bash` on tty1 | 1113-1126 | replaced by a single attempt whose status goes to the journal |
| unit: `Before=display-manager.service`, `Conflicts=getty@tty1.service`, `TTYPath=/dev/tty1`, `ExecStartPre=-plymouth quit` | unit 18-31 | server variant in `install/server/omarchy-provision-owner.service` (no display manager, no Conflicts, no TTY*, output to the journal); the orchestrator prefers `install/<profile>/` |
| `setup-form.sh` is 100% `gum` (user/hostname/timezone prompts) | all | **unresolved**: the server profile has no non-interactive source for those answers. Deferred provisioning on a server stays a follow-up. |
| `omarchy-system-factory-reset-finish.service` | — | GUI-agnostic, reused unchanged |
| Parts that still apply and were left intact | 675-756, 805-822, 852-987 | user groups (excludes `docker`), `create_user`, `install_authorized_keys`, hostname, timezone, LUKS re-key, OEM state cleanup |

---

## 5. Cmdline, `validate_boot` and the limine timeout

The server cmdline comes from the `omarchy-defaults.conf` shipped by
`omarchy-server-settings`: no `quiet splash loglevel=0`, no
`initramfs_async=0`, with `console=ttyS0,115200 console=tty0`, no `resume=`.

- `_write_limine_defaults` only requires the cmdline computed by archinstall to
  contain `root=`; the `KERNEL_CMDLINE[default]+=` from `limine-entry-tool.d`
  is appended later, when the UKI is generated. Nothing to change.
- `validate_boot` checks: `limine.conf` exists and contains the string
  `Omarchy` (our `interface_branding: Omarchy Server Bootloader` satisfies
  it), `/etc/kernel/cmdline` exists, the `limine_x64.efi` binary and the
  `omarchy_linux.efi` UKI exist and are non-empty, and there is a `Limine`
  entry in `efibootmgr`. There is **no** assertion about `resume=`, `quiet` or
  swap, so the absence of a swapfile passes cleanly.
- `timeout: 0` in the server `limine.conf`: the menu is still reachable by
  holding a key.

---

## 6. Build results

| Item | Value |
|---|---|
| ISO size | **2.9 GiB** (3,010,494,464 bytes), against 6.2 GiB for the desktop ISO |
| Cold build (empty package cache) | ~13 min, dominated by downloading the offline mirror |
| Warm build (cached mirror) | **3m20s** |
| Offline mirror | **1.5 GiB**, 1156 package files |
| Packages the target install resolves to | ~220 (shipped in the ISO as the install dashboard's denominator) |
| Packages built inside the ISO builder | `omarchy-server`, `omarchy-server-settings`, `omarchy-server-keyring` |

The ISO grew by ~70 MiB while the *install* shrank by 100 packages and 940 MiB.
That is the addon trade: the base install no longer carries docker, a compiler,
tailscale or the CLI toolbelt, but the ISO still carries all of them so
`omarchy-server-addon` works on a machine with no network. What left the ISO
(the pipewire stack, and packages nothing in the profile references any more)
roughly cancels out against `omarchy-nvim` and its Lua closure, which the
`editor` addon brings in. Trimming the mirror further means dropping addons from
the ISO, not from the profile.

Two bugs were found by building and installing, not by reading:

1. `${OMARCHY_NVIM_PACKAGE:=omarchy-nvim}` in `build-omarchy-packages.sh`
   resurrects the default for a name exported **empty on purpose**, so the
   builder tried to build a `pkgbuilds/omarchy-nvim` that does not exist.
2. `_install_early_packages` pacstrapped `EARLY_LUAROCKS_PACKAGES`
   unconditionally. Those packages only reach the offline mirror through
   `omarchy-nvim`'s dependency closure, so with no nvim target the phase died
   with `error: target not found: lua51`.

### Known cosmetic issues

- The live ISO inherits `cloud-init` from the archiso releng profile. It runs
  in the live system, finds the `cidata` drive (NoCloud is the same label
  Omarchy's autoinstall uses) and prints its ssh host-key output over the
  install dashboard on tty1. The install itself is unaffected — its state is in
  `/run/omarchy-install/state.json` and its log in
  `/var/log/omarchy-install.log` — but the dashboard becomes unreadable.
- The dashboard's rotating tips are desktop tips ("Super + K shows all the key
  bindings") during a server install.

---

## 7. Status and what is left

Done and verified end to end: `iso/build.sh` builds a server ISO from this
repository's sources, and that ISO installs a headless machine from a `cidata`
drive that passes the whole acceptance list (`pocs/server-install/README.md`).

Left over, in rough order of how much they hurt:

1. **`omarchy-update` is not non-interactive.** Its steps shell out to `sudo`
   and prompt on the terminal; unattended, each one stalls until sudo times
   out and is then skipped (no cache prune, no snapshot). It needs either a
   mode that requires root outright or a NOPASSWD rule for those commands.
   Details and the interaction with `pam_faillock` in
   `pocs/server-install/README.md`.
2. **Deferred provisioning on a server has no non-interactive path.**
   `omarchy-provision-owner` is safe to run headless now, but the setup form it
   drives is `gum`-only, so a `defer-provisioning` install still has no source
   for the answers. A cidata-style input for the first-boot form is the
   missing piece.
3. **`cloud-init` in the live ISO** prints over the install dashboard on tty1
   (see §6). Dropping it from the live package set, or ordering it after the
   dashboard, would make a failed install readable on the console instead of
   only through `/run/omarchy-install/state.json`.
4. **The install dashboard's tips are desktop tips** during a server install.
5. **The desktop profile is structurally untouched but was not rebuilt.** With
   `--profile desktop` every added branch takes its `desktop` arm and the
   package lists resolve exactly as upstream, but a desktop ISO build has not
   been run against the patched tree.
6. **The `[omarchy]` mirror is still `Optional TrustAll`** and the offline
   mirror `Never`. A signed repository of our own, with
   `/etc/pacman.d/omarchy-server.conf` shipped by the profile, is the next
   packaging step; `omarchy-server-keyring` is already built and installed by
   the ISO in preparation.
