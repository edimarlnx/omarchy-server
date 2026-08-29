# Preflight for the `selinux-tools` addon, sourced by omarchy-server-addon
# BEFORE it installs anything.
#
# These are tools for a policy store this machine may not have. Installing them
# over an `apparmor` machine, or over a machine with no MAC at all, pulls the
# whole SELinux userland in as a dependency and leaves 45 packages behind for
# nothing -- so refuse, and say which addon to run instead.
#
# shellcheck disable=SC1090
source "$OMARCHY_INSTALL/server/mac-server.sh"

case "$(omarchy_mac_configured)" in
  selinux) ;;
  apparmor)
    echo "selinux-tools: this machine is set up for apparmor." >&2
    echo "               These are SELinux policy tools; there is no policy" >&2
    echo "               store here for them to read." >&2
    exit 1
    ;;
  *)
    echo "selinux-tools: this machine has no SELinux policy store." >&2
    echo "               Run \`omarchy-server-addon selinux\` first; these are" >&2
    echo "               the authoring tools for the policy that addon loads." >&2
    exit 1
    ;;
esac
