#!/bin/bash

# Build omarchy-server-keyring, omarchy-server-settings and omarchy-server in a
# throwaway archlinux:latest container, then assemble a signed pacman repo in
# pkgs/repo/.
#
#   ./pkgs/build.sh              build everything
#   ./pkgs/build.sh omarchy-server   build one package
#
# Outputs (all gitignored):
#   pkgs/out/    the .pkg.tar.zst files and their .sig
#   pkgs/repo/   omarchy-server.db{,.tar.gz} + .files + the packages
#
# The build runs as an unprivileged `builder` user, the way the future GitHub
# Actions workflow will (a signed remote repository is a later step). The upstream checkout is bind
# mounted read-only at /src/omarchy and consumed through a pinned
# `git+file://` source, so the build never depends on the working tree's state.
# With a GitHub fork that URL becomes the fork and this mount goes away.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
pkgs_dir="$repo_root/pkgs"
image=${OMARCHY_BUILD_IMAGE:-archlinux:latest}
packages=("$@")

if ((${#packages[@]} == 0)); then
  packages=(omarchy-server-keyring omarchy-server-settings omarchy-server)
fi

if [[ ! -d $repo_root/upstream/omarchy/.git ]]; then
  echo "Error: upstream/omarchy is not a git clone. See README.md." >&2
  exit 1
fi

# The lab signing key. Generated on first run; see pkgs/keys/gen-lab-key.sh.
bash "$pkgs_dir/keys/gen-lab-key.sh"
fingerprint=$(<"$pkgs_dir/keys/fingerprint")

# Ship the server overlay into each PKGBUILD directory as a source tarball, so
# every input to makepkg is a declared source instead of an ambient path.
# `addons/` rides along: the ISO builder reads those package lists to fill the
# offline mirror and the runtime package ships them for omarchy-server-addon,
# and neither should own a second copy.
overlay_tarball_name=omarchy-server-overlay.tar.gz
for package in omarchy-server-settings omarchy-server; do
  tar -czf "$pkgs_dir/pkgbuilds/$package/$overlay_tarball_name" \
    -C "$repo_root/profile/server" overlay addons
done

install -d "$pkgs_dir/out" "$pkgs_dir/repo"

docker run --rm \
  -v "$repo_root/upstream/omarchy:/src/omarchy:ro" \
  -v "$pkgs_dir/pkgbuilds:/build/pkgbuilds:ro" \
  -v "$pkgs_dir/keys:/build/keys:ro" \
  -v "$pkgs_dir/out:/out" \
  -v "$pkgs_dir/repo:/repo" \
  -e "OMARCHY_SIGN_KEY=$fingerprint" \
  -e "OMARCHY_PACKAGES=${packages[*]}" \
  "$image" bash -euo pipefail -c '
    pacman -Syu --noconfirm --needed base-devel git

    useradd -m builder
    echo "builder ALL=(ALL) NOPASSWD: /usr/bin/pacman" >/etc/sudoers.d/builder
    chmod 0440 /etc/sudoers.d/builder

    # git refuses to read a repository owned by another user.
    git config --system --add safe.directory /src/omarchy

    install -d -o builder -g builder /home/builder/work /home/builder/gnupg
    cp -a /build/keys/gnupg/. /home/builder/gnupg/
    chown -R builder:builder /home/builder/gnupg
    chmod 700 /home/builder/gnupg

    for package in $OMARCHY_PACKAGES; do
      echo "=== building $package ==="
      cp -a "/build/pkgbuilds/$package" "/home/builder/work/$package"
      chown -R builder:builder "/home/builder/work/$package"
      su builder -c "
        set -euo pipefail
        export GNUPGHOME=/home/builder/gnupg
        export GPGKEY=$OMARCHY_SIGN_KEY
        cd /home/builder/work/$package
        # --nodeps, not -s: all three packages are arch=any file bundles with
        # no compile step, and their depends() name each other plus five
        # packages that only exist in the [omarchy] repo. Installing ~200 MiB
        # of runtime dependencies would buy the build nothing. The only real
        # makedepend, git, is installed in the image above.
        makepkg --noconfirm --nodeps --sign --key $OMARCHY_SIGN_KEY
      "
      cp -f "/home/builder/work/$package"/*.pkg.tar.zst* /out/
    done

    # Assemble the repository. SigLevel on the client will be
    # `Required DatabaseOptional`, so packages must be signed and the database
    # is signed too for good measure.
    cp -f /out/*.pkg.tar.zst /out/*.pkg.tar.zst.sig /repo/
    export GNUPGHOME=/home/builder/gnupg
    export GPGKEY=$OMARCHY_SIGN_KEY
    repo-add --sign --key "$OMARCHY_SIGN_KEY" \
      /repo/omarchy-server.db.tar.gz /repo/*.pkg.tar.zst

    chown -R '"$(id -u)"':'"$(id -g)"' /out /repo
  '

echo
echo "Packages:"
ls -la "$pkgs_dir/out"
echo
echo "Repo: $pkgs_dir/repo"
