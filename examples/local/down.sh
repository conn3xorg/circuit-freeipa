#!/usr/bin/env sh
# Removes the containers and everything up.sh and Conn3x created here.
set -eu
cd "$(dirname "$0")"
for role in server client; do
  ${PODMAN:-podman} rm -f -v "${NAME:-circuit-freeipa}-$role" >/dev/null 2>&1 || true
done
rm -rf ips.auto.tfvars id_ed25519 id_ed25519.pub known_hosts .terraform .terraform.lock.hcl terraform.tfstate terraform.tfstate.backup
echo "Removed."
