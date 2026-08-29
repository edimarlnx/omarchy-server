#!/bin/bash
# SELinux acceptance, run against a booted server VM that was installed with
# the `selinux` marker on its autoinstall drive.
#
#   LAB_OUT=pocs/lab/out-server-selinux ./pocs/server-install/acceptance-selinux.sh [vm-name]
#
# Same shape and same rules as acceptance.sh and acceptance-secureboot.sh: one
# PASS/FAIL line per item followed by the evidence it was judged on, and never
# a non-zero exit on a failed check -- the report is the product.
#
# What it is trying to establish, in order:
#   1. the kernel initialised SELinux at all, from the cmdline the addon wrote
#      into the UKI (selinuxfs, /proc/cmdline, sestatus);
#   2. the policy is the one this profile ships, with the local module in it;
#   3. the userland is the rebuilt one: the binaries that had to link
#      libselinux do, and the stock packages are gone;
#   4. processes are actually in domains -- init, sshd, the login session --
#      rather than all sharing one label because nothing transitions;
#  4b. the operator has an administrative role: the login is confined as
#      staff_t and sudo reaches sysadm_t. Without it, enforcing is a machine
#      that cannot be administered and cannot be switched back over ssh;
#   5. the filesystem is labelled, rather than a sea of unlabeled_t;
#   6. the workload runs: sudo, an update (by hand and under its unit), a
#      snapshot, a pacman transaction, an addon install, a serial login;
#   7. the denial count under that workload, which is the number that decides
#      whether enforcing is reachable;
#   8. and, when the machine is in enforcing, that it stays reachable across a
#      reboot. That last item reboots the VM.
#
# ENFORCE=1 switches the machine to enforcing before the workload, which is how
# the second half of the measurement is taken:
#
#   ENFORCE=1 LAB_OUT=... ./pocs/server-install/acceptance-selinux.sh srvsel
#
# The lab password never appears in the output: it is written once to ~/.lab-pw
# (mode 600) and read from there by the ~/.lab-sudo wrapper.
#
# The wrapper authenticates and runs the command as two separate sudo calls,
# and that is not a style choice. A single `sudo -S "$@" <~/.lab-pw` leaves
# every privileged command with its stdin still pointing at the password file,
# so the command inherits it and reads it -- measured, under the administrative
# role, as
#
#   avc: denied { read } comm="iptables" path="/home/omarchy/.lab-pw"
#         scontext=...:iptables_t tcontext=...:user_home_t
#
# a denial the harness caused and the profile would then be blamed for. `sudo -v`
# takes the password and only refreshes the credential cache; the `sudo -n` that
# follows runs the command with a clean </dev/null.
#
# SUDO_ASKPASS is not an option here: sudo would have to exec the helper, and a
# helper in the operator's home directory is user_home_t, which the sudo domain
# is quite rightly not allowed to execute.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
vm="${1:-srvsel}"
lab="$repo_root/pocs/lab/vm.sh"
export LAB_OUT="${LAB_OUT:-$repo_root/pocs/lab/out-server-selinux}"
export SSH_USER="${SSH_USER:-omarchy}"

run() { "$lab" "$vm" ssh "$@" 2>&1; }

"$lab" "$vm" ssh 'cat >~/.lab-pw && chmod 600 ~/.lab-pw' <"$LAB_OUT/lab-password" || {
  echo "could not stage the lab password in the VM" >&2
  exit 1
}
run 'printf "%s\n" "#!/bin/bash" "sudo -S -p \"\" -v <\$HOME/.lab-pw" "sudo -n \"\$@\" </dev/null" >~/.lab-sudo && chmod 700 ~/.lab-sudo' >/dev/null
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

echo "=== SELinux acceptance — VM '$vm' — $(date -Is) ==="
echo "mode under test: ${ENFORCE:+enforcing}${ENFORCE:-permissive}"
echo

# ── 1. the kernel took the switch ───────────────────────────────────────────

check "the kernel initialised SELinux" \
  'ls -d /sys/fs/selinux 2>&1; grep -o "lsm=[^ ]*" /proc/cmdline' \
  '^/sys/fs/selinux$'

check "lsm= names selinux, with lockdown ahead of it and bpf last" \
  'grep -o "lsm=[^ ]*" /proc/cmdline' \
  'lsm=landlock,lockdown,yama,integrity,selinux,bpf'

check "the cmdline came from inside the UKI, not from limine.conf" \
  '~/.lab-sudo grep -c "lsm=" /boot/limine.conf 2>/dev/null; echo "in-cmdline=$(grep -c "lsm=landlock" /proc/cmdline)"' \
  '^in-cmdline=1$'

# ── 2. the policy ───────────────────────────────────────────────────────────

check "the refpolicy-arch policy is loaded" \
  'sestatus' \
  'Loaded policy name: *refpolicy-arch'

check "/etc/selinux/config says what the addon wrote" \
  'grep -E "^(SELINUX|SELINUXTYPE)=" /etc/selinux/config; readlink -f /etc/selinux/config' \
  'SELINUXTYPE=refpolicy-arch'

# The profile's local file context, and where it now lives. `semanage` moved to
# the `selinux-tools` addon together with setools and 453 MiB of scientific
# Python, so a correctly configured machine does not have it; the addon writes
# the same file semanage would write, at the path libselinux looks for it.
# Asserting on the file rather than on the tool is the point of the split.
check "the profile's own file contexts are in the policy store" \
  '~/.lab-sudo cat /etc/selinux/refpolicy-arch/contexts/files/file_contexts.local' \
  '/usr/share/omarchy/bin.*bin_t'

check "and they are what the profile's commands actually carry" \
  'ls -Z /usr/share/omarchy/bin/omarchy-server-update' \
  ':bin_t'

# The split is only honest if the base addon really did leave the heavy tools
# out. 45 packages and 453 MiB is the whole reason it exists.
check "the base selinux addon did NOT pull setools or selinux-python in" \
  'pacman -Qq setools selinux-python python-networkx python-scipy python-pandas 2>&1 | sort -u' \
  'was not found'

check "and the policy tools are offered as their own addon" \
  'omarchy-server-addon --list | grep -E "^selinux"' \
  'selinux-tools'

# ── 3. the rebuilt userland ─────────────────────────────────────────────────

# The point of the whole rebuild set. A binary that cannot reach libselinux
# cannot read or set a context, whatever the kernel is doing -- so this is the
# check that separates "SELinux is on" from "SELinux does something".
#
# Two ways of reaching it count, and the distinction is not pedantry: modern
# systemd does not link libselinux at all, it dlopen()s it, so `ldd` reports
# nothing and the support is there. OpenSSH 9.8+ split the daemon, and the
# setexeccon() call lives in sshd-session, not in the sshd listener.
#
# Not a `check`: the assertion is "nothing in the list is out", which is the
# absence of a pattern rather than its presence.
linkage=$(run 'for b in /usr/lib/systemd/systemd /usr/bin/ls /usr/bin/id /usr/bin/sudo \
    /usr/lib/ssh/sshd-session /usr/bin/useradd /usr/bin/mount \
    /usr/lib/security/pam_selinux.so; do
    printf "%-40s " "$b"
    if readelf -d "$b" 2>/dev/null | grep -q "NEEDED.*libselinux"; then echo linked
    elif strings "$b" 2>/dev/null | grep -q "libselinux\\.so"; then echo dlopen
    else echo "NO SELINUX"; fi
  done')
if grep -q 'NO SELINUX' <<<"$linkage"; then
  report FAIL "every binary that needs libselinux reaches it" "${linkage//$'\n'/$'\n'      }"
else
  report PASS "every binary that needs libselinux reaches it" "${linkage//$'\n'/$'\n'      }"
fi

check "the stock packages were replaced, not installed alongside" \
  'pacman -Qq | grep -E "^(systemd|coreutils|util-linux|shadow|sudo|openssh|pam|pambase)(-selinux)?$" | sort' \
  'systemd-selinux'

check "openssh was not downgraded by the rebuild" \
  'pacman -Q openssh-selinux; sshd -V 2>&1 | head -1' \
  'openssh-selinux 10\.[5-9]'

# ── 4. processes are in domains ─────────────────────────────────────────────

# procps-ng on Arch is not built against libselinux, so `ps -Z` does not exist;
# the kernel exports the same thing per process.
# init_t, not kernel_t, and the difference is a measurement rather than a
# detail. PID 1 transitions to init_t at exec only if /usr/lib/systemd/systemd
# already carries init_exec_t. On the FIRST boot of a fresh install it does
# not: the offline relabel could not label what the orchestrator had not
# written yet, and omarchy-server-selinux-relabel.service fixes the labels
# after PID 1 has already started. So boot 1 leaves init in kernel_t and boot 2
# has it in init_t -- which is why this profile reboots once after the
# first-boot relabel before anyone considers enforcing, and why
# `omarchy-server-selinux enforcing` refuses while init is still kernel_t.
# Through sudo, and that is not laziness: in enforcing a confined user domain
# may not read another domain's attr file, which is the policy working. The
# administrative domain may (`allow sysadm_t domain:file read`), so the
# question is asked from there.
check "init runs in a domain of its own" \
  '~/.lab-sudo sh -c "tr -d \"\\0\" </proc/1/attr/current"' \
  'init_t'

check "sshd runs in a domain of its own" \
  '~/.lab-sudo sh -c "for p in \$(pgrep -x sshd); do tr -d \"\\0\" </proc/\$p/attr/current; echo; done | sort -u"' \
  'sshd_t'

check "the ssh session is not simply sshd's own context" \
  'id -Z; echo "---"; tr -d "\0" </proc/$$/attr/current' \
  '_u:[a-z_]+_r:[a-z_]+_t'

# Replacing pambase means replacing files under /etc/pam.d that this profile
# edits in place. increase-lockout-limit-server.sh seds deny=10 unlock_time=120
# into system-auth, which pambase owns; pacman must keep that edit and write
# its own version as a .pacnew rather than the other way round.
check "the profile's pam_faillock settings survived the pambase replacement" \
  'grep -n "pam_faillock" /etc/pam.d/system-auth; ls /etc/pam.d/*.pacnew 2>/dev/null' \
  'deny=10 unlock_time=120'

check "the transition is pam_selinux's, and it is in the sshd stack" \
  'grep -rn selinux /etc/pam.d/sshd /etc/pam.d/system-login 2>/dev/null' \
  'pam_selinux\.so'

# ── 4b. the administrative role ─────────────────────────────────────────────
#
# The blocker of the previous run, and the reason enforcing was a one-way door:
# with refpolicy's default mapping the operator was user_u:user_r:user_t and
# sudo gave Unix root without changing the SELinux context, so pacman, ufw,
# systemctl and setenforce were all refused in enforcing.
#
# Four checks, because three of them can hold while the fourth does not and the
# machine is then either unadministrable or unconfined.

check "the operator logs in as staff_t, not as the default user_t" \
  'id -Z' \
  ':staff_r:staff_t'

# THE check. Not "sudo works" -- sudo worked before and that was the trap --
# but "sudo lands in the administrative domain".
check "and sudo lands in sysadm_t, which is the whole point" \
  '~/.lab-sudo id -Z' \
  ':sysadm_r:sysadm_t'

# staff_u rather than sysadm_u: the LOGIN must stay confined. A machine whose
# login shell is already sysadm_t has no administrative boundary left to cross.
# Through sudo: /sys/fs/selinux/booleans is boolean_t, which a confined user
# domain may not read. Asking from staff_t would produce a denial of the
# harness's own making, on the very run whose bar is zero denials.
check "the login domain is confined: sysadm_t is reached by sudo, not by ssh" \
  'id -Z; ~/.lab-sudo getsebool ssh_sysadm_login allow_ptrace' \
  'ssh_sysadm_login --> off'

check "the mapping is %wheel -> staff_u in the policy store's seusers" \
  'grep -Ev "^#|^$" /etc/selinux/refpolicy-arch/seusers' \
  '%wheel:staff_u'

check "and sudoers carries the role transition for that same group" \
  '~/.lab-sudo cat /etc/sudoers.d/omarchy-selinux-role' \
  'Defaults:%wheel role=sysadm_r, type=sysadm_t'

check "omarchy-server-selinux status reports both halves" \
  'omarchy-server-selinux status | sed -n "/administrative role/,/^$/p"' \
  '%wheel:staff_u'

# ── 5. the filesystem is labelled ───────────────────────────────────────────

check "/etc and /usr carry real labels, not unlabeled_t" \
  'ls -Zd /etc /usr /usr/bin/sshd /etc/shadow' \
  'system_u:object_r'

# A relabel that half-finished is worse than one that did not run: the count is
# the evidence, not the absence of an error message.
#
# NOT `find -context`. Arch's findutils is not built against libselinux -- and
# findutils-selinux is deliberately not in the rebuild set -- so the predicate
# answers "find: invalid predicate -context: SELinux is not enabled" on stderr
# and prints nothing on stdout. Piped to `wc -l` that is a clean `0`, and the
# check passes without having looked at a single file. It did exactly that
# here before this was noticed.
#
# `restorecon -nvR` needs nothing but policycoreutils, and it answers a
# stronger question than "is anything unlabeled": it lists every path whose
# label differs from what the policy says it should be.
check "findutils here cannot do the sweep, which is why the check below does not use it" \
  'find /etc -maxdepth 0 -context "*" 2>&1 | head -1; echo "exit=$?"' \
  '.'

#
# /var/lib/docker and /var/lib/containerd are excluded, and the exclusion is
# the finding rather than a convenience: the container runtime labels its own
# tree on purpose and disagrees with the static file_contexts by design. §7 has
# a check of its own for it. Without the exclusion this one passes on a virgin
# machine and fails on the same machine after a container has ever run, which
# is a check that measures history rather than correctness.
check "no file under /etc /usr /var has a label the policy disagrees with" \
  '~/.lab-sudo restorecon -nvR -e /var/lib/docker -e /var/lib/containerd /etc /usr /var 2>&1 | head -20; echo "wrong=$(~/.lab-sudo restorecon -nvR -e /var/lib/docker -e /var/lib/containerd /etc /usr /var 2>/dev/null | wc -l)"' \
  '^wrong=0$'

# THE check of this whole re-validation. The first enforcing run locked the
# operator out because /home/<user> carried no label at all: the offline
# relabel ran before the orchestrator created the home directory, and it ran
# with `setfiles <file_contexts>`, which does not load file_contexts.homedirs
# where the /home/[^/]+ -> user_home_dir_t entry lives. Both halves are fixed;
# this is what proves it.
check "/home/<user> is labelled user_home_dir_t, not unlabeled" \
  'ls -Zd /home /home/*' \
  'user_home_dir_t'

check "and nothing under /home has a label the policy disagrees with" \
  '~/.lab-sudo restorecon -nvR /home /root 2>&1 | head -10; echo "wrong=$(~/.lab-sudo restorecon -nvR /home /root 2>/dev/null | wc -l)"' \
  '^wrong=0$'

check "the relabel flag was cleared, so the next boot does not repeat it" \
  'ls -l /.autorelabel 2>&1' \
  'No such file'

check "the first-boot relabel unit ran and succeeded" \
  'systemctl is-enabled omarchy-server-selinux-relabel.service; ~/.lab-sudo journalctl -u omarchy-server-selinux-relabel.service --no-pager -o cat | tail -5' \
  '.'

# ── 6. optionally switch to enforcing ───────────────────────────────────────

if [[ ${ENFORCE:-0} == 1 ]]; then
  echo "--- switching to enforcing ---"

  # WITHOUT --force. The previous run could not do this: the preflight refused,
  # correctly, because the session's role could not setenforce and the switch
  # would have been a one-way door. Now that the session reaches sysadm_t
  # through sudo, the guard is supposed to pass on its own -- and a run that
  # still needed --force would mean the administrative role had not taken.
  check "enforcing is accepted from a session that can undo it" \
    '~/.lab-sudo omarchy-server-selinux enforcing 2>&1 | head -8; echo "mode=$(getenforce)"' \
    '^mode=Enforcing$'

  check "and it will still be enforcing after a reboot" \
    'grep "^SELINUX=" /etc/selinux/config' 'SELINUX=enforcing'

  # The two-way door, asserted in both directions in one command. This is the
  # single most important property of the arrangement: an operator who breaks
  # something by going enforcing can undo it from the same ssh session, without
  # a console, a snapshot or an installer medium.
  check "and it is a TWO-way door: back to permissive and forward again, over ssh" \
    '~/.lab-sudo omarchy-server-selinux permissive >/dev/null 2>&1; echo "back=$(getenforce)"; ~/.lab-sudo omarchy-server-selinux enforcing --force >/dev/null 2>&1; echo "fwd=$(getenforce)"' \
    'back=Permissive'
  check "and forward again left it enforcing" 'getenforce' '^Enforcing$'
fi

# ── 7. the workload ─────────────────────────────────────────────────────────
#
# Everything a headless machine of this profile actually does, in one go. Each
# is a PASS/FAIL of its own, because "SELinux broke the update" and "SELinux
# broke snapper" are different findings.

check "sudo still works" '~/.lab-sudo id -un' '^root$'

check "a snapper snapshot can be taken" \
  '~/.lab-sudo snapper -c root create -d selinux-acceptance --print-number && ~/.lab-sudo snapper -c root list | tail -3' \
  '^[0-9]+$'

check "pacman can run a transaction" \
  '~/.lab-sudo pacman -Sy --noconfirm >/dev/null 2>&1; ~/.lab-sudo pacman -Q pacman-contrib && echo pacman-ok' \
  'pacman-ok'

# Judged on the exit status, not on a phrase in the output. `docker run
# hello-world` prints its greeting several lines before the end, so a check
# that tails the last few lines reports a working container as a failure.
check "the docker addon installs and runs a container" \
  '~/.lab-sudo omarchy-server-addon docker >/tmp/addon-docker.log 2>&1; echo "addon-exit=$?"; tail -3 /tmp/addon-docker.log; ~/.lab-sudo docker run --rm hello-world >/tmp/hello.log 2>&1; echo "run-exit=$?"; grep -c "Hello from Docker" /tmp/hello.log' \
  'run-exit=0'

# The container runtime tree, and the right question to ask about it.
#
# /var/lib/docker and /var/lib/containerd DO disagree with the static
# file_contexts after a container has run -- measured: 10 paths, volumes
# labelled container_file_t where the policy says container_var_lib_t, and
# snapshot layers labelled container_var_lib_t where it says
# container_ro_file_t. That is not drift to be repaired: the runtime sets those
# labels ON PURPOSE, `container_file_t` on a volume is what lets a container
# write to it, and `restorecon` there would take a working container apart.
# refpolicy's file_contexts cannot express "whatever the runtime decided", and
# it is not supposed to.
#
# So the check is not "does it match the policy" but the security-relevant one:
# is any of it UNLABELED, or labelled as something that is not container
# content. Unlabeled is what locked the operator out in §6.4 and it is the
# failure that matters.
check "nothing in the container runtime tree is unlabeled or non-container" \
  '~/.lab-sudo sh -c "ls -RZ /var/lib/docker /var/lib/containerd 2>/dev/null | grep -oE \"[a-z_]+_t \" | sort -u"; echo "bad=$(~/.lab-sudo sh -c "ls -RZ /var/lib/docker /var/lib/containerd 2>/dev/null | grep -cE \"unlabeled_t|:etc_t |:usr_t \"")"' \
  '^bad=0$'

# And the disagreement itself, recorded as a number rather than judged. It is
# expected to be non-zero and the reason is above; a run where it suddenly
# reached the hundreds would be worth looking at.
check "the size of that disagreement is recorded, not repaired" \
  'echo "differs-from-static-policy=$(~/.lab-sudo restorecon -nvR /var/lib/docker /var/lib/containerd 2>/dev/null | wc -l)"' \
  '^differs-from-static-policy=[0-9]+$'

check "the fwall addon installs" \
  '~/.lab-sudo omarchy-server-addon fwall 2>&1 | tail -3; command -v fwall' \
  '/fwall$'

check "the firewall still answers" \
  '~/.lab-sudo ufw status verbose | head -8' \
  'Status: active'

check "a login on the serial console reaches a shell in a user domain" \
  '~/.lab-sudo systemctl is-active serial-getty@ttyS0.service' \
  '^active$'

# Last of the workload, because it pulls the online mirrors and changes the
# package set every measurement above was taken on.
# Also judged on the exit status. omarchy-server-update has no single closing
# phrase -- what it prints depends on which steps had anything to do -- so a
# pattern guessed from one run is a check that fails on the next.
check "omarchy-server-update completes" \
  '~/.lab-sudo omarchy-server-update >/tmp/update.log 2>&1; echo "update-exit=$?"; tail -8 /tmp/update.log' \
  'update-exit=0'

# And the same update the way the daily timer runs it, which is a different
# measurement and not a duplicate: under the unit, pacman runs as initrc_t with
# its output on a socket systemd connected to the journal, and its children
# (systemd-notify from a post_install, restorecon from selinux-alpm-hook)
# transition into domains of their own. Nothing about that path is exercised by
# running the same command from a shell.
check "and the same update run the way the timer runs it" \
  '~/.lab-sudo systemctl start omarchy-server-update.service; ~/.lab-sudo systemctl show -p Result -p ExecMainStatus omarchy-server-update.service' \
  'Result=success'

# ── 7b. a kernel package, under enforcing ───────────────────────────────────
#
# The one path §11.5 of the mandatory-access-control report left unmeasured,
# and the one that decides whether enforcing is recommendable at all. A kernel
# transaction is not "one more package": it runs mkinitcpio, which reads the
# whole module tree and writes a UKI, then limine-entry-tool, which reads the
# ESP and rewrites limine.conf. Every one of those is a domain crossing, and a
# machine that cannot rebuild its own boot image under enforcing is a machine
# that cannot take a security update.
#
# The transaction is a reinstall when Arch has not moved, which is the harder
# case to get right and the same work either way: the files are rebuilt.
if [[ ${ENFORCE:-0} == 1 ]]; then
  echo "--- a kernel transaction under enforcing ---"

  check "a kernel transaction completes with the initramfs and UKI rebuilt" \
    'uki=$(~/.lab-sudo sh -c "ls -t /boot/EFI/Linux/*.efi" 2>/dev/null | head -1);
     before=$(~/.lab-sudo stat -c %Y "$uki" 2>/dev/null);
     ~/.lab-sudo dmesg -C >/dev/null 2>&1;
     timeout 1200 ~/.lab-sudo pacman -S --noconfirm linux >/tmp/kernel.log 2>&1; echo "pacman-exit=$?";
     ~/.lab-sudo tail -25 /tmp/kernel.log;
     after=$(~/.lab-sudo stat -c %Y "$uki" 2>/dev/null);
     echo "uki=$uki rebuilt=$([[ $after -gt ${before:-0} ]] && echo yes || echo no)"' \
    '^pacman-exit=0$'

  # The two strings §11.5 saw. They are not fatal to pacman -- limine-entry-tool
  # prints them and carries on -- so the exit status above cannot be the whole
  # check, and this is the one that would have caught the reported failure.
  check "no mkinitcpio or UKI build error appeared in that transaction" \
    '~/.lab-sudo grep -aE "mkinitcpio failed|errors were encountered|must be readable|Permission denied" /tmp/kernel.log || echo "no-build-errors"' \
    '^no-build-errors$'

  check "and the boot entry still points at a UKI that exists" \
    '~/.lab-sudo grep -c "EFI/Linux" /boot/limine.conf; ~/.lab-sudo ls -l /boot/EFI/Linux/' \
    '\.efi'

  # A denial the policy dontaudits is invisible here and in `ausearch`. That is
  # exactly the shape of "it failed and nothing was logged", so the count is
  # recorded rather than trusted -- §10 below is what looks underneath it.
  check "the kernel transaction was denied nothing that is audited" \
    '~/.lab-sudo ausearch -m avc -m user_avc -ts boot 2>/dev/null | grep -c "denied" || echo 0' \
    '^0$'

  check "the classifier does not ask for a reboot after a same-version rebuild" \
    'before=$(pacman -Q linux | awk "{print \$2}");
     ~/.lab-sudo rm -f /root/.local/state/omarchy/reboot-required;
     ~/.lab-sudo env HOME=/root omarchy-server-update-restart --no-restart 2>&1 | grep -E "^(kernel package|reboot required)";
     ~/.lab-sudo test -f /root/.local/state/omarchy/reboot-required && m=set || m=absent;
     echo "linux=$before marker=$m"' \
    'marker=absent'
fi

# ── 8. the denial record ────────────────────────────────────────────────────

echo "--- AVC denials accumulated by the workload above ---"
denials=$(run 'omarchy-server-selinux avc')
echo "${denials//$'\n'/$'\n'      }"
echo

denial_count=$(run "journalctl -k --no-pager -b -g 'avc: *denied' -o cat 2>/dev/null | wc -l" | tr -dc '0-9')
if [[ ${ENFORCE:-0} == 1 ]]; then
  # In enforcing, a denial is something that was actually refused. Zero is the
  # bar; anything else is a rule missing from the local module.
  if ((${denial_count:-1} == 0)); then
    report PASS "enforcing: nothing was denied under the workload" "0 AVC records this boot"
  else
    report FAIL "enforcing: something was denied under the workload" "$denial_count AVC records this boot — see the dump above"
  fi
else
  # In permissive a denial is a prediction, and the number is the size of the
  # remaining work rather than a failure.
  report PASS "permissive: the denial count was measured" "$denial_count AVC records this boot"
fi

# ── 9. reboot survival ──────────────────────────────────────────────────────

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

check "SELinux is still in the mode it was left in" 'getenforce' '^(Enforcing|Permissive)$'

check "and the boot produced no new denials before login" \
  "journalctl -k --no-pager -b -g 'avc: *denied' -o cat | wc -l" \
  '^[0-9]+$'

# ── 10. the disable path, and the §11.5 open question ───────────────────────
#
# `omarchy-server-selinux disable` removes the lsm= drop-in and rebuilds the
# UKI through limine-update. On the previous enforcing run that rebuild printed
# "WARNING: errors were encountered during the build" and "ERROR: mkinitcpio
# failed for kernel …, skipping", and **no AVC was logged**, so the report
# could not say whether SELinux was involved at all.
#
# "It failed and nothing was logged" has one common cause on this system, and
# it is not "SELinux was innocent": a denial matched by a `dontaudit` rule is
# refused and never audited. `semodule -DB` rebuilds the policy with every
# dontaudit removed, which is the standard way to see them; `semodule -B` puts
# them back. So this runs the rebuild twice -- once as it ships, once with the
# dontaudits off -- and keeps both transcripts. Whichever way it comes out is
# an answer: a denial appearing under -DB names the rule to add, and a clean
# run under -DB says the failure was never SELinux's.
#
# It is last because it is destructive: after it, this machine does not
# initialise SELinux on its next boot.
if [[ ${ENFORCE:-0} == 1 ]]; then
  echo "--- reproducing the disable-path UKI rebuild (§11.5) ---"

  check "limine-update rebuilds the UKI under enforcing, before anything is disabled" \
    '~/.lab-sudo limine-update >/tmp/limine-enforcing.log 2>&1; echo "limine-exit=$?";
     ~/.lab-sudo tail -20 /tmp/limine-enforcing.log;
     ~/.lab-sudo grep -aE "mkinitcpio failed|errors were encountered" /tmp/limine-enforcing.log || echo "no-build-errors"' \
    '^no-build-errors$'

  # The same command with every dontaudit rule removed from the loaded policy.
  # If the rebuild only fails here, or logs denials only here, the failure was
  # a silenced denial all along.
  check "and again with the dontaudit rules removed, which is where a silent denial shows" \
    '~/.lab-sudo semodule -DB >/dev/null 2>&1; echo "dontaudit-disabled-rc=$?";
     ~/.lab-sudo ausearch -m avc -ts recent >/dev/null 2>&1;
     start=$(date "+%H:%M:%S");
     ~/.lab-sudo limine-update >/tmp/limine-nodontaudit.log 2>&1; echo "limine-exit=$?";
     ~/.lab-sudo tail -20 /tmp/limine-nodontaudit.log;
     echo "--- AVCs since $start ---";
     ~/.lab-sudo ausearch -m avc -ts "$start" 2>&1 | grep "denied" | sed "s/.*denied/denied/" | sort | uniq -c | head -20;
     ~/.lab-sudo semodule -B >/dev/null 2>&1; echo "dontaudit-restored-rc=$?";
     ~/.lab-sudo grep -aE "mkinitcpio failed|errors were encountered" /tmp/limine-nodontaudit.log || echo "no-build-errors"' \
    '^no-build-errors$'

  check "omarchy-server-selinux disable completes, drop-in and sudoers role removed" \
    '~/.lab-sudo omarchy-server-selinux disable >/tmp/selinux-disable.log 2>&1; echo "disable-exit=$?";
     ~/.lab-sudo tail -25 /tmp/selinux-disable.log;
     test -e /etc/limine-entry-tool.d/omarchy-lsm-selinux.conf && echo "dropin=present" || echo "dropin=removed"' \
    '^dropin=removed$'

  check "and that disable rebuilt the UKI without a build error" \
    '~/.lab-sudo grep -aE "mkinitcpio failed|errors were encountered|must be readable" /tmp/selinux-disable.log || echo "no-build-errors"' \
    '^no-build-errors$'

  # The rebuilt command line is the thing the §11.5 failure delayed: with the
  # rebuild broken, the drop-in removal did not reach the UKI, so the next boot
  # would still have come up with lsm=selinux.
  # The verdict is computed rather than pattern-matched: the assertion is the
  # ABSENCE of a string, and grep -E has no way to say that.
  check "the rebuilt UKI no longer carries lsm=...selinux" \
    'uki=$(~/.lab-sudo sh -c "ls -t /boot/EFI/Linux/*.efi" 2>/dev/null | head -1); echo "uki=$uki";
     cmdline=$(~/.lab-sudo objcopy -O binary --only-section=.cmdline "$uki" /dev/stdout 2>/dev/null | tr -d "\0");
     if [ -z "$cmdline" ]; then echo "cmdline=unreadable";
     else echo "cmdline: $cmdline";
       case "$cmdline" in *lsm=*selinux*) echo "verdict=selinux-still-in-cmdline" ;;
       *) echo "verdict=selinux-gone-from-cmdline" ;; esac; fi' \
    '^verdict=selinux-gone-from-cmdline$'
fi

echo "=== $pass passed, $fail failed ==="
