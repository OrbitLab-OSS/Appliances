#!/bin/bash

set -eou pipefail

# Prep
rm -f orbitlab-gateway-*.tar.gz
declare -a SERVICES=(nftables frr dnsmasq)

# Runs setup commands
source "$CHROOT/common.sh"

# Install pacakges
sudo chroot "$CHROOT/mnt" apt install -y frr nftables dnsmasq 

# Make necessary directories
sudo mkdir "$CHROOT/mnt/etc/coredns"
sudo mkdir "$CHROOT/mnt/var/local/dnsmasq"
sudo mkdir "$CHROOT/mnt/etc/systemd/system-preset"

# Install custom files
sudo install -Dm755 "$CHROOT/gateway/sgwtool.sh" "$CHROOT/mnt/usr/bin/sgwtool"
sudo install -Dm755 "$CHROOT/gateway/coredns" "$CHROOT/mnt/usr/bin/coredns"
sudo install -Dm755 "$CHROOT/gateway/dhcp-to-hosts.sh" "$CHROOT/mnt/var/local/dnsmasq"
sudo cp "$CHROOT/gateway/sector-gateway.service" "$CHROOT/mnt/usr/lib/systemd/system"
sudo cp "$CHROOT/gateway/coredns.service" "$CHROOT/mnt/usr/lib/systemd/system"
# Add systemd preset to disable systemd-networkd-wait-online.service
# Proxmox uses ifupdown2 and /etc/network/interfaces and not systemd for LXC and 
# dnsmasq hangs waiting for network-online.target which is waiting for systemd-networkd-wait-online.service
sudo cp "$CHROOT/gateway/01-orbitlab.preset" "$CHROOT/mnt/etc/systemd/system-preset/01-orbitlab.preset"

# Delete default configs so we can initialize them later
sudo rm -f "$CHROOT/mnt/etc/nftables.conf"
sudo rm -f "$CHROOT/mnt/etc/frr/frr.conf"
sudo rm -f "$CHROOT/mnt/etc/dnsmasq.conf"

# Add necessary service file overrides
for service in "${SERVICES[@]}"; do
    sudo mkdir "$CHROOT/mnt/etc/systemd/system/$service.service.d"
    sudo cp "$CHROOT/gateway/orbitlab.conf" "$CHROOT/mnt/etc/systemd/system/$service.service.d"
done

cleanup
sudo tar --numeric-owner -czf "orbitlab-gateway-${version}.tar.gz" -C "$CHROOT/mnt" .
