# Secure Boot with keys this machine owns.
#
# Sourced by install/server/addons/secureboot.sh, which the ISO runs inside the
# target chroot when the autoinstall drive carries a `secureboot` marker, and
# which `omarchy-server-addon secureboot` runs on an already installed machine.
# Conventions follow agents/skills/install-scripts.md: no shebang, no exit,
# every path taken from $OMARCHY_INSTALL / $OMARCHY_PATH.
#
# What this leaf sets up, and what it deliberately leaves to other people's
# code:
#
#   keys        `sbctl create-keys` writes a PK/KEK/db triplet under
#               /var/lib/sbctl. They are generated HERE, on the target, at
#               install time, so no two machines share a signing key and no
#               private key ever travels in a package or on the ESP.
#
#   cmdline     /etc/limine-entry-tool.d/omarchy-secureboot.conf appends
#               `lockdown=integrity module.sig_enforce=1`. It sorts after
#               omarchy-defaults.conf, so it appends to the profile's cmdline
#               rather than replacing it. It has to be in place BEFORE the UKI
#               is built, because the cmdline is baked into the UKI -- which is
#               exactly why this runs in the addon phase, ahead of the
#               orchestrator's finalize_limine_boot.
#
#   signing     nothing. limine-entry-tool already signs the Limine EFI binary
#               (limine-common-functions' sb_sign, called from enroll_config,
#               which runs as /etc/boot/hooks/post.d/90-limine-enroll-config at
#               the end of every limine-install), and mkinitcpio already signs
#               the UKI (/usr/lib/initcpio/post/sbctl, run on the temporary
#               file before limine-entry-tool copies it to the ESP and records
#               its hash -- so the hash in limine.conf is the hash of the
#               SIGNED image). Both check `sbctl setup --print-state`, so
#               creating the keys above is the whole switch. sbctl's own
#               zz-sbctl.hook re-signs every file in its database after any
#               pacman transaction that touches boot/, which is what keeps a
#               kernel upgrade signed.
#
#               The files still have to be IN sbctl's database for sign-all to
#               reach them, which is what the `sbctl sign -s` calls below do.
#
#   enrollment  not here. Handing the firmware a PK while the ESP still holds
#               an unsigned binary is how a machine stops booting. The
#               orchestrator enrolls after finalize_limine_boot, once
#               `sbctl verify` passes; on an installed machine the operator
#               runs `omarchy-server-secureboot enroll`.

omarchy_sb_esp_mount() {
  local esp=""

  # Written by the installer's _write_limine_defaults and by limine-entry-tool
  # afterwards; the only record of where this machine's ESP is mounted.
  if [[ -r /etc/default/limine ]]; then
    esp=$(sed -n 's/^[[:space:]]*ESP_PATH=["'\'']\{0,1\}\([^"'\'']*\).*/\1/p' /etc/default/limine | tail -n 1)
  fi

  printf '%s' "${esp:-/boot}"
}

omarchy_sb_create_keys() {
  # `sbctl setup --print-state` is the same probe limine-entry-tool and
  # mkinitcpio's sbctl hook use to decide whether to sign, so asking it here is
  # asking the question those hooks will ask later.
  if [[ $(sbctl setup --print-state --json 2>/dev/null) == *'"installed": true'* ]]; then
    echo "secure boot: keys already present under /var/lib/sbctl"
    return 0
  fi

  echo "secure boot: creating machine-local PK/KEK/db"
  sbctl create-keys
}

omarchy_sb_protect_keys() {
  # sbctl writes the private keys 0400 root but leaves the directories 0755,
  # so every local account can see which keys exist and stat them. Nothing but
  # root and the hooks that run as root ever reads this tree.
  [[ -d /var/lib/sbctl ]] || return 0
  chmod 0700 /var/lib/sbctl
  find /var/lib/sbctl -type d -exec chmod 0700 {} +
}

omarchy_sb_write_cmdline_dropin() {
  # lockdown=integrity: Arch builds the lockdown LSM in and lists it in
  # CONFIG_LSM, but leaves it off (CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE), so
  # Secure Boot alone does not lock the kernel down. `integrity` is the mode
  # that closes the paths which would let root replace the running kernel
  # (/dev/mem, kexec of an unsigned image, unsigned module loading, hibernation
  # to an unverified image) while leaving the ones that only read kernel memory
  # -- `confidentiality` would also break perf and BPF, which a server actually
  # uses.
  #
  # module.sig_enforce=1: says the same thing about modules explicitly, so it
  # holds even on a boot where lockdown is not in force. Arch signs the in-tree
  # modules with an ephemeral key whose public half is built into the kernel,
  # so the stock module set loads; an out-of-tree module has to be signed with
  # this machine's db key (see docs/secure-boot.md, "Out-of-tree modules").
  install -Dm644 /dev/stdin /etc/limine-entry-tool.d/omarchy-secureboot.conf <<'EOF'
# Installed by install/server/secureboot-server.sh. Read after
# omarchy-defaults.conf (limine-entry-tool globs *.conf in sorted order), so
# this appends to the profile's cmdline instead of replacing it.
#
# The cmdline is embedded in the signed UKI, which is what makes it part of
# what Secure Boot actually protects: limine reads limine.conf off an
# unauthenticated FAT partition, and the `cmdline:` it finds there is ignored
# for a UKI entry.
KERNEL_CMDLINE[default]+=" lockdown=integrity module.sig_enforce=1"
EOF
}

omarchy_sb_register_esp_binaries() {
  local esp file
  esp=$(omarchy_sb_esp_mount)

  # `sbctl sign -s`: sign now and record the path, so `sbctl sign-all` (the
  # zz-sbctl.hook) reaches it after every future transaction. A file that does
  # not exist yet is not an error: on a fresh install the UKI is built later,
  # by finalize_limine_boot, and mkinitcpio's sbctl hook signs it there.
  for file in \
    "$esp/EFI/limine/limine_x64.efi" \
    "$esp/EFI/BOOT/BOOTX64.EFI" \
    "$esp/EFI/Linux/omarchy_linux.efi"; do
    if [[ -f $file ]]; then
      echo "secure boot: signing $file"
      sbctl sign -s "$file" || echo "secure boot: failed to sign $file" >&2
    else
      echo "secure boot: $file not built yet, it will be signed when it is"
    fi
  done
}

omarchy_sb_setup() {
  if ! command -v sbctl >/dev/null; then
    echo "secure boot: sbctl is not installed; nothing to set up." >&2
    echo "             Run \`omarchy-server-addon secureboot\` to install it." >&2
    return 0
  fi

  omarchy_sb_create_keys || return 1
  omarchy_sb_protect_keys
  omarchy_sb_write_cmdline_dropin
  omarchy_sb_register_esp_binaries

  echo
  echo "secure boot: keys are in place and the boot chain will be signed."
  echo "             Enroll them into the firmware with:"
  echo "                 sudo omarchy-server-secureboot enroll"
  echo "             The firmware must be in Setup Mode (no PK) for that to work."
}

omarchy_sb_setup
