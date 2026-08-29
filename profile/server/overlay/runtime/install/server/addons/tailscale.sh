# Setup leaf for the `tailscale` addon, sourced by omarchy-server-addon.
#
# Enabling the daemon is all that can be automated: joining a tailnet needs an
# auth key or an interactive login, which is `tailscale up`'s job. The ISO's
# configure_tailscale phase does that part when the autoinstall drive carries a
# tailscale_authkey file.
systemctl enable tailscaled.service

if [[ -d /run/systemd/system ]]; then
  systemctl start tailscaled.service
  echo "Run 'sudo tailscale up' to join a tailnet."
fi
