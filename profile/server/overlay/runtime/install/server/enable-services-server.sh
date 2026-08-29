# Server variant of config/enable-services.sh.
#
# Enable services only. Installs are followed by reboot, so don't start/reload
# daemons mid-install. UFW stays in firewall-server.sh; snapper-cleanup.timer
# and limine-snapper-sync.service are enabled by config/snapper.sh.
#
# The list is exhaustive on purpose: what a server runs is the surface it
# offers, so every unit here has to justify itself and nothing else is enabled.
# Dropped versus upstream: cups, cups-browsed, avahi-daemon,
# power-profiles-daemon, sddm, docker.socket (the `docker` addon enables it)
# and NetworkManager (replaced by systemd-networkd/-resolved).

# A server has no graphical session to boot into.
systemctl set-default multi-user.target

# The console of the machine. Upstream only enables sshd from the ISO's
# configure_ssh_access phase, and only when the autoinstall drive carried an
# authorized_keys file; on a server it is unconditional, which is why
# sshd-hardening-server.sh runs before this.
systemctl enable sshd.service

# Networking, from systemd itself: no NetworkManager, no wpa_supplicant, no
# dispatcher scripts. Configuration in install/server/network-server.sh.
systemctl enable systemd-networkd.service
systemctl enable systemd-resolved.service

# Correct time is a prerequisite for readable logs and for TLS.
systemctl enable systemd-timesyncd.service

# Keep the running kernel's modules loadable after an upgrade until the reboot.
systemctl enable linux-modules-cleanup.service

# Kill one runaway service instead of letting reclaim thrashing take the whole
# machine down. The eligible-cgroup drop-in is retargeted at system.slice in
# omarchy-server-settings, because a server has no user app.slice to watch.
systemctl enable systemd-oomd.service

# Serial console for headless debugging, paired with the console=ttyS0,115200
# cmdline from etc/limine-entry-tool.d/omarchy-defaults.conf.
systemctl enable serial-getty@ttyS0.service

# Tokyo Night on the virtual consoles, so the machine looks the same after the
# bootloader hands over as it did in the menu. Oneshot, ordered before getty,
# skipped where there is no /dev/tty1.
systemctl enable omarchy-tty-palette.service

# Never block boot on DHCP; see also the networkd mask in network-server.sh.
systemctl mask NetworkManager-wait-online.service 2>/dev/null || true

# None of these is installed in this profile. Masking is what keeps a
# dependency from quietly reintroducing one: a masked unit cannot be started,
# enabled or pulled in by another unit's Wants=.
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

# Enabled by snapper's own packaging, and not wanted: hourly timeline snapshots
# on a server fill the disk to record nothing changing.
systemctl disable snapper-timeline.timer 2>/dev/null || true
