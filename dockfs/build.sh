#!/bin/bash

set -eou pipefail

if [ "${CHROOT:-'unset'}" == "unset" ]; then
    echo "CHROOT was not provided."
    exit 1
fi
version="${VERSION:-dev}"

cleanup() {
    [ -z "$CONNECTED" ] && return 0
    if mountpoint "$CHROOT/mnt/dev"; then
        sudo umount "$CHROOT/mnt/dev"
    fi
    if mountpoint "$CHROOT/mnt/proc"; then
        sudo umount "$CHROOT/mnt/proc"
    fi
    if mountpoint "$CHROOT/mnt/sys"; then
        sudo umount "$CHROOT/mnt/sys"
    fi
    if mountpoint "$CHROOT/mnt/run"; then
        sudo umount "$CHROOT/mnt/run"
    fi
    if mountpoint "$CHROOT/mnt"; then
        sudo umount -l "$CHROOT/mnt"
    fi
    [ -z "$CONNECTED" ] || sudo qemu-nbd --disconnect /dev/nbd0
}

CONNECTED=""
rm -f orbitlab-dockfs-*.qcow2
trap "cleanup" EXIT INT TERM
set -o xtrace

# Make directory mount to use as QCOW2 root dir
mkdir -p "$CHROOT/mnt"

# Copy the generic QCOW2 to the project root 
cp "$CHROOT/dockfs/debian-13-generic-amd64.qcow2" "$CHROOT/debian-13-generic-amd64.qcow2"

# Connect to disk using nbd
sudo modprobe nbd max_part=8
sudo qemu-nbd --connect=/dev/nbd0 "$CHROOT/debian-13-generic-amd64.qcow2"
CONNECTED="true"

# Gives the system a beat to ensure the nbd mounts exist
sleep 1

# Mount files to use it as valid chroot
sudo mount /dev/nbd0p1 "$CHROOT/mnt"
sudo mount --bind /dev "$CHROOT/mnt/dev"
sudo mount --bind /proc "$CHROOT/mnt/proc"
sudo mount --bind /sys "$CHROOT/mnt/sys"
sudo mount --bind /run "$CHROOT/mnt/run"

# Update, Upgrade, and Install
sudo chroot "$CHROOT/mnt" apt-get update
sudo chroot "$CHROOT/mnt" apt-get upgrade -y
sudo chroot "$CHROOT/mnt" apt-get install -y qemu-guest-agent nfs-server keepalived ipcalc
sudo cp dockfs.sh "$CHROOT/mnt/usr/bin/dockfs"

cleanup
mv -f "$CHROOT/debian-13-generic-amd64.qcow2" "orbitlab-dockfs-amd64-${version}.qcow2"
