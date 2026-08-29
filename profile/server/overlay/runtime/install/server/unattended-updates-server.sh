# Enable the daily unattended-update timer, but only when the install asked for
# it. The package ships omarchy-server-update.timer disabled, because a machine
# that upgrades a database under load at 03:00 is not something to opt anyone
# into silently.
#
# The ISO's orchestrator exports OMARCHY_UNATTENDED_UPDATES=1 when the
# autoinstall drive carries an `unattended-updates` file; on every other install
# the variable is absent and the timer stays off, to be turned on later with
# `omarchy-server-update enable`.
if [[ ${OMARCHY_UNATTENDED_UPDATES:-0} == 1 ]]; then
  systemctl enable omarchy-server-update.timer
fi
