# Server profile entry point, run by omarchy-apply-system instead of
# config/all.sh + omarchy-apply-hardware + login/all.sh + post-install/all.sh
# when OMARCHY_PROFILE=server (see the apply-system patch in the overlay).
#
# Conventions follow agents/skills/install-scripts.md: leaf scripts are sourced
# through run_logged, carry no shebang and no exit, and take every path from
# $OMARCHY_INSTALL / $OMARCHY_PATH.

# --- system configuration -----------------------------------------------
run_logged "$OMARCHY_INSTALL/server/increase-lockout-limit-server.sh"
run_logged "$OMARCHY_INSTALL/server/ssh-command-path-server.sh"

# ssh keepalive defaults in /etc/ssh/ssh_config.d (upstream, unchanged)
run_logged "$OMARCHY_INSTALL/config/ssh-keepalive.sh"

# Key-only sshd, before the service is enabled below.
run_logged "$OMARCHY_INSTALL/server/sshd-hardening-server.sh"

# snapper root config + snapper-cleanup.timer + limine-snapper-sync
run_logged "$OMARCHY_INSTALL/config/snapper.sh"

# --- network ------------------------------------------------------------
# systemd-networkd + systemd-resolved, in place of upstream's
# hardware/network.sh, which exists to retire exactly that state in favour of
# NetworkManager.
run_logged "$OMARCHY_INSTALL/server/network-server.sh"

# --- services -----------------------------------------------------------
run_logged "$OMARCHY_INSTALL/server/enable-services-server.sh"

# --- firewall -----------------------------------------------------------
run_logged "$OMARCHY_INSTALL/server/firewall-server.sh"

# --- post-install -------------------------------------------------------
run_logged "$OMARCHY_INSTALL/server/post-install-pacman-server.sh"

# udevadm reload + power_supply trigger (upstream, unchanged)
run_logged "$OMARCHY_INSTALL/post-install/udev.sh"

# Trim the package cache so the @factory snapshot is taken on a clean disk.
# Last on purpose: everything above may still install packages, and the ISO's
# addon phase runs after this and prunes again.
run_logged "$OMARCHY_INSTALL/server/prune-pkg-cache-server.sh"

# ------------------------------------------------------------------------
# Deliberately NOT run in this profile (upstream files stay untouched):
#   config/docker.sh                        docker is an addon, not the base
#   config/locate.sh, post-install/localdb.sh
#                                           plocate is not installed; nothing
#                                           in the server runtime calls `locate`
#   config/theme-system.sh                  Yaru icons + Chromium policy
#   config/lockscreen-pam.sh                graphical lockscreen
#   config/fix-powerprofilesctl-shebang.sh  power-profiles-daemon not installed
#   config/increase-lockout-limit.sh        replaced above (no sddm-autologin)
#   config/ssh-command-path.sh              replaced above (no mise shims)
#   config/enable-services.sh               replaced above
#   config/firewall.sh                      replaced above (no LocalSend/docker)
#   post-install/pacman.sh                  replaced above (no cups-browsed)
#   login/all.sh, login/sddm.sh             no display manager
#   hardware/all.sh                         38 laptop/GPU/audio fixes; its
#                                           network.sh is replaced above
#
# Per-user setup is not part of this file. It runs as the user through
# omarchy-provision-user.
