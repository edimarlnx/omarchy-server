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
./iso/build.sh --profile desktop   # stock ISO, the desktop-parity baseline
```

`--profile desktop` skips `--local-source`: that profile's Omarchy packages are
`omarchy`/`omarchy-settings`/`omarchy-nvim`, whose PKGBUILDs live in a private
upstream repository, so a desktop build takes them off the published `[omarchy]`
mirror exactly as a stock `omarchy-iso-make` does. What it still exercises is
every patch in `iso/patches/`, which is the point of building it (§8).

The clones under `upstream/` are **read-only and gitignored**; nothing is edited
there. The script:

1. copies `upstream/omarchy-iso` to `iso/scratch/omarchy-iso/` (gitignored) and
   runs `git reset --hard` on every build, so every build starts from pristine
   upstream and a patch that stops applying fails loudly instead of piling up;
2. initializes the `archiso` submodule;
3. overlays `iso/overlay/` (whole files; empty today) and applies
   `iso/patches/*.patch` (changes to upstream files);
4. assembles `iso/scratch/pkgs/` = `pkgs/pkgbuilds/` + `profile/<profile>/` +
   the overlay tarballs that `pkgs/build.sh` also generates + `src/tui-tools`,
   a clone of the checkout the `fwall` addon package builds from. That
   directory is the second argument of `--local-source`;
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

Addon packages built from their own upstream follow the same shape. `fwall`
reads `FWALL_SRC`, and its checkout travels inside the pkgs directory
(`<pkgs-checkout>/src/tui-tools`) rather than on a mount of its own, because
`--local-source` takes exactly two paths and adding a third would mean patching
`bin/omarchy-iso-make`. It is a clone, not a copy: the working tree's
uncommitted state must not decide what a package contains, and the PKGBUILD
consumes a pinned commit anyway.

---

## 2. ISO patches (`iso/patches/`)

| Patch | File | What it does |
|---|---|---|
| `0001-iso-make-profile-flag.patch` | `bin/omarchy-iso-make` | Adds `--profile <name>` (default `desktop`), passes `OMARCHY_PROFILE` into the container, suffixes the ISO name with the profile and **splits the offline mirror cache per profile** (otherwise each build would prune the other's cache and re-download everything). |
| `0002-build-iso-profile-package-lists.patch` | `builder/build-iso.sh` | The core of the profile. A named profile lives in `/omarchy-pkgs/profile/<name>/` and provides `archinstall.packages` and `omarchy-<name>.packages`; the `server` profile points the targets at `omarchy-server`/`omarchy-server-settings`, leaves the nvim target **empty** and declares `omarchy-server-keyring` as an extra locally built package. Writes `/usr/share/omarchy-iso/profile` into the airootfs. Generalizes the three places that named the targets literally (`all_packages`, the local build filter, the prune keep-set) into a `local_package_names` list that drops empty names. Widens the package-count sanity range (600-2000 → 150-2000 outside desktop). **Bundles the profile's addons**: upstream's "other" list is what lands in the offline mirror without being installed, which is exactly what an addon is, so `profile/<name>/addons/*.packages` are concatenated into it. |
| `0003-build-packages-optional-and-extra-targets.patch` | `builder/build-omarchy-packages.sh` | Makes the nvim target optional and accepts `OMARCHY_EXTRA_PACKAGES`; replaces `${VAR:=default}` with `${VAR=default}` (a name **deliberately exported empty** was being resurrected by `:=`, the first build failure); adds `git config --system --add safe.directory` for both mounts, because the PKGBUILDs consume the checkout through a `git+file://` source and git refuses repositories owned by another user. |
| `0004-orchestrator-server-profile.patch` | `orchestrator/phases_impl.py` | Reads the profile (`OMARCHY_PROFILE` → `/root/profile` from cidata → `/usr/share/omarchy-iso/profile`). With `server`: skips `configure_hibernation` (no swapfile, no `resume=`) and `configure_login` (no display manager); drops `base-devel` and `git` from the early bootstrap packages, which is where a compiler would otherwise enter the install regardless of the package lists; writes `/etc/omarchy-profile` into the target **before** `run_system_finalizer` (named profiles only — a desktop install is left without the marker so its `/etc` is unchanged); exports `OMARCHY_PROFILE` and `OMARCHY_UNATTENDED_UPDATES` into the `arch-chroot` env; does not install nvim/luarocks when the nvim target is empty; prefers `install/<profile>/omarchy-provision-owner.service` over the stock unit; runs `ufw limit 22/tcp` instead of `ufw allow ssh` in `configure_ssh_access`; and adds the `install_addons` phase. |
| `0005-cidata-profile-and-addons.patch` | `usr/local/bin/omarchy-cidata-load` | Accepts `profile`, `addons` and `unattended-updates` files on the `cidata` drive, next to the other optional inputs, so one ISO can install another profile without a rebuild, an autoinstall can name the optional package sets to apply, and it can ask for the daily update timer. |
| `0006-orchestrator-addons-phase.patch` | `orchestrator/main.py` | Registers `install_addons` in the phase list, right after `Configuring system`. |
| `0007-build-packages-makedepends-and-extra-sources.patch` | `builder/build-omarchy-packages.sh` | `makepkg --nodeps` installs nothing at all, including makedepends a package genuinely needs to compile, so each PKGBUILD's `makedepends` are read out of `makepkg --printsrcinfo` and installed — and only those. Also picks up addon packages built from their own upstream: a checkout at `/omarchy-pkgs/src/<name>` gets a `safe.directory` entry and its `<NAME>_SRC` variable (`FWALL_SRC` for `tui-tools`), the same contract `OMARCHY_SRC` gives the Omarchy PKGBUILDs. |
| `0008-build-iso-profile-branding-and-addon-packages.patch` | `builder/build-iso.sh` | Adds `fwall` to the server profile's locally built packages, so it lands in the offline mirror and is never looked up on the network mirror. **Brands the live medium**: on a named profile the grub, syslinux and `profiledef.sh` labels become `Omarchy <Profile>` — a rename of the menu labels only, leaving the entry ids, the kernel command lines and the installer itself alone. |
| `0009-orchestrator-default-hostname.patch` | `orchestrator/context.py` | archinstall defaults `hostname` to `archlinux` and only overrides it when the JSON carries a non-empty value, so an autoinstall drive that says nothing about the hostname produces a machine called `archlinux`. Defaults it to `omarchy` instead — the same default the interactive configurator offers — while leaving an explicit hostname, including `archlinux`, untouched. |
| `0010-orchestrator-secure-boot.patch` | `omarchy-cidata-load`, `orchestrator/{main,phases_impl}.py` | Secure Boot with the machine's own keys. Accepts a `secureboot` marker file on the `cidata` drive; exports `OMARCHY_SECURE_BOOT` into the chroot env; **prepends the `secureboot` addon** to the requested list so the existing `install_addons` phase does the setup (and so it lands before `finalize_limine_boot`, which the cmdline drop-in requires); and adds one phase, `enroll_secure_boot`, after `validate_boot`. See §2.2 and `docs/secure-boot.md`. |
| `0011-build-iso-prebuilt-packages.patch` | `builder/build-iso.sh` | Packages that can be neither built here nor downloaded. `<pkgs-checkout>/prebuilt/*.pkg.tar.zst` is copied into the offline mirror, its names are excluded from the online download and added to the prune keep-set, and the `depend =` lines of each package's `.PKGINFO` are added to the download list so the dependency closure comes along. Kept in an array of its own, **not** in `local_package_names`: that list is also what the builder resolves to count the packages the target ends up with, and these are addon packages that replace packages the base installs. This is how the ~19-package SELinux set reaches a machine with no network. See `docs/mac.md` §6. |
| `0012-orchestrator-mac-addons.patch` | `omarchy-cidata-load`, `orchestrator/phases_impl.py` | Mandatory access control. Accepts a `selinux` or an `apparmor` marker file on the `cidata` drive and turns it into the addon of that name, inserted after `secureboot` and before whatever `--addons` asked for — the relabel is cheaper before the rest of the install writes more files, and like Secure Boot the addon writes a cmdline drop-in that `finalize_limine_boot` has to see. Both markers at once is refused at the drive: the kernel initialises one major LSM. See `docs/mac.md`. |

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

### 2.2 Secure Boot, and why it needed only one new phase

A `secureboot` marker on the autoinstall drive asks for an install whose boot
chain is signed by keys the machine generates for itself. Almost all of the
work is already-existing plumbing:

- **the setup is an addon.** `_requested_addons()` prepends `secureboot` when
  the marker is present, so `install_addons` installs `sbctl` out of the
  offline mirror and sources `install/server/secureboot-server.sh` — no new
  phase, no second copy of the offline-`pacman.conf` dance.
- **the ordering was already right.** `install_addons` runs before
  `finalize_limine_boot`, which is exactly what this needs: the cmdline
  drop-in that adds `lockdown=integrity module.sig_enforce=1` has to exist
  before the UKI that embeds it is built.
- **the signing is not ours.** `limine-entry-tool` signs the Limine EFI binary
  and `mkinitcpio` signs the UKI, both gated on `sbctl setup --print-state`.
  Creating the keys is the whole switch; the profile ships no signing hook.

What genuinely could not be folded into an existing phase is **enrollment**.
Handing the firmware a platform key is the moment it starts refusing what it
cannot verify, so it has to come after the chain has been written, signed and
validated — hence one phase, `enroll_secure_boot`, after `validate_boot` and
before `create_factory_snapshot` (it writes EFI variables, not files, so it has
nothing to contribute to the snapshot). It runs
`omarchy-server-secureboot enroll`, which re-verifies with `sbctl verify` and
refuses to enroll into a chain that is not fully signed.

Firmware that is not in Setup Mode is not an install failure: the command
prints the firmware-screen steps and exits 0. The **live ISO is unsigned**
(upstream builds it with an unsigned GRUB), so an install cannot happen on a
machine that is already enforcing; `docs/secure-boot.md` §6 has the lab flow
that gets around this by starting from an OVMF variable store with no PK.

## 3. Runtime patches (`profile/server/overlay/patches/`)

Applied in `prepare()` of `omarchy-server`:

| Patch | What it does |
|---|---|
| `0001-apply-system-server-profile.patch` | `omarchy-apply-system` runs `install/server/all.sh` instead of `config/all.sh` + `omarchy-apply-hardware` + `login/all.sh` + `post-install/all.sh`. |
| `0002-server-package-name.patch` | `omarchy-version`, `omarchy-update-available` and `omarchy-channel-current` recognize `omarchy-server`. |
| `0003-provision-user-server-profile.patch` | `omarchy-provision-user` server path: no `xdg-user-dirs-update`, no GTK bookmarks, no `omarchy-refresh-applications`/`xdg-settings`/`xdg-mime`, and `install/server/user-all.sh` (only `git.sh`) instead of `install/user/all.sh`. Keeps the agent-skill symlinks and the `--first-install` migration marking. Without it the "Finalizing user" phase dies on the first missing command. |
| `0004-provision-owner-server-profile.patch` | Neutralizes the first boot of a `defer-provisioning` install: no framebuffer greeter (which **blocks** on `read </dev/tty`), no VT palette, no SDDM `configure_login`/autologin, and no interactive retry that would `exec /bin/bash` on a tty1 nobody sees. |
| `0005-update-noninteractive.patch` | Extends the promise `-y` already makes to the two cases it did not cover and the two steps that never honored it. **Not server-specific**: with a terminal and no `-y` the desktop path is unchanged. §3.1 below. |
| `0006-update-free-space-server.patch` | `omarchy-update-requires-free-space` asks for 2 GiB instead of 10 on the `server` profile: 10 GiB is sized for an 8 GiB desktop install with a browser and a toolchain, and it refuses an update on a 1.2 GiB server that has room to spare. Every other profile keeps the 10. |

---

## 3.1 The non-interactive update

`omarchy update` asks three questions — start?, remove orphans?, reboot? — and
upstream already answers them for an unattended run: `-y` exports
`OMARCHY_UPDATE_UNATTENDED=1` so that "steps that would need an answer report
and move on". Two things kept that from working headless.

**The pty makes every `-t` test lie.** `omarchy-update` re-execs itself under
`script -qefc … /tmp/omarchy-update.log` to capture the transcript, and `script`
allocates a pseudo-terminal. Everything below that line therefore sees a
terminal, which is why `omarchy-update-orphan-pkgs`'s `[[ ! -t 0 || ! -t 1 ]]`
guard never fired in an unattended run. Patch `0005` decides the question
**before** the re-exec, from `-y`, from `OMARCHY_NONINTERACTIVE=1`, or from
stdin not being a terminal, and exports the answer.

**`omarchy-update-restart` prompted unconditionally.** After a kernel upgrade
its `gum confirm` sat there with the whole update already done. It now reports
what it would have asked and carries on exactly as a declined prompt does,
leaving the reboot-required state for the next login to act on. A reboot taken
without an answer is a reboot taken out from under whatever the machine was
doing.

**Running as root is the other half.** Every privileged step of the update
shells out to `sudo`, and `sudo` never asks root for a password. Under a user
account each of those steps prompts, waits out sudo's timeout, reports its own
failure and moves on — the update "finishes" having pruned nothing and
snapshotted nothing — and this profile's `pam_faillock` (`deny=10`,
`unlock_time=120`, `preauth silent`) then locks the account for two minutes
while looking exactly like a wrong password.

`omarchy-server-update` is the documented entry point that does both: it
re-execs itself under `sudo` and runs `omarchy-update -y` with
`OMARCHY_NONINTERACTIVE=1`. It also carries the timer toggle:

```bash
omarchy-server-update            # update now, non-interactively
omarchy-server-update enable     # turn on the daily timer
omarchy-server-update disable
omarchy-server-update status
```

`omarchy-server-update.timer` is `OnCalendar=daily`,
`RandomizedDelaySec=4h`, `Persistent=true`, and **ships disabled**. It is turned
on by the command above, or at install time by an autoinstall drive carrying an
`unattended-updates` file (`mkcidata.sh --unattended-updates`), which the
orchestrator turns into `OMARCHY_UNATTENDED_UPDATES=1` for
`install/server/unattended-updates-server.sh`. Its whole transcript goes to the
journal: `journalctl -u omarchy-server-update`.

Three things a root-run update needs that neither `sudo` nor systemd supplies
on its own, and where each comes from:

| Need | Why | Where it comes from |
|---|---|---|
| `$OMARCHY_PATH` | Omarchy commands read it and, per `AGENTS.md`, never default it themselves. On a server it comes from `/etc/profile.d` (login shells) and the `pam_env` line `install/server/ssh-command-path-server.sh` writes (ssh commands and sudo). A systemd unit goes through neither. | `Environment=` in `omarchy-server-update.service` |
| `$HOME` | `omarchy-migrate` keeps its per-user markers under `~/.local/state/omarchy/migrations` and `omarchy-update-restart` reads the restart flags there. systemd sets no `$HOME` for a root system service. | `Environment=HOME=/root` in the unit, matching what `sudo` gives |
| root's migration markers | The packages pre-mark every migration in `/etc/skel`, so an account created after the install does not replay ~90 desktop migrations. root predates `/etc/skel`. | `install/server/root-migration-state-server.sh` |

`omarchy-update-status` calls `omarchy-shell`, which returns 0 when
`$OMARCHY_PATH/shell/shell.qml` is missing — it is, because the server runtime
ships no `shell/` — so the graphical status refresh silently no-ops. The last
step still prints "Restarting shell / All plugins have been reloaded" followed
by `omarchy-restart-shell`'s own "config not found", which is cosmetic noise on
a headless machine and the one piece of the update path left untouched.

## 3.2 What happens after the update: restart, defer, reboot

§3.1 got the update to *finish* unattended. It did not get the machine to
**run** what the update installed. Upstream's last step asks "Linux kernel has
been updated. Reboot?", and an unattended run declines, which on a desktop is
right: the next login reboots anyway. On a server nobody logs in, so the machine
keeps the sshd, the networkd and the libssl it replaced on disk — for as long as
it stays up.

`omarchy-server-update` therefore no longer `exec`s the update. It records the
size of `/var/log/pacman.log` first, runs `omarchy-update -y`, and hands that
byte offset to **`omarchy-server-update-restart`**, which reads exactly the
transaction that just happened.

**Two sources, and the machine outranks the log.**

| Source | Answers |
|---|---|
| `/var/log/pacman.log` from the offset | which packages moved, and `upgraded` vs `reinstalled` — i.e. whether a *version* changed or only files did |
| `/proc/<pid>/maps` and `/proc/<pid>/exe` | which processes still map a file that has been unlinked (the `(deleted)` marker) — "running replaced code", with no guess about which package owns which library |

The second is what decides restarts, so a library nobody had mapped costs
nothing and a service that maps something the log did not obviously name is
still caught. Only `/usr` and `/opt` count: `/tmp`, `/run`, `/var`, `/dev` and
`memfd` deletions are programs managing their own scratch files.

**The classes, and the reason each one is where it is.**

| Class | Packages | Verdict |
|---|---|---|
| kernel | `linux`, `linux-lts`, `linux-zen`, `linux-hardened`, `linux-rt`, `linux-rt-lts` | reboot **only if** the running `uname -r` is no longer an installed kernel |
| firmware / microcode | `linux-firmware*`, `*-ucode` | reboot on a version change: the blob the hardware was handed at boot is gone |
| initramfs | `mkinitcpio*`, `booster`, `dracut` | reboot: the image was rebuilt and the running kernel booted from the old one |
| bootloader | `limine*` | reboot |
| glibc | `glibc` | reboot |
| systemd | `systemd`, `systemd-libs`, `systemd-sysvcompat`, `systemd-ukify` | **`daemon-reexec`**, not a reboot |
| bus | `dbus`, `dbus-broker` | `daemon-reload`; the bus process itself is deferred |
| everything else | — | whatever the `(deleted)` scan says |

Three of those are decisions rather than lookups.

**The kernel test is upstream's, not the package log's.** The question is not
whether a kernel package was in the transaction but whether the kernel this
machine is *running* is still one of the kernels installed on it. A
same-version reinstall — which is what `pacman -S linux` does when nothing
moved, and what a SELinux relabel or a re-signed UKI provokes — leaves the
answer yes, and costs no reboot at all. This is the rule that makes an
initramfs rebuild a non-event.

**systemd is re-executed, not rebooted.** `systemctl daemon-reexec` replaces
the running PID 1 with the new binary and keeps every unit's state; the proof is
`/proc/1/exe` losing its `(deleted)` marker. A reexec that does *not* clear it
is the one case where systemd earns a reboot, and it is checked rather than
assumed.

**`limine*` is listed as a reboot even though a bootloader takes effect on the
next boot regardless.** The reason is not technical necessity: it is that the
next boot is the first proof the new boot chain works, and a server should take
that boot in a window somebody chose rather than discover it during an
unplanned power cycle months later.

**The deny-list** — replaced, reported, not restarted:

| Unit | Why not |
|---|---|
| `dbus`, `dbus-broker` | every client holds a connection and none reconnect |
| `systemd-logind` | a restart invalidates every session, which here is every ssh login |
| `user@*`, `user-runtime-dir@*` | takes the user's session with it |
| `getty@*`, `serial-getty@*`, `console-getty` | the console login, and on this profile the serial console is the recovery path |
| `omarchy-server-update.service` | the unit the update is running inside |
| `emergency`, `rescue` | the paths that exist for when the rest failed |

`sshd` is deliberately **not** on it. Arch's unit sets `KillMode=process`, so
the per-connection children live outside the unit's kill scope and established
sessions survive the listener being swapped. That is a property of the shipped
unit rather than a law, so the command reads
`systemctl show -p KillMode --value` and defers instead when a drop-in changed
it. `sshd` is also restarted last, so a surprise there cannot take the rest of
the pass with it.

**The output is three lines, always all three**, because a report that only
speaks when something happened cannot be read as "nothing happened" — and this
is what the journal keeps for a run nobody watched:

```
restarted: sshd systemd-networkd systemd-resolved
deferred: dbus (the bus keeps its old process until a reboot)
reboot required: no
```

The upstream `reboot-required` marker (`$HOME/.local/state/omarchy/`) is set
**only** on the third line saying yes.

### `--kexec`: a required reboot without the firmware

The `kexec` addon is one package, `kexec-tools`, and it is an addon on the
premise that runs the rest of this profile: a machine that reboots twice a year
gains nothing from it. `omarchy-server-update --kexec` (or
`omarchy-server-update kexec on`, which writes `/etc/omarchy-server-update.conf`
for the timer to read) uses it only when it is installed; with the addon absent
a required reboot is left as the marker, exactly as before.

`omarchy-server-kexec load` is shaped entirely by this profile's boot image
being a **signed UKI** — a PE binary carrying the kernel, the initramfs and the
command line in its own sections:

* `kexec_load(2)`, the classic syscall, takes a bzImage and an initrd as
  separate files and verifies nothing. The `lockdown=integrity` baked into this
  profile's UKI makes the kernel refuse it outright, which is the point of
  lockdown.
* `kexec_file_load(2)` takes one file descriptor and verifies the image's
  signature in the kernel. `kexec --kexec-file-syscall` is how kexec-tools
  reaches it, and under lockdown it is the only route.

The keyring question is **not** the one module signing lost. Module signature
verification consults `.builtin` and `.machine`, so a certificate enrolled in
the firmware `db` — what this profile does — lands in `.platform` and is never
consulted (`docs/secure-boot.md` §8). kexec's PE verification path accepts
`.platform`. Measured in `reports/2026-08-29-update-without-reboot.md`.

Taking the reboot is `systemctl kexec`: systemd's ordinary shutdown
transaction, with a jump at the end instead of a firmware reset.

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
- `timeout: 2` in the server `limine.conf` (it was `0` until the branding
  work): at `0` the menu is only reachable by holding a key during the loader's
  startup, which is not something anyone does on a machine they are not
  standing in front of. The cost is exactly two seconds of boot — the loader
  goes from 0.67 s to 2.6-2.8 s, the whole boot from 4.8 s to 6.7-7.0 s.
  `interface_branding` is now `Omarchy Server`, which still satisfies
  `validate_boot`'s search for the string `Omarchy`.

---

## 6. Build results

| Item | Value |
|---|---|
| ISO size | **2.9 GiB** (3,012,608,000 bytes), against 6.2 GiB for the desktop ISO |
| Cold build (empty package cache) | ~13 min, dominated by downloading the offline mirror |
| Warm build (cached mirror) | **3m20s** |
| Offline mirror | **1.5 GiB**, 1156 package files |
| Packages the target install resolves to | ~220 (shipped in the ISO as the install dashboard's denominator) |
| Packages built inside the ISO builder | `omarchy-server`, `omarchy-server-settings`, `omarchy-server-keyring`, `fwall` |
| Warm build after adding `fwall` | 3m36s-4m01s (the Go toolchain is installed in the throwaway builder container, ~250 MiB, and the compile itself is seconds) |

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

### Branding on the live medium

`--profile server` also renames what the live medium calls itself: the grub
entries, the syslinux labels and `iso_application` in `profiledef.sh` read
`Omarchy Server` instead of `Omarchy`. It is a `sed` over the copies in the
build cache, applied for any profile that is not `desktop`, so a desktop build
is byte-identical to upstream. The choice of edition is made when the medium is
written and nothing on screen says so afterwards, which is the whole reason.

The installer dashboard is deliberately untouched: restyling it is a different
job from labelling the ISO, and its rotating tips are still desktop tips.

![The branded Limine menu of an installed server](screenshots/limine-menu.png)

The installed machine's own branding — the menu above, `/etc/issue`, the VT
palette, the MOTD and `os-release` — is `docs/packaging.md` §2.5, because it is
the packages that carry it, not the ISO.

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
repository's sources, and that ISO installs a headless machine that looks like
Omarchy from the bootloader to the shell prompt and passes the whole acceptance
list (`pocs/server-install/README.md`).

The ISO also carries the `fwall` addon package, built inside its own builder
from the `tui-tools` checkout. It is bundled in the offline mirror and installed
only on request, so the base install is byte-for-byte the same 220 packages it
was before.

The update path is non-interactive as of §3.1: `omarchy-server-update`, and the
opt-in `omarchy-server-update.timer`, run the whole update as root with nothing
to answer, and the desktop path is unchanged. The desktop profile has now also
been built and installed from the patched tree; the diff against the reference
install is §8.

Left over, in rough order of how much they hurt:

1. **Deferred provisioning on a server has no non-interactive path.**
   `omarchy-provision-owner` is safe to run headless now, but the setup form it
   drives is `gum`-only, so a `defer-provisioning` install still has no source
   for the answers. A cidata-style input for the first-boot form is the
   missing piece.
2. **`cloud-init` in the live ISO** prints over the install dashboard on tty1
   (see §6). Dropping it from the live package set, or ordering it after the
   dashboard, would make a failed install readable on the console instead of
   only through `/run/omarchy-install/state.json`.
3. **The install dashboard's tips are desktop tips** during a server install.
4. **The update's last step still talks about a shell.**
   `omarchy-update-restart` prints "Restarting shell / All plugins have been
   reloaded" and then `omarchy-restart-shell` says the config was not found.
   Cosmetic, and the only piece of the update path left untouched, because
   silencing it means a server branch in a command that has none today.
5. **`omarchy-server-addon fwall` has no source on an installed machine.**
   Every other addon installs from the Arch or `[omarchy]` mirrors; `fwall` is
   built here, so until `[omarchy-server]` is published (item 6) it can only be
   applied during the install, from the ISO's offline mirror.
6. **The `[omarchy]` mirror is still `Optional TrustAll`** and the offline
   mirror `Never`. A signed repository of our own, with
   `/etc/pacman.d/omarchy-server.conf` shipped by the profile, is the next
   packaging step; `omarchy-server-keyring` is already built and installed by
   the ISO in preparation.

---

## 8. Desktop parity

A desktop ISO built from this tree installs the same machine an upstream ISO
does. Measured, not asserted: `./iso/build.sh --profile desktop` (7m03s,
5.9 GiB) installed into a fresh VM `ref2` with the very cidata drive the
`pocs/lab/reference/` desktop reference was installed from. The full table is
`pocs/lab/reference/desktop-parity.md`; the summary:

| | Reference | `ref2` |
|---|---|---|
| Packages, and the name set | 942 | **942, identical both ways** |
| Explicit set, enabled units, subvolumes, cmdline, `limine.conf`, `mkinitcpio.conf.d`, `pacman.conf`, `os-release` | — | **identical** |
| `lua51` / `luarocks` / `omarchy-nvim` | present | present |
| Swapfile, `resume=`, `graphical.target`, sddm | present | present |
| Installed size | 8079.57 MiB | 8081.75 MiB |
| Failed units | 0 | 0 |

The 2.18 MiB is `mise-bin` growing 96.36 → 98.52 MiB between the two mirror
snapshots. Nothing here selects or pins it.

Two branches in the series *can* touch a desktop install:

- **`/etc/omarchy-profile`.** The first parity run produced an unowned
  `/etc/omarchy-profile` on the desktop, written unconditionally by
  `_write_profile_marker`. Nothing on a desktop reads it, but it was the one
  file separating a patched build from an upstream one, so the marker is now
  written for named profiles only. Fixed, and re-measured.
- **The default hostname.** `0009` changes the fallback for an autoinstall drive
  with no `hostname` key from archinstall's `archlinux` to `omarchy`. Inert for
  any install that names its host, including this one. Kept, because `omarchy`
  is what the ISO's own interactive configurator offers, so the patch makes the
  autoinstall path agree with the interactive one. This is the one deliberate
  desktop-path behaviour change in the series.

Everything else is gated: `_is_server_profile()` in the orchestrator, the
`desktop` arm of the `case` in `build-iso.sh`, `[[ $OMARCHY_PROFILE != "desktop" ]]`
for the live-medium branding and the mirror cache key. The runtime patches
(`profile/server/overlay/patches/`) never reach a desktop at all: they are
applied in `prepare()` of `omarchy-server`, a package a desktop does not install.
