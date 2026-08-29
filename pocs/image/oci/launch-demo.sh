#!/bin/bash
# Launch the omarchy-server-demo.quave.one instance from an imported custom
# image.
#
#   ./pocs/image/oci/launch-demo.sh --compartment-id OCID --image-id OCID \
#       --subnet-id OCID --demo-key PATH [--owner-key PATH] [--yes]
#
# Without --yes it prints the plan, renders the cloud-init user-data it would
# send, and creates nothing.
#
# What it creates with --yes: one network security group with a single ingress
# rule (22/tcp), and one instance. It does NOT create a VCN, a subnet, an
# internet gateway, a route table or a DNS record -- those are the tenancy's
# shape, they outlive the demo, and dns.md covers the record.
#
# The shape must be x86_64: this image is an x86_64 Arch install with an
# x86_64 UKI, so the Ampere A1 shapes (VM.Standard.A1.Flex) are not an option
# however cheap they are. VM.Standard.E5.Flex at 2 OCPU / 8 GB is the default;
# E4.Flex is the fallback in regions without E5.
#
# Not shielded, and this is a decision rather than an omission: a Shielded
# Instance enforces Secure Boot against Oracle's key set, and this image's
# Secure Boot mode is "keys the machine generates for itself", which needs
# firmware in Setup Mode that OCI does not offer. See docs/cloud-image.md.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

profile="${OCI_CLI_PROFILE:-DEFAULT}"
compartment=""
image_id=""
subnet_id=""
nsg_id=""
demo_key=""
demo_user="demo"
owner_key=""
shape="VM.Standard.E5.Flex"
ocpus=2
memory=8
hostname="omarchy-server-demo"
display=""
availability_domain=""
confirmed=0

usage() {
  cat <<'USAGE'
Usage: launch-demo.sh --compartment-id OCID --image-id OCID --subnet-id OCID
                      --demo-key PATH [flags] [--yes]

  --compartment-id OCID   compartment for the NSG and the instance (required)
  --image-id OCID         the custom image from import.sh (required)
  --subnet-id OCID        an existing PUBLIC subnet (required; not created here)
  --demo-key PATH         public key for the demo account (required)
  --demo-user NAME        name of the demo account (default: demo)
  --owner-key PATH        public key for the `omarchy` owner account (optional)
  --nsg-id OCID           reuse an NSG instead of creating one
  --shape NAME            default: VM.Standard.E5.Flex
  --ocpus N               default: 2
  --memory-gb N           default: 8
  --hostname NAME         default: omarchy-server-demo
  --availability-domain N default: the first one in the compartment
  --profile NAME          OCI CLI profile (default: $OCI_CLI_PROFILE or DEFAULT)
  --yes                   actually do it
USAGE
}

while (($#)); do
  case "$1" in
    --compartment-id) compartment="$2"; shift 2 ;;
    --image-id) image_id="$2"; shift 2 ;;
    --subnet-id) subnet_id="$2"; shift 2 ;;
    --nsg-id) nsg_id="$2"; shift 2 ;;
    --demo-key) demo_key="$2"; shift 2 ;;
    --demo-user) demo_user="$2"; shift 2 ;;
    --owner-key) owner_key="$2"; shift 2 ;;
    --shape) shape="$2"; shift 2 ;;
    --ocpus) ocpus="$2"; shift 2 ;;
    --memory-gb) memory="$2"; shift 2 ;;
    --hostname) hostname="$2"; shift 2 ;;
    --availability-domain) availability_domain="$2"; shift 2 ;;
    --profile) profile="$2"; shift 2 ;;
    --yes) confirmed=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v oci >/dev/null || { echo "the OCI CLI is not installed" >&2; exit 1; }
[[ -n $compartment ]] || { echo "--compartment-id is required" >&2; exit 2; }
[[ -n $image_id ]] || { echo "--image-id is required" >&2; exit 2; }
[[ -n $subnet_id ]] || { echo "--subnet-id is required" >&2; exit 2; }
[[ -n $demo_key ]] || { echo "--demo-key is required (./make-demo-key.sh writes one)" >&2; exit 2; }
[[ -f $demo_key ]] || { echo "no such public key: $demo_key" >&2; exit 1; }
[[ -z $owner_key || -f $owner_key ]] || { echo "no such public key: $owner_key" >&2; exit 1; }

display="${display:-$hostname}"
oci_cli() { oci --profile "$profile" "$@"; }

# ── the user-data ───────────────────────────────────────────────────────────
# Two accounts and no third. `demo` is the demo account the link in 1Password
# hands out; `omarchy` is the owner's, and it is the image's own default user
# name, so a key given here lands on the account the platform would have used
# anyway. Both are key-only and password-locked: the image ships no password
# and nothing here introduces one.
user_data=$(
  echo "#cloud-config"
  echo "hostname: $hostname"
  echo "fqdn: $hostname.quave.one"
  echo "users:"
  echo "  - name: ${demo_user}"
  echo "    gecos: Omarchy Server demo"
  echo "    groups: [ wheel ]"
  echo "    sudo: [ \"ALL=(ALL:ALL) NOPASSWD:ALL\" ]"
  echo "    shell: /bin/bash"
  echo "    lock_passwd: true"
  echo "    ssh_authorized_keys:"
  printf '      - %s\n' "$(cat "$demo_key")"
  if [[ -n $owner_key ]]; then
    echo "  - name: omarchy"
    echo "    gecos: Omarchy Server owner"
    echo "    groups: [ wheel ]"
    echo "    sudo: [ \"ALL=(ALL:ALL) NOPASSWD:ALL\" ]"
    echo "    shell: /bin/bash"
    echo "    lock_passwd: true"
    echo "    ssh_authorized_keys:"
    printf '      - %s\n' "$(cat "$owner_key")"
  fi
)

echo "=== OCI demo instance ==="
echo "profile:       $profile"
echo "display name:  $display"
echo "hostname:      $hostname  (DNS record is dns.md, not this script)"
echo "shape:         $shape  ${ocpus} OCPU / ${memory} GB"
echo "image:         $image_id"
echo "subnet:        $subnet_id"
echo "nsg:           ${nsg_id:-<created here: ingress 22/tcp only>}"
echo "shielded:      no (see the header of this script)"
echo "accounts:      demo${owner_key:+, omarchy}  — key only, no password"
echo
echo "--- cloud-init user-data ---"
echo "$user_data"
echo "---"
echo

if ((confirmed == 0)); then
  cat <<'PLAN'
Plan (nothing has been created):

  1. oci network nsg create             one NSG in the subnet's VCN
  2. oci network nsg rules add          ingress 0.0.0.0/0 -> 22/tcp, and
                                        egress all (an instance that cannot
                                        reach the mirrors cannot update)
  3. oci compute instance launch        with the user-data above
  4. wait for RUNNING, print the public IP and the ssh command

Re-run with --yes to do it.
PLAN
  exit 1
fi

if [[ -z $availability_domain ]]; then
  availability_domain=$(oci_cli iam availability-domain list \
    --compartment-id "$compartment" --query 'data[0].name' --raw-output)
  echo "› availability domain: $availability_domain"
fi

# ── the NSG ─────────────────────────────────────────────────────────────────
if [[ -z $nsg_id ]]; then
  vcn_id=$(oci_cli network subnet get --subnet-id "$subnet_id" --query 'data."vcn-id"' --raw-output)
  echo "› creating a network security group in $vcn_id"
  nsg_id=$(oci_cli network nsg create \
    --compartment-id "$compartment" --vcn-id "$vcn_id" \
    --display-name "$hostname-ssh" \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)

  rules=$(mktemp)
  trap 'rm -f "$rules"' EXIT
  cat >"$rules" <<'JSON'
[
  {
    "direction": "INGRESS",
    "protocol": "6",
    "source": "0.0.0.0/0",
    "sourceType": "CIDR_BLOCK",
    "isStateless": false,
    "description": "ssh, and nothing else. The instance also runs `ufw limit 22/tcp`.",
    "tcpOptions": { "destinationPortRange": { "min": 22, "max": 22 } }
  },
  {
    "direction": "EGRESS",
    "protocol": "all",
    "destination": "0.0.0.0/0",
    "destinationType": "CIDR_BLOCK",
    "isStateless": false,
    "description": "Outbound: pacman mirrors, NTP, DNS."
  }
]
JSON
  oci_cli network nsg rules add --nsg-id "$nsg_id" --security-rules "file://$rules" >/dev/null
  echo "› nsg: $nsg_id"
fi

# ── the instance ────────────────────────────────────────────────────────────
# user_data goes in base64, which is what the metadata field expects; the
# `ssh_authorized_keys` metadata key is deliberately NOT set, because it would
# put the same key on the image's default user behind the explicit `users:`
# block above and make the account list two things at once.
echo "› launching"
instance_id=$(oci_cli compute instance launch \
  --compartment-id "$compartment" \
  --availability-domain "$availability_domain" \
  --display-name "$display" \
  --hostname-label "$hostname" \
  --shape "$shape" \
  --shape-config "{\"ocpus\":$ocpus,\"memoryInGBs\":$memory}" \
  --image-id "$image_id" \
  --subnet-id "$subnet_id" \
  --nsg-ids "[\"$nsg_id\"]" \
  --assign-public-ip true \
  --metadata "{\"user_data\":\"$(printf '%s' "$user_data" | base64 -w0)\"}" \
  --wait-for-state RUNNING --wait-interval-seconds 15 --max-wait-seconds 1800 \
  --query 'data.id' --raw-output)

public_ip=$(oci_cli compute instance list-vnics --instance-id "$instance_id" \
  --query 'data[0]."public-ip"' --raw-output)

echo
echo "instance: $instance_id"
echo "public IP: $public_ip"
echo
echo "The first boot regenerates the ssh host keys and applies the metadata."
echo "Read the fingerprint from the console before trusting it:"
echo "  oci --profile $profile compute instance-console-connection create --instance-id $instance_id ..."
echo
echo "  ssh -i out/demo-guest_ed25519 demo@$public_ip"
echo
echo "Next: dns.md (an A record for $hostname.quave.one -> $public_ip)."
