# Print the Omarchy Server banner once per login shell.
#
# Upstream wires no MOTD at all: on the desktop the identity comes from the
# session, and fastfetch is something the user runs by hand. A headless machine
# has only the console and ssh, so the banner is what tells you where you just
# landed -- and it is the one place the edition can identify itself after the
# bootloader and the login prompt are gone.
#
# The work is in omarchy-server-motd, which prefers fastfetch when the
# `cli-tools` addon put it there and otherwise renders the same fields itself.
# This file only decides whether now is the moment to print.

# Interactive shells attached to a terminal only: `ssh host command`, scp and
# sftp never reach here, and a cron or systemd shell has no reader.
case $- in *i*) ;; *) return ;; esac
[ -t 1 ] || return

# A login shell inside a login shell (`sudo -i`, `su -l`, a nested `bash -l`)
# would print the banner again. Mark the environment on the first one.
[ -n "${OMARCHY_MOTD_SHOWN:-}" ] && return
OMARCHY_MOTD_SHOWN=1
export OMARCHY_MOTD_SHOWN

command -v omarchy-server-motd >/dev/null 2>&1 && omarchy-server-motd
