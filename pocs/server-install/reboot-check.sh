#!/bin/bash
# Reboot survival check: the last item of the acceptance list, kept separate
# because it has to run after omarchy-update (which may have replaced the
# kernel and rebuilt the UKI) and because it takes the VM down.
#
#   ./pocs/server-install/reboot-check.sh [vm-name]
#
# Reboots through the installed system's own `systemctl reboot`, waits for ssh
# to answer again, and re-reads the identity and boot facts that must survive.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
vm="${1:-srv}"
lab="$repo_root/pocs/lab/vm.sh"
export LAB_OUT="${LAB_OUT:-$repo_root/pocs/lab/out-server}"
export SSH_USER="${SSH_USER:-omarchy}"

run() { "$lab" "$vm" ssh "$@" 2>&1; }

echo "=== reboot survival — VM '$vm' — $(date -Is) ==="
echo
echo "before:"
run 'uptime -s; uname -r; omarchy-version 2>/dev/null'
boot_before=$(run 'uptime -s')

"$lab" "$vm" ssh 'cat >~/.lab-pw && chmod 600 ~/.lab-pw' <"$LAB_OUT/lab-password"
run 'printf "%s\n" "#!/bin/bash" "exec sudo -S -p \"\" \"\$@\" <\$HOME/.lab-pw" >~/.lab-sudo && chmod 700 ~/.lab-sudo' >/dev/null
echo
echo "rebooting..."
run '~/.lab-sudo systemctl reboot' >/dev/null 2>&1

sleep 10
started=$(date +%s)
# 10s between attempts: `ufw limit 22/tcp` drops a source that opens six
# connections within thirty seconds, so a tighter poll rate-limits itself out.
until "$lab" "$vm" ssh -o ConnectTimeout=3 -o BatchMode=yes 'test -f /etc/omarchy-profile' >/dev/null 2>&1; do
  (( $(date +%s) - started > 300 )) && { echo "FAIL: ssh did not come back within 300 s"; exit 1; }
  sleep 10
done
# The boot timestamp, not the reconnect delay, is the proof: this profile boots
# in under 4 s, so ssh can answer again before a naive timer says anything.
boot_after=$(run 'uptime -s')
if [[ $boot_after != "$boot_before" ]]; then
  echo "rebooted: boot time moved from $boot_before to $boot_after"
else
  echo "FAIL: boot time unchanged ($boot_before) — the machine did not reboot"
fi
echo "ssh answered $(( $(date +%s) - started ))s after the reboot request"
echo
echo "after:"
run 'uptime -s; uname -r; echo "profile: $(cat /etc/omarchy-profile)"; echo "version: $(omarchy-version 2>/dev/null)";
     echo "default target: $(systemctl get-default)"; echo "cmdline: $(cat /proc/cmdline)";
     systemd-analyze; echo "--- failed units ---"; systemctl --failed --no-pager;
     echo "--- firewall ---"; ~/.lab-sudo ufw status | head -6;
     echo "--- listening ---"; ~/.lab-sudo ss -ltnH | awk "{print \$4}" | sort -u'
run 'rm -f ~/.lab-pw ~/.lab-sudo' >/dev/null 2>&1
