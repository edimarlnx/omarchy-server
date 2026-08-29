# kexec under Secure Boot

**Date:** 2026-08-29
**Subject:** whether a machine that boots a signed UKI under lockdown can jump straight into the next kernel, and what that is worth
**Result:** **29 passed, 0 failed** on VM `srvsb`

## Scope

One machine of the `server` profile, installed headless from the ISO below by an
autoinstall `cidata` drive with no keyboard and no configurator, then measured
and put through the acceptance lists it was installed for (Secure Boot with keys the machine generated for itself).

## Environment

| | |
|---|---|
| VM | `srvsb`, QEMU/KVM `q35`, 4 vCPU, 8 GiB RAM, 40 GiB virtio disk |
| Firmware | OVMF 4M **secboot** variable store, put into Setup Mode before the first boot |
| ISO | `omarchy-2026.08.29-x86_64-server-local.iso` |
| ISO size | 2.9 GiB (3149234176 bytes) |
| ISO sha256 | `0d91fb501b97188c6559a11a84c595dc08307fcf4fa252805058eba0f88dae8f` |
| Autoinstall | `mkcidata.sh --profile server --secureboot` |
| Run | `2026-08-29T15:41:15-03:00` |

## Method

```bash
serverlab pkgs build && serverlab pkgs test
serverlab iso build --profile server
serverlab lab up srvsb --profile server --secboot --iso omarchy-2026.08.29-x86_64-server-local.iso
serverlab lab test srvsb --suite all
serverlab report srvsb

# what those run underneath:
#   pocs/lab/mkcidata.sh --profile server --secureboot
#   pocs/lab/vm.sh srvsb create|start|wait-ssh
#   pocs/server-install/collect.sh|surface.sh|acceptance*.sh|reboot-check.sh srvsb
```

`collect.sh` and `surface.sh` run **before** the acceptance lists: the
acceptance workload installs the `docker` addon and then runs an update, both
of which change the package set the measurements record. `reboot-check.sh`
runs last, because it takes the VM down.

## Results

### Acceptance — Secure Boot

**29 passed, 0 failed.** Full evidence in [`acceptance-secureboot.txt`](../pocs/server-install/reference/srvsb/acceptance-secureboot.txt).

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 1 | sbctl reports Secure Boot enabled with our keys | **PASS** | `Vendor Keys:	microsoft` |
| 2 | sbctl says the firmware is out of setup mode | **PASS** | `}` |
| 3 | sbctl owns the installed keys | **PASS** | `}` |
| 4 | the SecureBoot EFI variable reads 1 | **PASS** | `1` |
| 5 | the kernel saw secure boot at handover | **PASS** | `[    0.004422] Secure boot enabled` |
| 6 | every EFI binary on the ESP is signed | **PASS** | `unsigned=0` |
| 7 | the Limine binary, the fallback and the UKI are all in the signed set | **PASS** | `✓ /boot/EFI/limine/limine_x64.efi is signed` |
| 8 | limine.conf points at the UKI and its recorded hash matches the file | **PASS** | `hash-ok` |
| 9 | the cmdline the kernel booted with carries the lockdown options | **PASS** | `root=PARTUUID=e616c218-2b85-4f0b-ba64-6d6dfebf204b zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs  lo…` |
| 10 | lockdown is in integrity mode | **PASS** | `none [integrity] confidentiality` |
| 11 | module signature enforcement is on | **PASS** | `Y` |
| 12 | the cmdline drop-in appends to the profile defaults | **PASS** | `KERNEL_CMDLINE[default]+=" lockdown=integrity module.sig_enforce=1"` |
| 13 | the serial console survived on the cmdline | **PASS** | `root=PARTUUID=e616c218-2b85-4f0b-ba64-6d6dfebf204b zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs  lo…` |
| 14 | the keys are on the root filesystem, not on the ESP | **PASS** | `esp-key-files=0` |
| 15 | no account but root can read the key material | **PASS** | `ls: cannot open directory '/var/lib/sbctl': Permission denied` |
| 16 | an unsigned module is refused | **PASS** | `[   16.941203] Loading of unsigned module is rejected` |
| 17 | a stock in-tree module still loads | **PASS** | `UKI before the kernel reinstall: ea4013187e2ef0a7c665c0c52926df6b…` |
| 18 | reinstalling the kernel rebuilds the UKI | **PASS** | `uki-rebuilt` |
| 19 | the rebuilt UKI is signed | **PASS** | `unsigned=0` |
| 20 | limine.conf still records the hash of the rebuilt, signed UKI | **PASS** | `hash-ok` |
| 21 | limine-snapper-sync left the config consistent | **PASS** | `boot id after:  df778488-71ed-4be1-a2d5-128fbad0a401` |
| 22 | the machine actually rebooted | **PASS** | `boot_id fa333730-c197-4698-900f-9b5f0023ad08 -> df778488-71ed-4be1-a2d5-128fbad0a401` |
| 23 | the machine came back with Secure Boot still enforcing | **PASS** | `7.1.11-arch1-1` |
| 24 | and it is still refusing unsigned modules | **PASS** | `=== kexec ===` |
| 25 | the kexec addon installs kexec-tools and finds the signed UKI | **PASS** | `lockdown: none [integrity] confidentiality` |
| 26 | kexec_file_load refuses the UKI and accepts the kernel inside it | **PASS** | `[    6.835773] Lockdown: kexec: kexec of unsigned images is restricted; see man kernel_lockdown.7` |
| 27 | and it was the unpacked UKI that the kernel took | **PASS** | `kexec reboot: downtime 2s \| client 5s (10s resolution) \| boot_id 2517cf8b-7170-4395-8c53-b75304334ab3 -> 2174…` |
| 28 | both reboot paths came back, and were measured | **PASS** | `kexec reboot: downtime 2s \| client 5s (10s resolution) \| boot_id 2517cf8b-7170-4395-8c53-b75304334ab3 -> 2174…` |
| 29 | lockdown and module signing survived the kexec | **PASS** | `7.1.11-arch1-1` |

### Attack surface

| Metric | Value |
|---|---|
| Packages installed | **224** |
| Explicitly installed | **22** |
| Installed as a dependency | **202** |
| Installed size (MiB) | **1416** |
| `linux-firmware` (MiB) | **408** |
| Enabled unit files | **21** |
| Masked unit files | **13** |
| Listening sockets (`ss -ltnup`) | **6** |
| setuid/setgid binaries | **17** |
| Services running as root | **9** |

### Reboot survival

The machine came back over ssh after `systemctl reboot`.

| | |
|---|---|
| Verdict | rebooted: boot time moved from 2026-08-29 15:42:05 to 2026-08-29 15:42:14 |
| ssh | ssh answered 0s after the reboot request |
| Boot | Startup finished in 647ms (firmware) + 2.717s (loader) + 930ms (kernel) + 2.646s (userspace) = 6.941s |
| Failed units | 0 loaded units listed. |

## Evidence

- [`acceptance-secureboot.txt`](../pocs/server-install/reference/srvsb/acceptance-secureboot.txt) — the acceptance run, raw
- [`surface.txt`](../pocs/server-install/reference/srvsb/surface.txt) — the attack-surface measurements, raw
- [`reboot-check.txt`](../pocs/server-install/reference/srvsb/reboot-check.txt) — the reboot survival check
- [`packages-all.txt`](../pocs/server-install/reference/srvsb/packages-all.txt) — the package list of the installed machine
- [`boot-time.txt`](../pocs/server-install/reference/srvsb/boot-time.txt) — boot timing
- [`omarchy-install.log`](../pocs/server-install/reference/srvsb/omarchy-install.log) — the install log of the orchestrator

## Limitations

The tables were written by `serverlab report` from the evidence files listed
above. The rest of this section is not generated, and it is where the run
actually lives.

### The keyring answer, which is the good news

Module signing on this profile is defeated by a keyring boundary: a certificate
enrolled in the firmware `db` lands in `.platform`, and module verification
consults only `.builtin` and `.machine` (`docs/secure-boot.md` §8). The question
this run set out to answer was whether kexec has the same problem. **It does
not.** kexec's in-kernel PE verification accepts `.platform`, so the key that
cannot sign a module on this machine can sign the image it kexecs into — item 26.

### The bad news, which is about the UKI rather than the keyring

Handing the UKI itself to `kexec_file_load(2)` is refused:

```
kexec_file_load failed: Operation not permitted
PEFILE: Unsigned PE binary
Lockdown: kexec: kexec of unsigned images is restricted
```

`sbctl verify` calls that same file signed and the firmware boots it. The
signature layout systemd-ukify produces is simply not the one the kernel's
`pefile` parser reads. The stock Arch `vmlinuz` is refused for the honest
reason — Arch does not sign it. So `omarchy-server-kexec` unpacks the UKI,
signs the extracted `.linux` with the machine's own key, and loads that
(item 27). Nothing is trusted that was not trusted before: same bytes, same
key, and the kernel still verifies before accepting.

### What it is worth here: nothing, and that is the finding

| Path | Guest downtime | Client |
|---|---|---|
| firmware reboot | 2 s | 6 s |
| kexec reboot | 2 s | 5 s |

At one second granularity the two are **indistinguishable**, and a second run
of the same suite put the client figures the other way round (firmware 5 s,
kexec 6 s), which is the same statement said twice. That is the expected answer
and it is why `kexec` is an addon rather than a default: OVMF posts in about
half a second and the Limine menu is the only other pre-kernel cost, so there is
essentially no firmware here to skip. The case for `--kexec` is server hardware
whose POST is tens of seconds, and **this lab cannot demonstrate it.** Nobody
should read these two rows as a reason to install the addon or to leave it out.

### The bug this run found, and it was in the thing being tested

The first three attempts at the timing table failed with the machine never
coming back, and the cause was a defect in `omarchy-server-kexec` itself, not
in the harness:

A UKI *may* carry a `.cmdline` section. On this profile it does not — `objdump
-h` shows `.linux` and `.initrd` and nothing else, because limine-entry-tool
passes the command line from `limine.conf`. The load path read that absent
section, got an empty string, and a `[[ -n $cmdline ]]` guard **silently
dropped** `--command-line`. The loaded kernel had no `root=`, so it could not
mount anything, and no `console=`, so it died without a word.

What turned that into a brick rather than a failed experiment is a property of
kexec worth knowing on its own: **a loaded image redirects an ordinary
`systemctl reboot` into itself.** A machine that had merely been *asked about*
kexec could no longer reboot. Its own journal is the evidence — a complete,
tidy shutdown, unmounting `/boot` and `/home`, and then silence, with no
`reboot: Restarting system` on the serial console and no second Limine.

`/proc/cmdline` is the source now, a real `.cmdline` section still wins where
one exists, and with neither the command refuses to load rather than leaving a
trap. `load` and `status` both say out loud that an image is loaded.

### And a test that passed while the machine was bricked

The run that found the brick reported **29 passed, 0 failed**. "The machine came
back from a kexec" had been implemented as the *absence* of the phrase "did not
come back", so it passed on a run where the firmware reboot never returned, the
kexec line's starting boot id was the string
`kex_exchange_identification: read: Connection reset by peer`, and the downtime
computed from that was 784 seconds. The check now requires both timing lines to
carry a downtime and two real UUIDs. A green that survives a bricked machine is
worse than no check at all, and this one is only visible because the number it
printed was absurd.

### What this run does not prove

- **One VM, one firmware.** OVMF in setup mode with keys this machine generated
  for itself. No vendor firmware, no real `db`, no BMC.
- **The kexec chain is one hop deep.** Each kexec is handed `/proc/cmdline`, so
  a chain should stay identical, but only one jump was taken.
- **`--kexec` was not exercised through the update path.** Items 25-29 drive
  `omarchy-server-kexec` directly; `omarchy-server-update --kexec` deciding for
  itself that a reboot is required and taking it that way is untested.
- **The base and SELinux reports of the same day were taken at pkgrel 7**, this
  one at pkgrel 8. The only difference is `omarchy-server-kexec`, which neither
  of those suites calls.
