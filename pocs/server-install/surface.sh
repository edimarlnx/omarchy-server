#!/bin/bash
# Measure the attack surface of an installed machine, over ssh.
#
#   ./pocs/server-install/surface.sh [vm-name] [out-file]
#
# The premise of the server profile is that fewer packages mean less surface,
# and a premise that is never measured is a slogan. These are the numbers that
# say whether it held: how much code is installed, how much of it runs, how
# much of it listens, and how much of it is privileged.
#
#   packages          what is installed at all
#   installed size    how much of it there is
#   enabled units     what starts without being asked
#   listening sockets what can be reached from outside the machine
#   setuid/setgid     what an unprivileged local user can use to become root
#   root services     what an exploit in a running daemon gets
#   linux-firmware    the single largest item, called out on its own
#
# Everything runs read-only over ssh with the lab key. Privileged commands go
# through the same ~/.lab-sudo wrapper collect.sh and acceptance.sh use, so the
# lab password never reaches a command line or the output.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
vm="${1:-srv}"
out="${2:-$here/reference/surface.txt}"
lab="$repo_root/pocs/lab/vm.sh"
export LAB_OUT="${LAB_OUT:-$repo_root/pocs/lab/out-server}"
export SSH_USER="${SSH_USER:-omarchy}"

run() { "$lab" "$vm" ssh "$@"; }

# A machine installed from a cidata drive has a lab password; a machine booted
# from the CLOUD IMAGE has none at all, because the image ships no account with
# one and the only account on it was created by cloud-init with NOPASSWD sudo.
# Both get a ~/.lab-sudo that works, and the absence of a password file is a
# property of the machine rather than a broken harness.
if [[ -f $LAB_OUT/lab-password ]]; then
  "$lab" "$vm" ssh 'cat >~/.lab-pw && chmod 600 ~/.lab-pw' <"$LAB_OUT/lab-password"
  run 'printf "%s\n" "#!/bin/bash" "exec sudo -S -p \"\" \"\$@\" <\$HOME/.lab-pw" >~/.lab-sudo && chmod 700 ~/.lab-sudo' >/dev/null
else
  run 'printf "%s\n" "#!/bin/bash" "exec sudo -n \"\$@\"" >~/.lab-sudo && chmod 700 ~/.lab-sudo' >/dev/null
fi
cleanup() { run 'rm -f ~/.lab-pw ~/.lab-sudo' >/dev/null 2>&1 || true; }
trap cleanup EXIT

# `expac` is not part of the lean base, so installed sizes are read out of
# pacman's own database and normalized to MiB here.
read -r -d '' remote <<'REMOTE' || true
set -uo pipefail

size_mib() { # sum "Installed Size" over the package names on stdin
  LC_ALL=C pacman -Qi "$@" 2>/dev/null | awk '
    /^Installed Size/ {
      value = $4; unit = $5
      if (unit == "B")   value /= 1048576
      if (unit == "KiB") value /= 1024
      if (unit == "GiB") value *= 1024
      total += value
    }
    END { printf "%.0f\n", total }'
}

echo "=== packages ==="
echo "installed:  $(pacman -Qq | wc -l)"
echo "explicit:   $(pacman -Qqe | wc -l)"
echo "dependency: $(pacman -Qqd | wc -l)"
echo "installed size (MiB): $(size_mib $(pacman -Qq))"
echo "linux-firmware (MiB): $(size_mib $(pacman -Qq | grep '^linux-firmware') 2>/dev/null || echo 0)"
echo
echo "--- ten biggest packages ---"
LC_ALL=C pacman -Qi | awk '
  /^Name/ { name = $3 }
  /^Installed Size/ {
    value = $4; unit = $5
    if (unit == "B")   value /= 1048576
    if (unit == "KiB") value /= 1024
    if (unit == "GiB") value *= 1024
    printf "%10.1f MiB  %s\n", value, name
  }' | sort -rn | head -10

echo
echo "=== enabled units ==="
mapfile -t enabled < <(systemctl list-unit-files --state=enabled --no-legend | awk '{print $1}')
echo "count: ${#enabled[@]}"
printf '  %s\n' "${enabled[@]}"

echo
echo "=== masked units ==="
mapfile -t masked < <(systemctl list-unit-files --state=masked --no-legend | awk '{print $1}')
echo "count: ${#masked[@]}"
printf '  %s\n' "${masked[@]}"

echo
echo "=== listening sockets ==="
# Every socket the machine answers on, with the process behind it. This is the
# number that decides what a port scan finds.
~/.lab-sudo ss -ltnup
echo "listening tcp+udp: $(~/.lab-sudo ss -ltnupH | wc -l)"

echo
echo "=== setuid / setgid binaries ==="
# -xdev: one filesystem, so bind mounts are not counted twice.
mapfile -t suid < <(~/.lab-sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | sort)
echo "count: ${#suid[@]}"
for path in "${suid[@]}"; do
  printf '  %s  %s\n' "$(~/.lab-sudo stat -c '%A %U:%G' "$path")" "$path"
done

echo
echo "=== services running as root ==="
# Loaded service units with an ExecStart and no User=, i.e. the ones where a
# remote-code-execution bug is immediately root. DynamicUser counts as not
# root: systemd allocates a throwaway uid for those.
root_services=0
while read -r unit; do
  [[ -n $unit ]] || continue
  exec_start=$(systemctl show "$unit" -p ExecStart --value 2>/dev/null)
  [[ -n $exec_start ]] || continue
  user=$(systemctl show "$unit" -p User --value 2>/dev/null)
  dynamic=$(systemctl show "$unit" -p DynamicUser --value 2>/dev/null)
  if [[ -z $user || $user == root ]] && [[ $dynamic != yes ]]; then
    root_services=$((root_services + 1))
    echo "  $unit"
  fi
done < <(systemctl list-units --type=service --state=running --no-legend --plain | awk '{print $1}')
echo "count: $root_services"
REMOTE

echo "> measuring surface of '$vm'"
mkdir -p "$(dirname "$out")"
{
  echo "=== Attack surface — VM '$vm' — $(date -Is) ==="
  echo
  run "bash -s" <<<"$remote"
} >"$out"

echo "surface: $out"
grep -E '^(installed:|installed size|linux-firmware|count:|listening tcp)' "$out" || true
