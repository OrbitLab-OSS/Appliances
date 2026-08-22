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
sudo chroot mnt apt install -y jq

# Install tools
sudo install -Dm755 etcd-mgr.sh mnt/usr/bin/etcd-mgr
sudo install -Dm755 etcd-init.sh mnt/usr/bin/etcd-init
sudo install -Dm755 etcd mnt/usr/bin
sudo install -Dm755 etcdctl mnt/usr/bin
sudo install -Dm755 etcdutl mnt/usr/bin
sudo cp etcd.service mnt/usr/lib/systemd/system
sudo cp etcd-bootstrap.service mnt/usr/lib/systemd/system
sudo chroot mnt systemctl enable etcd-bootstrap
sudo chroot mnt systemctl enable etcd

cleanup
sudo tar --numeric-owner -czf "orbitlab-etcd-${version}.tar.gz" -C mnt .
