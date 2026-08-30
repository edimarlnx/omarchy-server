#!/bin/bash

# Build an Omarchy ISO for a given profile from our local sources.
#
#   ./iso/build.sh                    # profile: server (the default here)
#   ./iso/build.sh --profile desktop  # stock ISO, the desktop-parity baseline
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
# Steps 4 and 5's --local-source are skipped for --profile desktop: that
# profile's packages are upstream's own, built from a PKGBUILD repository that
# is not public, so a desktop build takes them off the published [omarchy]
# mirror. What it does exercise is every patch in iso/patches/, which is the
# point of building it at all (docs/iso-server.md, "Desktop parity").
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
#
# Desktop is the exception: its Omarchy packages are omarchy/omarchy-settings/
# omarchy-nvim, whose PKGBUILDs live in a private upstream repository nobody
# here has. A desktop build therefore takes them from the published [omarchy]
# mirror, exactly as a stock `omarchy-iso-make` does, and skips --local-source
# entirely. That is also what makes it a usable parity baseline: the only
# difference from an upstream ISO is this repository's patches.
if [[ $profile == "desktop" ]]; then
  echo "› desktop profile: building against the published [omarchy] mirror"
else
  echo "› assembling $pkgs_scratch"
  # The PKGBUILDs live in the omarchy-server-pkgs checkout beside this one, which
  # is also what GitHub Actions builds the signed [omarchy-server] repository
  # from. OMARCHY_PKGS_DIR moves it.
  pkgs_repo=${OMARCHY_PKGS_DIR:-$repo_root/../omarchy-server-pkgs}
  if [[ ! -d $pkgs_repo/pkgbuilds ]]; then
    echo "Error: $pkgs_repo/pkgbuilds not found (set OMARCHY_PKGS_DIR)." >&2
    echo "       git clone https://github.com/edimarlnx/omarchy-server-pkgs.git ../omarchy-server-pkgs" >&2
    exit 1
  fi
  bash "$repo_root/pkgs/keys/gen-lab-key.sh"

  rm -rf "$pkgs_scratch"
  mkdir -p "$pkgs_scratch/profile"
  cp -a "$pkgs_repo/pkgbuilds" "$pkgs_scratch/pkgbuilds"
  cp -a "$repo_root/profile/$profile" "$pkgs_scratch/profile/$profile" 2>/dev/null ||
    { [[ $profile == desktop ]] || { echo "Error: no profile/$profile in this repo." >&2; exit 1; }; }

  # Prebuilt packages the ISO builder copies straight into the offline mirror
  # (iso/patches/0011). This is where the SELinux set arrives: ~20 packages,
  # one of them systemd, built once by the packages repository's
  # scripts/build-selinux.sh instead of inside every ISO build.
  #
  # Missing is not an error. It means the `selinux` addon will not be
  # installable from this ISO's offline mirror, which is the right outcome for
  # somebody who has not built that set -- and the addon says so when it cannot
  # find its packages.
  selinux_out="$pkgs_repo/out/selinux"
  if compgen -G "$selinux_out/*.pkg.tar.zst" >/dev/null; then
    echo "› bundling $(ls "$selinux_out"/*.pkg.tar.zst | wc -l) prebuilt SELinux packages"
    mkdir -p "$pkgs_scratch/prebuilt"
    cp -f "$selinux_out"/*.pkg.tar.zst "$pkgs_scratch/prebuilt/"
  else
    echo "› no prebuilt SELinux packages in $selinux_out; the selinux addon will not be bundled"
    echo "  build them with: (cd $pkgs_repo && ./scripts/build-selinux.sh)"
  fi

  # Same overlay tarball pkgs/build.sh ships as a declared makepkg source.
  for package in omarchy-server-settings omarchy-server; do
    tar -czf "$pkgs_scratch/pkgbuilds/$package/omarchy-server-overlay.tar.gz" \
      -C "$repo_root/profile/server" overlay addons branding
  done

  # ── the tui-tools packages ────────────────────────────────────────────────
  # The `tui-tools` addon's packages are downloaded from the repository the
  # tools publish themselves and dropped into <pkgs-checkout>/prebuilt/, the
  # same door the SELinux set comes through. They used to be BUILT here, from
  # two local checkouts, and served out of [omarchy-server]; rebuilding
  # somebody else's releases to hand them to a user is a maintenance debt with
  # no upside, and it also meant the ISO carried a version nobody could
  # reproduce from a signed source.
  #
  # Every file is verified against the repository's signing key -- pinned by
  # fingerprint below, and the same key the addon's preflight imports into
  # pacman on the installed machine -- BEFORE it is copied anywhere. The
  # offline mirror itself is unsigned (see iso/patches/0011), so this download
  # is the only place the signature can be checked at all, which is why a
  # failure here is fatal rather than a warning.
  tui_tools_repo=${TUI_TOOLS_REPO_URL:-https://pkgs.tui.tools/arch/x86_64}
  tui_tools_key="$repo_root/profile/server/overlay/runtime/install/server/addons/tui-tools.pubkey.asc"
  tui_tools_fingerprint=767CFB337B01F32FFC073F3F389120B277E4FB44
  tui_tools_cache="$iso_dir/scratch/tui-tools"
  mkdir -p "$tui_tools_cache" "$pkgs_scratch/prebuilt"

  # A throwaway keyring holding exactly one key: the verification says "signed
  # by this key", not "signed by something in the operator's keyring".
  tui_tools_gnupg=$(mktemp -d)
  chmod 700 "$tui_tools_gnupg"
  gpg --quiet --homedir "$tui_tools_gnupg" --import "$tui_tools_key"
  gpg --quiet --homedir "$tui_tools_gnupg" --list-keys --with-colons |
    awk -F: '$1 == "fpr" { print $10 }' | grep -qx "$tui_tools_fingerprint" || {
    echo "Error: $tui_tools_key is not key $tui_tools_fingerprint." >&2
    exit 1
  }

  tui_tools_fetch() { # <filename>
    if [[ ! -f $tui_tools_cache/$1 ]]; then
      curl -fsSL --retry 3 -o "$tui_tools_cache/$1.part" "$tui_tools_repo/$1" || return 1
      mv -f "$tui_tools_cache/$1.part" "$tui_tools_cache/$1"
    fi
  }
  tui_tools_verify() { # <filename>, with its detached signature beside it
    gpg --quiet --homedir "$tui_tools_gnupg" --trust-model always \
      --verify "$tui_tools_cache/$1.sig" "$tui_tools_cache/$1" 2>/dev/null
  }

  echo "› fetching the tui-tools packages from $tui_tools_repo"
  # The database is refreshed on every build: a cached one would pin the ISO to
  # whatever the repository held the first time this ran. The packages
  # themselves are content-addressed by version in their filename, so those are
  # cached across builds.
  rm -f "$tui_tools_cache/tui-tools.db" "$tui_tools_cache/tui-tools.db.sig"
  tui_tools_fetch tui-tools.db && tui_tools_fetch tui-tools.db.sig || {
    echo "Error: cannot download the tui-tools database from $tui_tools_repo." >&2
    exit 1
  }
  tui_tools_verify tui-tools.db || {
    echo "Error: the tui-tools database is not signed by $tui_tools_fingerprint." >&2
    exit 1
  }

  # %FILENAME% per package name, out of the signed database, so the file a
  # package name resolves to is the one the repository says it is.
  # bsdtar is what Arch has; a build host may only have GNU tar, which needs to
  # be told to expand the pattern and can read zstd through its own -I hook.
  tui_tools_filename() { # <package name>
    if command -v bsdtar >/dev/null; then
      bsdtar -xOf "$tui_tools_cache/tui-tools.db" "$1-*/desc" 2>/dev/null
    else
      tar --zstd -xOf "$tui_tools_cache/tui-tools.db" --wildcards "$1-*/desc" 2>/dev/null
    fi | awk '/^%FILENAME%$/ { getline; print; exit }'
  }

  while read -r tool; do
    file=$(tui_tools_filename "$tool")
    [[ -n $file ]] || {
      echo "Error: $tool is not in the tui-tools repository database." >&2
      exit 1
    }
    tui_tools_fetch "$file" && tui_tools_fetch "$file.sig" || {
      echo "Error: cannot download $tui_tools_repo/$file." >&2
      exit 1
    }
    tui_tools_verify "$file" || {
      echo "Error: $file is not signed by $tui_tools_fingerprint." >&2
      exit 1
    }
    # The signature stays behind: the offline mirror is unsigned, and a .sig
    # from a key the live environment does not trust is worse than none.
    cp -f "$tui_tools_cache/$file" "$pkgs_scratch/prebuilt/"
    echo "  ✓ $file"
  done < <(grep -hv '^#\|^$' "$repo_root/profile/server/addons/tui-tools.packages")

  rm -rf "$tui_tools_gnupg"
fi

# ── 5. build ────────────────────────────────────────────────────────────────
make_args=(--profile "$profile" --keep-pkg-cache --no-boot-offer)
((debug)) && make_args+=(--debug)
if [[ $profile != "desktop" ]]; then
  make_args+=(--local-source "$upstream_omarchy" "$pkgs_scratch")
fi
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
