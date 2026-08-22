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
sudo chroot mnt apt install -y wireguard nftables etcd-client ipcalc

# Make necessary directories
sudo mkdir -p mnt/etc/wireguard

# Install custom files
sudo install -Dm755 wardlink.sh mnt/usr/bin/wardlink
sudo cp wardlink.service mnt/usr/lib/systemd/system
sudo chroot mnt systemctl enable wardlink
sudo rm -f mnt/etc/dhcpcd.conf
sudo cp dhcpcd.conf mnt/etc/dhcpcd.conf
sudo cp orbitlab.network mnt/etc/systemd/network/orbitlab.network

cleanup
sudo tar --numeric-owner -czf "orbitlab-wardlink-${version}.tar.gz" -C mnt .
