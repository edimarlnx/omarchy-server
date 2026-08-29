# SELinux, in permissive mode, with the Arch reference policy.
#
# Sourced by install/server/addons/selinux.sh, which the ISO runs inside the
# target chroot when the autoinstall drive carries a `selinux` marker, and
# which `omarchy-server-addon selinux` runs on an already installed machine.
# Conventions follow agents/skills/install-scripts.md: no shebang, no exit,
# every path taken from $OMARCHY_INSTALL / $OMARCHY_PATH.
#
# What this leaf sets up:
#
#   pam         the profile's account-lockout hardening, re-applied. Replacing
#               pambase replaces /etc/pam.d/system-auth, which this profile
#               edits in place, and pacman saves the edit as a .pacsave without
#               a word. See omarchy_selinux_restore_pam_hardening below.
#
#   config      /etc/selinux/config -> config.refpolicy-arch, with
#               SELINUX=permissive. Permissive is deliberate and is the state
#               the addon leaves behind: the policy is loaded, every decision
#               is evaluated and logged, and nothing is refused. A machine that
#               went straight to enforcing on a policy nobody has measured
#               against this profile is a machine that may not come back.
#               `omarchy-server-selinux enforcing` is the second step, taken
#               once `omarchy-server-selinux avc` is quiet.
#
#   cmdline     /etc/limine-entry-tool.d/omarchy-lsm-selinux.conf, written by
#               install/server/mac-server.sh: `lsm=...,selinux,bpf` plus
#               `selinux=1 security=selinux`. It has to be in place BEFORE the
#               UKI is built, because the cmdline is baked into the UKI --
#               which is why this runs in the addon phase, ahead of the
#               orchestrator's finalize_limine_boot.
#
#   local       the file contexts this profile adds, from
#               install/server/mac/selinux/local-fcontexts, applied with
#               `semanage fcontext -a`. The reference policy has never heard of
#               /usr/share/omarchy/bin and labels it usr_t -- data, not
#               programs -- and that is the one thing the policy gets wrong
#               about this profile out of the box.
#
#               No local policy MODULE ships today, and that is deliberate: a
#               rule belongs here only when a measured denial called for it.
#               If an omarchy_server.te appears beside local-fcontexts it is
#               built and installed too.
#
#   labels      the filesystem is relabelled HERE, offline, with `setfiles`
#               against the policy's file_contexts. A relabel is minutes of
#               I/O; doing it during the install, where the machine is already
#               busy writing, is cheaper than doing it on the first boot with
#               somebody watching.
#
#               And then AGAIN, once, on the first boot. /.autorelabel is left
#               in place and omarchy-server-selinux-relabel.service acts on it
#               -- selinux-refpolicy-arch ships no such unit, so this profile
#               ships one. It is not belt and braces: the orchestrator creates
#               the user's home directory in a phase that runs after this
#               addon, so the offline pass genuinely cannot have labelled it,
#               and an unlabeled /home/<user> locks the operator out the moment
#               the machine goes enforcing. Measured, in
#               reports/2026-08-29-mandatory-access-control.md.

OMARCHY_SELINUX_TYPE=refpolicy-arch
OMARCHY_SELINUX_STORE=/etc/selinux/$OMARCHY_SELINUX_TYPE

# shellcheck source=./mac-server.sh
source "$OMARCHY_INSTALL/server/mac-server.sh"

omarchy_selinux_require_userland() {
  local missing=() command
  for command in load_policy semodule semodule_package checkmodule setfiles restorecon semanage; do
    command -v "$command" >/dev/null || missing+=("$command")
  done

  if ((${#missing[@]})); then
    echo "selinux: the userland is not installed (${missing[*]} missing)." >&2
    echo "         Run \`omarchy-server-addon selinux\`." >&2
    return 1
  fi
}

# Replacing pambase is not only a package swap: pambase owns
# /etc/pam.d/system-auth, and this profile EDITS that file in place --
# install/server/increase-lockout-limit-server.sh seds `deny=10
# unlock_time=120` into the two pam_faillock lines. When pacman removes pambase
# and installs pambase-selinux it saves the edited file as system-auth.pacsave
# and installs the new package's own, so the account-lockout hardening is
# silently gone. There is no .pacnew and nothing says a word.
#
# Measured, not theorised: the first SELinux install in the lab came up with
# stock faillock lines and the hardened file sitting in
# /etc/pam.d/system-auth.pacsave. Re-applying the leaf is the repair, and it is
# idempotent -- the seds match the stock lines and rewrite them.
#
# This is the general hazard of the rebuild set, and it is why the acceptance
# script checks for it: any profile edit to a file owned by one of the eight
# replaced packages is undone by the replacement.
omarchy_selinux_restore_pam_hardening() {
  # shellcheck disable=SC1090
  source "$OMARCHY_INSTALL/server/increase-lockout-limit-server.sh"

  if grep -q 'pam_faillock.so preauth silent deny=10' /etc/pam.d/system-auth; then
    echo "selinux: re-applied the profile's pam_faillock settings after the pambase replacement"
  else
    echo "selinux: the pam_faillock settings could not be re-applied; check /etc/pam.d/system-auth" >&2
  fi
}

omarchy_selinux_write_config() {
  # The policy package ships /etc/selinux/config.refpolicy-arch and symlinks
  # /etc/selinux/config to it from its own post_install -- but only when no
  # config exists yet. Writing the symlink here as well makes the outcome the
  # same whether the package was installed a moment ago or a year ago.
  if [[ ! -e /etc/selinux/config ]]; then
    ln -sf "config.$OMARCHY_SELINUX_TYPE" /etc/selinux/config
  fi

  # SELINUX= and SELINUXTYPE= are read by the kernel-side init and by every
  # userland tool. Edited in place through the symlink, so an operator who
  # replaced the symlink with a real file keeps their file.
  local config
  config=$(readlink -f /etc/selinux/config)
  sed -i \
    -e "s/^SELINUX=.*/SELINUX=permissive/" \
    -e "s/^SELINUXTYPE=.*/SELINUXTYPE=$OMARCHY_SELINUX_TYPE/" \
    "$config"

  echo "selinux: /etc/selinux/config -> SELINUX=permissive SELINUXTYPE=$OMARCHY_SELINUX_TYPE"
}

omarchy_selinux_write_cmdline_dropin() {
  # selinux=1 security=selinux beside the lsm= list: `lsm=` is what actually
  # decides which modules initialise on a kernel that has CONFIG_LSM, but the
  # policy documentation and every SELinux troubleshooting guide reach for
  # these two, and a kernel that ignores them costs nothing. `selinux=1` also
  # overrides a CONFIG_SECURITY_SELINUX_BOOTPARAM default of 0 on kernels that
  # have one.
  omarchy_mac_write_dropin selinux "selinux=1 security=selinux"
  echo "selinux: kernel command line drop-in written"
}

# The profile's own file contexts. `semanage fcontext -a`, not a policy module:
# checkmodule rejects a module whose only content is a file-context file (it
# needs at least one rule), and this profile has no measured denial that calls
# for a rule. A local fcontext is the supported way to add a label without
# inventing policy; it survives a policy upgrade, and `semanage fcontext -l -C`
# lists exactly what was added here.
#
# When a measured denial does call for a rule, an `omarchy_server.te` beside
# this file is built and installed by omarchy_selinux_build_local_module below.
omarchy_selinux_add_fcontexts() {
  local file="$OMARCHY_INSTALL/server/mac/selinux/local-fcontexts"
  local path type

  [[ -f $file ]] || return 0

  while read -r path type _; do
    [[ -z $path || $path == \#* ]] && continue
    # `-a` fails when the rule is already there, which is the normal state on a
    # re-run; `-m` modifies an existing one. Try to add, fall back to modify.
    if ! semanage fcontext -S "$OMARCHY_SELINUX_TYPE" -N -a -t "$type" "$path" 2>/dev/null; then
      semanage fcontext -S "$OMARCHY_SELINUX_TYPE" -N -m -t "$type" "$path" 2>/dev/null ||
        echo "selinux: could not set the fcontext for $path" >&2
    fi
    echo "selinux: fcontext $path -> $type"
  done <"$file"
}

# A local policy module, when one exists. Plain module syntax -- `module`, not
# `policy_module()` -- so it builds with checkmodule and semodule_package,
# which come with the userland this addon already installs. The refpolicy macro
# form would need `make` and `m4` on the target, and a build toolchain on a
# production server to compile a forty-line policy is the wrong trade. Plain
# syntax is also exactly what `audit2allow -M` emits.
#
# No -M on checkmodule: refpolicy-arch is built TYPE=standard (its
# include/build.conf), so the policy is not MLS and neither is this.
omarchy_selinux_build_local_module() {
  local source_dir="$OMARCHY_INSTALL/server/mac/selinux"
  local module=omarchy_server
  local work

  [[ -f $source_dir/$module.te ]] || return 0

  work=$(mktemp -d)
  if ! checkmodule -m -o "$work/$module.mod" "$source_dir/$module.te"; then
    echo "selinux: $module.te did not compile; the local module is not installed" >&2
    rm -rf "$work"
    return 1
  fi
  semodule_package -o "$work/$module.pp" -m "$work/$module.mod"
  semodule -s "$OMARCHY_SELINUX_TYPE" --noreload -i "$work/$module.pp"
  rm -rf "$work"
  echo "selinux: local policy module '$module' installed"
}

omarchy_selinux_relabel() {
  local file_contexts="$OMARCHY_SELINUX_STORE/contexts/files/file_contexts"

  if [[ ! -f $file_contexts ]]; then
    echo "selinux: no file_contexts at $file_contexts; the relabel cannot run" >&2
    echo "         Leaving /.autorelabel as a marker. Repair with:" >&2
    echo "             sudo omarchy-server-selinux relabel" >&2
    touch /.autorelabel
    return 0
  fi

  echo "selinux: relabelling the filesystem (this takes a few minutes)"
  # -F: reset the context even where one is already set, which is the point on
  # a filesystem that was written before any policy existed.
  # -e: the pseudo-filesystems have no xattrs to write and are labelled by the
  # kernel at mount time.
  if setfiles -F -e /dev -e /proc -e /sys -e /run -e /tmp "$file_contexts" /; then
    # The flag STAYS, and the unit enabled below acts on it at the first boot.
    # This relabel cannot have covered everything: the orchestrator creates the
    # user's home directory in a phase that runs after this addon, so on a
    # fresh install /home/<user> is still unlabeled when setfiles finishes
    # here. That is invisible in permissive and locks the operator out the
    # moment SELinux goes enforcing.
    touch /.autorelabel
  else
    echo "selinux: setfiles reported errors; see above" >&2
    echo "         Leaving /.autorelabel as a marker. Repair with:" >&2
    echo "             sudo omarchy-server-selinux relabel" >&2
    touch /.autorelabel
  fi
}

# The first-boot relabel unit. Enabled here rather than by the package,
# because a machine without the addon has nothing to relabel and the unit would
# be one more enabled unit on the surface measurement for no reason.
omarchy_selinux_enable_relabel_unit() {
  systemctl enable omarchy-server-selinux-relabel.service
  echo "selinux: omarchy-server-selinux-relabel.service enabled for the first boot"
}

omarchy_selinux_setup() {
  omarchy_mac_require_exclusive selinux || return 1
  omarchy_selinux_require_userland || return 1

  omarchy_selinux_restore_pam_hardening
  omarchy_selinux_write_config
  omarchy_selinux_write_cmdline_dropin
  omarchy_selinux_add_fcontexts
  omarchy_selinux_build_local_module || true
  omarchy_selinux_relabel
  omarchy_selinux_enable_relabel_unit

  omarchy_mac_rebuild_boot

  echo
  echo "selinux: set up in PERMISSIVE mode. It takes effect on the next boot."
  echo "         After the reboot:"
  echo "             omarchy-server-selinux status     # is the policy loaded"
  echo "             omarchy-server-selinux avc        # what would have been denied"
  echo "             sudo omarchy-server-selinux enforcing"
  echo "         Go to enforcing only once \`avc\` is quiet under the workload"
  echo "         this machine actually runs."
}

omarchy_selinux_setup
