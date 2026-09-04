# Maintenance

How this repository is kept alive between upstream releases. Right now that is
one subject: following upstream. Others will land here as they are automated.

## Following upstream

Nothing in this repository forks Omarchy. The server profile is an **overlay**
plus a **patch series** applied to an upstream tree pinned at a known commit,
which is what keeps the diff readable and what makes an upstream release
something to follow rather than something to merge. The cost of that choice is
paid once per release: the pin moves, the patches are rebased, and the whole
thing is rebuilt and re-tested.

### Where the pin lives

| File | What it pins | Who writes it |
|---|---|---|
| `upstream/PIN` | both upstream trees: repo, ref, commit, date | `tools/upstream-bump.sh` |
| `pkgbuilds/omarchy-server/PKGBUILD` (`_commit`), in `omarchy-server-pkgs` | the omarchy tree the package is built from | a human, per bump |
| `upstream/omarchy`, `upstream/omarchy-iso` | the local work clones the build scripts bind mount | `tools/upstream-bump.sh` |

`upstream/PIN` is the one file in git that says which upstream trees everything
here is derived from. Everything else either follows it or has to be set to
agree with it. The clones under `upstream/` are gitignored working copies, not
submodules; they are recreated by anyone who clones this repository (`README.md`
§ Upstream clones) and moved onto the pinned commits by the bump script.

The `_commit` in the sibling `omarchy-server-pkgs` checkout is deliberately
**not** written by the script: it lives in another repository, with its own
`pkgrel` discipline and its own publish workflow, and a bot that edited it would
be publishing packages nobody had looked at. The bump's pull request carries it
as a checklist item instead.

### The two channels

- **`tags`** — the latest upstream **release tag**. This is the channel the
  profile follows, because a release is the thing upstream itself considers
  finished. `omacom-io/omarchy-iso` publishes no tags at all, so for that
  repository the tags channel falls back to the default branch and says so in
  its report.
- **`edge`** — the tip of the upstream default branch. Never the pin: it is a
  canary, run weekly, whose only job is to notice that a patch is about to stop
  applying one release before it matters.

### The weekly job

`.github/workflows/upstream-tracker.yml` runs every Monday at 06:00 UTC, and on
demand from the Actions tab with a `channel` input.

1. It asks GitHub where `basecamp/omarchy` and `omacom-io/omarchy-iso` are now.
2. If neither has moved past `upstream/PIN`, it exits quietly. No pull request,
   no noise.
3. Otherwise it exports the new upstream trees into a temp directory and applies
   the patch series onto them — `profile/server/overlay/patches/*.patch` onto
   omarchy, `iso/patches/*.patch` onto omarchy-iso — recording the result of
   each patch.
4. It runs `make test`, writes the new `upstream/PIN`, pushes the new upstream
   commit to the `edimarlnx/omarchy` mirror the PKGBUILD clones from, and opens
   a pull request titled `Upstream bump: omarchy <tag>, omarchy-iso <tag>`.
5. The pull request body carries the changelog range, the per-patch result and
   the checklist below. **Nothing is merged automatically.**

If a patch no longer applies, the pull request is still opened, labelled
`needs-rebase`, and the job **fails** so the week's run is red rather than
quietly green. The `edge-canary` job runs beside it and only writes a job
summary; it opens nothing and never fails.

The job needs one secret, `MIRROR_PUSH_TOKEN`, a token with `contents: write`
on `edimarlnx/omarchy`. Without it the mirror step is skipped with a warning and
the package build will not find the new commit until someone pushes it by hand.

### The checklist a bump leaves behind

The bot moves the pin and proves the patches apply. What it cannot do, in order:

1. Rebase any conflicting patch (runbook below).
2. In `omarchy-server-pkgs`: set `_commit` to the omarchy commit named in
   `upstream/PIN`, and bump `pkgrel`.
3. `./bin/serverlab pkgs build && ./bin/serverlab pkgs test`.
4. `./bin/serverlab iso build`.
5. VM acceptance on a host with KVM: `./bin/serverlab lab up srv --profile server`
   then `./bin/serverlab lab test srv --suite base`.
6. Merge here, then let `publish.yml` in `omarchy-server-pkgs` republish the
   signed repository.

## Running the bump by hand

The workflow owns no logic of its own: `tools/upstream-bump.sh` is the whole
thing, and it is meant to be run locally.

```bash
tools/upstream-bump.sh --dry-run                  # what would move, and does it still patch
tools/upstream-bump.sh --channel edge --dry-run   # the same against the upstream tip
tools/upstream-bump.sh --omarchy-ref v4.0.2 --dry-run   # rehearse one specific bump
tools/upstream-bump.sh                            # and write upstream/PIN
```

`--dry-run` writes nothing and leaves the work clones where they are. Without
it, the script writes `upstream/PIN` and checks the clones out at the new
commits, so the local `pkgs/build.sh` and `iso/build.sh` build what the pin now
names.

Its exit code is the verdict, which is what CI reads:

| Code | Meaning |
|---|---|
| `0` | nothing moved, or everything moved and the whole series applies |
| `3` | upstream moved but at least one patch no longer applies |
| `1` | usage error, a missing tool, or `make test` failed |

The patch series is always applied to a **fresh `git archive` export** of the
new upstream tree, never to `upstream/omarchy` itself, so a failed rehearsal
cannot leave a half-patched work clone behind for the next build to pick up.
Each patch is run through `patch -p1 --forward --dry-run` before it is applied
for real, which is what lets the report say "this one conflicts" instead of
"something went wrong somewhere in the series".

## Rebasing a patch by hand

When the report says `CONFLICT omarchy/0005-update-noninteractive.patch`, that
patch has to be rewritten against the new upstream tree.

The two series are not in the same format, and that decides the tool. The
omarchy series (`profile/server/overlay/patches/`) is plain `diff -u` output
with a **prose header above the diff** explaining what the patch does and why;
the header is the point of keeping these as patches at all, so it is preserved
by hand. The ISO series (`iso/patches/`) is `git diff` output, `index` lines
included, which means git can three-way merge it.

Both start with a scratch branch at the new upstream commit:

```bash
cd upstream/omarchy
git fetch --tags origin
new=$(sed -n 's/^omarchy_commit=//p' ../PIN)
git checkout -B rebase-probe "$new"
```

### Find out exactly what broke

```bash
for p in ../../profile/server/overlay/patches/*.patch; do
  patch -p1 --forward <"$p" || echo "^^ conflict in ${p##*/}"
done
```

Everything up to the conflict is now applied to the work tree, and the patch
that failed left a `.rej` beside each file it could not touch. Read the `.rej`:
it is the hunk, with the context upstream no longer has.

### Redo the hunk, then regenerate the patch body

Edit the file so it does what the patch meant to do against the code that is
there now, and delete the leftovers:

```bash
$EDITOR bin/omarchy-update            # apply the intent of the .rej by hand
rm -f bin/omarchy-update.rej bin/omarchy-update.orig
```

Then regenerate the diff for **that file only** and put it back under the
patch's existing header, which stays as it was unless the reason for the change
also changed:

```bash
# the header: everything above the first `---` line
sed '/^--- /,$d' ../../profile/server/overlay/patches/0005-update-noninteractive.patch >/tmp/header
{ cat /tmp/header; git diff -- bin/omarchy-update; } \
  >../../profile/server/overlay/patches/0005-update-noninteractive.patch
```

`git diff` here is diffing against the scratch branch's commit, which is the
clean new upstream tree, so what comes out is exactly this patch's contribution
— as long as no earlier patch in the series touched the same file. When one
did, commit the series so far first (`git add -A && git commit -m wip`) and
diff against that commit instead.

Repeat for each conflicting patch, in series order.

### The ISO series

`iso/patches/` carries `index` lines, so git can do the merge itself:

```bash
cd upstream/omarchy-iso
git checkout -B rebase-probe "$(sed -n 's/^omarchy_iso_commit=//p' ../PIN)"
git apply -3 ../../iso/patches/0004-orchestrator-server-profile.patch
```

`-3` falls back to a three-way merge and writes conflict markers into the file
instead of a `.rej`. Resolve them, then regenerate the patch with
`git diff -- <file>` over the same header-preserving step above.

### Prove it

From the repository root:

```bash
tools/upstream-bump.sh --dry-run     # every patch must report `ok`
make test
./bin/serverlab pkgs build && ./bin/serverlab pkgs test
```

Two things worth remembering while resolving:

- A patch that upstream has **adopted** should be dropped, not rebased. If the
  new tree already does what the patch did, delete the file and renumber the
  rest; the series is smaller and that is the direction it should move in.
- A patch that no longer has a file to apply to usually means upstream moved a
  command. Find where it went before rewriting the hunk — the overlay may be
  the better home for the change now, and `profile/server/overlay/runtime/bin/`
  costs no rebase at all.

## Reverting a bump

`upstream/PIN` is one commit, so a bump is one revert. The work clones follow it
back with:

```bash
git -C upstream/omarchy checkout --detach "$(sed -n 's/^omarchy_commit=//p' upstream/PIN)"
git -C upstream/omarchy-iso checkout --detach "$(sed -n 's/^omarchy_iso_commit=//p' upstream/PIN)"
```

Anything already published from the bumped pin is undone the way any package
release is: a new `pkgrel` in `omarchy-server-pkgs` pointing back at the old
`_commit`.
