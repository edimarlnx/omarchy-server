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
#               install/server/mac/selinux/local-fcontexts, written into the
#               policy store's file_contexts.local -- the same file semanage
#               writes, in the same format, without needing selinux-python on
#               the machine. The reference policy has never heard of
#               /usr/share/omarchy/bin and labels it usr_t -- data, not
#               programs -- and that is the one thing the policy gets wrong
#               about this profile out of the box.
#
#               A local policy MODULE ships only when a measured denial called
#               for it: an omarchy_server.te beside local-fcontexts is compiled
#               with checkmodule and installed with semodule.
#
#   admin       the administrative role. Members of `wheel` are mapped to the
#               SELinux user staff_u (seusers.local) and sudoers is given
#               `role=sysadm_r, type=sysadm_t` for that group, so the operator
#               logs in confined as staff_t and reaches sysadm_t through sudo.
#               Without it, enforcing means an administrator who cannot run
#               pacman, ufw or systemctl and cannot switch back to permissive
#               over ssh -- a one-way door, measured in
#               reports/2026-08-29-mandatory-access-control.md §10.6. The work
#               is in `omarchy-server-selinux admin-role`, called from here so
#               the machine is never installed without it.
#
#   labels      the filesystem is relabelled HERE, offline, with `setfiles`
#               over file_contexts + file_contexts.homedirs +
#               file_contexts.local concatenated. A relabel is minutes of I/O;
#               doing it during the install, where the machine is already busy
#               writing, is cheaper than doing it on the first boot with
#               somebody watching.
#
#               Concatenated, because setfiles reads exactly the one spec file
#               it is given, and the entry that gives /home/<user> its
#               user_home_dir_t lives in file_contexts.homedirs. Getting that
#               wrong is half of the lockout in
#               reports/2026-08-29-mandatory-access-control.md.
#
#               And then AGAIN, once, on the first boot. /.autorelabel is left
#               in place and omarchy-server-selinux-relabel.service acts on it
#               -- selinux-refpolicy-arch ships no such unit, so this profile
#               ships one. That is the other half: the orchestrator creates the
#               user's home directory in a phase that runs after this addon, so
#               the offline pass cannot have labelled a directory that did not
#               exist. The unit is ordered before systemd-user-sessions.service
#               so no login can happen against unlabeled paths.

OMARCHY_SELINUX_TYPE=refpolicy-arch
OMARCHY_SELINUX_STORE=/etc/selinux/$OMARCHY_SELINUX_TYPE

# shellcheck source=./mac-server.sh
source "$OMARCHY_INSTALL/server/mac-server.sh"

omarchy_selinux_require_userland() {
  local missing=() command
  # No `semanage` in this list any more. It lives in selinux-python, which
  # together with setools is 45 packages and 453 MiB of scientific Python on a
  # headless server, and it moved to the `selinux-tools` addon. Everything this
  # leaf needs is in policycoreutils, checkpolicy and semodule-utils.
  for command in load_policy semodule semodule_package checkmodule setfiles restorecon; do
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

# The profile's own file contexts, written straight into the policy store's
# file_contexts.local -- the same file `semanage fcontext -a` writes, in the
# same format, at the path libselinux's selinux_file_context_local_path()
# returns. Writing it directly is what lets the `selinux` addon drop
# selinux-python (and with it setools and 453 MiB of scientific Python; see
# addons/selinux-tools.packages).
#
# This is not a shortcut around semanage's bookkeeping: file_contexts.local is
# a plain spec file, semanage's only extra work on it is to rewrite it whole
# from its own record, and `restorecon` loads it by name whether semanage or
# this function put it there. It survives a policy upgrade for the same reason
# semanage's copy does -- the package owns file_contexts, not this file.
#
# Not a policy module either: checkmodule rejects a module whose only content
# is a file-context file (it needs at least one rule). When a measured denial
# calls for a rule, an `omarchy_server.te` beside this file is built and
# installed by omarchy_selinux_build_local_module below.
# The level suffix, or the absence of one. refpolicy-arch is built
# TYPE=standard (its include/build.conf), so it is NOT an MLS policy and a
# valid context has three fields: user:role:type. Writing the four-field
# `system_u:object_r:bin_t:s0` that an MLS policy would use produces
#
#     setfiles: <spec>: line N has invalid context system_u:object_r:bin_t:s0
#
# and the rule is DROPPED -- silently, as far as the addon is concerned, since
# setfiles still exits 0. Measured: it left /usr/share/omarchy/bin unlabeled on
# a machine whose relabel had otherwise worked.
#
# Rather than hard-coding either form, ask the policy's own file_contexts what
# shape its contexts have. A policy store swapped for an MLS one then keeps
# working.
omarchy_selinux_context_suffix() {
  local file_contexts="$OMARCHY_SELINUX_STORE/contexts/files/file_contexts"
  local context

  context=$(grep -Ev '^[[:space:]]*(#|$)' "$file_contexts" 2>/dev/null |
    awk '{print $NF}' | grep -m1 ':')
  # Four colon-separated fields means the last one is a level.
  if [[ $context == *:*:*:* ]]; then
    printf ':%s' "${context##*:}"
  fi
}

omarchy_selinux_add_fcontexts() {
  local source="$OMARCHY_INSTALL/server/mac/selinux/local-fcontexts"
  local target="$OMARCHY_SELINUX_STORE/contexts/files/file_contexts.local"
  local suffix path type

  [[ -f $source ]] || return 0
  suffix=$(omarchy_selinux_context_suffix)

  # Rewritten whole rather than appended to, so a re-run is idempotent and a
  # line removed from the profile disappears from the machine.
  {
    echo "# Written by install/server/selinux-server.sh from"
    echo "# install/server/mac/selinux/local-fcontexts. Do not edit by hand:"
    echo "# the addon rewrites this file whole on every run."
    while read -r path type _; do
      [[ -z $path || $path == \#* ]] && continue
      printf '%s\tsystem_u:object_r:%s%s\n' "$path" "$type" "$suffix"
    done <"$source"
  } >"$target"

  while read -r path type _; do
    [[ -z $path || $path == \#* ]] && continue
    echo "selinux: fcontext $path -> ${type}${suffix}"
  done <"$source"
}

# file_contexts.homedirs, and why this function exists at all.
#
# The reference policy labels /home `home_root_t` in its base file_contexts and
# says nothing there about what is INSIDE /home. The entries that give
# /home/<user> `user_home_dir_t` live in file_contexts.homedirs, which
# libsemanage generates (genhomedircon) when the policy store is rebuilt --
# generically, as /home/[^/]+ and /home/[^/]+/.*, so it does not matter that no
# user account exists yet when this runs in the install chroot.
#
# `semodule -B` rebuilds the store and regenerates it. Cheap, and it also
# expands the local module installed just above.
# The policy's own tunables, written the same way seusers.local and
# file_contexts.local are: straight into the store's booleans.local, which is
# the file `semanage boolean` writes, in the same format, at the same path, and
# which `semodule -B` merges. No selinux-python, and it works in the install
# chroot where `setsebool -P` cannot (it needs a mounted selinuxfs).
#
# One boolean, and it is not cosmetic. `cloudinit_growpart` is refpolicy's
# switch for letting cloud-init read the block device it is about to grow, and
# it ships OFF. With it off and the machine enforcing, cc_growpart is refused
# `read` on /dev/vda2, cloud-init reports
#
#     errors: - ('growpart', PermissionError(13, 'Permission denied'))
#
# and cloud-init-main.service fails -- which on a cloud image means a machine
# that came up on the 40 GiB of its image inside a 200 GiB boot volume, with
# the failure visible only to somebody who runs `cloud-init status --long`.
# Measured on the first enforcing boot of the image this file builds.
#
# Turning it on is what refpolicy expects of a machine that actually runs
# cloud-init: it is a boolean rather than a rule precisely because "does this
# machine let cloud-init resize its disk" is a per-machine question, and on an
# image whose whole purpose is being launched onto a bigger volume the answer
# is yes. On a machine with no cloud-init the boolean gates rules for a domain
# that never runs.
omarchy_selinux_write_booleans() {
  local target=/var/lib/selinux/$OMARCHY_SELINUX_TYPE/active/booleans.local

  [[ -d $(dirname "$target") ]] || return 0
  {
    echo "# Written by install/server/selinux-server.sh."
    echo "cloudinit_growpart=1"
  } >"$target"
  echo "selinux: booleans.local -> cloudinit_growpart=1"
}

omarchy_selinux_rebuild_store() {
  local homedirs="$OMARCHY_SELINUX_STORE/contexts/files/file_contexts.homedirs"

  echo "selinux: rebuilding the policy store"
  if ! semodule -s "$OMARCHY_SELINUX_TYPE" -B; then
    echo "selinux: semodule -B failed; the policy store may be incomplete" >&2
    return 1
  fi

  if [[ ! -s $homedirs ]]; then
    echo "selinux: WARNING -- no file_contexts.homedirs after the rebuild." >&2
    echo "         /home/<user> would be relabelled to nothing, which locks the" >&2
    echo "         operator out the moment this machine goes enforcing." >&2
    return 1
  fi
  echo "selinux: file_contexts.homedirs has $(grep -c . "$homedirs") entries"
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
  # `restorecon -R /`, and NOT `setfiles <file_contexts> /`.
  #
  # libselinux's label_file backend loads three spec files when it opens the
  # store by policy type -- file_contexts, then file_contexts.homedirs, then
  # file_contexts.local -- and exactly ONE when it is handed a path.
  # `setfiles` requires the path. So `setfiles <file_contexts> /` relabelled
  # against the base file alone: /home got home_root_t from it, /home/<user>
  # matched nothing (its /home/[^/]+ -> user_home_dir_t entry is in
  # file_contexts.homedirs) and stayed unlabeled, and this profile's own
  # /usr/share/omarchy/bin rule (file_contexts.local) was never applied.
  # That is half of the enforcing lockout in
  # reports/2026-08-29-mandatory-access-control.md.
  #
  # Concatenating the three into one spec for setfiles is NOT the fix, and was
  # tried: the three files legitimately specify the same path twice --
  # /root/.k5login is krb5_home_t under system_u in the base and under root in
  # homedirs -- and libselinux resolves that by letting the later file win,
  # while setfiles rejects the whole spec with "Multiple different
  # specifications" and relabels nothing. Only the loader has the precedence
  # rules; use the loader.
  #
  # -R recursive, -F reset a context that is already set (the point on a
  # filesystem written before any policy existed), -i ignore paths in the spec
  # that do not exist here, -e the pseudo-filesystems, which have no xattrs and
  # are labelled by the kernel at mount time.
  #
  # /.snapshots is excluded for a different reason and it is not cosmetic: this
  # profile keeps five snapper snapshots, snapper mounts them READ-ONLY, and
  # restorecon reports "Could not set context ...: Read-only file system" for
  # every file in every one of them and exits non-zero. On a machine that has
  # ever taken a snapshot, a relabel without this exclusion always "fails" --
  # which would leave /.autorelabel in place and make `enforcing` refuse
  # forever. A read-only snapshot of a past root is not part of the running
  # system's label set anyway; the subvolume gets relabelled when it is
  # rolled back into place.
  if restorecon -R -F -i \
    -e /dev -e /proc -e /sys -e /run -e /tmp -e /var/lib/machines -e /.snapshots /; then
    # The flag STAYS, and the unit enabled below acts on it at the first boot.
    # This pass cannot have covered everything: the orchestrator creates the
    # user's home directory in a phase that runs AFTER this addon, so on a
    # fresh install /home/<user> does not exist yet when this finishes. An
    # unlabeled home is invisible in permissive and locks the operator out the
    # moment SELinux goes enforcing.
    touch /.autorelabel
  else
    echo "selinux: restorecon reported errors; see above" >&2
    echo "         Leaving /.autorelabel as a marker. Repair with:" >&2
    echo "             sudo omarchy-server-selinux relabel" >&2
    touch /.autorelabel
  fi
}

# Did the relabel actually apply this profile's own rules?
#
# Neither setfiles nor restorecon fails when a spec line carries a context the
# policy rejects: the rule is dropped, the tool carries on and exits 0, and the
# paths it named stay unlabeled. That is not hypothetical -- a four-field
# `system_u:object_r:bin_t:s0` written into file_contexts.local against this
# non-MLS policy left /usr/share/omarchy/bin as unlabeled_t through two
# relabels without one error line. An exit status cannot be trusted here, so
# check the outcome instead of the mechanism.
omarchy_selinux_verify_labels() {
  local source="$OMARCHY_INSTALL/server/mac/selinux/local-fcontexts"
  local wrong=0 path type context probe

  [[ -f $source ]] || return 0

  # `ls -Z` can only report a context on a kernel that has SELinux running, and
  # this leaf's main caller is the ISO install chroot, where it is not: every
  # path there reads back as `?`. That is not a labelling failure, it is an
  # unanswerable question, and reporting it as a failure would print two
  # warnings on every single install. Check only where the answer means
  # something -- on a live machine, which is where
  # omarchy-server-selinux-relabel.service calls the same code path.
  if [[ ! -d /sys/fs/selinux ]]; then
    echo "selinux: (labels cannot be read while SELinux is inactive; the"
    echo "         first-boot relabel verifies them)"
    return 0
  fi

  while read -r path type _; do
    [[ -z $path || $path == \#* ]] && continue
    # The spec is a regex; the directory it is rooted at is the literal prefix
    # before the first regex metacharacter, and that is what can be checked.
    probe=${path%%[\(\[\*\?]*}
    probe=${probe%/}
    [[ -e $probe ]] || continue
    context=$(ls -Zd "$probe" 2>/dev/null | awk '{print $1}')
    if [[ $context != *":$type"* ]]; then
      echo "selinux: WARNING -- $probe is $context, but the profile asked for $type" >&2
      wrong=1
    fi
  done <"$source"

  if ((wrong)); then
    echo "selinux: the profile's own file contexts did not take. Leaving" >&2
    echo "         /.autorelabel so the first boot tries again, and check" >&2
    echo "         $OMARCHY_SELINUX_STORE/contexts/files/file_contexts.local" >&2
    touch /.autorelabel
    return 1
  fi
  echo "selinux: the profile's own file contexts are applied on disk"
}

# The first-boot relabel unit. Enabled here rather than by the package,
# because a machine without the addon has nothing to relabel and the unit would
# be one more enabled unit on the surface measurement for no reason.
omarchy_selinux_enable_relabel_unit() {
  systemctl enable omarchy-server-selinux-relabel.service
  echo "selinux: omarchy-server-selinux-relabel.service enabled for the first boot"
}

# The administrative role, applied by the runtime command so there is exactly
# one implementation of it and `omarchy-server-selinux admin-role` on an
# already-installed machine does the same thing this install does.
#
# --defer-rebuild because omarchy_selinux_rebuild_store below runs `semodule -B`
# anyway, and that is the step that merges seusers.local into the store; doing
# it twice would add a minute to every install for nothing.
#
# genhomedircon cannot expand `%wheel` here: this runs in the install chroot and
# the orchestrator creates the operator's account in a later phase. That is why
# omarchy-server-selinux-relabel.service rebuilds the store again on the first
# boot, where the account exists, before it relabels.
omarchy_selinux_apply_admin_role() {
  if ! "$OMARCHY_PATH/bin/omarchy-server-selinux" admin-role --defer-rebuild; then
    echo "selinux: WARNING -- the administrative role was not applied." >&2
    echo "         This machine must NOT be put into enforcing until it is:" >&2
    echo "             sudo omarchy-server-selinux admin-role" >&2
    return 1
  fi
}

omarchy_selinux_setup() {
  omarchy_mac_require_exclusive selinux || return 1
  omarchy_selinux_require_userland || return 1

  omarchy_selinux_restore_pam_hardening
  omarchy_selinux_write_config
  omarchy_selinux_write_cmdline_dropin
  omarchy_selinux_add_fcontexts
  omarchy_selinux_build_local_module || true
  omarchy_selinux_apply_admin_role || true
  omarchy_selinux_write_booleans
  # Before the relabel, not after: the relabel reads what this rebuilds, and
  # the rebuild is what merges booleans.local and seusers.local into the store.
  omarchy_selinux_rebuild_store || true
  omarchy_selinux_relabel
  omarchy_selinux_verify_labels || true
  omarchy_selinux_enable_relabel_unit

  omarchy_mac_rebuild_boot

  echo
  echo "selinux: set up in PERMISSIVE mode. It takes effect on the next boot."
  echo "         After the reboot:"
  echo "             omarchy-server-selinux status     # is the policy loaded"
  echo "             id -Z; sudo id -Z                 # staff_t, then sysadm_t"
  echo "             omarchy-server-selinux avc        # what would have been denied"
  echo "             sudo omarchy-server-selinux enforcing"
  echo "         Go to enforcing only once \`avc\` is quiet under the workload"
  echo "         this machine actually runs."
}

omarchy_selinux_setup
