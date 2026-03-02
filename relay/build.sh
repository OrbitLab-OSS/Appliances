#!/bin/bash

set -eou pipefail

# Prep
rm -f orbitlab-relay-*.tar.gz

# Runs setup commands
source "$CHROOT/common.sh"

# Install pacakges
sudo chroot "$CHROOT/mnt" apt install -y python3.13

# Install custom files
sudo install -Dm755 "$CHROOT/relay/orbital-relay.pex" "$CHROOT/mnt/usr/bin/orbital-relay"
sudo cp "$CHROOT/relay/orbital-relay.service" "$CHROOT/mnt/usr/lib/systemd/system"

cleanup
sudo tar --numeric-owner -czf "orbitlab-relay-${version}.tar.gz" -C "$CHROOT/mnt" .
