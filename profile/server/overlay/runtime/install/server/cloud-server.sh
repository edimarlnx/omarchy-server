# Cloud-init for the server profile.
#
# Sourced by install/server/addons/cloud.sh, which the ISO runs inside the
# target chroot when the autoinstall drive names the `cloud` addon, and which
# `omarchy-server-addon cloud` runs on an already installed machine.
# Conventions follow agents/skills/install-scripts.md: no shebang, no exit,
# every path taken from $OMARCHY_INSTALL / $OMARCHY_PATH.
#
# What this leaf decides, and why:
#
#   datasources   NoCloud, ConfigDrive, OpenStack, Oracle, Ec2, None. The list
#                 is closed on purpose: cloud-init's default is to probe every
#                 datasource it ships, which on a machine with none of them
#                 costs a boot delay looking for metadata services that are not
#                 there. NoCloud covers libvirt/Proxmox/QEMU (a seed ISO
#                 labelled `cidata`), ConfigDrive and OpenStack cover the
#                 OpenStack-derived clouds, Oracle covers OCI, Ec2 covers AWS
#                 and everything that imitates its 169.254.169.254. `None` is
#                 last so a machine with no metadata at all finishes its boot
#                 instead of failing a unit.
#
#   the user      no user is baked into the image. The default user is
#                 `omarchy`, password-locked, with no authorized_keys of its
#                 own: it is a NAME for the platform's metadata keys to land
#                 on (Ec2 and Oracle both hand cloud-init a key list and no
#                 user name), not an account. With no keys in the metadata it
#                 is an account nobody can log into -- no password, no key, and
#                 sshd refuses password authentication anyway.
#
#   networking    cloud-init's network rendering is OFF. This profile already
#                 owns /etc/systemd/network/20-wired.network (DHCP on any
#                 wired link, install/server/network-server.sh), and two
#                 sources writing networkd files is how a machine comes up with
#                 an address on one boot and not the next. The cost is that a
#                 platform handing out a static address through its metadata is
#                 not honoured; every cloud this image targets uses DHCP for
#                 the primary VNIC. docs/cloud-image.md records the trade.
#
#   growth        growpart + resizefs, both on. The root is btrfs, which
#                 cloud-init resizes with `btrfs filesystem resize max /`; the
#                 partition underneath it is grown by `growpart` from
#                 cloud-guest-utils. Between them a 40 GiB image fills whatever
#                 boot volume it was launched onto.
#
#   host keys     not here. The image is generalized without ssh host keys and
#                 omarchy-server-firstboot.service regenerates them before sshd
#                 starts, so no two machines from one image share an identity.

omarchy_cloud_write_config() {
  # One file, in cloud.cfg.d/, rather than a patched /etc/cloud/cloud.cfg: the
  # distribution's own cloud.cfg is upgraded by pacman and a modified one
  # becomes a .pacnew nobody reads. 05- sorts early enough to be overridden by
  # anything an operator drops in later.
  install -Dm644 /dev/stdin /etc/cloud/cloud.cfg.d/05-omarchy-server.cfg <<'EOF'
# Installed by install/server/cloud-server.sh (the `cloud` addon).
# Drop a higher-numbered file in this directory to override any of it.

# Closed list: probing datasources this image will never meet costs boot time.
datasource_list: [ NoCloud, ConfigDrive, OpenStack, Oracle, Ec2, None ]

# The image ships no user and no password. The metadata is the only source of
# an account, and sshd refuses password authentication regardless.
disable_root: true
ssh_pwauth: false
allow_public_ssh_keys: true

# The hostname comes from the metadata on every boot; a generalized image has
# no hostname worth preserving.
preserve_hostname: false

# Fill the boot volume the image was launched onto. resize_rootfs handles the
# btrfs side (`btrfs filesystem resize max /`), growpart the partition under it.
resize_rootfs: true
growpart:
  mode: auto
  devices: [ '/' ]
  ignore_growroot_disabled: false

# This profile owns its networkd configuration; see the header of
# install/server/cloud-server.sh for why cloud-init does not also write it.
network:
  config: disabled

system_info:
  distro: arch
  default_user:
    name: omarchy
    gecos: Omarchy Server
    # No password, ever: locked here and never set by anything downstream.
    lock_passwd: true
    groups: [ wheel ]
    sudo: [ "ALL=(ALL:ALL) NOPASSWD:ALL" ]
    shell: /bin/bash
  ssh_svcname: sshd
  paths:
    cloud_dir: /var/lib/cloud/
    templates_dir: /etc/cloud/templates/
EOF
}

omarchy_cloud_enable_units() {
  # cloud-init has renamed and split its units more than once (cloud-init.service
  # became cloud-init-network.service, cloud-init-main.service appeared), and an
  # image that silently enables three of four boots without ever applying the
  # metadata. Enable what this installation actually ships and say what was
  # found, so a version bump surfaces here instead of on a customer's first boot.
  local unit enabled=()
  for unit in \
    cloud-init-local.service \
    cloud-init-main.service \
    cloud-init-network.service \
    cloud-init.service \
    cloud-config.service \
    cloud-final.service; do
    # A file test rather than `systemctl cat`: this leaf runs inside the ISO's
    # install chroot as well as on a live machine, and asking the running
    # manager about units in another root is the kind of thing that works until
    # it does not.
    if [[ -f /usr/lib/systemd/system/$unit || -f /etc/systemd/system/$unit ]]; then
      systemctl enable "$unit" >/dev/null 2>&1 && enabled+=("$unit")
    fi
  done
  # The target is what those units are ordered inside; enabling it is what makes
  # cloud-init part of the boot rather than four independently enabled services.
  systemctl enable cloud-init.target >/dev/null 2>&1 || true
  echo "cloud: enabled ${enabled[*]:-nothing — cloud-init ships no unit this leaf recognises}"

  # Graceful shutdown and host-side snapshots. The channel device only exists
  # under a hypervisor that offers it; the unit simply does not start elsewhere.
  systemctl enable qemu-guest-agent.service >/dev/null 2>&1 || true
}

omarchy_cloud_enable_firstboot() {
  # The half of first boot that is NOT metadata: the ssh host identity a
  # generalized image deliberately does not carry, and the Secure Boot keys a
  # shared image must not carry. omarchy-server-firstboot does both, once.
  systemctl enable omarchy-server-firstboot.service >/dev/null 2>&1 ||
    echo "cloud: omarchy-server-firstboot.service is not installed; the image will not regenerate its ssh host keys" >&2
}

omarchy_cloud_setup() {
  if ! command -v cloud-init >/dev/null; then
    echo "cloud: cloud-init is not installed; nothing to set up." >&2
    echo "       Run \`omarchy-server-addon cloud\` to install it." >&2
    return 0
  fi

  omarchy_cloud_write_config
  omarchy_cloud_enable_units
  omarchy_cloud_enable_firstboot

  echo
  echo "cloud: cloud-init will configure hostname, users and ssh keys at first boot."
  echo "       Turn this machine into a shareable image with:"
  echo "           sudo omarchy-server-generalize --yes"
}

omarchy_cloud_setup
