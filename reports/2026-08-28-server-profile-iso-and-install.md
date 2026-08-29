# First server ISO and first headless install

**Date:** 2026-08-28
**Subject:** `iso/build.sh --profile server`, and the machine it installs with no keyboard
**Result:** ISO builds, installs unattended in **30.6 s** of orchestrator time, **17/17** acceptance checks pass

## Scope

The first end-to-end proof that a *profile* is a real thing in the upstream ISO
builder: a `--profile server` flag that swaps the package targets, an
orchestrator that knows to skip the desktop phases, an autoinstall drive that
can name the profile, and a VM that comes up headless and answers ssh.

The package set at this point is still **parity with the desktop edition** minus
the graphical stack. Trimming it is the next piece of work, not this one.

## Environment

| | |
|---|---|
| ISO | `omarchy-2026.08.28-x86_64-server-local.iso`, **2,937,683,968 bytes (2.74 GiB)**, built by `./iso/build.sh` from this repository's sources |
| Upstream | `omacom-io/omarchy-iso` cloned into `upstream/`, copied to `iso/scratch/` and `git reset --hard` on every build; patches applied on top, upstream never edited |
| VM | QEMU/KVM `q35`, 4 vCPU, 8 GiB RAM, 40 GiB virtio disk, user-mode networking with ssh forwarded to localhost |
| Firmware | OVMF 4M, without Secure Boot |
| Autoinstall | `cidata` from `mkcidata.sh --profile server` |

## Method

```bash
./iso/build.sh
./pocs/lab/mkcidata.sh --profile server --out pocs/lab/out-server
export LAB_OUT=$PWD/pocs/lab/out-server
./pocs/lab/vm.sh srv create --disk-gb 40
./pocs/lab/vm.sh srv start --iso iso/release/<iso> --cidata "$LAB_OUT/cidata.iso"
./pocs/lab/vm.sh srv wait-ssh
./pocs/server-install/collect.sh srv
./pocs/server-install/acceptance.sh srv
./pocs/server-install/reboot-check.sh srv
```

`--disk-gb 40` is not optional: the `cidata` JSON carries an absolute partition
layout for a 40 GiB disk, and a smaller one fails the first phase with
`Partition overlaps backup GPT header`.

`mkcidata.sh --profile server` differs from the desktop drive in four places:
the runtime and settings package names, `audio_config: null`, a shorter
`packages` list (no `base-devel`, no `git`), and a `profile` file that tells the
ISO's orchestrator which profile to install even when the ISO itself was built
for another one.

## Results

| Measurement | Server, first ISO | Desktop reference |
|---|---|---|
| Orchestrator | **30.6 s** across its phases | ~98 s |
| Packages (`pacman -Qq`) | **320** — 57 explicit, 263 dependencies | 942 |
| Installed size | **2344 MiB** | 8079 MiB |
| Used on `/` | **1.7 GiB** | 14 GiB |
| Default target | `multi-user.target` | `graphical.target` |
| Acceptance | **17 of 17 pass** | — |
| Reboot check | clean: machine returns, 0 failed units | — |

The 320-package machine is the one preserved as the "before" column of the
lean-base measurement: [`../pocs/server-install/reference/surface-before.txt`](../pocs/server-install/reference/surface-before.txt),
collected from VM `srv-before` at `2026-08-28T22:51:20-03:00`. It records gcc
220.9 MiB, docker 117.0, containerd 86.8, perl 70.3 and docker-buildx 62.5
among its ten biggest packages, and 17 enabled units, 5 masked, 8 listening
sockets, 19 setuid binaries and 12 services running as root.

**What the ISO patches had to do.** Nine patches, none of them modifying
upstream in place: a `--profile` flag on `omarchy-iso-make` that also splits the
offline-mirror cache per profile; profile package lists in `build-iso.sh` with
the nvim target left deliberately empty; optional and extra targets in
`build-omarchy-packages.sh`; a server-aware orchestrator that skips
`configure_hibernation` and `configure_login`, drops `base-devel` and `git` from
the early bootstrap packages, and writes `/etc/omarchy-profile`; a `cidata`
loader that accepts a `profile` file; and a new `install_addons` phase.

## Evidence

- [`../docs/iso-server.md`](../docs/iso-server.md) — §1 how the build works, §2 the patch table, §5 cmdline and `validate_boot`, §6 build results
- [`../pocs/server-install/README.md`](../pocs/server-install/README.md) — how to reproduce, and how to debug a failed install without a screen
- [`../pocs/server-install/reference/surface-before.txt`](../pocs/server-install/reference/surface-before.txt) — the 320-package machine, measured
- `iso/patches/0001`…`0006` — the patch series as it stood after this run

## Findings and bugs

Two build failures were found by building, not by reading:

1. **`${OMARCHY_NVIM_PACKAGE:=omarchy-nvim}`** resurrects the default for a name
   that was exported **empty on purpose**, so the builder tried to build a
   `pkgbuilds/omarchy-nvim` that does not exist. Fixed by using `${VAR=default}`.
2. **`_install_early_packages` pacstrapped `EARLY_LUAROCKS_PACKAGES`
   unconditionally.** Those packages only reach the offline mirror through
   `omarchy-nvim`'s dependency closure, so with no nvim target the phase died
   with `error: target not found: lua51`.

Two more, found by installing:

3. **`configure_ssh_access` ran `ufw allow ssh` unconditionally**, and UFW keeps
   one rule per (port, protocol, direction) — so it silently **replaced** the
   rate-limited rule the profile had written a few phases earlier with a
   permissive one. The phase now runs `ufw limit 22/tcp`, and the assertion that
   follows was relaxed to check that port 22 was recorded at all, because a
   `limit` rule records a jump to `ufw-user-limit-accept` rather than a direct
   `ACCEPT`.
4. **The install dashboard is not a reliable status source.** The live ISO
   inherits `cloud-init` from the archiso releng profile; it finds the same
   `cidata` drive (NoCloud is the same label) and prints its ssh host-key output
   over the dashboard on tty1. The install is unaffected — its state is in
   `/run/omarchy-install/state.json` and its log in
   `/var/log/omarchy-install.log` — but the screen becomes unreadable. Reaching
   tty2 through the QEMU monitor and starting sshd by hand in the live
   environment is what found every install-time bug recorded here.

## Limitations

- **The raw artifacts of this run no longer exist in the tree.** `collect.sh`,
  `acceptance.sh` and the timing JSON all write to fixed paths under
  `pocs/server-install/reference/`, and later runs overwrote them. The 30.6 s
  and the 17/17 are quoted from this run's record, not from a file that can be
  re-read today; `surface-before.txt` survives because it was written under a
  distinct name. Later reports quote later, re-collected numbers — for the same
  reason, a `reference/` directory is a snapshot of the **last** run, not a
  history.
- The 30.6 s figure is orchestrator time on a host that was not otherwise idle.
- The acceptance list at 17 items did not yet cover identity, addons, the update
  path or Secure Boot; each of those added items later.

## Next steps

- Cut the package list down to what a headless machine actually needs, and
  measure the same surface both ways.
- Give the profile a supported way to add things back, so the core can be small
  without being useless.
