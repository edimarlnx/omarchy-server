# The router profile

**Date:** 2026-08-30
**Scope:** a new `router` profile, sibling of `server`, that boots as a
firewall/router with only SSH and WireGuard exposed and no web management port.
**Result:** static verification only. The whole ISO patch stack applies clean,
the orchestrator compiles, every shell leaf parses, and the package list and
overlay render as designed. Nothing was booted; the router-1.0 acceptance on
real NICs (items 1-7 end to end) is owed to the lab.

This report is a design-and-static-check record, not an install measurement.
It states exactly what was verified without hardware and what was not.

## 1. What the profile is

The router edition is the server base with a router layered on. The server
base is already minimal, headless, sshd-hardened and firewalled; the router
adds three things and swaps one:

- **two NIC roles**, `wan0` (uplink, DHCP client) and `lan0` (internal gateway
  with a DHCP server), named by convention rather than by this host's
  interfaces;
- **IP forwarding**, a sysctl drop-in;
- **an nftables firewall** — the tui-firewall tool's own `inet tui` table with
  a safe default — in place of the server's ufw.

Everything else (snapshots, sshd hardening, the update path, the console
identity, the addon mechanism) is the server profile's, sourced directly so
the two cannot drift.

## 2. Layout

```
profile/router/
  archinstall.packages          # same seed as server (base, linux, nano, ...)
  omarchy-router.packages       # server core, minus ufw, plus nftables + wireguard-tools
  addons/*.packages             # the same opt-in sets server offers

profile/server/overlay/runtime/         # shipped inside the omarchy-server package
  install/router/
    all.sh                      # entry point; sources the server leaves + router ones
    network-router.sh           # wan0/lan0 .network units, roles.conf, forwarding sysctl
    firewall-router.sh          # writes /etc/nftables.conf (inet tui), enables nftables.service
    enable-services-router.sh   # server service set with nftables.service instead of ufw
    identity-router.sh          # /etc/issue.net says "Router"
    omarchy-provision-owner.service   # headless first-boot unit, OMARCHY_PROFILE=router
  bin/
    omarchy-router-nics         # roles.conf (WAN_MAC/LAN_MAC) -> systemd .link files
    omarchy-router-firewall     # preview and apply the inet tui ruleset
```

The router runtime lives inside the existing `omarchy-server` package because
the router profile *is* the server runtime with a router layered on;
`omarchy-apply-system` routes to `install/router/` when `OMARCHY_PROFILE=router`
(the same mechanism that routes `server` to `install/server/`).

## 3. The exposed-ports claim

Exposed on the WAN, and nothing else:

| Port | Purpose |
|---|---|
| `22/tcp` | SSH (key-only; sshd hardening is the server profile's) |
| `<WG_PORT>/udp` | WireGuard, default `51820`, in `/etc/omarchy/router/wireguard.env` |

There is **no web management port**. The tui-tools (tui-firewall, tui-network,
...) are terminal UIs run at the console or over SSH; none of them listens on a
socket. No daemon in the profile binds a management port. The LAN side
(`lan0`) additionally answers DHCP (udp/67) and DNS (53) for internal clients;
those are reachable from `lan0` only, never from `wan0`.

## 4. The forwarding / NAT default

`/etc/nftables.conf` is the `inet tui` table (named so tui-firewall manages it
natively). Its default policy:

| Chain | Policy | Accepts |
|---|---|---|
| `input` | drop | established/related, loopback, ICMP, **all from `lan0`**, and from `wan0` only `22/tcp` and `<WG_PORT>/udp` |
| `forward` | **drop** | established/related, and **`lan0` → `wan0`** (LAN reaches the internet). WAN → LAN is return traffic only |
| `postrouting` (nat) | accept | **masquerade out `wan0`** (source-NAT the LAN behind the WAN address) |

IP forwarding itself is `net.ipv4.ip_forward=1` /
`net.ipv6.conf.all.forwarding=1` in `/etc/sysctl.d/30-omarchy-router.conf`.

**Previewed, not hidden.** The ruleset is a plain readable file that
`nftables.service` loads at boot, so the box is never open while it waits for
an operator. `omarchy-router-firewall` prints the exact ruleset and re-applies
it on confirm (`nft -c` dry-run, then a y/N prompt), the same
command-preview-then-confirm contract the tui-tools follow. The install step
only writes the file and enables the loader; it never runs `nft` against a live
ruleset (it runs in the ISO's install chroot, where there is no router to apply
it to).

## 5. NIC roles without hardcoding this host

Roles are the stable names `wan0` and `lan0`; the mapping from a physical NIC
to a role is by MAC:

- `/etc/omarchy/router/roles.conf` carries `WAN_MAC=` / `LAN_MAC=` (and
  optional `LAN_ADDRESS=` / `LAN_DHCP=`);
- `omarchy-router-nics` turns those into `05-omarchy-{wan,lan}.link` files that
  rename the matching NIC. It does **not** rename a live interface (that would
  strand an SSH session); the rename takes effect on the next boot or an
  explicit `udevadm trigger`;
- an autoinstall drive may carry the same lines in a `router-nics` file, copied
  to `/root` by `omarchy-cidata-load` (patch `0013`) and seeded into
  `roles.conf` at install.

Until a role is assigned, `wan0`/`lan0` do not exist, so nothing is forwarded
and the machine is a plain headless SSH host on whatever NIC took a lease — a
safe unconfigured state, not an open one.

## 6. The tui-tools it installs

The `tui-tools` addon installs the whole published family from the tools' own
signed repository. **Released today** and pulled in on the router: `tui-firewall`
(its nftables backend manages the `inet tui` table this profile seeds) and
`tui-network`, alongside the rest of the family. **Not yet released**, left as
clearly-commented placeholders rather than pretending to install them:

- `tui-router` (a router cockpit) — not in the tools' repository database;
- `tui-vpn` — not released. The firewall's `forward` chain carries a commented
  `wg0` rule for the day a WireGuard tunnel is configured by hand or by
  `tui-vpn`.

The profile installs only what exists in `pkgs` today; the placeholders keep it
honest about what it cannot install yet.

## 7. Identity

The Omarchy identity is kept exactly as the server profile keeps it (wallpaper,
palette, os-release, the ISO menu label which patch `0008` already renders as
"Omarchy Router" for a named profile). The console additionally says it is a
router: `/etc/issue.net` reads "Omarchy Server — Router" before authentication,
and `omarchy-server-motd` labels the login banner "Omarchy Router" and adds
`wan` / `lan` / `forward` / `exposed` fields (read from `/proc` and the
profile's own config, no extra package). The server banner is unchanged byte
for byte when the profile is not `router`.

## 8. What a `--profile router` install does

1. `iso/build.sh --profile router` copies `profile/router/` into the pkgs
   checkout and builds the `omarchy-server` runtime/settings/keyring the same
   way a server build does (build-iso patch `0002`, case `server | router`).
2. The ISO installs `omarchy-router.packages`: the server core with `nftables`
   and `wireguard-tools` in and `ufw` out. No compiler, no editor, no display
   manager (the headless orchestrator gates in patch `0004`).
3. `omarchy-apply-system` runs `install/router/all.sh`: server leaves for
   snapshots/sshd/updates/identity, then `network-router.sh` (wan0/lan0 +
   forwarding), `enable-services-router.sh` (nftables, not ufw) and
   `firewall-router.sh` (writes `/etc/nftables.conf`, enables
   `nftables.service`).
4. The ISO's `configure_ssh_access` phase is skipped for the router (no ufw);
   SSH exposure is the `inet tui` table's WAN rule.
5. First boot: `nftables.service` loads the default ruleset (LAN→WAN allowed +
   masqueraded, WAN answering only 22/tcp and WireGuard, everything else
   dropped). `omarchy-router-nics` names the NICs from `roles.conf` /
   `router-nics`. `omarchy-router-firewall --preview` shows the ruleset.

## 9. What was verified statically

| Check | Method | Result |
|---|---|---|
| ISO patch stack applies (0001-0013) | fresh copy of `upstream/omarchy-iso` + `iso/overlay/` + `git apply` each patch in order, exactly as `iso/build.sh` does | 13/13 apply clean |
| orchestrator still valid Python | `python3 -m py_compile phases_impl.py` on the patched tree | OK |
| headless gates cover router, server-only gates unchanged | grep of `_is_headless_profile` (early packages, hibernation, login, addons) vs `_is_server_profile` (secure boot 0010, MAC 0012) | as designed |
| `configure_ssh_access` skips ufw for router | code path review on the patched file | router returns before the ufw block |
| `build-iso.sh`, `omarchy-cidata-load` parse | `bash -n` on the patched tree | OK |
| `omarchy-apply-system` overlay patch applies + routes router | applying the overlay patch onto `upstream/omarchy/bin/omarchy-apply-system` (one-level strip, as the PKGBUILD does), then `bash -n` | applies; routes `server`/`router` to `install/$profile/all.sh` |
| every router shell leaf and the two new commands parse | `bash -n` on all of `install/router/*.sh` and `bin/omarchy-router-*` | 7/7 OK |
| motd stays valid and server-identical off-router | `bash -n`; router block gated on `/etc/omarchy-profile == router` | OK |
| `omarchy-server` PKGBUILD ships `install/router/` | edited `package()` to copy the tree; `bash -n` on the PKGBUILD; `pkgrel` 15 → 16 | parses; content change accounted for |
| no web listener in the unit set | review of `enable-services-router.sh` (enables sshd, networkd, resolved, timesyncd, oomd, serial-getty, tty-palette, nftables; masks the rest) and the package list (no httpd/cockpit/web daemon) | none present |

## 10. What still needs the lab (router-1.0 acceptance, items 1-7)

None of the following can be shown without real (or virtual) multi-NIC
hardware; they are the end-to-end acceptance owed on a real machine:

1. two NICs come up as `wan0`/`lan0` from `roles.conf` MACs; the WAN gets a
   lease and the LAN serves DHCP;
2. IP forwarding is live and a LAN client reaches the internet through the
   masquerade;
3. the WAN answers on `22/tcp` and the WireGuard port and **nothing else**
   (a port scan from the WAN side);
4. `nftables.service` loads the `inet tui` table at boot and
   `omarchy-router-firewall --apply` reloads it without stranding SSH;
5. a WireGuard tunnel established over the WAN port, and its forward rule;
6. `omarchy-router-nics` renames survive a reboot; a mis-set MAC fails safe;
7. the full install driven by `serverlab` from a `--profile router` ISO, with a
   report written from the run's evidence.

Out of scope for router-1.0 and noted here so it is not mistaken for done:
Secure Boot (`0010`) and mandatory access control (`0012`) still gate on
`_is_server_profile`, so an autoinstall `secureboot`/`selinux`/`apparmor`
marker does not trigger during a router install. The addons remain installable
by hand (`omarchy-server-addon selinux`); wiring the router into those phases
is a later, separate decision.
