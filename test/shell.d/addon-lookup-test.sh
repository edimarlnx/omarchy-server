#!/bin/bash

# omarchy-server-addon finds its package lists along a per-profile search path.
# The bug this covers: a machine installed as the ROUTER profile was offered
# the SERVER addon sets -- no `headscale`, and a `tui-tools` list without the
# router tools -- because the runtime only ever shipped and only ever read
# install/server/addons/.
#
# Everything here runs against a fixture tree through OMARCHY_INSTALL, so the
# test needs no root, no pacman and no installed machine. It stops at the point
# where the command would install something: what is under test is which file
# it picked, not what pacman did with it.

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

addon_command="$RUNTIME_BIN/omarchy-server-addon"
fixture=$(make_temp_dir)

# ── the fixture ─────────────────────────────────────────────────────────────
#
# The shape the package installs: the server lists and the shared setup leaves
# in install/server/addons/, the router lists in install/router/addons/.
mkdir -p "$fixture/server/addons" "$fixture/router/addons"

printf '# Container runtime.\ndocker\nufw-docker\n' \
  >"$fixture/server/addons/docker.packages"
printf '# The tui-tools terminal UIs.\ntui-tools\ntui-firewall\n' \
  >"$fixture/server/addons/tui-tools.packages"
printf '# Mandatory access control.\nselinux\n' \
  >"$fixture/server/addons/selinux.packages"
printf -- '--ask=4\n' >"$fixture/server/addons/selinux.pacman-args"
printf 'echo server-leaf\n' >"$fixture/server/addons/docker.sh"

printf '# Container runtime.\ndocker\nufw-docker\n' \
  >"$fixture/router/addons/docker.packages"
printf '# The tui-tools terminal UIs, router half included.\ntui-tools\ntui-router\ntui-vpn\n' \
  >"$fixture/router/addons/tui-tools.packages"
printf '# The headscale coordination server.\nheadscale\n' \
  >"$fixture/router/addons/headscale.packages"

run_addon() {
  local profile="$1"
  shift
  env OMARCHY_INSTALL="$fixture" OMARCHY_PROFILE="$profile" \
    bash "$addon_command" "$@" 2>&1
}

# ── the server profile ──────────────────────────────────────────────────────
listing=$(run_addon server --list)
assert_contains "$listing" docker "server: the server lists are offered"
assert_not_contains "$listing" headscale "server: a router-only addon is not offered"

assert_equal "$(run_addon server --list | sort | tr '\n' ' ')" \
  "docker selinux tui-tools " \
  "server: exactly the server lists, in one sorted listing"

# The router list must not leak into the server profile: same addon name,
# different set, and the server machine gets the server one.
summary=$(run_addon server --help)
assert_contains "$summary" "Available addons (server profile)" \
  "server: the listing says which profile's lists these are"
assert_contains "$summary" "The tui-tools terminal UIs." \
  "server: the summary comes from the server list"
assert_not_contains "$summary" "router half included" \
  "server: the summary does not come from the router list"

status=0
missing=$(run_addon server headscale) || status=$?
assert_equal "$status" 1 "server: an addon it does not have is refused"
assert_contains "$missing" "no such addon: headscale" \
  "server: the refusal names the addon"

# ── the router profile ──────────────────────────────────────────────────────
listing=$(run_addon router --list)
assert_contains "$listing" headscale "router: the router-only addon is offered"
assert_contains "$listing" tui-tools "router: the shared addons are still offered"
assert_contains "$listing" selinux \
  "router: a server list with no router counterpart is still offered"

assert_equal "$(run_addon router --list | tr '\n' ' ')" \
  "docker headscale selinux tui-tools " \
  "router: every list on the search path, each addon named once"

summary=$(run_addon router --help)
assert_contains "$summary" "Available addons (router profile)" \
  "router: the listing says which profile's lists these are"
assert_contains "$summary" "router half included" \
  "router: the summary comes from the ROUTER list where there is one"
assert_contains "$summary" "The headscale coordination server." \
  "router: the router-only addon carries its own summary"

# ── the profile marker ──────────────────────────────────────────────────────
#
# /etc/omarchy-profile is the source when OMARCHY_PROFILE is unset, and it is a
# file root can write: a name that is not a profile name must not become a path
# component. Both cases fall back to the server lists.
listing=$(env OMARCHY_INSTALL="$fixture" OMARCHY_PROFILE="../../../etc" \
  bash "$addon_command" --list 2>&1)
assert_not_contains "$listing" headscale \
  "a profile name that is not a profile name falls back to the server lists"

listing=$(env OMARCHY_INSTALL="$fixture" OMARCHY_PROFILE="desktop" \
  bash "$addon_command" --list 2>&1)
assert_equal "$(printf '%s' "$listing" | sort | tr '\n' ' ')" \
  "docker selinux tui-tools " \
  "a profile with no lists of its own falls back to the server lists"

# ── the shipped lists ───────────────────────────────────────────────────────
#
# The fixture proves the lookup; these prove the profile ships what the lookup
# is supposed to find. profile/router/addons/ is the single source of truth for
# what a router is offered -- the packaging vendors it, it is not retyped.
router_addons="$ROOT/profile/router/addons"
[[ -f $router_addons/headscale.packages ]] ||
  fail "the router profile ships headscale.packages"
pass "the router profile ships headscale.packages"

router_tools=$(grep -v '^#\|^$' "$router_addons/tui-tools.packages")
for tool in tui-router tui-vpn tui-traffic tui-dc; do
  assert_contains "$router_tools" "$tool" \
    "the router tui-tools list carries $tool"
done

server_tools=$(grep -v '^#\|^$' "$ROOT/profile/server/addons/tui-tools.packages")
assert_not_contains "$server_tools" tui-router \
  "the server tui-tools list does not carry tui-router"

# The leaves stay in install/server/addons/ for both profiles, so a router-only
# addon has to find its own there. headscale is the one that has any, and its
# preflight sources the tui-tools preflight for the repository and the key.
leaves="$ROOT/profile/server/overlay/runtime/install/server/addons"
for leaf in headscale.preflight.sh headscale.sh tui-tools.preflight.sh; do
  [[ -f $leaves/$leaf ]] || fail "the shared addon leaves include $leaf"
done
pass "the router-only addon's leaves are on the shared search path"
