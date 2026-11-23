#!/bin/bash
# OmaCachy overlay: firewall setup that tolerates a CachyOS base.
#
# Upstream assumes ufw and ufw-docker are installed (they are in Omarchy's
# package set) and that ufw-docker's helper exists. Keep the same policy, but
# never abort the install when a piece is absent.

if ! command -v ufw >/dev/null 2>&1; then
  echo "OmaCachy: ufw is not installed, skipping firewall policy"
  exit 0
fi

ufw default deny incoming
ufw default allow outgoing

# LocalSend
ufw allow 53317/udp
ufw allow 53317/tcp

# Docker DNS
ufw allow in proto udp from 172.16.0.0/12 to 172.17.0.1 port 53 comment 'allow-docker-dns'
ufw allow in proto udp from 192.168.0.0/16 to 172.17.0.1 port 53 comment 'allow-docker-dns'

install_ufw_docker_rules() {
  local shim_dir status ufw_docker_bin

  ufw_docker_bin=$(command -v ufw-docker) || return 0
  shim_dir=$(mktemp -d)
  cat >"$shim_dir/ufw" <<'EOF'
#!/bin/bash
if [[ ${1:-} == "status" ]]; then
  echo "Status: active"
  exit 0
fi

exec /usr/bin/ufw "$@"
EOF

  sed "0,/^PATH=/s#^PATH=.*#PATH=\"$shim_dir:/bin:/usr/bin:/sbin:/usr/sbin\"#" \
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

install_ufw_docker_rules || echo "OmaCachy: ufw-docker rules could not be installed, continuing"

sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf
systemctl enable ufw
