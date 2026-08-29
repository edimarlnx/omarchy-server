# Mandatory access control: SELinux and AppArmor, measured side by side

**Date** 2026-08-29 · **Scope** both routes built, packaged, installed from the
ISO on fresh VMs, and run against the same workload in their logging mode and
then in their enforcing mode.

**Result in one line.** AppArmor reached enforce and stayed there: **24/24**,
zero denials under the whole workload, and the machine came back from a reboot
still confined. SELinux reached permissive cleanly (**28/30**) and then
**locked the operator out** when it went enforcing — root-caused, fixed in
code, and re-validated on a fresh install in **§10**.

Neither is recommended as a default today. §8 says what would change that, and
**§10.7 revisits it** against what the re-validation measured.

---

## 1. Environment

| | |
|---|---|
| ISO | `omarchy-2026.08.29-x86_64-server-local.iso`, 3004 MiB (the same builder, without either addon, produces 2876 MiB) |
| VMs | QEMU/KVM q35, 4 vCPU, 8 GiB, OVMF 4M **without** Secure Boot, 40 GiB virtio disk, user-mode networking |
| `srvsel` | installed with `mkcidata.sh --mac selinux`, hostname `omarchy-selinux` |
| `srvaa` | installed with `mkcidata.sh --mac apparmor`, hostname `omarchy-apparmor` |
| Baseline | the lean server base of `reports/2026-08-28-lean-secure-base.md`: 220 packages, 1402 MiB, 21 enabled units, 6.920 s boot |
| Packages | `omarchy-server-pkgs` at the SELinux manifest's pinned commit `95e4d01`; `apparmor` 4.1.7-1 from Arch `extra` |
| Evidence | `pocs/server-install/reference/acceptance-{selinux-permissive,selinux-enforcing,apparmor-complain,apparmor-enforce}.txt` |

The design is `docs/mac.md`. This report is what happened when it was run.

---

## 2. The kernel half, confirmed on the machine

Read from `/proc/config.gz` on `srvaa`, not from documentation:

```
CONFIG_SECURITY_SELINUX=y
CONFIG_SECURITY_SELINUX_BOOTPARAM=y
CONFIG_SECURITY_APPARMOR=y
CONFIG_LSM="landlock,lockdown,yama,integrity,bpf"
```

Both LSMs are compiled into Arch's stock kernel and neither is in `CONFIG_LSM`.
The `lsm=` drop-in the addons write is the entire kernel-side switch, and it
arrived through the UKI as designed:

```
$ grep -o 'lsm=[^ ]*' /proc/cmdline     # srvaa
lsm=landlock,lockdown,yama,integrity,apparmor,bpf
$ grep -o 'lsm=[^ ]*' /proc/cmdline     # srvsel
lsm=landlock,lockdown,yama,integrity,selinux,bpf
```

Both machines confirmed the flag is in the UKI and not in `limine.conf`. No
kernel was rebuilt for either route. That part of the premise holds exactly.

---

## 3. Building the SELinux set

Nineteen packages (25 files, counting the split builds), from
`archlinuxhardened/selinux` at the pinned commit, built by
`omarchy-server-pkgs/scripts/build-selinux.sh` in an `archlinux:latest`
container on 28 cores.

| Package | Build | Package file |
|---|---:|---:|
| libsepol | 16 s | 0.7 MiB |
| libselinux | 39 s | 0.5 MiB |
| checkpolicy | 15 s | 0.4 MiB |
| secilc | 14 s | 0.02 MiB |
| setools | 35 s | 1.1 MiB |
| libsemanage | 21 s | 0.3 MiB |
| semodule-utils | 13 s | 0.02 MiB |
| policycoreutils | 19 s | 0.2 MiB |
| selinux-python | 20 s | 2.6 MiB |
| selinux-alpm-hook | 5 s | 0.01 MiB |
| selinux-refpolicy-arch | 34 s | 3.1 MiB |
| pambase-selinux | 3 s | 0.005 MiB |
| pam-selinux | 78 s | 0.7 MiB |
| coreutils-selinux | 406 s | 3.9 MiB |
| util-linux-selinux | 230 s | 7.5 + 0.6 MiB |
| shadow-selinux | 65 s | 1.3 MiB |
| sudo-selinux | 57 s | 2.3 MiB |
| openssh-selinux | 82 s | 1.9 MiB |
| systemd-selinux | 455 s | 12.7 + 1.7 MiB (+ tests/ukify/resolvconf) |
| **total** | **~27 min** | **50 MiB of package files** |

Wall-clock was several times that: `ftp.openbsd.org` served the 2 MiB OpenSSH
tarball at ~85 KB/s on a link doing 20 MB/s to GitHub, which is why
`build-selinux.sh` now points `SRCDEST` at a host directory so a rebuild
reuses what the last one fetched.

### Five things that had to be fixed to get a build at all

Each is recorded because each is a cost somebody adopting this route pays too.

1. **`libselinux` 3.10 does not build against Arch's Python.** It calls
   `PyString_FromString`, which SWIG's generated header no longer defines under
   Python 3.14, and GCC 15 rejects the resulting implicit declaration. Upstream
   fixed it after the release; the fix is backported in
   `pkgbuilds/selinux-overrides/libselinux/`.
2. **`openssh-selinux` was a downgrade.** Upstream pins 10.4p1-3 while Arch
   ships 10.5p1-1, and the package `provides=openssh` — so installing it
   silently moves the one network-facing daemon back one release. The override
   is Arch's current PKGBUILD with the four SELinux changes.
3. **`sepolgen` is unbuildable and unwanted.** The standalone package is the
   2016 release, still wants python2, and `selinux-python` both
   `provides=sepolgen` and `conflicts=sepolgen<2.7`. Dropped from the set.
4. **`pacman --noconfirm` cannot replace a conflicting package.** The default
   answer to `:: X and Y are in conflict. Remove Y?` is no, and the whole
   transaction fails. Observed verbatim on `pambase-selinux`. Fixed with
   `--ask=4`, carried by `profile/server/addons/selinux.pacman-args` so the
   installed-machine path and the ISO chroot path use the same flag.
5. **`po4a` lives in `/usr/bin/vendor_perl`.** A build script with a
   hand-written `PATH` makes meson report `Program po4a found: NO` and fail
   `util-linux-selinux` with the package installed.

Two further problems appeared only in the ISO builder and are recorded in §4.

---

## 4. Getting the packages into the ISO

The SELinux packages exist in no public repository, so the ISO's offline mirror
cannot download them. `iso/patches/0011` copies them in from
`<pkgs-checkout>/prebuilt/`. Two bugs, both found by a failed install:

1. **The first version broke the install entirely.** It added the prebuilt
   names to `local_package_names`, which is also the list the builder resolves
   to count the packages the target will end up with — and resolving
   `systemd` and `systemd-selinux` together is an unsatisfiable transaction.
   `ERROR: could not resolve the target package count from the offline mirror.`
   Fixed by giving the prebuilt set its own array, used for the download
   exclusion and the prune keep-set but not for the expected-package count.
2. **The second version failed in the target chroot.** Excluding a package from
   the online download also means nothing pulls its dependencies:

   ```
   warning: cannot resolve "python-networkx>=2.6", a dependency of "setools"
   warning: cannot resolve "python-setuptools", a dependency of "setools"
   :: unable to satisfy dependency 'python-audit' required by 'selinux-python'
   ```

   Fixed by reading each prebuilt package's `.PKGINFO` `depend =` lines and
   adding them to the download list.

The ISO grew **2876 → 3004 MiB (+128 MiB)**, which is the SELinux set, its
dependency closure and `apparmor`, all bundled but not installed.

---

## 5. AppArmor

### 5.1 What it costs

| | Base | `srvaa` | Delta |
|---|---:|---:|---:|
| Packages | 220 | **222** | **+2** (`apparmor`, `python-legacy-cgi`) |
| Installed size | 1402 MiB | **1408 MiB** | **+6 MiB** |
| Enabled units | 21 | **22** | **+1** (`apparmor.service`) |
| Boot | 6.920 s | 7.376 s | +0.46 s, of which +0.09 s kernel; the rest is loader variance |

`audit`, the third dependency, is already in the base.

### 5.2 What it actually confines

This is the number that decides the route, and it is not flattering:

```
== loaded profiles ==
163 profiles are loaded.
78 profiles are in enforce mode.

== coverage ==
2 of 146 profiles under /etc/apparmor.d name a binary this machine has
  bin.ping
  usr.bin.sshd
```

Arch's `apparmor` package ships profiles for 1Password, Discord, Chrome,
Firefox, Xorg, MongoDB Compass, Evolution, Element — desktop software. On a
headless server **two** of them match a binary that exists, and one of those two
(`usr.bin.sshd`) is the profile this addon ships itself, because Arch's copy
lives under `/usr/share/apparmor/extra-profiles`, is not enabled, names
Debian's `/usr/sbin/sshd`, and carries upstream's own warning that these
profiles "may not work on default configurations".

So the honest description of the AppArmor route on this profile is: **it
confines sshd, and that is the whole of it.** `ping` comes along for free.

The shipped sshd profile is upstream's with three changes (Arch paths, the
`local/` include renamed, and the `internal-sftp` block that grants `/** r` and
`owner /** rwl` commented out). The acceptance verified all three, including
that the blanket read of the filesystem is not granted.

### 5.3 Complain, then enforce

| Run | Result | Denials under the workload |
|---|---|---:|
| complain | **21 passed, 1 failed** | **0** |
| enforce | **24 passed, 0 failed** | **0** |

The workload in both: ssh by key, sudo, a snapper snapshot, a `pacman -Sy`
transaction, `omarchy-server-addon docker` plus `docker run hello-world`,
`omarchy-server-addon fwall`, `ufw status`, the serial getty, the mutual
exclusion refusal, `omarchy-server-update`, and a reboot.

Zero denials in complain mode meant the switch to enforce was uneventful, and
enforce was then confirmed to be real rather than nominal: a write the profile
does not allow was refused, and the machine came back from a reboot with sshd
still under the profile.

The one failure in the complain run is a test artifact, not a finding: the
post-reboot check ran before ssh was answering again and got empty output. The
same assertion passed in the enforce run, and re-checking the machine by hand
afterwards showed `/usr/bin/sshd (complain)` as expected.

---

## 6. SELinux

### 6.1 What it costs

| | Base | `srvsel` | Delta |
|---|---:|---:|---:|
| Packages | 220 | **274** | **+54** |
| Installed size | 1402 MiB | **1954 MiB** | **+552 MiB** |
| Enabled units | 21 | 21 | 0 |
| Boot | 6.920 s | 7.814 s | +0.89 s, of which +0.10 s kernel |
| Install (orchestrator) | 28.9 s | **45 s** | +16 s (policy store + offline relabel) |

**+552 MiB is 39% on top of the whole base install**, and the reason is not
SELinux:

```
$ pacman -Qi python-scipy | grep 'Required By'
Required By     : python-networkx
$ pacman -Qi python-networkx | grep 'Required By'
Required By     : setools
```

`setools` depends on `python-networkx`, and Arch's `python-networkx` lists
`python-scipy`, `python-pandas`, `python-matplotlib` and `python-numpy` as hard
dependencies rather than optional ones. A headless server that turns on SELinux
gets a scientific Python stack.

Measured precisely: removing `setools` and `selinux-python` and everything that
came in with them, minus what the base already had, is **45 packages and
452.9 MiB** — 82% of the route's entire size cost. The ten biggest:

```
   118.6 python-scipy        21.2 python-fonttools
   110.3 python-pandas       15.1 lapack
    49.2 python-numpy        13.4 openjpeg2
    32.7 python-matplotlib    9.5 aom
    24.4 python-networkx      7.5 rav1e
```

What is lost by dropping them: `semanage`, `audit2allow` and `sesearch` on the
machine. The policy still loads, `restorecon`/`setfiles`/`semodule` still work,
and policy would be authored on a workstation and shipped as a `.pp`. This
profile's own setup leaf uses `semanage fcontext`, so the change is not a
one-line edit — which is why it is a recommendation in §8 and not a change made
here.

### 6.2 What it confines, and it is a different order of thing

```
$ tr -d '\0' </proc/1/attr/current
system_u:system_r:init_t
$ for p in $(pgrep -x sshd); do tr -d '\0' </proc/$p/attr/current; done
system_u:system_r:sshd_t
$ id -Z
user_u:user_r:user_t
```

init, sshd and the logged-in session are in three different domains, and the
session's domain came from `pam_selinux.so open` in the `system-login` stack
that `pambase-selinux` ships. Every service systemd starts transitions at exec.
`/etc` and `/usr` carry real labels, and the profile's own commands carry the
`bin_t` the addon's local file context assigns:

```
$ ls -Z /usr/share/omarchy/bin/omarchy-server-update
system_u:object_r:bin_t omarchy-server-update
```

The rebuild set does what it exists for. All seven checked binaries reach
`libselinux`, and two of them do it in ways `ldd` alone would have called a
failure:

| | how it reaches libselinux |
|---|---|
| `/usr/lib/systemd/systemd` | **dlopen** — modern systemd loads it at runtime |
| `/usr/lib/ssh/sshd-session` | linked — OpenSSH 9.8+ split the daemon; the listener `/usr/bin/sshd` does not link it and does not need to |
| `ls`, `id`, `sudo`, `useradd`, `mount`, `pam_selinux.so` | linked |

`/usr/bin/login` (from `util-linux-selinux`) links neither and mentions neither.
The console transition happens through `pam_selinux` regardless, so this is a
gap in inspection rather than in confinement — but it is a gap, and worth
knowing before trusting `login` to set a context.

And one thing that cannot be had: **`ps -Z` does not work.** There is no
`procps-ng-selinux` and Arch's `procps-ng` does not link `libselinux`. A
process's context comes from `/proc/PID/attr/current`, which is what
`omarchy-server-selinux status` reads.

### 6.3 Permissive: 28 passed, 2 failed, 55 denials

Both failures are real, and both are the same class of problem — **replacing a
core package undoes what the profile did to it**.

**The account-lockout hardening was silently reverted.**
`install/server/increase-lockout-limit-server.sh` seds `deny=10
unlock_time=120` into the two `pam_faillock` lines of `/etc/pam.d/system-auth`.
That file belongs to `pambase`. When pacman removed `pambase` and installed
`pambase-selinux`, it saved the edited file as `system-auth.pacsave` and
installed the package's own — stock, no options, no `.pacnew`, no message:

```
$ grep -n pam_faillock /etc/pam.d/system-auth
3:auth  required        pam_faillock.so      preauth
$ grep -n pam_faillock /etc/pam.d/system-auth.pacsave
3:auth  required        pam_faillock.so preauth silent deny=10 unlock_time=120
```

A machine that turned SELinux on quietly went from a 10-attempt lockout to
none. Fixed: the setup leaf now re-applies that leaf after the replacement, and
the acceptance checks for it.

**`omarchy-server-update` failed.** `omarchy-update-dev` reads `$OMARCHY_PATH`
under `set -u` on its first line; the variable comes from
`/etc/profile.d/omarchy-path.sh`, which only a login shell reads. On `srvsel`
the non-interactive root environment did not carry it and the update died with
`OMARCHY_PATH: unbound variable`; on `srvaa` the same command succeeded.
The exact mechanism by which the SELinux userland changes that environment was
**not isolated**, and this report does not claim it. What is clear is that
depending on the caller's environment is the bug: `omarchy-server-update` now
sets `OMARCHY_PATH` itself, which is right with or without a MAC.

The 55 AVC denials, by count:

```
    10  sshd_t          -> unlabeled_t       : dir  { search }
     2  user_t          -> unlabeled_t       : file { open }
     2  user_t          -> ldconfig_cache_t  : dir  { write }
     2  user_t          -> etc_t             : dir  { write }
     2  syslogd_t       -> tmpfs_t           : dir  { search }
     1  user_sudo_t     -> user_sudo_t       : capability { net_admin }
     1  systemd_networkd_t -> tmpfs_t        : dir  { read open }
     ... 34 more, mostly user_t and sshd_t against unlabeled_t
```

`unlabeled_t` dominates, and that is the whole story of what happened next.

### 6.4 Enforcing: it locked the operator out

20 passed, 9 failed, and the run could not finish.

```
[PASS] the machine is enforcing
[FAIL] and it will still be enforcing after a reboot
       Could not chdir to home directory /home/omarchy: Permission denied
[FAIL] sudo still works
       bash: line 1: /home/omarchy/.lab-sudo: Permission denied
```

`/home` was labelled `home_root_t` correctly. `/home/omarchy` was not labelled
at all, and `user_t` may not search `unlabeled_t` — so the session could not
reach its own home directory, could not run anything from it, and `sudo` went
with it. Nothing could be undone from inside afterwards.

**Root cause.** The addon relabels the filesystem offline, inside the install
chroot, in the addon phase. The orchestrator creates the user's home directory
in a phase that runs **after** that. The relabel could not have covered it.
Invisible in permissive; fatal on the first `setenforce 1`.

**Second finding, from trying to recover.** The standard advice — add
`enforcing=0` at the bootloader — **does not work on this profile**. The kernel
command line lives inside the UKI, and a UKI entry ignores the `cmdline:` in
`limine.conf`. `omarchy-server-selinux enforcing` was printing that advice; it
now prints the three routes that do work (a session that still has root, an
earlier snapper snapshot from the Limine menu, or the installer medium).

**Three fixes, written and committed:**

1. `omarchy-server-selinux-relabel.service` — a one-shot unit gated on
   `/.autorelabel`, enabled by the addon, that relabels once on the first boot.
   The machine boots permissive, so there is no window in which a wrong label
   refuses anything; by the time anyone switches to enforcing the labels are
   right. `/.autorelabel` is now deliberately left in place by the addon rather
   than removed, and the unit clears it.
2. `omarchy-server-selinux enforcing` refuses to enforce while there are
   unlabeled paths under `/home /root /etc /usr /var`, or while this boot has
   any AVC denial. `--force` is for somebody who has read the refusal and has a
   console. This guard alone would have turned the lockout into a message.
3. The corrected recovery instructions above.

**Re-validated on a fresh install — see §10.** The three fixes were not enough
on their own, and §10 is the run that found out why.

---

## 7. Surface, side by side

| | Base | AppArmor | SELinux |
|---|---:|---:|---:|
| Packages | 220 | 222 (+2) | 274 (+54) |
| Installed size | 1402 MiB | 1408 MiB (+6) | 1954 MiB (+552) |
| Enabled units | 21 | 22 (+1) | 21 (+0) |
| Boot | 6.920 s | 7.376 s | 7.814 s |
| Install time | 28.9 s | ~29 s | 45 s |
| Packages replaced | 0 | 0 | **10** |
| Kernel rebuilt | no | no | no |
| Confines sshd | yes | yes |
| Confines the login session | **no** — the shell is `Uxr`, it leaves the profile | **yes** — `user_u:user_r:user_t` |
| Confines every other service | no (no profile matches) | yes (the reference policy has domains) |
| Denials under the workload | 0 complain, 0 enforce | 55 permissive, 53 enforcing |
| Reached enforcing | **yes** | **not yet** |

### Against a short compliance-style checklist

| Control | AppArmor | SELinux |
|---|---|---|
| Process confinement of sshd | yes, one profile, enforce | yes, `sshd_t`, and the session gets `user_t` |
| Process confinement of sudo | no | yes, `user_sudo_t` |
| Process confinement of the container runtime | no | the reference policy has container domains; not exercised here |
| Confinement of every other system service | no — no profile matches | yes by construction |
| File labeling | not applicable to the model | yes, verified across `/etc`, `/usr`, the profile's own tree |
| Audit trail of policy decisions | yes, `apparmor="DENIED"` in the kernel log | yes, `avc: denied` in the kernel log, with subject and object contexts |
| Local policy without rebuilding | yes, `/etc/apparmor.d/local/*` | yes, `semanage` + a `.pp` module |
| Mechanism is a switch, not a fork | yes | yes for the kernel, no for the userland — 10 replaced packages |

---

## 8. Recommendation

**Ship AppArmor as the switch. Do not ship SELinux as a default, and do not
throw it away.**

For AppArmor, and the reasons to pass on to Omarchy:

- It costs **two packages and 6 MiB**. Nothing is replaced, nothing has to be
  kept in lockstep with Arch, and a pipeline that turns it on is turning on a
  package Arch already maintains plus one kernel command line flag.
- It reached **enforce with zero denials** on the first attempt and survived a
  reboot. There is no policy to author before a machine is usable.
- It cannot lock the operator out the way the SELinux run did, because the
  profile set is tiny and does not govern the login session at all.
- And that last clause is also the honest limit: **it confines sshd and
  nothing else.** Anyone told "this server runs AppArmor" should be told the
  number — 2 of 146 shipped profiles match a binary that exists here — because
  the difference between that and "the server is confined" is most of the
  value.

For SELinux, what would have to be true before it could be a default:

1. The three fixes from §6.4 validated on a fresh install, with an enforcing
   run that passes the workload. This is the immediate next step and is
   plausibly one build away — every enforcing failure traced to one unlabeled
   directory.
2. **Split the addon.** Move `setools` and `selinux-python` into a second,
   optional addon and rewrite the setup leaf's `semanage fcontext` call as a
   policy module. That is 45 packages and 453 MiB — 82% of the route's size
   cost — for tooling a fleet machine does not need, and it is the single
   biggest thing standing between this route and the profile's own premise.
3. **Automate the lockstep check.** Eight rebuilds `provides=` a core package,
   and one of the eight was already behind Arch at the pinned commit —
   `openssh-selinux`, i.e. the network-facing daemon, downgraded silently. A
   CI job comparing each `*-selinux` pkgver against Arch is not optional for
   anything that ships to real machines. `docs/packaging.md` §2.6 has the
   check; nothing runs it yet.
4. Decide what to do about `ps -Z`, which does not exist here, and about
   `/usr/bin/login` not linking `libselinux`.

The asymmetry is worth stating plainly, because it is the decision: **SELinux
confines vastly more and costs vastly more.** AppArmor gives a real, verifiable
answer to one question (is sshd confined) for almost nothing. SELinux gives a
real answer to all of them for 54 packages, 552 MiB, ten replaced core packages
and a standing maintenance obligation — and, today, one unvalidated fix between
here and a machine that stays reachable.

---

## 9. What this run does not prove

- The SELinux enforcing fixes. Written, not re-run. §6.4.
- The mechanism behind the `OMARCHY_PATH` difference between the two machines.
  The symptom and the fix are both real; the cause was not isolated.
- Secure Boot together with either MAC. Both are cmdline drop-ins that append,
  and they are designed to compose, but no machine in this run had both.
- Anything about containers under SELinux beyond `docker run hello-world` in
  permissive.
- Long-running behaviour. The longest thing either machine did was an
  `omarchy-server-update`.

---

## 10. Re-validation — SELinux on a fresh install, permissive then enforcing

**Date** 2026-08-29, later the same day · **Scope** the three fixes of §6.4
proven or disproven on a machine installed from scratch, plus the two changes
§8 asked for: the tooling split and the lockstep check.

**Result in one line.** Permissive is now **36/36**, with **0 AVC denials on a
boot**. Enforcing was reached and **the operator was not locked out** — ssh,
`sudo`, the home directory, snapper, `pacman` and a reboot all survived it. But
enforcing is **not usable** on this profile yet, for a reason nothing in §6 had
looked at: `sudo` does not change the SELinux role, so every administrative
command runs as `user_t` and most of them are refused.

### 10.1 What it took to get there

Five bugs stood between the §6.4 fixes and a working install. Each was found by
a run, and each is worth recording because each is a trap on this route.

| # | Bug | How it presented |
|---|---|---|
| 1 | `setfiles <file_contexts> /` reads **one** spec file | libselinux loads `file_contexts` + `.homedirs` + `.local` only when it opens the store *by policy type*; given a path it reads that file alone. So the relabel never applied the `/home/[^/]+ → user_home_dir_t` rule (it lives in `.homedirs`) nor the profile's own rules (`.local`). **This is the other half of the §6.4 lockout** — the late home directory was only the first half. Fixed by using `restorecon -R -F /`. |
| 2 | Concatenating the three specs for `setfiles` does not work | They legitimately disagree about `/root/.k5login` (`system_u` vs `root`), which libselinux resolves by precedence and `setfiles` rejects with *Multiple different specifications*, relabelling nothing. Tried, measured, reverted. |
| 3 | A four-field context is silently dropped | `system_u:object_r:bin_t:s0` is invalid on `refpolicy-arch`, which is `TYPE=standard`. `setfiles` prints one line, drops the rule and **exits 0**. `/usr/share/omarchy/bin` stayed `unlabeled_t` through two relabels with no failure anywhere. The setup leaf now derives the suffix from the policy's own `file_contexts` and **verifies the labels on disk afterwards** instead of trusting an exit status. |
| 4 | `/.snapshots` breaks every relabel | snapper mounts its five snapshots read-only; `restorecon -R /` reports *Read-only file system* for each file and exits non-zero, which would leave `/.autorelabel` in place and make `enforcing` refuse forever. Excluded. |
| 5 | The ssh host keys were `etc_t` | `sshdgenkeys.service` generates them on the first boot — **after** the relabel unit ran. The private host keys sat in `/etc/ssh` as `etc_t`, readable by every domain the policy lets read `/etc`. The relabel unit is now ordered `Wants=`/`After=sshdgenkeys.service` and `Before=sshd.service`. |

Bug 3 is the one to remember: **neither `setfiles` nor `restorecon` fails when a
spec line is invalid.** Any check on this route that trusts an exit status is
checking nothing.

A sixth was found in the *acceptance script itself*: the check for unlabeled
files used `find -context`, and Arch's `findutils` is not built against
libselinux (`findutils-selinux` is deliberately not in the rebuild set). The
predicate writes *"SELinux is not enabled"* to stderr and nothing to stdout, so
`| wc -l` returned a clean `0` and the check **passed without reading a file**.
It now uses `restorecon -nvR`, which answers a stronger question — every path
whose label differs from the policy, not merely the unlabeled ones. The
`enforcing` preflight had the same hole and now tests for the predicate first.

### 10.2 The local policy module

There is one now: `install/server/mac/selinux/omarchy_server.te`, 15 documented
blocks, compiled on the machine with `checkmodule` + `semodule_package`. Every
rule came from a measured denial. Getting there took six boot-and-measure
rounds, and the trajectory is the finding:

| Round | Boot denials | What changed |
|---:|---:|---|
| 1 | 18 | baseline, no module |
| 2 | 28 | first module; **new domains appeared** for the same PSI pattern |
| 3 | 18 | PSI rewritten against the `daemon` attribute |
| 4 | 18 | different set again — tmpfiles, modules, loadkeys |
| 5 | 12 | credentials generalised to `daemon` + `getty_t` |
| 6 | 4 | user-manager rules (gpg runtime, ManagedOOM) |
| 7 | **0** | gpg socket files, `system_dbusd_t → init_t:system status` |

Two rules are deliberately written against the `daemon` **attribute** rather
than per domain, and that is the lesson of rounds 2 and 4: the PSI
(`memory.pressure`) and systemd-credentials patterns are not "one service does
something odd", they are what systemd does for *every* unit. Enumerating
domains produced a list that grew on the next boot.

Everything in the module is the gap between **refpolicy 20250923** and
**systemd 261 / OpenSSH 10.5**: credentials on tmpfs, PSI, logind and networkd
over varlink instead of D-Bus, userdb, networkd's BPF, and the `system status`
class. None of it is a rule letting a confined domain reach something new.

One denial was fixed by **labelling instead of by policy**, which is the shape
to prefer: eight of the first eighteen were sshd reaching
`/var/lib/lastlog/lastlog2.db`. `refpolicy` knows `lastlog_t` and already grants
sshd what it needs on it, but only names `/var/log/lastlog` — shadow moved the
database. One line in `local-fcontexts` beat a rule widening `sshd_t` over all
of `var_lib_t`.

### 10.3 The tooling split (§8.2)

`setools` and `selinux-python` moved into a new **`selinux-tools`** addon.
What made it possible was rewriting the setup leaf to write the policy store's
`file_contexts.local` directly instead of calling `semanage fcontext` — the same
file, the same format, no `selinux-python` on the machine.

| | Base | SELinux before | SELinux now |
|---|---:|---:|---:|
| Packages | 220 | 274 (+54) | **229 (+9)** |
| Installed size | 1402 MiB | 1954 MiB (+552) | **1501 MiB (+99)** |
| Enabled units | 21 | 21 (+0) | **22 (+1)** — the relabel unit |
| Boot | 6.920 s | 7.814 s | 7.184 s |
| ISO | 2876 MiB without | 3003 MiB | 3003 MiB (unchanged — both addons are still bundled) |

**−45 packages and −453 MiB**, exactly the figure §6.1 predicted. Verified on
the machine: `setools`, `selinux-python`, `python-networkx`, `python-scipy` and
`python-pandas` are all *"was not found"*.

### 10.4 Permissive: 36 passed, 0 failed

Every check in `acceptance-selinux.sh` passes, including the ones this
re-validation added:

- `/home/omarchy` is `user_home_dir_t` — **the §6.4 lockout, gone.**
- nothing under `/home` or `/root` has a label the policy disagrees with;
- the profile's contexts are in `file_contexts.local` and on disk;
- the base addon pulled in neither `setools` nor `selinux-python`;
- the first-boot relabel unit ran and cleared `/.autorelabel`;
- `init` is `init_t`, `sshd` is `sshd_t`, the session is `user_u:user_r:user_t`;
- the `pam_faillock` hardening survived the `pambase` replacement (§6.3's bug,
  still fixed);
- `omarchy-server-update` completes (§6.3's `OMARCHY_PATH` bug, still fixed).

**0 AVC denials on a boot.** 31 under the full workload, all of them the
`user_t`-doing-root-work class of §10.6.

One ordering fact the design now depends on: **boot 1 of a fresh install leaves
`init` in `kernel_t`**, because PID 1 transitions at exec only if
`/usr/lib/systemd/systemd` already carried `init_exec_t`, and on boot 1 the
relabel unit runs after PID 1 has started. Boot 2 has `init_t`. The sequence is
therefore install → boot → relabel → **reboot** → consider enforcing, and the
`enforcing` preflight refuses while `init` is still `kernel_t`.

### 10.5 Enforcing: reached, reachable, and not lost

The machine went enforcing and **stayed reachable**. Against §6.4, where the
run could not finish at all:

| | §6.4 | now |
|---|---|---|
| ssh login | **lost** | works |
| home directory | **lost** (`Could not chdir`) | works |
| `sudo` | **lost** | works |
| snapper snapshot | not reached | works |
| `pacman -Sy` | not reached | works |
| reboot and come back | **failed** | works |
| Denials under the workload | 53 | **10** |

The preflight also did its job before any of that: asked to enforce, it
**refused**, and the acceptance now asserts the refusal before using `--force`
(which the lab has the standing for — serial console, snapshot, installer
medium; a remote operator has none of them).

### 10.6 Why enforcing is still not usable: `sudo` does not change the role

Five workload items failed in enforcing, and all five have one cause:

```
$ sudo id -Z
user_u:user_r:user_t
```

`sudo` on this profile gives Unix root and leaves the SELinux context exactly as
it found it. The policy store's `seusers` maps `__default__:user_u`, so the
operator is `user_u`, and "root through sudo" carries the authority of a
confined desktop user:

| Failed | Refused with |
|---|---|
| `omarchy-server-addon docker` | `failed to create temporary download directory /var/lib/pacman/sync/…: Permission denied` |
| `omarchy-server-update` | the same pacman failure |
| `ufw status verbose` | `ERROR: Couldn't determine iptables version` |
| `systemctl is-active serial-getty@ttyS0` | `Failed to connect to system scope bus via local transport: Operation not permitted` |
| making enforcing survive a reboot | the write to `/etc/selinux/config` was denied; the mode was runtime-only |

And the consequence that matters most:

```
$ sudo omarchy-server-selinux permissive
setenforce:  security_setenforce() failed:  Permission denied
```

**Enforcing is a one-way door over ssh.** Only `sysadm_r` and `secadm_r` are
granted `security { setenforce }`; `user_r` reaches neither — `runcon -t
sysadm_t` answers *invalid context* and `systemd-run` cannot reach the manager.
Every route back needs a console. `omarchy-server-selinux enforcing` now refuses
when the calling session's role cannot `setenforce`, and says exactly this.

The fix is the textbook arrangement and is **not made**: map the operator to
`staff_u` in `seusers` and give sudo a role transition (`ROLE=sysadm_r
TYPE=sysadm_t` in sudoers), so the login session stays confined as `staff_t`
while `sudo` reaches `sysadm_t`. It is a change with its own lockout risk and
needs its own run.

One further drift, found by the stronger label check: after `docker run`, 30+
paths under `/var/lib/docker` and `/var/lib/containerd` carry labels the policy
disagrees with (`container_var_lib_t` where it wants `container_ro_file_t`, and
so on). The container runtime creates them at runtime, so the pacman hook never
sees them. `restorecon -R /var/lib/docker /var/lib/containerd` fixes it; nothing
does that automatically today.

### 10.7 §8 revisited, honestly

**The recommendation does not change: ship AppArmor as the switch.** What
changes is the reason, and it is a better reason than "SELinux has not been
proven".

Three of §8's four conditions are now met:

1. ~~the enforcing fixes validated on a fresh install~~ — **done**, §10.4/§10.5.
   The operator is not locked out, and the guard that would have prevented the
   original lockout refuses correctly.
2. ~~the tooling split~~ — **done**, §10.3. **+9 packages and +99 MiB**, not
   +54 and +552.
3. ~~the lockstep check automated~~ — **done**, §10.8.
4. `ps -Z` still does not exist, and `/usr/bin/login` still does not link
   `libselinux`. Unchanged.

And the size argument that carried most of §8's weight is gone. **+9 packages
and +99 MiB for full-system confinement is a good trade**, and it is roughly
the cost of one moderate package. If the decision were only about surface,
SELinux would now win it.

What argues for AppArmor as the default is no longer size. It is three things
the re-validation put numbers on:

- **The operator has no administrative role.** Until `seusers` and sudo are
  arranged for a role transition, enforcing means an administrator who cannot
  run `pacman`, `ufw` or `systemctl` — and cannot turn it back off remotely.
  That is not a rough edge; it is the machine's own management being confined
  out of existence.
- **The policy is materially behind the userland, and closing the gap is
  open-ended.** Seven rounds to get a *bare boot* to zero denials, with a new
  set of domains appearing at rounds 2 and 4. That is not a one-time cost:
  every systemd release reopens it, and this profile is on Arch, which means
  every few weeks. Two of the fifteen rules had to be widened to a whole
  attribute precisely because enumeration was losing.
- **Ten packages still have to be kept in lockstep with Arch**, which is now
  automated (§10.8) but not eliminated. Automation converts a silent downgrade
  into a ticket; it does not do the rebuild.

Against that, AppArmor's honest description is unchanged and unflattering: it
confines sshd and nothing else, **2 of 146** shipped profiles matching a binary
this machine has. The asymmetry is now stated more precisely than in §8:

> **SELinux confines everything and costs a maintenance relationship.
> AppArmor confines one daemon and costs nothing.** The size gap that used to
> stand between them has closed; the maintenance gap has not, and the
> administrative-role gap is a hard blocker that has to be fixed before the
> question is even open.

What would now change the default, in order:

1. The `staff_u` + `ROLE=sysadm_r` mapping, validated, so an administrator can
   administer and can get back out of enforcing over ssh. **This is the
   blocker.**
2. A policy pin worth standing behind: either an upstream refpolicy that knows
   systemd 261, or an accepted position that this profile carries a local module
   and updates it on a schedule — with the schedule named.
3. A `restorecon` hook for container runtime paths, or a decision that container
   label drift is acceptable.

### 10.8 The lockstep check (§8.3)

`omarchy-server-pkgs/scripts/check-selinux-lockstep.sh` clones
`archlinuxhardened/selinux` at the manifest's pinned commit, copies the
repository's overrides over it — exactly what `build-selinux.sh` assembles —
reads `pkgver-pkgrel` from each PKGBUILD and `vercmp`s it against the Arch
package of the same name with `-selinux` stripped. It compares **what a build
today would produce**, not what is sitting in the gitignored `out/selinux/`.

`.github/workflows/selinux-lockstep.yml` runs it weekly (Mondays 06:17 UTC), on
dispatch, and on any push touching the manifest, an override or the script.
Behind → it opens or updates in place a single issue carrying the diff, and
fails the job. Level again → it comments and closes that issue. It never
rebuilds anything.

**First run, 2026-08-29: 14 rebuilds compared, all in sync.**

```
pambase 20260616-1   pam 1.7.2-2            coreutils 9.11-2
util-linux 2.42.2-1  util-linux-libs …      shadow 4.20.0.arch1-1
sudo 1.9.17.p2-6     openssh 10.5p1-1       systemd + 5 splits 261.2-1
```

`openssh-selinux` at **10.5p1-1** is the check's own justification working:
that is the override this repository carries because upstream's pin was a
silent downgrade to 10.4p1-3. Eleven additive packages have no Arch counterpart
and are listed as not compared, rather than counted as passing.

### 10.9 What this re-validation still does not prove

- The `staff_u` / `sysadm_r` arrangement. Identified, designed, **not built**.
- That the local policy module is complete. It is complete for *this workload
  on this boot*; rounds 2 and 4 are the evidence that another workload finds
  more.
- Container confinement beyond `docker run hello-world`, and the label drift in
  §10.6 is unaddressed.
- Secure Boot together with SELinux. Still no machine has had both.
- Anything about a machine that has been up longer than one acceptance run.
