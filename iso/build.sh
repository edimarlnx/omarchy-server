#!/bin/bash

# Build an Omarchy ISO for a given profile from our local sources.
#
#   ./iso/build.sh                    # profile: server (the default here)
#   ./iso/build.sh --profile desktop  # stock ISO, useful as a diff baseline
#   ./iso/build.sh --fresh            # discard the scratch tree first
#   ./iso/build.sh --debug            # OMARCHY_INSTALL_DEBUG=1 in the ISO
#
# upstream/omarchy-iso and upstream/omarchy are read-only clones and are never
# modified. This script instead:
#
#   1. copies upstream/omarchy-iso into iso/scratch/omarchy-iso (gitignored),
#      resetting it to its pinned HEAD on every run;
#   2. lays iso/overlay/ over that copy (whole files);
#   3. applies iso/patches/*.patch on top (changes to upstream files);
#   4. assembles iso/scratch/pkgs/ — our PKGBUILDs plus profile/<name>/ — as
#      the <pkgs-checkout> argument of --local-source;
#   5. runs the copy's own bin/omarchy-iso-make with --profile and
#      --local-source, so the builder container builds omarchy-server* from
#      upstream/omarchy + our overlay and puts them in the ISO's offline
#      mirror.
#
# The built ISO lands in iso/release/ (gitignored).
#
# What each patch does: docs/iso-server.md.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
iso_dir="$repo_root/iso"
upstream_iso="$repo_root/upstream/omarchy-iso"
upstream_omarchy="$repo_root/upstream/omarchy"
scratch="$iso_dir/scratch/omarchy-iso"
pkgs_scratch="$iso_dir/scratch/pkgs"
release="$iso_dir/release"

profile=server
fresh=0
debug=0
extra_args=()

while (($#)); do
  case "$1" in
    --profile) profile="$2"; shift 2 ;;
    --fresh) fresh=1; shift ;;
    --debug) debug=1; shift ;;
    --) shift; extra_args+=("$@"); break ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

for path in "$upstream_iso/.git" "$upstream_omarchy/.git"; do
  [[ -d $path ]] || { echo "Error: ${path%/.git} is not a git clone. See README.md." >&2; exit 1; }
done
command -v docker >/dev/null || { echo "Error: docker is required." >&2; exit 1; }

# ── 1. scratch copy of the ISO repo ─────────────────────────────────────────
# The copy keeps its .git so the upstream build script can run its
# file-permission lint (git ls-files --stage) and initialize the archiso
# submodule. Resetting to HEAD makes every build start from pristine upstream,
# so a patch that no longer applies fails loudly instead of stacking.
if ((fresh)); then
  rm -rf "$scratch"
fi

if [[ ! -d $scratch/.git ]]; then
  echo "› copying upstream/omarchy-iso into $scratch"
  mkdir -p "$scratch"
  rsync -a --exclude 'release/' "$upstream_iso/" "$scratch/"
else
  echo "› resetting $scratch to upstream HEAD"
  git -C "$scratch" reset --hard -q
  # -e archiso: the submodule checkout is expensive and unchanged by us.
  git -C "$scratch" clean -fdq -e archiso -e release
fi

echo "› upstream/omarchy-iso at $(git -C "$scratch" rev-parse --short HEAD)"
git -C "$scratch" submodule update --init --recursive --jobs=8 >/dev/null

# ── 2. overlay ──────────────────────────────────────────────────────────────
if [[ -d $iso_dir/overlay ]] && [[ -n $(ls -A "$iso_dir/overlay" 2>/dev/null) ]]; then
  echo "› applying overlay"
  rsync -a "$iso_dir/overlay/" "$scratch/"
fi

# ── 3. patches ──────────────────────────────────────────────────────────────
shopt -s nullglob
for patch in "$iso_dir"/patches/*.patch; do
  echo "› applying ${patch##*/}"
  git -C "$scratch" apply --whitespace=nowarn "$patch"
done
shopt -u nullglob

# The lint in bin/omarchy-iso-make reads file modes out of the git index, so
# anything the overlay added has to be staged before it runs.
git -C "$scratch" add -A

# ── 4. the <pkgs-checkout> for --local-source ───────────────────────────────
# builder/build-omarchy-packages.sh reads /omarchy-pkgs/pkgbuilds/<pkg>, and
# our patched builder/build-iso.sh reads /omarchy-pkgs/profile/<name>/.
echo "› assembling $pkgs_scratch"
bash "$repo_root/pkgs/keys/gen-lab-key.sh"

rm -rf "$pkgs_scratch"
mkdir -p "$pkgs_scratch/profile"
cp -a "$repo_root/pkgs/pkgbuilds" "$pkgs_scratch/pkgbuilds"
cp -a "$repo_root/profile/$profile" "$pkgs_scratch/profile/$profile" 2>/dev/null ||
  { [[ $profile == desktop ]] || { echo "Error: no profile/$profile in this repo." >&2; exit 1; }; }

# Same overlay tarball pkgs/build.sh ships as a declared makepkg source.
for package in omarchy-server-settings omarchy-server; do
  tar -czf "$pkgs_scratch/pkgbuilds/$package/omarchy-server-overlay.tar.gz" \
    -C "$repo_root/profile/server" overlay addons branding
done

# Addon packages built from their own upstream get a clone under
# <pkgs-checkout>/src/, which the patched builder/build-omarchy-packages.sh
# marks safe for git and hands to the PKGBUILD through <NAME>_SRC. A clone
# rather than a copy: the working tree's uncommitted state must not decide what
# a package contains, and the PKGBUILDs consume a pinned commit anyway.
tui_tools_dir=${TUI_TOOLS_DIR:-$repo_root/../tui-tools}
if [[ -d $tui_tools_dir/.git ]]; then
  echo "› cloning $tui_tools_dir into $pkgs_scratch/src/tui-tools"
  mkdir -p "$pkgs_scratch/src"
  git clone --quiet --no-hardlinks "$tui_tools_dir" "$pkgs_scratch/src/tui-tools"
else
  echo "Error: $tui_tools_dir is not a git clone; the fwall addon needs it." >&2
  echo "       Set TUI_TOOLS_DIR to the checkout." >&2
  exit 1
fi

# ── 5. build ────────────────────────────────────────────────────────────────
make_args=(--profile "$profile" --keep-pkg-cache --no-boot-offer)
((debug)) && make_args+=(--debug)
make_args+=(--local-source "$upstream_omarchy" "$pkgs_scratch")
((${#extra_args[@]})) && make_args+=("${extra_args[@]}")

mkdir -p "$release"
started=$(date +%s)
echo "› bin/omarchy-iso-make ${make_args[*]}"
(cd "$scratch" && ./bin/omarchy-iso-make "${make_args[@]}")
elapsed=$(($(date +%s) - started))

built=$(ls -t "$scratch"/release/*.iso | head -n1)
mv -f "$built" "$release/"
final="$release/${built##*/}"
sha256sum "$final" >"$final.sha256"

echo
echo "ISO:   $final"
echo "Size:  $(du -h "$final" | cut -f1)"
echo "Build: $((elapsed / 60))m$((elapsed % 60))s"
