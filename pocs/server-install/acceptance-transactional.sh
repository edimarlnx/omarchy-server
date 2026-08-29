#!/bin/bash
# Transactional-update acceptance, run against a booted server VM.
#
#   LAB_OUT=pocs/lab/out-srvsb ./pocs/server-install/acceptance-transactional.sh [vm-name]
#
# Same shape and same rules as acceptance.sh: one PASS/FAIL line per item
# followed by the evidence it was judged on, and never a non-zero exit on a
# failed check — the report is the product.
#
# What it is trying to establish, in order:
#   1. the mode is a setting, not a code path only reachable by hand;
#   2. a transaction that changes userspace leaves the RUNNING root untouched
#      until the reboot, and the machine comes back with the change;
#   3. a transaction that reinstalls the kernel does the same, with the UKI
#      rebuilt and re-signed and Secure Boot still enforcing afterwards;
#   4. a transaction that FAILS costs nothing: no subvolume left behind, no
#      package installed, the ESP byte for byte what it was;
#   5. rollback puts the previous root back and the machine boots it.
#
# The machine is rebooted three times by this suite, which is the point: a
# transaction is only real once the machine has come up on the other side.
#
# The lab password never appears in the output: it is written once to ~/.lab-pw
# (mode 600) and fed to `sudo -S` by the ~/.lab-sudo wrapper.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
vm="${1:-srvsb}"
lab="$repo_root/pocs/lab/vm.sh"
export LAB_OUT="${LAB_OUT:-$repo_root/pocs/lab/out-srvsb}"
export SSH_USER="${SSH_USER:-omarchy}"

run() { "$lab" "$vm" ssh "$@" 2>&1; }

"$lab" "$vm" ssh 'cat >~/.lab-pw && chmod 600 ~/.lab-pw' <"$LAB_OUT/lab-password" || {
  echo "could not stage the lab password in the VM" >&2
  exit 1
}
run 'printf "%s\n" "#!/bin/bash" "exec sudo -S -p \"\" \"\$@\" <\$HOME/.lab-pw" >~/.lab-sudo && chmod 700 ~/.lab-sudo' >/dev/null
cleanup() { run 'rm -f ~/.lab-pw ~/.lab-sudo' >/dev/null 2>&1; }
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

# The boot id, not a sleep: ssh multiplexing keeps the old session's socket
# alive for a couple of minutes after the machine is gone, so polling right
# after a reboot can succeed against a host that never went down and report a
# reboot that did not happen.
reboot_and_wait() { # reboot_and_wait <label> <remote command that reboots>
  local label=$1 command=$2 before now started elapsed
  before=$(run 'cat /proc/sys/kernel/random/boot_id')
  started=$(date +%s)
  run "$command" >/dev/null 2>&1
  for _ in $(seq 1 60); do
    sleep 10
    now=$(run 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)
    [[ -n $now && $now != "$before" ]] && break
  done
  elapsed=$(($(date +%s) - started))
  if [[ -n ${now:-} && $now != "$before" ]]; then
    report PASS "$label" "boot_id $before -> $now" "round trip ${elapsed}s"
  else
    report FAIL "$label" "boot_id is still $before (or the VM never came back)"
  fi
}

echo "=== Transactional update acceptance — VM '$vm' — $(date -Is) ==="
echo

# ── 1. the mode is configuration ────────────────────────────────────────────

check "the transaction command is installed and owned by the runtime package" \
  '~/.lab-sudo pacman -Qo /usr/bin/omarchy-server-transaction' \
  'owned by omarchy-server'

check "the mode defaults to in-place" \
  '~/.lab-sudo omarchy-server-update transactional status' \
  '^transactional=0$'

check "turning it on writes the config the timer reads" \
  '~/.lab-sudo omarchy-server-update transactional on; ~/.lab-sudo cat /etc/omarchy-server-update.conf' \
  '^TRANSACTIONAL=1$'

# The two toggles live in the same file and are set by two different commands;
# a whole-file rewrite would drop whichever was set first.
check "the kexec toggle and the mode toggle coexist in the config" \
  '~/.lab-sudo omarchy-server-update kexec on >/dev/null; ~/.lab-sudo omarchy-server-update transactional on >/dev/null;
   ~/.lab-sudo cat /etc/omarchy-server-update.conf;
   ~/.lab-sudo grep -c "^KEXEC=1$|^TRANSACTIONAL=1$" -E /etc/omarchy-server-update.conf | sed "s/^/both=/";
   ~/.lab-sudo omarchy-server-update kexec off >/dev/null' \
  '^both=2$'

# The timer's ExecStart is the same entry point a person runs, so the setting
# above is what an unattended run reads too. If this were a separate command,
# turning the mode on by hand would leave the timer updating in place.
check "the unattended timer runs the entry point that reads the mode" \
  'systemctl cat omarchy-server-update.service | grep ExecStart' \
  'ExecStart=/usr/bin/omarchy-server-update run$'

check "the machine starts on @, with no transaction recorded" \
  '~/.lab-sudo omarchy-server-transaction status' \
  'root subvolume: /@$'

# ── 2. a userspace transaction ──────────────────────────────────────────────

# Through omarchy-server-update and not the transaction command directly: the
# --transactional flag has to reach the mode, and the run has to end WITHOUT
# the in-place restart classifier having anything to say. The machine has
# nothing to upgrade, which is exactly the shape that proves the routing: it
# still builds a transaction, swaps it in and never mentions a restart.
check "omarchy-server-update --transactional routes to a transaction, with no restart classifier" \
  "~/.lab-sudo omarchy-server-update --transactional run --no-reboot 2>&1 | tee /dev/stderr |
     grep -cE '^(restarted|deferred|reboot required):' | sed 's/^/classifier-lines=/'" \
  '^classifier-lines=0$'

# Back to @ without a reboot, so the substantive transaction below starts from
# the same shape every other one does.
run '~/.lab-sudo omarchy-server-transaction rollback --no-reboot; ~/.lab-sudo omarchy-server-transaction prune --keep 0' >/dev/null

used_before=$(run '~/.lab-sudo btrfs filesystem usage -b / | awk "/^[[:space:]]*Used:/ {print \$2; exit}"')
echo "filesystem Used before the userspace transaction: ${used_before:-?} bytes"
echo

check "a transaction that installs a package leaves the live root untouched" \
  "~/.lab-sudo bash -c 'time omarchy-server-transaction run --with tree --no-reboot' 2>&1 | tail -20;
   echo '--- live root:'; pacman -Q tree 2>&1" \
  "error: package 'tree' was not found"

check "the swap happened: @ is the new root and the old one is kept" \
  '~/.lab-sudo omarchy-server-transaction status' \
  '@prev-[0-9]+'

check "the machine is still running the OLD root and says so" \
  '~/.lab-sudo omarchy-server-transaction status' \
  'running /@prev-[0-9]+, not @'

used_after=$(run '~/.lab-sudo btrfs filesystem usage -b / | awk "/^[[:space:]]*Used:/ {print \$2; exit}"')
if [[ -n ${used_before:-} && -n ${used_after:-} ]]; then
  report PASS "the cost of the transaction is measured" \
    "Used before: $used_before bytes" \
    "Used after:  $used_after bytes" \
    "delta:       $((used_after - used_before)) bytes ($(((used_after - used_before) / 1024 / 1024)) MiB)"
fi

reboot_and_wait "the machine reboots into the new root" '~/.lab-sudo systemctl reboot'

check "after the reboot the root subvolume is @ again" \
  '~/.lab-sudo omarchy-server-transaction status' \
  'root subvolume: /@$'

check "and the package the transaction installed is there" \
  'pacman -Q tree' \
  '^tree '

check "the snapper snapshot taken before the transaction is in the record" \
  '~/.lab-sudo snapper -c root list' \
  '^[1-9][0-9]* '

check "the machine is reachable, firewalled and running its services" \
  'systemctl is-system-running; ~/.lab-sudo ufw status | head -3; systemctl is-active sshd' \
  '^active$'

# ── 3. a kernel transaction ─────────────────────────────────────────────────

uki_before=$(run '~/.lab-sudo b2sum /boot/EFI/Linux/omarchy_linux.efi | cut -d" " -f1')
echo "UKI before the kernel transaction: ${uki_before:0:32}…"
echo

check "a transaction that reinstalls the kernel rebuilds and re-signs the UKI" \
  "~/.lab-sudo omarchy-server-transaction run --with linux --no-reboot 2>&1 | tail -15;
   echo '---';
   after=\$(~/.lab-sudo b2sum /boot/EFI/Linux/omarchy_linux.efi | cut -d' ' -f1);
   echo \"before=$uki_before\"; echo \"after=\$after\";
   [[ \$after == $uki_before ]] && echo uki-unchanged || echo uki-rebuilt" \
  '^uki-rebuilt$'

# The signing happened inside the chroot, with the sbctl keys that live on the
# snapshot's /var/lib/sbctl and an ESP that is the same partition either side.
check "the UKI the transaction wrote is signed by this machine's key" \
  '~/.lab-sudo sbctl verify | tee /dev/stderr | grep -c "is not signed" | sed "s/^/unsigned=/"' \
  '^unsigned=0$'

check "limine.conf records the hash of the signed UKI the transaction wrote" \
  '~/.lab-sudo bash -c '\''p=$(grep -o "path: boot():/EFI/Linux/[^#]*#[0-9a-f]*" /boot/limine.conf | head -1);
     f=/boot${p#*boot():}; f=${f%%#*}; h=${p##*#};
     [[ $h == $(b2sum "$f" | cut -d" " -f1) ]] && echo hash-ok || echo hash-mismatch'\' \
  '^hash-ok$'

reboot_and_wait "the machine reboots into the kernel the transaction built" '~/.lab-sudo systemctl reboot'

check "Secure Boot is still enforcing after a transactional kernel change" \
  '~/.lab-sudo sbctl status --json; echo "---"; ~/.lab-sudo cat /sys/kernel/security/lockdown; uname -r' \
  '"secure_boot": *true'

check "module signature enforcement survived it" \
  'cat /sys/module/module/parameters/sig_enforce' \
  '^Y$'

check "the cmdline is byte for byte the one the machine has always booted" \
  'cat /proc/cmdline' \
  'rootflags=subvol=@ .*lockdown=integrity.*console=ttyS0,115200'

# ── 4. a failed transaction costs nothing ───────────────────────────────────
#
# The failure is injected where it does the most damage: a pacman hook on the
# LIVE root, which the snapshot therefore carries into the transaction, so the
# package manager fails part-way through a real transaction rather than before
# it starts. The hook is removed again afterwards.

uki_intact=$(run '~/.lab-sudo b2sum /boot/EFI/Linux/omarchy_linux.efi | cut -d" " -f1')

check "a transaction whose hook fails leaves nothing behind" \
  "~/.lab-sudo bash -c 'install -d /etc/pacman.d/hooks; cat >/etc/pacman.d/hooks/00-acceptance-fail.hook <<HOOK
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = *

[Action]
Description = Failing on purpose, for the transactional acceptance run
When = PreTransaction
Exec = /usr/bin/false
AbortOnFail
HOOK'
   ~/.lab-sudo omarchy-server-transaction run --with cowsay --no-reboot 2>&1 | tail -12;
   echo \"exit=\${PIPESTATUS[0]}\";
   ~/.lab-sudo rm -f /etc/pacman.d/hooks/00-acceptance-fail.hook" \
  'The running system was not modified'

check "no transaction subvolume survived the failure" \
  '~/.lab-sudo omarchy-server-transaction status' \
  'root subvolume: /@$'

check "the failed package is not installed on the live root" \
  'pacman -Q cowsay 2>&1' \
  'was not found'

check "the ESP is byte for byte what it was before the failed transaction" \
  "after=\$(~/.lab-sudo b2sum /boot/EFI/Linux/omarchy_linux.efi | cut -d' ' -f1);
   echo \"before=$uki_intact\"; echo \"after=\$after\";
   [[ \$after == $uki_intact ]] && echo esp-unchanged || echo esp-changed" \
  '^esp-unchanged$'

check "the machine is still healthy after the failed transaction" \
  'systemctl is-system-running; systemctl is-active sshd; uname -r' \
  '^active$'

# ── 5. rollback ─────────────────────────────────────────────────────────────

check "there is a previous root to roll back to" \
  '~/.lab-sudo omarchy-server-transaction status' \
  '@prev-[0-9]+'

reboot_and_wait "rollback swaps the previous root back in and reboots" \
  '~/.lab-sudo omarchy-server-update rollback'

check "the machine is running @ again, and the failed root is kept as @failed-*" \
  '~/.lab-sudo omarchy-server-transaction status' \
  '@failed-[0-9]+'

# The rollback undoes the kernel transaction, which is the hard case: the UKI
# on the shared ESP belonged to the root that was just rolled away.
check "the rolled-back root boots, with Secure Boot still enforcing" \
  '~/.lab-sudo sbctl status --json; uname -r; cat /sys/module/module/parameters/sig_enforce' \
  '"secure_boot": *true'

check "the machine is reachable and its services are up after the rollback" \
  'systemctl is-system-running; systemctl is-active sshd; ~/.lab-sudo ufw status | head -2' \
  '^active$'

check "pruning removes the roots beyond the keep count" \
  '~/.lab-sudo omarchy-server-transaction prune --keep 0; ~/.lab-sudo omarchy-server-transaction status' \
  'kept the 0 most recent'

# Leave the machine as it was found.
run '~/.lab-sudo omarchy-server-update transactional off' >/dev/null

echo "=== $pass passed, $fail failed ==="
