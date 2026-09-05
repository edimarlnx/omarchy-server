# Security updates and the reboot window

A headless machine has two conflicting duties. It has to close published
vulnerabilities quickly, and it has to stay exactly as it was between the
moments somebody chose to change it. Taking the whole rolling release every
night satisfies the first and destroys the second; taking it once a month
satisfies the second and leaves a CVE open for weeks.

So this profile splits the update in two.

| | what moves | when | unit |
|---|---|---|---|
| security-only | only the packages `arch-audit` reports as vulnerable with a fix already published, plus their dependencies | daily | `omarchy-server-update-security.timer` |
| full | everything the repositories offer | weekly, Sunday 03:00 | `omarchy-server-update.timer` |
| reboot | nothing; takes a reboot an earlier run deferred | at the start of the reboot window | `omarchy-server-update-reboot.timer` |

```bash
sudo omarchy-server-update enable              # all three, from the config below
sudo omarchy-server-update run --security-only # now, by hand
sudo omarchy-server-update status              # what it did, what is still open
```

All three ship **disabled**, like the timer they replace.

## The security-only run

```
$ sudo omarchy-server-update run --security-only
vulnerable packages with a fix available: curl libxml2 linux
== pacman -Sy
== pacman -S --needed curl libxml2 linux
restarted: sshd systemd-resolved
deferred: none
reboot required: linux 6.19.14.arch1-1 -> 6.19.15.arch1-1
reboot deferred to window 04:00-05:00 (required since 2026-09-03T01:12:44-03:00)
```

The set comes from `arch-audit -uq`, which cross-checks the local package
database against [security.archlinux.org](https://security.archlinux.org) and
prints the installed packages whose advisory is **already fixed** in a version
the repositories carry. Packages with an open advisory and no fix are not in
the set: there is nothing to install for them, and the run is not the place to
learn about them (`arch-audit` on its own is, and `status` counts them).

Then `pacman -S --needed` on exactly that list. Dependencies are **not**
restricted — a fixed package that needs a newer library gets the newer library,
because the alternative is a machine that does not run — and nothing else
moves.

Everything after the package half is what a full run does, unchanged: the
snapper snapshot before, `omarchy-server-update-restart` after (which restarts
the services whose files were replaced and decides whether a reboot is really
required), and the same reboot handling. `--transactional` works too: the same
snapshot, the same swap, the same `omarchy-server-update rollback`.

**When the set is empty — most days — nothing happens at all.** No snapshot, no
database refresh, no pacman transaction, no reboot decision:

```
$ sudo omarchy-server-update run --security-only
no installed package has an open advisory with a fix available: nothing to do
```

### It is a partial upgrade, on purpose

Refreshing the sync databases and installing only some of what they offer is
the thing Arch tells you not to do, and it is precisely what this mode is. The
trade is deliberate and bounded: the window between a security-only run and the
next full run is at most a week, `--needed` keeps the set to packages that
actually moved, and dependencies are resolved rather than pinned. That is why
the full run stays on the calendar and why it is weekly rather than monthly. A
machine that only ever ran `--security-only` would drift.

## The reboot window

Whether a reboot is required is decided by the classifier, from what the
transaction did (see the README section on restarting what changed). **When**
that reboot is taken is decided by `REBOOT_WINDOW`:

* inside the window, the run takes the reboot itself when it finishes;
* outside it, the reboot-required marker is left where it is and the run prints
  `reboot deferred to window 04:00-05:00`. `omarchy-server-update-reboot.timer`
  fires at the start of the window and runs `reboot-if-due`, which reboots if
  and only if that marker is still set.

```bash
sudo omarchy-server-update reboot-if-due   # what the timer runs
```

A window whose end is before its start wraps around midnight: `23:00-01:00` is
two hours. A window that cannot be parsed falls back to the shipped default
with a warning on stderr — a typo is not consent to reboot at noon.

`--no-reboot` still means never and `--kexec` still means now, whatever the
window says: an operator at the keyboard outranks the calendar. With
`omarchy-server-update kexec on`, a reboot taken inside the window goes through
the signed UKI instead of the firmware.

Nothing clears the marker except the next update, which compares its
modification time against the boot time. That is what proves the reboot was
actually taken rather than merely asked for.

## The configuration

`/etc/omarchy/server/update.conf`, shipped by `omarchy-server-settings` with
these defaults and listed in the package's `backup=` array, so an edit survives
every upgrade:

```sh
SECURITY_DAILY=yes        # run the daily security-only update
FULL_WEEKLY=sun           # the day of the weekly full update, at 03:00
REBOOT_WINDOW=04:00-05:00 # when this machine may reboot itself, local time
```

`omarchy-server-update enable` reads the file and writes the difference from the
shipped units as drop-ins under `/etc/systemd/system/*.timer.d/`, so a package
upgrade cannot reset the schedule and `systemctl cat` shows both lines. **Edit
the file, then run `enable` again.**

`KEXEC` and `TRANSACTIONAL` are not here. They live in
`/etc/omarchy-server-update.conf` because the command writes them itself
(`omarchy-server-update kexec on`, `… transactional on`), and a file a program
rewrites is a bad place for settings a person edits.

## Status, and the machine-readable version

```
$ omarchy-server-update status
mode: in-place
last full run: 2026-09-01T03:41:12-03:00
last security run: 2026-09-03T04:07:55-03:00
pending vulnerable packages: 2
reboot due: yes, since 2026-09-03T04:09:31-03:00
reboot window: 04:00-05:00
upstream migrations: 96 marked done for root, 0 allowed
timers: omarchy-server-update.timer enabled, omarchy-server-update-security.timer enabled, omarchy-server-update-reboot.timer enabled
```

`pending vulnerable packages` is the count `arch-audit` reports now, not what
the last run installed: it is the number that should be zero shortly after a
security run and that going up is the thing to notice. It reads `unknown` when
`arch-audit` is not installed.

`status --json` emits the same fields for a monitor to collect:

```json
{
  "mode": "in-place",
  "timers": {"full": "enabled", "security": "enabled", "reboot": "enabled"},
  "last_full_run": "2026-09-01T03:41:12-03:00",
  "last_security_run": "2026-09-03T04:07:55-03:00",
  "pending_vulnerable_packages": 2,
  "reboot_due": true,
  "reboot_due_since": "2026-09-03T04:09:31-03:00",
  "reboot_window": "04:00-05:00",
  "full_weekly": "sun",
  "security_daily": "yes",
  "upstream_migrations": {"marked_done_for_root": 96, "allowed": 0}
}
```

Every key is always present. A run that never happened is `null`, not a missing
field, and `pending_vulnerable_packages` is `null` rather than absent when
`arch-audit` is missing — a consumer should not have to special-case a machine
that is less complete than the one it was written against.

`upstream migrations` is the pair described in the next section: how many
upstream migrations are marked as already applied for root, and how many the
profile has explicitly opted back into. Compare the first number with
`ls /usr/share/omarchy/migrations | wc -l`; a machine where it is lower has
migrations the next unattended update will run as root.

`reboot_due` staying true for days, or `pending_vulnerable_packages` climbing,
is the pair worth alerting on.

## Upstream migrations on a server

**Policy: upstream Omarchy migrations do not run on this profile unless the
profile asks for them.**

Omarchy records migrations per user, under
`~/.local/state/omarchy/migrations`, and `omarchy-migrate` runs every migration
that has no marker there. On a headless machine the account that runs them is
root, because that is the account the update runs as — the `== migrations`
step inside `omarchy-server-update`.

That is a bad place for them. Upstream migrations exist to carry an existing
desktop install forward; a machine on this profile ships current, so there is
nothing to carry. They run under `bash -euo pipefail` inside the update, so the
first one that fails aborts an unattended run. And they reason about the
account they are running as, which on a server is root — an account this
profile deliberately cannot log in with.

The concrete case: omarchy v4.0.2 shipped a migration that hardens sshd, and
its "no usable key authorized" branch runs `systemctl disable --now
sshd.service`. Run as root on a machine whose `PermitRootLogin` is `no`, root's
empty `authorized_keys` says nothing about the machine — and the migration took
the only login path off a remote server, in the middle of an unattended update,
with nothing to put it back. The measurement is in
`reports/2026-09-04-upstream-4.0.2.md`.

### How the opt-out works

`omarchy-server-migration-seed` writes an empty marker into
`/root/.local/state/omarchy/migrations/` for every migration the package
ships, which is exactly what `omarchy-migrate` reads as "already applied". It
runs in two places, and both go through the same command:

- **at install**, from `install/server/root-migration-state-server.sh`;
- **on every package upgrade**, from the `omarchy-server` package's
  `post_install` / `post_upgrade` scriptlet — so a migration that arrives with
  a new upstream release is marked *before* the update's migration step can
  reach it.

Only root is seeded. `/etc/skel` already carries a full set of markers, so an
account created after the package landed replays nothing on its own; and a
person's home directory is theirs. If somebody runs a desktop Omarchy session
on this machine, whether upstream's migrations touch their dotfiles is their
decision, not the server package's. The command's header spells this out.

Markers are only ever created, never removed, and only when missing — so the
scriptlet running on every upgrade is a no-op after the first time.

### The allowlist

Opting out of everything by default would be a way to quietly miss a migration
that matters, so the opt-out has a documented way back in:

```
/usr/share/omarchy/migrations                 what the package ships
/usr/share/omarchy/install/server/migrations-allow   what the profile wants to run
```

The allowlist is `profile/server/migrations-allow` in this repository. One
migration id per line — the file name under `migrations/`, with or without the
`.sh` suffix; `#` starts a comment. Anything listed there is left **unmarked**,
so it stays pending and the next `omarchy-migrate` runs it exactly as upstream
intended.

It ships empty. Reviewing it is part of an upstream bump: read the release's
new migrations, and add the id of any that a headless machine genuinely needs.
Adding an id does not un-mark a migration a machine already marked — a marker
means the machine is past it. Delete that marker by hand to replay one.

`omarchy-server-update status` reports both numbers, so a fleet can be asked
whether the seeding actually happened.

### What is tested

`test/shell.d/migration-seed-test.sh` runs the command against a fixture with
three migration files and an allowlist naming one: two are marked, one is left
pending, a second run changes nothing, a migration that arrives later is marked
too, `--dry-run` writes nothing, and a missing migrations directory or a
missing allowlist is reported rather than fatal.

## What is tested, and what needs a machine

`test/shell.d/update-security-only-test.sh` runs the real command with
`arch-audit`, `pacman`, `omarchy-snapshot`, the classifier and `systemctl`
stubbed, and covers the empty set, both `arch-audit` output shapes, the noise
that is not a package name, the window (inside, outside, wrapping midnight,
unparsable), `reboot-if-due` with and without the marker and the shape of
`status --json`.

The fixtures are the real formats. `arch-audit 0.2.0` on a lab machine prints

```
$ arch-audit
libxml2 is affected by denial of service. High risk!
linux is affected by multiple issues, insufficient validation. Medium risk!
$ arch-audit -q
libxml2
linux
$ arch-audit -uq          # nothing on that machine had a published fix yet
$ echo $?
0
```

so an empty answer is a normal day and not a failure, and the sentence form has
no `Package ` prefix on this release even though older ones printed one. Both
are parsed.

What the shell tests cannot cover, and what an installed machine has to: the
bytes `arch-audit -uq` prints on a day something IS upgradable, and whether
`pacman -S --needed` on that set resolves without a conflict on a machine a week
behind the repositories.
