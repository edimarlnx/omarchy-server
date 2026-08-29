# Shared ground between the two mandatory-access-control addons, `selinux` and
# `apparmor`.
#
# Sourced by install/server/selinux-server.sh and
# install/server/apparmor-server.sh. Conventions follow
# agents/skills/install-scripts.md: no shebang, no exit, every path taken from
# $OMARCHY_INSTALL / $OMARCHY_PATH.
#
# What the two routes have in common:
#
#   the kernel   Arch's stock kernel builds both LSMs in
#                (CONFIG_SECURITY_SELINUX=y, CONFIG_SECURITY_APPARMOR=y) and
#                activates neither, because CONFIG_LSM is
#                "landlock,lockdown,yama,integrity,bpf". Naming one of them in
#                `lsm=` on the kernel command line is the entire switch. No
#                kernel is rebuilt, and the profile already knows how to add a
#                cmdline flag: a drop-in under /etc/limine-entry-tool.d.
#
#   the ordering `lockdown` stays ahead of the MAC module in the list, the
#                order the stock CONFIG_LSM uses. lockdown's hooks answer
#                "may this process touch the kernel image at all", which is a
#                cheaper and more absolute question than "may this domain read
#                this file"; asking it first means a lockdown refusal is not
#                reported as a MAC denial. `bpf` stays last, as it does in the
#                stock list.
#
#   exclusivity  the kernel initialises whichever major LSM the list names, and
#                only one of SELinux and AppArmor can be it. Installing both
#                would leave a machine whose second addon silently does
#                nothing, so each refuses to run over the other.

# The cmdline drop-ins are named so they sort AFTER omarchy-defaults.conf --
# limine-entry-tool globs /etc/limine-entry-tool.d/*.conf in sorted order and
# these append to KERNEL_CMDLINE[default] rather than setting it.
OMARCHY_MAC_DROPIN_DIR=/etc/limine-entry-tool.d
OMARCHY_MAC_SELINUX_DROPIN="$OMARCHY_MAC_DROPIN_DIR/omarchy-lsm-selinux.conf"
OMARCHY_MAC_APPARMOR_DROPIN="$OMARCHY_MAC_DROPIN_DIR/omarchy-lsm-apparmor.conf"

# The stock CONFIG_LSM, with one name inserted before `bpf`.
omarchy_mac_lsm_list() { # omarchy_mac_lsm_list <selinux|apparmor>
  printf 'landlock,lockdown,yama,integrity,%s,bpf' "$1"
}

# Which MAC, if any, this machine is already set up for. Read from the drop-in
# rather than from the running kernel, because the answer has to be the same
# during an ISO install (where nothing is running) and on a live machine.
omarchy_mac_configured() {
  if [[ -f $OMARCHY_MAC_SELINUX_DROPIN ]]; then
    echo selinux
  elif [[ -f $OMARCHY_MAC_APPARMOR_DROPIN ]]; then
    echo apparmor
  else
    echo none
  fi
}

# Refuse to be the second one in. Returns non-zero, and the addon leaf turns
# that into an `exit` -- aborting the addon is exactly what should happen.
omarchy_mac_require_exclusive() { # omarchy_mac_require_exclusive <selinux|apparmor>
  local wanted=$1 current
  current=$(omarchy_mac_configured)

  case "$current" in
    none | "$wanted") return 0 ;;
  esac

  echo "$wanted: this machine is already set up for $current." >&2
  echo "         The kernel runs one major LSM, so the two addons are mutually" >&2
  echo "         exclusive. Remove the other one first:" >&2
  echo "             sudo omarchy-server-$current disable" >&2
  echo "         and reboot before installing this one." >&2
  return 1
}

# The cmdline drop-in. Written before the UKI is built, because the cmdline is
# baked into the UKI -- the same reason the Secure Boot leaf runs in the addon
# phase and not later.
omarchy_mac_write_dropin() { # omarchy_mac_write_dropin <selinux|apparmor> <extra flags...>
  local mac=$1
  shift
  local extra="$*" file lsm
  lsm=$(omarchy_mac_lsm_list "$mac")

  case "$mac" in
    selinux) file=$OMARCHY_MAC_SELINUX_DROPIN ;;
    apparmor) file=$OMARCHY_MAC_APPARMOR_DROPIN ;;
    *)
      echo "omarchy_mac_write_dropin: unknown MAC '$mac'" >&2
      return 1
      ;;
  esac

  install -Dm644 /dev/stdin "$file" <<EOF
# Installed by install/server/$mac-server.sh. Read after omarchy-defaults.conf
# (limine-entry-tool globs *.conf in sorted order), so this APPENDS to the
# profile's cmdline instead of replacing it.
#
# lsm=: Arch's stock kernel compiles $mac in but leaves it out of CONFIG_LSM,
# which is "landlock,lockdown,yama,integrity,bpf". This is that list with
# \`$mac\` inserted before bpf and after lockdown. Removing this file and
# rebuilding the UKI is how the machine goes back to no MAC at all.
KERNEL_CMDLINE[default]+=" lsm=$lsm${extra:+ $extra}"
EOF
}

omarchy_mac_remove_dropin() { # omarchy_mac_remove_dropin <selinux|apparmor>
  case "$1" in
    selinux) rm -f "$OMARCHY_MAC_SELINUX_DROPIN" ;;
    apparmor) rm -f "$OMARCHY_MAC_APPARMOR_DROPIN" ;;
  esac
}

# Rebuild the UKI so the new cmdline is actually in the image the firmware
# loads. During an ISO install this is a no-op on purpose: the orchestrator's
# finalize_limine_boot builds the UKI once, after every addon has run, and
# building it here as well would double the slowest phase of the install.
omarchy_mac_rebuild_boot() {
  if [[ ! -d /run/systemd/system ]]; then
    echo "  (installing; the UKI is built once at the end of the install)"
    return 0
  fi

  # limine-update is what the installer's finalize_limine_boot phase runs: it
  # regenerates the UKI through mkinitcpio, hands it to limine-entry-tool and
  # reinstalls Limine. The cmdline lives inside the UKI, so nothing short of
  # rebuilding it makes the drop-in real.
  if command -v limine-update >/dev/null; then
    echo "  rebuilding the UKI so the new kernel command line takes effect"
    limine-update || echo "  limine-update failed; run it by hand before rebooting" >&2
  else
    echo "  limine-update is not installed; rebuild the boot entry by hand" >&2
  fi
}
