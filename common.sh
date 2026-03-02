#!/bin/bash

# Common functions and prep commands used across all appliance builds
cleanup() {
    if mountpoint "$CHROOT/mnt/proc"; then
        sudo umount "$CHROOT/mnt/proc"
    fi
    if mountpoint "$CHROOT/mnt/sys"; then
        sudo umount "$CHROOT/mnt/sys"
    fi
    if mountpoint "$CHROOT/mnt/dev"; then
        sudo umount "$CHROOT/mnt/dev"
    fi
    sudo rm -f "$CHROOT/mnt/etc/resolv.conf"
}

if [ "${CHROOT:-'unset'}" == "unset" ]; then
    echo "CHROOT was not provided."
    exit 1
fi
version="${VERSION:-dev}"
sudo apt install -y debootstrap
trap "cleanup" EXIT INT TERM
set -o xtrace
mkdir "$CHROOT/mnt"
sudo debootstrap --variant=minbase trixie "$CHROOT/mnt" http://deb.debian.org/debian
sudo cp /etc/resolv.conf "$CHROOT/mnt/etc/resolv.conf"
sudo mount --bind /proc "$CHROOT/mnt/proc"
sudo mount --bind /sys  "$CHROOT/mnt/sys"
sudo mount --bind /dev  "$CHROOT/mnt/dev"
sudo chroot "$CHROOT/mnt" apt update -y
sudo chroot "$CHROOT/mnt" apt upgrade -y
sudo chroot "$CHROOT/mnt" apt install -y systemd-sysv ifupdown iproute2 dnsutils python3 netbase procps \
    ca-certificates iputils-ping net-tools ipcalc curl
