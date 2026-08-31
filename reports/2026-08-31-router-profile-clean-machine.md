# Router profile — clean-machine acceptance attempt

**Date:** 2026-08-31
**Subject:** installing the `router` profile from its own ISO with `serverlab`, and the acceptance suite it is measured by
**Result:** ISO builds; a **finding** blocks the headless install acceptance and needs a decision (below)

## What was done

- Added a router acceptance suite, `pocs/server-install/acceptance-router.sh`:
  16 checks that a clean install comes up as a router — nftables (not ufw) is
  the firewall with the `inet tui` ruleset loaded, the WAN opens exactly 22/tcp
  and 51820/udp and nothing else, input and forward default to drop, nothing
  web is listening, IP forwarding is persisted, and the tools it ships are
  present.
- `serverlab pkgs build` and `serverlab iso build --profile router`: **both
  pass**. The ISO `omarchy-2026.08.31-x86_64-router-local.iso` (3.0 GiB) builds
  clean in ~3m47s — the patch stack applies and the offline mirror carries the
  router package set.
- Added the `router` branch to `pocs/lab/mkcidata.sh` (it only knew
  `desktop|server`, so `serverlab lab up --profile router` failed at cidata with
  "unknown profile: router").

## Finding — a no-roles install locks itself out of SSH

`serverlab lab up` creates a single-NIC VM. The router profile, installed with
no NIC roles (the default `roles.conf` is `WAN_MAC=`/`LAN_MAC=`), does this:

- `omarchy-router-nics` **skips** renaming a NIC whose MAC is unset, so on a
  single-NIC machine no interface becomes `wan0` or `lan0` — it keeps its
  kernel name (`enp1s0`).
- `firewall-router.sh` unconditionally enables `nftables.service` with an
  `input` chain that is `policy drop` and accepts new inbound only on:
  `iifname "lan0" accept`, `iifname "wan0" tcp dport 22 accept`,
  `iifname "wan0" udp dport 51820 accept` (plus lo, icmp, established).

So on a machine whose one interface is neither `wan0` nor `lan0`, **every new
inbound SSH is dropped**. A router installed headless on a remote box with no
roles yet configured comes up unreachable — only the console can fix it. This
contradicts the profile's stated "unconfigured = a plain SSH host", and it is
what blocks the headless `serverlab` install acceptance (wait-ssh cannot reach
the installed VM).

## Decision needed (security posture)

The drop-everything default is deliberate ("safe from the first second"), but on
a remote headless install it is a foot-gun. Two ways to resolve it, Edimar's
call:

1. **Keep secure-by-default**, and make the router install *require* NIC roles:
   the lab passes a `router-nics` hint (both MACs) and uses a two-NIC VM, so the
   machine comes up as a real router (SSH via `lan0`, WAN on `wan0:22`). The
   acceptance then tests the full router.
2. **Reachable-until-configured**: when `roles.conf` has no MACs, write a
   safe-mode ruleset that accepts SSH on any interface (a plain SSH host, as the
   docs claim), and switch to the `wan0`/`lan0`-scoped ruleset only once roles
   are set. This makes a fresh remote install reachable to *be* configured.

Recommendation: **(2)** as the safety fix (a remote install you can't reach is
worse than one that accepts SSH until you scope it), plus **(1)**'s two-NIC lab
path for the full acceptance. Until decided, the acceptance suite is ready and
the ISO is proven; only the reachable install is pending.
