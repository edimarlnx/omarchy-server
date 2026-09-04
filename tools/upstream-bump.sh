#!/bin/bash

# Follow upstream: resolve where basecamp/omarchy and omacom-io/omarchy-iso
# are now, compare that with what this repository is pinned to, and prove the
# patch series still applies before anything is written down.
#
#   tools/upstream-bump.sh --dry-run           what would move, and does it still patch
#   tools/upstream-bump.sh                     the same, then write upstream/PIN
#   tools/upstream-bump.sh --channel edge      follow the default branch instead of tags
#   tools/upstream-bump.sh --omarchy-ref v4.0.2 --dry-run    rehearse one specific bump
#
# The pin lives in upstream/PIN, which is the ONE file in this repository that
# says which upstream tree everything here is derived from. The PKGBUILD's
# `_commit` in the sibling omarchy-server-pkgs checkout has to agree with it;
# this script does not reach into that repository, it reports the value the
# human (or the follow-up PR) has to set there.
#
# The patch series is applied to a FRESH EXPORT of the new upstream tree
# (`git archive` into a temp dir), never to upstream/omarchy itself: a rebase
# rehearsal must not leave a half-patched work clone behind. Each patch is run
# through `patch -p1 --forward --dry-run` first and only then for real, so the
# report distinguishes "conflicts" from "applied and then something else
# broke".
#
# Exit codes, because CI reads them:
#   0  nothing moved, or everything moved and every patch applied
#   3  upstream moved but at least one patch no longer applies (needs rebase)
#   1  usage error, missing tool, or `make test` failed
#
# Requirements: git, gh (authenticated), patch, tar. `make test` additionally
# needs go, and is skipped with a warning when it is not installed.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# The two upstream repositories, their work clone under upstream/, and the
# patch series this repository applies on top of each.
omarchy_repo=basecamp/omarchy
omarchy_iso_repo=omacom-io/omarchy-iso
# The public mirror the PKGBUILD's `source=` points at. Only reported here;
# pushing to it is the workflow's job, since it is the half that needs a token.
mirror_repo=edimarlnx/omarchy

pin_file="$repo_root/upstream/PIN"

channel=tags
dry_run=0
omarchy_ref=
omarchy_iso_ref=
body_out=
no_fetch=0

usage() {
  sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while (($#)); do
  case $1 in
  --dry-run) dry_run=1 ;;
  --channel)
    channel=${2:-}
    shift
    ;;
  --channel=*) channel=${1#*=} ;;
  --omarchy-ref)
    omarchy_ref=${2:-}
    shift
    ;;
  --omarchy-ref=*) omarchy_ref=${1#*=} ;;
  --iso-ref)
    omarchy_iso_ref=${2:-}
    shift
    ;;
  --iso-ref=*) omarchy_iso_ref=${1#*=} ;;
  --body)
    body_out=${2:-}
    shift
    ;;
  --body=*) body_out=${1#*=} ;;
  --no-fetch) no_fetch=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "Error: unknown argument: $1" >&2
    usage >&2
    exit 1
    ;;
  esac
  shift
done

case $channel in
tags | edge) ;;
*)
  echo "Error: --channel must be 'tags' or 'edge', not '$channel'." >&2
  exit 1
  ;;
esac

for tool in git patch tar; do
  command -v "$tool" >/dev/null || {
    echo "Error: $tool is not installed." >&2
    exit 1
  }
done

say() { printf '› %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# The work clones
#
# upstream/ is gitignored: these are ordinary read-only clones, not submodules,
# and pkgs/build.sh and iso/build.sh bind mount them. When a future commit
# turns them into real submodules this still works -- `git submodule update`
# leaves the same clone at the same path -- so the only thing that changes is
# who created the directory.
# ---------------------------------------------------------------------------

ensure_clone() {
  local path=$1 remote=$2
  if [[ -d $path/.git ]]; then
    ((no_fetch)) || git -C "$path" fetch --quiet --tags --force origin
    return
  fi
  if ((no_fetch)); then
    echo "Error: $path is not a clone and --no-fetch was given." >&2
    exit 1
  fi
  say "cloning $remote into ${path#"$repo_root/"}"
  git clone --quiet "https://github.com/$remote.git" "$path"
}

ensure_clone "$repo_root/upstream/omarchy" "$omarchy_repo"
ensure_clone "$repo_root/upstream/omarchy-iso" "$omarchy_iso_repo"

# ---------------------------------------------------------------------------
# Where upstream is now
#
# `tags` means the latest RELEASE tag, which is the stable channel the profile
# follows. omarchy-iso publishes no tags at all, so for that repository the
# tags channel degrades to the default branch and says so rather than
# pretending there is a release to follow.
# ---------------------------------------------------------------------------

gh_api() {
  command -v gh >/dev/null || {
    echo "Error: gh is not installed; pass --omarchy-ref/--iso-ref instead." >&2
    exit 1
  }
  gh api "$@"
}

default_branch() { gh_api "repos/$1" --jq .default_branch; }

# The newest release tag, or empty when the repository publishes none. The
# releases endpoint is the authority (a tag is not a release); the tag list is
# the fallback for a repository that tags without releasing.
#
# `|| tag=` rather than `|| true`: on a 404 gh prints the error BODY on stdout
# and only then exits non-zero, so the substitution has to be thrown away
# explicitly or the JSON becomes the "tag".
latest_tag() {
  local repo=$1 tag
  tag=$(gh_api "repos/$repo/releases/latest" --jq .tag_name 2>/dev/null) || tag=
  if [[ -z $tag || $tag == null ]]; then
    tag=$(gh_api "repos/$repo/tags?per_page=1" --jq '.[0].name' 2>/dev/null) || tag=
  fi
  [[ $tag == null ]] && tag=
  printf '%s' "$tag"
}

# Resolve a ref to a commit inside the work clone, so an annotated tag is
# dereferenced by git rather than by two more API calls.
#
# `origin/<ref>` FIRST, and only then the bare ref: a work clone that was left
# on `quattro` months ago still has a local branch of that name pointing at the
# commit it was left at, and resolving the branch locally would report upstream
# as unchanged when it has moved. A tag has no origin/ counterpart and falls
# through to the second form.
resolve_commit() {
  local path=$1 ref=$2
  git -C "$path" rev-parse --verify --quiet "origin/${ref}^{commit}" ||
    git -C "$path" rev-parse --verify "${ref}^{commit}"
}

# Fills: <name>_ref, <name>_commit, <name>_channel (tags|branch)
resolve_target() {
  local name=$1 path=$2 repo=$3 forced=$4
  local ref= kind=$channel

  if [[ -n $forced ]]; then
    ref=$forced
    kind=explicit
  elif [[ $channel == tags ]]; then
    ref=$(latest_tag "$repo")
    if [[ -z $ref ]]; then
      warn "$repo publishes no tags; following its default branch instead"
      ref=$(default_branch "$repo")
      kind=branch
    fi
  else
    ref=$(default_branch "$repo")
    kind=branch
  fi

  local commit
  commit=$(resolve_commit "$path" "$ref")
  printf -v "${name}_ref" '%s' "$ref"
  printf -v "${name}_commit" '%s' "$commit"
  printf -v "${name}_channel" '%s' "$kind"
}

resolve_target new_omarchy "$repo_root/upstream/omarchy" "$omarchy_repo" "$omarchy_ref"
resolve_target new_iso "$repo_root/upstream/omarchy-iso" "$omarchy_iso_repo" "$omarchy_iso_ref"

# ---------------------------------------------------------------------------
# Where this repository is pinned
#
# upstream/PIN when it exists. Before it exists (or when a clone was moved by
# hand) the fallback is the PKGBUILD's `_commit` for omarchy and the work
# clone's HEAD for omarchy-iso, which is exactly what the repository used to
# mean by "the pin".
# ---------------------------------------------------------------------------

pin_field() {
  [[ -f $pin_file ]] || return 0
  awk -F'=' -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$pin_file"
}

old_omarchy_ref=$(pin_field omarchy_ref)
old_omarchy_commit=$(pin_field omarchy_commit)
old_iso_ref=$(pin_field omarchy_iso_ref)
old_iso_commit=$(pin_field omarchy_iso_commit)

if [[ -z $old_omarchy_commit ]]; then
  pkgs_repo=${OMARCHY_PKGS_DIR:-$repo_root/../omarchy-server-pkgs}
  pkgbuild="$pkgs_repo/pkgbuilds/omarchy-server/PKGBUILD"
  if [[ -f $pkgbuild ]]; then
    old_omarchy_commit=$(sed -n 's/^_commit=\([0-9a-f]\{7,\}\).*/\1/p' "$pkgbuild" | head -1)
    old_omarchy_ref=${old_omarchy_ref:-"PKGBUILD _commit"}
  fi
fi
if [[ -z $old_omarchy_commit ]]; then
  old_omarchy_commit=$(git -C "$repo_root/upstream/omarchy" rev-parse HEAD)
  old_omarchy_ref=${old_omarchy_ref:-"upstream/omarchy HEAD"}
fi
if [[ -z $old_iso_commit ]]; then
  old_iso_commit=$(git -C "$repo_root/upstream/omarchy-iso" rev-parse HEAD)
  old_iso_ref=${old_iso_ref:-"upstream/omarchy-iso HEAD"}
fi

omarchy_moved=0
iso_moved=0
[[ $old_omarchy_commit == "$new_omarchy_commit" ]] || omarchy_moved=1
[[ $old_iso_commit == "$new_iso_commit" ]] || iso_moved=1

verdict() { ((${1})) && echo '[moved]' || echo '[unchanged]'; }

echo
say "channel: $channel"
printf '  omarchy      %s (%s)  ->  %s (%s)  %s\n' \
  "${old_omarchy_commit:0:12}" "${old_omarchy_ref:-?}" \
  "${new_omarchy_commit:0:12}" "$new_omarchy_ref" "$(verdict "$omarchy_moved")"
printf '  omarchy-iso  %s (%s)  ->  %s (%s)  %s\n' \
  "${old_iso_commit:0:12}" "${old_iso_ref:-?}" \
  "${new_iso_commit:0:12}" "$new_iso_ref" "$(verdict "$iso_moved")"
echo

# A GitHub Actions job reads the decision from here rather than from the log.
emit() {
  [[ -n ${GITHUB_OUTPUT:-} ]] || return 0
  printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
}

emit channel "$channel"
emit omarchy_ref "$new_omarchy_ref"
emit omarchy_commit "$new_omarchy_commit"
emit omarchy_iso_ref "$new_iso_ref"
emit omarchy_iso_commit "$new_iso_commit"
emit old_omarchy_commit "$old_omarchy_commit"
emit old_omarchy_iso_commit "$old_iso_commit"
# The branch the workflow puts the bump on. A release tag names it on its own;
# a branch tip does not, so the short commit is appended or every edge run
# would reuse one branch.
branch_name="upstream-bump-${new_omarchy_ref//[^A-Za-z0-9._-]/-}"
[[ $new_omarchy_channel == tags ]] || branch_name+="-${new_omarchy_commit:0:7}"
emit branch "$branch_name"

if ((!omarchy_moved && !iso_moved)); then
  say "no change: upstream has not moved since the current pin"
  emit changed false
  emit conflicts ""
  exit 0
fi
emit changed true

# ---------------------------------------------------------------------------
# Does the patch series still apply?
# ---------------------------------------------------------------------------

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Export a commit into a fresh tree. `git archive` gives the tree and nothing
# else: no .git, no index, no chance of leaving the work clone dirty.
export_tree() {
  local path=$1 commit=$2 dest=$3
  install -d "$dest"
  git -C "$path" archive --format=tar "$commit" | tar -x -C "$dest"
}

# Per-patch result lines, for the report: "<series> <patch> ok|conflict".
patch_results=()
conflicting=()

apply_series() {
  local label=$1 series_dir=$2 tree=$3
  [[ -d $series_dir ]] || return 0
  local patch name
  for patch in "$series_dir"/*.patch; do
    [[ -e $patch ]] || continue
    name=${patch##*/}
    # Dry run first: `patch --forward` on a real apply would leave .rej files
    # and a half-patched tree behind, and the report wants the verdict before
    # the damage.
    if patch -p1 --forward --dry-run -d "$tree" <"$patch" >/dev/null 2>&1; then
      patch -p1 --forward -d "$tree" <"$patch" >/dev/null
      patch_results+=("$label|$name|ok")
      printf '  ok        %s/%s\n' "$label" "$name"
    else
      patch_results+=("$label|$name|conflict")
      conflicting+=("$label/$name")
      printf '  CONFLICT  %s/%s\n' "$label" "$name"
    fi
  done
}

say "applying the patch series onto a fresh export of the new upstream tree"
export_tree "$repo_root/upstream/omarchy" "$new_omarchy_commit" "$work/omarchy"
apply_series omarchy "$repo_root/profile/server/overlay/patches" "$work/omarchy"
export_tree "$repo_root/upstream/omarchy-iso" "$new_iso_commit" "$work/omarchy-iso"
apply_series omarchy-iso "$repo_root/iso/patches" "$work/omarchy-iso"
echo

emit conflicts "${conflicting[*]-}"

# ---------------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------------

# The commit subjects between the old pin and the new one. Upstream tags its
# releases off a different branch than the one the pin has been following, so
# "old..new" is not always a fast-forward: when the two have diverged, listing
# `old..new` would dump the whole history. Say so and show the tip instead.
changelog_limit=60
changelog() {
  # Declared before they are used: `local a=$1 b=$a` creates every name as
  # unset first and then assigns, which under `set -u` makes $a an error.
  local path=$1 old=$2 new=$3
  local range="$old..$new" note=
  if ! git -C "$path" cat-file -e "${old}^{commit}" 2>/dev/null; then
    echo "_(the previous commit \`$old\` is not in this clone; showing the tip)_"
    echo
    range="$new"
  elif [[ $old == "$new" ]]; then
    echo "_(unchanged)_"
    return 0
  elif ! git -C "$path" merge-base --is-ancestor "$old" "$new" 2>/dev/null; then
    note="the two commits have diverged (the pin was not on this tag's branch), so this is the new tip, not a difference"
    range="$new"
  fi

  local -a lines=()
  mapfile -t lines < <(
    git -C "$path" log --no-merges --pretty='- `%h` %s' \
      "-n$((changelog_limit + 1))" "$range" 2>/dev/null || true
  )
  if ((${#lines[@]} == 0)); then
    echo "_(no commits in the range)_"
    return 0
  fi
  [[ -n $note ]] && { printf '_(%s)_\n\n' "$note"; }
  local shown=${#lines[@]} truncated=0
  if ((shown > changelog_limit)); then
    shown=$changelog_limit
    truncated=1
  fi
  printf '%s\n' "${lines[@]:0:shown}"
  ((truncated)) && printf '\n_(more than %d commits; the rest are not listed)_\n' "$changelog_limit"
  return 0
}

write_body() {
  local out=$1
  {
    echo "Upstream moved, so the pin moves with it. Prepared by"
    echo "\`tools/upstream-bump.sh --channel $channel\`; nothing here is merged"
    echo "automatically."
    echo
    echo "| | pinned | now | channel |"
    echo "|---|---|---|---|"
    printf '| `%s` | `%s` | **%s** `%s` | %s |\n' \
      "$omarchy_repo" "${old_omarchy_commit:0:12}" "$new_omarchy_ref" \
      "${new_omarchy_commit:0:12}" "$new_omarchy_channel"
    printf '| `%s` | `%s` | **%s** `%s` | %s |\n' \
      "$omarchy_iso_repo" "${old_iso_commit:0:12}" "$new_iso_ref" \
      "${new_iso_commit:0:12}" "$new_iso_channel"
    echo
    echo "## Patch series"
    echo
    if ((${#patch_results[@]} == 0)); then
      echo "_(no patches found)_"
    else
      echo "| series | patch | result |"
      echo "|---|---|---|"
      local line
      for line in "${patch_results[@]}"; do
        IFS='|' read -r series name result <<<"$line"
        if [[ $result == ok ]]; then
          printf '| %s | `%s` | applies |\n' "$series" "$name"
        else
          printf '| %s | `%s` | **CONFLICT** |\n' "$series" "$name"
        fi
      done
    fi
    if ((${#conflicting[@]})); then
      echo
      echo "> **This branch needs a rebase.** ${#conflicting[@]} patch(es) no"
      echo "> longer apply. \`docs/maintenance.md\` has the runbook."
    fi
    echo
    echo "## Upstream changelog"
    echo
    echo "### $omarchy_repo \`${old_omarchy_commit:0:12}..${new_omarchy_commit:0:12}\`"
    echo
    changelog "$repo_root/upstream/omarchy" "$old_omarchy_commit" "$new_omarchy_commit"
    echo
    echo "### $omarchy_iso_repo \`${old_iso_commit:0:12}..${new_iso_commit:0:12}\`"
    echo
    changelog "$repo_root/upstream/omarchy-iso" "$old_iso_commit" "$new_iso_commit"
    echo
    echo "## Checklist for the human"
    echo
    echo "- [ ] rebase any conflicting patch (\`docs/maintenance.md\`)"
    printf -- "- [ ] \`omarchy-server-pkgs\`: set \`_commit=%s\` in \`pkgbuilds/omarchy-server/PKGBUILD\` and bump \`pkgrel\`\n" "$new_omarchy_commit"
    echo "- [ ] mirror \`$mirror_repo\` carries \`$new_omarchy_ref\`"
    echo "- [ ] \`./bin/serverlab pkgs build && ./bin/serverlab pkgs test\`"
    echo "- [ ] \`./bin/serverlab iso build\`"
    echo "- [ ] VM acceptance on a KVM host (\`./bin/serverlab lab up srv\`, \`lab test srv\`)"
    echo "- [ ] merge here, then let \`publish.yml\` in \`omarchy-server-pkgs\` republish"
  } >"$out"
}

if [[ -n $body_out ]]; then
  write_body "$body_out"
  say "report written to $body_out"
fi

# ---------------------------------------------------------------------------
# make test
# ---------------------------------------------------------------------------

if command -v go >/dev/null; then
  say "make test"
  make -C "$repo_root" test
else
  warn "go is not installed; skipping \`make test\`"
fi

# ---------------------------------------------------------------------------
# Write the pin
# ---------------------------------------------------------------------------

if ((dry_run)); then
  say "dry run: upstream/PIN and the work clones are left alone"
else
  install -d "$repo_root/upstream"
  cat >"$pin_file" <<EOF
# The upstream trees this repository is derived from. Written by
# tools/upstream-bump.sh; the PKGBUILD's _commit in omarchy-server-pkgs must
# name the same omarchy commit.
channel=$channel
omarchy_repo=$omarchy_repo
omarchy_ref=$new_omarchy_ref
omarchy_commit=$new_omarchy_commit
omarchy_iso_repo=$omarchy_iso_repo
omarchy_iso_ref=$new_iso_ref
omarchy_iso_commit=$new_iso_commit
updated=$(date -u +%Y-%m-%d)
EOF
  say "wrote ${pin_file#"$repo_root/"}"

  # Move the work clones onto the new commits so the local build scripts, which
  # bind mount them, build what the pin now names.
  git -C "$repo_root/upstream/omarchy" checkout --quiet --detach "$new_omarchy_commit"
  git -C "$repo_root/upstream/omarchy-iso" checkout --quiet --detach "$new_iso_commit"
  say "upstream/omarchy and upstream/omarchy-iso moved onto the new commits"
fi

if ((${#conflicting[@]})); then
  echo
  warn "${#conflicting[@]} patch(es) no longer apply: ${conflicting[*]}"
  warn "see docs/maintenance.md for the rebase runbook"
  exit 3
fi

say "upstream moved and the whole patch series still applies"
