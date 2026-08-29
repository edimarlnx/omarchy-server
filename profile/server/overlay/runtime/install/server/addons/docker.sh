# Setup leaf for the `docker` addon, sourced by omarchy-server-addon after the
# packages are installed.
#
# The three drop-ins below ship with omarchy-server-settings under
# default/docker/ instead of /etc, precisely because they must not exist on a
# machine without Docker: 20-docker-dns.conf makes systemd-resolved open an
# extra DNS listener on the bridge address, which on a base install would be a
# listening socket nothing uses.

install -Dm644 "$OMARCHY_PATH/default/docker/daemon.json" \
  /etc/docker/daemon.json
install -Dm644 "$OMARCHY_PATH/default/docker/20-docker-dns.conf" \
  /etc/systemd/resolved.conf.d/20-docker-dns.conf
install -Dm644 "$OMARCHY_PATH/default/docker/no-block-boot.conf" \
  /etc/systemd/system/docker.service.d/no-block-boot.conf

# Let containers reach the resolved stub on the bridge address, matching
# daemon.json's "dns": ["172.17.0.1"].
#
# `|| true`, and the check on user.rules afterwards, because of where this runs
# during an ISO install: install/server/firewall-server.sh has already written
# ENABLED=yes, so ufw believes it is enabled and tries to load the rule into a
# kernel firewall the chroot does not own, printing "ERROR: problem running"
# and exiting non-zero. It writes the rule to user.rules first, and that file is
# what ufw.service loads on the first boot, so the exit status is the wrong
# thing to check here. The orchestrator's configure_ssh_access phase handles its
# own rule exactly this way.
ufw allow in proto udp from 172.16.0.0/12 to 172.17.0.1 port 53 comment 'allow-docker-dns' || true
ufw allow in proto udp from 192.168.0.0/16 to 172.17.0.1 port 53 comment 'allow-docker-dns' || true

# `exit`, not `return`: leaves under install/ avoid exiting because they are
# sourced by the system setup, but this one is sourced by omarchy-server-addon
# and aborting the addon is exactly what should happen here.
# Matched on the rule itself, not on the comment: ufw stores comments
# hex-encoded in user.rules.
if ! grep -q -- '-d 172.17.0.1 --dport 53' /etc/ufw/user.rules; then
  echo "docker addon: ufw did not record the container DNS rules" >&2
  exit 1
fi

# ufw-docker refuses to write its after.rules block unless UFW reports itself
# active, which it is not while the ISO install runs in a chroot sharing the
# live installer's kernel firewall. Satisfy the preflight with a status shim
# and leave the live firewall untouched; on an installed machine UFW is already
# active and the shim changes nothing.
install_ufw_docker_rules() {
  local shim_dir status ufw_docker_bin

  ufw_docker_bin=$(command -v ufw-docker)
  shim_dir=$(mktemp -d)
  cat >"$shim_dir/ufw" <<'EOF'
#!/bin/bash
if [[ ${1:-} == "status" ]]; then
  echo "Status: active"
  exit 0
fi

exec /usr/bin/ufw "$@"
EOF

  # The packaged ufw-docker pins PATH internally, so run a temporary copy whose
  # PATH can see the status shim above.
  sed "0,/^PATH=/s#^PATH=.*#PATH=\"$shim_dir:/bin:/usr/bin:/sbin:/usr/sbin:/snap/bin/\"#" \
    "$ufw_docker_bin" >"$shim_dir/ufw-docker"
  chmod 755 "$shim_dir/ufw" "$shim_dir/ufw-docker"

  if "$shim_dir/ufw-docker" install; then
    status=0
  else
    status=$?
  fi

  rm -rf "$shim_dir"
  return "$status"
}

# Same reasoning as the rules above: what matters is that the block reached
# after.rules, not whether ufw could load it into the running kernel.
install_ufw_docker_rules || true

if ! grep -q 'UFW AND DOCKER' /etc/ufw/after.rules; then
  echo "docker addon: ufw-docker did not write its after.rules block" >&2
  exit 1
fi

# docker.socket, not docker.service: the daemon starts on the first client
# connection instead of at every boot.
systemctl enable docker.socket

# Only when there is a running init to talk to. During an ISO install the next
# step is a reboot, and `enable` above is what makes it come up then.
if [[ -d /run/systemd/system ]]; then
  systemctl daemon-reload
  systemctl restart systemd-resolved.service
  systemctl start docker.socket
  ufw reload
fi
