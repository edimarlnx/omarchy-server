# Setup leaf for the `headscale` addon, sourced by omarchy-server-addon after
# the package is installed.
#
# The package ships /etc/headscale/config.yaml as a conffile: upstream's
# example, which runs self-contained (sqlite state, listening on localhost).
# Enabling it gives the operator a live daemon to configure against -- server
# URL, OIDC, DERP are theirs to set, from tui-vpn or the file -- and the unit
# is hardened by the package. On the router, nothing reaches it from the WAN:
# the scoped ruleset only opens 22 and WireGuard.
systemctl enable headscale.service

if [[ -d /run/systemd/system ]]; then
  systemctl start headscale.service
  echo "headscale is running with the example config (localhost, sqlite)."
  echo "Set server_url and friends in /etc/headscale/config.yaml, or manage it with tui-vpn."
fi
