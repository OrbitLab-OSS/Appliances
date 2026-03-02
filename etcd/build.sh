#!/bin/bash

set -eou pipefail

# Prep
rm -f orbitlab-etcd-*.tar.gz

# Runs setup commands
source "$CHROOT/common.sh"

# Install tools
sudo install -Dm755 "$CHROOT/etcd/etcd-mgr.sh" "$CHROOT/mnt/usr/bin/etcd-mgr"
sudo install -Dm755 "$CHROOT/etcd/etcd" "$CHROOT/mnt/usr/bin/etcd"
sudo install -Dm755 "$CHROOT/etcd/etcdctl" "$CHROOT/mnt/usr/bin/etcdctl"
sudo install -Dm755 "$CHROOT/etcd/etcdutl" "$CHROOT/mnt/usr/bin/etcdutl"
sudo cp "$CHROOT/etcd/etcd-bootstrap.service" "$CHROOT/mnt/usr/lib/systemd/system"

cleanup
sudo tar --numeric-owner -czf "orbitlab-etcd-${version}.tar.gz" -C "$CHROOT/mnt" .
