# Trim /var/cache/pacman/pkg so the @factory snapshot is taken on a clean disk.
#
# Measured on the desktop reference install: 14 GB used on / against 8.08 GiB
# installed, the difference being the install-time package cache on the @pkg
# subvolume. Upstream's omarchy-update-pkg-prune already runs `paccache -rk2`
# before every update; the install itself never prunes.
#
# -rk1 keeps the currently installed version of each package, so a
# `pacman -U` downgrade after a bad update is still possible offline.
# paccache -rk1 || true
paccache -ruk0 || true
