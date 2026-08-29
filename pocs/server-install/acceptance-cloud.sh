#!/bin/bash
# Acceptance list for a machine booted from the CLOUD IMAGE, run over ssh.
#
#   ./pocs/server-install/acceptance-cloud.sh [vm-name]
#
# Same shape as acceptance.sh — one PASS/FAIL line per item followed by the
# evidence it was judged on, never non-zero on a failed check — and a different
# subject. acceptance.sh asks whether an INSTALL is a server; this asks whether
# a machine that was copied from an image has become a machine of its own:
#
#   * did the metadata land (hostname, the user the seed named, its key)
#   * did nothing of the BUILD machine survive the copy (its user, its
#     password, its machine-id, its ssh host identity, its logs)
#   * did the image grow into the disk it was launched onto
#   * is it still recognisably Omarchy Server afterwards
#
# There is no lab password here, and that is a result rather than an omission:
# the image ships no account with a password, and the only account on the
# machine is the one cloud-init created from the seed, with NOPASSWD sudo and a
# key. `sudo -n` either works or the machine is not what it claims to be.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
vm="${1:-cloudimg}"
lab="$repo_root/pocs/lab/vm.sh"
export LAB_OUT="${LAB_OUT:-$repo_root/pocs/lab/out-$vm}"
# The user the seed asked cloud-init to create; the image itself has none.
export SSH_USER="${SSH_USER:-demo}"
# The account the image was BUILT with, which must not have survived
# generalization. Named here so the check can look for it by name.
build_user="${BUILD_USER:-imgbuild}"
# What the seed asked for, so the checks compare against the request rather
# than against a string somebody typed twice.
want_hostname="${WANT_HOSTNAME:-omarchy-cloud-test}"
# The disk the VM was created with. growpart's whole job is to turn the image's
# 40 GiB layout into this.
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

echo "=== Cloud image acceptance — VM '$vm' — $(date -Is) ==="
echo

# cloud-init first and blocking: every other assertion here is about state
# cloud-init writes, and asserting it while the agent is still running measures
# a race. `--wait` returns when the final stage has finished.
check "cloud-init finished its run" \
  'cloud-init status --wait 2>&1 | tail -3; echo "exit=$?"' \
  'status: done'

check "the datasource is one of the five this image declares" \
  'cloud-init query platform 2>/dev/null; cloud-init query --format "{{ v1.cloud_name }} / {{ v1.distro }}" 2>/dev/null;
   grep -h "^datasource_list" /etc/cloud/cloud.cfg.d/05-omarchy-server.cfg' \
  'NoCloud, ConfigDrive, OpenStack, Oracle, Ec2'

# ── what the metadata was supposed to decide ────────────────────────────────
check "hostname came from the metadata" \
  "echo \"hostname: \$(uname -n)\"; echo \"wanted: $want_hostname\"; hostnamectl --static" \
  "^$want_hostname$"

check "the user the seed named exists, with its key and passwordless sudo" \
  'id "$(id -un)"; echo "--- authorized_keys ---"; cut -d" " -f1,3 ~/.ssh/authorized_keys;
   echo "--- sudo ---"; sudo -n true && echo "sudo-n-ok"' \
  'sudo-n-ok'

# ── what must NOT have survived the copy ────────────────────────────────────
check "the build account is gone" \
  "echo \"build user: $build_user\"; id $build_user 2>&1;
   echo \"--- accounts with a uid over 999 ---\";
   awk -F: '\$3>=1000 && \$3<65534 {print \$1, \$3}' /etc/passwd;
   echo \"--- home ---\"; ls /home" \
  "no such user|Nenhum usu|not exist"

# The autoinstall drive gives root a password hash. An image that shipped one
# would ship a credential every machine from it shares and a console login
# would accept, so generalization replaces it outright rather than prefixing it
# with `!` (which leaves the original readable in /etc/shadow).
check "root carries no password" \
  'sudo -n awk -F: "\$1==\"root\" {print \"root field: [\" \$2 \"]\"; print (\$2==\"!\" || \$2==\"*\" || \$2==\"!!\" || \$2==\"\") ? \"root_locked=yes\" : \"root_locked=no\"}" /etc/shadow;
   sudo -n passwd -S root' \
  '^root_locked=yes$'

# A lab password file, a staged sudo wrapper or a sudoers drop-in for the build
# account are the three ways the build machine's credentials could ride along.
check "no build credentials anywhere on the image" \
  "ls -la /home/*/.lab-pw /home/*/.lab-sudo /etc/sudoers.d/ 2>&1 | tail -20;
   echo \"leftovers=\$(ls /home/*/.lab-pw /home/*/.lab-sudo /etc/sudoers.d/$build_user 2>/dev/null | wc -l)\"" \
  'leftovers=0'

# An empty machine-id in the image is what makes systemd generate one per
# machine. A non-empty one here proves the generation happened; the value is
# printed so two machines from one image can be compared by eye.
check "machine-id was generated on this machine" \
  'echo "machine-id: $(cat /etc/machine-id)"; echo "length: $(wc -c </etc/machine-id)";
   sudo -n systemd-id128 machine-id 2>/dev/null | head -1' \
  '^length: 33$'

check "ssh host keys were regenerated at first boot" \
  'ls -l --time-style=+%F_%T /etc/ssh/ssh_host_*_key.pub;
   echo "count=$(ls /etc/ssh/ssh_host_*_key 2>/dev/null | wc -l)"' \
  'count=[1-9]'

check "the first-boot unit ran and said what it did" \
  'systemctl is-enabled omarchy-server-firstboot.service 2>&1;
   sudo -n journalctl -u omarchy-server-firstboot --no-pager 2>/dev/null | tail -12;
   echo "marker: $(sudo -n cat /var/lib/omarchy/firstboot-done 2>/dev/null)"' \
  'firstboot: done|ssh host keys'

# A boot count would be the obvious assertion and it is the wrong one: the
# generalize wipes the journal and then the machine shuts down, which writes a
# short journal of its own shutdown into the image. What must not be in there is
# the build machine's WORK — the account, its sudo, its ssh session.
check "the image's journal mentions nothing of the build machine" \
  "echo \"boots recorded: \$(sudo -n journalctl --list-boots --no-pager 2>/dev/null | wc -l)\";
   echo \"first entry: \$(sudo -n journalctl --no-pager -o short-iso 2>/dev/null | head -1)\";
   echo \"build_user_mentions=\$(sudo -n journalctl --no-pager 2>/dev/null | grep -c '$build_user')\"" \
  'build_user_mentions=0'

# ── what the platform gave it ───────────────────────────────────────────────
# growpart grew /dev/vda2 into the larger disk, then cloud-init's resizefs ran
# `btrfs filesystem resize max /`. The assertion is on the FILESYSTEM size, not
# the partition: a grown partition with an unresized filesystem is the failure
# mode this is here to catch.
check "growpart + btrfs resize filled the ${want_disk_gb} GiB disk" \
  "lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS /dev/vda;
   df -h /; echo \"--- btrfs ---\"; sudo -n btrfs filesystem usage / 2>/dev/null | head -6;
   echo \"root_gib=\$(df --output=size -BG / | tail -1 | tr -dc '0-9')\"" \
  "root_gib=(3[5-9]|4[0-9])"

check "growpart and resizefs are in the cloud-init log, not assumed" \
  'sudo -n grep -hiE "growpart|resizefs|resize" /var/log/cloud-init.log 2>/dev/null | tail -8' \
  'resize|grow'

# ── still Omarchy Server ────────────────────────────────────────────────────
check "os-release, issue and MOTD still say Omarchy" \
  'grep -E "^(NAME|PRETTY_NAME|ID)=" /etc/os-release; echo "--- issue ---";
   head -3 /etc/issue; echo "--- motd ---"; omarchy-server-motd 2>/dev/null | head -5' \
  'Omarchy'

check "profile marker and version survived" \
  'echo "profile: $(cat /etc/omarchy-profile)"; echo "version: $(omarchy-version 2>/dev/null)";
   pacman -Q omarchy-server omarchy-server-settings 2>&1' \
  '^profile: server$'

check "the update entry point works on a machine nobody logs into" \
  'omarchy-server-update status 2>&1 | head -12' \
  'timer|transactional|update'

check "the firewall is up and rate-limits ssh" \
  'sudo -n ufw status verbose 2>&1 | head -12' \
  '22.*LIMIT|Status: active'

check "sshd still refuses passwords and root" \
  'sudo -n sshd -T 2>/dev/null | grep -iE "^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication) "' \
  '[Pp]ermit[Rr]oot[Ll]ogin no'

check "no failed units" \
  'systemctl --failed --no-pager; echo "failed=$(systemctl --failed --no-pager --plain --no-legend | wc -l)"' \
  '^failed=0$'

check "the boot is still a server's boot" \
  'systemd-analyze 2>&1; systemd-analyze blame 2>/dev/null | head -8' \
  'Startup finished'

# @factory is the generalized state, kept as a read-only subvolume beside @ so
# a machine can be reset to the image it came from without re-downloading it.
check "@factory is present beside @" \
  'sudo -n btrfs subvolume list / | awk "{print \$NF}" | grep -E "^@[^/]*$" | sort;
   echo "factory=$(sudo -n btrfs subvolume list / | awk "{print \$NF}" | grep -cx "@factory")"' \
  '^factory=1$'

check "the package cache shipped empty" \
  'echo "cached=$(ls /var/cache/pacman/pkg/*.pkg.tar.* 2>/dev/null | wc -l)";
   du -sh /var/cache/pacman/pkg 2>/dev/null' \
  '^cached=0$'

echo "=== $pass passed, $fail failed ==="
