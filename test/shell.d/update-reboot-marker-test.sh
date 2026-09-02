#!/bin/bash

# The reboot-required marker an unattended update leaves behind.
#
# omarchy-server-update-restart sets upstream's marker when a transaction
# really needs a reboot; nothing on a headless machine clears it, because the
# only command that does is omarchy-system-reboot (user systemd manager,
# Hyprland windows) and a server reboots with `systemctl reboot`. The marker
# then outlives the reboot it asked for, and every later unattended update
# prints
#
#   Updates require reboot. Ready? (not rebooting: unattended update)
#
# from upstream's omarchy-update-restart, immediately before this profile's own
# classifier reports "reboot required: no" about the transaction that just ran.
#
# The rule under test: a marker older than the current boot asked for a reboot
# that has since been taken, so it is cleared before the update runs. A marker
# written since this boot is a reboot still owed, and it is left alone.
#
# The update itself is stubbed. What runs is the real omarchy-server-update up
# to the point where it hands off, which is the only part that decides this.

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

# The command insists on root, and re-execs itself under sudo when it is not.
# An unprivileged user namespace is root enough: it reads and removes a file in
# a directory the test owns and calls two stubs.
if ! unshare -r true 2>/dev/null; then
  pass "no unprivileged user namespaces; skipping the update marker test"
  exit 0
fi

update_command="$RUNTIME_BIN/omarchy-server-update"
fixture=$(make_temp_dir)

mkdir -p "$fixture/bin" "$fixture/home/.local/state/omarchy"
marker="$fixture/home/.local/state/omarchy/reboot-required"

# The two commands the run hands off to. Both are stubs: this test is about
# what the marker looks like when omarchy-update is invoked, so the stub is
# what reports it.
cat >"$fixture/bin/omarchy-update" <<EOF
#!/bin/bash
if [[ -f "$marker" ]]; then
  echo "stub omarchy-update: marker present"
else
  echo "stub omarchy-update: marker absent"
fi
EOF
cat >"$fixture/bin/omarchy-server-update-restart" <<'EOF'
#!/bin/bash
echo "stub omarchy-server-update-restart: $*"
EOF
chmod +x "$fixture/bin/omarchy-update" "$fixture/bin/omarchy-server-update-restart"

run_update() {
  unshare -r env \
    HOME="$fixture/home" \
    PATH="$fixture/bin:$PATH" \
    bash "$update_command" run 2>&1
}

# ── a marker from before this boot ──────────────────────────────────────────
touch -d '@1000000000' "$marker"
output=$(run_update)
assert_contains "$output" "clearing a reboot-required marker from before this boot" \
  "a marker older than the boot is reported as stale"
assert_contains "$output" "stub omarchy-update: marker absent" \
  "the stale marker is gone before the update runs, so upstream cannot ask about it"
if [[ -f $marker ]]; then fail "the stale marker is removed"; fi
pass "the stale marker is removed"

# ── a marker written since this boot ────────────────────────────────────────
touch "$marker"
output=$(run_update)
assert_not_contains "$output" "clearing a reboot-required marker" \
  "a marker written since the boot is not called stale"
assert_contains "$output" "stub omarchy-update: marker present" \
  "a reboot still owed is still owed: the marker stands"
if [[ ! -f $marker ]]; then fail "the pending marker is kept"; fi
pass "the pending marker is kept"

# ── no marker at all ────────────────────────────────────────────────────────
rm -f "$marker"
output=$(run_update)
assert_not_contains "$output" "clearing a reboot-required marker" \
  "no marker, nothing to clear"
assert_contains "$output" "stub omarchy-server-update-restart" \
  "the update still hands off to the classifier"
