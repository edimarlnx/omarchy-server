#!/bin/bash

# The upstream-migration seeding: what the omarchy-server package's
# post_install / post_upgrade scriptlet runs, and what install/server/
# root-migration-state-server.sh runs at install time.
#
# The whole decision is which markers exist in root's state directory after the
# command has run, so the test is a fixture with three migration files, an
# allowlist naming one of them, and an empty state directory. Nothing here
# needs root, pacman or a machine: the three paths the command reads are
# overridable for exactly this reason.

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

seed_command="$RUNTIME_BIN/omarchy-server-migration-seed"
fixture=$(make_temp_dir)
mkdir -p "$fixture/migrations" "$fixture/state"

for id in 1700000001 1700000002 1700000003; do
  echo "echo migration $id" >"$fixture/migrations/$id.sh"
done
# One id, spelled without the .sh suffix, beside a comment and a blank line:
# all three shapes are what a maintainer's file actually looks like.
cat >"$fixture/allow" <<'EOF'
# The migrations this profile wants to run.

1700000002
EOF

run_seed() {
  OMARCHY_MIGRATIONS_DIR="$fixture/migrations" \
    OMARCHY_MIGRATIONS_ALLOW="$fixture/allow" \
    OMARCHY_ROOT_MIGRATION_STATE="$fixture/state" \
    bash "$seed_command" "$@" 2>&1
}

markers() {
  find "$fixture/state" -maxdepth 1 -type f -printf '%f\n' | sort | tr '\n' ' '
}

# ── the first run ───────────────────────────────────────────────────────────
output=$(run_seed)
assert_equal "$(markers)" "1700000001.sh 1700000003.sh " \
  "everything but the allowed migration is marked done for root"
assert_contains "$output" "2 newly marked done" \
  "the run reports what it marked"
assert_contains "$output" "1 left pending" \
  "and what it deliberately left for omarchy-migrate to run"
assert_contains "$output" "allowlist: 1 entry" \
  "and how many entries the allowlist carried"
[[ -s $fixture/state/1700000001.sh ]] &&
  fail "a marker is an empty file, the way omarchy-migrate writes it"
pass "a marker is an empty file, the way omarchy-migrate writes it"

# ── running again is idempotent ─────────────────────────────────────────────
# The scriptlet runs on every upgrade of the package, so the second run is the
# common case and it must neither re-mark nor un-mark anything.
before=$(markers)
output=$(run_seed)
assert_equal "$(markers)" "$before" \
  "a second run changes no marker"
assert_contains "$output" "0 newly marked done" \
  "and says it marked nothing new"
assert_contains "$output" "2 already marked" \
  "counting the ones that were already there"

# ── a migration that arrives by upgrade ─────────────────────────────────────
# The case the whole thing exists for: a new upstream release ships a migration
# the machine has never seen, and it is marked before omarchy-migrate can run
# it as root during the unattended update.
echo "echo migration 1700000004" >"$fixture/migrations/1700000004.sh"
run_seed >/dev/null
assert_equal "$(markers)" "1700000001.sh 1700000003.sh 1700000004.sh " \
  "a migration that arrived by upgrade is marked, and the allowed one stays pending"

# ── the allowlist is what keeps a migration pending ─────────────────────────
: >"$fixture/allow"
run_seed >/dev/null
assert_equal "$(markers)" "1700000001.sh 1700000002.sh 1700000003.sh 1700000004.sh " \
  "removing the entry lets the next run mark that migration too"

# ── --dry-run writes nothing ────────────────────────────────────────────────
rm -rf "$fixture/state"
printf '1700000002.sh\n' >"$fixture/allow"
output=$(run_seed --dry-run)
assert_contains "$output" "3 newly marked done" \
  "--dry-run reports what it would mark"
[[ -d $fixture/state ]] &&
  fail "--dry-run creates no state directory"
pass "--dry-run creates no state directory"

# The .sh spelling in the allowlist is the same entry as the bare id.
run_seed >/dev/null
assert_equal "$(markers)" "1700000001.sh 1700000003.sh 1700000004.sh " \
  "an allowlist entry written with .sh names the same migration"

# ── no migrations directory ─────────────────────────────────────────────────
# A tree without one is not an error: the command runs from a package
# scriptlet, and a scriptlet that fails fails the pacman transaction.
output=$(OMARCHY_MIGRATIONS_DIR="$fixture/nowhere" \
  OMARCHY_MIGRATIONS_ALLOW="$fixture/allow" \
  OMARCHY_ROOT_MIGRATION_STATE="$fixture/state" \
  bash "$seed_command" 2>&1)
assert_contains "$output" "nothing to seed" \
  "a missing migrations directory is reported, not fatal"

# A missing allowlist means no allowlist, not a failure.
output=$(OMARCHY_MIGRATIONS_DIR="$fixture/migrations" \
  OMARCHY_MIGRATIONS_ALLOW="$fixture/nowhere" \
  OMARCHY_ROOT_MIGRATION_STATE="$fixture/state" \
  bash "$seed_command" 2>&1)
assert_contains "$output" "allowlist: 0 entries" \
  "a missing allowlist is an empty allowlist"
assert_equal "$(markers)" "1700000001.sh 1700000002.sh 1700000003.sh 1700000004.sh " \
  "and then every shipped migration is marked"
