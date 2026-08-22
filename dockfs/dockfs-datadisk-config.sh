#!/bin/bash

# TODO: Extend the reconcile flow to manage multiple SCSI disks with LVM so
# DockFS can scale by adding disks or resizing existing ones.

set -eou pipefail

STATE_DIR=/var/lib/dockfs
RUN_DIR=/run/dockfs
LOCK_FILE="${RUN_DIR}/reconcile.lock"
HAD_DISK_FILE="${STATE_DIR}/had-disk"
NOTIFY_PENDING_FILE="${STATE_DIR}/notify-pending"
CURRENT_DEVICE_FILE="${STATE_DIR}/current-device"
MOUNT_PATH=/mnt/data
EXPORT_PATH=/exports/data
EXPORTS_FILE=/etc/exports
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

getPrimaryAddress() {
    ip -o -4 addr show dev eth0 | awk '$0 !~ /proto keepalived/ {print $4; exit}'
}

mountSignature() {
    findmnt -n --nofsroot -o SOURCE,FSTYPE "${1}" 2>/dev/null || true
}

ensureExt4Filesystem() {
    local device
    local filesystem_type

    device="${1}"

    if blkid "${device}" >/dev/null 2>&1; then
        filesystem_type="$(blkid -s TYPE -o value "${device}")"
        if [ "${filesystem_type}" = "ext4" ]; then
            return 1
        fi

        echo "Refusing to format ${device}: found existing filesystem '${filesystem_type}'" >&2
        return 2
    fi

    mkfs.ext4 -F -E lazy_itable_init=1,lazy_journal_init=1 "${device}"
    return 0
}

ensureShareRootPermissions() {
    local initialized_new_filesystem

    initialized_new_filesystem="${1}"

    if [ "${initialized_new_filesystem}" -eq 1 ]; then
        chmod 0777 "${MOUNT_PATH}"
    fi
}

writeFstab() {
    local uuid
    local temp_file

    uuid="${1}"
    temp_file="$(mktemp)"

    awk '$2 != "/mnt/data" && $2 != "/exports/data"' /etc/fstab >"${temp_file}"
    {
        printf 'UUID=%s /mnt/data ext4 defaults,noatime 0 0\n' "${uuid}"
        printf '/mnt/data /exports/data none bind 0 0\n'
    } >>"${temp_file}"

    mv "${temp_file}" /etc/fstab
}

removeFstabEntries() {
    local temp_file

    temp_file="$(mktemp)"
    awk '$2 != "/mnt/data" && $2 != "/exports/data"' /etc/fstab >"${temp_file}"
    mv "${temp_file}" /etc/fstab
}

ensureMounts() {
    local device
    local expected_uuid
    local current_source
    local current_uuid
    local mnt_signature
    local exports_signature

    device="${1}"
    expected_uuid="$(blkid -s UUID -o value "${device}")"
    current_source="$(findmnt -n -o SOURCE "${MOUNT_PATH}" 2>/dev/null || true)"

    if [ -z "${current_source}" ]; then
        mount "${MOUNT_PATH}"
    else
        current_uuid="$(blkid -s UUID -o value "${current_source}" 2>/dev/null || true)"
        if [ "${current_uuid}" != "${expected_uuid}" ]; then
            umount -f "${EXPORT_PATH}" 2>/dev/null || true
            umount -f "${MOUNT_PATH}" 2>/dev/null || true
            mount "${MOUNT_PATH}"
        fi
    fi

    mnt_signature="$(mountSignature "${MOUNT_PATH}")"
    exports_signature="$(mountSignature "${EXPORT_PATH}")"

    if [ -z "${exports_signature}" ]; then
        mount --bind "${MOUNT_PATH}" "${EXPORT_PATH}"
        return 0
    fi

    if [ "${exports_signature}" != "${mnt_signature}" ]; then
        umount -f "${EXPORT_PATH}" 2>/dev/null || true
        mount --bind "${MOUNT_PATH}" "${EXPORT_PATH}"
    fi
}

writeExports() {
    local cidr
    local temp_file

    cidr="${1}"
    touch "${EXPORTS_FILE}"
    temp_file="$(mktemp)"

    awk '$1 != "/exports/data"' "${EXPORTS_FILE}" >"${temp_file}"
    printf '/exports/data %s(%s)\n' "${cidr}" "${EXPORT_OPTIONS}" >>"${temp_file}"
    mv "${temp_file}" "${EXPORTS_FILE}"
}

removeExports() {
    local temp_file

    touch "${EXPORTS_FILE}"
    temp_file="$(mktemp)"
    awk '$1 != "/exports/data"' "${EXPORTS_FILE}" >"${temp_file}"
    mv "${temp_file}" "${EXPORTS_FILE}"
}

stopServing() {
    removeExports
    exportfs -r || true
    systemctl stop nfs-server || true
    umount -f "${EXPORT_PATH}" 2>/dev/null || true
    umount -f "${MOUNT_PATH}" 2>/dev/null || true
    removeFstabEntries
}

markDiskMissing() {
    local was_active

    was_active="${1}"

    if [ "${was_active}" -eq 1 ]; then
        touch "${NOTIFY_PENDING_FILE}"
    fi

    rm -f "${CURRENT_DEVICE_FILE}"
}

markDiskConfigured() {
    local device
    local uuid

    device="${1}"
    uuid="$(blkid -s UUID -o value "${device}")"

    touch "${HAD_DISK_FILE}"
    rm -f "${NOTIFY_PENDING_FILE}"
    printf 'device=%s\nuuid=%s\n' "${device}" "${uuid}" >"${CURRENT_DEVICE_FILE}"
}

configureActiveNode() {
    local device
    local address
    local cidr
    local filesystem_state
    local initialized_new_filesystem
    local uuid

    device="${1}"
    initialized_new_filesystem=0
    filesystem_state=0
    if ensureExt4Filesystem "${device}"; then
        initialized_new_filesystem=1
    else
        filesystem_state="${?}"
        if [ "${filesystem_state}" -gt 1 ]; then
            return "${filesystem_state}"
        fi
    fi

    address="$(getPrimaryAddress)"
    [ -n "${address}" ] || { echo "No IPv4 address found on eth0" >&2; return 1; }

    cidr="$(ipcalc -n "${address}" | awk '/Network/ {print $2}')"
    uuid="$(blkid -s UUID -o value "${device}")"

    mkdir -p "${MOUNT_PATH}" "${EXPORT_PATH}" "${STATE_DIR}" "${RUN_DIR}"
    chmod 0755 "${MOUNT_PATH}" "${EXPORT_PATH}"

    writeFstab "${uuid}"
    ensureMounts "${device}"
    ensureShareRootPermissions "${initialized_new_filesystem}"
    writeExports "${cidr}"
    systemctl enable nfs-server >/dev/null
    systemctl restart nfs-server
    exportfs -r
    markDiskConfigured "${device}"
}

reconcile() {
    local device
    local was_active

    mkdir -p "${STATE_DIR}" "${RUN_DIR}"
    exec 9>"${LOCK_FILE}"
    flock 9

    if device="$(getDrivePath)"; then
        configureActiveNode "${device}"
        return 0
    fi

    was_active=0
    if [ -f "${CURRENT_DEVICE_FILE}" ]; then
        was_active=1
    fi

    stopServing
    markDiskMissing "${was_active}"
}

COMMAND="${1:-reconcile}"
case "${COMMAND}" in
    reconcile)
        reconcile
        ;;
    *)
        echo "Unknown command: ${COMMAND}" >&2
        exit 1
        ;;
esac
