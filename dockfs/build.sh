#!/bin/bash

set -eou pipefail

version="${VERSION:-dev}"

cleanup() {
    [ -z "$CONNECTED" ] && return 0
    if mountpoint mnt/dev; then
        sudo umount mnt/dev
    fi
    if mountpoint mnt/proc; then
        sudo umount mnt/proc
    fi
    if mountpoint mnt/sys; then
        sudo umount mnt/sys
    fi
    if mountpoint mnt/run; then
        sudo umount mnt/run
    fi
    if mountpoint mnt; then
        sudo umount -l mnt
    fi
    [ -z "$CONNECTED" ] || sudo qemu-nbd --disconnect /dev/nbd0
}

CONNECTED=""
trap "cleanup" EXIT INT TERM
set -o xtrace

# Install build dependencies
sudo apt update
sudo apt install -y qemu-utils

# Make directory mount to use as QCOW2 root dir
mkdir mnt

# Connect to disk using nbd
sudo modprobe nbd max_part=8
sleep 1
ls -l /dev/nbd*
sudo qemu-nbd --disconnect /dev/nbd0 || true
sudo qemu-nbd --connect=/dev/nbd0 debian-13-generic-amd64.qcow2
CONNECTED="true"

# Gives the system a beat to ensure the nbd mounts exist
sleep 1

# Mount files to use it as valid chroot
sudo mount /dev/nbd0p1 mnt
sudo mount --bind /dev mnt/dev
sudo mount --bind /proc mnt/proc
sudo mount --bind /sys mnt/sys
sudo mount --bind /run mnt/run

# Update, Upgrade, and Install
sudo chroot mnt apt update
sudo chroot mnt apt purge -y grub-cloud-amd64 grub-pc grub-efi-amd64
sudo chroot mnt apt upgrade -y
sudo chroot mnt apt install -y curl qemu-guest-agent nfs-server keepalived ipcalc etcd-client jq
sudo rm -f mnt/etc/keepalived/keepalived.conf  # Need to delete default file to ensure we can create one on init
sudo install -Dm755 dockfs-init.sh mnt/usr/bin/dockfs-init  # Creates keepalived config once on boot
sudo install -Dm755 dockfs-check.sh mnt/usr/bin/dockfs-check  # Checks health for Active node (Passive will fail)
sudo install -Dm755 dockfs-notify.sh mnt/usr/bin/dockfs-notify  # Sends fault to control plane for data disk failover
sudo install -Dm755 dockfs-datadisk-config.sh mnt/usr/bin/dockfs-datadisk-config  # Configures SCSI1 for NFS export on attachement
sudo cp dockfs.service mnt/usr/lib/systemd/system  # One-shot that runs init and config on boot
sudo cp dockfs-manage-datadisk.service mnt/usr/lib/systemd/system  # Called by udev on SCSI1 attachment
sudo cp 99-dockfs.rules mnt/etc/udev/rules.d/  # udev rule for SCSI1 disk
sudo chroot mnt systemctl enable dockfs

cleanup
mv -f debian-13-generic-amd64.qcow2 "orbitlab-dockfs-amd64-${version}.qcow2"
