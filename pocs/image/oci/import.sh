#!/bin/bash
# Import a built Omarchy Server cloud image into OCI as a custom image.
#
#   ./pocs/image/oci/import.sh --compartment-id OCID --bucket NAME [flags] [--yes]
#
# Without --yes it prints the plan and creates nothing. With --yes it:
#
#   1. uploads the qcow2 to an Object Storage bucket you already own
#   2. `oci compute image import from-object` with --source-image-type QCOW2
#      and --launch-mode PARAVIRTUALIZED
#   3. waits for the image to reach AVAILABLE (polling; see the note at the
#      wait loop for why the CLI's --wait-for-state is not an option here)
#   4. attaches an image capability schema declaring UEFI_64 firmware, unless
#      the image already has one
#   5. reads the firmware back from the API and refuses to finish unless it
#      is UEFI_64
#   6. prints the image OCID launch-demo.sh wants
#
# Why those choices, because none of them is obvious:
#
#   QCOW2          OCI's custom-image import accepts QCOW2 and VMDK. QCOW2 is
#                  what qemu-img already produced, it compresses (the VMDK
#                  export would be the same bytes uncompressed) and it is what
#                  every other target in docs/cloud-image.md consumes.
#
#   PARAVIRTUALIZED  The launch mode decides which virtual hardware the instance
#                  is given. EMULATED presents an IDE disk and an E1000 NIC to
#                  an image whose drivers are unknown; PARAVIRTUALIZED presents
#                  virtio-blk and virtio-net, which is exactly what this image
#                  was built and tested on (pocs/lab/vm.sh boots it with
#                  virtio-blk-pci and virtio-net-pci) and what its initramfs
#                  carries. NATIVE is for images built with the OCI paravirt
#                  drivers and their metadata; we do not ship those.
#
#   UEFI_64        The image boots a UKI through Limine on an ESP. There is no
#                  MBR and no BIOS boot path at all, so an instance launched
#                  with the default BIOS firmware would find nothing bootable.
#                  OCI decides an instance's firmware from the IMAGE's
#                  capability schema, and an imported image has none until one
#                  is created for it -- which is what step 4 is, and why an
#                  import that stops at step 3 produces an image that imports
#                  cleanly and never boots.
#
#   NOT SecureBoot This image's Secure Boot mode enrolls keys the MACHINE
#                  generates for itself, which needs firmware in Setup Mode. An
#                  OCI Shielded Instance enforces Secure Boot against Oracle's
#                  own key set and gives the tenant no way to enroll a PK, so a
#                  UKI signed by a machine-local key is a UKI that firmware
#                  refuses. Do not launch this image shielded with Secure Boot
#                  on; docs/cloud-image.md has the long version.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

profile="${OCI_CLI_PROFILE:-DEFAULT}"
compartment=""
bucket=""
image=""
object=""
display=""
namespace=""
confirmed=0

usage() {
  cat <<'USAGE'
Usage: import.sh --compartment-id OCID --bucket NAME [flags] [--yes]

  --compartment-id OCID   compartment to create the image in (required)
  --bucket NAME           an Object Storage bucket you already own (required)
  --image PATH            the qcow2 (default: the newest in pocs/image/out)
  --object NAME           object name in the bucket (default: the file name)
  --display-name NAME     custom image display name (default: the file stem)
  --namespace NS          Object Storage namespace (default: `oci os ns get`)
  --profile NAME          OCI CLI profile (default: $OCI_CLI_PROFILE or DEFAULT)
  --yes                   actually do it

Creates: one object in the bucket, one custom image, one image capability
schema. Creates no VCN, no subnet and no instance.
USAGE
}

while (($#)); do
  case "$1" in
    --compartment-id) compartment="$2"; shift 2 ;;
    --bucket) bucket="$2"; shift 2 ;;
    --image) image="$2"; shift 2 ;;
    --object) object="$2"; shift 2 ;;
    --display-name) display="$2"; shift 2 ;;
    --namespace) namespace="$2"; shift 2 ;;
    --profile) profile="$2"; shift 2 ;;
    --yes) confirmed=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v oci >/dev/null || { echo "the OCI CLI is not installed" >&2; exit 1; }

[[ -n $compartment ]] || { echo "--compartment-id is required" >&2; exit 2; }
[[ -n $bucket ]] || { echo "--bucket is required" >&2; exit 2; }

if [[ -z $image ]]; then
  image=$(ls -t "$here/../out"/*.qcow2 2>/dev/null | head -n1 || true)
  [[ -n $image ]] || { echo "no image in pocs/image/out; run \`serverlab image build\`" >&2; exit 1; }
fi
[[ -f $image ]] || { echo "no such image: $image" >&2; exit 1; }

object="${object:-$(basename "$image")}"
display="${display:-$(basename "$image" .qcow2)}"
size=$(stat -c %s "$image")

oci_cli() { oci --profile "$profile" "$@"; }

# The namespace is a property of the tenancy, not a secret and not something to
# hard-code in a public repository: ask for it.
if [[ -z $namespace ]] && ((confirmed)); then
  namespace=$(oci_cli os ns get --query 'data' --raw-output)
fi

echo "=== OCI custom image import ==="
echo "profile:      $profile"
echo "image:        $image ($(numfmt --to=iec --suffix=B "$size"))"
echo "object:       ${namespace:-<namespace from \`oci os ns get\`>}/$bucket/$object"
echo "display name: $display"
echo "compartment:  $compartment"
echo "launch mode:  PARAVIRTUALIZED"
echo "firmware:     UEFI_64 (via an image capability schema)"
echo "secure boot:  NOT declared — see the header of this script"
echo

if ((confirmed == 0)); then
  cat <<'PLAN'
Plan (nothing has been created):

  1. oci os object put            upload the qcow2 to the bucket
  2. oci compute image import from-object
                                  --source-image-type QCOW2
                                  --launch-mode PARAVIRTUALIZED
  3. wait for the image to be AVAILABLE (up to 30 minutes)
  4. oci compute image-capability-schema create
                                  Compute.Firmware = UEFI_64
                                  Compute.LaunchMode = PARAVIRTUALIZED
                                  (skipped if the image already has a schema)
  5. oci compute image-capability-schema list
                                  verify Compute.Firmware is UEFI_64, or fail
  6. print the image OCID

Re-run with --yes to do it.
PLAN
  exit 1
fi

# ── 1. upload ───────────────────────────────────────────────────────────────
echo "› uploading (this is the slow part)"
oci_cli os object put \
  --namespace "$namespace" \
  --bucket-name "$bucket" \
  --name "$object" \
  --file "$image" \
  --force

# ── 2. import ───────────────────────────────────────────────────────────────
echo "› importing as a custom image"
image_id=$(oci_cli compute image import from-object \
  --compartment-id "$compartment" \
  --namespace "$namespace" \
  --bucket-name "$bucket" \
  --name "$object" \
  --display-name "$display" \
  --source-image-type QCOW2 \
  --launch-mode PARAVIRTUALIZED \
  --operating-system "Omarchy Server" \
  --operating-system-version "$(basename "$image" .qcow2 | sed 's/^omarchy-server-//; s/-x86_64$//')" \
  --query 'data.id' --raw-output)

echo "› image: $image_id"

# `oci compute image get` has NO --wait-for-state: the waiter flags exist on
# some compute commands and not on this one, and passing them makes the CLI
# exit 2 with "no such option" -- which, under `set -e`, killed this script
# right here and skipped step 3 entirely. That is exactly how an image gets
# imported with no capability schema and launches as BIOS. Poll instead.
echo "› waiting for AVAILABLE (an import is minutes, not seconds)"
wait_deadline=$((SECONDS + 1800))
image_state=""
while :; do
  image_state=$(oci_cli compute image get --image-id "$image_id" \
    --query 'data."lifecycle-state"' --raw-output)
  case "$image_state" in
    AVAILABLE) break ;;
    IMPORTING | PROVISIONING) ;;
    *)
      echo "!! the image entered state $image_state; it will never be AVAILABLE" >&2
      exit 1
      ;;
  esac
  if ((SECONDS >= wait_deadline)); then
    echo "!! the image is still $image_state after 30 minutes; giving up" >&2
    echo "   the image exists ($image_id) -- re-run the schema step by hand" >&2
    exit 1
  fi
  sleep 30
done
echo "  state: AVAILABLE"

# ── 3. capability schema ────────────────────────────────────────────────────
# Without this the instance is launched with BIOS firmware and never finds a
# boot sector, because there is not one. The schema VERSION name is a value of
# the tenancy's global schema, so it is discovered rather than hard-coded --
# it is a UUID in some tenancies and a "OCI_x.y.z" string in others.
#
# Idempotent: an image carries at most one capability schema, and a second
# create on the same image is an error, so a re-run of this script (or a run
# that resumes after the wait timed out) must skip a schema that is there.
existing_schema=$(oci_cli compute image-capability-schema list \
  --compartment-id "$compartment" --image-id "$image_id" \
  --query 'data[0].id' --raw-output 2>/dev/null || true)

schema_data=""
write_schema_data() {
  schema_data=$(mktemp)
  trap 'rm -f "$schema_data"' EXIT
  cat >"$schema_data" <<'JSON'
{
  "Compute.Firmware": {
    "descriptorType": "enumstring",
    "source": "IMAGE",
    "defaultValue": "UEFI_64",
    "values": [ "UEFI_64" ]
  },
  "Compute.LaunchMode": {
    "descriptorType": "enumstring",
    "source": "IMAGE",
    "defaultValue": "PARAVIRTUALIZED",
    "values": [ "PARAVIRTUALIZED" ]
  },
  "Storage.BootVolumeType": {
    "descriptorType": "enumstring",
    "source": "IMAGE",
    "defaultValue": "PARAVIRTUALIZED",
    "values": [ "PARAVIRTUALIZED" ]
  },
  "Network.AttachmentType": {
    "descriptorType": "enumstring",
    "source": "IMAGE",
    "defaultValue": "PARAVIRTUALIZED",
    "values": [ "PARAVIRTUALIZED" ]
  }
}
JSON
}

if [[ -n $existing_schema && $existing_schema != "null" ]]; then
  echo "› image capability schema already attached: $existing_schema"
else
  echo "› attaching an image capability schema (UEFI_64)"
  global_schema_id=$(oci_cli compute global-image-capability-schema list \
    --query 'data[0].id' --raw-output)
  version_name=$(oci_cli compute global-image-capability-schema-version list \
    --global-image-capability-schema-id "$global_schema_id" \
    --all --query 'data[-1].name' --raw-output)
  echo "  global schema version: $version_name"

  write_schema_data

  # The flag is --global-image-capability-schema-version-name, not
  # --image-capability-schema-version-name (the API field is named for the
  # GLOBAL schema the version belongs to). The short name does not exist and
  # the CLI would exit 2 -- the same way the wait above did.
  oci_cli compute image-capability-schema create \
    --compartment-id "$compartment" \
    --image-id "$image_id" \
    --global-image-capability-schema-version-name "$version_name" \
    --schema-data "file://$schema_data" \
    --display-name "$display-capabilities" >/dev/null
fi

# ── 4. verify ───────────────────────────────────────────────────────────────
# Read the firmware back from the API rather than trusting that the create
# above did what it was asked. A silent BIOS image is a VM that boots to an
# empty serial console and bills by the hour, so fail loudly instead.
firmware=$(oci_cli compute image-capability-schema list \
  --compartment-id "$compartment" --image-id "$image_id" \
  --query 'data[0]."schema-data"."Compute.Firmware"."default-value"' \
  --raw-output 2>/dev/null || true)

if [[ $firmware != "UEFI_64" ]]; then
  cat >&2 <<EOF

!! FIRMWARE IS NOT UEFI_64 -- DO NOT LAUNCH THIS IMAGE

   image:    $image_id
   firmware: ${firmware:-<no capability schema attached>}

   An instance launched from this image would get BIOS firmware, find no boot
   sector (this image has none, it boots a UKI from an ESP) and sit at an
   empty serial console. Attach the schema by hand -- section 3 of this
   script has the exact commands -- and re-run this script to verify.
EOF
  exit 1
fi

echo "› firmware: UEFI_64 (verified)"

echo
echo "image OCID: $image_id"
echo
echo "Launch the demo with:"
echo "  ./pocs/image/oci/launch-demo.sh --compartment-id $compartment \\"
echo "      --image-id $image_id --subnet-id <SUBNET OCID> \\"
echo "      --demo-key out/demo-guest_ed25519.pub --owner-key ~/.ssh/id_ed25519.pub --yes"
