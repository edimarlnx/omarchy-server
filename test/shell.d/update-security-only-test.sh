#!/bin/bash

# The security-only update, the reboot window and the status report.
#
# `omarchy-server-update run --security-only` upgrades only what arch-audit
# reports as vulnerable with a fix available; `reboot-if-due` takes a reboot an
# earlier run deferred; `status --json` is what a canary reads. All three are
# decisions this command makes on its own, before it hands anything to pacman,
# which is exactly the part a fixture tree can exercise.
#
# Everything the run would touch on a machine is a stub: arch-audit (the set),
# pacman (the upgrade), omarchy-snapshot, the restart classifier (which owns
# the reboot-required marker) and systemctl (the reboot itself). What runs for
# real is the command's own logic: the parse, the empty-set shortcut, the
# window arithmetic and the report.

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

# The command insists on root, and re-execs itself under sudo when it is not.
# An unprivileged user namespace is root enough: every path it writes is inside
# the fixture and every command it calls is a stub.
if ! unshare -r true 2>/dev/null; then
  pass "no unprivileged user namespaces; skipping the security-only update test"
  exit 0
fi

update_command="$RUNTIME_BIN/omarchy-server-update"
fixture=$(make_temp_dir)
mkdir -p "$fixture/bin" "$fixture/home/.local/state/omarchy" "$fixture/state"
marker="$fixture/home/.local/state/omarchy/reboot-required"
audit_output="$fixture/audit-output"
log="$fixture/calls"

# ── the stubs ───────────────────────────────────────────────────────────────
# arch-audit prints whatever the test put in $audit_output, so one stub covers
# the quiet format, the verbose format, the noise and the empty answer.
cat >"$fixture/bin/arch-audit" <<EOF
#!/bin/bash
echo "arch-audit \$*" >>"$log"
cat "$audit_output"
EOF
cat >"$fixture/bin/pacman" <<EOF
#!/bin/bash
echo "pacman \$*" >>"$log"
EOF
cat >"$fixture/bin/omarchy-snapshot" <<EOF
#!/bin/bash
echo "omarchy-snapshot \$*" >>"$log"
EOF
# The classifier owns the marker on a real machine; here the test decides,
# through \$STUB_REBOOT_REQUIRED, whether this transaction needed one.
cat >"$fixture/bin/omarchy-server-update-restart" <<EOF
#!/bin/bash
echo "restart classifier: \$*"
if [[ \${STUB_REBOOT_REQUIRED:-0} == 1 ]]; then
  touch "$marker"
  echo "reboot required: stub"
fi
EOF
cat >"$fixture/bin/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >>"$log"
case "\$1" in
  is-enabled) echo disabled ;;
  reboot | kexec) echo "stub systemctl: \$1" ;;
esac
EOF
chmod +x "$fixture/bin/"*

run_update() {
  unshare -r env \
    HOME="$fixture/home" \
    PATH="$fixture/bin:$PATH" \
    OMARCHY_SERVER_UPDATE_CONF="$fixture/update.conf" \
    OMARCHY_SERVER_STATE_DIR="$fixture/state" \
    ${OMARCHY_UPDATE_NOW:+OMARCHY_UPDATE_NOW="$OMARCHY_UPDATE_NOW"} \
    ${STUB_REBOOT_REQUIRED:+STUB_REBOOT_REQUIRED="$STUB_REBOOT_REQUIRED"} \
    bash "$update_command" "$@" 2>&1
}

write_config() {
  cat >"$fixture/update.conf" <<EOF
SECURITY_DAILY=yes
FULL_WEEKLY=sun
REBOOT_WINDOW=${1:-04:00-05:00}
EOF
}

write_config

# ── an empty set is a no-op ─────────────────────────────────────────────────
# The point of the mode: on most days there is nothing to do, and nothing is
# what should happen -- no snapshot to fill the disk, no database refresh, no
# pacman transaction to classify.
: >"$log"
cat >"$audit_output" <<'EOF'
EOF
output=$(run_update run --security-only)
assert_contains "$output" "nothing to do" \
  "an empty audit is reported as nothing to do"
assert_not_contains "$(cat "$log")" "pacman" \
  "an empty set never reaches pacman"
assert_not_contains "$(cat "$log")" "omarchy-snapshot" \
  "an empty set never snapshots"
[[ -f $fixture/state/last-security-run ]] ||
  fail "the run is still recorded: the machine looked, and that is what status reports"
pass "the run is still recorded: the machine looked, and that is what status reports"

# The tracker's own "nothing found" sentence, and a blank line, are messages and
# not package names.
: >"$log"
cat >"$audit_output" <<'EOF'
No vulnerable packages found

EOF
output=$(run_update run --security-only)
assert_contains "$output" "nothing to do" \
  "a message rather than a list is still an empty set"
assert_not_contains "$(cat "$log")" "pacman" \
  "a message never becomes a pacman target"

# ── a non-empty set ─────────────────────────────────────────────────────────
# Every shape at once. The quiet upgradable format is `name>=version`, which is
# what the run actually asks for; the two sentence forms are what arch-audit
# 0.2.0 prints without -q (captured from a lab machine) and what older releases
# printed with a "Package " prefix. None of them is a contract, so all of them
# are parsed, and the duplicate proves the set is de-duplicated.
: >"$log"
cat >"$audit_output" <<'EOF'
curl>=8.20.0-1
linux is affected by multiple issues, insufficient validation. Update to 6.19.15.arch1-1!
Package openssl is affected by CVE-2026-1234. Update to 3.6.2-1!
curl>=8.20.0-1
EOF
output=$(run_update run --security-only)
assert_contains "$output" "vulnerable packages with a fix available: curl linux openssl" \
  "both output shapes are parsed, sorted and de-duplicated"
calls=$(cat "$log")
assert_contains "$calls" "pacman -Sy --noconfirm --noprogressbar" \
  "the sync databases are refreshed first, or the fixed version cannot be found"
assert_contains "$calls" "pacman -S --needed --noconfirm --noprogressbar curl linux openssl" \
  "only the audited packages are installed, with --needed and with their dependencies"
assert_not_contains "$calls" "pacman -Syu" \
  "a security-only run never takes the whole release"
assert_contains "$calls" "omarchy-snapshot create" \
  "the snapshot is taken here, because omarchy-update is not the one running"
assert_contains "$output" "restart classifier" \
  "the security run hands off to the same classifier a full run does"

# ── the reboot window ───────────────────────────────────────────────────────
# The classifier says a reboot is required; the window says when it is taken.
export STUB_REBOOT_REQUIRED=1

rm -f "$marker"
OMARCHY_UPDATE_NOW=04:30 output=$(OMARCHY_UPDATE_NOW=04:30 run_update run --security-only)
assert_contains "$output" "inside the reboot window 04:00-05:00: rebooting" \
  "a required reboot inside the window is taken"
assert_contains "$output" "stub systemctl: reboot" \
  "and it is taken with systemctl reboot"

rm -f "$marker"
output=$(OMARCHY_UPDATE_NOW=12:00 run_update run --security-only)
assert_contains "$output" "reboot deferred to window 04:00-05:00" \
  "a required reboot outside the window is deferred, not taken"
assert_not_contains "$output" "stub systemctl: reboot" \
  "nothing reboots at noon"
[[ -f $marker ]] || fail "the marker is left for the reboot timer"
pass "the marker is left for the reboot timer"

# A window that ends before it starts wraps around midnight: 23:00-01:00 is two
# hours, not a mistake.
write_config 23:00-01:00
rm -f "$marker"
output=$(OMARCHY_UPDATE_NOW=23:30 run_update run --security-only)
assert_contains "$output" "inside the reboot window 23:00-01:00: rebooting" \
  "23:30 is inside a window that wraps midnight"
rm -f "$marker"
output=$(OMARCHY_UPDATE_NOW=00:30 run_update run --security-only)
assert_contains "$output" "inside the reboot window 23:00-01:00: rebooting" \
  "00:30 is inside a window that wraps midnight"
rm -f "$marker"
output=$(OMARCHY_UPDATE_NOW=02:00 run_update run --security-only)
assert_contains "$output" "reboot deferred to window 23:00-01:00" \
  "02:00 is outside a window that wraps midnight"

# A window that cannot be read must not become "reboot whenever": a typo is not
# consent to reboot at noon.
write_config 4am-5am
rm -f "$marker"
output=$(OMARCHY_UPDATE_NOW=12:00 run_update run --security-only)
assert_contains "$output" "is not HH:MM-HH:MM" \
  "an unparsable window is reported"
assert_contains "$output" "reboot deferred to window 04:00-05:00" \
  "and falls back to the shipped default rather than to always"

write_config
unset STUB_REBOOT_REQUIRED

# ── reboot-if-due ───────────────────────────────────────────────────────────
# What the reboot timer runs at the start of the window. The marker is the
# whole decision: it does not re-audit, re-classify or re-check the window.
rm -f "$marker"
: >"$log"
output=$(run_update reboot-if-due)
assert_contains "$output" "no reboot due" \
  "no marker, no reboot"
assert_not_contains "$(cat "$log")" "systemctl reboot" \
  "and nothing is asked of systemd"

touch "$marker"
: >"$log"
output=$(run_update reboot-if-due)
assert_contains "$output" "reboot due since" \
  "a marker is a reboot owed, and the report says since when"
assert_contains "$output" "stub systemctl: reboot" \
  "reboot-if-due takes it"

touch "$marker"
output=$(run_update reboot-if-due --no-reboot)
assert_contains "$output" "not rebooting (--no-reboot)" \
  "--no-reboot outranks the marker"
assert_not_contains "$output" "stub systemctl: reboot" \
  "and nothing reboots"
rm -f "$marker"

# ── status ──────────────────────────────────────────────────────────────────
cat >"$audit_output" <<'EOF'
curl>=8.20.0-1
openssl>=3.6.2-1
EOF
output=$(run_update status)
assert_contains "$output" "pending vulnerable packages: 2" \
  "status counts what arch-audit reports"
assert_contains "$output" "reboot due: no" \
  "status reports the reboot state"
assert_contains "$output" "reboot window: 04:00-05:00" \
  "status reports the window"
assert_contains "$output" "last security run: " \
  "status reports the last security run"

touch "$marker"
json=$(run_update status --json)
assert_contains "$json" '"pending_vulnerable_packages": 2' \
  "the JSON carries the count as a number"
assert_contains "$json" '"reboot_due": true' \
  "the JSON carries the reboot state as a boolean"
assert_contains "$json" '"reboot_window": "04:00-05:00"' \
  "the JSON carries the window"
assert_contains "$json" '"last_full_run": null' \
  "a run that never happened is null, not a missing key"
assert_contains "$json" '"timers": {"full": "disabled"' \
  "the JSON carries all three timers"

if command -v python3 >/dev/null; then
  python3 -c 'import json,sys; json.load(sys.stdin)' <<<"$json" ||
    fail "status --json emits valid JSON" "$json"
  pass "status --json emits valid JSON"
else
  pass "no python3; skipping the JSON parse"
fi
rm -f "$marker"
