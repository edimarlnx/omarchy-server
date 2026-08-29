# A signed pacman repository on GitHub Releases

**Date:** 2026-08-29
**Subject:** `[omarchy-server]` — built and signed by CI, served from a release, consumed by an installed machine
**Result:** **13/13** local assertions including two tamper cases; the release is live and three CI runs have published to it

## Scope

Until this point the profile's packages existed only inside the ISO's offline
mirror. A machine installed from that ISO could boot, update Arch and snapshot
itself, but `omarchy-server-addon fwall` had nowhere to fetch `fwall` from, and a
fix to `omarchy-server` could not reach an installed machine at all.

The answer is a signed pacman repository served from the assets of a **fixed**
GitHub release (`repo`) of `edimarlnx/omarchy-server-pkgs`. The tag never moves;
every build replaces the assets under it, which gives pacman a stable base URL.
The idea is not new: the upstream Omarchy ISO already carries a
`releases/download/release` `Server` line for the MacBook T2 mirror.

```
[omarchy-server]
SigLevel = Required DatabaseOptional
Server = https://github.com/edimarlnx/omarchy-server-pkgs/releases/download/repo
```

## Environment

| | |
|---|---|
| Repository | `github.com/edimarlnx/omarchy-server-pkgs`, release tag `repo`, created 2026-08-29T04:42:49Z |
| CI | `.github/workflows/publish.yml`, `archlinux:latest` container, on every push to `main` and on manual dispatch |
| Signing key | the **lab** key, imported from the `PACMAN_GPG_KEY` secret into a throwaway GnuPG home; only the public half is committed |
| Local verification | `scripts/verify.sh` — a clean `archlinux` container, `repo/` served over **HTTP** on loopback |

## Method

The PKGBUILDs moved out of this repository into that one. Keeping them here
would mean a CI runner cloning a lab repository that is tied to a working tree,
or a second copy of four PKGBUILDs drifting from the first. `pkgs/build.sh` and
`iso/build.sh` now read them from the sibling checkout (`OMARCHY_PKGS_DIR` moves
it) and keep doing the thing only they can do: build against the **working
tree** of `profile/server/`, so editing the overlay stays a loop measured in
seconds. That repository carries a vendored copy of `profile/server/` for CI,
refreshed by its own `sync-overlay.sh`.

```bash
export GNUPGHOME=pkgs/keys/gnupg          # the lab key
../omarchy-server-pkgs/scripts/build.sh
../omarchy-server-pkgs/scripts/publish.sh --local   # assemble repo/ with repo-add --sign
../omarchy-server-pkgs/scripts/verify.sh            # serve over HTTP, install, attack
```

## Results

### Local verification over HTTP — 13 assertions, all PASS

| Assertion group | What it proves |
|---|---|
| transport | the database is fetched over HTTP, not from a local path |
| bootstrap | the key is read out of the keyring package, locally signed, the package installed under verification, then `pacman-key --populate omarchy-server` |
| install | `pacman -Sy` syncs `omarchy-server.db`; `fwall` and `omarchy-server` install with `SigLevel = PackageRequired` in force |
| client wiring | the installed `/etc/pacman.d/omarchy-server.conf` carries the real `Server` line |
| **hostile mirror** | the same repository re-served with `fwall` signed by a **freshly generated stranger's key** and the database rebuilt so every checksum agrees → pacman refuses (`required key missing from keyring`) and nothing installs |
| **unsigned** | the same package with its `.sig` removed → pacman refuses to complete the transaction and nothing installs |

The hostile-mirror case is the one that matters. A checksum proves nothing about
a database an attacker has just rewritten; the signature is the only thing
between the machine and that mirror. The download cache and the previously
synced database signature are both cleared before it runs, or the test would be
verifying the copy it already trusts.

### The release, live

Three workflow runs, all `success`:

| Run | Commit | Finished | Duration |
|---|---|---|---|
| 33234418039 | Document the repository | 2026-08-29T04:41:20Z | 1m37s |
| 33242220606 | Ship the non-interactive update path | 2026-08-29T08:02:38Z | 1m16s |
| 33244883873 | Bump `pkgrel`, vendor the Secure Boot addon | 2026-08-29T09:10:57Z | 1m30s |

Assets on the `repo` release after the last run:

```
fwall-0.1.0-1-x86_64.pkg.tar.zst                    1 541 682 B  (+ .sig)
omarchy-server-4.0.1-3-any.pkg.tar.zst                457 519 B  (+ .sig)
omarchy-server-settings-4.0.1-2-any.pkg.tar.zst        65 995 B  (+ .sig)
omarchy-server-keyring-20260828-1-any.pkg.tar.zst       3 784 B  (+ .sig)
omarchy-server.db / .db.tar.gz                          1 380 B  (+ .sig each)
omarchy-server.files / .files.tar.gz                   10 027 B  (+ .sig each)
```

An **end-to-end install from that public URL** was then run against a clean
machine: the keyring bootstrap by hand (fetch the database, read the keyring
package's file name out of it, extract the `.gpg`, `pacman-key --add` +
`--lsign-key`, install, `--populate`), the repository added, and `fwall`
installed with pacman reporting **`Validated By : Signature`**. That closes the
loop the local `verify.sh` only simulates: the transport is GitHub's CDN, the
signature is the one CI produced, and the client is an ordinary Arch machine.

### The three pieces on the client

1. **`omarchy-server-keyring`** puts the public key in
   `/usr/share/pacman/keyrings/` and its scriptlet runs
   `pacman-key --populate omarchy-server`, which is what makes
   `SigLevel = Required` mean something rather than merely say it. The runtime
   package depends on it, so it cannot be skipped.
2. **`omarchy-server-settings`** ships `/etc/pacman.d/omarchy-server.conf` and
   appends `Include = /etc/pacman.d/omarchy-server.conf` to each of the three
   channel templates. The definition lives in its own file precisely because
   `/etc/pacman.conf` is rewritten wholesale by `omarchy-refresh-pacman` and by
   the install's `post-install-pacman-server.sh`; a repository definition that a
   channel switch deletes is a repository that disappears at the worst moment.
3. **The install scriptlet** adds that `Include` to a `pacman.conf` already on
   disk, because an ordinary update never rewrites it from the template. It
   refuses in two cases: when `pacman.conf` has no `[omarchy]` section — which is
   how the live ISO's offline configuration looks inside the target chroot, and
   adding a remote repository there would send every remaining offline install to
   GitHub — and when an `[omarchy-server]` section is already defined inline.

## Evidence

- [`../docs/packaging.md`](../docs/packaging.md) §5 — the whole design: assets, the client pieces, the build, the verification table
- `omarchy-server-pkgs/scripts/verify.sh` — the 13 assertions, including both hostile cases
- `omarchy-server-pkgs/.github/workflows/publish.yml` — the workflow
- `pkgs/keys/gen-lab-key.sh` — exports the **public** half of the lab key into the keyring PKGBUILD in that checkout, where those three files are committed, because CI has to build the keyring package from that repository alone

## Findings and bugs

1. **`repo-add` leaves `omarchy-server.db` as a symlink** to
   `omarchy-server.db.tar.gz`, and `$repo.db` is the exact name pacman asks the
   mirror for. A release asset cannot be a symlink, so `publish.sh` uploads those
   two as **real copies**. A naive upload gets this wrong and the repository is
   unusable.
2. **Every content change must bump `pkgrel`.** Release assets are addressed by
   file name, and the file name carries `pkgver-pkgrel`. Rebuilding without a
   bump republishes the same asset name, `repo-add` records the same version,
   `pacman -Syu` compares versions, finds them equal, and reports nothing to do —
   the new content sits on the server and is never installed. **This already
   happened once**, to `omarchy-server` and `omarchy-server-settings` at
   `4.0.1-1`, which is why both restart at `4.0.1-2`. Nothing in the toolchain
   can detect it: a package with new contents and an old version is a perfectly
   valid package. `pkgs/test.sh` now reads the version back from pacman instead
   of hard-coding it, so a bump needs no edit there.
3. **`publish.sh` fetches the currently published database before adding this
   run's packages to it**, so a build that rebuilt one package does not strand
   the other three, and it deletes a package asset only once the database has
   stopped referencing it.
4. **`omarchy-server-addon` used to leave pacman to answer "target not found"**
   when the repository was missing. It now says so itself.

## Limitations

- **The key is a lab key.** Switching to a real one is four steps — generate
  offline, export the public half over the three keyring files, bump the
  keyring's `pkgver`, put the private half in the `PACMAN_GPG_KEY` secret — and
  the rotation **order** matters: a machine already installed trusts only the old
  key, so the package that teaches it the new one has to be signed by the old
  one.
- **The live end-to-end install has no captured transcript in this repository.**
  It was run interactively; `pocs/` holds nothing from it. The reproducible
  artifact is `verify.sh`, which covers the same path over loopback HTTP. Worth
  turning the public-URL run into a script that writes its output somewhere.
- The ISO's offline mirror is unaffected and still reads with
  `SigLevel = Optional TrustAll`, which is right: its integrity is the ISO's, and
  pacstrap verifies against the *live* keyring, not the target's.
- `docs/packaging.md` §5 still ends with a "What is left: publishing itself"
  paragraph written before the first workflow run. The release now exists; that
  paragraph is stale.

## Next steps

- Script the public-URL install so it produces evidence next to the other runs.
- Replace the lab key, following the documented rotation order.
