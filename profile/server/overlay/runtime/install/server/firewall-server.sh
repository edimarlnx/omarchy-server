# Server variant of config/firewall.sh.
#
# Dropped versus upstream: the two LocalSend rules (not installed) and the
# whole Docker block — the docker DNS rules and `ufw-docker install` moved to
# install/server/addons/docker.sh, because a base install has no Docker and
# therefore no bridge network to poke a hole for.
#
# Added: `ufw limit 22/tcp`. This is the one port the machine answers on, so it
# is also the one port that gets probed; `limit` drops a source that opens six
# connections in thirty seconds, which is the whole of a password-guessing run
# even though passwords are already off.

# Allow nothing in, everything out.
ufw default deny incoming
ufw default allow outgoing

# The ISO's configure_ssh_access phase adds its own rule for port 22 after
# this script runs. On the server profile it adds the same `limit` rule, so the
# two agree instead of the later `allow` replacing this one; see the
# orchestrator patch in iso/patches/. This line is what makes the profile
# correct when it is applied outside the ISO.
ufw limit 22/tcp comment 'omarchy-sshd'

# Installs are followed by reboot, so configure UFW to start on the installed
# system instead of mutating the live install session's firewall.
sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf
systemctl enable ufw
