# AppArmor, with the profiles a headless machine can actually use.
#
# Sourced by install/server/addons/apparmor.sh, which the ISO runs inside the
# target chroot when the autoinstall drive carries an `apparmor` marker, and
# which `omarchy-server-addon apparmor` runs on an already installed machine.
# Conventions follow agents/skills/install-scripts.md: no shebang, no exit,
# every path taken from $OMARCHY_INSTALL / $OMARCHY_PATH.
#
# What this leaf sets up:
#
#   cmdline     /etc/limine-entry-tool.d/omarchy-lsm-apparmor.conf, written by
#               install/server/mac-server.sh: `lsm=...,apparmor,bpf`. Before
#               the UKI is built, because the cmdline is baked into it.
#
#   service     apparmor.service, which loads every profile under
#               /etc/apparmor.d at boot. Enabled, not started: during an ISO
#               install there is no running init, and on a live machine the
#               profiles cannot load until the kernel has AppArmor, which is
#               after the reboot.
#
#   profiles    this is where the route gets honest. Arch's `apparmor` package
#               ships around two hundred profiles under /etc/apparmor.d, and
#               they are for desktop software: browsers, chat clients, document
#               viewers, Xorg. On the server base almost none of them matches a
#               binary that exists. The daemons a headless machine does run --
#               sshd above all -- have no enabled profile at all; sshd's lives
#               under /usr/share/apparmor/extra-profiles, which upstream's own
#               README describes as not mature enough to enable by default.
#
#               So the profile ships its own adapted copy
#               (install/server/mac/apparmor/usr.bin.sshd) and puts it in
#               COMPLAIN mode. Complain, not enforce, for the same reason
#               SELinux starts permissive: an sshd profile that refuses one
#               thing it should have allowed is a machine nobody can log into.
#               `omarchy-server-apparmor enforce` is the second step.

# shellcheck source=./mac-server.sh
source "$OMARCHY_INSTALL/server/mac-server.sh"

OMARCHY_APPARMOR_PROFILE_DIR=/etc/apparmor.d

omarchy_apparmor_require_userland() {
  if ! command -v apparmor_parser >/dev/null; then
    echo "apparmor: apparmor_parser is not installed." >&2
    echo "          Run \`omarchy-server-addon apparmor\`." >&2
    return 1
  fi
}

omarchy_apparmor_write_cmdline_dropin() {
  omarchy_mac_write_dropin apparmor
  echo "apparmor: kernel command line drop-in written"
}

omarchy_apparmor_install_profiles() {
  local source_dir="$OMARCHY_INSTALL/server/mac/apparmor"
  local profile name

  [[ -d $source_dir ]] || return 0

  install -d "$OMARCHY_APPARMOR_PROFILE_DIR/force-complain" \
    "$OMARCHY_APPARMOR_PROFILE_DIR/local"

  for profile in "$source_dir"/*; do
    [[ -f $profile ]] || continue
    name=${profile##*/}
    install -Dm644 "$profile" "$OMARCHY_APPARMOR_PROFILE_DIR/$name"

    # force-complain/<name> is AppArmor's own switch for "load this profile,
    # log what it would have refused, refuse nothing". A symlink, so removing
    # it is the whole of `omarchy-server-apparmor enforce`.
    ln -sf "../$name" "$OMARCHY_APPARMOR_PROFILE_DIR/force-complain/$name"

    # local/<name> is included by the profile itself (`include if exists
    # <local/...>`) and is where a site adds rules without editing a file the
    # package owns. Created empty so the operator has somewhere obvious to put
    # what `omarchy-server-apparmor denials` turns up.
    [[ -e $OMARCHY_APPARMOR_PROFILE_DIR/local/$name ]] ||
      printf '# Site-specific additions to the %s profile. Not owned by any package.\n' "$name" \
        >"$OMARCHY_APPARMOR_PROFILE_DIR/local/$name"

    echo "apparmor: profile '$name' installed in complain mode"
  done
}

# The set of shipped profiles that matches a binary this machine actually has.
# Reported rather than acted on: the point is that the operator sees how little
# of Arch's profile set is relevant here before deciding this route is enough.
omarchy_apparmor_report_coverage() {
  local total=0 matching=0 profile binary

  for profile in "$OMARCHY_APPARMOR_PROFILE_DIR"/*; do
    [[ -f $profile ]] || continue
    # total=$((total+1)), not ((total++)): this file is sourced by
    # omarchy-server-addon, which runs under `set -e`, and a post-increment
    # from zero returns the old value -- so the first one would abort the addon.
    total=$((total + 1))
    # A profile's name is the path of what it confines with / replaced by .
    binary=/${profile##*/}
    binary=${binary//./\/}
    [[ -x $binary ]] && matching=$((matching + 1))
  done

  echo "apparmor: $total profiles under $OMARCHY_APPARMOR_PROFILE_DIR, $matching of which name a binary this machine has"
}

omarchy_apparmor_enable_service() {
  systemctl enable apparmor.service
  echo "apparmor: apparmor.service enabled"
}

omarchy_apparmor_setup() {
  omarchy_mac_require_exclusive apparmor || return 1
  omarchy_apparmor_require_userland || return 1

  omarchy_apparmor_write_cmdline_dropin
  omarchy_apparmor_install_profiles
  omarchy_apparmor_report_coverage
  omarchy_apparmor_enable_service

  omarchy_mac_rebuild_boot

  echo
  echo "apparmor: set up. It takes effect on the next boot."
  echo "          After the reboot:"
  echo "              omarchy-server-apparmor status     # which profiles loaded"
  echo "              omarchy-server-apparmor denials    # what would have been refused"
  echo "              sudo omarchy-server-apparmor enforce"
  echo "          Go to enforce only once \`denials\` is quiet under the workload"
  echo "          this machine actually runs."
}

omarchy_apparmor_setup
