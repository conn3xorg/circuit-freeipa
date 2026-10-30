#!/usr/bin/env sh
# Starts two throwaway hosts that Conn3x can configure: a FreeIPA server on
# 127.0.0.1:$PORT (default 2222) and a client on the port after it, with a
# fresh SSH key and their host keys in ./known_hosts. CONTAINERFILE picks
# another image for both, such as one of Conn3x's test images, and
# CLIENT_CONTAINERFILE another for the client alone.
# Needs Podman, since the hosts run systemd. FreeIPA runs a directory
# server, a KDC and a CA under systemd, so the containers are privileged.
# Rootful Podman is simplest: CONTAINER_CONNECTION=podman-machine-default-root
# on a Mac, or PODMAN="sudo podman" on Linux.
# The containers keep their own /etc/hosts and /etc/hostname, which the
# circuit edits; Podman's would be mounted over them. Their addresses go in
# ips.auto.tfvars, since the images have no ip command for Conn3x to find
# them with.
set -eu
cd "$(dirname "$0")"
: > ips.auto.tfvars
port=${PORT:-2222}
containerfile=${CONTAINERFILE:-Containerfile}
client_containerfile=${CLIENT_CONTAINERFILE:-$containerfile}
name=${NAME:-circuit-freeipa}

podman=${PODMAN:-podman}
[ -f id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C "$name" -f id_ed25519
: > known_hosts
for role in server client; do
  if [ "$role" = server ]; then file=$containerfile; p=$port; else file=$client_containerfile; p=$((port + 1)); fi
  $podman build -q -f "$file" -t "$name-$role" "$(dirname "$file")" >/dev/null
  $podman rm -f -v "$name-$role" >/dev/null 2>&1 || true
  $podman run -d --name "$name-$role" --systemd=always --privileged --no-hosts --no-hostname \
    -p "127.0.0.1:$p:22" "$name-$role" >/dev/null
  $podman exec -i "$name-$role" sh -c 'cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys' < id_ed25519.pub
  $podman exec "$name-$role" timeout 60 systemctl is-system-running --wait >/dev/null 2>&1 || true
  # Two containers from one image share its machine ID, and udev on some
  # images derives eth0's MAC address from it, so both get the same one and
  # can't reach each other. Keep the address Podman assigned, from the next
  # boot on.
  $podman exec "$name-$role" sh -c 'mkdir -p /etc/systemd/network && printf "[Match]\nOriginalName=*\n\n[Link]\nMACAddressPolicy=none\n" > /etc/systemd/network/99-default.link'
  $podman restart "$name-$role" >/dev/null
  $podman exec "$name-$role" timeout 60 systemctl is-system-running --wait >/dev/null 2>&1 || true

  echo "${role}_ip = \"$($podman inspect -f '{{.NetworkSettings.IPAddress}}' "$name-$role")\"" >> ips.auto.tfvars

  ok=
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ssh-keyscan -p "$p" 127.0.0.1 > known_hosts.part 2>/dev/null && [ -s known_hosts.part ]; then
      cat known_hosts.part >> known_hosts && ok=1 && break
    fi
    sleep 1
  done
  rm -f known_hosts.part
  if [ -z "$ok" ]; then
    echo "The $role container started, but SSH didn't answer on 127.0.0.1:$p." >&2
    exit 1
  fi
done
echo "Ready on 127.0.0.1:$port and :$((port + 1)). Now run: conn3x init && conn3x apply -var port=$port"
