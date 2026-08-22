#!/bin/bash

set -eou pipefail

version="${VERSION:-dev}"

# Runs setup commands
# shellcheck source=common.sh
source ../common.sh
mkdir -p mnt
sudo tar -xzf ../debian13-root.tar.gz -C mnt
initRoot

# Install pacakges
sudo chroot mnt apt install -y jq postgresql postgresql-17 keepalived patroni python3-etcd etcd-client

# Make necessary directories
sudo mkdir mnt/etc/datacore
sudo mkdir mnt/etc/systemd/system/postgresql.service.d

# Install tools
sudo install -Dm755 datacore.sh mnt/usr/bin/datacore
sudo cp datacore.service mnt/usr/lib/systemd/system
sudo cp patroni.service mnt/usr/lib/systemd/system
sudo cp datacore.conf mnt/etc/systemd/system/postgresql.service.d/
if sudo chroot mnt pg_lsclusters --no-header | awk '{print $1 " " $2}' | grep -Fxq "17 main"; then
    sudo chroot mnt pg_dropcluster --stop 17 main
fi
if ! sudo grep -Fxq 'export PATRONICTL_CONFIG_FILE=/etc/datacore/patroni.yaml' mnt/root/.bashrc; then
    echo 'export PATRONICTL_CONFIG_FILE=/etc/datacore/patroni.yaml' | sudo tee -a mnt/root/.bashrc > /dev/null
fi
sudo chroot mnt systemctl enable datacore
sudo chroot mnt systemctl disable postgresql@
sudo chroot mnt systemctl mask postgresql@

cleanup
sudo tar --numeric-owner -czf "orbitlab-datacore-${version}.tar.gz" -C mnt .
