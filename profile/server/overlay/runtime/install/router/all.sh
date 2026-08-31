# Router profile entry point, run by omarchy-apply-system instead of
# config/all.sh + omarchy-apply-hardware + login/all.sh + post-install/all.sh
# when OMARCHY_PROFILE=router (see the apply-system patch in the overlay).
#
# The router profile is the server base with a router's network and firewall
# layered on. Everything here that is not router-specific is the same leaf the
# server profile runs: this file sources those leaves from install/server/
# directly rather than copying them, so the two profiles cannot drift.
#
# Conventions follow agents/skills/install-scripts.md: leaf scripts are sourced
# through run_logged, carry no shebang and no exit, and take every path from
# $OMARCHY_INSTALL / $OMARCHY_PATH.

# --- system configuration (shared with the server profile) --------------
run_logged "$OMARCHY_INSTALL/server/increase-lockout-limit-server.sh"
run_logged "$OMARCHY_INSTALL/server/ssh-command-path-server.sh"

# ssh keepalive defaults in /etc/ssh/ssh_config.d (upstream, unchanged)
run_logged "$OMARCHY_INSTALL/config/ssh-keepalive.sh"

# Key-only sshd, before the service is enabled below.
run_logged "$OMARCHY_INSTALL/server/sshd-hardening-server.sh"

# snapper root config + snapper-cleanup.timer + limine-snapper-sync
run_logged "$OMARCHY_INSTALL/config/snapper.sh"

# The Limine wallpaper onto the ESP, beside the limine.conf the installer
# already wrote from the profile's template.
run_logged "$OMARCHY_INSTALL/server/limine-branding-server.sh"

# --- router identity ----------------------------------------------------
# The console says "router" while keeping the Omarchy identity: issue.net and
# the profile marker the MOTD reads.
run_logged "$OMARCHY_INSTALL/router/identity-router.sh"

# --- network ------------------------------------------------------------
# systemd-networkd + systemd-resolved with WAN/LAN role links, in place of
# upstream's hardware/network.sh. This also writes the IP-forwarding sysctl
# drop-in: a router forwards, a server does not.
run_logged "$OMARCHY_INSTALL/router/network-router.sh"

# --- updates ------------------------------------------------------------
# A headless machine updates as root, and root has no /etc/skel seeding.
run_logged "$OMARCHY_INSTALL/server/root-migration-state-server.sh"

# --- services -----------------------------------------------------------
run_logged "$OMARCHY_INSTALL/router/enable-services-router.sh"

# The daily update timer, off unless the autoinstall drive asked for it.
run_logged "$OMARCHY_INSTALL/server/unattended-updates-server.sh"

# --- firewall -----------------------------------------------------------
# Seeds the default `inet tui` nftables table and enables nftables.service.
# The ISO's configure_ssh_access phase and ufw play no part here: the router
# has no ufw. See firewall-router.sh for the exposed-ports contract.
run_logged "$OMARCHY_INSTALL/router/firewall-router.sh"

# --- post-install (shared with the server profile) ----------------------
run_logged "$OMARCHY_INSTALL/server/post-install-pacman-server.sh"

# udevadm reload + power_supply trigger (upstream, unchanged)
run_logged "$OMARCHY_INSTALL/post-install/udev.sh"

# Trim the package cache so the @factory snapshot is taken on a clean disk.
run_logged "$OMARCHY_INSTALL/server/prune-pkg-cache-server.sh"

# ------------------------------------------------------------------------
# Deliberately NOT run in this profile, exactly as the server profile omits
# them (upstream files stay untouched): config/docker.sh, config/locate.sh,
# post-install/localdb.sh, config/theme-system.sh, config/lockscreen-pam.sh,
# config/fix-powerprofilesctl-shebang.sh, config/increase-lockout-limit.sh,
# config/ssh-command-path.sh, config/enable-services.sh, config/firewall.sh
# (replaced by the nftables router firewall), post-install/pacman.sh,
# login/all.sh, login/sddm.sh, hardware/all.sh.
#
# Also NOT run, versus the server profile:
#   server/network-server.sh   replaced by router/network-router.sh
#                              (role links + forwarding + a LAN DHCP server)
#   server/firewall-server.sh  replaced by router/firewall-router.sh
#                              (nftables inet tui table, not ufw)
#   server/enable-services-server.sh
#                              replaced by router/enable-services-router.sh
#                              (nftables.service, not ufw.service)
#
# Per-user setup runs as the user through omarchy-provision-user, same as the
# server profile.
