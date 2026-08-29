# Export OMARCHY_PATH for login shells.
#
# On the desktop the authoritative export happens in the uwsm session
# (usr/share/uwsm/env.d/10-omarchy). There is no session on a server, so this
# file plus /etc/profile.d/omarchy.sh (which sources default/bash/env-bootstrap)
# are what put OMARCHY_PATH in the environment. Kept separate and dependency
# free so the export survives even if env-bootstrap is unavailable.
#
# Commands invoked over ssh with no shell at all (ssh host omarchy-...) are
# covered by the pam_env line from install/server/ssh-command-path-server.sh.
# See docs/packaging.md, "Auditoria do OMARCHY_PATH".
[ -n "${OMARCHY_PATH:-}" ] || export OMARCHY_PATH=/usr/share/omarchy
