# Lean, security-first base, and the addon mechanism

**Date:** 2026-08-28
**Subject:** cutting the server base to what a headless machine needs, and measuring the difference
**Result:** 320 → **220** packages, 2344 → **1402 MiB**, **23/23** acceptance checks pass

## Scope

The first server ISO installed a machine that was a desktop minus the desktop:
320 packages, a compiler, a container runtime, NetworkManager, `perl`. This run
replaces that with a base that does five things — boot, update, snapshot, be
reached by ssh, be firewalled — and moves everything else into an **addon**,
bundled in the ISO's offline mirror but not installed.

The measurement is the point. Both columns below come from the **same script**
(`pocs/server-install/surface.sh`) run against the same VM shape, one machine
installed from the previous ISO and one from the new one. The "before" column is
not read out of old notes.

## Environment

| | |
|---|---|
| "Before" VM | `srv-before`, installed from `omarchy-2026.08.28-x86_64-server-local.iso`, measured `2026-08-28T22:51:20-03:00` |
| "After" VM | `srv`, installed from the rebuilt ISO |
| Both | QEMU/KVM `q35`, 4 vCPU, 8 GiB RAM, 40 GiB virtio disk, OVMF 4M without Secure Boot, `cidata` autoinstall |

## Method

```bash
./iso/build.sh
./pocs/lab/mkcidata.sh --profile server --out pocs/lab/out-server
LAB_OUT=$PWD/pocs/lab/out-server ./pocs/lab/vm.sh srv create --disk-gb 40
# … start, wait-ssh …
./pocs/server-install/collect.sh srv    # before acceptance: acceptance changes the package set
./pocs/server-install/surface.sh  srv
./pocs/server-install/acceptance.sh srv
./pocs/server-install/reboot-check.sh srv
```

`collect.sh` must run **before** `acceptance.sh`, because the acceptance list
installs the `docker` addon and then runs an update, both of which change what
the measurements would record.

## Results

| Metric | Before | After | Δ |
|---|---|---|---|
| Packages installed | 320 | **220** | −100 (−31%) |
| Explicitly installed | 57 | **21** | −36 |
| Installed size | 2344 MiB | **1402 MiB** | −942 MiB (−40%) |
| Used on `/` | 1.7 GiB | **1.2 GiB** | −0.5 GiB |
| Enabled unit files | 17 | **20** | +3 |
| Masked unit files | 5 | **13** | +8 |
| Listening sockets (`ss -ltnup`) | 8 | **6** | −2 |
| Reachable off the machine | 22 + `172.17.0.1:53` | **22 only** | −1 |
| setuid/setgid binaries | 19 | **16** | −3 |
| Services running as root | 12 | **9** | −3 |
| `linux-firmware` | 408 MiB | 408 MiB | — |
| Compiler present | gcc, 221 MiB | **none** | −221 MiB |
| Container runtime present | docker + containerd + buildx, 266 MiB | **none** | −266 MiB |
| `perl` | 70 MiB | **none** | −70 MiB |

### Reading the table

**The enabled-unit count went up, not down.** Swapping NetworkManager for
systemd-networkd trades two services (`NetworkManager`, its `dispatcher`) for
one service plus four sockets that systemd ships as separate units
(`systemd-networkd.socket`, two varlink sockets, the resolve hook); `docker.socket`
left. Counting unit *files* flatters NetworkManager here. The honest comparison
is the services-as-root row — what an exploit actually gets — and that fell from
12 to 9: `NetworkManager`, `NetworkManager-dispatcher` and `systemd-hostnamed`
are gone.

**The one listener that mattered was the docker DNS stub.** Upstream's
`20-docker-dns.conf` sets `DNSStubListenerExtra=172.17.0.1`, so the base install
answered DNS on the bridge address whether or not anything ran there —
`systemd-resolve` held two sockets on `172.17.0.1:53` on a machine with no
containers. Moving that file out of the settings package and into the docker
addon's setup leaf is what removes it. After: `sshd` on `0.0.0.0:22` and
`[::]:22`, plus resolved's `127.0.0.53`/`127.0.0.54` stubs, which no other host
can reach.

**The setuid set is now the distribution's own.** Three left with the packages
that brought them: `pkexec` (polkit, pulled in by NetworkManager — a setuid
binary with its own CVE history), `plocate` and `utempter`. What remains is
Arch's baseline; nothing this profile added.

**`dockerd` never appeared in the root-services row**, before or after, because
`docker.socket` starts it on the first client connection. The 266 MiB was still
on disk and still upgraded on every update; it is now there only when asked for.

**`linux-firmware` is the largest single item left**, 408 MiB of the 1402. It is
one line in the profile's package list, and worth dropping for a VM or a fleet
with known hardware. It stays for now because a server ISO that will not bring
up a NIC on unknown hardware is worse than a large one.

### What made the difference

- **`systemd-networkd` instead of NetworkManager.** `network-server.sh` replaces
  upstream's `hardware/network.sh` (which exists to *retire* networkd in favour
  of NetworkManager): it keeps archinstall's `20-ethernet.network` when present,
  writes an equivalent DHCP `.network` for `en*`/`eth*` when not, points
  `/etc/resolv.conf` at resolved's stub and masks
  `systemd-networkd-wait-online`. The resolv.conf symlink is skipped when the
  path is a mount point, which is what it is inside the install chroot.
- **sshd hardening at install time.** `sshd-hardening-server.sh` writes
  `/etc/ssh/sshd_config.d/10-omarchy-server.conf` with `PasswordAuthentication no`,
  `KbdInteractiveAuthentication no`, `PermitRootLogin no`,
  `PermitEmptyPasswords no`, and validates the result with `sshd -G`. Upstream
  has no equivalent: on a desktop, sshd is turned on by the owner by hand. Here
  it is enabled unconditionally, so the hardening has to be part of the install.
- **`ufw limit 22/tcp`.** Deny incoming, allow outgoing, rate-limited ssh.
- **Addons.** `profile/server/addons/<name>.packages` plus an optional setup leaf
  under `install/server/addons/<name>.sh`, driven by `omarchy-server-addon`,
  which re-execs under sudo so the leaf runs as root exactly the way the install
  scripts do. Shipped: `docker`, `tailscale`, `cli-tools`, `dev`, `editor`,
  `net-tools`, `fwall`, `vm` (and later `secureboot`). Online it runs
  `pacman -Syu --needed`, not `-Sy` + `-S`: a fresh install has empty sync
  databases, and pulling one package into an unrefreshed system is exactly the
  partial upgrade Arch warns about.

### Acceptance

**23 of 23 checks pass**, plus a clean reboot check: the machine comes back, 0
failed units, and the profile marker, default target, cmdline, `ufw` rules and
listener set all survive. Item 23, `omarchy-update` completing, passed **with a
caveat** that is the subject of a later report.

The addon path was verified the other way round too, on VM `srv-docker`
installed with `mkcidata.sh --addons docker`: the orchestrator's
`Installing addons` phase applies it in the chroot against the ISO's offline
mirror, and the machine comes up with docker installed, `docker.socket` enabled
and the three drop-ins in `/etc`, without ever reaching the network.

## Evidence

- [`../pocs/server-install/reference/surface-before.txt`](../pocs/server-install/reference/surface-before.txt) — the "before" column, raw
- [`../pocs/server-install/reference/surface.txt`](../pocs/server-install/reference/surface.txt) — the "after" column, raw
- [`../pocs/server-install/README.md`](../pocs/server-install/README.md) — the surface table and the acceptance list
- [`../docs/packaging.md`](../docs/packaging.md) §2.3 — the dependency audit, `install/server/` and the addon table

## Findings and bugs

1. **The firewall rate-limited the test harness.** `ufw limit 22/tcp` drops a
   source that opens six connections within thirty seconds. Every helper in
   `pocs/` opened one ssh connection per command, so the harness rate-limited
   itself out and looked hung while the rule was doing exactly its job. `vm.sh`
   now multiplexes over a single connection (`ControlMaster`) and `wait-ssh`
   polls every 10 s instead of every 5 s. Worth knowing before wiring this
   profile into any automation that reconnects in bursts.
2. **`ufw allow ssh` and `ufw limit 22/tcp` are the same rule.** UFW keeps one
   rule per (port, protocol, direction), so an unconditional `allow` later in
   the install silently replaces the `limit` written earlier.
3. **`20-docker-dns.conf` is not inert without docker** — see the listener row
   above. A configuration file shipped "just in case" opened a socket.
4. **`systemd-oomd` was enabled but structurally unable to kill anything**: the
   upstream drop-in targets the session `app.slice`, which does not exist here.
   Replaced with an equivalent on `system.slice`.

## Limitations

- **The "after" raw file is from a later install.**
  `pocs/server-install/reference/surface.txt` was re-collected on 2026-08-29,
  after the identity work landed. Its package count and size are unchanged (220
  / 1402 MiB — identity added no packages, which the next report demonstrates),
  but its enabled-unit count reads **21**, not the 20 measured here: the extra
  unit is `omarchy-tty-palette.service`, which did not exist yet on 2026-08-28.
  The `+3` in the table above is the honest figure for this run; the
  `pocs/server-install/README.md` table quotes `+4` because it describes the
  current machine.
- **`surface.txt` is partly corrupted.** Its header line was overwritten by a
  stray `pacman` warning (`=== Attack surface — VM 'srwarning: database file for
  'core' does not exist…`), and two lines in the middle of the setuid list were
  replaced by the output of a `grep` run whose output file was also its input.
  The counts (`count: 16`) and every section total are intact and are what the
  table quotes; three individual setuid paths are unreadable in that file.
  `surface-before.txt` is clean. Worth re-running `surface.sh` to a fresh file.
- Boot time moved from 3.9 s to 4.8–6.6 s across these two ISOs, and the
  difference is entirely in the loader, which runs before a single package
  matters. The spread within one machine on consecutive boots is as large as the
  difference, so this was recorded as host noise rather than a conclusion.

## Next steps

- Give the machine an identity — a headless install currently looks like plain
  Arch — without adding a single package.
- Re-run `surface.sh` into a clean file.
