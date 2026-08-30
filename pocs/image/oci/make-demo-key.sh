#!/bin/bash
# Generate the keypair the demo account `demo` logs in with, and print the block
# that goes into 1Password.
#
#   ./pocs/image/oci/make-demo-key.sh [--host HOST] [--out DIR]
#   ./pocs/image/oci/make-demo-key.sh --fingerprint          # after the launch
#
# The private key is written under pocs/image/out/, which is gitignored. It is
# the one file in this whole pipeline that is a credential, and it exists here
# rather than in someone's ~/.ssh because a demo key is a shared, rotatable,
# disposable thing and mixing it into a personal key store is how it stops
# being any of those.
#
# The host key fingerprint is deliberately a SECOND step. It cannot be known
# before the instance boots -- the image ships no host keys and the machine
# makes its own on its first boot, which is the whole point -- and a 1Password
# entry with a blank fingerprint is worse than one that says where to get it.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

out="$here/../out"
host="demo.tui.tools"
user=demo
fingerprint_only=0

while (($#)); do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --host) host="$2"; shift 2 ;;
    --user) user="$2"; shift 2 ;;
    --fingerprint) fingerprint_only=1; shift ;;
    -h | --help)
      sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$out"
key="$out/demo-${user}_ed25519"

if ((fingerprint_only == 0)); then
  if [[ -f $key ]]; then
    echo "› keypair already exists: $key (delete it to rotate)"
  else
    ssh-keygen -q -t ed25519 -N "" -C "$user@$host" -f "$key"
    chmod 600 "$key"
    echo "› wrote $key and $key.pub"
  fi
fi

# ssh-keyscan reaches the machine only after it is up and the DNS record
# exists; until then the block below says so rather than inventing a value.
host_fingerprint="(not launched yet — re-run with --fingerprint once the instance answers)"
if ((fingerprint_only)) || [[ ${OMARCHY_DEMO_SCAN:-0} == 1 ]]; then
  scanned=$(ssh-keyscan -t ed25519 "$host" 2>/dev/null | ssh-keygen -lf - 2>/dev/null | head -1 || true)
  [[ -n $scanned ]] && host_fingerprint="$scanned"
fi

cat <<BLOCK

──────────────────────── 1Password entry ────────────────────────
Title:        Omarchy Server demo ($host)
Type:         SSH Key / Server

  Host:            $host
  Port:            22
  User:            $user
  Private key:     $key
  Public key:      $(cat "$key.pub" 2>/dev/null || echo "(generate it first)")
  Host key:        $host_fingerprint

  Connect:         ssh -i $key $user@$host

  Notes:
    Key-only. The account has no password and sshd refuses password
    authentication. Sudo is passwordless inside the demo box.
    The machine is disposable: pocs/image/oci/reset.md is how it goes
    back to the state it was launched in.
─────────────────────────────────────────────────────────────────

BLOCK

if ((fingerprint_only == 0)); then
  echo "Next:"
  echo "  1. ./import.sh --compartment-id ... --bucket ... --yes"
  echo "  2. ./launch-demo.sh --compartment-id ... --image-id ... --subnet-id ... \\"
  echo "         --demo-key $key.pub --owner-key ~/.ssh/id_ed25519.pub --yes"
  echo "  3. dns.md, then re-run this with --fingerprint"
fi
