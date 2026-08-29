# Update without a reboot

**Date:** 2026-08-29
**Subject:** the server update path classifying its own transaction: what it restarted, what it deferred, and whether a reboot was genuinely required
**Result:** **44 passed, 0 failed** on VM `srvup`

## Scope

One machine of the `server` profile, installed headless from the ISO below by an
autoinstall `cidata` drive with no keyboard and no configurator, then measured
and put through the acceptance lists it was installed for.

## Environment

| | |
|---|---|
| VM | `srvup`, QEMU/KVM `q35`, 4 vCPU, 8 GiB RAM, 40 GiB virtio disk |
| Firmware | OVMF 4M without Secure Boot |
| ISO | `omarchy-2026.08.29-x86_64-server-local.iso` |
| ISO size | 2.9 GiB (3149234176 bytes) |
| ISO sha256 | `db5a0e10b34c54644d8b201396aec0fdd3623f8d76ff4fc11637b099b6c4b4b2` |
| Autoinstall | `mkcidata.sh --profile server` |
| Run | `2026-08-29T14:16:45-03:00` |

## Method

```bash
serverlab pkgs build && serverlab pkgs test
serverlab iso build --profile server
serverlab lab up srvup --profile server --iso omarchy-2026.08.29-x86_64-server-local.iso
serverlab lab test srvup --suite base
serverlab report srvup

# what those run underneath:
#   pocs/lab/mkcidata.sh --profile server
#   pocs/lab/vm.sh srvup create|start|wait-ssh
#   pocs/server-install/collect.sh|surface.sh|acceptance*.sh|reboot-check.sh srvup
```

`collect.sh` and `surface.sh` run **before** the acceptance lists: the
acceptance workload installs the `docker` addon and then runs an update, both
of which change the package set the measurements record. `reboot-check.sh`
runs last, because it takes the VM down.

## Results

### Acceptance — the base install

**44 passed, 0 failed.** Full evidence in [`acceptance.txt`](../pocs/server-install/reference/srvup/acceptance.txt).

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 1 | default target is multi-user.target | **PASS** | `multi-user.target` |
| 2 | no sddm/hyprland/pipewire/plymouth installed | **PASS** | `graphical=0` |
| 3 | docker is absent from the base | **PASS** | `extras=0` |
| 4 | ssh with the cidata key works | **PASS** | `logged in as omarchy@omarchy from 10.0.2.2 35010 10.0.2.15 22` |
| 5 | password authentication is refused | **PASS** | `omarchy@localhost: Permission denied (publickey).` |
| 6 | root cannot log in over ssh | **PASS** | `PermitEmptyPasswords no` |
| 7 | networkd brought the link up by DHCP | **PASS** | `enp0s3 10.0.2.15/24` |
| 8 | resolved answers through the stub resolver | **PASS** | `dns-ok` |
| 9 | sudo works with the lab password | **PASS** | `root` |
| 10 | ufw is active and rate-limits 22 | **PASS** | `22/tcp (v6)                LIMIT IN    Anywhere (v6)              # omarchy-sshd` |
| 11 | nothing listens except ssh | **PASS** | `only-ssh` |
| 12 | factory snapshot exists and snapper is configured | **PASS** | `root` |
| 13 | /boot/limine.conf lists snapshot entries once a snapshot exists | **PASS** | `cmdline: root=PARTUUID=ba95fa5c-cbb3-48e9-8249-b7800d2bde9b zswap.enabled=0 rootflags=subvol=/@/.snapshots/1/…` |
| 14 | pacman -Qq \| wc -l in 150-260 | **PASS** | `in-range` |
| 15 | installed size and disk used < 3 GB | **PASS** | `under-3g` |
| 16 | boot to ssh under 20 s | **PASS** | `under-20s` |
| 17 | /proc/cmdline has console=ttyS0 and no quiet/splash/resume | **PASS** | `cmdline-ok` |
| 18 | zram active | **PASS** | `/dev/zram0 partition 3.9G   0B  100` |
| 19 | /etc/omarchy-profile is server | **PASS** | `server` |
| 20 | omarchy-version reports the profile release (4.0.1-N) | **PASS** | `4.0.1-7` |
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
| 36 | the unattended update pruned the cache and took a snapshot | **PASS** | `root,/,2,no,no,single,,2026-08-29 14:17:04,root,,number,4.0.1-7,` |
| 37 | no prompt was rendered during the unattended update | **PASS** | `no reboot was required` |
| 38 | the update reported restarts, deferrals and a reboot verdict | **PASS** | `3` |
| 39 | a userspace-only transaction restarts services and requires no reboot | **PASS** | `marker=absent` |
| 40 | sshd is restarted by openssh's own alpm hooks, before the classifier sees it | **PASS** | `verdict=restarted-by-the-package` |
| 41 | an ssh session survives the sshd restart it triggers | **PASS** | `same-shell=yes still-connected=yes` |
| 42 | a firmware upgrade sets the reboot-required marker | **PASS** | `marker=set` |
| 43 | a kernel transaction sets the reboot marker only when the kernel moved | **PASS** | `verdict=reinstall-no-reboot` |
| 44 | kexec is an addon, absent from the base | **PASS** | `apparmor cli-tools dev docker editor fwall kexec net-tools secureboot selinux-tools selinux tailscale vm` |

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
| Verdict | rebooted: boot time moved from 2026-08-29 14:15:14 to 2026-08-29 14:17:24 |
| ssh | ssh answered 1s after the reboot request |
| Boot | Startup finished in 514ms (firmware) + 2.594s (loader) + 894ms (kernel) + 2.725s (userspace) = 6.728s |
| Failed units | 0 loaded units listed. |

## Evidence

- [`acceptance.txt`](../pocs/server-install/reference/srvup/acceptance.txt) — the acceptance run, raw
- [`surface.txt`](../pocs/server-install/reference/srvup/surface.txt) — the attack-surface measurements, raw
- [`reboot-check.txt`](../pocs/server-install/reference/srvup/reboot-check.txt) — the reboot survival check
- [`packages-all.txt`](../pocs/server-install/reference/srvup/packages-all.txt) — the package list of the installed machine
- [`boot-time.txt`](../pocs/server-install/reference/srvup/boot-time.txt) — boot timing
- [`omarchy-install.log`](../pocs/server-install/reference/srvup/omarchy-install.log) — the install log of the orchestrator

## Limitations

The tables were written by `serverlab report` from the evidence files listed
above. What the run does **not** prove is not in them, and belongs here.

**The interesting result is a negative one, and it is not in the tables.** The
classifier was written expecting sshd to be the headline case: the daemon that
gets replaced by every openssl update and that nobody dares restart. It is not.
On Arch, `10-openssh-mark-sshd-for-restart.hook` and
`70-openssh-restart-sshd.hook` restart sshd inside the same pacman transaction,
so by the time anything reads `/proc` the listener is already the new binary —
item 40 records that, and the check that expected the opposite is the one thing
this run changed. The service the classifier actually caught was
`systemd-resolved`, after openssl was replaced under it. The sshd deny-list
reasoning stays, because the guarantee does not: it is one distribution's
packaging decision, it covers one daemon, and a local drop-in can change
`KillMode` at any time — which is why item 41 measures the property on the
machine instead of quoting it.

**The reboot classes were not all provoked the same way.** Items 39 and 43 are
real transactions: openssl and openssh reinstalled, then `pacman -S linux`,
which rebuilt the initramfs, the UKI and `limine.conf` and still correctly
asked for no reboot because the running kernel was still an installed one.
Item 42 is a *recorded* transaction, `[ALPM] upgraded linux-firmware (…)` fed
through `OMARCHY_PACMAN_LOG`, because Arch had not moved firmware on the day
of the run. The classification logic it exercises is the same code path; the
pacman transaction behind it is not. A kernel that genuinely moves version is
therefore still unproven end to end — item 43 is written to pass on either
outcome and reports which one it got (`verdict=reinstall-no-reboot` here).

**Nothing here exercises the deny-list under load.** `deferred: none` on every
run means dbus, logind and the gettys were never among the processes running
replaced code during these transactions. The deny-list is therefore correct by
inspection and untested by measurement.

**`glibc` and `systemd` were not upgraded during this run.** The systemd branch
(`daemon-reexec`, and `/proc/1/exe` losing its `(deleted)` marker as the proof)
fires on this machine only because the code checks PID 1's state as well as the
package log; a run where systemd actually moves version has not happened yet.

**One QEMU/OVMF machine on one host.** No real firmware, no real NIC, no disk
that can be slow. The boot figures (6.7 s total, 514 ms firmware) are an upper
bound for a machine with no devices to probe, and they matter here because they
are the baseline the kexec measurement in the Secure Boot suite is compared
against — on hardware where POST alone is a minute, the same comparison looks
completely different.

**The surface numbers are the base install, not the end state.** `collect.sh`
and `surface.sh` run before the acceptance workload, which installs the docker
addon and then updates. 220 packages and 1403 MiB describe the machine as
installed.

### The kexec half, and where it stands

`--kexec` is not exercised on this machine at all: the base has no
`kexec-tools` (item 44), which is the addon boundary working as intended. It
was measured separately on a Secure Boot VM (`srvsb`), where it is hardest —
lockdown on, the boot image a signed UKI — and the result changed the
implementation:

* Handing the **UKI** to `kexec_file_load(2)` is refused. The kernel logs
  `PEFILE: Unsigned PE binary` and `Lockdown: kexec: kexec of unsigned images
  is restricted`, even though `sbctl verify` calls the same file signed and the
  firmware boots it: the signature layout systemd-ukify writes is not the one
  the kernel's `pefile` parser reads. The stock Arch `vmlinuz` is refused for
  the honest reason — Arch does not sign it.
* The kernel **inside** that UKI, extracted from its `.linux` section and
  re-signed with the machine's own key, is accepted. That is the premise this
  profile could not use for modules, proved: `.platform` — where a firmware-`db`
  certificate lands — is consulted by kexec's verification and not by module
  verification (`docs/secure-boot.md` §8).
* `systemctl kexec` after that load comes back with a new boot id, still
  `lockdown=integrity` and still `module.sig_enforce=1`.

`omarchy-server-kexec` therefore unpacks and re-signs rather than handing over
the UKI, and the Secure Boot suite records all three facts. **The reboot-time
comparison is not settled.** Three separate harness faults came out of trying to
measure it, all of them the lab's own firewall: `ufw limit 22` drops the seventh
connection from one source inside thirty seconds, a reboot kills the ssh master
so every probe is a new connection, a dropped connect *hangs* rather than
failing, and its error text was being accepted as a boot id. The probe now has a
timeout, a UUID check, twenty second spacing and a settle delay before each
sample — and the numbers taken by hand on this VM (kexec 9 s, firmware 8 s from
the client) say the honest thing anyway: with OVMF posting in 533 ms and Limine
waiting 2 s, a virtual machine has almost nothing for kexec to save. The 3.4 s
of firmware and loader it skips is the whole prize here. On hardware where POST
alone is a minute, the same measurement is a different conversation, and this
lab cannot have it.
