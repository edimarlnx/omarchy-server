# Preflight for the `tui-tools` addon, sourced by omarchy-server-addon BEFORE
# it installs anything. It configures the repository the tools publish
# themselves and pins the key that signs it, which has to happen first: on an
# installed machine there is nowhere else to fetch these packages from.
#
#   [tui-tools]
#   SigLevel = Required TrustedOnly
#   Server   = https://pkgs.tui.tools/arch/$arch
#
# Required, not TrustAll: the repository signs both its database and every
# package, and this profile has no reason to accept less than that.
#
# The signing key is vendored beside this file rather than fetched, so the key
# a machine trusts is the key that is in this repository's history, and an
# install off the ISO's offline mirror needs no network at all. Whichever copy
# is used, its fingerprint is compared against the one pinned below before
# anything is imported -- `pacman-key --add` of a downloaded file with no
# fingerprint check would trust whatever the network handed over.

tui_tools_fingerprint=767CFB337B01F32FFC073F3F389120B277E4FB44
tui_tools_pubkey_url=https://pkgs.tui.tools/pubkey.asc
tui_tools_repo_conf=/etc/pacman.d/tui-tools.conf
tui_tools_pubkey="$OMARCHY_INSTALL/server/addons/tui-tools.pubkey.asc"

# Installing from the ISO's offline mirror: the packages are already on the
# medium, so a failure to reach the network or to reach pacman's keyring must
# not abort an install. The repository is still configured, because the machine
# that comes out of that install is the one that will want updates.
tui_tools_offline=0
[[ -n ${OMARCHY_ADDON_PACMAN_CONF:-} ]] && tui_tools_offline=1

tui_tools_fail() {
  echo "tui-tools: $1" >&2
  if ((tui_tools_offline)); then
    echo "tui-tools: continuing; the packages come from the offline mirror on this install." >&2
    return 1
  fi
  exit 1
}

tui_tools_setup_key() {
  local key=$tui_tools_pubkey found

  if [[ ! -f $key ]]; then
    # No vendored copy (an older runtime package, or a hand-assembled tree).
    # Falling back to the published key is still safe, because the fingerprint
    # check below is what decides whether it is trusted.
    key=$(mktemp) || return 1
    curl -fsSL --retry 3 -o "$key" "$tui_tools_pubkey_url" ||
      { tui_tools_fail "could not download $tui_tools_pubkey_url"; return 1; }
  fi

  found=$(gpg --show-keys --with-colons "$key" 2>/dev/null |
    awk -F: '$1 == "fpr" { print $10; exit }')
  if [[ $found != "$tui_tools_fingerprint" ]]; then
    tui_tools_fail "key fingerprint is $found, expected $tui_tools_fingerprint"
    return 1
  fi

  # pacman-key needs its keyring to exist before a key can be added to it or
  # signed locally. On an installed machine it always does; inside a target
  # chroot that has not been populated yet, creating it is one command.
  [[ -d /etc/pacman.d/gnupg ]] || pacman-key --init ||
    { tui_tools_fail "pacman-key --init failed"; return 1; }

  pacman-key --add "$key" ||
    { tui_tools_fail "pacman-key --add failed"; return 1; }
  # --lsign-key is what moves the key from "known" to "trusted by this
  # machine"; without it every package from the repository is rejected as
  # signed by an untrusted key.
  pacman-key --lsign-key "$tui_tools_fingerprint" ||
    { tui_tools_fail "pacman-key --lsign-key failed"; return 1; }

  echo "tui-tools: signing key $tui_tools_fingerprint imported and locally signed"
}

tui_tools_setup_repo() {
  # $arch is pacman's own variable, not the shell's: quoted so it reaches the
  # file literally and pacman expands it per architecture.
  cat >"$tui_tools_repo_conf" <<'CONF'
# The tui-tools repository (https://pkgs.tui.tools), written by
# `omarchy-server-addon tui-tools`. Signed by
# 767CFB337B01F32FFC073F3F389120B277E4FB44, imported into pacman's keyring and
# locally signed by the same addon.
[tui-tools]
SigLevel = Required TrustedOnly
Server = https://pkgs.tui.tools/arch/$arch
CONF

  # Same shape as the Include omarchy-server-settings drops for
  # [omarchy-server]: one line appended to pacman.conf, added once.
  if ! grep -q "^Include *= *$tui_tools_repo_conf" /etc/pacman.conf; then
    printf '\n# Added by `omarchy-server-addon tui-tools`.\nInclude = %s\n' \
      "$tui_tools_repo_conf" >>/etc/pacman.conf
  fi
  echo "tui-tools: repository configured in $tui_tools_repo_conf"
}

tui_tools_setup_key || true
tui_tools_setup_repo

unset tui_tools_fingerprint tui_tools_pubkey_url tui_tools_repo_conf tui_tools_pubkey tui_tools_offline
unset -f tui_tools_fail tui_tools_setup_key tui_tools_setup_repo
