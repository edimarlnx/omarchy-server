#!/bin/bash
# Build a NoCloud seed ISO: the `cidata`-labelled drive cloud-init reads on a
# machine with no metadata service. It is what boots the cloud image on
# libvirt, Proxmox and this lab, and it is what the local validation feeds the
# image so the assertions have something to assert about.
#
# Note the label collision, which is deliberate on both sides: Omarchy's
# autoinstall drive and cloud-init's NoCloud drive are both labelled `cidata`.
# They never meet — the autoinstall drive is read by the ISO's installer, the
# seed by an installed machine's cloud-init — and using the label cloud-init
# documents is what makes this seed work on any cloud-init, not only ours.
#
# Usage: mkseed.sh [--hostname NAME] [--user NAME] [--key PATH] [--out DIR]
#                  [--extra-user NAME:PATH]
# Output: $OUT/seed/{user-data,meta-data} and $OUT/seed.iso
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

hostname=omarchy-cloud-test
username=demo
key=""
out="$here/out"
extra_users=()

while (($#)); do
  case "$1" in
    --hostname) hostname="$2"; shift 2 ;;
    --user) username="$2"; shift 2 ;;
    --key) key="$2"; shift 2 ;;
    --extra-user) extra_users+=("$2"); shift 2 ;;
    --out) out="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

for tool in xorriso ssh-keygen; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

mkdir -p "$out"
dir="$out/seed"
rm -rf "$dir"
mkdir -p "$dir"

# A keypair of the lab's own, so a validation run needs nothing from the
# operator's ~/.ssh. Reused across runs: the seed has to stay stable while the
# image under test changes.
#
# The name is `lab_ed25519` and not `seed_ed25519` on purpose: vm.sh reaches a
# VM with `-i $LAB_OUT/lab_ed25519` and every helper under pocs/ inherits that.
# A seed that writes its key anywhere else produces a machine the harness cannot
# log into, which is a confusing way to learn that cloud-init worked perfectly.
if [[ -z $key ]]; then
  key="$out/lab_ed25519"
  [[ -f $key ]] || ssh-keygen -q -t ed25519 -N "" -C "omarchy-cloud-seed" -f "$key"
fi
[[ -f $key.pub ]] || { echo "no public key at $key.pub" >&2; exit 1; }

# instance-id decides whether cloud-init considers this a first boot. A fixed
# one would make the second boot of a test VM skip every once-per-instance
# module, which is the opposite of what a first-boot test wants to measure, so
# it carries the seed's own build time.
instance_id="omarchy-$(date +%Y%m%d%H%M%S)"

cat >"$dir/meta-data" <<EOF
instance-id: $instance_id
local-hostname: $hostname
EOF

# The user block is written by hand rather than through `ssh_authorized_keys`
# at the top level, because the top-level form attaches the keys to the DEFAULT
# user and the point of this seed is to prove that a named user the metadata
# asked for is the one that gets created.
{
  echo "#cloud-config"
  echo "hostname: $hostname"
  echo "fqdn: $hostname"
  echo "users:"
  printf '  - name: %s\n' "$username"
  echo "    groups: [ wheel ]"
  echo "    sudo: [ \"ALL=(ALL:ALL) NOPASSWD:ALL\" ]"
  echo "    shell: /bin/bash"
  echo "    lock_passwd: true"
  echo "    ssh_authorized_keys:"
  printf '      - %s\n' "$(cat "$key.pub")"
  for entry in "${extra_users[@]}"; do
    name="${entry%%:*}"
    path="${entry#*:}"
    [[ -f $path ]] || { echo "no public key at $path (for user $name)" >&2; exit 1; }
    printf '  - name: %s\n' "$name"
    echo "    groups: [ wheel ]"
    echo "    sudo: [ \"ALL=(ALL:ALL) NOPASSWD:ALL\" ]"
    echo "    shell: /bin/bash"
    echo "    lock_passwd: true"
    echo "    ssh_authorized_keys:"
    printf '      - %s\n' "$(cat "$path")"
  done
} >"$dir/user-data"

xorriso -as mkisofs -quiet -V cidata -J -r -o "$out/seed.iso" "$dir" 2>/dev/null
echo "seed: $out/seed.iso (hostname=$hostname user=$username instance-id=$instance_id)"
echo "key:  $key"
