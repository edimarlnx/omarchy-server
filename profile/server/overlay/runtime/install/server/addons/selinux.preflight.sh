# Preflight for the `selinux` addon, sourced by omarchy-server-addon BEFORE it
# installs anything.
#
# The kernel initialises one major LSM, so `selinux` and `apparmor` cannot both
# be set up on a machine. Refusing that in the setup leaf would be too late: by
# then nineteen packages -- eight of which replace core packages -- would
# already be installed on a machine that is not going to use them.
#
# shellcheck disable=SC1090
source "$OMARCHY_INSTALL/server/mac-server.sh"
omarchy_mac_require_exclusive selinux || exit 1
