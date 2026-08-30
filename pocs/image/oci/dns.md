# DNS for `demo.tui.tools`

Deliberately not automated. `quave.one` is a production zone shared by things
that are not this demo, and a script in a lab repository that can write records
into it is a script that can take something else down. The record is two
minutes of work and it is the owner's to make.

## The record

| | |
|---|---|
| Name | `omarchy-server-demo` (in the `quave.one` zone) |
| Type | `A` |
| Value | the public IP `launch-demo.sh` printed |
| TTL | `300` while the demo is being reset often; `3600` once it settles |

A short TTL is not caution, it is the reset story: `reset.md`'s cheapest path
re-launches the instance and gets a **new** public IP. With a 3600 s TTL that
is an hour of a demo pointing at nothing.

No `AAAA`: the instance is launched into a subnet with an IPv4 public IP and
nothing in the profile listens on IPv6 by choice. Add one only after
`ip -6 addr` on the machine shows a global address the platform routes.

## Verifying it

```bash
dig +short demo.tui.tools A
ssh -i pocs/image/out/demo-guest_ed25519 demo@demo.tui.tools
```

The second command will ask about a host key it has never seen. That is
correct and it is the point of the image shipping without one: compare what ssh
offers against the fingerprint in the instance's serial console
(`journalctl -u omarchy-server-firstboot` prints every host key's fingerprint at
first boot, and the console shows the same lines) before typing `yes`.

```bash
./pocs/image/oci/make-demo-key.sh --fingerprint     # fills the 1Password block
```

## Reserved IP

If the demo becomes something people bookmark, reserve the public IP in OCI
(`oci network public-ip create --lifetime RESERVED`) and attach it to the
instance's VNIC. Then the address survives a re-launch, the A record stops
being part of the reset procedure, and the TTL can go up.
