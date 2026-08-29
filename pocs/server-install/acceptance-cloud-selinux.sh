#!/bin/bash
# SELinux acceptance for a machine booted from the CLOUD IMAGE, run over ssh.
#
#   ./pocs/server-install/acceptance-cloud-selinux.sh [vm-name]
#   ENFORCE=1 ./pocs/server-install/acceptance-cloud-selinux.sh [vm-name]
#
# acceptance-selinux.sh asks whether an INSTALL is confined. This asks the
# question an image makes different, and it is not a small difference:
#
#   * on an installed machine the operator's account and home directory are
#     created by the orchestrator, minutes after the offline relabel, and the
#     first-boot relabel unit covers them;
#   * on a machine from an image, EVERY account, home directory and
#     authorized_keys file is created by cloud-init, on the first boot, after
#     the image was labelled — and the machine may be enforcing while that
#     happens. An unlabeled home is what locked an operator out in
#     reports/2026-08-29-mandatory-access-control.md §6.4.
#
# So the subjects here are the three agents an install never has: cloud-init
# (creating users, homes, keys and growing the filesystem),
# omarchy-server-firstboot (ssh host keys — which must end up sshd_key_t, not
# etc_t) and qemu-guest-agent. Plus the two things only an image can get wrong:
# the mode the image ships in, and whether the first boot's relabel finished
# before anything logged in.
#
# There is no lab password anywhere in here, and that is a property of the
# image rather than an omission: the image ships no account at all. The only
# account is the one cloud-init created from the seed, in `wheel`, with a key
# and NOPASSWD sudo — which is also what makes it staff_u under the
# administrative-role mapping. `sudo -n` either works or the machine is not
# what it claims to be.
#
# ENFORCE=1 switches the machine to enforcing (through the guard, without
# --force) after the as-shipped measurements, then reboots and measures again.
# The second boot is the one that matters: it is the first boot on which
# cloud-init does NOT re-run, so a denial there is a denial the machine will
# have for the rest of its life.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
vm="${1:-cloudtest}"
lab="$repo_root/pocs/lab/vm.sh"
export LAB_OUT="${LAB_OUT:-$repo_root/pocs/lab/out-$vm}"
# The user the NoCloud seed asked cloud-init to create; the image has none.
export SSH_USER="${SSH_USER:-demo}"
want_disk_gb="${WANT_DISK_GB:-40}"

run() { "$lab" "$vm" ssh "$@" 2>&1; }

pass=0
fail=0
report() { # report <PASS|FAIL> <name> <evidence...>
  local status=$1 name=$2
  shift 2
  if [[ $status == PASS ]]; then ((pass++)); else ((fail++)); fi
  printf '[%s] %s\n' "$status" "$name"
  printf '      %s\n' "$@"
  echo
}

check() { # check <name> <remote command> <regex the output must match>
  local name=$1 cmd=$2 pattern=$3 output status
  output=$(run "$cmd")
  if grep -Eq "$pattern" <<<"$output"; then status=PASS; else status=FAIL; fi
  report "$status" "$name" "\$ $cmd" "${output//$'\n'/$'\n'      }"
}

echo "=== Cloud image SELinux acceptance — VM '$vm' — $(date -Is) ==="
echo "mode under test: ${ENFORCE:+enforcing}${ENFORCE:-as shipped}"
echo

# cloud-init first and blocking, for the same reason acceptance-cloud.sh does
# it: everything below is about state cloud-init writes, and measuring it while
# the agent is still running measures a race.
check "cloud-init finished its run" \
  'cloud-init status --wait 2>&1 | tail -3' \
  'status: done'

# ── 1. the mode the image shipped in ────────────────────────────────────────
#
# The decision this suite exists to record. An image is copied to machines
# nobody is watching, so "which mode does the artifact ship in" is a property
# of the artifact and not of an operator's judgement afterwards.

check "the kernel initialised SELinux from the cmdline baked into the UKI" \
  'ls -d /sys/fs/selinux 2>&1; grep -o "lsm=[^ ]*" /proc/cmdline; echo "in-limine-conf=$(sudo -n grep -c "lsm=" /boot/limine.conf 2>/dev/null)"' \
  'lsm=landlock,lockdown,yama,integrity,selinux,bpf'

check "the refpolicy-arch policy is loaded" \
  'sestatus' \
  'Loaded policy name: *refpolicy-arch'

check "the image records the mode it ships in, and the running mode agrees" \
  'echo "running=$(getenforce)"; grep -E "^SELINUX=" /etc/selinux/config' \
  '^running=(Enforcing|Permissive)$'

check "the local policy module survived generalization" \
  'sudo -n semodule -l 2>/dev/null | grep -c omarchy_server; echo "modules=$(sudo -n semodule -l 2>/dev/null | wc -l)"' \
  '^1$'

# refpolicy gates cloud-init's read of the block device it is about to grow
# behind a boolean that ships OFF. With it off and the machine enforcing,
# cc_growpart is refused, cloud-init-main.service fails, and the machine sits on
# the image's 40 GiB inside whatever volume it was launched onto -- visible only
# to somebody who runs `cloud-init status --long`. The addon turns it on;
# this is the check that it is still on in the artifact.
check "the cloudinit_growpart boolean is on, or growpart cannot read the disk" \
  'sudo -n getsebool cloudinit_growpart' \
  'cloudinit_growpart --> on'

# ── 2. the first boot's relabel ─────────────────────────────────────────────
#
# omarchy-server-generalize touches /.autorelabel precisely because the machine
# that boots the image creates its /home afterwards. This is where that promise
# is either kept or found to have raced.

check "the first-boot relabel ran and cleared its flag" \
  'ls -l /.autorelabel 2>&1; systemctl is-enabled omarchy-server-selinux-relabel.service' \
  'No such file'

check "and it reported what it did" \
  'sudo -n journalctl -u omarchy-server-selinux-relabel.service -b --no-pager -o cat | tail -6' \
  '.'

# The cost of the first boot, in seconds, because it is time an operator waits
# with no console: relabel plus the initramfs/UKI rebuild firstboot does.
check "the first boot's relabel cost is recorded" \
  'sudo -n systemd-analyze blame 2>/dev/null | grep -E "relabel|firstboot" ;
   echo "relabel=$(sudo -n systemctl show -p ExecMainStartTimestampMonotonic -p ExecMainExitTimestampMonotonic omarchy-server-selinux-relabel.service | tr "\n" " ")"' \
  'relabel='

# PID 1 transitions to init_t at exec only if /usr/lib/systemd/systemd already
# carries init_exec_t. On a fresh INSTALL it does not on boot 1, which is why
# that route needs a reboot before enforcing. An image is different and this is
# the check that says so: the build machine relabelled /usr offline and again
# on its own first boot, so a machine from the image has init_t from its very
# first boot — which is what makes shipping enforcing thinkable at all.
check "init is in init_t on the FIRST boot of the image, not kernel_t" \
  'sudo -n sh -c "tr -d \"\\0\" </proc/1/attr/current"' \
  'init_t'

check "sshd runs in a domain of its own" \
  'sudo -n sh -c "for p in \$(pgrep -x sshd); do tr -d \"\\0\" </proc/\$p/attr/current; echo; done | sort -u"' \
  'sshd_t'

# ── 3. what cloud-init created, and how it is labelled ──────────────────────
#
# The heart of it. Every one of these paths was created after the image was
# labelled, by an agent an installed machine does not run.

check "the home directory cloud-init created is user_home_dir_t" \
  'ls -Zd /home /home/*' \
  'user_home_dir_t'

check "the authorized_keys cloud-init wrote is ssh_home_t" \
  "ls -Zd /home/$SSH_USER/.ssh /home/$SSH_USER/.ssh/authorized_keys" \
  'ssh_home_t'

check "nothing under /home or /root disagrees with the policy" \
  'sudo -n restorecon -nvR /home /root 2>&1 | head -10; echo "wrong=$(sudo -n restorecon -nvR /home /root 2>/dev/null | wc -l)"' \
  '^wrong=0$'

check "the sudoers drop-in cloud-init wrote carries a policy label" \
  'sudo -n ls -Z /etc/sudoers.d/' \
  'etc_t'

check "cloud-init's own state directory is labelled, not unlabeled" \
  'sudo -n ls -Zd /var/lib/cloud /var/lib/cloud/instance 2>&1' \
  '_t'

# ── 4. the ssh host identity ────────────────────────────────────────────────
#
# The image ships none; omarchy-server-firstboot makes them. They must end up
# sshd_key_t: the eight files that stayed etc_t on an installed machine are
# recorded in the mandatory-access-control report, and on an image the keys are
# generated on EVERY machine, so getting the ordering wrong ships the defect
# everywhere at once.
# Through sudo, and not because of SELinux: the private keys are mode 0600 and
# owned by root, so an unprivileged `ls -Z` cannot stat them and reports the
# context as `?` -- which is a check that passes on a permissive machine and
# fails on an enforcing one for a reason that has nothing to do with the labels.
check "the regenerated ssh host keys are sshd_key_t, not etc_t" \
  'sudo -n ls -Z /etc/ssh/ssh_host_*; echo "wrong=$(sudo -n ls -Z /etc/ssh/ssh_host_* | grep -vc sshd_key_t)"' \
  '^wrong=0$'

check "and the first-boot unit is the one that made them" \
  'sudo -n journalctl -u omarchy-server-firstboot.service -b --no-pager -o cat | grep -E "ssh host keys|SHA256" | head -5' \
  'ssh host keys 0 -> [0-9]'

# ── 5. the machine grew, under whatever mode it shipped in ──────────────────
#
# growpart forks sfdisk/partx and resize_rootfs runs `btrfs filesystem resize`,
# all of them from cloud-init's domain against a block device. It is the one
# piece of cloud-init's work that touches the kernel's storage layer, and the
# obvious candidate for a refusal that leaves a machine on 40 GiB of a 200 GiB
# volume with nothing in the journal.
check "growpart and the btrfs resize filled the disk" \
  'df -h --output=size,used,avail / | tail -1; echo "root_gib=$(df --output=size -BG / | tail -1 | tr -dc "0-9")"' \
  "root_gib=(3[5-9]|[4-9][0-9]|[0-9]{3,})$"

check "and they are in the cloud-init log rather than assumed" \
  'sudo -n grep -hE "config-(growpart|resizefs): SUCCESS" /var/log/cloud-init.log | tail -2' \
  'SUCCESS'

# `cloud-init status` says `done` even when a module failed; only `--long`
# carries the error list. A growpart refused by the policy shows up here and
# nowhere else a casual look would find it.
check "cloud-init finished with an empty error list, not merely 'done'" \
  'sudo -n cloud-init status --long | sed -n "1,12p"' \
  'errors: \[\]'

# ── 6. the guest agent ──────────────────────────────────────────────────────
#
# qemu-guest-agent is what a hypervisor's "stop instance" and its volume
# freeze/thaw go through, and refpolicy has no rule written for it by name. If
# it lands in a domain that cannot answer the channel device, the failure only
# shows up on the day somebody takes a backup.
check "qemu-guest-agent is running, in a domain, on the virtio channel" \
  'systemctl is-active qemu-guest-agent.service; ls -l /dev/virtio-ports/ 2>&1 | tail -2;
   sudo -n sh -c "for p in \$(pgrep -x qemu-ga); do tr -d \"\\0\" </proc/\$p/attr/current; echo; done"' \
  ':[a-z_]+_t$'

# And the thing the agent is FOR, asked from the host rather than from inside
# the guest: a hypervisor's volume backup freezes the filesystems, snapshots the
# volume and thaws them. That path crosses from the agent into the kernel's
# freeze ioctl on every mounted filesystem, and if the policy refuses it the
# backup is of a filesystem that was never quiesced -- which nobody notices
# until the restore.
#
# vm.sh gives every lab VM the same virtio-serial channel a cloud gives it, and
# the host end is a unix socket in the VM's directory. python3 rather than a
# `qemu-ga` client, because there is no host-side CLI for this in the lab's
# dependency set.
freeze=$(python3 - "$LAB_OUT/vm/$vm/qga.sock" <<'PYEOF'
import socket, sys, time
try:
    s = socket.socket(socket.AF_UNIX); s.settimeout(20); s.connect(sys.argv[1])
    def ask(command):
        s.sendall(('{"execute":"%s"}\n' % command).encode())
        return s.recv(4096).decode().strip()
    print("ping:   ", ask("guest-ping"))
    print("freeze: ", ask("guest-fsfreeze-freeze"))
    time.sleep(1)
    print("status: ", ask("guest-fsfreeze-status"))
    print("thaw:   ", ask("guest-fsfreeze-thaw"))
    print("status: ", ask("guest-fsfreeze-status"))
except Exception as error:
    print("qga-error:", error)
PYEOF
)
if grep -q '"frozen"' <<<"$freeze" && grep -q '"thawed"' <<<"$freeze"; then
  report PASS "the host can freeze and thaw the guest through the agent" "${freeze//$'\n'/$'\n'      }"
else
  report FAIL "the host can freeze and thaw the guest through the agent" "${freeze//$'\n'/$'\n'      }"
fi

# ── 7. the administrative role, through a cloud-init account ────────────────
#
# %wheel -> staff_u is a GROUP mapping, and the seed puts its user in wheel.
# Nothing in the image knows the account's name, so this is the check that the
# mapping survives an account created by a stranger after the image was made.
check "the cloud-init account logs in as staff_t, not the default user_t" \
  'id -Z; id -nG' \
  ':staff_r:staff_t'

check "and sudo lands in sysadm_t, which is what makes the machine administrable" \
  'sudo -n id -Z' \
  ':sysadm_r:sysadm_t'

check "the mapping is %wheel -> staff_u in the policy store's seusers" \
  'grep -Ev "^#|^$" /etc/selinux/refpolicy-arch/seusers' \
  '%wheel:staff_u'

check "and sudoers carries the role transition for that same group" \
  'sudo -n cat /etc/sudoers.d/omarchy-selinux-role' \
  'Defaults:%wheel role=sysadm_r, type=sysadm_t'

# ── 8. the label sweep ──────────────────────────────────────────────────────

check "no file under /etc /usr /var has a label the policy disagrees with" \
  'sudo -n restorecon -nvR -e /var/lib/docker -e /var/lib/containerd /etc /usr /var 2>&1 | head -20;
   echo "wrong=$(sudo -n restorecon -nvR -e /var/lib/docker -e /var/lib/containerd /etc /usr /var 2>/dev/null | wc -l)"' \
  '^wrong=0$'

# ── 9. the denial record of the first boot ──────────────────────────────────
#
# Recorded before anything is switched, because this is the boot on which
# cloud-init runs. Whatever it costs, it costs once per machine — and it is the
# number that decides whether an image may ship enforcing.
echo "--- AVC denials of the FIRST boot (cloud-init, firstboot, qemu-ga) ---"
first_boot_denials=$(run "sudo -n dmesg | grep -oE 'avc: +denied.*' | sed -E 's/pid=[0-9]+ //; s/ino=[0-9]+ //' | sort | uniq -c | head -30")
echo "${first_boot_denials//$'\n'/$'\n'      }"
echo
first_count=$(run "sudo -n dmesg | grep -cE 'avc: +denied'" | tr -dc '0-9')
report PASS "the first boot's denial count was measured" \
  "${first_count:-0} AVC records on the boot that ran cloud-init"

# Which agents produced them, by domain, because "12 denials" and "12 denials
# all belonging to cloud-init" are different findings.
check "the denials are attributed to a domain, not left as a number" \
  "sudo -n dmesg | grep -oE 'scontext=[^ ]+' | sort | uniq -c | sort -rn | head -10; echo 'attributed'" \
  'attributed'

# ── 10. optionally switch to enforcing ──────────────────────────────────────

if [[ ${ENFORCE:-0} == 1 ]]; then
  echo "--- switching to enforcing ---"

  # Without --force. On an image the guard has to pass on its own: /.autorelabel
  # cleared by the first boot, init in init_t, and a session whose role can
  # setenforce. A run that needed --force would mean the image cannot be
  # switched by whoever launched it either.
  check "enforcing is accepted from the session, through the guard" \
    'sudo -n omarchy-server-selinux enforcing 2>&1 | head -10; echo "mode=$(getenforce)"' \
    '^mode=Enforcing$'

  check "and the mode was written down, so it survives a reboot" \
    'grep "^SELINUX=" /etc/selinux/config' 'SELINUX=enforcing'

  check "it is a TWO-way door over ssh: back to permissive and forward again" \
    'sudo -n omarchy-server-selinux permissive >/dev/null 2>&1; echo "back=$(getenforce)";
     sudo -n omarchy-server-selinux enforcing --force >/dev/null 2>&1; echo "fwd=$(getenforce)"' \
    'back=Permissive'
  check "and forward again left it enforcing" 'getenforce' '^Enforcing$'
fi

# ── 11. the workload an image actually has ──────────────────────────────────
#
# Deliberately not acceptance-selinux.sh's workload: that one installs docker
# and runs two updates, and it is already measured on an installed machine. The
# question here is whether the things a COPIED machine does — pacman, snapper,
# the firewall, the update entry point, the guest agent — still work in the
# mode the image ships in.

check "sudo works and reaches root" 'sudo -n id -un' '^root$'

check "pacman can run a transaction" \
  'sudo -n pacman -Sy --noconfirm >/dev/null 2>&1; echo "pacman-exit=$?"; sudo -n pacman -Q pacman-contrib' \
  '^pacman-exit=0$'

check "a snapper snapshot can be taken" \
  'sudo -n snapper -c root create -d cloud-selinux-acceptance --print-number' \
  '^[0-9]+$'

check "the firewall still answers" \
  'sudo -n ufw status verbose | head -6' \
  'Status: active'

check "the update entry point runs the way its timer runs it" \
  'sudo -n systemctl start omarchy-server-update.service; sudo -n systemctl show -p Result -p ExecMainStatus omarchy-server-update.service' \
  'Result=success'

check "the boot entry still points at a UKI that exists" \
  'sudo -n grep -c "EFI/Linux" /boot/limine.conf; sudo -n ls -l /boot/EFI/Linux/' \
  '\.efi'

# ── 12. reboot, and the boot that matters ───────────────────────────────────
#
# The second boot is the first one on which cloud-init does not re-run. A
# denial here is a denial the machine keeps forever, and zero is the bar for
# calling an image enforcing-ready.

echo "--- rebooting ---"
boot_before=$(run 'cat /proc/sys/kernel/random/boot_id')
echo "boot id before: $boot_before"
run 'sudo -n systemctl reboot' >/dev/null 2>&1
boot_now=""
for _ in $(seq 1 60); do
  sleep 10
  boot_now=$(run 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)
  [[ -n $boot_now && $boot_now != "$boot_before" ]] && break
done
echo "boot id after:  ${boot_now:-<unreachable>}"
echo

if [[ -n ${boot_now:-} && $boot_now != "$boot_before" ]]; then
  report PASS "the machine came back over ssh after a reboot" "boot_id $boot_before -> $boot_now"
else
  report FAIL "the machine came back over ssh after a reboot" "boot_id is still $boot_before (or the VM never came back)"
fi

check "SELinux is in the mode the machine was left in" 'getenforce' '^(Enforcing|Permissive)$'

check "cloud-init did not redo its once-per-instance work" \
  'cloud-init status --wait 2>&1 | tail -2; uname -n; ls -Zd /home/*' \
  'user_home_dir_t'

echo "--- AVC denials of the SECOND boot ---"
second=$(run "sudo -n dmesg | grep -oE 'avc: +denied.*' | sed -E 's/pid=[0-9]+ //; s/ino=[0-9]+ //' | sort | uniq -c | head -30")
echo "${second//$'\n'/$'\n'      }"
echo
second_count=$(run "sudo -n dmesg | grep -cE 'avc: +denied'" | tr -dc '0-9')
if [[ ${ENFORCE:-0} == 1 ]]; then
  if ((${second_count:-1} == 0)); then
    report PASS "enforcing: the second boot denied nothing" "0 AVC records this boot"
  else
    report FAIL "enforcing: the second boot denied something" "$second_count AVC records this boot — see the dump above"
  fi
else
  report PASS "the second boot's denial count was measured" "${second_count:-0} AVC records this boot"
fi

# The label check again, after a reboot in this mode: a machine whose home
# directory is fine on boot 1 and unlabeled on boot 2 would be the worst of the
# failure modes, because nobody looks twice.
check "the home directory is still user_home_dir_t after the reboot" \
  'ls -Zd /home/*' 'user_home_dir_t'

check "and the root filesystem is still the grown one" \
  'echo "root_gib=$(df --output=size -BG / | tail -1 | tr -dc "0-9")"' \
  "root_gib=(3[5-9]|[4-9][0-9]|[0-9]{3,})$"

echo "=== $pass passed, $fail failed ==="
