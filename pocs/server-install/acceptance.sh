#!/bin/bash
# Acceptance list, run against a booted server VM over ssh.
#
#   ./pocs/server-install/acceptance.sh [vm-name]
#
# Prints one PASS/FAIL line per item followed by the evidence it was judged on,
# so a failure is readable without re-running anything. Never exits non-zero on
# a failed check: the point is the report, not the exit status.
#
# The lab password never appears in the output. It is written once to
# ~/.lab-pw inside the VM (mode 600) and fed to `sudo -S` by the ~/.lab-sudo
# wrapper; both are removed when the run ends. The evidence shows `.lab-sudo`
# where a privileged command ran.
#
# omarchy-update runs LAST on purpose — it pulls the online mirrors and would
# change the package count and disk usage the checks above measure.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
vm="${1:-srv}"
lab="$repo_root/pocs/lab/vm.sh"
# The server lab lives in its own out dir (own disk, own cidata ssh key).
export LAB_OUT="${LAB_OUT:-$repo_root/pocs/lab/out-server}"
export SSH_USER="${SSH_USER:-omarchy}"

run() { "$lab" "$vm" ssh "$@" 2>&1; }

# Stage the password and the sudo wrapper. The password travels on stdin, so it
# is never part of a command line this script prints or the VM's shell history.
"$lab" "$vm" ssh 'cat >~/.lab-pw && chmod 600 ~/.lab-pw' <"$LAB_OUT/lab-password" || {
  echo "could not stage the lab password in the VM" >&2
  exit 1
}
run 'printf "%s\n" "#!/bin/bash" "exec sudo -S -p \"\" \"\$@\" <\$HOME/.lab-pw" >~/.lab-sudo && chmod 700 ~/.lab-sudo' >/dev/null
# Some steps of omarchy-update echo their stdin back (yay does), and stdin is
# where the password is fed, so anything that becomes evidence goes through
# this filter first.
run 'printf "%s\n" "#!/bin/bash" "sed \"s|\$(cat \$HOME/.lab-pw)|<lab-password>|g\"" >~/.lab-redact && chmod 700 ~/.lab-redact' >/dev/null
cleanup() { run 'rm -f ~/.lab-pw ~/.lab-sudo ~/.lab-redact' >/dev/null 2>&1; }
trap cleanup EXIT

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

echo "=== Server install acceptance — VM '$vm' — $(date -Is) ==="
echo

check "default target is multi-user.target" \
  'systemctl get-default' '^multi-user\.target$'

check "no sddm/hyprland/pipewire/plymouth installed" \
  'for p in sddm hyprland pipewire plymouth wireplumber uwsm quickshell xdg-desktop-portal-hyprland gnome-keyring; do pacman -Qq "$p" >/dev/null 2>&1 && echo "PRESENT: $p"; done; echo "graphical=$(pacman -Qq | grep -cE "^(sddm|hyprland|pipewire|plymouth|wireplumber|uwsm|quickshell)$")"' \
  'graphical=0'

# The premise of this profile: the base is what a headless machine needs and
# nothing else. Docker in particular is an addon, not part of it.
check "docker is absent from the base" \
  'for p in docker docker-compose docker-buildx ufw-docker lazydocker networkmanager base-devel gcc git tailscale; do pacman -Qq "$p" >/dev/null 2>&1 && echo "PRESENT: $p"; done; echo "extras=$(pacman -Qq | grep -cE "^(docker|networkmanager|gcc|tailscale)$")"' \
  'extras=0'

check "ssh with the cidata key works" \
  'echo "logged in as $(id -un)@$(uname -n) from $SSH_CONNECTION"' 'logged in as'

# The hardening drop-in, tested against the running daemon rather than by
# reading the file: sshd must refuse to even offer password authentication.
check "password authentication is refused" \
  'ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 "$(id -un)@localhost" true 2>&1 | tail -2' \
  'Permission denied \(publickey\)'

# `sshd -T` dumps the effective configuration the daemon would run with, so
# this reads the merged result of the drop-in rather than the file.
check "root cannot log in over ssh" \
  '~/.lab-sudo sshd -T 2>/dev/null | grep -iE "^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|permitemptypasswords) "' \
  '[Pp]ermit[Rr]oot[Ll]ogin no'

# systemd-networkd + systemd-resolved, in place of NetworkManager: the link has
# to come up by DHCP and names have to resolve through the resolved stub.
check "networkd brought the link up by DHCP" \
  'networkctl status --no-pager 2>&1 | sed -n "1,25p"; ip -4 -o addr show scope global | awk "{print \$2, \$4}"' \
  'routable'

check "resolved answers through the stub resolver" \
  'readlink -f /etc/resolv.conf; resolvectl status --no-pager | sed -n "1,12p"; getent hosts archlinux.org | head -1 && echo dns-ok' \
  '^dns-ok$'

# pam_faillock in this profile denies after 10 failures within a 120 s window,
# and `preauth silent` makes a locked account look exactly like a wrong
# password. A previous run that timed out on a sudo prompt leaves failures
# behind, so wait the window out before the first privileged check rather than
# reporting a lockout as a broken password.
wait_out_faillock() {
  local valid attempt
  for attempt in 1 2 3 4 5; do
    valid=$(run 'faillock 2>/dev/null | grep -c " V"' | tr -dc '0-9')
    (( ${valid:-0} < 5 )) && return 0
    echo "waiting out pam_faillock (${valid} recent failures)..." >&2
    sleep 130
  done
}
wait_out_faillock

check "sudo works with the lab password" \
  '~/.lab-sudo id -un' '^root$'

check "ufw is active and rate-limits 22" \
  '~/.lab-sudo ufw status verbose' '22/tcp +LIMIT IN'

# What a port scan finds. Anything but 22 here is surface nobody asked for.
# resolved's stub listeners live on 127.0.0.53/127.0.0.54 and are not reachable
# from off the machine, so they are excluded rather than counted.
check "nothing listens except ssh" \
  '~/.lab-sudo ss -ltnpH | awk "{print \$4}" | grep -v "^127\." | sort -u | tee /dev/stderr | grep -qvE ":22$" && echo unexpected-listener || echo only-ssh' \
  '^only-ssh$'

# The install leaves the factory snapshot as a btrfs subvolume (@factory), not
# as a snapper snapshot: `snapper list` right after an install shows only entry
# 0 on the desktop reference too.
check "factory snapshot exists and snapper is configured" \
  '~/.lab-sudo snapper list; ~/.lab-sudo btrfs subvolume list / | grep -i factory; ~/.lab-sudo ls /etc/snapper/configs/' \
  'factory'

# limine-snapper-sync writes boot entries from snapper snapshots, so there is
# nothing to list until one exists. Create one and check the entries appear.
check "/boot/limine.conf lists snapshot entries once a snapshot exists" \
  '~/.lab-sudo snapper -c root create -d acceptance >/dev/null 2>&1; ~/.lab-sudo systemctl start limine-snapper-sync.service >/dev/null 2>&1; sleep 3; ~/.lab-sudo snapper -c root list | tail -3; ~/.lab-sudo grep -iE "snapshot" /boot/limine.conf | head -6' \
  'Snapshots'

check "pacman -Qq | wc -l in 150-260" \
  'n=$(pacman -Qq | wc -l); echo "packages=$n"; [ "$n" -ge 150 ] && [ "$n" -le 260 ] && echo in-range || echo out-of-range' \
  '^in-range$'

# `expac` is not part of the lean base; sizes come out of pacman's database.
check "installed size and disk used < 3 GB" \
  'LC_ALL=C pacman -Qi | awk "/^Installed Size/ { v=\$4; u=\$5; if (u==\"B\") v/=1048576; if (u==\"KiB\") v/=1024; if (u==\"GiB\") v*=1024; s+=v } END { printf \"installed=%.0f MiB\n\", s }"; used=$(df --output=used -BM / | tail -1 | tr -dc 0-9); echo "used=${used}MiB"; [ "$used" -lt 3072 ] && echo under-3g || echo over-3g' \
  '^under-3g$'

check "boot to ssh under 20 s" \
  'systemd-analyze; t=$(systemd-analyze | sed -n "s/.*= \([0-9.]*\)s.*/\1/p"); awk -v t="$t" "BEGIN{print (t+0<20)?\"under-20s\":\"over-20s\"}"' \
  '^under-20s$'

check "/proc/cmdline has console=ttyS0 and no quiet/splash/resume" \
  'cat /proc/cmdline; grep -q "console=ttyS0" /proc/cmdline && ! grep -qE "quiet|splash|resume=" /proc/cmdline && echo cmdline-ok || echo cmdline-bad' \
  '^cmdline-ok$'

check "zram active" \
  'zramctl; swapon --show' '/dev/zram0'

check "/etc/omarchy-profile is server" \
  'cat /etc/omarchy-profile' '^server$'

check "omarchy-version is 4.0.1-1" \
  'omarchy-version 2>/dev/null' '4\.0\.1-1'

# The addon mechanism, end to end: install the docker addon from the ISO's
# offline mirror and run a container with it. On a VM installed with
# `mkcidata.sh --addons docker` the packages are already there and this only
# re-runs the setup leaf, which is idempotent.
check "omarchy-server-addon docker installs and runs a container" \
  '~/.lab-sudo omarchy-server-addon docker 2>&1 | tail -5; ~/.lab-sudo systemctl start docker.socket; ~/.lab-sudo docker run --rm hello-world 2>&1 | sed -n "/Hello from Docker/,+3p"' \
  'Hello from Docker'

# The addon adds exactly one listener, and it is the reason 20-docker-dns.conf
# is not in the base: systemd-resolved's stub on the docker bridge address,
# which only containers can reach and which the two allow-docker-dns ufw rules
# gate. Anything else appearing here would be a regression.
check "the docker addon opens only the container DNS stub" \
  '~/.lab-sudo ss -ltnpH | awk "{print \$4}" | grep -vE "^127\.|^172\.17\.0\.1:53$" | sort -u | tee /dev/stderr | grep -qvE ":22$" && echo unexpected-listener || echo expected-only; ~/.lab-sudo ufw status | grep -c allow-docker-dns' \
  '^expected-only$'

# omarchy-update is not sudo-less: several of its steps shell out to `sudo`
# and prompt on the terminal, so a plain `</dev/null` run stalls on every one
# of them until sudo times out. Feeding the lab password to the pty `script`
# allocates is what makes an unattended run possible at all — a finding in its
# own right, recorded in the README.
#
# `while cat`, not `while :; do cat`: the feeder has to end when the update
# closes the pipe. With `:` as the condition only the inner cat dies of
# SIGPIPE and the loop spins forever, holding the ssh session open long after
# the update finished.
# The password is fed on stdin and some steps (yay) echo stdin back, so the
# output is redacted before it becomes evidence.
check "omarchy-update runs to completion" \
  'timeout 2400 omarchy-update -y < <(while cat ~/.lab-pw; do sleep 2; done) 2>&1 | tail -40 | ~/.lab-redact; echo "rc=${PIPESTATUS[0]}"' \
  '^rc=0$'

echo "=== $pass passed, $fail failed ==="
