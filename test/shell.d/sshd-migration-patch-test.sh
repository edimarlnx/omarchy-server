#!/bin/bash

# The guard added by profile/server/overlay/patches/0007-sshd-migration-keep-keyonly-server.patch.
#
# Upstream's migration 1788124236 disables sshd when the invoking account has
# no usable authorized key. On this profile the update runs as root with
# HOME=/root, an account that is keyless and forbidden from logging in by
# policy, so that answer would take a headless machine off the network. The
# patch makes the branch inert when sshd's effective configuration already
# refuses passwords, and never disables the daemon for root on a machine with
# PermitRootLogin no.
#
# What runs here is the patched migration itself, rebuilt exactly as the
# package does it: the upstream file at the pinned commit with the series patch
# applied on top. Everything it would touch on a machine is a stub -- sshd
# (both -t and -T), systemctl, ssh-keygen, sudo and install -- so the three
# branches can be walked without a daemon, a key or root.

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

migration=migrations/1788124236.sh
patch_file="$ROOT/profile/server/overlay/patches/0007-sshd-migration-keep-keyonly-server.patch"
clone="$ROOT/upstream/omarchy"
hardening=/etc/ssh/sshd_config.d/10-omarchy-hardening.conf

# The upstream work clone is gitignored: present on a maintainer's machine and
# on the bump workflow, absent on a bare checkout. Without it there is nothing
# to patch, and skipping is honest.
if [[ ! -d $clone/.git && ! -f $clone/HEAD ]]; then
  pass "no upstream/omarchy clone; skipping the sshd migration patch test"
  exit 0
fi

pinned=$(awk -F= '$1 == "omarchy_commit" { print $2; exit }' "$ROOT/upstream/PIN")
if [[ -z $pinned ]] || ! git -C "$clone" cat-file -e "$pinned:$migration" 2>/dev/null; then
  pass "the pinned commit or its migration is not in upstream/omarchy; skipping"
  exit 0
fi

# The migration hardcodes the drop-in path and exits early when it exists, so
# a host that already has one would make every assertion below meaningless.
if [[ -e $hardening || -L $hardening ]]; then
  pass "$hardening exists on this host; skipping the sshd migration patch test"
  exit 0
fi

work=$(make_temp_dir)
mkdir -p "$work/tree"
git -C "$clone" archive --format=tar "$pinned" "$migration" | tar -x -C "$work/tree"
patch -p1 --forward --silent -d "$work/tree" <"$patch_file" ||
  fail "the sshd migration patch applies to the pinned upstream file"
pass "the sshd migration patch applies to the pinned upstream file"
script="$work/tree/$migration"

# ── the stubs ───────────────────────────────────────────────────────────────
# $fixture/sshd-T is what `sshd -T` answers; each scenario writes it. The
# install stub catches the drop-in the success path writes, since /etc is not
# the test's to touch.
bin="$work/bin"
mkdir -p "$bin"
log="$work/calls"
dropin="$work/hardening.conf"

cat >"$bin/sshd" <<STUB
#!/bin/bash
echo "sshd \$*" >>"$log"
case "\$1" in
  -T) cat "$work/sshd-T" ;;
  -t) exit 0 ;;
esac
STUB
# An enabled and active daemon, which is the state the migration requires
# before it touches anything.
cat >"$bin/systemctl" <<STUB
#!/bin/bash
echo "systemctl \$*" >>"$log"
exit 0
STUB
# sshd's own question, without needing openssh installed: does the line parse
# as a public key?
cat >"$bin/ssh-keygen" <<'STUB'
#!/bin/bash
line=$(cat)
[[ $line =~ ^(ssh-(rsa|ed25519)|ecdsa-sha2-) ]]
STUB
cat >"$bin/sudo" <<'STUB'
#!/bin/bash
exec "$@"
STUB
cat >"$bin/install" <<STUB
#!/bin/bash
echo "install \$*" >>"$log"
cat >"$dropin"
STUB
chmod +x "$bin"/*

# A home the migration is willing to trust: StrictModes rejects a group- or
# world-writable one.
home="$work/home"
mkdir -p "$home/.ssh"
chmod 700 "$home" "$home/.ssh"
authorized_keys="$home/.ssh/authorized_keys"

run_migration() {
  : >"$log"
  rm -f "$dropin"
  env -i HOME="$home" PATH="$bin:/usr/bin:/bin" bash "$script" 2>&1
}

# ── no key, passwords already refused: nothing to close ─────────────────────
# The state this profile installs with. Upstream's repair has no hole to
# repair, so the daemon must be left alone.
cat >"$work/sshd-T" <<'CONF'
passwordauthentication no
kbdinteractiveauthentication no
permitrootlogin no
CONF
rm -f "$authorized_keys"
output=$(run_migration) || fail "a key-only server exits 0" "$output"
pass "a key-only server exits 0"
assert_contains "$output" "there is no password-only server to close" \
  "and says why it did nothing"
assert_not_contains "$(cat "$log")" "systemctl disable" \
  "sshd is not disabled when passwords are already refused"

# An authorized_keys that exists but holds nothing usable is the same answer.
printf '# just a comment\n' >"$authorized_keys"
output=$(run_migration) || fail "an unusable authorized_keys exits 0" "$output"
pass "an unusable authorized_keys exits 0"
assert_not_contains "$(cat "$log")" "systemctl disable" \
  "an unusable key file does not disable a key-only server either"

# ── no key, passwords accepted: upstream's behaviour, untouched ─────────────
# A machine that genuinely accepts passwords with no key authorized is the hole
# upstream closes, and this patch does not defend it.
cat >"$work/sshd-T" <<'CONF'
passwordauthentication yes
kbdinteractiveauthentication yes
permitrootlogin prohibit-password
CONF
rm -f "$authorized_keys"
output=$(run_migration) || fail "the upstream branch still exits 0" "$output"
pass "the upstream branch still exits 0"
assert_contains "$(cat "$log")" "systemctl disable --now sshd.service" \
  "a password-only server with no key is still disabled"
assert_contains "$output" "The SSH server has been disabled" \
  "with upstream's notice"

# ── no key, passwords accepted, but invoked by root under PermitRootLogin no ─
# Root cannot have a usable key by policy, so its empty authorized_keys says
# nothing about the machine. Needs EUID 0, which an unprivileged user namespace
# provides without a real root.
if unshare -r true 2>/dev/null; then
  cat >"$work/sshd-T" <<'CONF'
passwordauthentication yes
kbdinteractiveauthentication yes
permitrootlogin no
CONF
  rm -f "$authorized_keys"
  : >"$log"
  rm -f "$dropin"
  output=$(unshare -r env -i HOME="$home" PATH="$bin:/usr/bin:/bin" bash "$script" 2>&1) ||
    fail "root under PermitRootLogin no exits 0" "$output"
  pass "root under PermitRootLogin no exits 0"
  assert_contains "$output" "sshd refuses root logins" \
    "and says the key question was asked of an account that cannot log in"
  assert_not_contains "$(cat "$log")" "systemctl disable" \
    "sshd is not disabled on root's answer when root may not log in"
else
  pass "no unprivileged user namespaces; skipping the root branch"
fi

# ── a usable key: upstream's success path, untouched ────────────────────────
cat >"$work/sshd-T" <<'CONF'
passwordauthentication no
kbdinteractiveauthentication no
permitrootlogin no
CONF
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexampleexampleexampleexampleexamplex test@lab\n' \
  >"$authorized_keys"
output=$(run_migration) || fail "the key-present branch exits 0" "$output"
pass "the key-present branch exits 0"
calls=$(cat "$log")
assert_contains "$calls" "install -Dm644 /dev/stdin /etc/ssh/sshd_config.d/10-omarchy-hardening.conf" \
  "a usable key still gets the hardening drop-in"
assert_contains "$(cat "$dropin")" "PasswordAuthentication no" \
  "and the drop-in is upstream's"
assert_contains "$calls" "systemctl reload sshd.service" \
  "and sshd is reloaded, not disabled"
assert_not_contains "$calls" "systemctl disable" \
  "the key-present branch never disables sshd"
