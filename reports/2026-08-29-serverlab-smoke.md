# serverlab smoke run

**Date:** 2026-08-29
**Subject:** the base acceptance list driven end to end by `serverlab`, from the same ISO the hand-written reports use
**Result:** **36 passed, 1 failed** on VM `srvlab`

## Scope

One machine of the `server` profile, installed headless from the ISO below by an
autoinstall `cidata` drive with no keyboard and no configurator, then measured
and put through the acceptance lists it was installed for.

## Environment

| | |
|---|---|
| VM | `srvlab`, QEMU/KVM `q35`, 4 vCPU, 8 GiB RAM, 40 GiB virtio disk |
| Firmware | OVMF 4M without Secure Boot |
| ISO | `omarchy-2026.08.29-x86_64-server-local.iso` |
| ISO size | 2.9 GiB (3149234176 bytes) |
| ISO sha256 | `38a61bca2954c14fb1b027784eba56b02ac00bc1e431c007195b508b097a27e9` |
| Autoinstall | `mkcidata.sh --profile server` |
| Run | `2026-08-29T12:09:55-03:00` |

## Method

```bash
serverlab pkgs build && serverlab pkgs test
serverlab iso build --profile server
serverlab lab up srvlab --profile server --iso omarchy-2026.08.29-x86_64-server-local.iso
serverlab lab test srvlab --suite base
serverlab report srvlab

# what those run underneath:
#   pocs/lab/mkcidata.sh --profile server
#   pocs/lab/vm.sh srvlab create|start|wait-ssh
#   pocs/server-install/collect.sh|surface.sh|acceptance*.sh|reboot-check.sh srvlab
```

`collect.sh` and `surface.sh` run **before** the acceptance lists: the
acceptance workload installs the `docker` addon and then runs an update, both
of which change the package set the measurements record. `reboot-check.sh`
runs last, because it takes the VM down.

## Results

### Acceptance — the base install

**36 passed, 1 failed.** Full evidence in [`acceptance.txt`](../pocs/server-install/reference/srvlab/acceptance.txt).

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 1 | default target is multi-user.target | **PASS** | `multi-user.target` |
| 2 | no sddm/hyprland/pipewire/plymouth installed | **PASS** | `graphical=0` |
| 3 | docker is absent from the base | **PASS** | `extras=0` |
| 4 | ssh with the cidata key works | **PASS** | `logged in as omarchy@omarchy from 10.0.2.2 37244 10.0.2.15 22` |
| 5 | password authentication is refused | **PASS** | `omarchy@localhost: Permission denied (publickey).` |
| 6 | root cannot log in over ssh | **PASS** | `PermitEmptyPasswords no` |
| 7 | networkd brought the link up by DHCP | **PASS** | `enp0s3 10.0.2.15/24` |
| 8 | resolved answers through the stub resolver | **PASS** | `dns-ok` |
| 9 | sudo works with the lab password | **PASS** | `root` |
| 10 | ufw is active and rate-limits 22 | **PASS** | `22/tcp (v6)                LIMIT IN    Anywhere (v6)              # omarchy-sshd` |
| 11 | nothing listens except ssh | **PASS** | `[::]:22` |
| 12 | factory snapshot exists and snapper is configured | **PASS** | `root` |
| 13 | /boot/limine.conf lists snapshot entries once a snapshot exists | **PASS** | `cmdline: root=PARTUUID=af197de0-c207-4c8f-8ee3-467e9b74ee6f zswap.enabled=0 rootflags=subvol=/@/.snapshots/1/…` |
| 14 | pacman -Qq \| wc -l in 150-260 | **PASS** | `in-range` |
| 15 | installed size and disk used < 3 GB | **PASS** | `under-3g` |
| 16 | boot to ssh under 20 s | **PASS** | `under-20s` |
| 17 | /proc/cmdline has console=ttyS0 and no quiet/splash/resume | **PASS** | `cmdline-ok` |
| 18 | zram active | **PASS** | `/dev/zram0 partition 3.9G   0B  100` |
| 19 | /etc/omarchy-profile is server | **PASS** | `server` |
| 20 | omarchy-version is 4.0.1-1 | **FAIL** | `4.0.1-5` |
| 21 | the hostname defaults to omarchy when cidata gives none | **PASS** | `default-hostname-ok` |
| 22 | os-release identifies the edition | **PASS** | `LOGO=omarchy` |
| 23 | /etc/issue carries the logo, the version and the machine fields | **PASS** | `issue-ok` |
| 24 | the serial console gets its own logo-free issue | **PASS** | `serial-issue-ok` |
| 25 | the VT palette unit ran and left the serial console alone | **PASS** | `palette-ok` |
| 26 | /boot/limine.conf is branded, waits 2 s and points at the wallpaper | **PASS** | `wallpaper_style: stretched` |
| 27 | the wallpaper is on the ESP | **PASS** | `/boot/limine-wallpaper.png: PNG image data, 1920 x 1080, 8-bit/color RGB, non-interlaced` |
| 28 | the login banner prints the machine identity | **PASS** | `ip        10.0.2.15/24` |
| 29 | the banner is wired into every login shell | **PASS** | `motd-wired` |
| 30 | fwall is not in the base | **PASS** | `fwall-absent` |
| 31 | omarchy-server-addon docker installs and runs a container | **PASS** | `To generate this message, Docker took the following steps:` |
| 32 | the docker addon opens only the container DNS stub | **PASS** | `2` |
| 33 | the update timer ships disabled and toggles | **PASS** | `shipped=disabled enabled=enabled disabled=disabled` |
| 34 | the free-space check uses the server threshold | **PASS** | `37G` |
| 35 | omarchy-server-update runs non-interactively to completion | **PASS** | `rc=0` |
| 36 | the unattended update pruned the cache and took a snapshot | **PASS** | `root,/,2,no,no,single,,2026-08-29 12:10:11,root,,number,4.0.1-5,` |
| 37 | no prompt was rendered during the unattended update | **PASS** | `no reboot was required` |

### Attack surface

| Metric | Value |
|---|---|
| Packages installed | **220** |
| Explicitly installed | **21** |
| Installed as a dependency | **199** |
| Installed size (MiB) | **1403** |
| `linux-firmware` (MiB) | **408** |
| Enabled unit files | **21** |
| Masked unit files | **13** |
| Listening sockets (`ss -ltnup`) | **6** |
| setuid/setgid binaries | **16** |
| Services running as root | **9** |

### Reboot survival

The machine came back over ssh after `systemctl reboot`.

| | |
|---|---|
| Verdict | rebooted: boot time moved from 2026-08-29 12:09:36 to 2026-08-29 12:10:19 |
| ssh | ssh answered 1s after the reboot request |
| Boot | Startup finished in 829ms (firmware) + 2.690s (loader) + 910ms (kernel) + 1.663s (userspace) = 6.094s |
| Failed units | 0 loaded units listed. |

## Evidence

- [`acceptance.txt`](../pocs/server-install/reference/srvlab/acceptance.txt) — the acceptance run, raw
- [`surface.txt`](../pocs/server-install/reference/srvlab/surface.txt) — the attack-surface measurements, raw
- [`reboot-check.txt`](../pocs/server-install/reference/srvlab/reboot-check.txt) — the reboot survival check
- [`packages-all.txt`](../pocs/server-install/reference/srvlab/packages-all.txt) — the package list of the installed machine
- [`boot-time.txt`](../pocs/server-install/reference/srvlab/boot-time.txt) — boot timing
- [`omarchy-install.log`](../pocs/server-install/reference/srvlab/omarchy-install.log) — the install log of the orchestrator

## Limitations

The tables were written by `serverlab report` from the evidence files listed
above. What the run does **not** prove is not in them, and belongs here:

- **The one failure was the test, not the machine.** Item 20 expected
  `omarchy-version` to read `4.0.1-1` and got `4.0.1-5`: the acceptance list
  pinned a `pkgrel` that moves every time the profile package is rebuilt, so it
  was guaranteed to fail on the fifth build of a package whose *version* was
  correct. Fixed in `fceb474` — the check now accepts any `pkgrel` of the
  expected release — and the base run in
  [`2026-08-29-update-without-reboot.md`](2026-08-29-update-without-reboot.md)
  is the same list passing whole.
- **The environment is one QEMU/OVMF virtual machine on one host.** No physical
  firmware, no real NIC, no disk that can be slow. Boot timing (item 16, and the
  6.1 s in the reboot table) is therefore an upper bound on a machine with no
  device probing to do, not a number to carry to hardware.
- **The surface numbers are a snapshot of one moment of the run.** `collect.sh`
  and `surface.sh` deliberately run *before* the acceptance workload, which
  installs the `docker` addon and then updates: the 220 packages and 1403 MiB
  are the base install, not what the machine looked like when the last check
  passed.
- **Nothing here exercises the update classifier or the MAC addons.** This
  machine was installed with no `--mac` and no Secure Boot, and its update
  (items 35–37) ran the pre-classifier `omarchy-server-update`.
