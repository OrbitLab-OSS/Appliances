#!/bin/bash

# Common functions and prep commands used across all appliance builds
cleanup() {
    if mountpoint mnt/proc; then
        sudo umount mnt/proc
    fi
    if mountpoint mnt/sys; then
        sudo umount mnt/sys
    fi
    if mountpoint mnt/dev; then
        sudo umount mnt/dev
    fi
    sudo rm -f mnt/etc/resolv.conf
}

initRoot() {
    trap "cleanup" EXIT INT TERM
    set -o xtrace
    sudo cp /etc/resolv.conf mnt/etc/resolv.conf
    sudo mount --bind /proc mnt/proc
    sudo mount --bind /sys mnt/sys
    sudo mount --bind /dev mnt/dev
}

buildCommonRoot() {
    sudo apt install -y debootstrap
    trap "cleanup" EXIT INT TERM
    set -o xtrace
    mkdir mnt
    sudo debootstrap --variant=minbase trixie mnt http://deb.debian.org/debian
    initRoot
    sudo chroot mnt apt update -y
    sudo chroot mnt apt upgrade -y
    sudo chroot mnt apt install -y systemd-sysv ifupdown iproute2 dnsutils python3 netbase procps \
        ca-certificates iputils-ping net-tools ipcalc curl
    cleanup
    sudo tar --numeric-owner -czf "debian13-root.tar.gz" -C mnt .
}
