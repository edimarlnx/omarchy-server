# Headless install of the server profile, measured

**Date:** 2026-08-29
**Subject:** one `server` machine installed from a `cidata` drive and put through the acceptance lists it was installed for
**Result:** **6 passed, 0 failed** on VM `srv`

## Scope

One machine of the `server` profile, installed headless from the ISO below by an
autoinstall `cidata` drive with no keyboard and no configurator, then measured
and put through the acceptance lists it was installed for.

## Environment

| | |
|---|---|
| VM | `srv`, QEMU/KVM `q35`, 4 vCPU, 8 GiB RAM, 40 GiB virtio disk |
| Firmware | OVMF 4M without Secure Boot |
| ISO | `omarchy-2026.08.29-x86_64-server-local.iso` |
| ISO size | 2.9 GiB (3149234176 bytes) |
| ISO sha256 | `0000000000000000000000000000000000000000000000000000000000000000` |
| Autoinstall | `mkcidata.sh --profile server` |
| Run | `2026-08-29T04:32:43-03:00` |

## Method

```bash
serverlab pkgs build && serverlab pkgs test
serverlab iso build --profile server
serverlab lab up srv --profile server --iso omarchy-2026.08.29-x86_64-server-local.iso
serverlab lab test srv --suite base
serverlab report srv

# what those run underneath:
#   pocs/lab/mkcidata.sh --profile server
#   pocs/lab/vm.sh srv create|start|wait-ssh
#   pocs/server-install/collect.sh|surface.sh|acceptance*.sh|reboot-check.sh srv
```

`collect.sh` and `surface.sh` run **before** the acceptance lists: the
acceptance workload installs the `docker` addon and then runs an update, both
of which change the package set the measurements record. `reboot-check.sh`
runs last, because it takes the VM down.

## Results

### Acceptance — the base install

**6 passed, 0 failed.** Full evidence in [`acceptance.txt`](../pocs/lab/out-srv/evidence/acceptance.txt).

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 1 | default target is multi-user.target | **PASS** | `multi-user.target` |
| 2 | no sddm/hyprland/pipewire/plymouth installed | **PASS** | `graphical=0` |
| 3 | docker is absent from the base | **PASS** | `extras=0` |
| 4 | ssh with the cidata key works | **PASS** | `logged in as omarchy@omarchy from 10.0.2.2 50312 10.0.2.15 22` |
| 5 | password authentication is refused | **PASS** | `omarchy@localhost: Permission denied (publickey).` |
| 6 | root cannot log in over ssh | **PASS** | `PermitEmptyPasswords no` |

### Attack surface

| Metric | Value |
|---|---|
| Packages installed | **320** |
| Explicitly installed | **57** |
| Installed as a dependency | **263** |
| Installed size (MiB) | **2344** |
| `linux-firmware` (MiB) | **408** |
| Enabled unit files | **17** |
| Masked unit files | **5** |
| Listening sockets (`ss -ltnup`) | **8** |
| setuid/setgid binaries | **19** |
| Services running as root | **12** |

### Reboot survival

The machine came back over ssh after `systemctl reboot`.

| | |
|---|---|
| Verdict | rebooted: boot time moved from 2026-08-29 04:32:28 to 2026-08-29 04:33:09 |
| ssh | ssh answered 1s after the reboot request |
| Boot | Startup finished in 628ms (firmware) + 2.649s (loader) + 847ms (kernel) + 1.660s (userspace) = 5.785s |
| Failed units | 0 loaded units listed. |

## Evidence

- [`acceptance.txt`](../pocs/lab/out-srv/evidence/acceptance.txt) — the acceptance run, raw
- [`surface.txt`](../pocs/lab/out-srv/evidence/surface.txt) — the attack-surface measurements, raw
- [`reboot-check.txt`](../pocs/lab/out-srv/evidence/reboot-check.txt) — the reboot survival check

## Limitations

_Written by `serverlab report` from the evidence files listed above._ The tables are the
run; what the run does **not** prove is not in them, and belongs here:

- TODO: what this environment does not cover (hardware, firmware, network).
- TODO: which numbers are host noise rather than a conclusion.
- TODO: the bugs this run found, and what changed because of them.
