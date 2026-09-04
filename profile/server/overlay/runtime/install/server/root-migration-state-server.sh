# Mark every shipped migration as already applied for root.
#
# Omarchy records migrations per user, under ~/.local/state/omarchy/migrations,
# and the runtime package pre-marks all of them in /etc/skel so an account
# created after the install does not replay the whole history. root predates
# /etc/skel and gets no such seeding.
#
# That matters here because a headless machine updates as root — `sudo
# omarchy-update`, or the omarchy-server-update timer — and omarchy-migrate
# then reads root's empty state directory and runs all ~90 migrations against
# /root on the first update. They are written for a desktop session, they run
# under `bash -euo pipefail`, and the first one that fails aborts the update
# before the packages it was supposed to migrate to are even in use.
#
# Marking, not running: the migrations are for a system this install already
# ships current.
#
# The same seeding runs again on every omarchy-server upgrade, from the
# package's post_upgrade scriptlet, so migrations that arrive later by upgrade
# are covered too. Both paths go through the same command, which is also where
# the install/server/migrations-allow allowlist is honoured -- a migration this
# profile wants is left pending here as well as there.
install -d -m 700 /root/.local /root/.local/state /root/.local/state/omarchy
if command -v omarchy-server-migration-seed >/dev/null; then
  OMARCHY_PATH="$OMARCHY_PATH" omarchy-server-migration-seed
else
  # Fallback for a tree without the command: mark everything, no allowlist.
  install -d -m 700 /root/.local/state/omarchy/migrations
  for migration in "$OMARCHY_PATH"/migrations/*.sh; do
    [[ -e $migration ]] || continue
    : >"/root/.local/state/omarchy/migrations/${migration##*/}"
  done
fi
