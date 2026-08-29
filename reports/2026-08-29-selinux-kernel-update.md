# A kernel update under SELinux enforcing

**Date:** 2026-08-29
**Subject:** a kernel transaction, a UKI rebuild and the disable path on an enforcing machine; and the root cause of the mkinitcpio failure §11.5 could not explain
**Result:** **103 passed, 1 failed** on VM `srvsel`

## Scope

One machine of the `server` profile, installed headless from the ISO below by an
autoinstall `cidata` drive with no keyboard and no configurator, then measured
and put through the acceptance lists it was installed for (mandatory access control: `selinux`).

## Environment

| | |
|---|---|
| VM | `srvsel`, QEMU/KVM `q35`, 4 vCPU, 8 GiB RAM, 40 GiB virtio disk |
| Firmware | OVMF 4M without Secure Boot |
| ISO | `omarchy-2026.08.29-x86_64-server-local.iso` |
| ISO size | 2.9 GiB (3149234176 bytes) |
| ISO sha256 | `db5a0e10b34c54644d8b201396aec0fdd3623f8d76ff4fc11637b099b6c4b4b2` |
| Autoinstall | `mkcidata.sh --profile server --hostname omarchy-selinux --mac selinux` |
| Run | `2026-08-29T14:23:58-03:00` |

## Method

```bash
serverlab pkgs build && serverlab pkgs test
serverlab iso build --profile server
serverlab lab up srvsel --profile server --mac selinux --iso omarchy-2026.08.29-x86_64-server-local.iso
serverlab lab test srvsel --suite all
serverlab report srvsel

# what those run underneath:
#   pocs/lab/mkcidata.sh --profile server --hostname omarchy-selinux --mac selinux
#   pocs/lab/vm.sh srvsel create|start|wait-ssh
#   pocs/server-install/collect.sh|surface.sh|acceptance*.sh|reboot-check.sh srvsel
```

`collect.sh` and `surface.sh` run **before** the acceptance lists: the
acceptance workload installs the `docker` addon and then runs an update, both
of which change the package set the measurements record. `reboot-check.sh`
runs last, because it takes the VM down.

## Results

### Acceptance — SELinux, as installed

**44 passed, 1 failed.** Full evidence in [`acceptance-selinux.txt`](../pocs/server-install/reference/srvsel/acceptance-selinux.txt).

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 1 | the kernel initialised SELinux | **PASS** | `lsm=landlock,lockdown,yama,integrity,selinux,bpf` |
| 2 | lsm= names selinux, with lockdown ahead of it and bpf last | **PASS** | `lsm=landlock,lockdown,yama,integrity,selinux,bpf` |
| 3 | the cmdline came from inside the UKI, not from limine.conf | **PASS** | `in-cmdline=1` |
| 4 | the refpolicy-arch policy is loaded | **PASS** | `Max kernel policy version:      35` |
| 5 | /etc/selinux/config says what the addon wrote | **PASS** | `/etc/selinux/config.refpolicy-arch` |
| 6 | the profile's own file contexts are in the policy store | **PASS** | `/opt/containerd(/.*)?	system_u:object_r:container_var_lib_t` |
| 7 | and they are what the profile's commands actually carry | **PASS** | `system_u:object_r:bin_t /usr/share/omarchy/bin/omarchy-server-update` |
| 8 | the base selinux addon did NOT pull setools or selinux-python in | **PASS** | `error: package 'setools' was not found` |
| 9 | and the policy tools are offered as their own addon | **PASS** | `selinux` |
| 10 | every binary that needs libselinux reaches it | **PASS** | `/usr/lib/security/pam_selinux.so         linked` |
| 11 | the stock packages were replaced, not installed alongside | **PASS** | `util-linux-selinux` |
| 12 | openssh was not downgraded by the rebuild | **PASS** | `OpenSSH_10.5p1, OpenSSL 3.6.4 25 Aug 2026` |
| 13 | init runs in a domain of its own | **FAIL** | `system_u:system_r:kernel_t` |
| 14 | sshd runs in a domain of its own | **PASS** | `system_u:system_r:sshd_t` |
| 15 | the ssh session is not simply sshd's own context | **PASS** | `staff_u:staff_r:staff_t` |
| 16 | the profile's pam_faillock settings survived the pambase replacement | **PASS** | `12:# If you drop the above call to pam_faillock.so the lock will be done also` |
| 17 | the transition is pam_selinux's, and it is in the sshd stack | **PASS** | `/etc/pam.d/system-login:20:session    required   pam_selinux.so open` |
| 18 | the operator logs in as staff_t, not as the default user_t | **PASS** | `staff_u:staff_r:staff_t` |
| 19 | and sudo lands in sysadm_t, which is the whole point | **PASS** | `staff_u:sysadm_r:sysadm_t` |
| 20 | the login domain is confined: sysadm_t is reached by sudo, not by ssh | **PASS** | `allow_ptrace --> off` |
| 21 | the mapping is %wheel -> staff_u in the policy store's seusers | **PASS** | `%wheel:staff_u` |
| 22 | and sudoers carries the role transition for that same group | **PASS** | `Defaults:%wheel role=sysadm_r, type=sysadm_t` |
| 23 | omarchy-server-selinux status reports both halves | **PASS** | `sudoers:    (not readable without root)` |
| 24 | /etc and /usr carry real labels, not unlabeled_t | **PASS** | `system_u:object_r:sshd_exec_t /usr/bin/sshd` |
| 25 | findutils here cannot do the sweep, which is why the check below does not use it | **PASS** | `exit=0` |
| 26 | no file under /etc /usr /var has a label the policy disagrees with | **PASS** | `wrong=0` |
| 27 | /home/<user> is labelled user_home_dir_t, not unlabeled | **PASS** | `staff_u:object_r:user_home_dir_t /home/omarchy` |
| 28 | and nothing under /home has a label the policy disagrees with | **PASS** | `wrong=0` |
| 29 | the relabel flag was cleared, so the next boot does not repeat it | **PASS** | `ls: cannot access '/.autorelabel': No such file or directory` |
| 30 | the first-boot relabel unit ran and succeeded | **PASS** | `omarchy-server-selinux-relabel.service: Consumed 804ms CPU time over 1.161s wall clock time, 87.7M memory pea…` |
| 31 | sudo still works | **PASS** | `root` |
| 32 | a snapper snapshot can be taken | **PASS** | `1 \| single \|       \| Sat Aug 29 14:24:00 2026 \| root \|         \| selinux-acceptance \|` |
| 33 | pacman can run a transaction | **PASS** | `pacman-ok` |
| 34 | the docker addon installs and runs a container | **PASS** | `1` |
| 35 | nothing in the container runtime tree is unlabeled or non-container | **PASS** | `bad=0` |
| 36 | the size of that disagreement is recorded, not repaired | **PASS** | `differs-from-static-policy=10` |
| 37 | the fwall addon installs | **PASS** | `/usr/bin/fwall` |
| 38 | the firewall still answers | **PASS** | `22/tcp                     LIMIT IN    Anywhere` |
| 39 | a login on the serial console reaches a shell in a user domain | **PASS** | `active` |
| 40 | omarchy-server-update completes | **PASS** | `reboot required: no` |
| 41 | and the same update run the way the timer runs it | **PASS** | `the machine should not have made is a hole, not a fix.` |
| 42 | permissive: the denial count was measured | **PASS** | `boot id after:  5ca9aa28-46c2-4048-895c-5ac8d2bd73a7` |
| 43 | the machine came back over ssh after a reboot | **PASS** | `boot_id 366a0134-67d1-4f5f-8f17-7fdd61a7d93b -> 5ca9aa28-46c2-4048-895c-5ac8d2bd73a7` |
| 44 | SELinux is still in the mode it was left in | **PASS** | `Permissive` |
| 45 | and the boot produced no new denials before login | **PASS** | `0` |

### Acceptance — SELinux, enforcing

**59 passed, 0 failed.** Full evidence in [`acceptance-selinux-enforce.txt`](../pocs/server-install/reference/srvsel/acceptance-selinux-enforce.txt).

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 1 | the kernel initialised SELinux | **PASS** | `lsm=landlock,lockdown,yama,integrity,selinux,bpf` |
| 2 | lsm= names selinux, with lockdown ahead of it and bpf last | **PASS** | `lsm=landlock,lockdown,yama,integrity,selinux,bpf` |
| 3 | the cmdline came from inside the UKI, not from limine.conf | **PASS** | `in-cmdline=1` |
| 4 | the refpolicy-arch policy is loaded | **PASS** | `Max kernel policy version:      35` |
| 5 | /etc/selinux/config says what the addon wrote | **PASS** | `/etc/selinux/config.refpolicy-arch` |
| 6 | the profile's own file contexts are in the policy store | **PASS** | `/opt/containerd(/.*)?	system_u:object_r:container_var_lib_t` |
| 7 | and they are what the profile's commands actually carry | **PASS** | `system_u:object_r:bin_t /usr/share/omarchy/bin/omarchy-server-update` |
| 8 | the base selinux addon did NOT pull setools or selinux-python in | **PASS** | `error: package 'setools' was not found` |
| 9 | and the policy tools are offered as their own addon | **PASS** | `selinux` |
| 10 | every binary that needs libselinux reaches it | **PASS** | `/usr/lib/security/pam_selinux.so         linked` |
| 11 | the stock packages were replaced, not installed alongside | **PASS** | `util-linux-selinux` |
| 12 | openssh was not downgraded by the rebuild | **PASS** | `OpenSSH_10.5p1, OpenSSL 3.6.4 25 Aug 2026` |
| 13 | init runs in a domain of its own | **PASS** | `system_u:system_r:init_t` |
| 14 | sshd runs in a domain of its own | **PASS** | `system_u:system_r:sshd_t` |
| 15 | the ssh session is not simply sshd's own context | **PASS** | `staff_u:staff_r:staff_t` |
| 16 | the profile's pam_faillock settings survived the pambase replacement | **PASS** | `12:# If you drop the above call to pam_faillock.so the lock will be done also` |
| 17 | the transition is pam_selinux's, and it is in the sshd stack | **PASS** | `/etc/pam.d/system-login:20:session    required   pam_selinux.so open` |
| 18 | the operator logs in as staff_t, not as the default user_t | **PASS** | `staff_u:staff_r:staff_t` |
| 19 | and sudo lands in sysadm_t, which is the whole point | **PASS** | `staff_u:sysadm_r:sysadm_t` |
| 20 | the login domain is confined: sysadm_t is reached by sudo, not by ssh | **PASS** | `allow_ptrace --> off` |
| 21 | the mapping is %wheel -> staff_u in the policy store's seusers | **PASS** | `%wheel:staff_u` |
| 22 | and sudoers carries the role transition for that same group | **PASS** | `Defaults:%wheel role=sysadm_r, type=sysadm_t` |
| 23 | omarchy-server-selinux status reports both halves | **PASS** | `sudoers:    (not readable without root)` |
| 24 | /etc and /usr carry real labels, not unlabeled_t | **PASS** | `system_u:object_r:sshd_exec_t /usr/bin/sshd` |
| 25 | findutils here cannot do the sweep, which is why the check below does not use it | **PASS** | `exit=0` |
| 26 | no file under /etc /usr /var has a label the policy disagrees with | **PASS** | `wrong=0` |
| 27 | /home/<user> is labelled user_home_dir_t, not unlabeled | **PASS** | `staff_u:object_r:user_home_dir_t /home/omarchy` |
| 28 | and nothing under /home has a label the policy disagrees with | **PASS** | `wrong=0` |
| 29 | the relabel flag was cleared, so the next boot does not repeat it | **PASS** | `ls: cannot access '/.autorelabel': No such file or directory` |
| 30 | the first-boot relabel unit ran and succeeded | **PASS** | `--- switching to enforcing ---` |
| 31 | enforcing is accepted from a session that can undo it | **PASS** | `mode=Enforcing` |
| 32 | and it will still be enforcing after a reboot | **PASS** | `SELINUX=enforcing` |
| 33 | and it is a TWO-way door: back to permissive and forward again, over ssh | **PASS** | `fwd=Enforcing` |
| 34 | and forward again left it enforcing | **PASS** | `Enforcing` |
| 35 | sudo still works | **PASS** | `root` |
| 36 | a snapper snapshot can be taken | **PASS** | `4 \| single \|       \| Sat Aug 29 14:24:37 2026 \| root \|         \| selinux-acceptance \|` |
| 37 | pacman can run a transaction | **PASS** | `pacman-ok` |
| 38 | the docker addon installs and runs a container | **PASS** | `1` |
| 39 | nothing in the container runtime tree is unlabeled or non-container | **PASS** | `bad=0` |
| 40 | the size of that disagreement is recorded, not repaired | **PASS** | `differs-from-static-policy=10` |
| 41 | the fwall addon installs | **PASS** | `/usr/bin/fwall` |
| 42 | the firewall still answers | **PASS** | `22/tcp                     LIMIT IN    Anywhere` |
| 43 | a login on the serial console reaches a shell in a user domain | **PASS** | `active` |
| 44 | omarchy-server-update completes | **PASS** | `reboot required: no` |
| 45 | and the same update run the way the timer runs it | **PASS** | `--- a kernel transaction under enforcing ---` |
| 46 | a kernel transaction completes with the initramfs and UKI rebuilt | **PASS** | `uki=/boot/EFI/Linux/omarchy_linux.efi rebuilt=no` |
| 47 | no mkinitcpio or UKI build error appeared in that transaction | **PASS** | `no-build-errors` |
| 48 | and the boot entry still points at a UKI that exists | **PASS** | `-rwx------. 1 root root 39224320 Aug 29 14:22 omarchy_linux.efi` |
| 49 | the kernel transaction was refused nothing in enforcing | **PASS** | `enforcing-denials=0` |
| 50 | the classifier does not ask for a reboot after a same-version rebuild | **PASS** | `(none in this boot's kernel log)` |
| 51 | enforcing: nothing was denied under the workload | **PASS** | `boot id after:  cbe20e1f-64ae-4885-b355-8a0d079adb4c` |
| 52 | the machine came back over ssh after a reboot | **PASS** | `boot_id 5ca9aa28-46c2-4048-895c-5ac8d2bd73a7 -> cbe20e1f-64ae-4885-b355-8a0d079adb4c` |
| 53 | SELinux is still in the mode it was left in | **PASS** | `Enforcing` |
| 54 | and the boot produced no new denials before login | **PASS** | `--- reproducing the disable-path UKI rebuild (§11.5) ---` |
| 55 | limine-update rebuilds the UKI under enforcing, before anything is disabled | **PASS** | `no-build-errors` |
| 56 | and again with the dontaudit rules removed, which is where a silent denial shows | **PASS** | `no-build-errors` |
| 57 | omarchy-server-selinux disable completes, drop-in and sudoers role removed | **PASS** | `dropin=removed` |
| 58 | and that disable rebuilt the UKI without a build error | **PASS** | `no-build-errors` |
| 59 | the rebuilt UKI no longer carries lsm=...selinux | **PASS** | `verdict=selinux-gone-from-cmdline` |

### Attack surface

| Metric | Value |
|---|---|
| Packages installed | **229** |
| Explicitly installed | **39** |
| Installed as a dependency | **190** |
| Installed size (MiB) | **1501** |
| `linux-firmware` (MiB) | **408** |
| Enabled unit files | **22** |
| Masked unit files | **13** |
| Listening sockets (`ss -ltnup`) | **6** |
| setuid/setgid binaries | **16** |
| Services running as root | **9** |

### Reboot survival

The machine came back over ssh after `systemctl reboot`.

| | |
|---|---|
| Verdict | rebooted: boot time moved from 2026-08-29 14:25:02 to 2026-08-29 14:25:27 |
| ssh | ssh answered 1s after the reboot request |
| Boot | Startup finished in 795ms (firmware) + 2.618s (loader) + 910ms (kernel) + 2.740s (userspace) = 7.065s |
| Failed units | 0 loaded units listed. |

## Evidence

- [`acceptance-selinux.txt`](../pocs/server-install/reference/srvsel/acceptance-selinux.txt) — the acceptance run, raw
- [`acceptance-selinux-enforce.txt`](../pocs/server-install/reference/srvsel/acceptance-selinux-enforce.txt) — the acceptance run, raw
- [`surface.txt`](../pocs/server-install/reference/srvsel/surface.txt) — the attack-surface measurements, raw
- [`reboot-check.txt`](../pocs/server-install/reference/srvsel/reboot-check.txt) — the reboot survival check
- [`packages-all.txt`](../pocs/server-install/reference/srvsel/packages-all.txt) — the package list of the installed machine
- [`boot-time.txt`](../pocs/server-install/reference/srvsel/boot-time.txt) — boot timing
- [`omarchy-install.log`](../pocs/server-install/reference/srvsel/omarchy-install.log) — the install log of the orchestrator

## Limitations

The tables were written by `serverlab report` from the evidence files listed
above. The rest of this section is not generated, and it is the part that
matters.

### What this run set out to answer, and did

§11.5 of [`2026-08-29-mandatory-access-control.md`](2026-08-29-mandatory-access-control.md)
left one thing open: `omarchy-server-selinux disable` rebuilt the UKI through
`limine-update`, that rebuild printed **"WARNING: errors were encountered
during the build"** and **"ERROR: mkinitcpio failed for kernel …, skipping"**,
and **no AVC was logged** — so the report could not say whether SELinux was
involved. It was, and both halves of that sentence turned out to be wrong.

**The denial was always there.** The earlier run looked with `ausearch`.
`ausearch` reads auditd's log, and this profile does not install auditd. The
records were in the kernel ring buffer the whole time, and `journalctl -k -g
'avc: *denied'` had them. There are three, and they say:

```
avc: denied { search } for comm="depmod" name="mkinitcpio.tQq4WU" tclass=dir
     scontext=staff_u:sysadm_r:kmod_t tcontext=staff_u:object_r:user_tmp_t
```

**The mechanism.** mkinitcpio assembles the image in a `mktemp -d` under `/tmp`
and then runs `depmod -b <buildroot>` over it. `depmod` execs kmod, which
type-transitions into `kmod_t`; the build root was created by the
administrator's shell, so it is `user_tmp_t`; and `kmod_t` has no rule to so
much as **search** a `user_tmp_t` directory. depmod cannot enter the tree it was
pointed at, exits non-zero, mkinitcpio raises its build-error flag, and
limine-entry-tool skips the UKI. The drop-in removal therefore never reached the
running command line, which is exactly the symptom §11.5 recorded: the machine
came back still enforcing.

**Why two rounds of validation missed it.** It is rule 23's shape: an
administrative path the update timer never takes. Under the timer pacman is
`initrc_t` and its temporaries are `initrc_tmp_t`, where refpolicy's `kmod_t`
works. Run by hand — `sudo pacman -S linux`, `omarchy-server-selinux disable`,
`limine-update` — pacman is `sysadm_t` and the same build root lands in the
administrator's tmp. A machine whose kernel is updated by the timer never sees
it; a machine whose operator updates it by hand cannot rebuild its own boot
image. §10 and §11 both exercised the timer path and passed.

**It was ours, and it is fixed.** Rules 24 and 25 of `omarchy_server.te`.
This run is the fixed policy: `limine-update` under enforcing, the same command
again with `semodule -DB` so a silenced denial would have shown, a real
`pacman -S linux`, and the full `disable` — **59 passed, 0 failed, zero
enforcing denials**, and item 59 reads the `.cmdline` section out of the
rebuilt UKI and finds no `lsm=…selinux` in it. The disable path reaches the
running command line now.

### What it does not prove

**The one failure is in the permissive pass and is not a regression.** Item 8
of the permissive list, "init runs in a domain of its own", reads `kernel_t`
rather than `init_t`. That is the **first boot after the install-time relabel**:
PID 1 started before the new labels were in place. The enforcing pass, which
runs after a reboot, reads `init_t`. It is a property of the first boot, it has
been there since §10, and nothing in this run changed it — but a suite that
reports it as a failure on every fresh install is a suite that trains people to
ignore a red line, and that is worth fixing separately.

**`rebuilt=no` in item 46 is a bad signal, not a bad result.** The check
compares the UKI's mtime across the transaction and the mtime did not move; the
transcript in the same evidence shows "Creating unified kernel image … Unified
kernel image generation successful" and "Updated: /boot/limine.conf". The ESP is
vfat and limine-entry-tool installs through a temporary file, so mtime is not a
reliable witness here. Items 47 (no build errors), 48 (the entry still points at
a UKI) and 49 (zero enforcing denials) are what the conclusion rests on.

**A kernel that actually moves version was not exercised.** `pacman -S linux`
reinstalled the version already on the machine, because Arch had not moved it.
That is the harder case for the classifier and the same work for mkinitcpio —
the initramfs and the UKI are rebuilt either way — but the reboot-into-a-new-
kernel half is untested under enforcing.

**One VM, one workload, one operator.** The `%wheel → staff_u → sysadm_t`
arrangement has still been through one account. And the denial count is only
worth reading because of how it was reached: item 49 counts `permissive=0`
records only, and item 56 re-runs the rebuild with every `dontaudit` removed —
a zero that has not been checked that way is a zero that means nothing.

**Nothing about `secadm_r`.** Unchanged from §11: the administrative role here
is `sysadm_r`, which can load policy and set enforcing.
