# Validation record

The profile in this repository is in its testing phase. Every claim it makes —
how small the base is, what listens, whether an install survives a reboot,
whether Secure Boot really enforces — comes from a run that was measured, not
from an intention. This directory is the published record of those runs: one
report per validation, written from the raw artifacts collected at the time.

Each report is self-contained. It states the scope, the exact environment (ISO
file, VM shape, firmware), the commands used, the results in tables, links to
the raw evidence under `pocs/`, and — deliberately — the bugs found and the
limits of what the run proves. Where a number moved between runs, the report
says so rather than quietly picking one.

The reports are a record, not documentation. The design lives in `docs/`; the
scripts and artifacts live in `pocs/`.

## Reports, newest first

| Date | Report | Subject | Result |
|---|---|---|---|
| 2026-08-29 | [The cloud image, built and booted](2026-08-29-cloud-image.md) | one qcow2 generalized from an ordinary install, launched onto a 40 GiB disk with a NoCloud seed and nothing else | 65 passed, 1 failed |
| 2026-08-29 | [Transactional updates, and the case against an immutable root](2026-08-29-transactional-updates.md) | an update that never writes to the running root: the snapshot, the subvolume swap that selects it, rollback, and what a read-only `/` would cost on top | 63 passed, 0 failed (34 of them transactional); mode B: not now |
| 2026-08-29 | [kexec under Secure Boot](2026-08-29-secure-boot-kexec.md) | whether a machine that boots a signed UKI under lockdown can jump straight into the next kernel, and what that is worth | 29 passed, 0 failed |
| 2026-08-29 | [A kernel update under SELinux enforcing](2026-08-29-selinux-kernel-update.md) | a kernel transaction, a UKI rebuild and the disable path on an enforcing machine; and the root cause of the mkinitcpio failure §11.5 could not explain | 103 passed, 1 failed |
| 2026-08-29 | [Update without a reboot](2026-08-29-update-without-reboot.md) | the server update path classifying its own transaction: what it restarted, what it deferred, and whether a reboot was genuinely required | 44 passed, 0 failed |
| 2026-08-29 | [serverlab smoke run](2026-08-29-serverlab-smoke.md) | the base acceptance list driven end to end by `serverlab`, from the same ISO the hand-written reports use | 36 passed, 1 failed |
| 2026-08-29 | [Mandatory access control](2026-08-29-mandatory-access-control.md) | SELinux and AppArmor built, installed and run against the same workload, permissive then enforcing; §10 re-validates SELinux on a fresh install after the lockout fixes, the addon split and the lockstep check; §11 gives the operator an administrative role (`%wheel` → `staff_u`, sudo → `sysadm_t`) | AppArmor 24/24 in enforce. SELinux 45/45 permissive and **49/49 enforcing, zero denials in both**, on a fresh install; `sudo` reaches `sysadm_t` and enforcing is a two-way door over ssh. Cost: +9 packages / +99 MiB, and 23 locally-maintained policy blocks |
| 2026-08-29 | [ZFS as a signed kernel module](2026-08-29-zfs-signed-module.md) | whether an out-of-tree module signed by a key this profile controls loads under Secure Boot | it does not; the work is paused on that answer |
| 2026-08-29 | [Secure Boot](2026-08-29-secure-boot.md) | own-keys Secure Boot, enrolled during a headless install | 24 passed, 0 failed |
| 2026-08-29 | [Unattended update and desktop parity](2026-08-29-unattended-update-and-desktop-parity.md) | an update with nobody to answer it; the patch series measured against a stock desktop | 37/37; same 942 packages as the reference |
| 2026-08-29 | [Package repository](2026-08-29-package-repository.md) | the signed `[omarchy-server]` repository on GitHub Releases | 13/13 including two tamper cases; release live |
| 2026-08-29 | [Omarchy identity](2026-08-29-omarchy-identity.md) | bootloader, console, palette, MOTD, `os-release` — at zero new packages | 33/33; still 220 packages / 1402 MiB |
| 2026-08-28 | [Lean secure base](2026-08-28-lean-secure-base.md) | cutting the base to what a headless machine needs, and the addon mechanism | 23/23; 320 → 220 packages, 2344 → 1402 MiB |
| 2026-08-28 | [Server profile ISO and first install](2026-08-28-server-profile-iso-and-install.md) | `--profile server` in the ISO builder, and the first headless install | 17/17; orchestrator 30.6 s |
| 2026-08-28 | [Server package build](2026-08-28-server-package-build.md) | the three profile packages plus `fwall`: layout, sizes, container test | 66 assertions, all pass |
| 2026-08-28 | [Desktop reference install](2026-08-28-desktop-reference-install.md) | stock Omarchy 4.0.1 desktop, the baseline everything is compared against | 942 packages, 8.08 GiB, 12.2 s boot |

## A note on the raw artifacts

`pocs/lab/reference/` and `pocs/server-install/reference/` hold the output of
the **most recent** run of each collector, not a history: a later run overwrites
an earlier one in place. Reports written from an earlier run therefore quote
numbers that the files no longer contain, and say so where that is the case.
