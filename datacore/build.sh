#!/bin/bash

set -eou pipefail

# Prep
rm -f orbitlab-datacore-*.tar.gz

# Runs setup commands
source "$CHROOT/common.sh"

# Install pacakges
sudo chroot "$CHROOT/mnt" apt install -y jq postgresql postgresql-17 keepalived patroni python3-etcd etcd-client

# Make necessary directories
sudo mkdir "$CHROOT/mnt/etc/datacore"
sudo mkdir "$CHROOT/mnt/etc/systemd/system/postgresql.service.d"

# Install tools
sudo install -Dm755 "$CHROOT/datacore/datacore.sh" "$CHROOT/mnt/usr/bin/datacore"
sudo cp "$CHROOT/datacore/provision_application_db.sql" "$CHROOT/mnt/etc/datacore"
sudo cp "$CHROOT/datacore/datacore.service" "$CHROOT/mnt/usr/lib/systemd/system"
sudo cp "$CHROOT/datacore/patroni.service" "$CHROOT/mnt/usr/lib/systemd/system"
sudo cp "$CHROOT/datacore/datacore.conf" "$CHROOT/mnt/etc/systemd/system/postgresql.service.d/"
sudo rm -rf "$CHROOT/mnt/var/lib/postgresql/17/main/*"

cleanup
sudo tar --numeric-owner -czf "orbitlab-datacore-${version}.tar.gz" -C "$CHROOT/mnt" .
