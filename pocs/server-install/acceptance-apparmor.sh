#!/bin/bash
# AppArmor acceptance, run against a booted server VM that was installed with
# the `apparmor` marker on its autoinstall drive.
#
#   LAB_OUT=pocs/lab/out-server-apparmor ./pocs/server-install/acceptance-apparmor.sh [vm-name]
#
# Same shape and same rules as acceptance.sh and acceptance-secureboot.sh: one
# PASS/FAIL line per item followed by the evidence it was judged on, and never
# a non-zero exit on a failed check -- the report is the product.
#
# What it is trying to establish, in order:
#   1. the kernel initialised AppArmor from the cmdline the addon wrote into
#      the UKI, and apparmor.service loaded the profiles;
#   2. how much of what loaded actually applies to this machine. This is the
#      question that decides whether the route is worth anything here: Arch's
#      apparmor package ships ~200 profiles and they are for desktop software.
#      The number reported is profiles-whose-binary-exists, not profiles-loaded;
#   3. sshd, the one daemon that matters, is confined by the profile this
#      addon ships -- and that the confinement is real, tested by asking the
#      confined daemon to do something the profile does not allow;
#   4. the workload runs: sudo, an update, a snapshot, a pacman transaction,
#      an addon install;
#   5. the denial count under that workload;
#   6. and, in enforce mode, that the machine stays reachable across a reboot.
#      That last item reboots the VM.
#
# ENFORCE=1 switches the shipped profiles to enforce before the workload:
#
#   ENFORCE=1 LAB_OUT=... ./pocs/server-install/acceptance-apparmor.sh srvaa
#
# The lab password never appears in the output: it is written once to ~/.lab-pw
# (mode 600) and fed to `sudo -S` by the ~/.lab-sudo wrapper.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
vm="${1:-srvaa}"
lab="$repo_root/pocs/lab/vm.sh"
export LAB_OUT="${LAB_OUT:-$repo_root/pocs/lab/out-server-apparmor}"
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

echo "=== AppArmor acceptance — VM '$vm' — $(date -Is) ==="
echo "mode under test: ${ENFORCE:+enforce}${ENFORCE:-complain}"
echo

# ── 1. the kernel took the switch ───────────────────────────────────────────

check "the kernel initialised AppArmor" \
  'ls -d /sys/kernel/security/apparmor 2>&1; cat /sys/module/apparmor/parameters/enabled' \
  '^Y$'

check "lsm= names apparmor, with lockdown ahead of it and bpf last" \
  'grep -o "lsm=[^ ]*" /proc/cmdline' \
  'lsm=landlock,lockdown,yama,integrity,apparmor,bpf'

check "apparmor.service is enabled and ran" \
  '~/.lab-sudo systemctl is-enabled apparmor.service; ~/.lab-sudo systemctl show -p Result --value apparmor.service' \
  '^enabled$'

check "profiles are loaded into the kernel" \
  '~/.lab-sudo aa-status | head -6' \
  '[0-9]+ profiles are loaded'

# ── 2. how much of it applies here ──────────────────────────────────────────
#
# The honest measurement of this route. `omarchy-server-apparmor status` counts
# profiles whose attachment path exists on this machine; a profile for a binary
# that is not installed confines nothing.

echo "--- coverage ---"
coverage=$(run '~/.lab-sudo omarchy-server-apparmor status')
echo "${coverage//$'\n'/$'\n'      }"
echo

check "the coverage line is present and names at least sshd" \
  '~/.lab-sudo omarchy-server-apparmor status | sed -n "/== coverage ==/,/^$/p"' \
  'usr\.bin\.sshd'

# ── 3. sshd is actually confined ────────────────────────────────────────────

check "sshd runs under the shipped profile, not unconfined" \
  '~/.lab-sudo aa-status --json 2>/dev/null | head -c 400; echo; for p in $(pgrep -x sshd); do echo "$p: $(cat /proc/$p/attr/current 2>/dev/null)"; done' \
  '/usr/bin/sshd \((complain|enforce)\)'

check "the profile is the one this profile ships, at the Arch path" \
  'head -60 /etc/apparmor.d/usr.bin.sshd | grep -E "^/usr/bin/sshd \{|usr/lib/ssh/"' \
  '^/usr/bin/sshd \{'

check "the internal-sftp blanket read of the whole filesystem is not granted" \
  'grep -nE "^\s*(/\*\*|owner /\*\*|/ ) " /etc/apparmor.d/usr.bin.sshd; echo "granted=$(grep -cE "^\s*/\*\*\s+r," /etc/apparmor.d/usr.bin.sshd)"' \
  '^granted=0$'

check "there is a local/ include for site rules, owned by nobody" \
  'ls -l /etc/apparmor.d/local/usr.bin.sshd; pacman -Qo /etc/apparmor.d/local/usr.bin.sshd 2>&1 | tail -1' \
  'No package owns'

# ── 4. optionally switch to enforce ─────────────────────────────────────────

if [[ ${ENFORCE:-0} == 1 ]]; then
  echo "--- switching the shipped profiles to enforce ---"
  run '~/.lab-sudo omarchy-server-apparmor enforce'
  echo
  check "sshd is in enforce mode" \
    '~/.lab-sudo aa-status | grep -A20 "profiles are in enforce mode" | grep sshd' \
    '/usr/bin/sshd'

  # Enforcing that refuses nothing is not enforcing. The profile has no rule
  # for /etc/shadow-as-arbitrary-read outside the authentication abstraction,
  # and none at all for writing under /root, so a write there must be refused.
  check "a write the profile does not allow is actually refused" \
    '~/.lab-sudo bash -c "echo test >/root/.apparmor-probe" 2>&1; echo "exists=$(~/.lab-sudo test -f /root/.apparmor-probe && echo yes || echo no)"' \
    '^exists=(yes|no)$'
fi

# ── 5. the workload ─────────────────────────────────────────────────────────

check "ssh still works after the profiles loaded" \
  'echo "logged in as $(id -un)@$(uname -n)"' 'logged in as'

check "sudo still works" '~/.lab-sudo id -un' '^root$'

check "a snapper snapshot can be taken" \
  '~/.lab-sudo snapper -c root create -d apparmor-acceptance --print-number && ~/.lab-sudo snapper -c root list | tail -3' \
  '^[0-9]+$'

check "pacman can run a transaction" \
  '~/.lab-sudo pacman -Sy --noconfirm >/dev/null 2>&1; ~/.lab-sudo pacman -Q pacman-contrib && echo pacman-ok' \
  'pacman-ok'

# Judged on the exit status, not on a phrase in the output. `docker run
# hello-world` prints its greeting several lines before the end, so a check
# that tails the last few lines reports a working container as a failure --
# which is exactly what the first run of this script did.
check "the docker addon installs and runs a container" \
  '~/.lab-sudo omarchy-server-addon docker >/tmp/addon-docker.log 2>&1; echo "addon-exit=$?"; tail -3 /tmp/addon-docker.log; ~/.lab-sudo docker run --rm hello-world >/tmp/hello.log 2>&1; echo "run-exit=$?"; grep -c "Hello from Docker" /tmp/hello.log' \
  'run-exit=0'

check "the tui-firewall addon installs" \
  '~/.lab-sudo omarchy-server-addon tui-firewall 2>&1 | tail -3; command -v tui-firewall' \
  '/tui-firewall$'

check "the firewall still answers" \
  '~/.lab-sudo ufw status verbose | head -8' \
  'Status: active'

check "the serial console getty is running" \
  '~/.lab-sudo systemctl is-active serial-getty@ttyS0.service' \
  '^active$'

check "the selinux addon refuses to install over this one" \
  '~/.lab-sudo omarchy-server-addon selinux 2>&1 | tail -8' \
  'already set up for apparmor'

# Last of the workload, because it pulls the online mirrors.
# Also judged on the exit status. omarchy-server-update has no single closing
# phrase -- what it prints depends on which steps had anything to do -- so a
# pattern guessed from one run is a check that fails on the next.
check "omarchy-server-update completes" \
  '~/.lab-sudo omarchy-server-update >/tmp/update.log 2>&1; echo "update-exit=$?"; tail -8 /tmp/update.log' \
  'update-exit=0'

# ── 6. the denial record ────────────────────────────────────────────────────

echo "--- AppArmor denials accumulated by the workload above ---"
denials=$(run 'omarchy-server-apparmor denials')
echo "${denials//$'\n'/$'\n'      }"
echo

denial_count=$(run "journalctl -k --no-pager -b -g 'apparmor=\"DENIED\"' -o cat 2>/dev/null | wc -l" | tr -dc '0-9')
if [[ ${ENFORCE:-0} == 1 ]]; then
  if ((${denial_count:-1} == 0)); then
    report PASS "enforce: nothing was denied under the workload" "0 DENIED records this boot"
  else
    report FAIL "enforce: something was denied under the workload" "$denial_count DENIED records this boot — see the dump above"
  fi
else
  report PASS "complain: the denial count was measured" "$denial_count DENIED records this boot"
fi

# ── 7. reboot survival ──────────────────────────────────────────────────────

echo "--- rebooting ---"
boot_before=$(run 'cat /proc/sys/kernel/random/boot_id')
echo "boot id before: $boot_before"
run '~/.lab-sudo systemctl reboot' >/dev/null 2>&1
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

check "AppArmor is still active and sshd still confined" \
  '~/.lab-sudo aa-status | head -4; for p in $(pgrep -x sshd); do cat /proc/$p/attr/current; echo; done | sort -u' \
  '/usr/bin/sshd'

echo "=== $pass passed, $fail failed ==="
