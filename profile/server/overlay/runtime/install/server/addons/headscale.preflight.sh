# Preflight for the `headscale` addon, sourced by omarchy-server-addon BEFORE
# it installs anything.
#
# First: if the machine already has a headscale -- installed by hand, by another
# repository, by an earlier run -- there is nothing to do and nothing to touch.
# Installing over it could downgrade a working coordination server or swap its
# source under the operator; an existing install is theirs to keep. Exiting is
# how a preflight refuses, and here it refuses the happy way.
if command -v headscale >/dev/null 2>&1; then
  echo "headscale: already installed ($(command -v headscale)), leaving it as it is."
  exit 0
fi

# The package comes from the tui-tools repository, so the repository and its
# pinned signing key have to be configured first. That is exactly what the
# tui-tools addon's preflight does, and it is idempotent, so it is reused
# rather than copied: one place holds the fingerprint and the repo stanza.
# shellcheck disable=SC1091
source "$OMARCHY_INSTALL/server/addons/tui-tools.preflight.sh"
