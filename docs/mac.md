# Mandatory access control

Optional, off unless asked for, and delivered twice: `omarchy-server-addon
selinux` and `omarchy-server-addon apparmor`. The two are mutually exclusive,
they are measured against the same workload, and this document is the design of
both plus what each one costs.

The framing matters. This is meant to be a **switch Omarchy could turn on in
its own package pipeline**, not a fork: everything below is an addon, nothing
is in the core, and a machine that never asks for either carries no extra
package and no extra kernel flag. The choice of a default is the owner's; §8 is
the recommendation and the reasons behind it.

---

## 1. What the kernel already gives us

Measured on Arch's stock `linux` package, not assumed:

```
$ zgrep -E 'CONFIG_SECURITY_(SELINUX|APPARMOR)|CONFIG_LSM=' /proc/config.gz
CONFIG_SECURITY_SELINUX=y
CONFIG_SECURITY_SELINUX_BOOTPARAM=y
CONFIG_SECURITY_APPARMOR=y
CONFIG_SECURITY_APPARMOR_BOOTPARAM_VALUE=1
CONFIG_LSM="landlock,lockdown,yama,integrity,bpf"
```

Both modules are **compiled in**. Neither is **active**, because `CONFIG_LSM`
— the list the kernel initialises at boot — names neither. Overriding that list
is a kernel command line parameter, `lsm=`, and nothing else. There is no kernel
to rebuild, no patch to carry, and no out-of-tree module involved.

This is the single most important fact about the whole exercise, and it is what
makes "a switch Omarchy turns on" a reasonable description rather than a
euphemism. The kernel side of either route is one line:

```
lsm=landlock,lockdown,yama,integrity,selinux,bpf
lsm=landlock,lockdown,yama,integrity,apparmor,bpf
```

### Where that line lives

The profile already has a mechanism for adding a kernel command line flag:
a drop-in under `/etc/limine-entry-tool.d/`, which is how the Secure Boot addon
adds `lockdown=integrity module.sig_enforce=1` (`docs/secure-boot.md`). The MAC
addons use the same one — `omarchy-lsm-selinux.conf` and
`omarchy-lsm-apparmor.conf`, named so they sort after `omarchy-defaults.conf`
and append to the profile's cmdline instead of replacing it.

The cmdline is **baked into the UKI**, so the drop-in has to exist before the
UKI is built. During an ISO install that means the addon phase, ahead of
`finalize_limine_boot`; on a running machine it means `limine-update` after the
drop-in is written, which `install/server/mac-server.sh` does.

Because it is inside the signed UKI, `lsm=` is also covered by Secure Boot when
that addon is on: an attacker with write access to the ESP cannot turn the MAC
off by editing `limine.conf`, since a UKI entry ignores the `cmdline:` there.

### The order of the list

`lockdown` stays ahead of the MAC module, and `bpf` stays last, which is the
order stock `CONFIG_LSM` uses. lockdown answers "may this process touch the
kernel image at all", which is a cheaper and more absolute question than "may
this domain read this file"; asking it first means a lockdown refusal is
reported as a lockdown refusal rather than surfacing as a MAC denial.

---

## 2. Two routes, and why they are not comparable in cost

The kernel halves are equal. The userland halves are not, and that asymmetry is
the whole story.

| | SELinux | AppArmor |
|---|---|---|
| Model | label every object and subject; policy is a compiled database | path-based rules per binary |
| Kernel | in Arch's stock kernel | in Arch's stock kernel |
| Userland in Arch's repos | **none** | `apparmor` (one package) |
| Userland this profile ships | 11 additive packages + **8 rebuilds of core packages** | none |
| Policy | the Arch reference policy, `selinux-refpolicy-arch` | ~200 profiles shipped with `apparmor` |
| Profiles/policy that apply to a headless server | the reference policy covers init, sshd, sudo, login, cron, containers | see §5 — the honest answer is "almost none" |

### Why SELinux needs rebuilds and AppArmor does not

AppArmor's decisions are made entirely in the kernel from the path of the
binary being executed. Userland does not participate, so no package has to know
about it.

SELinux's decisions need a **context** on every process and every file, and
someone has to set them. That someone is userland:

- `pam_selinux` puts a login session into a domain. Without it, every session
  inherits the domain of whatever started it — on a server, sshd's.
- `sshd` calls `setexeccon()` before handing off to the user's shell.
- `login` does the same on the console.
- `sudo` performs the role transition to the target user's domain.
- `systemd` labels `/run` and the cgroup hierarchy, honours `SELinuxContext=`,
  transitions each service into its own domain at exec, and relabels `/dev`.
- `coreutils` (`cp`, `mv`, `install`, `ls -Z`, `id -Z`) preserves and sets
  contexts. Every `install/` leaf of this profile writes files with `install`.
- `shadow` (`useradd`) labels the home directory it creates.

None of Arch's builds of these link `libselinux`:

```
$ pacman -Si coreutils | grep '^Depends'
Depends On      : acl  attr  glibc  gmp  libcap  openssl
$ pacman -Si systemd | grep '^Depends'      # no libselinux either
```

So the eight rebuilds are not a nice-to-have. Without them SELinux loads a
policy, labels nothing, transitions nothing, and reports that everything is
allowed — the worst possible outcome, because it looks like it is working.

---

## 3. The SELinux package set

Built from [`archlinuxhardened/selinux`](https://github.com/archlinuxhardened/selinux)
at a pinned commit by `omarchy-server-pkgs/scripts/build-selinux.sh`, signed
into `[omarchy-server]`, and bundled in the ISO's offline mirror.
`omarchy-server-pkgs/pkgbuilds/selinux.manifest` is the list, the pin, and one
paragraph per package saying why it is in the set — and, at the bottom, one
paragraph per package saying why it is not.

**Additive** (replace nothing; installing them changes nothing about a machine
that never enables SELinux): `libsepol`, `libselinux`, `checkpolicy`, `secilc`,
`setools`, `libsemanage`, `semodule-utils`, `policycoreutils`, `selinux-python`,
`selinux-alpm-hook`, `selinux-refpolicy-arch`.

**Rebuilds** (each `provides=` and `conflicts=` its stock counterpart):
`pambase-selinux`, `pam-selinux`, `coreutils-selinux`, `util-linux-selinux`,
`shadow-selinux`, `sudo-selinux`, `openssh-selinux`, `systemd-selinux` (which
splits into `systemd-selinux`, `systemd-libs-selinux`,
`systemd-sysvcompat-selinux`).

### What was deliberately left out

`dbus-selinux` and `dbus-broker-selinux` — dbus is in the base because systemd
pulls it, but the server runs no bus client of its own. `findutils-selinux`,
`psmisc-selinux`, `iproute2-selinux` — `find -context`, `killall -Z`, `ip -Z`
are inspection conveniences, not confinement, and each is one more package to
keep in lockstep with Arch. `logrotate-selinux`, `cronie-selinux` — neither
package is installed here. `mcstrans` — the policy is targeted, not MLS.
`restorecond` — a daemon and an inotify watch to do what the pacman hook and
`restorecon` already do. `selinux-gui`, `selinux-sandbox`,
`selinux-dbus-config` — desktop. `base-selinux` — a meta package that pulls
half of the above.

`sepolgen` is a special case: the standalone package is the 2016 release, still
wants python2 to build, and `selinux-python` both `provides=sepolgen` and
`conflicts=sepolgen<2.7`. It is not built.

### One thing that cannot be had at all

There is no `procps-ng-selinux`, and Arch's `procps-ng` does not link
`libselinux`. **`ps -Z` and `ps -o label` do not work on this system.** A
process's context is read from `/proc/PID/attr/current`, which is what
`omarchy-server-selinux status` does. This is a real gap in the operator
experience and is worth knowing before choosing this route.

### Replacing packages the base already has

`pacman -S` under `--noconfirm` takes the **default** answer to
`:: X and Y are in conflict. Remove Y? [y/N]`, which is no, and fails the whole
transaction as an unresolvable conflict. This is not theoretical — it is the
first thing that happened when the build container tried to install
`pambase-selinux`:

```
:: pambase-selinux-20260616-1 and pambase-20260616-1 are in conflict. Remove pambase? [y/N]
error: unresolvable package conflicts detected
```

The fix is `--ask=4`, ALPM's `QUESTION_CONFLICT_PKG` bit pre-answered yes. It
answers that one question and no other — in particular it does not pre-answer
the corrupted-package or untrusted-key questions, which must keep failing.

Rather than special-case one addon inside `omarchy-server-addon`, the runner
learned a general mechanism: an addon may ship `<name>.pacman-args` beside its
`<name>.packages`, one flag per line, comments allowed. `selinux.pacman-args`
is the only one that exists, and it contains `--ask=4` and the paragraph
explaining it. The same file is used on the installed-machine path and in the
ISO chroot path, so the two cannot drift.

### Lockstep with Arch

This is the standing cost of the SELinux route and it must be stated plainly: a
rebuild of a core package has to track that package's version in Arch, or the
machine that installs it gets a **downgrade** of something it depends on.

At the pinned commit that was already true of one package:

| Package | archlinuxhardened | Arch | |
|---|---|---|---|
| coreutils | 9.11-2 | 9.11-2 | in sync |
| pam | 1.7.2-2 | 1.7.2-2 | in sync |
| pambase | 20260616-1 | 20260616-1 | in sync |
| shadow | 4.20.0.arch1-1 | 4.20.0.arch1-1 | in sync |
| sudo | 1.9.17.p2-6 | 1.9.17.p2-6 | in sync |
| systemd | 261.2-1 | 261.2-1 | in sync |
| util-linux | 2.42.2-1 | 2.42.2-1 | in sync |
| **openssh** | **10.4p1-3** | **10.5p1-1** | **behind** |

Installing `openssh-selinux` as upstream ships it would have downgraded the one
daemon this profile exposes to the network, by one release, silently, through
`provides=openssh`. That is not acceptable, so the profile carries an override:
`omarchy-server-pkgs/pkgbuilds/selinux-overrides/openssh-selinux/` is Arch's
current `openssh` PKGBUILD with the same four SELinux changes archlinuxhardened
makes (the name, `libselinux` in `depends`, `conflicts`/`provides`, and
`--with-selinux`), and nothing else. It is deleted the moment upstream catches
up.

A second override exists for a different reason: `libselinux` 3.10 does not
build against the Python currently in Arch (it calls `PyString_FromString`,
which SWIG's generated header no longer defines under Python 3.14, and GCC 15
rejects the resulting implicit declaration). The override is the one-line
upstream fix, backported.

Two overrides on a nineteen-package set, at one point in time, is the honest
measure of what "keeping a rebuild set in lockstep with Arch" costs. A pipeline
that adopts this needs a job that compares each `*-selinux` pkgver against the
Arch package of the same name and opens an issue when they diverge; that job
does not exist yet and is the largest piece of unfinished work here.

---

## 4. The AppArmor package set

One package, `apparmor`, from Arch's `extra`. Its dependencies are `audit`
(already in the base), `bash`, `glibc`, `libgcc`, `pam`, `python`,
`python-legacy-cgi`.

There is nothing to rebuild, nothing to keep in lockstep, and nothing to
replace. This is the entire packaging story for the AppArmor route, and it is
the route's decisive advantage.

---

## 5. What each route actually confines

### SELinux

The reference policy has domains for init, sshd, sudo, login, getty, the
package manager, the container runtime and the filesystem tools — because it
was written for exactly this kind of machine. Every service systemd starts
transitions into its own domain at exec, every file has a label, and the
policy's answer to "may `sshd_t` read `shadow_t`" is a rule somebody wrote on
purpose.

The one thing the reference policy gets wrong about *this* profile out of the
box is the label on its own commands: `/usr/share/omarchy/bin` holds programs,
and the default for anything under `/usr/share` is `usr_t`, which is data. The
addon fixes that with `semanage fcontext -a`, from
`install/server/mac/selinux/local-fcontexts`.

There is deliberately **no local policy module**. A module has to contain at
least one rule to compile at all — `checkmodule` rejects one whose only content
is a file-context file — and a rule belongs there only when a measured denial
called for it. If an `omarchy_server.te` appears beside `local-fcontexts` the
setup leaf builds and installs it with `checkmodule` + `semodule_package`,
which is plain module syntax and exactly what `audit2allow -M` emits.

### AppArmor

Arch's `apparmor` package ships around two hundred profiles under
`/etc/apparmor.d`. Reading the list is the fastest way to understand this
route's limit here:

```
1password  Discord  MongoDB_Compass  QtWebEngineProcess  Xorg  brave  chrome
chromium  code  element-desktop  epiphany  evolution  firefox  flatpak  geary
github-desktop  keybase  vivaldi-bin  ...
```

They are for desktop software. A profile whose attachment path does not exist
on the machine loads and confines nothing.

The daemons a headless server actually runs have **no enabled profile at all**.
sshd's exists — but under `/usr/share/apparmor/extra-profiles/usr.sbin.sshd`,
which Arch ships and does not enable, and whose own upstream README says:

> The profiles in this directory are not turned on by default because they are
> not as mature as the profiles in `/etc/apparmor.d/`. In some cases, it is
> because the profile hasn't been updated to work with newer code; in other
> cases, it because any benefit provided by the profile is much less than the
> potential for causing problems.

So the `apparmor` addon ships its own adapted copy,
`install/server/mac/apparmor/usr.bin.sshd`, with exactly three changes from
that file:

1. **Paths.** Arch builds OpenSSH with `--sbindir=/usr/bin` and
   `--libexecdir=/usr/lib/ssh`; upstream's profile names `/usr/sbin/sshd` and
   `/usr/lib/openssh/*`, which are Debian's layout and match nothing here. A
   profile whose attachment path does not exist is a profile that never loads
   — the quiet failure this route has to avoid.
2. **The internal-sftp block.** Upstream grants `/ r`, `/** r` and
   `owner /** rwl` so the in-process SFTP server can serve any path. Those
   three lines give the confined daemon read access to every file on the
   machine, which is most of what confining it was supposed to prevent. They
   are commented out, with a pointer to `/etc/apparmor.d/local/usr.bin.sshd`
   for a machine that genuinely serves `Subsystem sftp internal-sftp`.
3. The `local/` include, renamed to match.

Note what remains upstream's, because it bounds the claim: every login shell is
listed `Uxr`, which means the shell leaves the profile. AppArmor here confines
**sshd**, not the session it hands off to. SELinux, through `pam_selinux`, puts
that session in a domain of its own.

`omarchy-server-apparmor status` prints the number that matters — how many of
the loaded profiles name a binary this machine has — so an operator sees the
coverage rather than the profile count.

---

## 6. The addons

Both follow the shape the `secureboot` addon established: a package list, a
setup leaf under `install/server/` (not in the addon directory, because it is a
profile setup step that happens to need packages), a thin
`install/server/addons/<name>.sh` that sources it, and a runtime command.

```
profile/server/addons/selinux.packages          the package set
profile/server/addons/selinux.pacman-args       --ask=4, and why
profile/server/addons/apparmor.packages
overlay/runtime/install/server/addons/selinux.preflight.sh   refuse before installing
overlay/runtime/install/server/addons/apparmor.preflight.sh
overlay/runtime/install/server/mac-server.sh    shared: lsm= drop-in, exclusivity
overlay/runtime/install/server/selinux-server.sh
overlay/runtime/install/server/apparmor-server.sh
overlay/runtime/install/server/mac/selinux/local-fcontexts
overlay/runtime/systemd/omarchy-server-selinux-relabel.service
overlay/runtime/install/server/mac/apparmor/usr.bin.sshd
overlay/runtime/bin/omarchy-server-selinux      status|avc|permissive|enforcing|relabel|disable
overlay/runtime/bin/omarchy-server-apparmor     status|denials|complain|enforce|disable
```

### Both start permissive

`selinux` leaves `SELINUX=permissive`; `apparmor` leaves its shipped profiles
in `force-complain`. In both cases the policy is loaded, every decision is
evaluated, nothing is refused, and what *would* have been refused is in the
kernel log.

This is deliberate and it is the safest part of the design. A machine that goes
straight to enforcing on a policy nobody has measured against its workload is a
machine that may not come back — and this is a headless machine reached only
over ssh. `omarchy-server-selinux avc` / `omarchy-server-apparmor denials`
summarise the log by count; the second step is taken once they are quiet.

### The relabel happens during the install

SELinux labels the filesystem with `setfiles` inside the install chroot, not on
the first boot. A relabel is minutes of I/O, and doing it while the machine is
already busy writing is cheaper than doing it with somebody watching a console.
And then once more on the first boot. `/.autorelabel` is left in place and
`omarchy-server-selinux-relabel.service` acts on it — `selinux-refpolicy-arch`
ships no such unit, so this profile ships one, enabled by the addon. That
second pass is not belt and braces: the orchestrator creates the user's home
directory in a phase that runs *after* the addon, so the offline pass cannot
have labelled it, and an unlabeled `/home/<user>` locks the operator out the
moment the machine goes enforcing. §7 is the run where that happened.

### Mutual exclusion

The kernel initialises one major LSM. Installing both would leave a machine
whose second addon silently does nothing, which is the failure mode a security
feature must never have. It is refused in three places:

- a **preflight leaf**, `install/server/addons/<name>.preflight.sh`, which
  `omarchy-server-addon` sources *before* it installs anything. Refusing in the
  setup leaf would be too late: nineteen packages, eight of them replacing core
  packages, would already be on a machine that is not going to use them. The
  preflight mechanism is general — any addon may ship one — but these two are
  the only addons that have a reason to.
- the ISO orchestrator raises if the autoinstall drive carries both markers,
  before anything is installed.
- `mkcidata.sh --mac` takes one value, so a lab drive cannot be built with
  both.

The way to switch is `omarchy-server-<current> disable`, reboot, then install
the other one. `disable` removes the cmdline drop-in and rebuilds the UKI; it
deliberately does **not** uninstall the SELinux replacement packages, because
putting Arch's systemd, coreutils, util-linux, shadow, sudo, openssh and pam
back is a much riskier operation than turning a kernel flag off, and it prints
the command rather than running it.

### At install time

A marker file on the autoinstall drive, exactly like `secureboot`:

```bash
pocs/lab/mkcidata.sh --profile server --mac selinux
pocs/lab/mkcidata.sh --profile server --mac apparmor
```

`omarchy-cidata-load` copies it to `/root`, and the orchestrator turns it into
an addon that runs early — after `secureboot` (which must be first, so the keys
and its own cmdline drop-in exist before any initramfs is rebuilt) and before
the addons the drive named, so the relabel happens before the rest of the
install writes more files.

The SELinux packages exist in no public Arch repository, so the ISO cannot
download them. They ride in the offline mirror through a new mechanism
(`iso/patches/0011`): `<pkgs-checkout>/prebuilt/*.pkg.tar.zst` is copied into
the mirror and added to `local_package_names`, which is the same list the
locally-built `omarchy-server*` packages use to be excluded from the online
download and kept by the prune step. `iso/build.sh` fills that directory from
`omarchy-server-pkgs/out/selinux/`, and says so — or says the addon will not be
bundled — rather than failing a build for somebody who has not built the set.

---

## 7. Measurements

`reports/2026-08-29-mandatory-access-control.md` is the run: two VMs installed
from the same ISO with the two markers, the same workload on both, logging mode
first and then enforcing. The numbers that decide the design:

| | Base | AppArmor | SELinux |
|---|---:|---:|---:|
| Packages | 220 | 222 (+2) | 274 (+54) |
| Installed size | 1402 MiB | 1408 MiB (+6) | 1954 MiB (+552) |
| Enabled units | 21 | 22 (+1) | 21 (+0) |
| Boot | 6.920 s | 7.376 s | 7.814 s |
| Install (orchestrator) | 28.9 s | ~29 s | 45 s |
| Packages replaced | 0 | 0 | 10 |
| Denials under the workload | — | 0 complain, 0 enforce | 55 permissive, 53 enforcing |
| Reached its enforcing mode | — | **yes, 24/24** | **not yet** |

Three results from that run change what is written above, and are worth having
here rather than only in the report:

**AppArmor confines sshd and nothing else.** `omarchy-server-apparmor status`
measured **2 of 146** profiles under `/etc/apparmor.d` naming a binary this
machine has — `bin.ping`, and the `usr.bin.sshd` this addon ships itself. 163
profiles load; they are for desktop software that is not installed. That is the
route's real coverage, and it should be quoted whenever the route is described.

**82% of the SELinux route's size is not SELinux.** `setools` depends on
`python-networkx`, which in Arch has `python-scipy`, `python-pandas`,
`python-matplotlib` and `python-numpy` as hard dependencies. Removing `setools`
and `selinux-python`, minus what the base already had, is **45 packages and
452.9 MiB**. Splitting the management tooling into a second addon is the
biggest open improvement to this design.

**Replacing a core package undoes what the profile did to it.** The addon
replaced `pambase`, and pacman saved the profile's hardened
`/etc/pam.d/system-auth` as a `.pacsave` and installed the stock one — silently
turning off the 10-attempt account lockout. The setup leaf now re-applies that
leaf, and the acceptance script checks for it. Any profile edit to a file owned
by one of the eight replaced packages has this hazard.

**Enforcing locked the operator out, and how it was fixed.** The offline
relabel runs in the addon phase; the orchestrator creates the user's home
directory afterwards, so `/home/<user>` was unlabeled, and `user_t` may not
search `unlabeled_t` — the session could not reach its own home, and `sudo` went
with it. Three changes came out of that:

- `omarchy-server-selinux-relabel.service`, a one-shot gated on `/.autorelabel`
  that relabels once on the first boot. The addon now leaves that flag in place
  rather than clearing it, and the unit clears it.
- `omarchy-server-selinux enforcing` refuses while unlabeled paths exist or the
  boot has any AVC denial. `--force` is for somebody with a console.
- The recovery advice was wrong and is corrected. **`enforcing=0` cannot be
  added at the Limine menu on this profile**: the cmdline is inside the UKI and
  a UKI entry ignores `limine.conf`'s `cmdline:`. The routes that work are a
  session that still has root, an earlier snapper snapshot, or the installer
  medium.

Those three are written but **not yet re-validated on a fresh install**.

## 8. Recommendation

**Ship AppArmor as the switch. Keep SELinux, do not default to it yet.**

AppArmor costs two packages and 6 MiB, replaces nothing, has no lockstep
obligation, reached enforce with zero denials on the first attempt, and cannot
lock the operator out the way the SELinux run did. For a pipeline that wants to
turn something on, that is the whole argument — provided the claim made for it
is the true one: *sshd is confined*, not *the server is confined*.

SELinux confines vastly more and costs vastly more: 54 packages, 552 MiB, ten
replaced core packages, a standing obligation to track Arch's versions, and one
unvalidated fix between here and a machine that stays reachable in enforcing.
Four things would change the recommendation, in order:

1. the enforcing fixes validated on a fresh install;
2. `setools` and `selinux-python` split into a second addon (45 packages,
   453 MiB);
3. a CI job comparing every `*-selinux` pkgver against the Arch package of the
   same name — one of the eight was already behind at the pinned commit, and it
   was `openssh`;
4. an answer for `ps -Z`, which does not exist on this system.

The reasoning, with the evidence behind each number, is in
`reports/2026-08-29-mandatory-access-control.md`.
