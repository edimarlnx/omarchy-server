#!/bin/bash
# Build the autoinstall `cidata` ISO the Omarchy installer consumes, without
# running the interactive configurator. The JSON mirrors what
# omarchy-iso/configs/airootfs/root/configurator writes for a full-disk
# install (Limine, btrfs @/@home/@log/@pkg, 2 GiB ESP), see docs/upstream-map.md.
#
# Usage: mkcidata.sh [--profile desktop|server] [--hostname NAME] [--user NAME]
#                    [--disk /dev/vda] [--disk-size-gb 40] [--addons a,b]
#                    [--unattended-updates] [--out DIR]
# Output: $OUT/cidata/* (the plain files) and $OUT/cidata.iso (volume label
# "cidata", ISO9660+Joliet+RockRidge, which udev exposes as
# /dev/disk/by-label/cidata inside the live ISO).
set -euo pipefail

profile=desktop
# Empty on purpose: the JSON key is then omitted and the installer picks the
# default. archinstall's own fallback is "archlinux"; the orchestrator patch
# turns that into "omarchy", which is what the interactive configurator offers
# too. Leaving it unset here is what exercises that path.
hostname=""
username=omarchy
disk=/dev/vda
disk_size_gb=40
addons=""
unattended_updates=0
out="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/out"
timezone="${TZ_NAME:-America/Sao_Paulo}"
keyboard="${KB_LAYOUT:-us}"
full_name="${FULL_NAME:-Omarchy Lab}"
email="${EMAIL:-lab@example.invalid}"

while (($#)); do
  case "$1" in
    --profile) profile="$2"; shift 2 ;;
    --hostname) hostname="$2"; shift 2 ;;
    --user) username="$2"; shift 2 ;;
    --disk) disk="$2"; shift 2 ;;
    --disk-size-gb) disk_size_gb="$2"; shift 2 ;;
    --addons) addons="$2"; shift 2 ;;
    --unattended-updates) unattended_updates=1; shift ;;
    --out) out="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

for tool in jq openssl xorriso; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

dir="$out/cidata"
rm -rf "$dir"
mkdir -p "$dir"

# Password: reuse an existing one for this lab so re-generating cidata keeps
# the credentials stable across VMs.
password_file="$out/lab-password"
if [[ ! -f $password_file ]]; then
  openssl rand -base64 18 >"$password_file"
  chmod 600 "$password_file"
fi
password=$(<"$password_file")
password_hash=$(openssl passwd -6 "$password")

# An omitted key, not an empty string: archinstall only overrides its default
# when the value is non-empty, and an explicit "" would read the same as absent
# to it but not to a human reading the file.
hostname_field=""
if [[ -n $hostname ]]; then
  hostname_field="\"hostname\": \"$hostname\","
fi

# ---- disk layout (same arithmetic as the configurator) --------------------
mib=$((1024 * 1024))
gib=$((mib * 1024))
disk_size=$((disk_size_gb * gib))
disk_size_in_mib=$((disk_size / mib * mib))
gpt_backup_reserve=$((mib))
boot_partition_start=$((mib))
boot_partition_size=$((2 * gib))
main_partition_start=$((boot_partition_size + boot_partition_start))
main_partition_size=$((disk_size_in_mib - main_partition_start - gpt_backup_reserve))

case "$profile" in
  desktop)
    runtime_pkg=omarchy
    settings_pkg=omarchy-settings
    # archinstall's application step installs the PipeWire stack.
    audio_config='{ "audio": "pipewire" }'
    early_packages='"base-devel", "git", "omarchy-keyring"'
    ;;
  server)
    runtime_pkg=omarchy-server
    settings_pkg=omarchy-server-settings
    # No audio stack at all on a server.
    audio_config='null'
    # The lean base carries no compiler and no git; the ISO's early bootstrap
    # does not ask for them either on this profile.
    early_packages='"omarchy-keyring"'
    ;;
  *) echo "unknown profile: $profile" >&2; exit 1 ;;
esac

cat >"$dir/user_configuration.json" <<EOF
{
    "app_config": null,
    "archinstall-language": "English",
    "auth_config": {},
    "audio_config": $audio_config,
    "bootloader_config": { "bootloader": "Limine", "uki": false, "removable": false },
    "custom_commands": [],
    "omarchy_install": {
        "mode": "full_disk",
        "defer_provisioning": false,
        "target_mount": "/mnt",
        "boot": {
            "esp_mount": "/boot",
            "esp_path": "/EFI/limine",
            "efi_binary": "limine_x64.efi",
            "enable_fallback": true
        },
        "storage": {
            "kernel": "linux"
        }
    },
    "disk_config": {
        "config_type": "default_layout",
        "device_modifications": [
            {
                "device": "$disk",
                "partitions": [
                    {
                        "btrfs": [],
                        "dev_path": null,
                        "flags": [ "boot", "esp" ],
                        "fs_type": "fat32",
                        "mount_options": [],
                        "mountpoint": "/boot",
                        "obj_id": "ea21d3f2-82bb-49cc-ab5d-6f81ae94e18d",
                        "size": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $boot_partition_size },
                        "start": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $boot_partition_start },
                        "status": "create",
                        "type": "primary"
                    },
                    {
                        "btrfs": [
                            { "mountpoint": "/", "name": "@" },
                            { "mountpoint": "/home", "name": "@home" },
                            { "mountpoint": "/var/log", "name": "@log" },
                            { "mountpoint": "/var/cache/pacman/pkg", "name": "@pkg" }
                        ],
                        "dev_path": null,
                        "flags": [],
                        "fs_type": "btrfs",
                        "mount_options": [ "compress=zstd" ],
                        "mountpoint": null,
                        "obj_id": "8c2c2b92-1070-455d-b76a-56263bab24aa",
                        "size": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $main_partition_size },
                        "start": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $main_partition_start },
                        "status": "create",
                        "type": "primary"
                    }
                ],
                "wipe": true
            }
        ]
    },
    $hostname_field
    "kernels": [ "linux" ],
    "network_config": { "type": "iso" },
    "ntp": true,
    "parallel_downloads": 8,
    "script": null,
    "services": [],
    "swap": true,
    "timezone": "$timezone",
    "locale_config": { "kb_layout": "$keyboard", "sys_enc": "UTF-8", "sys_lang": "en_US.UTF-8" },
    "mirror_config": {
        "custom_repositories": [],
        "custom_servers": [
            {"url": "https://mirror.omarchy.org/\$repo/os/\$arch"},
            {"url": "https://mirror.rackspace.com/archlinux/\$repo/os/\$arch"},
            {"url": "https://geo.mirror.pkgbuild.com/\$repo/os/\$arch"}
        ],
        "mirror_regions": {},
        "optional_repositories": []
    },
    "packages": [ $early_packages, "$settings_pkg", "$runtime_pkg" ],
    "profile_config": { "gfx_driver": null, "greeter": null, "profile": {} },
    "version": "3.0.9"
}
EOF

jq -n --arg hash "$password_hash" --arg user "$username" '{
  root_enc_password: $hash,
  users: [ { enc_password: $hash, groups: [], sudo: true, username: $user } ]
}' >"$dir/user_credentials.json"

# The ISO bakes in the profile it was built for; this file overrides it, so a
# server cidata is explicit about what it expects even on a dual-purpose ISO
# (omarchy-cidata-load copies it to /root, the orchestrator reads it).
echo "$profile" >"$dir/profile"

# Optional package sets to apply in the chroot right after the system setup,
# one name per line. The orchestrator runs `omarchy-server-addon <name>` for
# each, against the ISO's offline mirror, so a machine installed without a
# network still comes up with them.
if [[ -n $addons ]]; then
  tr ',' '\n' <<<"$addons" | sed '/^[[:space:]]*$/d' >"$dir/addons"
fi

# A marker file, not a value: its presence turns on the server profile's daily
# update timer during the install (install/server/unattended-updates-server.sh).
if ((unattended_updates)); then
  echo "enabled" >"$dir/unattended-updates"
fi

echo "$full_name" >"$dir/user_full_name.txt"
echo "$email" >"$dir/user_email_address.txt"
echo false >"$dir/user_encrypt_installation.txt"

# SSH: a lab-only keypair (out/lab_ed25519, gitignored) plus any public key
# of the operator, so the VM is reachable headless.
lab_key="$out/lab_ed25519"
[[ -f $lab_key ]] || ssh-keygen -q -t ed25519 -N "" -C "omarchy-lab" -f "$lab_key"
cat "$lab_key.pub" >"$dir/authorized_keys"
for key in "$HOME"/.ssh/id_*.pub; do
  [[ -f $key ]] && cat "$key" >>"$dir/authorized_keys"
done

jq . "$dir/user_configuration.json" >/dev/null # validate

xorriso -as mkisofs -quiet -V cidata -J -r -o "$out/cidata.iso" "$dir" 2>/dev/null
echo "cidata: $out/cidata.iso (profile=$profile host=${hostname:-<installer default>} user=$username disk=$disk ${disk_size_gb}G addons=${addons:-none} unattended-updates=$unattended_updates)"
echo "password: $password_file"
