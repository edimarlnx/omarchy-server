# Router console identity. Keeps the Omarchy identity the server profile
# established (same wordmark, same palette, same os-release) and adds the one
# fact a person at the console needs to know first: this machine is a router.
#
# Two touch points, both cheap:
#   - /etc/issue.net, shown at the login prompt before authentication. The
#     server profile ships "Omarchy Server"; the router says so too and adds
#     "Router" on the same line, so a mistyped ssh target is obvious.
#   - /etc/omarchy-profile already says "router" (the ISO writes it, and it is
#     what omarchy-apply-system routed on). omarchy-server-motd reads it and
#     labels the login banner accordingly, so no file is written for that here.
#
# issue.net is owned by omarchy-server-settings as "Omarchy Server". Rewriting
# it at install is a configuration step, the same kind the server profile's own
# leaves make; the package file is the fallback if this never runs.

cat >/etc/issue.net <<'EOF'
Omarchy Server — Router
Authorized use only. All activity may be logged.
EOF
chmod 0644 /etc/issue.net
