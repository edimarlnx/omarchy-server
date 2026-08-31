# Router profile: multi-NIC deploy on a real machine

Date: 2026-08-31
Host: local libvirt/KVM (Fedora host), two virtual networks
Image: omarchy-server cloud image (SELinux + tui-tools), booted directly with a
NoCloud seed — no ISO.

## What this establishes

The router-profile acceptance (reports/2026-08-31-router-profile-clean-machine.md)
proved the *profile* comes up as a router on a single-NIC machine in safe mode.
This report proves the *routing*: a machine with two NICs, WAN and LAN roles
assigned, produces the scoped ruleset with the real device names, and a client
behind it reaches the internet through the router — DHCP, DNS, and NAT.

The full forwarding behaviour was already proven on the two-network tui-lab
twins; this is the same behaviour, produced by the shipping profile on a
freshly booted machine rather than by a hand-built lab.

## Topology

- Router VM: 2 NICs — `enp1s0` on the NAT network (WAN, upstream + internet),
  `enp2s0` on an isolated network (LAN). Secure Boot off (OVMF non-secboot).
- LAN client VM: 1 NIC on the isolated LAN network, no other path out.
- Roles written to `/etc/omarchy/router/roles.conf`: `WAN_IFS=enp1s0`,
  `LAN_IFS=enp2s0`. Applied with the profile's own
  `install/router/{network-router,firewall-router}.sh`.

## Evidence

Scoped ruleset (real device names, not safe mode):

    type filter hook input priority filter; policy drop;
      iifname "enp2s0" accept
      iifname "enp1s0" tcp dport 22 accept
      iifname "enp1s0" udp dport 51820 accept
    type filter hook forward priority filter; policy drop;
      iifname "enp2s0" oifname "enp1s0" accept
    oifname "enp1s0" masquerade

Router LAN gateway and forwarding:

    enp2s0  UP  10.55.0.1/24
    net.ipv4.ip_forward = 1

LAN client, entirely from the router's DHCP:

    address        10.55.0.127/24
    default route  via 10.55.0.1 dev enp1s0   (the router)
    resolver       10.55.0.1                  (the router)

Client reaching the public internet through the router (name-resolved, NATed):

    example.com    -> http=200 resolved_host=172.66.147.243
    cloudflare.com -> http=301 resolved_host=104.16.133.229
    one.one.one.one resolves

The router stayed reachable on SSH over the WAN (`enp1s0`) throughout — the
scoped input rule opens 22 on the WAN, and configuring the router did not lock
it out.

## Bug found and fixed during the deploy

The LAN's DHCP hands out the router itself as the client's DNS server
(`DNS=_server_address`, i.e. 10.55.0.1). But systemd-resolved's stub answers
only on 127.0.0.53 by default, so LAN clients were handed a resolver that never
replied: IP-based traffic worked (NAT proven with `curl --resolve`), name
resolution did not.

Fix (network-router.sh): write a resolved drop-in binding an extra stub
listener on the LAN gateway address —

    [Resolve]
    DNSStubListenerExtra=10.55.0.1

and restart systemd-resolved when re-applied on a running machine (the extra
listener binds on restart, not reload; skipped in the ISO install chroot). After
the fix the router answers DNS on 10.55.0.1:53 and forwards upstream over the
WAN, and the client resolves names end-to-end (the HTTP 200 above).

## Status

Router profile: deploy validated on a real multi-NIC machine. Items #4 (multi-NIC
router install) and #7 (real deploy report) of the router-1.0 track are closed by
this run.
