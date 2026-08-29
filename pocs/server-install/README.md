# Headless install of the server profile

A VM installed from the ISO of `docs/iso-server.md`, entirely from a `cidata`
drive, with no keyboard and no configurator. This directory holds the scripts
that drive it, the artifacts collected from the installed machine
(`reference/`), and the acceptance verdict.

## How to reproduce

```bash
./iso/build.sh                                   # builds iso/release/*.iso

./pocs/lab/mkcidata.sh --profile server \
  --hostname omarchy-srv --out pocs/lab/out-server

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

`mkcidata.sh --profile server` differs from the desktop one in four places: the
runtime/settings package names, `audio_config: null` (no PipeWire), a shorter
`packages` list (no `base-devel`, no `git`), and a `profile` file that tells the
ISO's orchestrator which profile to install even if the ISO itself was built
for another one. `--addons` adds a fifth, the `addons` file.

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
(the VM's serial console), `console.png` (the console after boot) and
`acceptance.txt` (the raw evidence behind the table below).

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
| Boot | **4.8-6.6 s** (firmware 0.55 + loader 1.3-2.0 + kernel 0.9-1.1 + userspace 1.9-3.1) | 12.2 s |
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
| Enabled unit files | 17 | **20** | +3 |
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
  (`systemd-networkd.socket`, two varlink sockets, the resolve hook), and
  `docker.socket` left. Counting unit *files* flatters NetworkManager here; the
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
- **Boot got slower**, 3.9 s → 4.8-6.6 s, and most of the difference is in the
  loader (0.67 s → 1.3-2.0 s), which has nothing in it that this change
  touched: `timeout: 0` is unchanged and the loader runs before a single
  package matters. The measurements were taken with two other VMs on the same
  host, and the spread within a single machine (4.8 s and 6.6 s on consecutive
  boots) is as large as the difference from the baseline, so this is host noise
  until it is measured on a quiet machine. Worth re-measuring, not worth a
  conclusion.

### Acceptance

Full evidence in `reference/acceptance.txt`.

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 1 | `systemctl get-default` = `multi-user.target` | **PASS** | `multi-user.target` |
| 2 | no sddm/hyprland/pipewire/plymouth installed | **PASS** | `graphical=0` |
| 3 | docker absent from the base | **PASS** | none of docker, docker-compose, docker-buildx, ufw-docker, lazydocker, networkmanager, base-devel, gcc, git, tailscale is installed |
| 4 | ssh with the cidata key works | **PASS** | `logged in as omarchy@omarchy-srv` |
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
| 16 | boot to ssh < 20 s | **PASS** | `systemd-analyze` = 4.8 s |
| 17 | `/proc/cmdline` has `console=ttyS0`, no quiet/splash/resume | **PASS** | `… rootfstype=btrfs console=ttyS0,115200 console=tty0` |
| 18 | zram active | **PASS** | `/dev/zram0`, zstd, 3.9 GiB (RAM/2), priority 100, no swapfile |
| 19 | `/etc/omarchy-profile` = `server` | **PASS** | `server` |
| 20 | `omarchy-version` = `4.0.1-1` | **PASS** | `4.0.1-1` |
| 21 | `omarchy-server-addon docker` installs and runs a container | **PASS** | `Hello from Docker!` |
| 22 | the docker addon opens only the container DNS stub | **PASS** | new listener is `172.17.0.1:53`, gated by the two `allow-docker-dns` rules |
| 23 | `omarchy-update` runs to completion | **PASS** (with a caveat, below) | `rc=0` |

**23 of 23 checks pass**, plus the reboot check
(`reboot-check.sh`): the machine comes back, 0 failed units, the profile marker,
default target, cmdline, `ufw` rules and listener set all survive.

The addon path was also verified the other way round, on a second VM
(`srv-docker`) installed with `mkcidata.sh --addons docker`: the orchestrator's
`Installing addons` phase applies it in the chroot against the ISO's offline
mirror, and the machine comes up with docker installed, `docker.socket` enabled
and the three drop-ins in `/etc`, without ever reaching the network.

### The `omarchy-update` caveat

`omarchy-update` completes on a server, but it is **not** non-interactive:
several steps shell out to `sudo`, which prompts on the terminal. Run
`omarchy-update -y </dev/null` and every one of those steps stalls until sudo
times out, then reports its own failure and moves on — the update "finishes"
having pruned nothing and snapshotted nothing. The acceptance harness feeds the
password to the pty `script` allocates, which is why its run is clean.

Two aggravating factors of this profile:

- `install/server/increase-lockout-limit-server.sh` raises `pam_faillock` to
  `deny=10 unlock_time=120`, and the `preauth silent` line means a locked
  account is indistinguishable from a wrong password. A stalled unattended run
  therefore leaves the account locked for two minutes with no explanation.
- `omarchy-update-status` calls `omarchy-shell`, which is not usable without
  Quickshell. It happens to be harmless: `omarchy-shell -q` returns 0 when
  `$OMARCHY_PATH/shell/shell.qml` is missing, which it is because the server
  runtime does not ship `shell/`. So the graphical status refresh silently
  no-ops instead of failing the update. No patch was needed.

A truly unattended server update wants a non-interactive mode that either
requires root outright or a NOPASSWD rule for the specific commands. That is
the one acceptance item met with a caveat rather than cleanly.

### The firewall rate-limits the test harness

`ufw limit 22/tcp` drops a source that opens six connections within thirty
seconds. Every helper in `pocs/` opened one ssh connection per command, so the
harness rate-limited itself out and looked hung while the rule was doing exactly
its job. `vm.sh` now multiplexes over a single connection (`ControlMaster`) and
`wait-ssh` polls every 10 s instead of every 5 s. Worth knowing before wiring
this profile into any automation that reconnects in bursts.
