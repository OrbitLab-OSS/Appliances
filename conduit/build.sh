#!/bin/bash

set -eou pipefail

version="${VERSION:-dev}"

# Runs setup commands
# shellcheck source=common.sh
source ../common.sh
mkdir -p mnt
sudo tar -xzf ../debian13-root.tar.gz -C mnt
initRoot

# Install packages
sudo chroot mnt apt install -y jq etcd-client

# Make necessary directories
sudo mkdir -p mnt/etc/traefik
sudo mkdir -p mnt/etc/default
sudo mkdir -p mnt/var/log/traefik
sudo mkdir -p mnt/var/lib/traefik

# Install tools
sudo install -Dm755 conduit.sh mnt/usr/bin/conduit
sudo install -Dm755 conduit-telemetry.sh mnt/usr/bin/conduit-telemetry
sudo install -Dm755 traefik mnt/usr/bin/traefik
sudo install -Dm0644 /dev/null mnt/etc/default/conduit
sudo cp conduit.service mnt/usr/lib/systemd/system
sudo cp conduit-acme-sync.service mnt/usr/lib/systemd/system
sudo cp conduit-telemetry.service mnt/usr/lib/systemd/system
sudo chroot mnt systemctl enable conduit
sudo chroot mnt systemctl enable conduit-acme-sync
sudo chroot mnt systemctl enable conduit-telemetry
sudo rm -f mnt/etc/dhcpcd.conf
sudo cp dhcpcd.conf mnt/etc/dhcpcd.conf
sudo cp orbitlab.network mnt/etc/systemd/network/orbitlab.network

cleanup
sudo tar --numeric-owner -czf "orbitlab-conduit-${version}.tar.gz" -C mnt .
