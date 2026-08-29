# Setup leaf for the `selinux` addon, sourced by omarchy-server-addon after it
# installed the userland, the policy and the replacement core packages. The
# work is in install/server/selinux-server.sh, which is where it belongs: it is
# a profile setup step that happens to need a package set, not a package set
# that happens to have a setup step. Keeping it there also lets the ISO run the
# same file for an install that asked for SELinux on the autoinstall drive.
#
# shellcheck disable=SC1090
source "$OMARCHY_INSTALL/server/selinux-server.sh"
