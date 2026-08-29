# Desktop parity of the patched ISO builder

The point of `iso/patches/` is that a **desktop** ISO built from the patched
tree installs the same machine an upstream ISO does. This is the measurement.

## What was compared

| | Reference | Parity run |
|---|---|---|
| VM | `ref`, snapshot `reference` (untouched) | `ref2`, fresh 40 GiB disk |
| ISO | official `omarchy-4.0.1.iso` | `omarchy-2026.08.29-x86_64-quattro.iso`, built by `./iso/build.sh --profile desktop` from this tree |
| cidata | `pocs/lab/out/cidata.iso` | the same file, byte for byte |
| Taken | 2026-08-28 | 2026-08-29 |

`--profile desktop` builds **without** `--local-source`: the desktop's Omarchy
packages come from the published `[omarchy]` mirror, exactly as a stock
`omarchy-iso-make` run takes them, so the only thing separating this ISO from an
upstream one is the patch series. Build: 7m03s, 5.9 GiB.

## Result

| Measurement | Reference | `ref2` | Verdict |
|---|---|---|---|
| Packages (`pacman -Qq`) | 942 | 942 | **identical**, and the name sets are equal in both directions |
| Explicitly installed | 159 | 159 | **identical set** |
| Enabled unit files | sddm, cups(+browsed/.path/.socket), avahi, bluetooth, power-profiles-daemon, NetworkManager(+dispatcher), docker.socket, … | same | **identical set** |
| Default target | `graphical.target` | `graphical.target` | same |
| `lua51` / `luarocks` / `omarchy-nvim` | 5.1.5-13 / 3.13.0-5 / 2026.8.13-1 | same | same — the empty-nvim-target branch is server-only |
| btrfs subvolumes | `@ @home @log @pkg swap .snapshots @factory` + machines/portables | same | **identical** |
| Swapfile / hibernation | `/swap/swapfile`, `resume=`, `resume_offset=` | same | same — `configure_hibernation` is skipped only on `server` |
| Kernel cmdline | `zswap.enabled=0 … resume= … initramfs_async=0 quiet splash loglevel=0 …` | same modulo PARTUUID and resume offset | **identical** |
| `limine.conf` | `interface_branding: Omarchy Bootloader`, Tokyo Night palette, `#timeout: 3` | same | **identical** — the `Omarchy <Profile>` renaming is skipped for `desktop` |
| `mkinitcpio.conf.d` | `omarchy_hooks.conf omarchy_resume.conf thunderbolt_module.conf` | same | identical |
| `/etc/pacman.conf` | `[omarchy] SigLevel = Optional TrustAll` | same | identical — no patch touches SigLevel |
| `os-release` | `NAME=Omarchy`, `ID=omarchy` | same | identical |
| Hostname | `omarchy-ref` (the cidata names it) | `omarchy-ref` | same |
| Installed size | 8079.57 MiB | 8081.75 MiB | **+2.18 MiB** |
| Boot | 12.2 s | 11.1 s | host noise |
| Failed units | 0 | 0 | — |

### The one difference, and where it comes from

`mise-bin` grew from 96.36 MiB to 98.52 MiB between the two runs. That is
+2.16 MiB of the +2.18 MiB total, and it is an upstream package update: the
version resolved from the mirror on 2026-08-29 is not the one resolved on
2026-08-28. Nothing in this repository selects, pins or patches `mise-bin`.

## Differences our patches do cause, and why they are acceptable

Two branches in the patch series can change a desktop install. Neither did in
this run, and both are recorded here rather than left to be rediscovered.

**`/etc/omarchy-profile` — fixed, no longer a difference.** The first parity run
(same ISO, before this fix) came out with an unowned `/etc/omarchy-profile`
containing `desktop`, written by the orchestrator's `_write_profile_marker`.
Nothing on a desktop reads it, but it was the one file that made a patched build
differ from an upstream one, so the marker is now written for named profiles
only. `ref2` has no such file; the server install still has one, shipped by
`omarchy-server-settings` and rewritten by the orchestrator.

**The default hostname — a deliberate change, documented.**
`0009-orchestrator-default-hostname.patch` changes the fallback used when the
autoinstall drive carries no `hostname` key from archinstall's `archlinux` to
`omarchy`. It is inert here because this cidata names the host `omarchy-ref`,
and it is inert for any install that names its host. It is kept because
`omarchy` is what the ISO's own interactive configurator offers as the default,
so the patch makes the autoinstall path agree with the interactive one instead
of quietly producing a machine called `archlinux`. This is the one desktop-path
behaviour change in the series.

## Reproducing

```bash
./iso/build.sh --profile desktop
./pocs/lab/vm.sh ref2 create --disk-gb 40      # NOT `ref`: its `reference` snapshot stays
./pocs/lab/vm.sh ref2 start \
  --iso "$PWD/iso/release/omarchy-2026.08.29-x86_64-quattro.iso" \
  --cidata "$PWD/pocs/lab/out/cidata.iso"
./pocs/lab/vm.sh ref2 wait-ssh
LAB_OUT=$PWD/pocs/lab/out ./pocs/server-install/collect.sh ref2 /tmp/ref2
```

`collect.sh` and the script that produced `pocs/lab/reference/` are not the same
collector, so their `system.txt`, `storage.txt` and `packages-biggest.txt`
differ in layout. The comparisons above are field by field, not file by file.
