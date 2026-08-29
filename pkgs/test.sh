#!/bin/bash

# Install the packages from the local signed repo into a fresh
# archlinux:latest container and assert the acceptance criteria of the packaging step
#: the server profile must install without pulling a single desktop
# dependency, and the commands the ISO and omarchy-update rely on must work.
#
#   ./pkgs/test.sh
#
# Run ./pkgs/build.sh first. Anything that needs a running init (systemctl,
# ufw, mkinitcpio) is checked by parsing or --help only; the real thing is the
# the VM install.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
pkgs_dir="$repo_root/pkgs"
image=${OMARCHY_BUILD_IMAGE:-archlinux:latest}

[[ -f $pkgs_dir/repo/omarchy-server.db.tar.gz ]] || {
  echo "Error: pkgs/repo is empty. Run ./pkgs/build.sh first." >&2
  exit 1
}

docker run --rm \
  -v "$pkgs_dir/repo:/repo:ro" \
  "$image" bash -euo pipefail -c '
    fail=0
    check() {
      local label="$1"; shift
      if "$@" >/tmp/check.out 2>&1; then
        echo "  PASS  $label"
      else
        echo "  FAIL  $label"
        sed "s/^/        /" /tmp/check.out
        fail=1
      fi
    }

    # [omarchy] provides limine-mkinitcpio-hook, limine-snapper-sync, ufw-docker,
    # tzupdate and yay, which are not in the Arch repositories. The ISO mirrors
    # it offline; here it is fetched over the network.
    cat >>/etc/pacman.conf <<EOF

[omarchy]
SigLevel = Optional TrustAll
Server = https://pkgs.omarchy.org/stable/\$arch

[omarchy-server]
SigLevel = Required DatabaseOptional
Server = file:///repo
EOF

    echo "== pacman keyring =="
    pacman-key --init
    pacman-key --populate archlinux

    # Trust anchor bootstrap. The keyring package is signed by the very key it
    # delivers, so it cannot verify itself — the same chicken-and-egg
    # archlinux-keyring has. Break it by importing the key out of the package
    # file and locally signing it, then install the package normally with full
    # signature checking. (On an ISO install the equivalent step is the
    # offline mirror, which pacman reads as SigLevel = Optional TrustAll.)
    bsdtar -xOf /repo/omarchy-server-keyring-*.pkg.tar.zst \
      usr/share/pacman/keyrings/omarchy-server.gpg >/tmp/omarchy-server.gpg
    bsdtar -xOf /repo/omarchy-server-keyring-*.pkg.tar.zst \
      usr/share/pacman/keyrings/omarchy-server-trusted >/tmp/omarchy-server-trusted
    repo_key=$(cut -d: -f1 /tmp/omarchy-server-trusted)
    pacman-key --add /tmp/omarchy-server.gpg
    pacman-key --lsign-key "$repo_key"

    pacman -U --noconfirm /repo/omarchy-server-keyring-*.pkg.tar.zst
    pacman-key --populate omarchy-server

    echo
    echo "== installing omarchy-server from [omarchy-server] =="
    pacman -Sy --noconfirm omarchy-server

    echo
    echo "== assertions =="
    # Read the version back from pacman instead of writing it down here. Every
    # content change bumps pkgrel (docs/packaging.md §1 "Versioning"), so a
    # literal in this file would have to be edited on every release and would
    # fail the run on the one it was forgotten on.
    pkg_version=$(pacman -Q omarchy-server | cut -d" " -f2)   # pkgver-pkgrel
    pkg_pkgver=${pkg_version%%-*}
    echo "testing omarchy-server $pkg_version"
    check "no desktop packages installed" bash -c \
      "! pacman -Qq | grep -qE \"^(hyprland|sddm|pipewire|quickshell|plymouth|wireplumber|uwsm|gnome-keyring|xdg-desktop-portal-hyprland)\""
    check "omarchy-version prints the package version" bash -c \
      "[[ \$(omarchy-version) == $pkg_version ]]"
    # The runtime depends on omarchy-server-settings=${pkgver}, without a
    # pkgrel, so the two may carry different pkgrels; only the pkgver has to
    # agree.
    check "omarchy-server-settings is the matching pkgver" bash -c \
      "[[ \$(pacman -Q omarchy-server-settings | cut -d\" \" -f2) == $pkg_pkgver-* ]]"
    check "omarchy-pkg-present bash" omarchy-pkg-present bash
    check "omarchy-pkg-present of a missing package fails" bash -c \
      "! omarchy-pkg-present definitely-not-installed"
    check "login shell exports OMARCHY_PATH" bash -c \
      "[[ \$(bash -lc \"echo \\\$OMARCHY_PATH\") == /usr/share/omarchy ]]"
    check "omarchy-apply-system --help" omarchy-apply-system --help
    check "install/server/all.sh parses" bash -n /usr/share/omarchy/install/server/all.sh
    check "every install/server script parses" bash -c \
      "for f in /usr/share/omarchy/install/server/*.sh /usr/share/omarchy/install/server/addons/*.sh; do bash -n \"\$f\" || exit 1; done"
    check "apply-system routes the server profile" bash -c \
      "grep -q \"OMARCHY_INSTALL/server/all.sh\" /usr/bin/omarchy-apply-system"
    check "/etc/omarchy-profile says server" bash -c \
      "[[ \$(cat /etc/omarchy-profile) == server ]]"
    check "provides/conflicts recorded" bash -c \
      "pacman -Qi omarchy-server | grep -q \"Provides *: omarchy\" && pacman -Qi omarchy-server | grep -q \"Conflicts With *: omarchy\""
    check "limine cmdline has the serial console" bash -c \
      "grep -q \"console=ttyS0,115200 console=tty0\" /etc/limine-entry-tool.d/omarchy-defaults.conf"
    # grep -v "^#" everywhere below: the server files explain in comments what
    # they dropped, so a naive grep would match the explanation.
    check "limine cmdline has no quiet splash" bash -c \
      "! grep -v \"^#\" /etc/limine-entry-tool.d/omarchy-defaults.conf | grep -q \"quiet splash\""
    check "limine timeout is 2" bash -c \
      "grep -qx \"timeout: 2\" /usr/share/omarchy/default/limine/limine.conf"
    check "mkinitcpio hooks have no plymouth" bash -c \
      "! grep -v \"^#\" /etc/mkinitcpio.conf.d/omarchy_hooks.conf | grep -q plymouth"
    check "zram-size is ram / 2" bash -c \
      "grep -qx \"zram-size = ram / 2\" /usr/lib/systemd/zram-generator.conf.d/90-omarchy.conf"
    check "nsswitch has no mdns" bash -c \
      "! grep -v \"^#\" /etc/nsswitch.conf | grep -q mdns"
    check "os-release is the server one" bash -c \
      "grep -qx \"ID=omarchy-server\" /etc/os-release"

    echo
    echo "== [omarchy-server] repository wiring =="
    # What lets an installed machine reach its own packages: the repository
    # definition ships as a file under /etc/pacman.d, and every channel
    # template Includes it, so a channel switch (omarchy-refresh-pacman) or the
    # end of an ISO install (post-install-pacman-server.sh) keeps it enabled.
    check "the repository definition ships under /etc/pacman.d" bash -c \
      "grep -qx \"\\[omarchy-server\\]\" /etc/pacman.d/omarchy-server.conf && grep -qx \"SigLevel = Required DatabaseOptional\" /etc/pacman.d/omarchy-server.conf && grep -qx \"Server = https://github.com/edimarlnx/omarchy-server-pkgs/releases/download/repo\" /etc/pacman.d/omarchy-server.conf"
    check "every channel template includes it" bash -c \
      "for c in stable rc edge; do grep -qx \"Include = /etc/pacman.d/omarchy-server.conf\" /usr/share/omarchy/default/pacman/pacman-\$c.conf || exit 1; done"
    check "the definition is a backup= file" bash -c \
      "pacman -Qii omarchy-server-settings | grep -q \"etc/pacman.d/omarchy-server.conf\""
    # The container defines [omarchy-server] inline (file:///repo). The
    # scriptlet must leave pacman.conf alone: adding its Include would splice a
    # SECOND [omarchy-server] section in, pointing at GitHub, and pacman would
    # be reading a duplicate repository.
    check "the scriptlet does not duplicate an inline definition" bash -c \
      "(( \$(grep -c \"^\\[omarchy-server\\]\" /etc/pacman.conf) == 1 )) && ! grep -q \"^Include = /etc/pacman.d/omarchy-server.conf\" /etc/pacman.conf"
    check "omarchy-server-addon warns when the repo is missing" bash -c \
      "grep -q \"the \\[omarchy-server\\] repository is not configured\" /usr/share/omarchy/bin/omarchy-server-addon"

    echo
    echo "== identity =="
    check "os-release names the edition and the version" bash -c \
      "grep -qx \"NAME=\\\"Omarchy Server\\\"\" /etc/os-release && grep -qx \"PRETTY_NAME=\\\"Omarchy Server $pkg_pkgver\\\"\" /etc/os-release && grep -qx \"ANSI_COLOR=\\\"0;32\\\"\" /etc/os-release && grep -qx \"LOGO=omarchy\" /etc/os-release"
    check "limine.conf brands the menu" bash -c \
      "grep -qx \"interface_branding: Omarchy Server\" /usr/share/omarchy/default/limine/limine.conf"
    check "limine.conf points at the wallpaper on the ESP" bash -c \
      "grep -qx \"wallpaper: boot():/limine-wallpaper.png\" /usr/share/omarchy/default/limine/limine.conf"
    check "the wallpaper ships with the settings package" bash -c \
      "test -s /usr/share/omarchy/default/limine/limine-wallpaper.png"
    check "install/server copies the wallpaper to the ESP" bash -c \
      "grep -q limine-wallpaper.png /usr/share/omarchy/install/server/limine-branding-server.sh && grep -q \"server/limine-branding-server.sh\" /usr/share/omarchy/install/server/all.sh"
    check "/etc/issue carries the logo and the agetty fields" bash -c \
      "grep -q \"Omarchy Server\" /etc/issue && grep -qF \"S{VERSION_ID}\" /etc/issue && grep -qF \"ipv4\" /etc/issue && grep -qP \"\\x1b\\[32m\" /etc/issue && grep -q \"███\" /etc/issue"
    check "the serial console gets a logo-free issue" bash -c \
      "test -s /etc/issue.serial && ! grep -q \"███\" /etc/issue.serial && grep -q \"issue-file /etc/issue.serial\" \"/etc/systemd/system/serial-getty@.service.d/10-omarchy-issue.conf\""
    check "issue.net ships plain, with no escapes" bash -c \
      "test -s /etc/issue.net && ! grep -qP \"\\x1b\" /etc/issue.net"
    check "the VT palette unit and its command are installed" bash -c \
      "test -f /usr/lib/systemd/system/omarchy-tty-palette.service && test -L /usr/bin/omarchy-tty-palette && bash -n /usr/share/omarchy/bin/omarchy-tty-palette"
    check "the palette unit is enabled by the install" bash -c \
      "grep -q \"systemctl enable omarchy-tty-palette.service\" /usr/share/omarchy/install/server/enable-services-server.sh"
    check "the palette leaves the serial console alone" bash -c \
      "! grep -v \"^#\" /usr/share/omarchy/bin/omarchy-tty-palette | grep -q ttyS"
    check "the login banner is wired and renders" bash -c \
      "test -f /etc/profile.d/omarchy-motd.sh && test -L /usr/bin/omarchy-server-motd && omarchy-server-motd | grep -q \"Omarchy Server\""
    check "the banner reports the fields a server login needs" bash -c \
      "out=\$(omarchy-server-motd); for f in os host kernel uptime packages memory; do grep -q \"\$f\" <<<\"\$out\" || exit 1; done"
    check "fastfetch reads the logo from the runtime package" bash -c \
      "grep -q \"/usr/share/omarchy/logo.txt\" /etc/fastfetch/config.jsonc && test -s /usr/share/omarchy/logo.txt"
    check "agent skills shipped" test -d /usr/share/omarchy/default/agents/skills
    check "themes and shell are NOT shipped" bash -c \
      "! test -e /usr/share/omarchy/themes && ! test -e /usr/share/omarchy/shell"
    check "usr/bin entries are symlinks" bash -c \
      "test -L /usr/bin/omarchy-version && test -L /usr/bin/omarchy-update"
    check "migration stubs seeded in /etc/skel" bash -c \
      "(( \$(ls /etc/skel/.local/state/omarchy/migrations | wc -l) > 50 ))"
    check "update guard hook installed" test -f /usr/share/libalpm/hooks/00-omarchy-update-guard.hook
    check "hyprland reload hooks NOT installed" bash -c \
      "! ls /usr/share/libalpm/hooks/ | grep -q hyprland"
    check "omarchy-channel-current knows omarchy-server" bash -c \
      "grep -q omarchy-server-settings /usr/bin/omarchy-channel-current"

    echo
    echo "== lean base =="
    # The runtime depends are what a pacman install of omarchy-server drags in
    # unconditionally, so this is where the base stops being lean if a desktop
    # dependency creeps back.
    check "runtime does not depend on git/jq/perl/fakeroot" bash -c \
      "! pacman -Qi omarchy-server | sed -n \"/^Depends On/,/^Optional Deps/p\" | grep -qE \"(^| )(git|jq|perl|fakeroot)( |$)\""
    check "docker is not installed" bash -c "! pacman -Qq docker >/dev/null 2>&1"
    check "tailscale is not installed" bash -c "! pacman -Qq tailscale >/dev/null 2>&1"
    check "networkmanager is not installed" bash -c \
      "! pacman -Qq networkmanager >/dev/null 2>&1"
    check "no compiler in the closure" bash -c \
      "! pacman -Qq gcc >/dev/null 2>&1"
    # The docker drop-ins must NOT be in /etc: 20-docker-dns.conf makes
    # systemd-resolved open a listener on the docker bridge address.
    check "docker drop-ins are defaults, not /etc" bash -c \
      "test -f /usr/share/omarchy/default/docker/20-docker-dns.conf && ! test -e /etc/systemd/resolved.conf.d/20-docker-dns.conf && ! test -e /etc/docker/daemon.json"
    check "sshd hardening turns passwords off" bash -c \
      "grep -q \"PasswordAuthentication no\" /usr/share/omarchy/install/server/sshd-hardening-server.sh && grep -q \"PermitRootLogin no\" /usr/share/omarchy/install/server/sshd-hardening-server.sh"
    check "firewall rate-limits ssh" bash -c \
      "grep -v \"^#\" /usr/share/omarchy/install/server/firewall-server.sh | grep -q \"ufw limit 22/tcp\""
    check "firewall no longer installs docker rules" bash -c \
      "! grep -v \"^#\" /usr/share/omarchy/install/server/firewall-server.sh | grep -q ufw-docker"
    check "services enable networkd and resolved, not NetworkManager" bash -c \
      "grep -q \"systemctl enable systemd-networkd.service\" /usr/share/omarchy/install/server/enable-services-server.sh && ! grep -q \"systemctl enable NetworkManager.service\" /usr/share/omarchy/install/server/enable-services-server.sh"
    check "services no longer enable docker.socket" bash -c \
      "! grep -v \"^#\" /usr/share/omarchy/install/server/enable-services-server.sh | grep -q docker.socket"

    echo
    echo "== addons =="
    check "omarchy-server-addon is linked into /usr/bin" bash -c \
      "test -L /usr/bin/omarchy-server-addon"
    check "omarchy-server-addon --list names every addon" bash -c \
      "for a in cli-tools dev docker editor net-tools secureboot tailscale tui-firewall tui-systemd vm; do omarchy-server-addon --list | grep -qx \"\$a\" || exit 1; done"
    check "omarchy-server-addon --help does not touch the system" \
      omarchy-server-addon --help
    check "an unknown addon fails" bash -c \
      "! omarchy-server-addon definitely-not-an-addon"
    check "docker addon lists the docker packages" bash -c \
      "grep -qx docker /usr/share/omarchy/install/server/addons/docker.packages && grep -qx ufw-docker /usr/share/omarchy/install/server/addons/docker.packages"
    check "docker addon setup leaf ships with it" \
      test -f /usr/share/omarchy/install/server/addons/docker.sh
    echo
    echo "== secure boot =="
    check "the secureboot addon is sbctl and nothing else" bash -c \
      "[[ \$(grep -cv \"^#\\|^\$\" /usr/share/omarchy/install/server/addons/secureboot.packages) == 1 ]] && grep -qx sbctl /usr/share/omarchy/install/server/addons/secureboot.packages"
    check "sbctl is not in the base" bash -c \
      "! pacman -Qq sbctl >/dev/null 2>&1"
    check "the addon leaf runs the profile setup script" bash -c \
      "grep -q \"server/secureboot-server.sh\" /usr/share/omarchy/install/server/addons/secureboot.sh"
    check "the setup script adds the lockdown cmdline" bash -c \
      "grep -q \"lockdown=integrity module.sig_enforce=1\" /usr/share/omarchy/install/server/secureboot-server.sh && grep -q \"limine-entry-tool.d/omarchy-secureboot.conf\" /usr/share/omarchy/install/server/secureboot-server.sh"
    # The cmdline must be an addition, not a replacement: the drop-in has to
    # sort after omarchy-defaults.conf and use += .
    check "the cmdline drop-in appends rather than replaces" bash -c \
      "grep -q \"KERNEL_CMDLINE\\[default\\]+=\" /usr/share/omarchy/install/server/secureboot-server.sh && [[ omarchy-secureboot.conf > omarchy-defaults.conf ]]"
    check "the base ships no secure boot cmdline" bash -c \
      "! test -e /etc/limine-entry-tool.d/omarchy-secureboot.conf"
    check "omarchy-server-secureboot is linked into /usr/bin and parses" bash -c \
      "test -L /usr/bin/omarchy-server-secureboot && bash -n /usr/share/omarchy/bin/omarchy-server-secureboot"
    check "omarchy-server-secureboot --help does not touch the system" \
      omarchy-server-secureboot --help
    check "the tui-* tools are addons, not part of the base" bash -c \
      "grep -qx tui-firewall /usr/share/omarchy/install/server/addons/tui-firewall.packages && grep -qx tui-systemd /usr/share/omarchy/install/server/addons/tui-systemd.packages && ! pacman -Qq tui-firewall >/dev/null 2>&1 && ! pacman -Qq tui-systemd >/dev/null 2>&1"

    echo
    echo "== tui-firewall =="
    # Installed here rather than through omarchy-server-addon, which would need
    # sudo and a real firewall; what is being checked is the package.
    pacman -S --noconfirm tui-firewall >/dev/null
    check "tui-firewall installs a static binary" bash -c \
      "test -x /usr/bin/tui-firewall && ! ldd /usr/bin/tui-firewall 2>&1 | grep -q libc.so"
    check "tui-firewall --version reports the packaged version" bash -c \
      "tui-firewall --version | grep -q 0.1.0"
    check "tui-firewall ships a ufw-pinned configuration" bash -c \
      "grep -qx \"backend = \\\"ufw\\\"\" /etc/tui-firewall/config.toml"
    # The README is read out of the package file, not the filesystem: the
    # archlinux container image carries NoExtract = usr/share/doc/* .
    check "tui-firewall ships its licence and README" bash -c \
      "test -s /usr/share/licenses/tui-firewall/LICENSE && bsdtar -tf /repo/tui-firewall-*.pkg.tar.zst | grep -qx usr/share/doc/tui-firewall/README.md"
    # The tool was called fwall until it moved to the tui-tools organization.
    # A machine that installed the old name has to take this package as an
    # upgrade rather than a second copy of the same binary.
    check "tui-firewall replaces the old fwall package" bash -c \
      "pacman -Qi tui-firewall | grep -q \"^Replaces .*fwall\" && pacman -Qi tui-firewall | grep -q \"^Provides .*fwall\""
    pacman -Rns --noconfirm tui-firewall >/dev/null

    echo
    echo "== tui-systemd =="
    pacman -S --noconfirm tui-systemd >/dev/null
    check "tui-systemd installs a static binary" bash -c \
      "test -x /usr/bin/tui-systemd && ! ldd /usr/bin/tui-systemd 2>&1 | grep -q libc.so"
    check "tui-systemd --version reports the packaged version" bash -c \
      "tui-systemd --version | grep -q 0.1.0"
    check "tui-systemd ships the machine-wide configuration it reads" bash -c \
      "grep -q \"^sudo = \" /etc/tui-systemd/config.toml"
    check "tui-systemd ships its licence and README" bash -c \
      "test -s /usr/share/licenses/tui-systemd/LICENSE && bsdtar -tf /repo/tui-systemd-*.pkg.tar.zst | grep -qx usr/share/doc/tui-systemd/README.md"
    pacman -Rns --noconfirm tui-systemd >/dev/null

    echo
    echo "== measurements =="
    printf "packages installed: %s\n" "$(pacman -Qq | wc -l)"
    pacman -S --noconfirm --needed expac >/dev/null 2>&1
    printf "total installed size: %s MiB\n" \
      "$(expac -Q "%m" $(pacman -Qq) | awk "{ s += \$1 } END { printf \"%.0f\", s / 1048576 }")"
    echo
    printf "%-28s %10s\n" package "installed"
    expac -Q "%-28n %10m" omarchy-server omarchy-server-settings omarchy-server-keyring

    echo
    if (( fail )); then
      echo "RESULT: FAILED"
      exit 1
    fi
    echo "RESULT: OK"
  '
