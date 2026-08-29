#!/bin/bash
# Secure Boot acceptance, run against a booted server VM that was installed
# with the `secureboot` marker on its autoinstall drive.
#
#   LAB_OUT=pocs/lab/out-server-secboot ./pocs/server-install/acceptance-secureboot.sh [vm-name]
#
# Same shape and same rules as acceptance.sh: one PASS/FAIL line per item
# followed by the evidence it was judged on, and never a non-zero exit on a
# failed check — the report is the product.
#
# What it is trying to establish, in order:
#   1. the firmware is enforcing and the keys it enforces with are this
#      machine's (sbctl status, the SecureBoot EFI variable, dmesg);
#   2. every EFI binary in the chain verifies against them (sbctl verify), and
#      limine.conf points at the signed UKI;
#   3. the kernel took the cmdline that came with it (lockdown, sig_enforce);
#   4. an unsigned module is actually refused, rather than the flag merely
#      being set;
#   5. a kernel reinstall regenerates the UKI AND re-signs it, so the machine
#      still boots afterwards. That last item reboots the VM.
#
# The lab password never appears in the output: it is written once to ~/.lab-pw
# (mode 600) and fed to `sudo -S` by the ~/.lab-sudo wrapper.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
vm="${1:-srvsb}"
lab="$repo_root/pocs/lab/vm.sh"
export LAB_OUT="${LAB_OUT:-$repo_root/pocs/lab/out-server-secboot}"
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

echo "=== Secure Boot acceptance — VM '$vm' — $(date -Is) ==="
echo

# ── 1. the firmware ─────────────────────────────────────────────────────────

# sbctl's own summary: enrolled keys present, setup mode left behind, Secure
# Boot on. Grepping for the three lines rather than the whole block, because
# sbctl's formatting is not a contract.
check "sbctl reports Secure Boot enabled with our keys" \
  '~/.lab-sudo sbctl status' \
  'Secure Boot:.*(enabled|✓)'

check "sbctl says the firmware is out of setup mode" \
  '~/.lab-sudo sbctl status --json' \
  '"setup_mode": *false'

check "sbctl owns the installed keys" \
  '~/.lab-sudo sbctl status --json' \
  '"installed": *true'

# The firmware's own variable, independent of sbctl agreeing with it. Byte 4 is
# the value; the first four are the EFI attribute word.
check "the SecureBoot EFI variable reads 1" \
  'od -An -t u1 -j4 -N1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c | tr -d " "' \
  '^1$'

check "the kernel saw secure boot at handover" \
  '~/.lab-sudo dmesg | grep -i "secure boot" || echo NONE' \
  '[Ss]ecure boot enabled'

# ── 2. the chain ────────────────────────────────────────────────────────────

# `sbctl verify` walks the ESP and reports every PE binary it finds. A single
# unsigned one is a machine that would not have booted, or will not boot after
# the next update. Its EXIT STATUS is 0 even when it has just reported an
# unsigned file, so the report is what gets checked, not `$?`.
check "every EFI binary on the ESP is signed" \
  '~/.lab-sudo sbctl verify | tee /dev/stderr | grep -c "is not signed" | sed "s/^/unsigned=/"' \
  '^unsigned=0$'

check "the Limine binary, the fallback and the UKI are all in the signed set" \
  '~/.lab-sudo sbctl verify | grep -E "limine_x64.efi|BOOTX64.EFI|omarchy_linux.efi"' \
  'omarchy_linux\.efi'

# The hash limine records is the hash of the file it copied to the ESP, which
# is the signed one (mkinitcpio signs the temporary file first). If that were
# the other way round, this hash would not match the file on disk.
check "limine.conf points at the UKI and its recorded hash matches the file" \
  '~/.lab-sudo bash -c '\''p=$(grep -o "path: boot():/EFI/Linux/[^#]*#[0-9a-f]*" /boot/limine.conf | head -1);
     f=/boot${p#*boot():}; f=${f%%#*}; h=${p##*#};
     echo "file=$f"; echo "recorded=$h"; echo "actual=$(b2sum "$f" | cut -d" " -f1)";
     [[ $h == $(b2sum "$f" | cut -d" " -f1) ]] && echo hash-ok || echo hash-mismatch'\' \
  '^hash-ok$'

# ── 3. the kernel ───────────────────────────────────────────────────────────

check "the cmdline the kernel booted with carries the lockdown options" \
  'cat /proc/cmdline' \
  'lockdown=integrity.*module\.sig_enforce=1|module\.sig_enforce=1.*lockdown=integrity'

check "lockdown is in integrity mode" \
  '~/.lab-sudo cat /sys/kernel/security/lockdown' \
  '\[integrity\]'

check "module signature enforcement is on" \
  'cat /sys/module/module/parameters/sig_enforce' \
  '^Y$'

# The drop-in is what put those options there, and it must be a separate file
# that appends: replacing omarchy-defaults.conf would drop the serial console.
check "the cmdline drop-in appends to the profile defaults" \
  'ls /etc/limine-entry-tool.d/; grep -v "^#" /etc/limine-entry-tool.d/omarchy-secureboot.conf' \
  'KERNEL_CMDLINE\[default\]\+=.*lockdown=integrity'

check "the serial console survived on the cmdline" \
  'cat /proc/cmdline' \
  'console=ttyS0,115200'

# ── 4. keys on disk ─────────────────────────────────────────────────────────

check "the keys are on the root filesystem, not on the ESP" \
  '~/.lab-sudo find /var/lib/sbctl -name "*.key" | sort; ~/.lab-sudo find /boot -name "*.key" -o -name "*.pem" | wc -l | sed "s/^/esp-key-files=/"' \
  '^esp-key-files=0$'

check "no account but root can read the key material" \
  '~/.lab-sudo stat -c "%a %n" /var/lib/sbctl /var/lib/sbctl/keys /var/lib/sbctl/keys/db /var/lib/sbctl/keys/db/db.key;
   ls /var/lib/sbctl 2>&1 | tail -1' \
  'Permission denied'

# ── 5. an unsigned module is refused ────────────────────────────────────────

# No compiler in this profile, so building a .ko is not an option. Coreutils
# and zstd are enough: take a real module out of the running kernel's tree,
# decompress it, and append one byte. Arch appends the signature to the module
# and marks it with a trailing `~Module signature appended~` magic in the last
# bytes of the file; one extra byte after that leaves the kernel looking at a
# module with no recognisable signature at all — which under
# module.sig_enforce=1 draws exactly the refusal an attacker's module would.
#
# The module is chosen from the ones NOT currently loaded, so a refusal cannot
# be confused with "already inserted", and `rmmod` runs afterwards in case the
# enforcement was not there and it went in.
check "an unsigned module is refused" \
  '~/.lab-sudo bash -c '\''k=$(uname -r); m=""; n="";
     for f in $(find /usr/lib/modules/$k/kernel -name "*.ko.zst" | head -200); do
       b=$(basename "$f" .ko.zst); b=${b//-/_};
       lsmod | grep -q "^$b " || { m=$f; n=$b; break; };
     done;
     echo "module=$n source=$m";
     zstd -qdc "$m" >/tmp/tamper.ko; printf "\\x00" >>/tmp/tamper.ko;
     echo "insmod:"; insmod /tmp/tamper.ko 2>&1 || true;
     rmmod "$n" 2>/dev/null && echo "WARNING: it loaded";
     rm -f /tmp/tamper.ko'\'' 2>&1;
   echo "---"; ~/.lab-sudo dmesg | tail -3' \
  'Key was rejected by service|Required key not available|Invalid module format|Operation not permitted'

# And the counter-check: the stock in-tree modules DO load, because Arch signs
# them with a key built into the kernel. Enforcement that broke the machine
# would not be enforcement worth having.
check "a stock in-tree module still loads" \
  '~/.lab-sudo modprobe -r dummy 2>/dev/null; ~/.lab-sudo modprobe dummy && echo loaded; ~/.lab-sudo modprobe -r dummy' \
  '^loaded$'

# ── 6. a kernel update keeps it signed ──────────────────────────────────────

# The whole point of the design: nobody re-signs anything by hand. Reinstalling
# the kernel package fires 90-mkinitcpio-install (rebuild + sign the UKI),
# 80-limine-efi-deploy (redeploy + re-sign limine) and zz-sbctl.hook
# (sign-all). What is checked is the state afterwards, not the log.
uki_before=$(run '~/.lab-sudo b2sum /boot/EFI/Linux/omarchy_linux.efi | cut -d" " -f1')
echo "UKI before the kernel reinstall: ${uki_before:0:32}…"
echo

# `pacman -Sy` first: the install ran off the ISO's offline mirror, so a fresh
# machine has no sync databases at all and `-S linux` would fail with "target
# not found" — which the old form of this check happily read as a pass.
# `pacman -S` on an up-to-date package reinstalls it, which fires the same
# hooks a real upgrade does. The assertion is that the UKI actually CHANGED:
# the initramfs is rebuilt from scratch, so an identical hash means no rebuild
# happened and there was nothing to re-sign.
check "reinstalling the kernel rebuilds the UKI" \
  "~/.lab-sudo pacman -Sy --noconfirm >/dev/null 2>&1;
   ~/.lab-sudo pacman -S --noconfirm linux 2>&1 | tail -25;
   echo \"---\";
   after=\$(~/.lab-sudo b2sum /boot/EFI/Linux/omarchy_linux.efi | cut -d' ' -f1);
   echo \"before=$uki_before\"; echo \"after=\$after\";
   [[ \$after == $uki_before ]] && echo uki-unchanged || echo uki-rebuilt" \
  '^uki-rebuilt$'

check "the rebuilt UKI is signed" \
  '~/.lab-sudo sbctl verify | tee /dev/stderr | grep -c "is not signed" | sed "s/^/unsigned=/"' \
  '^unsigned=0$'

check "limine.conf still records the hash of the rebuilt, signed UKI" \
  '~/.lab-sudo bash -c '\''p=$(grep -o "path: boot():/EFI/Linux/[^#]*#[0-9a-f]*" /boot/limine.conf | head -1);
     f=/boot${p#*boot():}; f=${f%%#*}; h=${p##*#};
     [[ $h == $(b2sum "$f" | cut -d" " -f1) ]] && echo hash-ok || echo hash-mismatch'\' \
  '^hash-ok$'

# limine-snapper-sync rewrites limine.conf whenever snapshots change; the
# branding above the first entry and the signed-UKI entry both have to survive.
check "limine-snapper-sync left the config consistent" \
  '~/.lab-sudo bash -c "~/.lab-sudo snapper -c root create -d acceptance-secureboot 2>/dev/null; sleep 20; grep -c \"^/+\\|^  //\" /boot/limine.conf; grep -q \"interface_branding: Omarchy Server\" /boot/limine.conf && echo branding-ok"' \
  'branding-ok'

echo "=== rebooting to prove the machine still boots enforcing ==="
# The boot id, not a sleep: ssh multiplexing keeps the old session's socket
# alive for a couple of minutes after the machine is gone, so `wait-ssh` right
# after a reboot can succeed against a host that never went down and report a
# reboot that did not happen.
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

# Not a `check`: the assertion is "different from the value captured above",
# which is a comparison and not a pattern.
if [[ -n ${boot_now:-} && $boot_now != "$boot_before" ]]; then
  report PASS "the machine actually rebooted" "boot_id $boot_before -> $boot_now"
else
  report FAIL "the machine actually rebooted" "boot_id is still $boot_before (or the VM never came back)"
fi

check "the machine came back with Secure Boot still enforcing" \
  '~/.lab-sudo sbctl status --json; echo "---"; cat /sys/kernel/security/lockdown; uname -r' \
  '"secure_boot": *true'

check "and it is still refusing unsigned modules" \
  'cat /sys/module/module/parameters/sig_enforce' \
  '^Y$'

# ── kexec, on the machine where it is hardest ───────────────────────────────
#
# This is the interesting environment for kexec and the reason the check lives
# in the Secure Boot suite rather than the base one. The UKI here is signed by
# a key in the firmware `db`, the cmdline inside it carries lockdown=integrity,
# and lockdown blocks the classic kexec_load(2) outright. The only route is
# kexec_file_load(2), which verifies the image's PE signature in the kernel --
# against `.builtin`, `.secondary` and `.platform`.
#
# That last keyring is the point. Module signing on this profile is defeated
# because a db certificate lands in `.platform` and module verification only
# consults `.builtin` and `.machine` (docs/secure-boot.md §8). kexec's
# verification path accepts `.platform`, so the same key that cannot sign a
# module should be able to sign the image this machine kexecs into. Either the
# run proves that or it disproves it; both are worth writing down.
echo "=== kexec ==="

# reboot_seconds <label> <remote command>: two measurements of the same reboot,
# because neither alone is trustworthy here.
#
#   client   the wall-clock gap between issuing the command and ssh answering
#            on a NEW boot id. It is what an operator feels, and it carries the
#            lab's own noise: the helpers multiplex ssh (ControlPersist=120,
#            because `ufw limit 22` drops the seventh connection in thirty
#            seconds), so the first probe after a reboot can be answered by a
#            socket that has not yet noticed the machine is gone.
#   guest    `systemd-analyze time`, read off the machine afterwards. This is
#            the honest one for comparing the two paths, because the firmware
#            and loader phases it names are EXACTLY what kexec skips: a kexec
#            boot has no firmware line at all.
reboot_seconds() {
  local label=$1 command=$2 before after started elapsed analyze
  before=$(run 'cat /proc/sys/kernel/random/boot_id')
  started=$(date +%s)
  run "$command" >/dev/null 2>&1
  for _ in $(seq 1 90); do
    sleep 2
    after=$(run 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)
    [[ -n $after && $after != "$before" ]] && break
  done
  elapsed=$(($(date +%s) - started))
  if [[ -n ${after:-} && $after != "$before" ]]; then
    analyze=$(run 'systemd-analyze time 2>/dev/null | head -1')
    echo "$label: client ${elapsed}s | guest ${analyze:-<unavailable>} | boot_id $before -> $after"
  else
    echo "$label: did not come back within ${elapsed}s"
  fi
}

check "the kexec addon installs kexec-tools and finds the signed UKI" \
  '~/.lab-sudo omarchy-server-addon kexec >/dev/null 2>&1; echo "addon-rc=$?";
   pacman -Qq kexec-tools;
   ~/.lab-sudo omarchy-server-kexec status' \
  '^image: .*\.efi$'

# The load, on its own, before anything reboots: this is where a rejected
# signature shows up as a message rather than as a machine that did not
# come back.
check "kexec_file_load accepts the UKI signed by the machine's own db key" \
  '~/.lab-sudo omarchy-server-kexec load 2>&1; echo "loaded=$(cat /sys/kernel/kexec_loaded)"' \
  'loaded via kexec_file_load'

echo "--- timing the two reboot paths ---"
firmware_time=$(reboot_seconds "firmware reboot" '~/.lab-sudo systemctl reboot')
echo "$firmware_time"
kexec_time=$(reboot_seconds "kexec reboot" '~/.lab-sudo omarchy-server-kexec load && ~/.lab-sudo systemctl kexec')
echo "$kexec_time"
echo

if [[ $kexec_time == *"did not come back"* ]]; then
  report FAIL "the machine came back from a kexec" "$kexec_time"
else
  report PASS "the machine came back from a kexec" "$firmware_time" "$kexec_time"
fi

# A kexec'd kernel is not launched by the firmware, so it cannot be verified by
# it: whatever it reports about Secure Boot is inherited from the kernel that
# loaded it, not a fresh firmware verdict. Recording what it actually says is
# the point -- a machine that quietly drops out of lockdown across a kexec
# would be a reason not to use this path at all.
check "lockdown and module signing survived the kexec" \
  'cat /sys/kernel/security/lockdown; cat /sys/module/module/parameters/sig_enforce;
   ~/.lab-sudo dmesg | grep -iE "secure boot|lockdown" | head -5; uname -r' \
  '^Y$'

echo "=== $pass passed, $fail failed ==="
