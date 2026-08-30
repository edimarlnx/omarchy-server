# The demo image: tui-tools from their own signed repository

**Date:** 2026-08-30
**Subject:** the `tui-tools` addon, `fakeroot` in the base, and the cloud image
built for a reviewer to log into
**Result:** **22 passed / 0 failed** (cloud acceptance) and **42 passed / 0
failed** (cloud SELinux acceptance) on the image that is published as
`image-2026-08-30`; **79 passed / 0 failed** in the packaging container test.
One bug found and fixed in the build driver: `serverlab image build` could
build an image out of an earlier run's disk.

## Scope

An external reviewer is to be handed a live machine of this profile. That
turned three loose ends into one run:

1. **`checkupdates` never worked.** `omarchy-update-available` and the server
   MOTD call it, and it dies with "Cannot find the fakeroot binary" when
   `fakeroot` is absent — reporting a machine that is up to date when it is
   not. The base carried `pacman-contrib` and not `fakeroot`.
2. **The terminal UIs were being rebuilt here.** `tui-firewall` and
   `tui-systemd` were built from source inside the ISO builder and served out
   of `[omarchy-server]`. The tools now publish their own signed pacman
   repository, so the profile can install them instead of rebuilding them.
3. **The demo instance's shape and accounts** had to be decided and written
   into `pocs/image/oci/launch-demo.sh` rather than into somebody's shell
   history.

No OCI resource was created while this was measured; §1–§4 end at a published
artifact and a script whose plan was rendered and read. The owner then ran the
import and the launch for real, and §5 is what that found.

## 1. `fakeroot` in the base

`checkupdates` (pacman-contrib) refreshes a throwaway copy of the sync
databases as an unprivileged user, and does it by running pacman under
`fakeroot`:

```
$ grep -n fakeroot /usr/bin/checkupdates
128:if ! type -p fakeroot >/dev/null; then
129:	die 'Cannot find the fakeroot binary'
150:	if ! fakeroot -- pacman -Sy --disable-sandbox-filesystem ...
```

So `fakeroot` joins `profile/server/omarchy-server.packages` **and** the
`depends` of `omarchy-server` (4.0.1-14), which is the honest statement: the
runtime calls a command that does not run without it.

It is not a privilege: `fakeroot` is `LD_PRELOAD` of `libfakeroot.so` plus a
helper daemon in the caller's own session. No setuid bit, no file capability,
no privilege the caller did not already have — and the pacman it wraps only
writes into the temporary database directory it was pointed at. The
alternative considered and rejected was dropping `pacman-contrib`: `paccache`
is on the update path too, and an update check that silently answers "nothing
to do" is worse than a package.

| Assertion | Result |
|---|---|
| the runtime declares `fakeroot` | **PASS** |
| the runtime still declares no `git`, `jq` or `perl` | **PASS** |
| `checkupdates` exits 0 or 2 (it ran) instead of 1 (it died) | **PASS** |

## 2. The `tui-tools` addon

Fourteen terminal UIs — the firewall, systemd, the journal, disks, snapshots,
users, ssh, certificates, cron, containers, samba, the network, updates and a
security review — installed by one addon from
`https://pkgs.tui.tools/arch/$arch`.

What the profile owns is not the software but **which key a machine trusts**:

| Aspect | Choice |
|---|---|
| `SigLevel` | `Required TrustedOnly` — the repository signs its database and every package |
| Key | pinned by fingerprint `767CFB33 7B01F32F FC073F3F 389120B2 77E4FB44`, vendored in the profile at `install/server/addons/tui-tools.pubkey.asc` |
| When | `install/server/addons/tui-tools.preflight.sh`, which runs BEFORE the packages are installed — on an installed machine there is nowhere else to fetch them from |
| Order | fingerprint check → `pacman-key --add` → `pacman-key --lsign-key` → write `/etc/pacman.d/tui-tools.conf` and the `Include` |
| Offline | `iso/build.sh` downloads the packages, verifies each against the same key, and drops them in `<pkgs-checkout>/prebuilt/`, from where the ISO builder puts them in its offline mirror |

Adding a downloaded key with no fingerprint check would trust whatever the
network handed over, so the check is the first thing the preflight does and the
only thing that decides whether the key is imported at all. During an install
off the offline mirror a key failure is reported and the install continues —
the packages are already on the medium — while on an installed machine it is
fatal.

The two per-tool addons are gone, and so are the two PKGBUILDs in
`omarchy-server-pkgs`. Two copies of the same package name in two
repositories, at different versions, is an ambiguity a machine should never
have to resolve.

Measured on the image (VM `cloudtest`, booted from the published artifact):

```
$ pacman -Qq | grep '^tui-' | tr '\n' ' '
tui-cert tui-containers tui-cron tui-disk tui-firewall tui-logs tui-network
tui-samba tui-secure tui-snapper tui-ssh tui-systemd tui-update tui-users

$ pacman-conf --repo tui-tools SigLevel Server
SigLevel = PackageRequired
SigLevel = PackageTrustedOnly
SigLevel = DatabaseRequired
SigLevel = DatabaseTrustedOnly
Server = https://pkgs.tui.tools/arch/x86_64

$ sudo pacman-key --list-keys 767CFB337B01F32FFC073F3F389120B277E4FB44
pub   rsa4096 2026-08-30 [SC]
      767CFB337B01F32FFC073F3F389120B277E4FB44
uid           [  full  ] tui-tools package signing ...
```

`[ full ]` is the local signature: without it every package from that
repository would be rejected as signed by a key this machine does not trust.
`sudo omarchy-server-update --dry-run` on the same machine synced
`tui-tools is up to date` **over the network**, under `Required`, which is the
proof that the repository works for a machine and not only for the ISO.

Cost: 14 packages, **67 MiB** installed, no daemon and no listening socket —
each one a static Go binary that shells out to the tool the machine already
has. The base without the addon is unchanged.

## 3. The image

Built with `serverlab image build --mac selinux --addons tui-tools` off
`omarchy-2026.08.30-x86_64-server-local.iso` (3.0 GiB), then tested with
`serverlab image test --recreate`.

| Item | Value |
|---|---|
| Artifact | `omarchy-server-2026-08-30-selinux-tui-tools-x86_64.qcow2` |
| Size | 1,489,436,672 bytes (1.4 GiB) |
| sha256 | `0f2b9bc1f72a7d4af50b0d60d3b9b955ea7831ab01e712b1551e55f96b0b5b99` |
| Published | release `image-2026-08-30` of this repository, with its `.sha256` |
| Packages installed | 274 |
| SELinux | `enabled`, policy `refpolicy-arch`, mode **permissive** as shipped |
| Firewall | `ufw` active, `22/tcp LIMIT` and nothing else |
| Boot | 7.9 s to `multi-user.target`, 0 failed units |

| Suite | Result |
|---|---|
| `pocs/server-install/acceptance-cloud.sh` | **22 passed, 0 failed** |
| `pocs/server-install/acceptance-cloud-selinux.sh` | **42 passed, 0 failed** |
| `pocs/server-install/reboot-check.sh` | clean: no failed units, only `22/tcp` and the local resolver listening |
| `pkgs/test.sh` (packaging, clean container) | **79 passed, 0 failed** |
| `omarchy-server-pkgs/scripts/verify.sh` (the signed repository served over HTTP, then re-served hostile) | **13 passed, 0 failed** |

Evidence: `pocs/lab/out-cloudtest/evidence/`, published into
`pocs/server-install/reference/cloudtest/`.

### The bug this found

`serverlab image build` **skipped creating the build VM's disk when one was
already there**, and then installed nothing: the machine booted the earlier
install off that disk, was generalized, and was converted into an image. The
artifact was well-formed, the test suite ran, and the whole thing was
yesterday's machine — the failure mode that looks exactly like a success. It
was caught because the SELinux suite failed 22 of 42 assertions on an image
that was supposed to ship SELinux, and `/var/log` on the machine was dated the
day before.

`image build` now deletes a leftover build VM instead of reusing it. (`image
test` still keeps its disk unless `--recreate` is passed; that VM is a
consumer of the artifact, not the thing being built. A test run against a
still-RUNNING test VM has the same shape of trap: `vm start` on a running
machine is a no-op, so the suite talks to the old one. Stop it first.)

## 4. The demo instance

Decided and written into `pocs/image/oci/launch-demo.sh`:

| Setting | Value | Why |
|---|---|---|
| Shape | `VM.Standard.E4.Flex`, 1 OCPU / 2 GB, baseline **12.5%** (`BASELINE_1_8`) | the smallest UEFI-capable x86 shape this image fits on; a demo box somebody ssh's into once a day is exactly what a burstable instance is for. `VM.Standard.E5.Flex` is the documented alternative; `--baseline none` bills a full OCPU |
| Firmware | UEFI_64 through the image capability schema `import.sh` attaches | the image boots a UKI through Limine on an ESP; there is no BIOS path at all |
| Shielded | no | the image's Secure Boot mode enrolls keys the machine generates for itself, which needs firmware in Setup Mode; OCI enforces against Oracle's key set |
| Network | one NSG, ingress `22/tcp` only, egress all | plus `ufw limit 22/tcp` on the machine itself |
| Accounts | two, both `wheel`, both `NOPASSWD` sudo, both key-only | a reviewer who cannot `sudo` cannot look at anything a server is interesting for. `lock_passwd` leaves no password, `ssh_pwauth: false` refuses password authentication, `disable_root: true` keeps root off ssh |

`--demo-user` names the reviewer's account, `--owner-user` the owner's; the
rendered `#cloud-config` is printed by a run without `--yes`, which creates
nothing.

A run without `--yes`, with the two public keys the owner placed outside this
repository (the keys themselves are redacted here, and neither the keys nor
the tenancy identifiers are ever committed):

```
=== OCI demo instance ===
profile:       <the owner's OCI CLI profile>
display name:  omarchy-server-demo
hostname:      omarchy-server-demo  (DNS record is dns.md, not this script)
shape:         VM.Standard.E4.Flex  1 OCPU / 2 GB  baseline BASELINE_1_8
image:         <image OCID from import.sh>
subnet:        <an existing public subnet OCID>
nsg:           <created here: ingress 22/tcp only>
shielded:      no (see the header of this script)
accounts:      <reviewer>, <owner>  — key only, no password, sudo NOPASSWD

--- cloud-init user-data ---
#cloud-config
hostname: omarchy-server-demo
fqdn: omarchy-server-demo.tui.tools
disable_root: true
ssh_pwauth: false
users:
  - name: <reviewer>
    gecos: Omarchy Server demo
    groups: [ wheel ]
    sudo: [ "ALL=(ALL) NOPASSWD: ALL" ]
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-ed25519 <REDACTED>
  - name: <owner>
    gecos: Omarchy Server owner
    groups: [ wheel ]
    sudo: [ "ALL=(ALL) NOPASSWD: ALL" ]
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-rsa <REDACTED>
---

Plan (nothing has been created):
  1. oci network nsg create             one NSG in the subnet's VCN
  2. oci network nsg rules add          ingress 0.0.0.0/0 -> 22/tcp, egress all
  3. oci compute instance launch        with the user-data above
  4. wait for RUNNING, print the public IP and the ssh command
```

## 5. What went wrong at the first launch

The scripts were run for real after this report was written, and the first
instance never booted: an empty serial console, no output at all. It had
launched with **`firmware = BIOS`**, and this image has no BIOS boot path —
it is a UKI on an ESP behind Limine, with no MBR to find.

The cause was in `import.sh`, not in the image. `oci compute image get` does
not accept `--wait-for-state`; the CLI exited 2 with "no such option", and
under `set -euo pipefail` the script stopped there — right after printing
`› waiting for AVAILABLE`, which reads like progress — and never reached the
step that attaches the image capability schema. The import itself had already
been accepted, so the image went AVAILABLE on its own and looked healthy.
`oci compute image-capability-schema list --image-id ...` came back empty,
which was the whole diagnosis. A second defect sat behind the first: the
create flag is `--global-image-capability-schema-version-name`, not
`--image-capability-schema-version-name`, so the schema step would have failed
on its own line anyway.

Creating the schema by hand, with the same JSON the script carries, fixed it;
the image now reports `Compute.Firmware` default `UEFI_64`.

Changed so that a silent skip cannot happen again:

| Change | Where |
|---|---|
| poll `lifecycle-state` instead of the non-existent waiter, tolerating `IMPORTING` for 30 minutes | `import.sh` |
| the schema step skips an image that already has one, so a re-run finishes a half-done import | `import.sh` |
| read `Compute.Firmware` back from the API and exit non-zero unless it is `UEFI_64`; print `firmware: UEFI_64 (verified)` | `import.sh` |
| `--launch-options '{"firmware":"UEFI_64"}'` on the launch, as belt and braces | `launch-demo.sh` |
| assert the launched instance's `launch-options.firmware`, and **terminate the instance** if it is not `UEFI_64` | `launch-demo.sh` |

The last one is the one that matters commercially: a BIOS VM from this image
does nothing except bill, and nobody watches a console that shows nothing.

## What this run does not prove

- **The report's own measurements stop at the artifact.** Everything above §5
  is QEMU/KVM. The OCI run described in §5 established the firmware failure
  mode and its fix, and nothing else about the image's behaviour on a cloud.
- **SELinux ships permissive.** Taking it to enforcing is
  `reports/2026-08-29-cloud-image-selinux.md`, and it is a deliberate step an
  operator takes, not a default.
- **The `tui-tools` packages are somebody else's build.** That is the point of
  taking them from a signed repository, but it does move the trust from "we
  compiled it" to "this key signed it". The key is pinned by fingerprint in
  this repository, which is what makes that trust reviewable.
- **The offline path and the online path install different versions over
  time.** The ISO carries the packages as they were on the day it was built;
  a machine that runs `pacman -Syu` gets what the repository holds today.
