# Router replacement for install/hardware/network.sh and, versus the server
# profile, for install/server/network-server.sh.
#
# A router has at least two NICs with fixed roles: WAN faces the uplink and
# takes a DHCP lease; LAN faces the internal network, holds the gateway address
# and hands out leases. systemd-networkd and systemd-resolved do all of this
# with no networking package added -- the same reason the server profile uses
# them.
#
# Roles, not renamed interfaces. This host's NICs keep their kernel names
# (enp1s0/eth0/...); the WAN and LAN are ROLES assigned to them, the way
# OPNsense assigns a role to a physical port. The mapping lives in
# /etc/omarchy/router/roles.conf, both forms editable and reassignable:
#
#   WAN_IF=/LAN_IF=    by interface name
#   WAN_MAC=/LAN_MAC=  by MAC, matched to the interface that carries it now
#
# An autoinstall drive may carry a `router-nics` file with the same lines;
# omarchy-cidata-load copies it to /root and this script seeds roles.conf from
# it. Until BOTH roles are assigned nothing is forwarded and every interface
# takes a DHCP lease, so the machine is a plain reachable SSH host -- a safe
# unconfigured state, not an open one and not a locked-out one.

install -d -m 0755 /etc/systemd/network /etc/omarchy/router

# --- role configuration -------------------------------------------------
roles_conf=/etc/omarchy/router/roles.conf
if [[ ! -f $roles_conf ]]; then
  if [[ -r /root/router-nics ]]; then
    install -m 0644 /root/router-nics "$roles_conf"
  else
    cat >"$roles_conf" <<'EOF'
# Omarchy Router: which interfaces play which role. Each role is a SET -- list
# more than one for several uplinks or several LAN ports. Assign by name or by
# MAC (both editable; reassigning is just editing here and re-applying):
#
#   WAN_IFS="enp1s0"                 # one or more uplinks, by name
#   WAN_MACS="aa:bb:cc:dd:ee:ff"     # or by MAC (survives a name change)
#   LAN_IFS="enp2s0 enp3s0"          # one LAN port, or several -> bridged
#   LAN_MACS=""
#
# Several WAN uplinks means failover between them (lowest-metric reachable
# default). Several LAN ports are bridged into br-lan as one segment. VLANs,
# separate LAN subnets, and per-IP routing on a shared port are rules you add
# with tui-network / tui-firewall, not guessed here.
#
# Re-apply after editing:
#   sudo omarchy-router-nics --apply    # rewrites the .network units
#   sudo omarchy-router-firewall        # rescopes /etc/nftables.conf
#
# Until BOTH roles have an interface the machine is a plain SSH host on a DHCP
# lease, forwarding nothing. Optional LAN overrides:
#   LAN_ADDRESS=10.55.0.1/24   the gateway address the LAN holds
#   LAN_DHCP=yes               run a DHCP server on the LAN (default yes)
WAN_IFS=
WAN_MACS=
LAN_IFS=
LAN_MACS=
EOF
    chmod 0644 "$roles_conf"
  fi
fi

# --- resolve roles to sets of real interface names ----------------------
WAN_IFS="" LAN_IFS="" WAN_MACS="" LAN_MACS="" LAN_ADDRESS="" LAN_DHCP=""
# shellcheck disable=SC1090
[[ -r $roles_conf ]] && source "$roles_conf"

resolve_set() { # resolve_set "<ifs>" "<macs>" -> space-separated device names
  local ifs="$1" macs="$2" out=() name mac d
  for name in $ifs; do out+=("$name"); done
  for mac in $macs; do
    mac="${mac,,}"
    for d in /sys/class/net/*; do
      [[ -r $d/address ]] || continue
      [[ "$(cat "$d/address" 2>/dev/null)" == "$mac" ]] && { out+=("$(basename "$d")"); break; }
    done
  done
  printf '%s' "${out[*]}"
}
read -r -a wan_devs <<<"$(resolve_set "$WAN_IFS" "$WAN_MACS")"
read -r -a lan_devs <<<"$(resolve_set "$LAN_IFS" "$LAN_MACS")"

lan_address=10.55.0.1/24
lan_dhcp=yes
[[ -n $LAN_ADDRESS ]] && lan_address="$LAN_ADDRESS"
[[ -n $LAN_DHCP ]] && lan_dhcp="$LAN_DHCP"

# Start clean so a reassignment leaves no stale unit behind.
rm -f /etc/systemd/network/1*-omarchy-wan-*.network \
  /etc/systemd/network/20-omarchy-lan.network \
  /etc/systemd/network/2*-omarchy-lan-member-*.network \
  /etc/systemd/network/25-omarchy-br-lan.netdev \
  /etc/systemd/network/50-omarchy-unassigned.network

# --- WAN uplinks: each is its own DHCP client ---------------------------
# Several uplinks means several default routes; the kernel uses the reachable
# one of lowest metric and fails over to the next, which is the gateways view
# tui-network shows. No bridging: uplinks stay independent.
wi=0
for dev in "${wan_devs[@]}"; do
  wi=$((wi + 1))
  cat >"/etc/systemd/network/10-omarchy-wan-$wi.network" <<EOF
# Omarchy Router: WAN uplink $wi, the interface the WAN role points at.
[Match]
Name=$dev

[Network]
DHCP=yes
IPv6AcceptRA=yes
DNSSEC=no

[DHCPv4]
UseDomains=yes
RouteMetric=$((100 + wi))
EOF
  chmod 0644 "/etc/systemd/network/10-omarchy-wan-$wi.network"
done

# --- LAN: one port is the LAN; several ports are bridged into one ---------
lan_iface=""
if ((${#lan_devs[@]} == 1)); then
  lan_iface="${lan_devs[0]}"
elif ((${#lan_devs[@]} > 1)); then
  # Bridge the LAN ports into br-lan: one L2 segment, one subnet -- the "LAN
  # switch" a small router is expected to be. VLANs and separate LAN subnets
  # are the operator's to build on top with tui-network.
  lan_iface="br-lan"
  cat >/etc/systemd/network/25-omarchy-br-lan.netdev <<'EOF'
# Omarchy Router: the LAN bridge that joins the LAN ports into one segment.
[NetDev]
Name=br-lan
Kind=bridge
EOF
  chmod 0644 /etc/systemd/network/25-omarchy-br-lan.netdev
  mi=0
  for dev in "${lan_devs[@]}"; do
    mi=$((mi + 1))
    cat >"/etc/systemd/network/22-omarchy-lan-member-$mi.network" <<EOF
# Omarchy Router: LAN port $mi, enslaved to br-lan.
[Match]
Name=$dev

[Network]
Bridge=br-lan
EOF
    chmod 0644 "/etc/systemd/network/22-omarchy-lan-member-$mi.network"
  done
fi

if [[ -n $lan_iface ]]; then
  {
    cat <<EOF
# Omarchy Router: the internal LAN, the gateway address and its DHCP server.
[Match]
Name=$lan_iface

[Network]
Address=$lan_address
EOF
    if [[ $lan_dhcp == yes ]]; then
      cat <<'EOF'
DHCPServer=yes

[DHCPServer]
EmitDNS=yes
DNS=_server_address
EOF
    fi
  } >/etc/systemd/network/20-omarchy-lan.network
  chmod 0644 /etc/systemd/network/20-omarchy-lan.network
fi

# Unconfigured (or half-configured): every interface with no role takes a DHCP
# lease, so a freshly installed router is reachable to be configured. The
# high number keeps it from stealing an interface a role unit (a lower number)
# already claimed -- networkd applies the first matching unit.
if ((${#wan_devs[@]} == 0 || ${#lan_devs[@]} == 0)); then
  cat >/etc/systemd/network/50-omarchy-unassigned.network <<'EOF'
# Omarchy Router: interfaces with no role yet. DHCP so the machine is reachable
# while the operator assigns WAN and LAN.
[Match]
Name=en* eth*

[Network]
DHCP=yes
IPv6AcceptRA=yes
DNSSEC=no
EOF
  chmod 0644 /etc/systemd/network/50-omarchy-unassigned.network
fi

# --- IP forwarding ------------------------------------------------------
# A router forwards; a server does not. Persisted as a sysctl drop-in. Harmless
# while unconfigured: the firewall's forward chain is policy drop until roles
# scope it, so nothing is forwarded regardless of this switch.
cat >/etc/sysctl.d/30-omarchy-router.conf <<'EOF'
# Omarchy Router: forward packets between interfaces. The firewall
# (/etc/nftables.conf, the `inet tui` table) decides what forwarding is
# allowed. Written by install/router/network-router.sh.
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
chmod 0644 /etc/sysctl.d/30-omarchy-router.conf

# --- resolved -----------------------------------------------------------
# resolved's stub resolver, so /etc/resolv.conf is a symlink into /run rather
# than a file the DHCP client rewrites. Not inside the ISO's install chroot,
# where /etc/resolv.conf is a bind mount; this block makes the script correct on
# its own when re-applied on a running machine.
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
