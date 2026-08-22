#!/bin/bash

set -eou pipefail

version="${VERSION:-dev}"

# Prep
declare -a SERVICES=(nftables frr dnsmasq)

# Runs setup commands
# shellcheck source=common.sh
source ../common.sh
mkdir mnt
sudo tar -xzf ../debian13-root.tar.gz -C mnt
initRoot

# Install pacakges
sudo chroot mnt apt install -y frr nftables dnsmasq etcd-client

# Make necessary directories
sudo mkdir mnt/etc/coredns
sudo mkdir mnt/var/local/dnsmasq
sudo mkdir mnt/etc/systemd/system-preset

# Install custom files
sudo install -Dm755 gateway-init.sh mnt/usr/bin/gateway-init
sudo install -Dm755 ../coredns/coredns mnt/usr/bin/coredns
sudo install -Dm755 relay.sh mnt/var/local/dnsmasq
sudo cp sector-gateway.service mnt/usr/lib/systemd/system
sudo cp coredns.service mnt/usr/lib/systemd/system
# Add systemd preset to disable systemd-networkd-wait-online.service
# Proxmox uses ifupdown2 and /etc/network/interfaces and not systemd for LXC and 
# dnsmasq hangs waiting for network-online.target which is waiting for systemd-networkd-wait-online.service
sudo cp 01-orbitlab.preset mnt/etc/systemd/system-preset/01-orbitlab.preset

# Delete default configs so we can initialize them later
sudo rm -f mnt/etc/nftables.conf
sudo rm -f mnt/etc/frr/frr.conf
sudo rm -f mnt/etc/dnsmasq.conf

# Add necessary service file overrides
for service in "${SERVICES[@]}"; do
    sudo mkdir "mnt/etc/systemd/system/$service.service.d"
    sudo cp orbitlab.conf "mnt/etc/systemd/system/$service.service.d"
done

cleanup
sudo tar --numeric-owner -czf "orbitlab-gateway-${version}.tar.gz" -C mnt .
