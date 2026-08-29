# Setup leaf for the `apparmor` addon, sourced by omarchy-server-addon after it
# installed the apparmor package. The work is in
# install/server/apparmor-server.sh, for the same reason the selinux and
# secureboot addons keep theirs under install/server/: it is a profile setup
# step that happens to need a package, and the ISO runs the same file when the
# autoinstall drive asked for AppArmor.
#
# shellcheck disable=SC1090
source "$OMARCHY_INSTALL/server/apparmor-server.sh"
