#!/bin/bash
# Router acceptance, run against a booted VM installed with the `router`
# profile.
#
#   LAB_OUT=pocs/lab/out-server ./pocs/server-install/acceptance-router.sh [vm-name]
#
# Same shape and same rules as acceptance.sh: one PASS/FAIL line per item
# followed by the evidence it was judged on, and never a non-zero exit on a
# failed check -- the report is the product.
#
# What it establishes: the profile the tui-tools ship on installs and boots as a
# router, not a server or a desktop. The full in/out/forward routing behaviour
# (NAT, DHCP, WireGuard, failover) is proven separately on a two-network lab in
# tui-lab; here the subject is the PROFILE -- that a clean install comes up with
# the router firewall loaded, forwarding persisted, the two WAN ports the design
# promises and no others, and nothing that listens on the web.
#
# The lab password never appears in the output: it is written once to ~/.lab-pw
# (mode 600) and read from there by the ~/.lab-sudo wrapper.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
vm="${1:-srv}"
lab="$repo_root/pocs/lab/vm.sh"
export LAB_OUT="${LAB_OUT:-$repo_root/pocs/lab/out-server}"
export SSH_USER="${SSH_USER:-omarchy}"

run() { "$lab" "$vm" ssh "$@" 2>&1; }

# Stage the password and the sudo wrapper. The password travels on stdin, so it
# is never part of a command line this script prints or the VM's shell history.
if [[ -f $LAB_OUT/lab-password ]]; then
  "$lab" "$vm" ssh 'cat >~/.lab-pw && chmod 600 ~/.lab-pw' <"$LAB_OUT/lab-password" || {
    echo "could not stage the lab password in the VM" >&2
    exit 1
  }
  run 'printf "%s\n" "#!/bin/bash" "exec sudo -S -p \"\" \"\$@\" <\$HOME/.lab-pw" >~/.lab-sudo && chmod 700 ~/.lab-sudo' >/dev/null
else
  run 'printf "%s\n" "#!/bin/bash" "exec sudo -n \"\$@\"" >~/.lab-sudo && chmod 700 ~/.lab-sudo' >/dev/null
fi

cleanup() { run 'rm -f ~/.lab-pw ~/.lab-sudo' >/dev/null 2>&1; }
trap cleanup EXIT

pass=0
fail=0
report() { # report <PASS|FAIL> <name> <evidence...>
  local status=$1 name=$2
  shift 2
  if [[ $status == PASS ]]; then ((pass++)); else ((fail++)); fi
  printf '[%s] %s\n' "$status" "$name"
  printf '      %s\n' "$@"
  echo
}

check() { # check <name> <remote command> <regex the output must match>
  local name=$1 cmd=$2 pattern=$3 output status
  output=$(run "$cmd")
  if grep -Eq "$pattern" <<<"$output"; then status=PASS; else status=FAIL; fi
  report "$status" "$name" "\$ $cmd" "${output//$'\n'/$'\n'      }"
}

echo "=== Router install acceptance — VM '$vm' — $(date -Is) ==="
echo

# --- the machine is a headless server, the base the router builds on ---------
check "default target is multi-user.target" \
  "systemctl get-default" \
  "^multi-user\.target$"

check "no display manager: sddm is masked or absent" \
  "systemctl is-enabled sddm.service 2>&1 || true" \
  "masked|not-found|disabled"

# --- nftables is the firewall, not ufw ---------------------------------------
check "nftables.service is enabled" \
  "systemctl is-enabled nftables.service 2>&1" \
  "^enabled$"

# nftables.service is a load-and-exit oneshot, so it reads "inactive (dead)"
# after it has applied the ruleset -- what matters is that the ruleset is in the
# kernel, which the checks below read from `nft list ruleset`. Prove the loader
# actually loaded the router table.
check "the router ruleset is loaded in the kernel (inet tui)" \
  "~/.lab-sudo nft list ruleset" \
  "table inet tui"

check "ufw is not the active firewall" \
  "systemctl is-active ufw.service 2>&1 || true" \
  "inactive|not-found|failed|unknown"

# --- the router's own ruleset, on disk and loaded ----------------------------
check "/etc/nftables.conf is the router ruleset (inet tui)" \
  "cat /etc/nftables.conf" \
  "table inet tui"

check "the loaded ruleset drops input by default" \
  "~/.lab-sudo nft list ruleset" \
  "type filter hook input priority filter; policy drop"

# This VM has one NIC and no WAN/LAN roles assigned, so the ruleset is the
# safe-mode one: reachable on SSH from any interface (the scoped, role-named
# ruleset is proven on the two-network tui-lab). That the acceptance can ssh in
# at all is itself the proof it did not lock itself out.
check "the unconfigured router accepts SSH, staying reachable to be configured" \
  "~/.lab-sudo nft list ruleset" \
  "tcp dport 22 accept"

check "the router accepts WireGuard (51820/udp)" \
  "~/.lab-sudo nft list ruleset" \
  "udp dport 51820 accept"

check "the forward chain drops by default (LAN-to-WAN is the only opening)" \
  "~/.lab-sudo nft list ruleset" \
  "type filter hook forward priority filter; policy drop"

# --- nothing web is listening, and SSH is ------------------------------------
check "no web port is listening (80/443/8080)" \
  "~/.lab-sudo ss -tlnH | awk '{print \$4}' | grep -E ':(80|443|8080)\$' || echo NONE" \
  "^NONE$"

check "sshd is listening on 22" \
  "~/.lab-sudo ss -tlnH | awk '{print \$4}' | grep -E ':22\$' | head -1" \
  ":22$"

# An update must never take the machine off the network. Upstream's v4.0.2
# migration disables sshd when the account running it has no authorized key,
# and on this profile that account is root, which is keyless by policy; the
# profile's patch series makes that branch inert on a key-only server. The unit
# state is the proof, and it is separate from the listener above: a daemon
# stopped by a migration keeps a perfectly valid configuration.
check "sshd enabled and active after update" \
  'echo sshd=$(systemctl is-enabled sshd.service 2>&1)/$(systemctl is-active sshd.service 2>&1);
   ls /etc/ssh/sshd_config.d/' \
  '^sshd=enabled/active$'

# --- forwarding is persisted (a router forwards; a server does not) ----------
check "IP forwarding is persisted as a sysctl drop-in" \
  "cat /etc/sysctl.d/30-omarchy-router.conf" \
  "net\.ipv4\.ip_forward=1"

check "IP forwarding is on at runtime" \
  "sysctl -n net.ipv4.ip_forward" \
  "^1$"

# --- the router's own knobs and the tools it ships ---------------------------
check "the WireGuard port config is present (default 51820)" \
  "cat /etc/omarchy/router/wireguard.env" \
  "WG_PORT=51820"

check "the role config exists (assign WAN/LAN by name or MAC, reassignable)" \
  "cat /etc/omarchy/router/roles.conf" \
  "WAN_(IFS|MACS)=|LAN_(IFS|MACS)="

check "tui-firewall, the tool that manages the ruleset, is installed" \
  "command -v tui-firewall || echo MISSING" \
  "/tui-firewall$"

echo "=== $pass passed, $fail failed ==="
