#!/bin/bash

set -eou pipefail

MOUNT_PATH=/mnt/data
EXPORT_PATH=/exports/data
EXPORT_OPTIONS="rw,sync,no_root_squash,no_subtree_check,fsid=0,crossmnt"

getDrivePath() {
    local device

    udevadm settle --timeout=10 || true
    for device in /dev/disk/by-id/*scsi1; do
        [ -b "${device}" ] || continue
        case "${device}" in
            *-part*) continue ;;
        esac
        printf '%s\n' "${device}"
        return 0
    done

    return 1
}

mountSignature() {
    findmnt -n --nofsroot -o SOURCE,FSTYPE "${1}" 2>/dev/null
}

checkMounts() {
    local mounted_source
    local mounted_uuid
    local expected_uuid
    local mnt_signature
    local exports_signature

    mounted_source="$(findmnt -n -o SOURCE "${MOUNT_PATH}" 2>/dev/null)" || return 1
    mounted_uuid="$(blkid -s UUID -o value "${mounted_source}" 2>/dev/null)" || return 1
    expected_uuid="$(blkid -s UUID -o value "${1}")" || return 1
    [ "${mounted_uuid}" = "${expected_uuid}" ] || return 1

    mnt_signature="$(mountSignature "${MOUNT_PATH}")" || return 1
    exports_signature="$(mountSignature "${EXPORT_PATH}")" || return 1
    [ "${exports_signature}" = "${mnt_signature}" ] || return 1
}

main() {
    local device
    local address
    local cidr

    device="$(getDrivePath)" || exit 1
    checkMounts "${device}" || exit 1

    address="$(ip -o -4 addr show dev eth0 | awk '$0 !~ /proto keepalived/ {print $4; exit}')"
    [ -n "${address}" ] || exit 1
    cidr="$(ipcalc -n "${address}" | awk '/Network/ {print $2}')"

    grep -Fxq "/exports/data ${cidr}(${EXPORT_OPTIONS})" /etc/exports || exit 1
    exportfs -v | grep -q "^/exports/data " || exit 1
    systemctl is-active --quiet nfs-server || exit 1
}

main
