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

# containerd's plugin directory, created here rather than by containerd.
#
# containerd makes /opt/containerd/{bin,lib} the first time it starts. /opt is
# usr_t, and under SELinux that means the daemon is refused:
#
#   comm="containerd" name="containerd" tclass=dir { create add_name }
#     scontext=system_u:system_r:dockerd_t tcontext=system_u:object_r:usr_t
#
# The policy fix would be `allow dockerd_t usr_t:dir { create add_name }` --
# a container runtime with write access to /opt, /usr/share and everything else
# usr_t covers, so that it can make two directories it knows the name of.
# Creating them at install time instead means the runtime only ever works
# INSIDE a directory that already exists and already carries the right label
# (install/server/mac/selinux/local-fcontexts gives it container_var_lib_t).
#
# Harmless without SELinux: containerd would have created exactly these.
install -dm755 /opt/containerd/bin /opt/containerd/lib

# And the labels on everything this leaf just wrote. The pacman hook relabels
# files a PACKAGE installed; nothing relabels files an addon installed, so
# /etc/docker comes out with the etc_t it inherited from /etc while the policy
# says container_config_t. Measured as label drift after the addon, which is
# the check this profile's acceptance runs; it is also a real difference,
# because container_config_t is what the runtime's own rules are written
# against.
#
# Skipped in the ISO install chroot, where SELinux is not active and there is
# nothing to read a context from. Nothing is lost there: the addon phase leaves
# /.autorelabel behind and omarchy-server-selinux-relabel.service covers the
# whole filesystem on the first boot.
if [[ -d /sys/fs/selinux ]] && command -v restorecon >/dev/null; then
  restorecon -RF /opt/containerd /etc/docker \
    /etc/systemd/resolved.conf.d /etc/systemd/system/docker.service.d
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
