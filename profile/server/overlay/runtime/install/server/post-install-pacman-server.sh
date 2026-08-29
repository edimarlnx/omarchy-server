# Server variant of post-install/pacman.sh.
#
# Configure pacman after package installation completes. Offline target package
# installs use the live ISO's offline pacman.conf until this final restore.
#
# Dropped versus upstream: the cups-browsed.conf override block (cups is not
# installed) and `source hardware/pacman.sh`, whose only body is the MacBook T2
# [arch-mact2] repo hook, gated on an lspci id no server target has.
cp -f "$OMARCHY_PATH/default/pacman/pacman-${OMARCHY_MIRROR:-stable}.conf" /etc/pacman.conf
cp -f "$OMARCHY_PATH/default/pacman/mirrorlist-${OMARCHY_MIRROR:-stable}" /etc/pacman.d/mirrorlist
