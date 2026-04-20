#!/bin/bash

set -eou pipefail

# Prep
rm -f orbitlab-backplane-dns-*.tar.gz

# Runs setup commands
source "$CHROOT/common.sh"

# Install pacakges
sudo chroot "$CHROOT/mnt" apt install -y python3.13

# Make necessary directories
sudo mkdir "$CHROOT/mnt/etc/coredns" 

# Install custom files
sudo install -Dm755 "$CHROOT/coredns/coredns" "$CHROOT/mnt/usr/bin/coredns"
sudo install -Dm755 "$CHROOT/backplane-dns/backplane-init.sh" "$CHROOT/mnt/usr/bin/backplane-init"
sudo install -Dm755 "$CHROOT/backplane-dns/orbital-relay.pex" "$CHROOT/mnt/usr/bin/orbital-relay"
sudo cp "$CHROOT/backplane-dns/coredns.service" "$CHROOT/mnt/usr/lib/systemd/system"
sudo cp "$CHROOT/backplane-dns/orbital-relay.service" "$CHROOT/mnt/usr/lib/systemd/system"
sudo chroot "$CHROOT/mnt" systemctl enable coredns

cleanup
sudo tar --numeric-owner -czf "orbitlab-backplane-dns-${version}.tar.gz" -C "$CHROOT/mnt" .
