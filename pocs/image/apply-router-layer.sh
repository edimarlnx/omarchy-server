#!/bin/bash
# Turn a booted SERVER cloud image into the ROUTER profile, in place, before it
# is generalized into the router cloud image. This is the "server + a layer"
# path the router acceptance validated (reports/2026-08-31-router-profile-
# clean-machine.md): the ISO-install path is not needed to produce the image.
#
#   ssh <build-vm> 'sudo bash -s' < pocs/image/apply-router-layer.sh
#
# What the layer is, and why every step is here rather than in a hand-typed
# session: the first router image (router-2026-09-01) was baked by running only
# the install/router/*.sh leaves -- and shipped without wireguard-tools, because
# the leaves configure the router but the router's PACKAGE DELTA over the server
# profile (profile/router/omarchy-router.packages minus profile/server/
# omarchy-server.packages) is installed by the ISO, not by the leaves. This
# script owns both halves, so a bake cannot forget one of them again.
#
# Steps, all idempotent:
#   1. update through the profile's own updater (direct pacman is guarded);
#   2. install the router package delta, remove the server-only ufw;
#   3. run the router setup leaves in the order install/router/all.sh uses;
#   4. make nftables the boot firewall (unit enabled, ufw disabled);
#   5. sanity: the router table is on disk and loads.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
export OMARCHY_PATH=/usr/share/omarchy
export OMARCHY_INSTALL=/usr/share/omarchy/install
profile_dir=/usr/share/omarchy/profile

echo "› 1. runtime update"
omarchy-server-update run --no-reboot || true
[[ -d $OMARCHY_INSTALL/router ]] || { echo "install/router tree missing after update: runtime too old" >&2; exit 1; }

echo "› 2. router package delta"
# The delta is computed from the two package lists the profile ships, so this
# script never carries its own copy of the answer.
server_list=$OMARCHY_INSTALL/../profile/server/omarchy-server.packages
router_list=$OMARCHY_INSTALL/../profile/router/omarchy-router.packages
if [[ -f $server_list && -f $router_list ]]; then
  mapfile -t add < <(comm -13 <(grep -vE '^#|^$' "$server_list" | sort -u) <(grep -vE '^#|^$' "$router_list" | sort -u))
  mapfile -t drop < <(comm -23 <(grep -vE '^#|^$' "$server_list" | sort -u) <(grep -vE '^#|^$' "$router_list" | sort -u))
else
  # Runtime packages older than the lists: the known delta, stated out loud.
  echo "  (package lists not shipped by this runtime; using the known delta)"
  add=(nftables wireguard-tools); drop=(ufw)
fi
echo "  install: ${add[*]:-none}   remove: ${drop[*]:-none}"
((${#add[@]})) && OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -S --needed --noconfirm "${add[@]}"
for p in "${drop[@]:-}"; do
  [[ -n $p ]] && pacman -Q "$p" >/dev/null 2>&1 && { systemctl disable --now "$p" 2>/dev/null || true; OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Rns --noconfirm "$p"; }
done

echo "› 3. router setup leaves"
cd "$OMARCHY_INSTALL/router"
for leaf in identity-router.sh network-router.sh enable-services-router.sh firewall-router.sh; do
  echo "  $leaf"; bash "$leaf"
done

echo "› 4. boot firewall"
systemctl enable nftables.service >/dev/null 2>&1
systemctl restart nftables.service

echo "› 5. sanity"
grep -q "table inet tui" /etc/nftables.conf || { echo "router ruleset not on disk" >&2; exit 1; }
nft list ruleset | grep -q "table inet tui" || { echo "router ruleset not loaded" >&2; exit 1; }
command -v wg >/dev/null || { echo "wireguard-tools missing" >&2; exit 1; }
echo "router layer applied: $(pacman -Q omarchy-server nftables wireguard-tools | tr '\n' ' ')"
