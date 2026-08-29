#!/bin/bash
# Collect the artifacts from a running server VM, mirroring what the desktop
# reference install produced, so the two can be compared line by line.
#
#   ./pocs/server-install/collect.sh [vm-name] [out-dir]
#
# Run this BEFORE acceptance.sh: the acceptance list ends with omarchy-update,
# which pulls the online mirrors and changes the package set being recorded.
#
# Everything runs over ssh with the cidata key; nothing is installed in the VM.
# Privileged commands go through the same ~/.lab-sudo wrapper acceptance.sh
# uses, so the lab password never reaches a command line or the output.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
vm="${1:-srv}"
out="${2:-$here/reference}"
lab="$repo_root/pocs/lab/vm.sh"
# The server lab lives in its own out dir (own disk, own cidata ssh key).
export LAB_OUT="${LAB_OUT:-$repo_root/pocs/lab/out-server}"
export SSH_USER="${SSH_USER:-omarchy}"

mkdir -p "$out"
run() { "$lab" "$vm" ssh "$@"; }

"$lab" "$vm" ssh 'cat >~/.lab-pw && chmod 600 ~/.lab-pw' <"$LAB_OUT/lab-password"
run 'printf "%s\n" "#!/bin/bash" "exec sudo -S -p \"\" \"\$@\" <\$HOME/.lab-pw" >~/.lab-sudo && chmod 700 ~/.lab-sudo' >/dev/null
cleanup() { run 'rm -f ~/.lab-pw ~/.lab-sudo' >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "> system"
run 'uname -r; grep -E "^(NAME|PRETTY_NAME|ID)=" /etc/os-release; echo "profile: $(cat /etc/omarchy-profile)";
     echo "omarchy-version: $(omarchy-version 2>/dev/null)";
     echo "--- /usr/share/omarchy ---"; ls /usr/share/omarchy;
     echo "--- $HOME ---"; ls -a ~;
     echo "--- /proc/cmdline ---"; cat /proc/cmdline;
     echo "--- default target ---"; systemctl get-default;
     echo "--- zram/swap ---"; zramctl; swapon --show;
     echo "--- failed units ---"; systemctl --failed --no-pager' >"$out/system.txt"

echo "> packages"
run 'pacman -Qq 2>/dev/null' >"$out/packages-all.txt"
run 'pacman -Qqe 2>/dev/null' >"$out/packages-explicit.txt"
run 'pacman -Qqd 2>/dev/null' >"$out/packages-deps.txt"
# `expac` is not part of the lean base, so sizes come out of pacman's own
# database, normalized to MiB by awk.
size_awk='/^Name/ { name = $3 }
  /^Installed Size/ {
    v = $4; u = $5
    if (u == "B") v /= 1048576; if (u == "KiB") v /= 1024; if (u == "GiB") v *= 1024
    printf "%.2f\t%s\n", v, name
  }'
run "LC_ALL=C pacman -Qi | awk '$size_awk' | sort -rn | head -40" >"$out/packages-biggest.txt"
run "LC_ALL=C pacman -Qi | awk '$size_awk' | awk '{s+=\$1} END {printf \"%.2f MiB total installed\\n\", s}';
     pacman -Qq 2>/dev/null | wc -l | sed 's/\$/ packages/';
     df -h --output=used / | tail -1 | sed 's|^ *|used on /|'" >"$out/size.txt"

echo "> services"
run 'systemctl list-unit-files --state=enabled --no-pager' >"$out/services-enabled.txt"
run 'systemctl list-unit-files --state=masked --no-pager' >"$out/services-masked.txt"
run 'systemctl --user list-unit-files --state=enabled --no-pager 2>&1 || true' >"$out/user-services-enabled.txt"

echo "> boot"
run 'systemd-analyze; echo; systemd-analyze blame | head -25' >"$out/boot-time.txt"
run '~/.lab-sudo ls -la /boot /boot/EFI/BOOT /boot/EFI/Linux /boot/EFI/limine;
     echo "--- /boot/limine.conf ---"; ~/.lab-sudo cat /boot/limine.conf;
     echo "--- /etc/default/limine ---"; ~/.lab-sudo cat /etc/default/limine;
     echo "--- /etc/kernel/cmdline ---"; ~/.lab-sudo cat /etc/kernel/cmdline;
     echo "--- /etc/limine-entry-tool.d ---"; ~/.lab-sudo cat /etc/limine-entry-tool.d/omarchy-defaults.conf;
     echo "--- /etc/mkinitcpio.conf.d ---"; ~/.lab-sudo cat /etc/mkinitcpio.conf.d/omarchy_hooks.conf' >"$out/boot.txt"

echo "> storage"
run 'df -h; echo; findmnt -t btrfs,vfat -o TARGET,SOURCE,FSTYPE,OPTIONS;
     echo; ~/.lab-sudo btrfs subvolume list /;
     echo; ~/.lab-sudo snapper list;
     echo; ~/.lab-sudo ls /etc/snapper/configs/' >"$out/storage.txt"

echo "> firewall"
run '~/.lab-sudo ufw status verbose; echo "--- listening ---"; ~/.lab-sudo ss -ltnup' >"$out/firewall.txt"

echo "> logs"
run 'ls /var/log; echo "--- errors this boot ---"; ~/.lab-sudo journalctl -p err -b --no-pager | tail -40' >"$out/logs.txt"
run '~/.lab-sudo cat /var/log/omarchy-install-timing.json' >"$out/install-timing.json"
run '~/.lab-sudo cat /var/log/omarchy-install.log' >"$out/omarchy-install.log"

echo "> attack surface"
"$here/surface.sh" "$vm" "$out/surface.txt" >/dev/null

echo "> console screenshot"
if shot=$("$lab" "$vm" screenshot 2>/dev/null) && [[ -f $shot ]]; then
  cp "$shot" "$out/console.png"
fi

cp "$LAB_OUT/vm/$vm/serial.log" "$out/serial.log" 2>/dev/null || true

echo "artifacts in $out"
