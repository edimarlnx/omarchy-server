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
`libsemanage`, `semodule-utils`, `policycoreutils`, `selinux-alpm-hook`,
`selinux-refpolicy-arch`.

**Not in the `selinux` addon at all**: `setools` and `selinux-python`. They are
the separate **`selinux-tools`** addon — see "Two addons, not one" below.

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

Four things the reference policy gets wrong about *this* profile out of the box
are labels, and all four are fixed by labelling rather than by policy:

- `/usr/share/omarchy/bin` holds programs, and the default for anything under
  `/usr/share` is `usr_t`, which is data.
- `/var/lib/lastlog` holds shadow's `lastlog2.db`, which sshd writes on every
  login. refpolicy knows `lastlog_t` and grants sshd what it needs on it, but
  only names `/var/log/lastlog`; shadow moved the database and the policy has
  not followed.
- `/etc/pacman.d/gnupg` is a GnuPG home that happens to live under `/etc`, so
  the default gives it `etc_t` and gpg is refused when it updates the trust
  database on every `pacman -Sy`. gpg exits non-zero, pacman carries on, and
  the trustdb silently stops being maintained. `gpg_secret_t` is the type
  refpolicy already has for exactly this content.
- `/opt/containerd` is where containerd puts its plugins, and `/opt` is
  `usr_t`, so the daemon cannot create it. `container_var_lib_t` -- the type
  `/var/lib/containerd` already carries -- plus the `docker` addon creating the
  two directories itself, instead of `allow dockerd_t usr_t:dir create`.

And one place where the labels are **deliberately** not what the policy says:
`/var/lib/docker` and `/var/lib/containerd` after a container has run. The
runtime sets `container_file_t` on volumes so that containers can write to them
and `container_ro_file_t` on snapshot layers so that they cannot; `restorecon`
there would take a working container apart, and a static `file_contexts` cannot
express "whatever the runtime decided". The acceptance therefore asks whether
any of that tree is *unlabeled* -- the failure that matters -- and records the
disagreement with the static policy as a number instead of judging it.

All of them live in `install/server/mac/selinux/local-fcontexts`, which the setup leaf
renders into the policy store's `file_contexts.local` — the same file
`semanage fcontext -a` writes, in the same format, at the path libselinux looks
for it. Writing it directly rather than through `semanage` is what lets the
`selinux` addon leave `selinux-python` out.

> Contexts there are **three fields**, no `:s0`. `refpolicy-arch` is built
> `TYPE=standard` and is not MLS, so a four-field context is *invalid* — and
> `setfiles` responds by dropping that rule, printing one line, and exiting
> **0**. That mistake left `/usr/share/omarchy/bin` as `unlabeled_t` through two
> relabels without a failure anywhere. The setup leaf now derives the suffix
> from the policy's own `file_contexts`, and verifies afterwards that the
> labels are on disk rather than trusting the exit status.

There **is** a local policy module, `install/server/mac/selinux/omarchy_server.te`,
and every rule in it came from a denial measured on this profile. The setup leaf
builds it on the machine with `checkmodule -m` + `semodule_package` — plain
module syntax, exactly what `audit2allow -M` emits, and no `make`/`m4` on a
production server. What it covers, and why each rule is the shape it is, is in
the file; the short version is three groups:

- the gap between refpolicy 20250923 and systemd 261 — credentials on tmpfs,
  PSI (`memory.pressure`), logind and networkd over varlink instead of D-Bus,
  userdb, and networkd's BPF;
- the standard streams a privileged command inherits from the session that ran
  it. A **non-interactive** `ssh host sudo …` gives the command a pipe that
  belongs to `sshd_t` or to the login shell, and a domain that may not write to
  it produces the worst possible failure: the command runs, exits 0, and prints
  nothing. Measured on `sudo id -Z`, on `ufw status | head`, and on
  `docker run hello-world`. An interactive session with a real terminal never
  sees any of it;
- one restored type transition. `systemd-sysusers`, run by an alpm hook, gets
  its own domain when pacman is `initrc_t` (the update timer) and did not when
  pacman is `sysadm_t` (an administrator at the keyboard), so it was editing
  `/etc/gshadow` as the administrative domain. Five lines make the transition
  happen; the two-line alternative would have given `sysadm_t` write access to
  the account databases refpolicy deliberately withholds from it.
- two `dontaudit` lines. `sudo` asks for `CAP_NET_ADMIN` on every invocation
  and works without it; `systemd-networkd` asks for `CAP_SYS_ADMIN` because the
  kernel's `bpf_capable()` tries it before `CAP_BPF`, and stays routable
  without it. Silencing those is right; granting them would not be.

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
profile/server/addons/selinux.packages          the package set (17)
profile/server/addons/selinux.pacman-args       --ask=4, and why
profile/server/addons/selinux-tools.packages    setools + selinux-python (2)
profile/server/addons/apparmor.packages
overlay/runtime/install/server/addons/selinux.preflight.sh        refuse before installing
overlay/runtime/install/server/addons/selinux-tools.preflight.sh  refuse without a policy store
overlay/runtime/install/server/addons/apparmor.preflight.sh
overlay/runtime/install/server/mac-server.sh    shared: lsm= drop-in, exclusivity
overlay/runtime/install/server/selinux-server.sh
overlay/runtime/install/server/apparmor-server.sh
overlay/runtime/install/server/mac/selinux/local-fcontexts
overlay/runtime/install/server/mac/selinux/omarchy_server.te   the local policy
overlay/runtime/systemd/omarchy-server-selinux-relabel.service
overlay/runtime/install/server/mac/apparmor/usr.bin.sshd
overlay/runtime/bin/omarchy-server-selinux      status|avc|permissive|enforcing|relabel|admin-role|disable
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

### What `enforcing` refuses over, and what it only warns about

`omarchy-server-selinux enforcing` has a preflight, because §7 is a run where
the operator lost the machine by switching without one. What it blocks on is
narrow and does not move:

1. `/.autorelabel` still present — the first-boot relabel did not finish.
2. `/root` or any `/home/<user>` unlabeled. `ls -Zd`, which needs nothing but
   `coreutils-selinux`.
3. PID 1 not in `init_t`. init transitions at exec only if
   `/usr/lib/systemd/systemd` already carried `init_exec_t`, so `kernel_t`
   means this boot happened before the labels were complete — exactly the state
   that locks the operator out. It is the normal state of the *first* boot of a
   fresh install, and the reason the sequence is relabel → **reboot** →
   enforcing.
4. Unlabeled paths under `/home /root /etc /usr /var` — *when this machine can
   look*. Arch's `findutils` is not built against libselinux and
   `findutils-selinux` is deliberately not in the rebuild set, so
   `find -context` answers "SELinux is not enabled" on stderr and nothing on
   stdout. Piped to `wc -l` that is a clean `0` and the check passes without
   having read a file. The preflight tests for the predicate first and says so
   when it has to skip; checks 2 and 3 do not depend on it.
5. Denials **on the way back in**: anything whose target is `unlabeled_t`, and
   anything raised by `sshd_t`, `login`, a getty, `sudo` or the user role.

Everything *else* in the denial log is printed as a **warning with a count**,
not a refusal. An earlier version refused over any denial at all; that was
measured and it is unusable. A bare boot of a correctly labelled machine
produces on the order of eighteen denials from systemd mechanisms
refpolicy 20250923 has not been taught, the set differs from boot to boot as
different services start, and closing them is an open-ended job rather than a
precondition. A gate nobody can satisfy is a gate everybody passes with
`--force`.

The distinction is the honest one: a denial on the login path is a locked door,
and a denial inside a service is that service degrading — recoverable over the
ssh session the first four checks just protected.

### The administrative role, and why `enforcing` used to be a one-way door

The sixth thing the preflight blocks on is the one nobody expected, and it is
what the addon's `admin-role` step exists to prevent. With refpolicy's default
mapping there is **no way back from enforcing over ssh**, and that was measured
rather than reasoned:

```
$ sudo omarchy-server-selinux permissive
setenforce:  security_setenforce() failed:  Permission denied
$ sudo id -Z
user_u:user_r:user_t
```

`sudo` gives Unix root and does not touch the SELinux context. The policy
store's `seusers` maps `__default__:user_u`, the operator logs in as
`user_u:user_r:user_t`, and "root through sudo" therefore has the SELinux
authority of a confined desktop user: `pacman` cannot write its sync directory,
`ufw` cannot reach netfilter, `systemctl` cannot reach the manager bus, and
`security { setenforce }` — granted only to `sysadm_r` and `secadm_r` — is out
of reach in both directions. `runcon -t sysadm_t` answers *invalid context*
because `user_u` is not authorised for that role at all.

**What the profile does about it.** `omarchy-server-selinux admin-role`, run by
the addon at install time and available afterwards on any machine:

| | |
|---|---|
| `seusers` | `%wheel:staff_u` in the store's `seusers.local`, merged by `semodule -B`. `__default__` stays `user_u`. |
| login | `staff_u:staff_r:staff_t` — `staff_t` is in refpolicy's `unpriv_userdomain`, so sshd may transition into it with `ssh_sysadm_login` **off**. |
| sudo | `Defaults:%wheel role=sysadm_r, type=sysadm_t` in `/etc/sudoers.d/omarchy-selinux-role`, so `sudo id -Z` answers `staff_u:sysadm_r:sysadm_t`. |
| booleans | **one changed, and only for the cloud path.** `cloudinit_growpart=1`, written into the store's `booleans.local` beside `seusers.local`, because refpolicy ships it off and cloud-init cannot then read the disk it is about to grow (`reports/2026-08-29-cloud-image-selinux.md`). `ssh_sysadm_login` and `allow_ptrace` stay off. |

Nothing in the policy had to be changed for the role transition itself:
refpolicy's own users file already says `user staff_u roles { staff_r sysadm_r }`,
`allow staff_r sysadm_r` is already there, and `staff_sudo_t` may already
transition into any `userdomain`. The one rule the local module adds for this
is §16 of `omarchy_server.te` — `sysadm_t` writing to the pipe it inherited, so
a **non-interactive** `ssh host sudo …` does not silently lose its output.

**Why `staff_u` and not `sysadm_u`.** `sysadm_u` is authorised for `sysadm_r`
only, so the *login shell* would be `sysadm_t`: everything the operator does
over ssh — a build, a text editor, a file somebody sent them — would run in the
domain that may load policy and set enforcing, and there would be no
administrative boundary left to cross. It would also need
`ssh_sysadm_login=on`, which this arrangement does not. `staff_u` keeps the
confined session and the administrative domain apart, with an authenticated
`sudo` between them.

`%wheel` rather than the install user by name, because that is the group the
profile already grants sudo to and the group a second administrator is added
to. A `%group` entry is resolved by libselinux at login through `getgrnam`, and
if it cannot be resolved the lookup falls through to `__default__` — the
confined `user_u`. The failure direction is *less* privilege.

The preflight still refuses when the calling session's role cannot
`setenforce`, and it asks the honest form of the question: not "is the machine
configured" but "can **this** process, the one about to call `setenforce`, call
it again afterwards". On a machine where `admin-role` did not run, that is still
a refusal and still the right one. `--force` is for somebody who has a console.

Measured after the change: `permissive` → `enforcing` → `permissive` →
`enforcing`, all four from the same ssh session, and `/etc/selinux/config`
written each time so the mode survives a reboot.

### Two addons, not one

`selinux` is what a machine needs to **run** confined: the policy, the loader,
`restorecon`/`setfiles`/`semodule`, and the eight rebuilds. `selinux-tools` is
what a machine needs to **author** policy: `semanage`, `audit2allow`,
`sesearch` — i.e. `selinux-python` and `setools`.

The split is not tidiness. `setools` depends on `python-networkx`, and Arch's
`python-networkx` hard-depends on `python-scipy`, `python-pandas`,
`python-matplotlib` and `python-numpy`. Measured on an installed machine, those
two packages and their closure are **45 packages and 453 MiB** — a scientific
Python stack on a headless server so that somebody could run `audit2allow` on
it once. Splitting them took the SELinux route from +54 packages / +552 MiB to
**+9 packages / +99 MiB**.

What made it possible was rewriting the setup leaf to write
`file_contexts.local` directly instead of calling `semanage fcontext`. The
workflow it assumes: a machine reports its denials with
`omarchy-server-selinux avc`; the rule is authored wherever `selinux-tools` is
installed and ships as an `omarchy_server.te` in the profile, which every
machine compiles locally with `checkmodule`.

`selinux-tools` has a preflight that refuses on a machine with no SELinux
policy store, so it cannot be installed by mistake over an `apparmor` machine.

### The relabel happens during the install, and again on the first boot

SELinux labels the filesystem inside the install chroot, not on the first boot.
A relabel is minutes of I/O, and doing it while the machine is already busy
writing is cheaper than doing it with somebody watching a console. And then once
more on the first boot: `/.autorelabel` is left in place and
`omarchy-server-selinux-relabel.service` acts on it — `selinux-refpolicy-arch`
ships no such unit, so this profile ships one, enabled by the addon. That second
pass is not belt and braces: the orchestrator creates the user's home directory
in a phase that runs *after* the addon, so the offline pass cannot have labelled
a directory that did not exist yet, and an unlabeled `/home/<user>` locks the
operator out the moment the machine goes enforcing. §7 is the run where that
happened.

The unit is ordered `Before=systemd-user-sessions.service`, not before `sshd`
only. `systemd-user-sessions` is the gate that removes `/run/nologin`, so
ordering ahead of it holds back ssh, the serial getty and the virtual consoles
alike instead of racing them.

**Both passes use `restorecon -R -F /`, never `setfiles <file_contexts> /`.**
libselinux loads three spec files — `file_contexts`, then
`file_contexts.homedirs`, then `file_contexts.local` — when it opens the store
*by policy type*, and exactly one when it is handed a *path*, which `setfiles`
requires. So a `setfiles` relabel silently applied neither the
`/home/[^/]+ → user_home_dir_t` entry (which lives in `file_contexts.homedirs`)
nor this profile's own rules (which live in `file_contexts.local`). That was
half of the lockout in §7; the home directory being created late was the other
half.

Concatenating the three into one spec for `setfiles` was tried and is **not** a
fix: they legitimately disagree about `/root/.k5login`, which libselinux
resolves by precedence and `setfiles` rejects outright with "Multiple different
specifications", relabelling nothing. Only the loader has the precedence rules.

`file_contexts.homedirs` is generated by libsemanage's genhomedircon, so the
setup leaf runs `semodule -B` before relabelling and refuses to continue
quietly if the file is still empty afterwards.

`/.snapshots` is excluded from both passes. This profile keeps five snapper
snapshots and snapper mounts them read-only, so without the exclusion every
relabel on a machine that has ever taken a snapshot reports thousands of
"Read-only file system" errors and exits non-zero — which would leave
`/.autorelabel` in place and make `enforcing` refuse forever.

### Mutual exclusion

The kernel initialises one major LSM. Installing both would leave a machine
whose second addon silently does nothing, which is the failure mode a security
feature must never have. It is refused in three places:

- a **preflight leaf**, `install/server/addons/<name>.preflight.sh`, which
  `omarchy-server-addon` sources *before* it installs anything. Refusing in the
  setup leaf would be too late: seventeen packages, eight of them replacing core
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
| Packages | 220 | 222 (+2) | **229 (+9)** |
| Installed size | 1402 MiB | 1408 MiB (+6) | **1501 MiB (+99)** |
| Enabled units | 21 | 22 (+1) | 22 (+1) |
| Boot | 6.920 s | 7.376 s | 7.184 s |
| Packages replaced | 0 | 0 | 10 |
| Denials on a boot | — | 0 | **0** |
| Denials under the workload | — | 0 complain, 0 enforce | 31 permissive, 10 enforcing |
| Reached its enforcing mode | — | **yes, 24/24** | **yes** — permissive 36/36, enforcing reached without a lockout, but see below |

The SELinux column is the re-validation of report §10, not the original run:
`setools` and `selinux-python` moved to `selinux-tools` (−45 packages,
−453 MiB) and the local policy module took a bare boot to zero denials.

Three results from that run change what is written above, and are worth having
here rather than only in the report:

**AppArmor confines sshd and nothing else.** `omarchy-server-apparmor status`
measured **2 of 146** profiles under `/etc/apparmor.d` naming a binary this
machine has — `bin.ping`, and the `usr.bin.sshd` this addon ships itself. 163
profiles load; they are for desktop software that is not installed. That is the
route's real coverage, and it should be quoted whenever the route is described.

**82% of the SELinux route's size was not SELinux, and is now gone.** `setools`
depends on `python-networkx`, which in Arch has `python-scipy`, `python-pandas`,
`python-matplotlib` and `python-numpy` as hard dependencies — **45 packages and
452.9 MiB**. They are the `selinux-tools` addon now, and the route costs **+9
packages and +99 MiB**.

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

Those three were re-validated on a fresh install, and were **not sufficient**.
Two more things had to be fixed before `/home/<user>` was labelled at all —
`setfiles` reading only one spec file, and a four-field context being silently
dropped — and the ssh host keys turned out to be `etc_t` because they are
generated after the relabel. All five are in report §10.1.

**The one that is not fixed.** `sudo` does not change the SELinux role on this
profile: `sudo id -Z` answers `user_u:user_r:user_t`, because `seusers` maps
`__default__:user_u`. So in enforcing, an administrator cannot run `pacman`,
`ufw` or `systemctl`, and cannot switch back to permissive — enforcing is a
one-way door over ssh. That is the blocker now, and the section above says what
the fix looks like.

## 8. Recommendation

**Ship AppArmor as the switch. Keep SELinux, do not default to it yet.**

AppArmor costs two packages and 6 MiB, replaces nothing, has no lockstep
obligation, reached enforce with zero denials on the first attempt, and cannot
lock the operator out the way the SELinux run did. For a pipeline that wants to
turn something on, that is the whole argument — provided the claim made for it
is the true one: *sshd is confined*, not *the server is confined*.

SELinux confines vastly more. **It no longer costs vastly more**: the addon
split took it from +54 packages / +552 MiB to **+9 packages / +99 MiB**, and
the size argument that carried most of this recommendation is gone. Three of
the four conditions below have been met since it was first written:

1. ~~the enforcing fixes validated on a fresh install~~ — **done**. Permissive
   is 36/36 with zero boot denials; enforcing was reached and the operator kept
   ssh, `sudo`, the home directory, snapper, `pacman` and a reboot.
2. ~~`setools` and `selinux-python` split into a second addon~~ — **done**, as
   `selinux-tools`.
3. ~~a CI job comparing every `*-selinux` pkgver against Arch~~ — **done**,
   weekly in `omarchy-server-pkgs`; first run compared 14 rebuilds, all in sync.
4. an answer for `ps -Z`, which does not exist on this system. Unchanged.
5. ~~an administrative role, so `sudo` reaches a domain that can administer the
   machine and can leave enforcing again~~ — **done**. `%wheel` → `staff_u` in
   `seusers`, `role=sysadm_r, type=sysadm_t` in sudoers, applied by the addon.
   The enforcing workload passes end to end with **zero denials**, and
   enforcing is a two-way door over ssh.

What keeps AppArmor the default is now a shorter and sharper set of reasons:

- **The policy is materially behind the userland.** Getting a *bare boot* to
  zero denials took seven rounds, and new domains appeared for the same pattern
  at rounds 2 and 4. refpolicy 20250923 against systemd 261 is a standing gap,
  and this profile is on Arch.
- **Ten packages still have to track Arch.** Automated now, not eliminated: the
  job opens a ticket, it does not do the rebuild.

Which leaves the trade stated more precisely than before:

> **SELinux confines everything and costs a maintenance relationship. AppArmor
> confines one daemon and costs nothing.** The size gap has closed and so has
> the administrative-role gap; the maintenance gap has not, and it is now the
> whole of the argument.

The reasoning, with the evidence behind each number, is in
`reports/2026-08-29-mandatory-access-control.md` — §10 for the re-validation.
