# Server replacement for install/hardware/network.sh.
#
# The desktop edition runs NetworkManager, and hardware/network.sh exists to
# retire the systemd-networkd state archinstall leaves behind. A headless
# machine wants the opposite: systemd-networkd and systemd-resolved are already
# part of systemd, so a DHCP server needs no networking package at all and
# NetworkManager (plus its wpa_supplicant/iwd, modem and dispatcher surface)
# drops out of the install entirely.
#
# archinstall's "copy ISO network" mode already writes 20-ethernet.network with
# `Name=en*` / `DHCP=yes`, which is exactly what is wanted here. Keep it when it
# is there, and write an equivalent when it is not, so this script is correct
# whether or not archinstall did the work.

install -d -m 0755 /etc/systemd/network

if ! compgen -G '/etc/systemd/network/*.network' >/dev/null; then
  cat >/etc/systemd/network/20-wired.network <<'EOF'
# Omarchy Server: DHCP on any wired interface. Replace or shadow this file with
# a lower-numbered one to give the machine a static address.
[Match]
Name=en* eth*

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCPv4]
UseDomains=yes
EOF
  chmod 0644 /etc/systemd/network/20-wired.network
fi

# resolved's stub resolver, so /etc/resolv.conf is a symlink into /run rather
# than a file the DHCP client rewrites.
#
# Not inside the ISO's install chroot, though: arch-chroot bind-mounts the live
# environment's /etc/resolv.conf over the target's so the chroot has working
# DNS, and replacing a bind mount with a symlink is both impossible and
# pointless. That is exactly why the ISO writes this symlink from outside, in
# its configure_dns_resolver phase — Arch's documented way of doing it. This
# block is what makes the script correct on its own when it is re-applied on a
# running machine.
if ! mountpoint -q /etc/resolv.conf 2>/dev/null &&
  { [[ ! -L /etc/resolv.conf ]] ||
    [[ $(readlink /etc/resolv.conf) != *stub-resolv.conf ]]; }; then
  ln -sfn ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi

# iwd competes with whatever manages the link and has no place on a wired
# server. Disabled rather than removed: it is not installed in this profile,
# and this guards against a dependency dragging it back.
systemctl disable iwd.service 2>/dev/null || true

# Never block boot on DHCP. The unit is pulled in by network-online.target,
# which anything ordering itself after the network drags in.
systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true
