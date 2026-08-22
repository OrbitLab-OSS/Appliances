#!/bin/bash

set -eou pipefail

version="${VERSION:-dev}"

# Runs setup commands
# shellcheck source=common.sh
source ../common.sh
mkdir mnt
sudo tar -xzf ../debian13-root.tar.gz -C mnt
initRoot

# Install pacakges
sudo chroot mnt apt install -y python3.13

# Make necessary directories
sudo mkdir mnt/etc/coredns

# Install custom files
sudo install -Dm755 ../coredns/coredns mnt/usr/bin/coredns
sudo install -Dm755 backplane-init.sh mnt/usr/bin/backplane-init
sudo install -Dm755 orbital-relay.pex mnt/usr/bin/orbital-relay
sudo cp coredns.service mnt/usr/lib/systemd/system
sudo cp orbital-relay.service mnt/usr/lib/systemd/system
sudo chroot mnt systemctl enable coredns

cleanup
sudo tar --numeric-owner -czf "orbitlab-backplane-${version}.tar.gz" -C mnt .
