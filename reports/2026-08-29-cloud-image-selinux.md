# The cloud image under SELinux

**Date:** 2026-08-29
**Subject:** a --mac selinux image built, booted from a NoCloud seed, and taken to enforcing over ssh
**Result:** **68 passed, 0 failed** on VM `cloudsel`, and **0 AVC denials on
either boot** — the first one included, which is the boot that runs cloud-init

## Scope

`reports/2026-08-29-cloud-image.md` built a cloud image and said, in its own
"what this does not prove" list, that a `--mac selinux` image was asserted by
design and not by a run. This is that run.

One machine of the `server` profile, **launched from a `--mac selinux` cloud
image** onto a 40 GiB disk it was not built on, told about itself by nothing but
a NoCloud seed, and asked the questions an image makes different from an
install. On an installed machine the operator's account and home directory are
created by the orchestrator, minutes after the offline relabel. On a machine
from an image, **every account, home directory and authorized_keys file is
created by cloud-init on the first boot, after the artifact was labelled** —
which is precisely the case that locked an operator out of an enforcing machine
in `reports/2026-08-29-mandatory-access-control.md` §6.4.

So the subjects are the three agents an install never runs — cloud-init,
`omarchy-server-firstboot` and `qemu-guest-agent` — plus the decision an image
has to make and an install does not: **which mode the artifact ships in**.

Both answers were measured. The image ships **permissive**, and this run takes
it to enforcing over ssh, through the guard, without `--force`. A second image,
byte-identical apart from one line of `/etc/selinux/config`, was booted
**enforcing from its very first boot**; §"An image that ships enforcing" below
is what that found.

## Environment

| | |
|---|---|
| VM | `cloudsel`, QEMU/KVM `q35`, 4 vCPU, 8 GiB RAM, 40 GiB virtio disk |
| Firmware | OVMF 4M without Secure Boot |
| Image | `omarchy-server-2026-08-29-selinux-x86_64.qcow2` |
| Image size | 1.3 GiB (1427308544 bytes) |
| Image sha256 | `519f96a75adbac1990602f9b390bf41c419968baf8365ef6891504fc7de45139` |
| NoCloud seed | `mkseed.sh --hostname omarchy-cloud-test --user demo` |
| Run | `2026-08-29T18:22:13-03:00` |

## Method

```bash
serverlab iso build                       # the profile changed; the ISO carries it
serverlab image build --mac selinux
serverlab image test cloudsel --image omarchy-server-2026-08-29-selinux-x86_64.qcow2 \
    --disk-gb 40 --enforce
serverlab report cloudsel

# what those run underneath:
#   pocs/lab/mkcidata.sh --profile server --user imgbuild --addons cloud
#   pocs/image/generalize.sh + pocs/image/convert.sh
#   pocs/image/mkseed.sh --hostname omarchy-cloud-test --user demo
#   pocs/lab/vm.sh cloudsel create --from-image <image> --disk-gb 40
#   pocs/server-install/acceptance-cloud.sh|surface.sh|reboot-check.sh cloudsel
#   ENFORCE=1 pocs/server-install/acceptance-cloud-selinux.sh cloudsel
```

`--enforce` is what makes the SELinux list switch the machine to enforcing —
through `omarchy-server-selinux enforcing`, without `--force`, so the guard has
to pass on its own — run the workload there and reboot into it.

`collect.sh` and `surface.sh` run **before** the acceptance lists: the
acceptance workload installs the `docker` addon and then runs an update, both
of which change the package set the measurements record. `reboot-check.sh`
runs last, because it takes the VM down.

## Results

### Acceptance — the cloud image, booted from a NoCloud seed

**22 passed, 0 failed.** Full evidence in [`acceptance-cloud.txt`](../pocs/server-install/reference/cloudsel/acceptance-cloud.txt).

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 1 | cloud-init finished its run | **PASS** | `exit=0` |
| 2 | the datasource is one of the five this image declares | **PASS** | `datasource_list: [ NoCloud, ConfigDrive, OpenStack, Oracle, Ec2, None ]` |
| 3 | hostname came from the metadata | **PASS** | `omarchy-cloud-test` |
| 4 | the user the seed named exists, with its key and passwordless sudo | **PASS** | `sudo-n-ok` |
| 5 | the build account is gone | **PASS** | `demo` |
| 6 | root carries no password | **PASS** | `root L 2026-08-29 -1 -1 -1 -1` |
| 7 | no build credentials anywhere on the image | **PASS** | `leftovers=0` |
| 8 | machine-id was generated on this machine | **PASS** | `829642422cd14dceb99281416351146e` |
| 9 | ssh host keys were regenerated at first boot | **PASS** | `count=3` |
| 10 | the first-boot unit ran and said what it did | **PASS** | `marker: 2026-08-29T18:22:04-03:00` |
| 11 | the image's journal mentions nothing of the build machine | **PASS** | `build_user_mentions=0` |
| 12 | growpart + btrfs resize filled the 40 GiB disk | **PASS** | `root_gib=38` |
| 13 | growpart and resizefs are in the cloud-init log, not assumed | **PASS** | `2026-08-29 21:22:01,568 - handlers.py[DEBUG]: finish: init-network/config-resizefs: SUCCESS: config-resizefs …` |
| 14 | os-release, issue and MOTD still say Omarchy | **PASS** | `[2mhost     [0m omarchy-cloud-test` |
| 15 | profile marker and version survived | **PASS** | `omarchy-server-settings 4.0.1-4` |
| 16 | the update entry point works on a machine nobody logs into | **PASS** | `Triggers: ● omarchy-server-update.service` |
| 17 | the firewall is up and rate-limits ssh | **PASS** | `22/tcp (v6)                LIMIT IN    Anywhere (v6)              # omarchy-sshd` |
| 18 | sshd still refuses passwords and root | **PASS** | `KbdInteractiveAuthentication no` |
| 19 | no failed units | **PASS** | `failed=0` |
| 20 | the boot is still a server's boot | **PASS** | `162ms ufw.service` |
| 21 | @factory is present beside @ | **PASS** | `factory=1` |
| 22 | the package cache shipped empty | **PASS** | `0	/var/cache/pacman/pkg` |

### Acceptance — the cloud image under SELinux, enforcing

**46 passed, 0 failed.** Full evidence in [`acceptance-cloud-selinux-enforce.txt`](../pocs/server-install/reference/cloudsel/acceptance-cloud-selinux-enforce.txt).

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 1 | cloud-init finished its run | **PASS** | `status: done` |
| 2 | the kernel initialised SELinux from the cmdline baked into the UKI | **PASS** | `in-limine-conf=1` |
| 3 | the refpolicy-arch policy is loaded | **PASS** | `Max kernel policy version:      35` |
| 4 | the image records the mode it ships in, and the running mode agrees | **PASS** | `SELINUX=permissive` |
| 5 | the local policy module survived generalization | **PASS** | `modules=416` |
| 6 | the cloudinit_growpart boolean is on, or growpart cannot read the disk | **PASS** | `cloudinit_growpart --> on` |
| 7 | the first-boot relabel ran and cleared its flag | **PASS** | `enabled` |
| 8 | and it reported what it did | **PASS** | `omarchy-server-selinux-relabel.service: Consumed 573ms CPU time over 887ms wall clock time, 87.7M memory peak.` |
| 9 | the first boot's relabel cost is recorded | **PASS** | `relabel=ExecMainStartTimestampMonotonic=14410547 ExecMainExitTimestampMonotonic=15298321` |
| 10 | init is in init_t on the FIRST boot of the image, not kernel_t | **PASS** | `system_u:system_r:init_t` |
| 11 | sshd runs in a domain of its own | **PASS** | `system_u:system_r:sshd_t` |
| 12 | the home directory cloud-init created is user_home_dir_t | **PASS** | `user_u:object_r:user_home_dir_t /home/demo` |
| 13 | the authorized_keys cloud-init wrote is ssh_home_t | **PASS** | `user_u:object_r:ssh_home_t /home/demo/.ssh/authorized_keys` |
| 14 | nothing under /home or /root disagrees with the policy | **PASS** | `wrong=0` |
| 15 | the sudoers drop-in cloud-init wrote carries a policy label | **PASS** | `system_u:object_r:etc_t omarchy-tzupdate` |
| 16 | cloud-init's own state directory is labelled, not unlabeled | **PASS** | `system_u:object_r:cloud_init_state_t /var/lib/cloud/instance` |
| 17 | the regenerated ssh host keys are sshd_key_t, not etc_t | **PASS** | `wrong=0` |
| 18 | and the first-boot unit is the one that made them | **PASS** | `firstboot: 256 SHA256:7Hz/CSlyoTxTjjgOIpkcDVL5vmlfJSuPmqn+CEuyeb4 root@omarchy-server (MLDSA44-ED25519)` |
| 19 | growpart and the btrfs resize filled the disk | **PASS** | `root_gib=38` |
| 20 | and they are in the cloud-init log rather than assumed | **PASS** | `2026-08-29 21:22:01,568 - handlers.py[DEBUG]: finish: init-network/config-resizefs: SUCCESS: config-resizefs …` |
| 21 | cloud-init finished with an empty error list, not merely 'done' | **PASS** | `recoverable_errors: {}` |
| 22 | qemu-guest-agent is running, in a domain, on the virtio channel | **PASS** | `system_u:system_r:initrc_t` |
| 23 | the host can freeze and thaw the guest through the agent | **PASS** | `status:  {"return": "thawed"}` |
| 24 | the cloud-init account logs in as staff_t, not the default user_t | **PASS** | `demo wheel` |
| 25 | and sudo lands in sysadm_t, which is what makes the machine administrable | **PASS** | `staff_u:sysadm_r:sysadm_t` |
| 26 | the mapping is %wheel -> staff_u in the policy store's seusers | **PASS** | `%wheel:staff_u` |
| 27 | and sudoers carries the role transition for that same group | **PASS** | `Defaults:%wheel role=sysadm_r, type=sysadm_t` |
| 28 | no file under /etc /usr /var has a label the policy disagrees with | **PASS** | `--- AVC denials of the FIRST boot (cloud-init, firstboot, qemu-ga) ---` |
| 29 | the first boot's denial count was measured | **PASS** | `0 AVC records on the boot that ran cloud-init` |
| 30 | the denials are attributed to a domain, not left as a number | **PASS** | `--- switching to enforcing ---` |
| 31 | enforcing is accepted from the session, through the guard | **PASS** | `mode=Enforcing` |
| 32 | and the mode was written down, so it survives a reboot | **PASS** | `SELINUX=enforcing` |
| 33 | it is a TWO-way door over ssh: back to permissive and forward again | **PASS** | `fwd=Enforcing` |
| 34 | and forward again left it enforcing | **PASS** | `Enforcing` |
| 35 | sudo works and reaches root | **PASS** | `root` |
| 36 | pacman can run a transaction | **PASS** | `pacman-contrib 1.13.1-1` |
| 37 | a snapper snapshot can be taken | **PASS** | `1` |
| 38 | the firewall still answers | **PASS** | `To                         Action      From` |
| 39 | the update entry point runs the way its timer runs it | **PASS** | `ExecMainStatus=0` |
| 40 | the boot entry still points at a UKI that exists | **PASS** | `boot id after:  d552f338-c570-4138-babf-d3f44eaf9ee2` |
| 41 | the machine came back over ssh after a reboot | **PASS** | `boot_id afaed2e9-0122-4ef5-9eb0-27adf7351584 -> d552f338-c570-4138-babf-d3f44eaf9ee2` |
| 42 | SELinux is in the mode the machine was left in | **PASS** | `Enforcing` |
| 43 | cloud-init did not redo its once-per-instance work | **PASS** | `--- AVC denials of the SECOND boot ---` |
| 44 | enforcing: the second boot denied nothing | **PASS** | `0 AVC records this boot` |
| 45 | the home directory is still user_home_dir_t after the reboot | **PASS** | `user_u:object_r:user_home_dir_t /home/demo` |
| 46 | and the root filesystem is still the grown one | **PASS** | `root_gib=38` |

### Attack surface

| Metric | Value |
|---|---|
| Packages installed | **259** |
| Explicitly installed | **42** |
| Installed as a dependency | **217** |
| Installed size (MiB) | **1527** |
| `linux-firmware` (MiB) | **408** |
| Enabled unit files | **28** |
| Masked unit files | **13** |
| Listening sockets (`ss -ltnup`) | **6** |
| setuid/setgid binaries | **16** |
| Services running as root | **10** |

### Reboot survival

The machine came back over ssh after `systemctl reboot`.

| | |
|---|---|
| Verdict | rebooted: boot time moved from 2026-08-29 18:22:29 to 2026-08-29 18:22:39 |
| ssh | ssh answered 1s after the reboot request |
| Boot | Startup finished in 928ms (firmware) + 2.739s (loader) + 778ms (kernel) + 3.227s (userspace) = 7.673s |
| Failed units | 0 loaded units listed. |

## The first boot, in order

What a machine booted from this image does before anyone can log in, measured
on the run above:

| | Unit | What it does | Cost |
|---|---|---|---|
| 1 | `cloud-init-local` / `cloud-init` | hostname, the account the metadata names, its home and `authorized_keys`, `growpart` + `btrfs filesystem resize` | ~1 s |
| 2 | `omarchy-server-firstboot` | four ssh host key pairs, a fresh entropy seed, `limine-update` (mkinitcpio + UKI) to re-tag the boot entry with this machine's machine-id | **3.603 s** |
| 3 | `omarchy-server-selinux-relabel` | `restorecon -R -F /`, acting on the `/.autorelabel` generalization left | **887 ms** |
| 4 | `systemd-user-sessions`, `sshd` | logins are possible from here | — |

Two things about that ordering are new in this run.

**The relabel is now ordered after cloud-init.** Both units were already ordered
before `systemd-user-sessions.service` and neither was ordered against the
other, so which of them saw `/home/<user>` first was a race. Measured, the race
came out right — cloud-init created the account 3 s before the relabel started,
because `firstboot` rebuilds the initramfs in between — and `useradd` labels a
home directory correctly anyway. Neither is a guarantee: the first depends on
how long mkinitcpio takes, the second on cloud-init using `useradd` rather than
writing the tree itself. `After=cloud-init.service` on the relabel unit costs
nothing and turns the accident into a property.

**`init` is `init_t` on boot 1.** On a fresh install it is `kernel_t` there —
PID 1 transitions only if `/usr/lib/systemd/systemd` already carried
`init_exec_t`, and on an install the relabel happens after PID 1 has started, so
that route needs a reboot before enforcing is even considered. An image is
different: the build machine relabelled `/usr` twice before the artifact was
taken, so a machine from the image starts with a complete label set. That is
what makes `omarchy-server-selinux enforcing` pass its own preflight on the
first boot, and what makes an enforcing-from-boot-1 image thinkable at all.

## The denials this run found, and what each one cost

Eleven distinct denials, on paths an installed machine never takes. Every one of
them was closed before the run above, which is why its first-boot count is zero;
the numbers below are from the runs that found them.

| Denial | What it broke | Resolution |
|---|---|---|
| `cloud_init_t` → `cloud_init_runtime_t:sock_file create` (and `getsched`, `sysctl_vm_overcommit_t`, `nsfs_t`) | cloud-init 26's stage sockets under `/run/cloud-init/share` | policy, rule 26 |
| `cloud_init_t` → `fixed_disk_device_t:blk_file read` | **`growpart` refused; `cloud-init-main.service` failed; the machine stayed on the image's 40 GiB** | the `cloudinit_growpart` boolean, which refpolicy ships **off**; the addon now writes `booleans.local` |
| `staff_t` → `cloud_init_state_t` / `cloud_init_runtime_t` read | `cloud-init status --wait` answered `error` on a perfectly provisioned machine | policy, rule 27 (read-only, `staff_t` only) |
| `staff_t` → `systemdunit:service status` | `systemctl --failed` printed an **empty table** rather than an error — a health check that cannot fail | policy, rule 28 (against the attribute, not seven unit types) |
| `systemd_tmpfiles_t` → `user_home_dir_t` / `ssh_home_t` | `/root/.ssh` from systemd's `provision.conf` credential path | policy, rule 29 |
| `kmod_t` → `initrc_tmp_t` (depmod, 10 lines) | **mkinitcpio failed inside `firstboot`'s `limine-update`**: "errors were encountered during the build", no UKI | policy, rule 30 — the other half of rule 24, which had assumed the service path was safe |
| `loadkeys_t` → `initrc_lock_t:file write` | nothing: an inherited descriptor from limine's lock | `dontaudit`, rule 31 |
| `fsadm_t` → the session's pipe | `sudo btrfs subvolume list /` over ssh **exited 0 and printed nothing** — the `@factory` check would have read "absent" | policy, rule 31 (rule 16's domain list, extended) |
| `useradd_t` → `xdg_config_t` / `xdg_data_t` / `git_xdg_config_t` | this profile's `/etc/skel` half-copied into every account cloud-init creates, silently | policy, rule 35 |
| `staff_t` → `systemd_unit_t:file read` | `systemctl is-enabled` on a unit with no symlink | policy, rule 36 |
| `staff_systemd_t` → `virtio_device_t:chr_file getattr` | nothing; the user manager enumerating `/dev` | policy, rule 37 |
| `ss` → `kernel_t:system module_request`, then `netlink_tcpdiag_socket` | the listening-socket list came back **empty**, and the `enforcing` guard classified the first as a lockout risk and refused | `dontaudit` (38) + policy (39) |
| cloud-init's locale module (`localedef` over `usr_t`, `locale_t`, `systemd-localed` exec) | `cc_locale` re-generating a locale the install had already set | **not** policy: `locale: false` in the profile's `cloud.cfg`, and rule 34 records the decision as a rule that is deliberately absent |
| `cloud_init_t` → `sshd_key_t:file unlink` | on a **re-provision** (new instance-id, keys already present) cloud-init could not rotate the host keys, so a clone would answer with its parent's | policy, rule 33 |

Three of those are worth reading twice.

**The growpart boolean is the one that would have shipped broken.** refpolicy
gates cloud-init's access to the block device behind `cloudinit_growpart`, and
it ships off. In permissive nothing complains and the disk grows. In enforcing
`cloud-init status` still says `done` — only `--long` carries
`('growpart', PermissionError(13, ...))` — while the machine sits on 40 GiB of a
200 GiB volume. The acceptance now asks `--long` for exactly that reason.

**mkinitcpio inside a service is the §11.5 failure, again.** The
mandatory-access-control report closed that question for the administrative path
(`sudo pacman -S linux`, build root `user_tmp_t`) and its rule says the update
timer is safe because pacman under systemd is `initrc_t`. It is not: `kmod_t`
cannot search or write `initrc_tmp_t` either. The image found it because
`firstboot` rebuilds the UKI on every first boot — but the same hole is on the
path a **daily update timer** takes to install a kernel.

**`ss` refused is worse than `ss` failing.** With the netlink socket denied the
listening-socket check returns nothing and reads as a pass. The same shape as
`systemctl --failed` above: under enforcing, several diagnostics answer *less*
rather than answering *no*, and a check written against a permissive machine
cannot tell the difference.

## An image that ships enforcing

The second measurement, and the one the mode decision turns on. The same
artifact with one line changed offline —
`SELINUX=permissive` → `SELINUX=enforcing` in `/etc/selinux/config.refpolicy-arch`,
written with `guestfish` — booted onto a fresh 40 GiB disk with its own NoCloud
seed, enforcing from the very first instruction:

| | Result |
|---|---|
| ssh with the seed's key | works |
| cloud-init | `status: done`, `errors: []` |
| the account, its home, its `authorized_keys` | created, `user_home_dir_t` / `ssh_home_t` |
| growpart + btrfs resize | `root_gib=38` |
| ssh host keys | regenerated, `sshd_key_t` |
| the relabel unit | ran, cleared `/.autorelabel` |
| `sudo id -Z` | `staff_u:sysadm_r:sysadm_t` |
| guest agent freeze/thaw from the host | works |
| **AVC denials, boot 1** | **0** |
| **AVC denials, boot 2** | **0** |
| the SELinux cloud list | **42 passed, 0 failed** |
| the base cloud list | **19 passed, 3 failed** |

The three failures are the finding. None of them is the machine:

* `root carries no password` — the check reads `/etc/shadow` through `sudo`, and
  refpolicy deliberately withholds the auth files from `sysadm_t` (the same
  separation rule 23 of the policy module was written to preserve). `passwd -S
  root` still answers `root L`.
* `ssh host keys were regenerated at first boot` — the check `ls -l`s the keys as
  the login user; `staff_t` may not stat `sshd_key_t`. Through `sudo` the keys
  are there and correctly labelled, which is what the SELinux list asserts.
* `sshd still refuses passwords and root` — `sudo sshd -T` answers
  `sesh: unable to execute /usr/bin/sshd: Permission denied`, **with no AVC
  logged**, because refpolicy `dontaudit`s an administrator executing
  `sshd_exec_t` outside its unit. The setting is in `/etc/ssh/sshd_config` and
  the daemon enforces it; the *diagnostic* is what enforcing takes away.

So an enforcing image works. What it also does is make three of this
repository's own checks unanswerable, and that is a fair summary of the wider
cost: under enforcing several ordinary diagnostics return less than they used
to, quietly.

## The decision: the image ships permissive

**The `--mac selinux` image ships `SELINUX=permissive`, and enforcing is one
command away.** Not because enforcing does not work — it does, from the first
boot, with zero denials — but because of what an image is:

1. **An image is copied to platforms this lab has not seen.** Everything
   measured here is QEMU/KVM with a NoCloud seed. A machine that comes up
   enforcing on a cloud whose metadata service, disk layout or guest agent does
   something this policy has not been taught is a machine that may not finish
   provisioning, and on most clouds there is no console to fix it from. Shipping
   permissive means such a platform produces a *denial list* instead of an
   incident.
2. **The switch is cheap, guarded and reversible.** `sudo omarchy-server-selinux
   enforcing` passes its own preflight on the first boot (no `--force`), writes
   the mode so it survives a reboot, and is a **two-way door**: back to
   permissive and forward again from the same ssh session, measured in this run.
3. **The evidence for enforcing is already in the artifact.** The operator does
   not have to trust it: `omarchy-server-selinux avc` after a day of the real
   workload is the same question this run asked, on the machine that matters.

The counter-argument — that a security feature nobody turns on is not a security
feature — is real, and the honest answer is that it is a **default**, not a
verdict. An operator who wants enforcing from the first instruction has a
one-line change on the artifact, and this report is the measurement that says it
comes up clean:

```bash
guestfish --rw -a omarchy-server-<date>-selinux-x86_64.qcow2 <<'EOF'
run
mount-options subvol=@ /dev/sda2 /
command "sed -i s/^SELINUX=permissive/SELINUX=enforcing/ /etc/selinux/config.refpolicy-arch"
EOF
```


## Evidence

- [`acceptance-cloud.txt`](../pocs/server-install/reference/cloudsel/acceptance-cloud.txt) — the acceptance run, raw
- [`acceptance-cloud-selinux-enforce.txt`](../pocs/server-install/reference/cloudsel/acceptance-cloud-selinux-enforce.txt) — the acceptance run, raw
- [`surface.txt`](../pocs/server-install/reference/cloudsel/surface.txt) — the attack-surface measurements, raw
- [`reboot-check.txt`](../pocs/server-install/reference/cloudsel/reboot-check.txt) — the reboot survival check
- [`cloudselenf/acceptance-cloud-selinux.txt`](../pocs/server-install/reference/cloudselenf/acceptance-cloud-selinux.txt) — the image that ships enforcing, raw
- [`cloudselenf/acceptance-cloud.txt`](../pocs/server-install/reference/cloudselenf/acceptance-cloud.txt) — the same machine against the base cloud list, with the three unanswerable checks

## Limitations

_Written by `serverlab report` from the evidence files listed above._ The tables are the
run; what the run does **not** prove is not in them, and belongs here:

- **No cloud was touched.** QEMU/KVM with OVMF and a NoCloud seed, again. Every
  claim about how this image behaves on OCI, AWS or Proxmox is reasoning, not a
  measurement — and the policy work above is exactly the kind of thing another
  platform's agent set would add to.
- **One workload, one shape.** 4 vCPU, 8 GiB, a 40 GiB disk grown from a 40 GiB
  image, and the acceptance workload: pacman, snapper, ufw, the update unit, the
  docker addon. §10.2 of the mandatory-access-control report is the standing
  evidence that another workload finds more rules.
- **Secure Boot and SELinux together, still not measured.** This image was built
  without `--secboot`; that combination remains the open one.
- **The re-provision path is asserted by one rule, not by a suite.** Rule 33 came
  from `cloud-init clean` + reboot, which is a simulation of a clone taken from a
  running machine. A real second instance-id from a metadata service was not
  tried.
- **`qemu-guest-agent` runs as `initrc_t`.** refpolicy has no domain for it, so
  the agent that a hypervisor uses to freeze filesystems and stop the machine is
  the generic init-script domain. It works — ping, `guest-get-osinfo` and
  freeze/thaw were driven from the host with zero denials — but "it works" is not
  "it is confined", and a domain for it is unwritten work.
- **The enforcing variant was made with `guestfish`, not by the build.** There is
  no `serverlab image build --enforcing` flag; the artifact measured in
  §"An image that ships enforcing" was the shipped image with one line edited
  offline. If enforcing ever becomes the default, that flag is the change.
