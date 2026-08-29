# Server variant of install/user/all.sh, sourced by omarchy-provision-user when
# OMARCHY_PROFILE=server (see the provision-user patch in the overlay).
#
# Of the 13 scripts upstream chains here, exactly one applies to a headless
# machine: git.sh, which writes the name and e-mail collected by the installer
# into ~/.gitconfig. Everything else is theme, browser, compose key, GNOME
# keyring, mise-managed AI CLIs or per-laptop audio fixes.
#
# git is not part of the lean base (it comes with the `dev` addon), and
# `git config` is the only thing git.sh does, so the step is conditional
# instead of being a guaranteed failure on every install.
if command -v git >/dev/null; then
  run_logged "$OMARCHY_INSTALL/user/git.sh"
fi
