# Preflight for the `apparmor` addon, sourced by omarchy-server-addon BEFORE it
# installs anything. See selinux.preflight.sh for why this is not left to the
# setup leaf.
#
# shellcheck disable=SC1090
source "$OMARCHY_INSTALL/server/mac-server.sh"
omarchy_mac_require_exclusive apparmor || exit 1
