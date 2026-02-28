#!/bin/bash

set -eou pipefail

# Prep
rm -f orbitlab-backplane-dns-*.tar.gz

# Runs setup commands
source "$CHROOT/common.sh"

# Make necessary directories
sudo mkdir "$CHROOT/mnt/etc/coredns" 

# Install custom files
sudo install -Dm755 "$CHROOT/backplane_dns/coredns" "$CHROOT/mnt/usr/bin/coredns"
sudo install -Dm755 "$CHROOT/backplane_dns/obd-tool.sh" "$CHROOT/mnt/usr/bin/obd-tool"
sudo cp "$CHROOT/backplane_dns/coredns.service" "$CHROOT/mnt/usr/lib/systemd/system"
sudo chroot "$CHROOT/mnt" systemctl enable coredns

cleanup
sudo tar --numeric-owner -czf "orbitlab-backplane-dns-${version}.tar.gz" -C "$CHROOT/mnt" .
