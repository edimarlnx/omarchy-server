# Unattended update, and desktop parity of the patched ISO builder

**Date:** 2026-08-29
**Subject:** making `omarchy update` complete with nobody to answer it, and proving the patch series does not change a desktop install
**Result:** **37/37** acceptance checks on a fresh install; the desktop parity run installs the **same 942 packages** as the untouched reference

## Scope

Two pieces of work that landed together because the second is what makes the
first safe to ship.

`omarchy update` asks three questions — start?, remove orphans?, reboot? — and a
headless machine has nobody at the console for any of them. Unattended it
stalled on each one until sudo timed out, then "finished" having pruned nothing
and snapshotted nothing, with `pam_faillock` locking the account for two minutes
on the way out.

The fix touches a command the **desktop** also runs. So the second half of this
report is the measurement that says a desktop installed from this tree is the
machine an upstream ISO installs.

## Environment

| | |
|---|---|
| Server run | fresh install from the rebuilt server ISO into VM `srv`; QEMU/KVM `q35`, 4 vCPU, 8 GiB, 40 GiB virtio, OVMF 4M without Secure Boot |
| Server kernel | `7.1.11-arch1-1`; `omarchy-version` `4.0.1-1` |
| Parity reference | VM `ref`, snapshot `reference`, installed 2026-08-28 from the official `omarchy-4.0.1.iso` and left untouched |
| Parity run | VM `ref2`, fresh 40 GiB disk, ISO `omarchy-2026.08.29-x86_64-quattro.iso` built by `./iso/build.sh --profile desktop` (7m03s, 5.9 GiB) |
| Parity `cidata` | `pocs/lab/out/cidata.iso` — **the same file, byte for byte**, for both installs |
| Extra VM | `srvu`, installed with `mkcidata.sh --profile server --unattended-updates` |

`--profile desktop` builds **without** `--local-source`: the desktop's Omarchy
packages come from the published `[omarchy]` mirror exactly as a stock
`omarchy-iso-make` run takes them, so the only thing separating that ISO from an
upstream one is this repository's patch series.

## Method — the update

Two runtime patches, applied in `prepare()` of `omarchy-server`:

- **`0005-update-noninteractive.patch`** decides "unattended" from `-y`, from
  `OMARCHY_NONINTERACTIVE=1`, or from stdin not being a terminal — **before** the
  re-exec — and makes the two remaining prompts honour the answer. Not
  server-specific: with a terminal and no `-y` the desktop path is unchanged.
- **`0006-update-free-space-server.patch`** asks for 2 GiB instead of 10 on the
  `server` profile. Every other profile keeps the 10.

And one entry point, `omarchy-server-update`, which re-execs under `sudo` and
runs `omarchy-update -y` with `OMARCHY_NONINTERACTIVE=1`, plus the toggle for
`omarchy-server-update.timer` (`OnCalendar=daily`, `RandomizedDelaySec=4h`,
`Persistent=true`, **shipped disabled**).

## Results — the update

**37 of 37 acceptance checks pass.** The four that are new:

| # | Item | Evidence |
|---|---|---|
| 34 | the timer ships disabled and toggles | `shipped=disabled enabled=enabled disabled=disabled` |
| 35 | the free-space check uses the server threshold | `+ required_gib=2` under `bash -x`, `rc=0`, 37G available |
| 36 | the update runs non-interactively to completion as root | `rc=0`, stdin closed, nothing to answer |
| 37 | it pruned and snapshotted, with no prompt in the transcript | `pruned=yes snapshotted=yes`; `confirm-prompts=0`; `no reboot was required` |

Transcript excerpt from the run (control sequences stripped):

```
Prune package cache
==> no candidate packages found for pruning
Create system snapshot
Snapshots can be selected during boot.
Update Arch signing keys
Keys are correct
Update system packages
:: Synchronizing package databases...
   core / extra / multilib / omarchy / omarchy-server  … up to date
:: Starting full system upgrade...
   there is nothing to do
Restarting shell
All plugins have been reloaded
Omarchy shell config not found: /usr/share/omarchy/shell
rc=0
```

and the snapper list afterwards, showing the snapshot the run created:

```
root,/,0,no,no,single,,,root,,,current,
root,/,1,no,no,single,,2026-08-29 04:32:44,root,,,acceptance,
root,/,2,no,no,single,,2026-08-29 04:32:59,root,,number,4.0.1-1,
```

### Root cause

**The `script` re-exec makes every `-t` test lie.** `omarchy-update` re-execs
itself under `script -qefc … /tmp/omarchy-update.log` to capture a transcript,
and `script` allocates a pseudo-terminal. Everything below that line therefore
sees a terminal nobody is sitting at — which is exactly why
`omarchy-update-orphan-pkgs`'s `[[ ! -t 0 || ! -t 1 ]]` guard never fired in an
unattended run. Deciding the question *before* the re-exec is the fix.

**`omarchy-update-restart` never honoured the flag at all.** Its `gum confirm`
sat there with the whole update already done. It now reports what it would have
asked and carries on exactly as a declined prompt does, leaving the
reboot-required state for the next login. A reboot taken without an answer is a
reboot taken out from under whatever the machine was doing.

**Running as root is the other half.** Every privileged step shells out to
`sudo`, and `sudo` never asks root for a password. Three things a root-run
update needs that neither `sudo` nor systemd supplies, and where each comes from:

| Need | Why | Source |
|---|---|---|
| `$OMARCHY_PATH` | Omarchy commands read it and never default it themselves | `Environment=` in the unit |
| `$HOME` | `omarchy-migrate` keeps per-user markers under `~/.local/state`, and the restart flags live there | `Environment=HOME=/root` |
| root's migration markers | the packages pre-mark every migration in `/etc/skel`; root predates `/etc/skel`, so without them `omarchy-migrate` replays ~90 desktop migrations against `/root` on the first run | `install/server/root-migration-state-server.sh` |

## Results — desktop parity

| Measurement | Reference (`ref`) | Parity run (`ref2`) | Verdict |
|---|---|---|---|
| Packages (`pacman -Qq`) | 942 | 942 | **identical**, name sets equal in both directions |
| Explicitly installed | 159 | 159 | identical set |
| Enabled unit files | sddm, cups(+browsed/.path/.socket), avahi, bluetooth, power-profiles-daemon, NetworkManager(+dispatcher), docker.socket, … | same | identical set |
| Default target | `graphical.target` | `graphical.target` | same |
| `lua51` / `luarocks` / `omarchy-nvim` | present | present | same — the empty-nvim-target branch is server-only |
| btrfs subvolumes | `@ @home @log @pkg swap .snapshots @factory` + machines/portables | same | identical |
| Swapfile / hibernation | `/swap/swapfile`, `resume=`, `resume_offset=` | same | same — `configure_hibernation` is skipped only on `server` |
| Kernel cmdline | `zswap.enabled=0 … quiet splash loglevel=0 …` | same modulo PARTUUID and resume offset | identical |
| `limine.conf` | `interface_branding: Omarchy Bootloader`, `#timeout: 3` | same | identical — the `Omarchy <Profile>` renaming is skipped for `desktop` |
| `mkinitcpio.conf.d` | `omarchy_hooks / omarchy_resume / thunderbolt_module` | same | identical |
| `/etc/pacman.conf` | `[omarchy] SigLevel = Optional TrustAll` | same | identical — no patch touches `SigLevel` |
| `os-release` | `NAME=Omarchy`, `ID=omarchy` | same | identical |
| Installed size | 8079.57 MiB | 8081.75 MiB | **+2.18 MiB** |
| Boot | 12.2 s | 11.1 s | host noise |
| Failed units | 0 | 0 | — |

**The one difference.** `mise-bin` grew from 96.36 MiB to 98.52 MiB between the
two runs — +2.16 MiB of the +2.18 MiB total. It is an upstream package update:
the version resolved from the mirror on 2026-08-29 is not the one resolved on
2026-08-28. Nothing in this repository selects, pins or patches it.

**One fix, found by this measurement.** The first parity run came out with an
unowned `/etc/omarchy-profile` containing `desktop`, written unconditionally by
the orchestrator's `_write_profile_marker`. Nothing on a desktop reads it, but it
was the one file that made a patched build differ from an upstream one. The
marker is now written for **named profiles only**; `ref2` has no such file, and
the server install still has one.

**One justified difference, kept.**
`0009-orchestrator-default-hostname.patch` changes the fallback used when the
autoinstall drive carries no `hostname` key from archinstall's `archlinux` to
`omarchy`. It is inert for any install that names its host, including this one.
It is kept because `omarchy` is what the ISO's own interactive configurator
offers, so the patch makes the autoinstall path agree with the interactive one
instead of quietly producing a machine called `archlinux`. This is the **only**
desktop-path behaviour change in the series.

## Evidence

- [`../pocs/server-install/reference/acceptance.txt`](../pocs/server-install/reference/acceptance.txt) — items 34–37 with their raw output, and `=== 37 passed, 0 failed ===`
- [`../pocs/lab/reference/desktop-parity.md`](../pocs/lab/reference/desktop-parity.md) — the parity table, field by field, and how to reproduce it
- [`../docs/iso-server.md`](../docs/iso-server.md) §3.1 — the full update audit, §8 — the parity summary
- [`../pocs/server-install/README.md`](../pocs/server-install/README.md) — "The update path"

## Findings and bugs

1. **`pam_faillock` made the failure mode worse.**
   `increase-lockout-limit-server.sh` raises it to `deny=10 unlock_time=120`, and
   the `preauth silent` line means a locked account is indistinguishable from a
   wrong password. A stalled unattended run left the account locked for two
   minutes with no explanation. Running as root never consults it.
2. **`omarchy-update-status` calls `omarchy-shell`, which is unusable without
   Quickshell** — and that one turned out to be harmless: `omarchy-shell -q`
   returns 0 when `$OMARCHY_PATH/shell/shell.qml` is missing, which it is,
   because the server runtime ships no `shell/`. The graphical status refresh
   silently no-ops. No patch was needed.
3. **The 10 GiB free-space floor is sized for an 8 GiB desktop install** and
   refuses an update on a 1.2 GiB server with 37 GiB free.
4. **`_write_profile_marker` wrote a marker on desktops too** — see above.

## Limitations

- **The timer has no captured journal.** Items 34–37 exercise
  `omarchy-server-update` directly and the toggle, and VM `srvu` was installed
  with `--unattended-updates`, but no transcript of a **timer-triggered** run was
  collected. `journalctl -u omarchy-server-update` is where one would be.
- Item 36's run had nothing to do: the machine was fresh, so `pacman -Syu`
  reported "there is nothing to do" and the prune found no candidates. The test
  proves the run completes with no prompt; it does not prove the behaviour of a
  large upgrade.
- **The update's last step still talks about a shell**, printing "Restarting
  shell / All plugins have been reloaded" followed by "config not found". Cosmetic
  on a headless machine, and the one piece of the update path left untouched,
  because silencing it means adding a server branch to a command that has none.
- The parity comparison is field by field, not file by file: the two reference
  directories were written by different collectors, so their `system.txt`,
  `storage.txt` and `packages-biggest.txt` differ in layout.

## Next steps

- Capture a timer-triggered run from the journal on `srvu`.
- Re-run parity whenever the patch series grows a branch that is not gated on the
  profile.
