# Router variant of install/server/enable-services-server.sh.
#
# Identical to the server profile's service set with one substitution: the
# firewall is nftables.service, not ufw.service (enabled by
# install/router/firewall-router.sh, not here, the same way the server profile
# leaves ufw's enablement to firewall-server.sh). Everything else -- what a
# headless machine enables and the exhaustive mask list -- is the server set,
# because a router is a server that forwards.
#
# Enable services only. Installs are followed by reboot, so don't start/reload
# daemons mid-install.

# A router has no graphical session to boot into.
systemctl set-default multi-user.target

# The console of the machine.
systemctl enable sshd.service

# Networking, from systemd itself: no NetworkManager. Configuration in
# install/router/network-router.sh (wan0/lan0 role links, LAN DHCP server).
systemctl enable systemd-networkd.service
systemctl enable systemd-resolved.service

# Correct time is a prerequisite for readable logs and for TLS.
systemctl enable systemd-timesyncd.service

# Keep the running kernel's modules loadable after an upgrade until the reboot.
systemctl enable linux-modules-cleanup.service

# Kill one runaway service instead of letting reclaim thrashing take the whole
# machine down.
systemctl enable systemd-oomd.service

# Serial console for headless debugging, paired with console=ttyS0,115200.
systemctl enable serial-getty@ttyS0.service

# Tokyo Night on the virtual consoles.
systemctl enable omarchy-tty-palette.service

# Never block boot on DHCP; see also the networkd mask in network-router.sh.
systemctl mask NetworkManager-wait-online.service 2>/dev/null || true

# None of these is installed in this profile. Masking keeps a dependency from
# quietly reintroducing one.
for unit in \
  plymouth-start.service \
  plymouth-quit.service \
  plymouth-quit-wait.service \
  sddm.service \
  cups.service \
  cups.socket \
  cups-browsed.service \
  avahi-daemon.service \
  avahi-daemon.socket \
  bluetooth.service \
  power-profiles-daemon.service; do
  systemctl mask "$unit" 2>/dev/null || true
done

# Hourly timeline snapshots on a router fill the disk to record nothing
# changing.
systemctl disable snapper-timeline.timer 2>/dev/null || true
