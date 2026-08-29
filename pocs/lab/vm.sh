#!/bin/bash
# Headless QEMU/KVM lab VM for the Omarchy ISO (mirrors omarchy-iso/bin/
# omarchy-iso-boot, minus the GUI): OVMF 4M firmware, virtio disk, the
# install ISO and the `cidata` autoinstall ISO as cdroms, user-mode network
# with ssh forwarded to localhost:$SSH_PORT, VNC on 127.0.0.1:$VNC, and a QEMU
# monitor socket for screenshots.
#
# Usage: vm.sh <name> create [--disk-gb 40] [--data-disk-gb N] [--from-image PATH] [--secboot]
#        vm.sh <name> start  [--iso PATH] [--cidata PATH] [--secboot]
#        vm.sh <name> stop | status | screenshot | ssh [cmd...] | wait-ssh [secs]
#        vm.sh <name> snapshot <tag> | restore <tag>
# Each VM lives in out/vm/<name>/ (disk.qcow2, vars.qcow2, monitor.sock, pid).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Where this lab keeps its VMs, ISOs and the cidata ssh key. One directory per
# profile keeps the desktop reference VM and the server VM from sharing a key,
# a password or a disk: LAB_OUT=pocs/lab/out-server for the server profile.
out="${LAB_OUT:-$here/out}"
[[ $out == /* ]] || out="$(cd "$out" && pwd)"
name="${1:?vm name}"; shift
cmd="${1:?command}"; shift
vm="$out/vm/$name"
disk="$vm/disk.qcow2"
# An optional second, empty disk. The install only ever touches /dev/vda, so
# this one arrives as an untouched /dev/vdb -- which is what a machine that has
# to be tested with a separate data volume needs.
data_disk="$vm/data.qcow2"
vars="$vm/vars.qcow2"
# The QEMU monitor is a unix socket, and a socket path is capped at ~108 bytes.
# A checkout path plus an out-<profile>/vm/<name>/ directory already overflows
# that, so the socket lives in the runtime dir keyed by the VM's own path.
control_dir="${XDG_RUNTIME_DIR:-/tmp}/omarchy-lab"
mkdir -p "$control_dir"
mon="$control_dir/$(printf '%s' "$vm" | cksum | cut -d' ' -f1).mon"
pidfile="$vm/pid"
ovmf_dir=/usr/share/edk2/ovmf

# Stable per-VM ports derived from the name so several VMs can coexist.
port_base=$(( 2200 + ( $(printf '%s' "$name" | cksum | cut -d' ' -f1) % 50 ) ))
SSH_PORT="${SSH_PORT:-$port_base}"
VNC="${VNC:-$(( port_base - 2200 + 10 ))}"

mem="${MEM:-8192}"
cpus="${CPUS:-4}"
iso="$out/omarchy-4.0.1.iso"
cidata="$out/cidata.iso"
disk_gb=40
data_disk_gb=0
secboot=0
# `create --from-image PATH`: start from a built cloud image instead of an
# empty disk. The image is copied (never used in place — a test must not be
# able to write into the artifact it is testing) and grown to --disk-gb, which
# is what gives growpart something to grow into.
from_image=""

while (($#)); do
  case "$1" in
    --disk-gb) disk_gb="$2"; shift 2 ;;
    --from-image) from_image="$2"; shift 2 ;;
    --data-disk-gb) data_disk_gb="$2"; shift 2 ;;
    --iso) iso="$2"; shift 2 ;;
    --cidata) cidata="$2"; shift 2 ;;
    --secboot) secboot=1; shift ;;
    *) break ;;
  esac
done

running() { [[ -f $pidfile ]] && kill -0 "$(<"$pidfile")" 2>/dev/null; }

# ControlMaster: every helper in pocs/ opens one ssh connection per command,
# and the server profile's firewall rate-limits port 22 (`ufw limit`), which
# drops the seventh connection from the same source within thirty seconds --
# the harness looks hung while the rule is doing exactly its job. Multiplexing
# turns those bursts into sessions over a single TCP connection.
#
# The socket lives under the runtime dir for the same length reason as the
# monitor socket above.
ssh_opts=(-p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
  -o ControlMaster=auto -o ControlPath="$control_dir/%C" -o ControlPersist=120)
[[ -f $out/lab_ed25519 ]] && ssh_opts+=(-i "$out/lab_ed25519" -o IdentitiesOnly=yes)

monitor() { # send one HMP command
  printf '%s\n' "$1" | socat - "UNIX-CONNECT:$mon" | tail -n +2 | sed 's/\r//'
}

case "$cmd" in
  create)
    mkdir -p "$vm"
    [[ -f $disk ]] && { echo "disk exists: $disk (delete it to recreate)" >&2; exit 1; }
    if [[ -n $from_image ]]; then
      [[ -f $from_image ]] || { echo "no such image: $from_image" >&2; exit 1; }
      # A full convert rather than a backing file: a qcow2 with a backing file
      # would make every write in the test a delta against the artifact, and
      # the artifact would then have to stay where it is for the VM to boot.
      qemu-img convert -O qcow2 "$from_image" "$disk"
      qemu-img resize -q "$disk" "${disk_gb}G"
    else
      qemu-img create -q -f qcow2 "$disk" "${disk_gb}G"
    fi
    (( data_disk_gb )) && qemu-img create -q -f qcow2 "$data_disk" "${data_disk_gb}G"
    if (( secboot )); then
      # The distro's secboot variable store is NOT in Setup Mode: it ships with
      # Microsoft's PK, KEK and db already enrolled, which means the firmware
      # enforces from the first boot and `sbctl enroll-keys` has nothing it is
      # allowed to write. Two things would then be impossible in one VM: the
      # LIVE ISO is unsigned (upstream builds it with an unsigned GRUB) so it
      # would not boot at all, and the install could not enroll the machine's
      # own keys.
      #
      # Deleting the PK is the file-level equivalent of the firmware setup
      # screen's "erase all Secure Boot variables" / "reset to Setup Mode":
      # with no platform key the firmware reports SetupMode=1, enforces
      # nothing, and accepts unauthenticated writes to PK/KEK/db -- which is
      # exactly the state install/server/secureboot-server.sh and
      # `omarchy-server-secureboot enroll` are written for. KEK, db and dbx are
      # left alone; enroll-keys overwrites the first two and the Microsoft
      # revocation list in dbx is worth keeping.
      cp "$ovmf_dir/OVMF_VARS_4M.secboot.qcow2" "$vars"
      command -v virt-fw-vars >/dev/null || {
        echo "--secboot needs virt-fw-vars (Arch: python-virt-firmware, Fedora: virt-firmware)" >&2
        exit 1
      }
      virt-fw-vars --inplace "$vars" --delete PK >/dev/null 2>&1 || {
        echo "failed to clear the platform key from $vars" >&2
        exit 1
      }
    else
      cp "$ovmf_dir/OVMF_VARS_4M.qcow2" "$vars"
    fi
    # Remember the choice: OVMF's secboot variable store only works against the
    # secboot CODE image, and a later `start` without the flag would pair them
    # wrongly and boot a firmware that cannot see its own variables.
    (( secboot )) && : >"$vm/secboot"
    note=""; (( secboot )) && note=" [firmware in setup mode]"
    [[ -n $from_image ]] && note+=" [from ${from_image##*/}]"
    (( data_disk_gb )) && note+=" [data disk ${data_disk_gb}G]"
    echo "created $vm (disk ${disk_gb}G, secboot=$secboot)$note"
    ;;
  start)
    running && { echo "already running (pid $(<"$pidfile"))"; exit 0; }
    [[ -f $disk && -f $vars ]] || { echo "run create first" >&2; exit 1; }
    [[ -f $vm/secboot ]] && secboot=1
    code="$ovmf_dir/OVMF_CODE_4M.qcow2"
    (( secboot )) && code="$ovmf_dir/OVMF_CODE_4M.secboot.qcow2"
    args=(
      -name "$name" -machine q35,accel=kvm -cpu host -smp "$cpus" -m "$mem"
      -drive if=pflash,format=qcow2,readonly=on,file="$code"
      -drive if=pflash,format=qcow2,file="$vars"
      -drive file="$disk",format=qcow2,if=none,id=drive0
      -device virtio-blk-pci,drive=drive0,bootindex=1
      -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"$SSH_PORT"-:22
      -device virtio-net-pci,netdev=net0
      -display none -vnc 127.0.0.1:"$VNC"
      -monitor unix:"$mon",server,nowait
      -serial file:"$vm/serial.log"
      # The guest agent's channel. The `cloud` addon enables
      # qemu-guest-agent.service, and without this device the unit's
      # ConditionPathExists on /dev/virtio-ports/org.qemu.guest_agent.0 is unmet
      # and it never starts -- so a lab VM measured "the guest agent is not
      # running" and said nothing about whether it WORKS, which is the question
      # an image raises (a hypervisor's stop-instance and its volume
      # freeze/thaw both go through it). Every cloud that runs this image
      # presents the same channel; presenting it here is what makes the lab the
      # same machine.
      -chardev socket,path="$vm/qga.sock",server=on,wait=off,id=qga0
      -device virtio-serial
      -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0
      -rtc base=utc
      -daemonize -pidfile "$pidfile"
    )
    # The data disk, when one was created, and no bootindex: it is empty and
    # must never be what the firmware tries to boot.
    if [[ -f $data_disk ]]; then
      args+=(-drive file="$data_disk",format=qcow2,if=none,id=drive1 -device virtio-blk-pci,drive=drive1)
    fi
    if [[ -f $iso ]]; then
      args+=(-drive file="$iso",media=cdrom,if=none,format=raw,id=cdrom0 -device ide-cd,drive=cdrom0,bus=ide.0,bootindex=2)
    fi
    if [[ -f $cidata ]]; then
      args+=(-drive file="$cidata",media=cdrom,if=none,format=raw,id=cdrom1 -device ide-cd,drive=cdrom1,bus=ide.1)
    fi
    qemu-system-x86_64 "${args[@]}"
    echo "started $name: ssh -p $SSH_PORT localhost, vnc 127.0.0.1:$VNC, iso=$([[ -f $iso ]] && echo yes || echo no) cidata=$([[ -f $cidata ]] && echo yes || echo no)"
    ;;
  stop)
    running || { echo "not running"; exit 0; }
    monitor 'system_powerdown' >/dev/null || true
    for _ in $(seq 1 30); do running || break; sleep 1; done
    running && kill "$(<"$pidfile")"
    echo "stopped"
    ;;
  status)
    if running; then echo "running pid $(<"$pidfile") ssh=$SSH_PORT vnc=$VNC"; else echo "stopped"; fi
    ;;
  screenshot)
    running || { echo "not running" >&2; exit 1; }
    shot="$vm/screen-$(date +%H%M%S).ppm"
    monitor "screendump $shot" >/dev/null
    if command -v magick >/dev/null; then magick "$shot" "${shot%.ppm}.png" && rm "$shot" && shot="${shot%.ppm}.png"
    elif command -v convert >/dev/null; then convert "$shot" "${shot%.ppm}.png" && rm "$shot" && shot="${shot%.ppm}.png"; fi
    echo "$shot"
    ;;
  ssh)
    exec ssh "${ssh_opts[@]}" "${SSH_USER:-omarchy}@localhost" "$@"
    ;;
  wait-ssh)
    limit="${1:-1800}"
    # 10s, not 5s: the server profile's `ufw limit 22/tcp` drops a source that
    # opens six connections within thirty seconds, and a 5s poll sits exactly on
    # that threshold — the machine would come up and the poll would rate-limit
    # itself out.
    for ((i = 0; i < limit; i += 10)); do
      if ssh "${ssh_opts[@]}" -o ConnectTimeout=3 -o BatchMode=yes "${SSH_USER:-omarchy}@localhost" true 2>/dev/null; then
        echo "ssh up after ${i}s"; exit 0
      fi
      sleep 10
    done
    echo "ssh not reachable after ${limit}s" >&2; exit 1
    ;;
  snapshot)
    tag="${1:?tag}"; running && { echo "stop the VM first" >&2; exit 1; }
    qemu-img snapshot -c "$tag" "$disk" && cp "$vars" "$vm/vars.$tag.qcow2" && echo "snapshot $tag"
    ;;
  restore)
    tag="${1:?tag}"; running && { echo "stop the VM first" >&2; exit 1; }
    qemu-img snapshot -a "$tag" "$disk" && cp "$vm/vars.$tag.qcow2" "$vars" && echo "restored $tag"
    ;;
  *) echo "unknown command: $cmd" >&2; exit 1 ;;
esac
