# Resetting the demo

A demo box is a machine strangers have root on. Assume every one of them
changed something, and reset on a schedule rather than on suspicion.

There are three ways back, and they differ in what they cost and in what they
prove.

## 1. `@factory` — seconds, no cloud API, keeps the IP

The image was generalized with `omarchy-server-generalize`, whose last act is a
read-only btrfs snapshot of the finished root, taken at the top level beside
`@` and called `@factory`. It is the exact state every machine from this image
started from, and it is still on the boot volume.

Going back to it is the same pair of renames a transactional rollback is
(`docs/transactional.md`), which is why it is safe under a signed boot chain:
the kernel command line, the UKI, `/etc/fstab` and every pacman hook stay byte
for byte what they were.

```bash
sudo -i
top=$(mktemp -d)
mount -o subvolid=5 "$(findmnt -no SOURCE / | sed 's/\[.*//')" "$top"

# A read-only snapshot cannot BE the root; take a writable copy of it.
btrfs subvolume snapshot "$top/@factory" "$top/@reset"
mv "$top/@" "$top/@old-$(date +%Y%m%d%H%M%S)"
mv "$top/@reset" "$top/@"
umount "$top" && reboot
```

What it does **not** undo: anything outside `@`. `/home` is `@home` and
`/var/log` is `@log`, both separate subvolumes. Delete them by hand if the
point of the reset is that the last visitor's home directory is gone:

```bash
btrfs subvolume delete "$top/@home" && btrfs subvolume create "$top/@home"
```

Nor does it re-run cloud-init: the instance-id has not changed, so the accounts
`launch-demo.sh` created are the accounts in `@factory`… which is to say they
are **not** there, because `@factory` predates them. Add
`cloud-init clean --logs` before the reboot so the next boot re-applies the
metadata and recreates `demo`:

```bash
cloud-init clean --logs && reboot
```

## 2. Boot volume backup restore — minutes, keeps the image, changes the IP

Take a backup once, right after the demo is set up the way it should be found:

```bash
oci bs boot-volume-backup create --boot-volume-id <BOOT VOLUME OCID> \
    --display-name omarchy-server-demo-golden --type FULL
```

Restoring means creating a new boot volume from the backup and launching an
instance against it; the old instance is terminated. It is the only route that
also resets `/home` and `/var/log`, and it captures the state *after* the
launch metadata was applied, which `@factory` cannot.

## 3. Re-launch from the image — minutes, proves the most

Terminate the instance and run `launch-demo.sh` again. It is the slowest of the
three and the only one that re-exercises the whole path a customer would take:
image → metadata → first boot → host keys → growpart. If a reset is also a
smoke test, this is the one.

```bash
oci compute instance terminate --instance-id <OCID> --preserve-boot-volume false --force
./pocs/image/oci/launch-demo.sh --compartment-id ... --image-id ... --subnet-id ... \
    --demo-key ../out/demo-guest_ed25519.pub --owner-key ~/.ssh/id_ed25519.pub --yes
```

The public IP changes unless it was reserved (`dns.md`), so update the A record.
The ssh host key changes too — that is the image working correctly, and
`make-demo-key.sh --fingerprint` is how the 1Password entry catches up.

## Which one to use

| Situation | Route |
|---|---|
| Nightly, unattended, IP must not move | 1 (`@factory` + `cloud-init clean`) |
| Someone broke it and `/home` is suspect | 2 (boot volume backup) |
| Before showing it to somebody who matters | 3 (re-launch) |
