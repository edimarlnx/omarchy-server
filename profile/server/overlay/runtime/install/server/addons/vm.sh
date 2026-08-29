# Setup leaf for the `vm` addon, sourced by omarchy-server-addon.
#
# The guest agent lets the hypervisor shut the machine down cleanly and freeze
# the filesystems for a consistent snapshot. It listens on a virtio serial port
# rather than on the network, and does nothing on bare metal, which is why it
# is an addon rather than part of the base.
systemctl enable qemu-guest-agent.service

if [[ -d /run/systemd/system ]]; then
  systemctl start qemu-guest-agent.service
fi
