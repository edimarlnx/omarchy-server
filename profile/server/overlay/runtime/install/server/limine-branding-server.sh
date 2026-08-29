# Put the Limine wallpaper on the ESP, next to limine.conf.
#
# The branded menu is two files. limine.conf comes from
# default/limine/limine.conf, which the ISO installer copies to the ESP and
# `omarchy-refresh-limine` copies again on demand, so its `wallpaper:` line
# survives every regeneration by limine-entry-tool and limine-snapper-sync.
# The image it points at is not on the ESP unless something puts it there, and
# that is this file.
#
# `boot():/limine-wallpaper.png` resolves to the partition limine.conf itself
# was read from, so the destination is the ESP mount and nothing else. Limine
# skips a wallpaper it cannot read instead of panicking, which is what makes
# this safe to be best-effort: a machine whose ESP is full still boots, just
# without the image.

omarchy_esp_mount() {
  local esp=""

  # Written by the installer's _write_limine_defaults from the profile's
  # default.conf, and by limine-entry-tool afterwards. It is the only record of
  # where this machine's ESP is mounted.
  if [[ -r /etc/default/limine ]]; then
    esp=$(sed -n 's/^[[:space:]]*ESP_PATH=["'\'']\{0,1\}\([^"'\'']*\).*/\1/p' /etc/default/limine | tail -n 1)
  fi

  printf '%s' "${esp:-/boot}"
}

omarchy_install_limine_wallpaper() {
  local wallpaper esp
  wallpaper="$OMARCHY_PATH/default/limine/limine-wallpaper.png"
  esp=$(omarchy_esp_mount)

  if [[ ! -r $wallpaper ]]; then
    echo "limine branding: no wallpaper at $wallpaper, skipping" >&2
    return 0
  fi
  if [[ ! -d $esp ]]; then
    echo "limine branding: ESP $esp is not mounted, skipping" >&2
    return 0
  fi

  install -Dm644 "$wallpaper" "$esp/limine-wallpaper.png"
}

omarchy_install_limine_wallpaper || true
