#!/bin/bash

# Generate the LAB GPG key that signs the [omarchy-server] packages and repo db,
# and export what omarchy-server-keyring packages.
#
# LAB ONLY. The key has no passphrase and lives on disk in this directory,
# which is gitignored. It exists to prove the whole signed-repo path
# end to end without waiting on a real key. A production key is generated
# offline, kept off this machine, and only its export is committed. Swapping
# them means re-running the export half of this script with the real key and
# rebuilding omarchy-server-keyring: nothing else refers to the key material.
#
# Idempotent: re-running only re-exports.

set -euo pipefail

keys_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export GNUPGHOME="$keys_dir/gnupg"
key_uid="Omarchy Server Lab <lab@omarchy-server.invalid>"
keyring_dir="$keys_dir/../pkgbuilds/omarchy-server-keyring"

if [[ ! -d $GNUPGHOME ]]; then
  install -d -m 700 "$GNUPGHOME"
fi

if ! gpg --list-secret-keys "$key_uid" >/dev/null 2>&1; then
  echo "Generating lab signing key: $key_uid"
  gpg --batch --yes --quiet --passphrase '' --quick-generate-key "$key_uid" ed25519 sign never
fi

fingerprint=$(gpg --with-colons --list-keys "$key_uid" | awk -F: '$1 == "fpr" { print $10; exit }')
[[ -n $fingerprint ]] || { echo "Error: could not read the key fingerprint" >&2; exit 1; }

gpg --batch --yes --export --output "$keyring_dir/omarchy-server.gpg" "$fingerprint"

# Ownertrust 4 is "full", which is what archlinux-keyring gives its own
# packager keys. pacman-key --populate reads this file to set the trust level
# without any interactive prompt.
echo "$fingerprint:4:" >"$keyring_dir/omarchy-server-trusted"

# No revocations yet. The file must exist: pacman-key --populate reads it.
: >"$keyring_dir/omarchy-server-revoked"

echo "$fingerprint" >"$keys_dir/fingerprint"
echo "Lab key ready: $fingerprint"
echo "Exported to $keyring_dir/{omarchy-server.gpg,omarchy-server-trusted,omarchy-server-revoked}"
