# Setup leaf for the `editor` addon, sourced by omarchy-server-addon.
#
# omarchy-nvim seeds its configuration through /etc/skel, which only helps
# users created after it is installed. Copy it into the existing home
# directories that do not have one yet, so the addon is useful on a machine
# that is already running.
for home in /home/*; do
  [[ -d $home ]] || continue
  [[ -e $home/.config/nvim ]] && continue
  [[ -d /etc/skel/.config/nvim ]] || continue

  owner=$(stat -c '%U:%G' "$home")
  install -d -o "${owner%%:*}" -g "${owner##*:}" "$home/.config"
  cp -a /etc/skel/.config/nvim "$home/.config/nvim"
  chown -R "$owner" "$home/.config/nvim"
done
