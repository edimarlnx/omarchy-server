# Setup leaf for the `secureboot` addon, sourced by omarchy-server-addon after
# it installed sbctl. The work is in install/server/secureboot-server.sh, which
# is where it belongs: it is a profile setup step that happens to need one
# package, not a package that happens to have a setup step. Keeping it there
# also lets the ISO run the same file for an install that asked for Secure Boot
# on the autoinstall drive.
#
# shellcheck disable=SC1090
source "$OMARCHY_INSTALL/server/secureboot-server.sh"
