#!/bin/bash

# omarchy-router-firewall prints a summary under the ruleset it printed. The bug
# this covers: that summary was a fixed sentence. It named `wan0`, an interface
# the profile never creates (roles resolve to real kernel names like enp1s0),
# and it described the SCOPED router ruleset even when the file on disk -- and
# on screen right above it -- was the unconfigured safe-mode one, so the
# operator read the preview and the summary contradicting each other.
#
# Everything here runs against fixture files through OMARCHY_ROUTER_RULESET and
# OMARCHY_ROUTER_ROLES, so the test needs no root, no nft and no machine. Only
# --preview is exercised: --apply's extra work is `nft`, which is the part a
# fixture cannot stand in for.

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

firewall_command="$RUNTIME_BIN/omarchy-router-firewall"
fixture=$(make_temp_dir)
mkdir -p "$fixture" # make_temp_dir's own cleanup runs when its subshell exits

# ── the fixtures ────────────────────────────────────────────────────────────
#
# Byte for byte the two rulesets install/router/firewall-router.sh writes: the
# scoped one when both roles are assigned, the safe-mode one until then.

write_scoped_ruleset() { # write_scoped_ruleset <path> <lan-set> <wan-set>
  local path="$1" lan="$2" wan="$3"
  cat >"$path" <<EOF
#!/usr/sbin/nft -f
# Omarchy Router default firewall.
flush ruleset
table inet tui {
  chain input {
    type filter hook input priority filter; policy drop;

    ct state established,related accept
    ct state invalid drop
    iif "lo" accept

    meta l4proto icmp accept
    meta l4proto ipv6-icmp accept

    iifname $lan accept
    iifname $wan tcp dport 22 accept
    iifname $wan udp dport 51820 accept
  }

  chain forward {
    type filter hook forward priority filter; policy drop;

    ct state established,related accept
    ct state invalid drop

    iifname $lan oifname $wan accept
  }

  chain output {
    type filter hook output priority filter; policy accept;
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;

    oifname $wan masquerade
  }
}
EOF
}

cat >"$fixture/unconfigured.nft" <<'EOF'
#!/usr/sbin/nft -f
# Omarchy Router firewall -- UNCONFIGURED (WAN/LAN roles not both assigned).
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
    udp dport 51820 accept
  }
  chain forward { type filter hook forward priority filter; policy drop; }
  chain output { type filter hook output priority filter; policy accept; }
}
EOF

# A ruleset that is neither shape: what an operator's own edit, or a ruleset
# tui-firewall saved, can look like.
cat >"$fixture/hand-edited.nft" <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
table inet tui {
  chain input {
    type filter hook input priority filter; policy accept;
  }
}
EOF

printf 'WAN_IFS="enp1s0"\nLAN_IFS="enp2s0 enp3s0"\n' >"$fixture/roles.conf"
printf 'WAN_IFS="enp1s0"\nLAN_IFS="enp2s0"\n' >"$fixture/roles-single-lan.conf"

run_firewall() { # run_firewall <ruleset> <roles.conf> [args...]
  local ruleset="$1" roles="$2"
  shift 2
  env OMARCHY_ROUTER_RULESET="$ruleset" OMARCHY_ROUTER_ROLES="$roles" \
    bash "$firewall_command" "$@" 2>&1
}

# ── one WAN port, one LAN port ──────────────────────────────────────────────
write_scoped_ruleset "$fixture/single.nft" '{ "enp2s0" }' '{ "enp1s0" }'
preview=$(run_firewall "$fixture/single.nft" "$fixture/roles-single-lan.conf" --preview)

assert_not_contains "$preview" wan0 \
  "single: the summary does not name an interface the profile never creates"
assert_contains "$preview" "Exposed on the WAN: 22/tcp and 51820/udp (WireGuard) only." \
  "single: the open ports come from the rules, not from a fixed sentence"
assert_contains "$preview" "  WAN  enp1s0" \
  "single: the WAN is the interface the masquerade and the ssh rule name"
assert_contains "$preview" "  LAN  enp2s0" \
  "single: the LAN is the interface the forward rule names"

# The default (no argument) is the same preview, which is the path the roles
# wizard points people at.
assert_equal "$(run_firewall "$fixture/single.nft" "$fixture/roles-single-lan.conf")" \
  "$preview" "single: no argument previews exactly like --preview"

# ── several LAN ports, bridged ──────────────────────────────────────────────
#
# network-router.sh bridges more than one LAN port into br-lan, and the ruleset
# then matches the bridge. The summary has to name the bridge AND the ports
# behind it, or "br-lan" tells the operator nothing about which sockets it is.
write_scoped_ruleset "$fixture/bridged.nft" '{ "br-lan" }' '{ "enp1s0" }'
bridged=$(run_firewall "$fixture/bridged.nft" "$fixture/roles.conf" --preview)

assert_contains "$bridged" "  LAN  bridge br-lan: enp2s0 and enp3s0" \
  "bridged: the summary names the bridge and its member ports"
assert_contains "$bridged" "  WAN  enp1s0" \
  "bridged: the WAN is still the real uplink name"

# Without a readable roles.conf the bridge is still named; only the members are
# unknown, and an unknown is left out rather than guessed.
bridged_no_roles=$(run_firewall "$fixture/bridged.nft" "$fixture/absent.conf" --preview)
assert_contains "$bridged_no_roles" "  LAN  bridge br-lan" \
  "bridged: with no roles.conf the bridge is named without inventing members"

# ── several WAN uplinks ─────────────────────────────────────────────────────
write_scoped_ruleset "$fixture/multiwan.nft" '{ "enp2s0" }' '{ "enp1s0", "enp4s0" }'
multiwan=$(run_firewall "$fixture/multiwan.nft" "$fixture/roles-single-lan.conf" --preview)

assert_contains "$multiwan" "  WAN  enp1s0 and enp4s0" \
  "multi-WAN: every uplink in the role is named"

# ── the unconfigured ruleset ────────────────────────────────────────────────
#
# The bug's sharpest edge: this file forwards nothing, and the old summary said
# it forwarded and masqueraded.
unconfigured=$(run_firewall "$fixture/unconfigured.nft" "$fixture/roles.conf" --preview)

assert_contains "$unconfigured" "This is the UNCONFIGURED ruleset" \
  "unconfigured: the summary says which ruleset was printed"
assert_contains "$unconfigured" "accepted on EVERY" \
  "unconfigured: it says the ports are open on every interface"
assert_not_contains "$unconfigured" "masqueraded out of the WAN" \
  "unconfigured: it does not claim a masquerade the ruleset does not have"
assert_not_contains "$unconfigured" "Exposed on the WAN:" \
  "unconfigured: it does not describe the scoped ruleset it did not print"
assert_not_contains "$unconfigured" wan0 \
  "unconfigured: no invented interface name"
assert_contains "$unconfigured" "omarchy-router-firewall --regenerate" \
  "unconfigured: it names the command that scopes the ruleset to the roles"
assert_contains "$unconfigured" "omarchy-router-firewall --apply" \
  "unconfigured: and the command that loads the result"

# ── a ruleset the profile did not write ─────────────────────────────────────
edited=$(run_firewall "$fixture/hand-edited.nft" "$fixture/roles.conf" --preview)

assert_contains "$edited" "not one of the two the profile generates" \
  "hand-edited: an unrecognised ruleset is not summarised by guesswork"
assert_not_contains "$edited" "masqueraded out of the WAN" \
  "hand-edited: nothing is claimed about forwarding"

# ── a ruleset that is not there ─────────────────────────────────────────────
status=0
missing=$(run_firewall "$fixture/absent.nft" "$fixture/roles.conf" --preview) || status=$?
assert_equal "$status" 1 "missing: a ruleset that does not exist is an error"
assert_contains "$missing" "--regenerate" \
  "missing: the error points at the command that writes one"
