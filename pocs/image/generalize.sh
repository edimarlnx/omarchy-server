#!/bin/bash
# Strip the identity from an installed lab VM and power it off, leaving a disk
# that can be converted into a shared image.
#
#   ./pocs/image/generalize.sh [vm-name] [build-user]
#
# The work is `omarchy-server-generalize`, which lives in the profile and not
# here: the machine knows where its snapper store, its ESP and its btrfs top
# level are, and an operator who built a golden machine by hand is entitled to
# the same command. This script is the ssh driver around it — stage the sudo
# password, run it, wait for the machine to actually stop.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
vm="${1:-cloudimg}"
build_user="${2:-imgbuild}"
lab="$repo_root/pocs/lab/vm.sh"
export LAB_OUT="${LAB_OUT:-$repo_root/pocs/lab/out-$vm}"
export SSH_USER="${SSH_USER:-$build_user}"

run() { "$lab" "$vm" ssh "$@" 2>&1; }

echo "=== generalize — VM '$vm', build user '$build_user' — $(date -Is) ==="
echo

# Same password path as the acceptance scripts: it travels on stdin, so it is
# never in a command line this script prints or in the VM's shell history.
"$lab" "$vm" ssh 'cat >~/.lab-pw && chmod 600 ~/.lab-pw' <"$LAB_OUT/lab-password" || {
  echo "could not stage the lab password in the VM" >&2
  exit 1
}
run 'printf "%s\n" "#!/bin/bash" "exec sudo -S -p \"\" \"\$@\" <\$HOME/.lab-pw" >~/.lab-sudo && chmod 700 ~/.lab-sudo' >/dev/null

echo "--- before ---"
run 'echo "hostname: $(uname -n)"; echo "machine-id: $(cat /etc/machine-id)";
     echo "host keys: $(ls /etc/ssh/ssh_host_*_key 2>/dev/null | wc -l)";
     echo "users: $(awk -F: "\$3>=1000 && \$3<65534 {print \$1}" /etc/passwd | tr "\n" " ")";
     echo "cache: $(du -sh /var/cache/pacman/pkg 2>/dev/null | cut -f1)";
     echo "root used: $(df -h --output=used / | tail -1 | tr -d " ")"'
echo

# The command detaches its own second phase (it deletes the account this very
# session is logged in as), so ssh returning is not the end of the work. The
# machine stopping is.
echo "--- omarchy-server-generalize ---"
# --remove-all-users, not just the build account: the installer creates an
# `omarchy` owner account nobody asked for, and an earlier build of this
# pipeline shipped it -- locked, homeless, and still an account in a public
# image. The named account stays on the command line so the message says which
# one this session is logged in as.
run "~/.lab-sudo omarchy-server-generalize --yes --remove-user $build_user --remove-all-users --poweroff"
echo

echo "waiting for the machine to power off..."
started=$(date +%s)
while "$lab" "$vm" status | grep -q '^running'; do
  if (($(date +%s) - started > 300)); then
    echo "FAIL: the VM was still running 300 s after the generalize request" >&2
    exit 1
  fi
  sleep 5
done
echo "powered off after $(($(date +%s) - started))s"
