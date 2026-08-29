# Setup leaf for the `cloud` addon, sourced by omarchy-server-addon after it
# installed cloud-init, cloud-guest-utils and qemu-guest-agent. The work is in
# install/server/cloud-server.sh, for the same reason the `secureboot` addon
# keeps its work in secureboot-server.sh: it is a profile setup step that
# happens to need three packages, not a package that happens to have a setup
# step. Keeping it there also lets the ISO run the same file for an install
# whose autoinstall drive named the addon.
#
# shellcheck disable=SC1090
source "$OMARCHY_INSTALL/server/cloud-server.sh"
