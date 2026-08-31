# Router replacement for install/hardware/network.sh and, versus the server
# profile, for install/server/network-server.sh.
#
# A router has at least two NICs with fixed roles: WAN faces the uplink and
# takes a DHCP lease; LAN faces the internal network, holds the gateway address
# and hands out leases. systemd-networkd and systemd-resolved do all of this
# with no networking package added -- the same reason the server profile uses
# them.
#
# Role naming, not interface naming. This host's NICs are not hardcoded (the
# kernel names them enp1s0/enp2s0/eth0 by slot, which is not portable and not
# knowable here). Instead the roles are the stable names `wan0` and `lan0`, and
# the mapping from a physical NIC to a role is one of:
#
#   1. MAC. /etc/omarchy/router/roles.conf carries WAN_MAC=/LAN_MAC=; the
#      omarchy-router-nics command turns those into .link files that rename the
#      matching NIC to wan0/lan0. This is the documented convention.
#   2. A cidata hint. An autoinstall drive may carry a `router-nics` file with
#      the same WAN_MAC=/LAN_MAC= lines; omarchy-cidata-load copies it to
#      /root, and this script seeds roles.conf from it when roles.conf has not
#      already been filled in.
#
# Until a role is assigned, wan0/lan0 simply do not exist, so nothing is
# forwarded and the machine is a plain headless SSH host on whatever NIC got a
# lease -- a safe unconfigured state, not an open one.

install -d -m 0755 /etc/systemd/network /etc/omarchy/router

# --- role configuration -------------------------------------------------
roles_conf=/etc/omarchy/router/roles.conf
if [[ ! -f $roles_conf ]]; then
  # Seed from a cidata hint when one was supplied, otherwise write an empty
  # template the operator fills in and re-applies with `omarchy-router-nics`.
  if [[ -r /root/router-nics ]]; then
    install -m 0644 /root/router-nics "$roles_conf"
  else
    cat >"$roles_conf" <<'EOF'
# Omarchy Router: which physical NIC plays which role. Fill in the MAC
# addresses (lower-case, colon-separated) and run `omarchy-router-nics` to
# generate the systemd .link files that rename them to wan0 and lan0.
#
#   WAN_MAC=aa:bb:cc:dd:ee:ff
#   LAN_MAC=aa:bb:cc:dd:ee:00
#
# Leave a role blank to not assign it. With no WAN there is no uplink and no
# NAT; with no LAN the machine is a plain SSH host. Optional overrides:
#   LAN_ADDRESS=10.55.0.1/24   the gateway address handed to lan0
#   LAN_DHCP=yes               run a DHCP server on lan0 (default yes)
WAN_MAC=
LAN_MAC=
EOF
    chmod 0644 "$roles_conf"
  fi
fi

# --- role-named .network units ------------------------------------------
# wan0: DHCP client on the uplink.
cat >/etc/systemd/network/10-omarchy-wan.network <<'EOF'
# Omarchy Router: the WAN uplink. Renamed to wan0 by a .link file that
# omarchy-router-nics writes from /etc/omarchy/router/roles.conf.
[Match]
Name=wan0

[Network]
DHCP=yes
IPv6AcceptRA=yes
# The router's own resolver; LAN clients are pointed at lan0 (below), not here.
DNSSEC=no

[DHCPv4]
UseDomains=yes
EOF
chmod 0644 /etc/systemd/network/10-omarchy-wan.network

# lan0: static gateway address, and a DHCP server for the internal network.
# The address and DHCP toggle come from roles.conf so a deployment can move the
# subnet without editing this file.
lan_address=10.55.0.1/24
lan_dhcp=yes
# shellcheck disable=SC1090
[[ -r $roles_conf ]] && source "$roles_conf"
[[ -n ${LAN_ADDRESS:-} ]] && lan_address="$LAN_ADDRESS"
[[ -n ${LAN_DHCP:-} ]] && lan_dhcp="$LAN_DHCP"

{
  cat <<EOF
# Omarchy Router: the internal LAN. Renamed to lan0 by a .link file that
# omarchy-router-nics writes from /etc/omarchy/router/roles.conf.
[Match]
Name=lan0

[Network]
Address=$lan_address
EOF
  if [[ $lan_dhcp == yes ]]; then
    cat <<'EOF'
# A DHCP server straight from networkd: no dnsmasq, no extra package. Clients
# get the gateway (lan0's address) and this router as their resolver.
DHCPServer=yes

[DHCPServer]
EmitDNS=yes
DNS=_server_address
EOF
  fi
} >/etc/systemd/network/20-omarchy-lan.network
chmod 0644 /etc/systemd/network/20-omarchy-lan.network

# Turn roles.conf into .link files now, so a machine that was handed its MACs
# (by the operator or by cidata) comes up with wan0/lan0 already named.
if [[ -x $OMARCHY_PATH/bin/omarchy-router-nics ]]; then
  "$OMARCHY_PATH/bin/omarchy-router-nics" --apply || true
fi

# --- IP forwarding ------------------------------------------------------
# A router forwards; a server does not. Persisted as a sysctl drop-in so it
# survives reboots and is visible where an operator looks for it.
cat >/etc/sysctl.d/30-omarchy-router.conf <<'EOF'
# Omarchy Router: forward packets between interfaces. This is the one setting
# that turns a multi-homed host into a router; the firewall
# (/etc/nftables.conf, the `inet tui` table) decides what forwarding is
# allowed. Written by install/router/network-router.sh.
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
chmod 0644 /etc/sysctl.d/30-omarchy-router.conf

# --- resolved -----------------------------------------------------------
# resolved's stub resolver, so /etc/resolv.conf is a symlink into /run rather
# than a file the DHCP client rewrites. Not inside the ISO's install chroot,
# where /etc/resolv.conf is a bind mount (the ISO writes the symlink from its
# configure_dns_resolver phase); this block makes the script correct on its own
# when re-applied on a running machine.
if ! mountpoint -q /etc/resolv.conf 2>/dev/null &&
  { [[ ! -L /etc/resolv.conf ]] ||
    [[ $(readlink /etc/resolv.conf) != *stub-resolv.conf ]]; }; then
  ln -sfn ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi

# iwd competes with whatever manages the link and has no place on a wired
# router. Disabled rather than removed: it is not installed in this profile.
systemctl disable iwd.service 2>/dev/null || true

# Never block boot on DHCP: the WAN lease may not be ready, and the LAN side
# does not wait on anyone.
systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true
