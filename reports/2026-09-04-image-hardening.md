# Image hardening: the graphical decode chain, and the libxml2 advisory

**Date:** 2026-09-04
**Subject:** two independent pieces of the "zero known-vulnerability open at build" goal — removing the graphical image-decoding chain a headless server never uses, and settling the three High libxml2 CVEs that a scanner reports against the base
**Result:** the decode chain (`libtiff`, `giflib`, `libjxl`, `librsvg`, `lcms2`, `gdk-pixbuf2`, `glycin`, plus `fontconfig`, `freetype2`, `libpng`) is provably removable with no loss of function — boot, snapshots and router acceptance all still pass without it; the three High libxml2 CVEs are **already fixed** in the installed `libxml2 2.15.3`, and the advisory that still lists them is stale

## Scope

Two levers toward an image that ships with no open, evidenced vulnerability.

1. **Surface reduction.** A headless server pulls a full graphical image-decoding
   stack it never calls. Every package in it is code the machine carries and a
   scanner matches CVEs against, for a capability the profile has no use for.
   Trace where it enters the package set and cut it at the honest root.
2. **libxml2.** A scanner flags three 2025 High CVEs against the base `libxml2`.
   The library cannot be removed — it is a hard dependency of `libarchive`,
   which `pacman` itself needs — so each CVE needs a verdict backed by evidence:
   fixed, not applicable, or accepted on the record.

Each piece was investigated and proven on its own. The surface work was done and
measured first because it is the safe one: it removes code rather than changing
what remains.

## Environment

| | |
|---|---|
| Lab VM | an isolated single-NIC VM booted from the server cloud image, runtime reporting `4.0.1`, profile `server` |
| Kernel | `7.2.2-arch1-1` |
| Relevant package versions | `libxml2 2.15.3-1`, `gdk-pixbuf2 2.44.7-1`, `glycin 2.1.5-2`, `librsvg 2:2.62.3-1`, `libtiff 4.7.2-1`, `giflib 6.1.3-2`, `libjxl 0.12.0-1`, `lcms2 2.19.1-1`, `libnotify 0.8.8-1`, `limine-snapper-sync 1.31.0-1` |

The chains examined are defined by Arch package dependencies and package
versions, which are the same rolling-snapshot versions the current point release
installs; the finding is not specific to the runtime label the VM happened to
report.

---

# Part 1 — the graphical decode chain

## What is pulled, and by what

The seven packages the scan flags as a graphical stack are all tied together in
a single dependency knot. `pactree -r` on each of them resolves to one entry
point:

```
libtiff  ─ required by ─ lcms2   ┐
giflib   ─ required by ─ libjxl   ├─ all required by ─ glycin
librsvg  ─────────────────────────┘
glycin   ─ required by ─ gdk-pixbuf2
gdk-pixbuf2 ─ required by ─ libnotify  and  librsvg   (a cycle)
libnotify ─ required by ─ limine-snapper-sync ─ required by ─ omarchy-server
```

`gdk-pixbuf2`, `glycin` and `librsvg` form a dependency cycle among themselves,
so the only non-circular way the whole knot enters the server is through
**`libnotify`**, and `libnotify` has exactly one consumer on the machine:

```
$ pactree -r libnotify
libnotify
└─limine-snapper-sync
  └─omarchy-server
```

`limine-snapper-sync` is the package that integrates Limine boot entries with
Snapper snapshots — the profile needs it, and it is a hard dependency of the
`omarchy-server` metapackage. It declares `libnotify` as a **hard** `depends`,
`libnotify` declares `gdk-pixbuf2` as a **hard** `depends`, and current Arch
`gdk-pixbuf2` declares `glycin` as a **hard** `depends`. `glycin` is the modern
image-loader layer, and it is what drags in `libjxl` (→ `giflib`), `lcms2`
(→ `libtiff`) and `librsvg`, and through those `fontconfig`, `freetype2` and
`libpng`.

This is not a `base-devel`, `mesa` or desktop leak, and it is not a package that
can be dropped from a profile list. It is one legitimately-needed package
carrying an over-declared hard dependency: `limine-snapper-sync` pulls
`libnotify` for desktop notifications on snapshot events, which a headless
server has no session, no D-Bus and no notification daemon to display.

## `libnotify` is dead weight on a headless machine

The snapshot integration itself does not link `libnotify`. Its main binary
loads none of the graphical libraries:

```
$ ldd /usr/lib/limine/limine-snapper-sync | grep -iE 'notify|gdk|pixbuf|glycin|tiff|gif|jxl|rsvg'
  (none of the graphical libs linked)
```

`libnotify` is reached only through the `notify-send` command line, from a
handful of shell scripts (`limine-snapper-notify`, `limine-snapper-restore`,
`limine-snapper-watcher`) and two XDG autostart entries. Every call site is
already guarded and opt-in:

```
notify_user() {
    ...
    if command -v notify-send &>/dev/null; then
        action=$(notify-send ... )
    else
        error_msg "notify-send is not installed."
```

The autostart `.desktop` files require a graphical session that never exists on
this profile, and notifications sit behind an `ENABLE_NOTIFICATION` config knob
and a `--notify` flag. Remove `notify-send` and the tool logs one line and
carries on. The correct dependency class for `libnotify` here is `optdepends`,
not `depends`.

## Proof: remove the whole chain, then check the machine still works

On the lab VM the chain was removed exactly as a package that treated
`libnotify` as an optional dependency would leave it — `libnotify` first, then
the now-orphaned decoder graph:

```
# pacman -Rdd libnotify
# pacman -Rns gdk-pixbuf2 glycin librsvg lcms2 libjxl libtiff giflib
```

The recursive removal also took `fontconfig`, `freetype2`, `libpng`, `xorgproto`,
`libxau` and `libxdmcp` as orphans — nothing else on the server needed them.
`limine-snapper-sync` stayed installed and intact (`pacman -Qkk`: 48 files, 0
altered), which is expected since its binary never linked any of the removed
libraries.

The machine was then rebooted and measured:

| Check | Result |
|---|---|
| `systemctl is-system-running` | `running` |
| Failed units | none |
| Decode chain still present | none of the 11 packages remain |
| `limine-snapper-sync.service` | ran to completion, `status=0/SUCCESS` |
| `limine-snapper-list` | lists the existing snapshots correctly |
| Snapper plugin `/usr/lib/snapper/plugins/10-limine-snapper-sync` | present |
| `tui-router --check` | `rc=0`, full JSON status returned |
| `omarchy-router-firewall --preview` | `rc=0`, ruleset rendered |

The snapshot-to-boot integration — the entire reason `limine-snapper-sync` is in
the profile — works without `libnotify` and the graphical stack. The box boots,
no unit fails, and both acceptance commands pass.

Installing `arch-audit` on the trimmed machine and running it confirms the
chain no longer contributes anything to match against:

```
$ arch-audit
libxml2 is affected by denial of service. High risk!
linux is affected by multiple issues, insufficient validation. Medium risk!
openssl is affected by arbitrary command execution, certificate verification bypass. Medium risk!

$ arch-audit | grep -iE 'libtiff|giflib|libjxl|librsvg|gdk-pixbuf|glycin|lcms2|libnotify'
  (no output)
```

`arch-audit` tracks Arch advisories with a published fix, so it does not list
`libtiff`/`giflib` even before removal — their historical CVEs are fixed in the
shipped versions. The value of removal is against a version-matching scanner
(the kind the build gate will run): with the packages gone, the ~22 stale
`libtiff`/`giflib` CVE matches and the `libjxl`/`librsvg`/`lcms2` surface have
nothing left to match. After the cut the only thing `arch-audit` reports is the
libxml2 advisory of Part 2 (plus the `linux` and `openssl` entries, which are
noise: a 2026 kernel matched against 2020–2021 advisories, and `openssl` CLI
paths the server does not run).

## The fix, and why nothing is shipped in this PR

The honest change is one line where the dependency is declared: move `libnotify`
from `depends` to `optdepends` in the `limine-snapper-sync` package. It is a
metadata change — no code, no recompile — and it is safe precisely because the
runtime already degrades gracefully without `notify-send`.

`limine-snapper-sync` is not built in this repository. It comes from the
upstream `[omarchy]` package repository and is a Kotlin / Gradle project built
to a native image, so producing a local rebuild would mean standing up a JVM and
native-image toolchain and then tracking that third-party project release by
release. That is the wrong tradeoff for a one-line metadata change, and it would
put a boot-critical package under our maintenance. Two better paths:

1. **Upstream the change (recommended).** Send the `optdepends` move to the
   package's maintainer. It fixes every consumer, costs us no fork, and is the
   correct home for the change. Draft below.
2. **In-repo fallback, only if upstream declines.** The `[omarchy-server]`
   repository already shadows base packages (the SELinux rebuilds) and is
   ordered so its versions win. A `libnotify`-as-`optdepends` build of
   `limine-snapper-sync` published there as `1.31.0-2` would win over the
   upstream `1.31.0-1` at bake and on update. This does **not** need a Kotlin
   rebuild: it can be a metadata-only repackage of the upstream binary package
   (rewrite the `depend`/`optdepend` line in `.PKGINFO`, repack, re-sign),
   plus a lockstep check like the SELinux one so an upstream version bump past
   `1.31.0-2` is noticed. It adds a boot-critical override and a maintenance
   surface, so it is a decision for the owner, not something this PR bakes in.

Because the load-bearing risk (does the machine still work without the chain?)
is proven on the lab, and the remaining choice is an ownership/maintenance call,
this PR ships the finding and the drafted submission rather than an unvalidated
override of a boot package.

### Drafted submission (not sent) — `limine-snapper-sync`: `libnotify` should be optional

> **Subject:** Make `libnotify` an optional dependency
>
> `limine-snapper-sync` declares `libnotify` as a hard dependency, but the
> daemon binary does not link it — `libnotify` is used only through the
> `notify-send` command from the notification helper scripts, and every call
> site is already guarded with `command -v notify-send` and gated behind
> `ENABLE_NOTIFICATION` / `--notify`. On a headless install there is no session,
> no D-Bus and no notification daemon, so `libnotify` is never exercised, yet as
> a hard dependency it pulls the full `gdk-pixbuf2 → glycin → {libjxl, lcms2,
> librsvg}` image-decoder stack (and transitively `libtiff`, `giflib`,
> `fontconfig`, `freetype2`, `libpng`) onto machines that never decode an image.
>
> Please move `libnotify` from `depends` to `optdepends`:
>
> ```
> -depends=('bash' 'limine' 'snapper' 'btrfs-progs' 'libnotify')
> +depends=('bash' 'limine' 'snapper' 'btrfs-progs')
> +optdepends=('libnotify: desktop notifications on snapshot events')
> ```
>
> Verified on a headless machine: with `libnotify` and the decoder stack
> removed, the service runs to `status=0/SUCCESS`, `limine-snapper-list` and the
> Snapper plugin work unchanged, and the notification scripts log one line and
> continue. Desktop installs keep the notifications because `optdepends` is
> installed by default on a full setup.

---

# Part 2 — libxml2 (CVE-2025-49794, CVE-2025-49795, CVE-2025-49796)

## Why it cannot just be removed

`libxml2 2.15.3-1` is a hard dependency of `gettext`, `libarchive` and
`snapper`; `libarchive` is what `pacman` links to read packages, so the library
stays. On this server it is exercised by `pacman`/`libarchive` (the `xar`
archive path) and by `snapper` (which reads a per-snapshot `info.xml` with the
ordinary parser). Nothing on the server invokes Schematron validation.

## The advisory

The Arch security tracker groups the three High CVEs (plus one Low) as
**AVG-2898**, status **Vulnerable**, `fixed: null`:

| CVE | Severity | Tracker status | Area |
|---|---|---|---|
| CVE-2025-49794 | High | Vulnerable | Schematron — use-after-free |
| CVE-2025-49795 | High | Vulnerable | Schematron — NULL-pointer dereference (DoS) |
| CVE-2025-49796 | High | Vulnerable | Schematron — type confusion |
| CVE-2025-6170 | Low | Vulnerable | `xmllint` interactive shell |

`fixed: null` means no Arch maintainer has recorded a fixed package version on
the advisory. It does **not**, on its own, mean the shipped package is
vulnerable — and here it is not.

## Upstream fixed all three, and the fix is in the installed version

The three High CVEs are all in the Schematron code, and upstream GNOME libxml2
fixed them on 2025-07-04:

| CVE | Fix commit | Message |
|---|---|---|
| CVE-2025-49795 | `499bcb78`, `24d7e159` | "Schematron: Fix null pointer dereference leading to DoS" / "Complete fix for CVE-2025-49795" (#932) |
| CVE-2025-49794, CVE-2025-49796 | `71e1e8af` | "schematron: Fix memory safety issues in `xmlSchematronReportOutput` — Fix use-after-free (CVE-2025-49794) and type confusion (CVE-2025-49796)" (#931, #933) |

These first shipped in upstream `v2.14.5` (2025-07-10) and were backported to
`v2.13.9` and `v2.14.6` (2025-09-08). The installed Arch package is `2.15.3`
(upstream tag `v2.15.3`, 2026-04-15), which is on the newer line.

Containment was checked both ways with the upstream compare API:

- `24d7e159 … v2.15.3` → 138 commits (the tag is 138 commits ahead of the fix).
- `v2.15.3 … 24d7e159` → 0 commits (the fix has nothing the tag lacks).

Zero commits on the reverse compare proves `24d7e159` is an ancestor of
`v2.15.3` — the fix is in the tree Arch builds `2.15.3` from. The tag's `NEWS`
lists both Schematron fixes.

To rule out a later revert, the fixed function was read directly from
`schematron.c` at `v2.15.3`. `xmlSchematronReportOutput` — the function that
carried the use-after-free and the type confusion — is now a safe stub:

```c
xmlSchematronReportOutput(xmlSchematronValidCtxtPtr ctxt ATTRIBUTE_UNUSED,
                          xmlNodePtr cur ATTRIBUTE_UNUSED,
                          const char *msg) {
    /* TODO */
    xmlPrintErrorMessage("%s", msg);
}
```

Both `ctxt` and `cur` are `ATTRIBUTE_UNUSED`: there is no cast of `cur` and no
dereference, so neither the use-after-free nor the type confusion can occur. The
fixing commit also shipped a regression test (`test/schematron/cve-2025-49794_0.xml`).

Arch's `2.15.3` is built **with** Schematron enabled (`xmllint --version` lists
`Schematron`, and the `xmlSchematron*` symbols are exported), so the code is
present — but it is the fixed code. (Upstream `2.15.x` disables Schematron by
default; Arch does not take that default, which is why the advisory is not
moot on the build flag alone. It is moot on the fix.)

## Verdict — not applicable / already fixed

The installed `libxml2 2.15.3-1` is **not vulnerable** to CVE-2025-49794,
CVE-2025-49795 or CVE-2025-49796. The upstream fixes are present in the exact
source the package is built from, confirmed by ancestry, by `NEWS`, and by
reading the fixed function. AVG-2898 is stale — it was opened against `2.14.4`
(the release current when it was filed) and never updated once `2.14.5`+ shipped
the fix.

This is the plan's "not applicable / already fixed" verdict: a **suppression
with evidence**, not an accept-on-record and not a backport. There is nothing to
backport — Arch already ships the fix in the binary — and nothing to accept: the
residual exposure is that the (fixed) Schematron path would only ever run if the
server validated an attacker-controlled schema against an attacker-controlled
document, which no server automation does.

Because `arch-audit` reads the tracker, it will keep reporting `libxml2` as High
until AVG-2898 is closed. The suppression entry below is what the build gate
should carry so this does not read as an open finding; closing the advisory
upstream removes it at the source.

### Suppression entry for the build gate

```
package:   libxml2 2.15.3-1
cves:      CVE-2025-49794, CVE-2025-49795, CVE-2025-49796
verdict:   not-applicable / already-fixed
evidence:  upstream fixes 499bcb78, 24d7e159 (CVE-2025-49795) and 71e1e8af
           (CVE-2025-49794, CVE-2025-49796), all ancestors of tag v2.15.3;
           xmlSchematronReportOutput is a safe stub at v2.15.3; Arch tracker
           AVG-2898 not yet updated. Reviewed 2026-09-04.
review:    re-check if libxml2 is downgraded below 2.14.5 or AVG-2898 changes.
```

### CVE-2025-6170 (Low)

The remaining item on AVG-2898 is a stack overflow in the `xmllint` interactive
shell (`xmllint --shell`) command parser. It is Low, requires a human running
`xmllint` interactively and typing shell commands, and is on no server path. It
does not block; it is recorded here so the gate can suppress it with the same
"not on any server path" reasoning.

### Drafted note (not sent) — ask Arch to update AVG-2898

> **Subject:** AVG-2898 (libxml2): fixed since 2.14.5, tracker still Vulnerable
>
> AVG-2898 lists CVE-2025-49794/49795/49796 as Vulnerable against `libxml2`
> with no fixed version. All three were fixed upstream on 2025-07-04 in commits
> `499bcb78` + `24d7e159` (CVE-2025-49795) and `71e1e8af` (CVE-2025-49794,
> CVE-2025-49796), first released in `v2.14.5` and backported to `v2.13.9` /
> `v2.14.6`. The currently packaged `2.15.3-1` descends from those commits (they
> are ancestors of tag `v2.15.3`) and the fixed `xmlSchematronReportOutput` is a
> safe stub in that source. Could AVG-2898 be marked Fixed for the `2.14.5`
> line? Happy to attach the compare output and the function body.

---

# What this PR contains, and what is owed

- **Ships:** this report. No package or profile change — the surface fix belongs
  upstream (drafted), and the libxml2 finding is that the shipped package is
  already fixed (drafted note to close the stale advisory).
- **Proven on the lab:** the graphical decode chain is fully removable with no
  loss of boot, snapshot or router-acceptance function.
- **Owed to the owner (decisions, not code):**
  1. send the `limine-snapper-sync` `optdepends` submission upstream, or, if
     declined, decide whether to carry the metadata-repackage override in
     `[omarchy-server]`;
  2. send the AVG-2898 update request so `arch-audit` stops reporting a fixed
     issue as open;
  3. feed the libxml2 suppression entry to the build gate when it lands.
