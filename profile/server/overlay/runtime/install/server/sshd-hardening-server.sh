# sshd defaults for a machine whose only door is sshd.
#
# Upstream has no equivalent: on the desktop, `omarchy-setup-security-sshd` is
# what turns sshd on, and it is a command the owner runs by hand. On a server
# sshd is enabled unconditionally at install time, so the hardening has to be
# part of the install rather than a later opt-in — a machine that boots with
# password authentication open is exposed from its first second on the network.
#
# What this leaves to omarchy-setup-security-sshd: authorizing keys (from
# GitHub or pasted) and the `ufw limit 22/tcp` rule, which firewall-server.sh
# already applies. Running that command afterwards remains harmless.
#
# A drop-in, not an edit of /etc/ssh/sshd_config: the main file is owned by
# openssh and pacman would fight over it on every upgrade.

install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/10-omarchy-server.conf <<'EOF'
# Omarchy Server: keys only.
#
# Delete this file to go back to OpenSSH's defaults, or shadow it with a
# lower-numbered drop-in. sshd reads the FIRST value it sees for a keyword, and
# /etc/ssh/sshd_config includes this directory before setting anything itself,
# so these win over the distribution defaults.

# Passwords are the one credential that can be guessed from the internet, and
# an install that authorized a key does not need them.
PasswordAuthentication no

# The same door by another name: keyboard-interactive falls through to PAM and
# back to the account's password.
KbdInteractiveAuthentication no

# Root logs in through a named account and sudo, so the audit trail names a
# person. Nothing on this machine needs a root ssh session.
PermitRootLogin no

# An empty password is not a password.
PermitEmptyPasswords no
EOF
chmod 0644 /etc/ssh/sshd_config.d/10-omarchy-server.conf

# Catch a typo here instead of at the next boot. `-G` parses the configuration
# and prints the effective one; unlike `-t` it does not load the host keys,
# which do not exist yet inside the ISO's install chroot (sshd-keygen.service
# generates them on first boot). Reported rather than fatal: an install that
# stops here leaves a machine nobody can reach at all.
if ! sshd_check=$(sshd -G 2>&1 >/dev/null); then
  echo "warning: sshd rejected its configuration: $sshd_check" >&2
fi
