# Server variant of config/ssh-command-path.sh.
#
# SSH commands (ssh host cmd) run without a login or interactive shell, so on
# Arch the PAM environment is the only place they can inherit PATH from.
# Differences from upstream:
#   - @{HOME}/.local/share/mise/shims is dropped: mise is not in the server
#     profile.
#   - OMARCHY_PATH is added. /etc/profile.d only covers login shells and
#     default/bash/envs only covers the bash rc chain; a bare `ssh host
#     omarchy-refresh-pacman` gets neither, and 53 of the shipped commands
#     read $OMARCHY_PATH without a ${:-/usr/share/omarchy} fallback.
#     See docs/packaging.md, "Auditoria do OMARCHY_PATH".
if ! grep -qE '^PATH[[:space:]]' /etc/security/pam_env.conf; then
  cat >>/etc/security/pam_env.conf <<'EOF'

# Omarchy: give SSH commands and other non-shell logins the user-level tool paths
PATH DEFAULT=/usr/local/sbin:/usr/local/bin:/usr/bin:@{HOME}/.local/bin
EOF
fi

if ! grep -qE '^OMARCHY_PATH[[:space:]]' /etc/security/pam_env.conf; then
  cat >>/etc/security/pam_env.conf <<'EOF'

# Omarchy: commands invoked over ssh without a shell still need OMARCHY_PATH
OMARCHY_PATH DEFAULT=/usr/share/omarchy
EOF
fi
