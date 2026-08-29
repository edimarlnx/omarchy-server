# Headless install of the server profile

A VM installed from the ISO of `docs/iso-server.md`, entirely from a `cidata`
drive, with no keyboard and no configurator. This directory holds the scripts
that drive it, the artifacts collected from the installed machine
(`reference/`), and the acceptance verdict.

## How to reproduce

```bash
./iso/build.sh                                   # builds iso/release/*.iso

# No --hostname: the cidata drive then carries no `hostname` key at all and the
# installed machine gets the profile default, `omarchy`. Pass --hostname NAME
# to name it.
./pocs/lab/mkcidata.sh --profile server --out pocs/lab/out-server

export LAB_OUT=$PWD/pocs/lab/out-server
./pocs/lab/vm.sh srv create --disk-gb 40
./pocs/lab/vm.sh srv start \
  --iso "$PWD/iso/release/omarchy-2026.08.29-x86_64-server-local.iso" \
  --cidata "$PWD/pocs/lab/out-server/cidata.iso"
./pocs/lab/vm.sh srv wait-ssh

./pocs/server-install/collect.sh srv          # artifacts into reference/
./pocs/server-install/surface.sh srv          # attack-surface measurements
./pocs/server-install/acceptance.sh srv       # PASS/FAIL list with evidence
./pocs/server-install/reboot-check.sh srv     # reboot survival, runs last
```

`LAB_OUT` keeps the server lab (disk, NVRAM, cidata ssh key, lab password) in
its own directory, so the desktop reference VM of the earlier lab stays intact.

Run `collect.sh` **before** `acceptance.sh`: the acceptance list installs the
`docker` addon and then runs `omarchy-update`, both of which change the package
set the measurements record.

To install with an addon already applied, pass it to `mkcidata.sh` and the
orchestrator applies it in the chroot from the ISO's offline mirror:

```bash
./pocs/lab/mkcidata.sh --profile server --addons docker \
  --hostname omarchy-srv-docker --out pocs/lab/out-server-docker
```

The `fwall` addon is verified this way rather than through
`omarchy-server-addon` on a running machine, because it is the one addon whose
package exists only in the ISO's offline mirror until the `[omarchy-server]`
repository is published:

```bash
./pocs/lab/mkcidata.sh --profile server --addons fwall --out pocs/lab/out-server-fwall
LAB_OUT=$PWD/pocs/lab/out-server-fwall ./pocs/lab/vm.sh srvf create --disk-gb 40
```

Note `--disk-gb 40`: the cidata JSON carries an absolute partition layout for a
40 GiB disk, and a smaller VM disk fails the install at the first phase with
`Partition overlaps backup GPT header`.

`mkcidata.sh --profile server` differs from the desktop one in four places: the
runtime/settings package names, `audio_config: null` (no PipeWire), a shorter
`packages` list (no `base-devel`, no `git`), and a `profile` file that tells the
ISO's orchestrator which profile to install even if the ISO itself was built
for another one. `--addons` adds a fifth, the `addons` file, and
`--unattended-updates` a sixth: a marker file whose presence makes the install
enable the daily `omarchy-server-update.timer`, which the package ships
disabled.

```bash
./pocs/lab/mkcidata.sh --profile server --unattended-updates \
  --out pocs/lab/out-server-auto
```

## Debugging a failed install

The install dashboard runs on tty1 of the live ISO, and `cloud-init` (inherited
from the archiso releng profile) sometimes prints over it, so the screen is not
a reliable status source. What is:

- `/run/omarchy-install/state.json` — every phase with its status, elapsed time
  and, on failure, the exact command and error;
- `/var/log/omarchy-install.log` — the target setup log, with `set -x` output
  from every `install/` script when the ISO was built with `--debug`.

Both live in the live environment, which is reachable without a screen: switch
to tty2 through the QEMU monitor (`sendkey alt-f2`), log in as `root` (no
password in archiso), copy the cidata key into place and restart sshd:

```bash
mkdir -p /root/.ssh
cp /root/authorized_keys /root/.ssh/authorized_keys
chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys
systemctl restart sshd
```

That path found every install-time bug recorded in `docs/iso-server.md`.

## Artifacts in `reference/`

`packages-all.txt`, `packages-explicit.txt`, `packages-deps.txt`,
`packages-biggest.txt`, `size.txt`, `services-enabled.txt`,
`services-masked.txt`, `user-services-enabled.txt`, `surface.txt`,
`boot-time.txt`, `boot.txt`, `storage.txt`, `firewall.txt`, `system.txt`,
`logs.txt`, `install-timing.json`, `omarchy-install.log`, plus `serial.log`
(the VM's serial console), `console.png` (the console after boot),
`serial-issue.txt` (the login banner as agetty wrote it to the serial line) and
`acceptance.txt` (the raw evidence behind the table below).

The three screenshots the README shows — the branded Limine menu, the console
banner and the MOTD — live in `docs/screenshots/`. They were taken from this
VM: the console and MOTD with `vm.sh srv screenshot`, the menu by holding it
open with `sendkey down` through the QEMU monitor (any keypress cancels
Limine's two-second countdown) and screenshotting at leisure. The MOTD is a
real login shell on tty3, opened with `openvt -c 3 -f -s -- su - omarchy`.

---

## Result

Installed from `omarchy-2026.08.29-x86_64-server-local.iso` (2.9 GiB) into a
QEMU/KVM VM: q35, 4 vCPU, 8 GiB RAM, OVMF 4M without Secure Boot, 40 GiB virtio
disk, user-mode networking with ssh forwarded to localhost.

| Measurement | Server profile | Desktop reference |
|---|---|---|
| Orchestrator, 15 phases | **28.9 s** (`Installing Arch + Omarchy` 21.0 s) | ~98 s |
| VM power-on to ssh, install included | **~60 s** | — |
| Packages (`pacman -Qq`) | **220** (21 explicit, 199 dependencies) | 942 |
| Installed size | **1402 MiB** | 8079 MiB |
| Used on `/` | **1.2 GiB** | 14 GiB |
| Boot | **5.9-7.0 s** (firmware 0.55 + loader 2.6-2.8 + kernel 0.8-0.9 + userspace 1.8-2.8) | 12.2 s |
| Default target | `multi-user.target` | `graphical.target` |
| Biggest packages | linux 148 MiB, linux-firmware-intel 132, linux-firmware-nvidia 104, python 74 | libreoffice 421, chromium 416, electron43 333 |

## Attack surface, before and after

"Before" is the first server baseline, which took its package list from parity
with the desktop edition. "After" is the lean base: only what a headless machine
needs to boot, update, snapshot, be reached by ssh and be firewalled, with
everything else moved into an addon. Both were measured with `surface.sh` on the
same VM shape, from an install of the ISO that produced them.

| Metric | Before | After | Δ |
|---|---|---|---|
| Packages installed | 320 | **220** | −100 (−31%) |
| Explicitly installed | 57 | **21** | −36 |
| Installed size | 2344 MiB | **1402 MiB** | −942 MiB (−40%) |
| Used on `/` | 1.7 GiB | **1.2 GiB** | −0.5 GiB |
| Enabled unit files | 17 | **21** | +4 |
| Masked unit files | 5 | **13** | +8 |
| Listening sockets (`ss -ltnup`) | 8 | **6** | −2 |
| Reachable off the machine | 22 + 172.17.0.1:53 | **22 only** | −1 |
| setuid/setgid binaries | 19 | **16** | −3 |
| Services running as root | 12 | **9** | −3 |
| `linux-firmware` | 408 MiB | 408 MiB | — |
| Compiler present | gcc, 221 MiB | **none** | −221 MiB |
| Container runtime present | docker + containerd + buildx, 266 MiB | **none** | −266 MiB |
| `perl` | 70 MiB | **none** | −70 MiB |

The "before" column is not read out of the old notes: it was re-measured with
the same `surface.sh` against a VM installed from the previous ISO
(`omarchy-2026.08.28-x86_64-server-local.iso`), so both columns come from the
same script on the same VM shape. The raw output is
`reference/surface-before.txt` next to `reference/surface.txt`.

Reading the table:

- **The enabled-unit count went up, not down.** Swapping NetworkManager for
  systemd-networkd trades two services (`NetworkManager`, its `dispatcher`) for
  one service plus four sockets that systemd ships as separate units
  (`systemd-networkd.socket`, two varlink sockets, the resolve hook),
  `docker.socket` left, and `omarchy-tty-palette.service` — a oneshot that runs
  once before getty and exits — arrived. Counting unit *files* flatters NetworkManager here; the
  honest comparison is the services-as-root row, which is what an exploit
  actually gets. That fell from 12 to 9: `NetworkManager`,
  `NetworkManager-dispatcher` and `systemd-hostnamed` are gone.
- **The one listener that mattered was the docker DNS stub.** Upstream's
  `20-docker-dns.conf` sets `DNSStubListenerExtra=172.17.0.1`, so the base
  install answered DNS on the bridge address whether or not anything ran there
  — `systemd-resolve` held two sockets on `172.17.0.1:53` on a machine with no
  containers. Moving that file out of the settings package and into the docker
  addon's setup leaf is what removes it. After: `sshd` on `0.0.0.0:22` and
  `[::]:22`, plus resolved's `127.0.0.53`/`127.0.0.54` stubs, which no other
  host can reach.
- **The setuid set is now the distribution's own.** Three left with the
  packages that brought them: `pkexec` (polkit, pulled in by NetworkManager —
  a setuid binary with its own CVE history), `plocate`, and `utempter`. What
  remains is `mount`/`umount`/`su`/`sudo`/`passwd`/`chage`/`chfn`/`chsh`/
  `gpasswd`/`newgrp`/`unix_chkpwd`/`ssh-keysign`/`ksu`/`wall`/`write` and the
  dbus launch helper — Arch's baseline, nothing this profile added.
- **`dockerd` never showed up in the root-services row**, before or after,
  because `docker.socket` starts it on the first client connection. The 266 MiB
  of docker + containerd + buildx was still on disk and still upgraded on every
  `omarchy-update`; it is now only there when someone asks for it.
- **`linux-firmware` is the largest single item left**, 408 MiB of the 1402.
  It is in `profile/server/archinstall.packages`; dropping it is one line, and
  worth it for a VM or a fleet with known hardware. It stays in for now because
  a server ISO that will not bring up a NIC on unknown hardware is worse than a
  large one.
- **Boot got slower**, 3.9 s → 5.9-7.0 s, and all of the difference is in the
  loader (0.67 s → 2.6-2.8 s). Two of those seconds are bought deliberately:
  `timeout` went from 0 to 2 so the branded menu is on screen and reachable
  without holding a key. The rest is host noise — the spread within a single
  machine, on consecutive boots, is as large as it — and the loader runs before
  a single package matters, so nothing in the package set is implicated.

### Acceptance

Full evidence in `reference/acceptance.txt`.

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 1 | `systemctl get-default` = `multi-user.target` | **PASS** | `multi-user.target` |
| 2 | no sddm/hyprland/pipewire/plymouth installed | **PASS** | `graphical=0` |
| 3 | docker absent from the base | **PASS** | none of docker, docker-compose, docker-buildx, ufw-docker, lazydocker, networkmanager, base-devel, gcc, git, tailscale is installed |
| 4 | ssh with the cidata key works | **PASS** | `logged in as omarchy@omarchy` |
| 5 | password authentication is refused | **PASS** | `Permission denied (publickey)` with `PubkeyAuthentication=no` |
| 6 | root cannot log in over ssh | **PASS** | `sshd -T`: `permitrootlogin no`, `passwordauthentication no`, `kbdinteractiveauthentication no`, `permitemptypasswords no` |
| 7 | networkd brought the link up by DHCP | **PASS** | `networkctl` reports the link `routable`, address from DHCP |
| 8 | resolved answers through the stub resolver | **PASS** | `/etc/resolv.conf` → `stub-resolv.conf`, `getent hosts` resolves |
| 9 | sudo works with the lab password | **PASS** | `sudo -S` returns `root` |
| 10 | ufw active, deny incoming, 22 rate-limited | **PASS** | `Status: active`, `Default: deny (incoming)`, `22/tcp LIMIT IN` |
| 11 | nothing listens except ssh | **PASS** | off-loopback listeners are `0.0.0.0:22` and `[::]:22` only |
| 12 | factory snapshot present, snapper configured | **PASS** | btrfs subvolume `@factory`, snapper config `root` |
| 13 | `/boot/limine.conf` lists snapshot entries | **PASS** | after `snapper create`, a `//Snapshots` section appears |
| 14 | `pacman -Qq \| wc -l` in 150-260 | **PASS** | 220 |
| 15 | installed size and disk used < 3 GB | **PASS** | 1402 MiB installed, 1.2 GiB used |
| 16 | boot to ssh < 20 s | **PASS** | `systemd-analyze` = 5.9 s |
| 17 | `/proc/cmdline` has `console=ttyS0`, no quiet/splash/resume | **PASS** | `… rootfstype=btrfs console=ttyS0,115200 console=tty0` |
| 18 | zram active | **PASS** | `/dev/zram0`, zstd, 3.9 GiB (RAM/2), priority 100, no swapfile |
| 19 | `/etc/omarchy-profile` = `server` | **PASS** | `server` |
| 20 | `omarchy-version` = `4.0.1-1` | **PASS** | `4.0.1-1` |
| 21 | hostname defaults to `omarchy` when cidata gives none | **PASS** | `hostnamectl hostname` = `omarchy` |
| 22 | `os-release` identifies the edition | **PASS** | `NAME`/`PRETTY_NAME` = `Omarchy Server`/`Omarchy Server 4.0.1`, `ID=omarchy-server`, `ANSI_COLOR="0;32"`, `LOGO=omarchy` |
| 23 | `/etc/issue` carries the logo, the version and the machine fields | **PASS** | the ESC-green logo, `\S{VERSION_ID}`, `host`/`tty`/`ipv4`; rendered in `reference/console.png` |
| 24 | the serial console gets its own logo-free issue | **PASS** | `/etc/issue.serial` has no art, the `serial-getty@.service.d` drop-in points agetty at it; rendered in `reference/serial-issue.txt` |
| 25 | the VT palette unit ran, and left the serial console alone | **PASS** | `omarchy-tty-palette.service` enabled + active, exit status 0, no `ttyS` in the command |
| 26 | `/boot/limine.conf` is branded, waits 2 s, points at the wallpaper | **PASS** | `timeout: 2`, `interface_branding: Omarchy Server`, `wallpaper: boot():/limine-wallpaper.png`, `wallpaper_style: stretched` — checked **after** `limine-snapper-sync` regenerated the entries (item 13) |
| 27 | the wallpaper is on the ESP | **PASS** | `/boot/limine-wallpaper.png`, 17941 B, `PNG image data, 1920 x 1080, 8-bit/color RGB` |
| 28 | the login banner prints the machine identity | **PASS** | `Omarchy Server 4.0.1` plus host, kernel, uptime, packages, updates, memory, ip |
| 29 | the banner is wired into every login shell | **PASS** | `/etc/profile.d/omarchy-motd.sh` calls `omarchy-server-motd` |
| 30 | `fwall` is not in the base | **PASS** | not installed |
| 31 | `omarchy-server-addon docker` installs and runs a container | **PASS** | `Hello from Docker!` |
| 32 | the docker addon opens only the container DNS stub | **PASS** | new listener is `172.17.0.1:53`, gated by the two `allow-docker-dns` rules |
| 33 | the update timer ships disabled and toggles | **PASS** | `shipped=disabled enabled=enabled disabled=disabled` |
| 34 | the free-space check uses the server threshold | **PASS** | `+ required_gib=2` under `bash -x` |
| 35 | `omarchy-server-update` runs non-interactively to completion | **PASS** | `rc=0`, as root, stdin closed, nothing to answer |
| 36 | the unattended update pruned the cache and took a snapshot | **PASS** | `pruned=yes snapshotted=yes`, and the snapper list shows the new snapshot |
| 37 | no prompt was rendered during the unattended update | **PASS** | `confirm-prompts=0` in the transcript |

**37 of 37 checks pass**, plus the reboot check
(`reboot-check.sh`): the machine comes back, 0 failed units, the profile marker,
default target, cmdline, `ufw` rules and listener set all survive.

The addon path was also verified the other way round, on a second VM
(`srv-docker`) installed with `mkcidata.sh --addons docker`: the orchestrator's
`Installing addons` phase applies it in the chroot against the ISO's offline
mirror, and the machine comes up with docker installed, `docker.socket` enabled
and the three drop-ins in `/etc`, without ever reaching the network.

The `fwall` addon was verified the same way, on a VM (`srvf`) installed with
`mkcidata.sh --addons fwall`. It is the case that needs this route rather than
`omarchy-server-addon` on a running machine: the package is built by the ISO
builder and exists only in the offline mirror until the `[omarchy-server]`
repository is published.

| Check | Result |
|---|---|
| package installed by the `Installing addons` phase | `fwall 0.1.0-1`, 3.69 MiB, MIT |
| package count against the base | 221, one more than the 220 of the lean base |
| `fwall --version` | `fwall 0.1.0` |
| `/etc/fwall/config.toml` | `backend = "ufw"` |
| `fwall --demo` on the console | renders, in the same palette the rest of the machine uses |

![fwall running on the console of a server installed with the addon](../../docs/screenshots/fwall.png)

### The update path

`omarchy-update` used to be the one acceptance item met with a caveat: several
of its steps shell out to `sudo`, which prompts on the terminal, so
`omarchy-update -y </dev/null` stalled on each one until sudo timed out and then
"finished" having pruned nothing and snapshotted nothing. Two aggravating
factors of this profile made that worse:

- `install/server/increase-lockout-limit-server.sh` raises `pam_faillock` to
  `deny=10 unlock_time=120`, and the `preauth silent` line means a locked
  account is indistinguishable from a wrong password. A stalled unattended run
  left the account locked for two minutes with no explanation.
- `omarchy-update-status` calls `omarchy-shell`, which is not usable without
  Quickshell. That one is harmless: `omarchy-shell -q` returns 0 when
  `$OMARCHY_PATH/shell/shell.qml` is missing, which it is because the server
  runtime does not ship `shell/`, so the graphical status refresh silently
  no-ops. No patch was needed.

Both are settled now, and the fix is two moves. **Run as root**, where `sudo`
never asks for a password and `pam_faillock` is never consulted — that is what
`omarchy-server-update` does, and what the systemd unit does. **Make the
promise explicit before the transcript's pty exists**: `omarchy-update` re-execs
itself under `script`, which allocates a pseudo-terminal, so every `-t` test
below that line reports a terminal nobody is at. The patched
`omarchy-update` decides "unattended" from `-y`, `OMARCHY_NONINTERACTIVE=1` or a
non-tty stdin *before* the re-exec, and `omarchy-update-restart` and
`omarchy-update-orphan-pkgs` honor the answer.

```bash
sudo omarchy-server-update           # now
sudo omarchy-server-update enable    # daily timer (ships disabled)
journalctl -u omarchy-server-update  # what a run did
```

`docs/iso-server.md` §3.1 has the full audit, including the three things a
root-run update needs that neither `sudo` nor systemd supplies (`$OMARCHY_PATH`,
`$HOME`, and root's migration markers).

### The firewall rate-limits the test harness

`ufw limit 22/tcp` drops a source that opens six connections within thirty
seconds. Every helper in `pocs/` opened one ssh connection per command, so the
harness rate-limited itself out and looked hung while the rule was doing exactly
its job. `vm.sh` now multiplexes over a single connection (`ControlMaster`) and
`wait-ssh` polls every 10 s instead of every 5 s. Worth knowing before wiring
this profile into any automation that reconnects in bursts.

## Secure Boot, with the machine's own keys

Verified end to end on VM `srvsb`, ISO `omarchy-2026.08.29-x86_64-server-local`,
`omarchy-server 4.0.1-3`. Full evidence in `reference/acceptance-secureboot.txt`
(`acceptance-secureboot.sh`, **24 passed, 0 failed**).

```bash
pocs/lab/mkcidata.sh --profile server --secureboot --hostname srvsb \
  --out pocs/lab/out-server-secboot
LAB_OUT=pocs/lab/out-server-secboot pocs/lab/vm.sh srvsb create --secboot
LAB_OUT=pocs/lab/out-server-secboot pocs/lab/vm.sh srvsb start \
  --iso iso/release/<iso> --cidata pocs/lab/out-server-secboot/cidata.iso
LAB_OUT=pocs/lab/out-server-secboot pocs/server-install/acceptance-secureboot.sh srvsb
```

`create --secboot` clears the platform key out of OVMF's `secboot` variable
store (`virt-fw-vars --delete PK`), which is the only way one VM can do both
halves of the exercise: the live ISO is unsigned and would not boot against an
enforcing firmware, and `sbctl enroll-keys` needs Setup Mode to write anything.
The install enrolls, and the machine has been enforcing ever since — including
across the reboot at the end of the acceptance run.

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 1 | firmware enforcing with our keys | **PASS** | `sbctl status`: `Secure Boot: ✓ Enabled`, `Setup Mode: ✓ Disabled`, `installed: true` |
| 2 | the firmware's own variable agrees | **PASS** | `SecureBoot-8be4df61…` byte 4 = `1` |
| 3 | the kernel saw it at handover | **PASS** | `[ 0.004285] Secure boot enabled` |
| 4 | every EFI binary on the ESP is signed | **PASS** | `limine_x64.efi`, `BOOTX64.EFI`, `omarchy_linux.efi` — `unsigned=0` |
| 5 | `limine.conf`'s recorded hash is the hash of the **signed** UKI | **PASS** | `recorded == b2sum(file)` |
| 6 | the booted cmdline carries the lockdown options | **PASS** | `lockdown=integrity module.sig_enforce=1` in `/proc/cmdline` |
| 7 | lockdown is in integrity mode | **PASS** | `/sys/kernel/security/lockdown` → `none [integrity] confidentiality` |
| 8 | module signature enforcement is on | **PASS** | `sig_enforce=Y` |
| 9 | the drop-in appends, it does not replace | **PASS** | `omarchy-secureboot.conf` with `KERNEL_CMDLINE[default]+=`, serial console intact |
| 10 | keys on `@`, never on the ESP | **PASS** | `PK/KEK/db` under `/var/lib/sbctl`, `esp-key-files=0` |
| 11 | key material is root-only | **PASS** | dirs `0700`, `db.key` `0400`, `ls` as the user → `Permission denied` |
| 12 | an unsigned module is refused | **PASS** | tampered `aegis128_aesni.ko`: `insmod: Key was rejected by service`, `dmesg: Loading of unsigned module is rejected` |
| 13 | stock in-tree modules still load | **PASS** | `modprobe dummy` → loaded |
| 14 | a kernel reinstall rebuilds **and** re-signs the UKI | **PASS** | `pacman -S linux`: mkinitcpio post hook `[sbctl] ✓ Signed`, then `✓ Signed /boot/EFI/limine/limine_x64.efi`, then `(5/5) Signing EFI binaries…`; UKI hash changed |
| 15 | `limine.conf` still records the new signed UKI | **PASS** | `hash-ok` after the reinstall |
| 16 | `limine-snapper-sync` keeps the config consistent | **PASS** | snapshot entries added, branding above the first entry intact |
| 17 | it still boots enforcing afterwards | **PASS** | boot id changed, `secure_boot: true`, `[integrity]`, `sig_enforce=Y` |

Nothing in that list is re-signed by code this profile owns. The signatures come
from `limine-entry-tool`'s `sb_sign` (the Limine binary), mkinitcpio's
`/usr/lib/initcpio/post/sbctl` (the UKI, on the temporary file, before its hash
is recorded) and sbctl's `zz-sbctl.hook` (everything in the database, after any
transaction that touches `boot/`). All three are gated on
`sbctl setup --print-state`, so creating the keys is the entire switch.
`docs/secure-boot.md` is the design and the limitations.

### Two things that bit during this run

**`sbctl verify` exits 0 while reporting an unsigned file.** The first pass of
the acceptance script checked `$?` and called an unsigned `BOOTX64.EFI` a pass.
Both the script and `omarchy-server-secureboot` now parse the report for
`is not signed`.

**The removable fallback is signed by nobody during an install.**
`limine-entry-tool` signs only `limine_x64.efi`; `/EFI/BOOT/BOOTX64.EFI` is
covered by sbctl's pacman hook, and no transaction runs after `limine-install`
writes it. `omarchy-server-secureboot enroll` now signs the chain itself before
verifying, which closes the gap wherever it appears.
