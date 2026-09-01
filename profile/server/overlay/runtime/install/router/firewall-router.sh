# Router firewall: the default `inet tui` nftables table.
#
# This replaces the server profile's install/server/firewall-server.sh (ufw).
# A router's job is to forward and NAT, which ufw's host-oriented model does
# not express cleanly, and the tui-firewall tool -- the one this profile hands
# the operator through the `tui-tools` addon -- manages a native nftables table
# named `inet tui`. So the profile writes exactly that table as the default,
# and the tool and the seed agree on one manager of one subsystem.
#
# Roles, not renamed interfaces. WAN and LAN are ROLES, each a SET of real
# interfaces (a router can have several uplinks and several LAN ports), the way
# OPNsense assigns ports to a role. The physical NICs keep their kernel names
# (enp1s0, eth0, ...) and the ruleset scopes to them with nftables interface
# sets. The mapping lives in /etc/omarchy/router/roles.conf, both forms editable:
#   WAN_IFS=/LAN_IFS=    by interface name, space-separated
#   WAN_MACS=/LAN_MACS=  by MAC, each matched to the interface that carries it
#
# The default policy once both roles are assigned (router-1.0):
#   input    drop, except: established/related, loopback, ICMP, everything from
#            the LAN, and from the WAN only 22/tcp and the WireGuard UDP port.
#   forward  drop, except: established/related and LAN -> WAN.
#   nat      masquerade out of the WAN.
#
# UNTIL both roles are assigned the machine is a plain, reachable SSH host: the
# ruleset accepts ssh (and WireGuard) on every interface and forwards nothing.
# A router installed headless with no roles yet must be reachable to BE
# configured -- scoping ssh to a WAN that does not exist yet would lock the
# operator out.
#
# "Previewed, not hidden": the ruleset is this plain file at /etc/nftables.conf,
# which nftables.service loads at boot, and `omarchy-router-firewall` prints it
# and re-applies it on confirm. This script only writes the file and enables the
# loader; it never runs `nft` against the live ruleset (it runs inside the ISO's
# install chroot, where there is no router to apply it to).

install -d -m 0755 /etc/omarchy/router

# The WireGuard port the WAN rule opens. A file so a deployment can move it
# without editing the ruleset, and so omarchy-router-firewall reads the same
# value when it regenerates the table.
wg_env=/etc/omarchy/router/wireguard.env
if [[ ! -f $wg_env ]]; then
  cat >"$wg_env" <<'EOF'
# Omarchy Router: the WireGuard listen port opened on the WAN. Change it here
# and run `omarchy-router-firewall` to regenerate /etc/nftables.conf.
WG_PORT=51820
EOF
  chmod 0644 "$wg_env"
fi
wg_port=51820
# shellcheck disable=SC1090
[[ -r $wg_env ]] && source "$wg_env"
[[ ${WG_PORT:-} =~ ^[0-9]+$ ]] && wg_port="$WG_PORT"

# Resolve the WAN and LAN roles to real interface names. Each role is a SET of
# interfaces -- a router can have more than one uplink and more than one LAN
# port. Assign them by name (WAN_IFS=/LAN_IFS=, space-separated) or by MAC
# (WAN_MACS=/LAN_MACS=, each matched to the interface that carries it now). The
# physical NICs are never renamed; the ruleset scopes to their real names with
# nftables interface sets, the way OPNsense scopes a rule to the ports a role
# holds. Per-IP routing on a shared interface is rules the operator adds with
# tui-firewall (ip saddr/daddr), not something the boot default guesses.
roles_conf=/etc/omarchy/router/roles.conf
WAN_IFS="" LAN_IFS="" WAN_MACS="" LAN_MACS=""
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

# nft_set formats a device list as an anonymous nftables set: { "a", "b" }.
nft_set() { local parts=() d; for d in "$@"; do parts+=("\"$d\""); done; local IFS=', '; printf '{ %s }' "${parts[*]}"; }

read -r -a wan_devs <<<"$(resolve_set "$WAN_IFS" "$WAN_MACS")"
read -r -a lan_devs <<<"$(resolve_set "$LAN_IFS" "$LAN_MACS")"

# More than one LAN port is bridged into br-lan by network-router.sh (one L2
# segment, one subnet), so the LAN the ruleset matches is the bridge, not the
# members. One LAN port is matched directly. This has to agree with
# network-router.sh, which computes the same thing.
if ((${#lan_devs[@]} > 1)); then
  lan_ifaces=(br-lan)
else
  lan_ifaces=("${lan_devs[@]}")
fi

if ((${#wan_devs[@]} > 0 && ${#lan_devs[@]} > 0)); then
  # Both roles assigned: the scoped router ruleset, on the real device names,
  # as interface sets so every WAN uplink and every LAN port is covered.
  wan_set="$(nft_set "${wan_devs[@]}")"
  lan_set="$(nft_set "${lan_ifaces[@]}")"
  cat >/etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
# Omarchy Router default firewall. WAN={${wan_devs[*]}} LAN={${lan_devs[*]}}.
# Written by install/router/firewall-router.sh and regenerated by
# \`omarchy-router-firewall\`. Managed live by tui-firewall (the \`tui-tools\`
# addon), whose native table this is. Exposed to the WAN: 22/tcp and udp/$wg_port.
flush ruleset
table inet tui {
  chain input {
    type filter hook input priority filter; policy drop;

    ct state established,related accept
    ct state invalid drop
    iif "lo" accept

    meta l4proto icmp accept
    meta l4proto ipv6-icmp accept

    iifname $lan_set accept
    iifname $wan_set tcp dport 22 accept
    iifname $wan_set udp dport $wg_port accept
  }

  chain forward {
    type filter hook forward priority filter; policy drop;

    ct state established,related accept
    ct state invalid drop

    iifname $lan_set oifname $wan_set accept
  }

  chain output {
    type filter hook output priority filter; policy accept;
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;

    oifname $wan_set masquerade
  }
}
EOF
else
  # Not both roles assigned yet: a plain, reachable SSH host. Drop the rest,
  # forward nothing. Assign WAN and LAN in roles.conf and re-run
  # omarchy-router-firewall to switch to the scoped ruleset above.
  cat >/etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
# Omarchy Router firewall -- UNCONFIGURED (WAN/LAN roles not both assigned).
# A plain reachable SSH host until roles are set in
# /etc/omarchy/router/roles.conf; then \`omarchy-router-firewall\` scopes it.
flush ruleset
table inet tui {
  chain input {
    type filter hook input priority filter; policy drop;
    ct state established,related accept
    ct state invalid drop
    iif "lo" accept
    meta l4proto icmp accept
    meta l4proto ipv6-icmp accept
    tcp dport 22 accept
    udp dport $wg_port accept
  }
  chain forward { type filter hook forward priority filter; policy drop; }
  chain output { type filter hook output priority filter; policy accept; }
}
EOF
fi
chmod 0755 /etc/nftables.conf

# nftables.service loads /etc/nftables.conf at boot. The default is safe from
# the first second -- reachable, not open -- before any operator logs in.
systemctl enable nftables.service

# A drop-in points the service at the profile's loader, which prefers the
# ruleset tui-firewall saved (/etc/omarchy/router/tui-firewall.nft) and falls
# back to the default above. This is what makes TUI-managed rules survive a
# reboot; without a saved file nothing changes.
mkdir -p /etc/systemd/system/nftables.service.d
cat >/etc/systemd/system/nftables.service.d/50-omarchy-router.conf <<'DROPIN'
# Omarchy Router: load tui-firewall's saved ruleset when present, else the
# default /etc/nftables.conf. Written by install/router/firewall-router.sh.
[Service]
ExecStart=
ExecStart=/usr/share/omarchy/bin/omarchy-router-firewall-load
DROPIN
chmod 0644 /etc/systemd/system/nftables.service.d/50-omarchy-router.conf
systemctl daemon-reload 2>/dev/null || true

# The router has no ufw. If a dependency ever dragged it in, a masked unit
# cannot start and cannot be pulled in by another unit's Wants=.
systemctl mask ufw.service 2>/dev/null || true
