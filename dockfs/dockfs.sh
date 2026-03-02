#!/bin/bash

set -eou pipefail

initializeDockFS() {
    local address="$(ip addr show eth0 | grep "inet\b" | grep "brd" | awk '{print $2}')"
    local cidr="$(ipcalc -n $address | awk '/Network/ {print $2}')"

    local drive_id=$(ls /dev/disk/by-id | grep scsi1)
    local drive_uuid=$(blkid "/dev/disk/by-id/$drive_id" | cut -d" " -f2 | cut -d"=" -f2 | sed 's/"//g')
    if [ -z "$drive_uuid" ] ; then
      mkfs.ext4 "/dev/disk/by-id/$drive_id"
      local drive_uuid=$(blkid "/dev/disk/by-id/$drive_id" | cut -d" " -f2 | cut -d"=" -f2 | sed 's/"//g')
    fi
    mkdir -p /mnt/data
    chmod 0777 /mnt/data
    mkdir -p /exports/data
    if ! mountpoint /exports/data; then
      mount --bind /mnt/data /exports/data
    fi
    local reload_daemon=""
    if [ $(cat /etc/fstab | grep "UUID=$drive_uuid  /mnt/data" | wc -l) -lt 1 ]; then
      echo "UUID=$drive_uuid  /mnt/data  ext4  defaults,noatime  0  0" >> /etc/fstab
      local reload_daemon="true"
    fi
    if [ $(cat /etc/fstab | grep '/mnt/data /exports/data' | wc -l) -lt 1 ]; then
      echo "/mnt/data /exports/data none bind" >> /etc/fstab
      local reload_daemon="true"
    fi
    if [ $(cat /etc/exports | grep "/exports/data $cidr(rw,sync" | wc -l) -lt 1 ]; then
      echo "/exports/data $cidr(rw,sync,no_subtree_check,fsid=0,crossmnt)" >> /etc/exports
      local reload_daemon="true"
    fi
    [ -z "$reload_daemon" ] || systemctl daemon-reload 
    mount -a
    exportfs -r
}

configureKeepalived() {
    local vip="$1"
    local virtual_router_id="$1"
    local auth_secret="$1"
    cat >/etc/keepalived/keepalived.conf <<EOL
global_defs {
    router_id DOCKFS
    enable_script_security
    script_user root
}
vrrp_script dockfs_ready {
    script "/usr/bin/dockfs 'check-health'"
    interval 2
    fall 2
    rise 2
}
vrrp_instance DOCKFS_VIP {
    state BACKUP
    interface eth0
    virtual_router_id $virtual_router_id
    priority 100
    advert_int 1

    nopreempt

    authentication {
        auth_type PASS
        auth_pass $auth_secret
    }

    virtual_ipaddress {
        $vip
    }

    track_script {
        dockfs_ready
    }

    notify_master "/usr/bin/dockfs 'promoted'"
    notify_fault  "/usr/bin/dockfs 'failover'"
    notify_stop  "/usr/bin/dockfs 'failover'"
}
EOL
    systemctl restart keepalived
}

checkHealth() {
    mountpoint -q /mnt/data || exit 1
    [ "$(df --output=source,fstype /mnt/data/)" = "$(df --output=source,fstype /exports/data/)" ] || exit 1
    [ $(exportfs -v | grep "/exports/data" | wc -l) -ge 1 ] || exit 1
    systemctl is-active --quiet nfs-server || exit 1
}

COMMAND="$1"
case "$COMMAND" in
    create)
        initializeDockFS
        configureKeepalived "$2" "$3" "$4"
        ;;
    create-passive)
        configureKeepalived "$2" "$3" "$4"
        ;;
    promote)
        initializeDockFS
        ;;
    promoted)
        MANIFEST="dockfs-$(hostname | awk -F- '{print $2}')"
        ADDRESS="$(ip addr show eth0 | grep "inet\b" | grep "brd" | awk '{print $2}')"
        curl -X POST http://orbital-relay.orbitlab.internal/dockfs/v1/reconcile \
            --data "{\"manifest\":\"$MANIFEST\", \"address\": \"$ADDRESS\"}"
        ;;
    failover)
        MANIFEST="dockfs-$(hostname | awk -F- '{print $2}')"
        ADDRESS="$(ip addr show eth0 | grep "inet\b" | grep "brd" | awk '{print $2}')"
        curl -X POST http://orbital-relay.orbitlab.internal/dockfs/v1/failover \
            --data "{\"manifest\":\"$MANIFEST\", \"address\": \"$ADDRESS\"}"
        ;;
    check-health)
        checkHealth
        ;;
    *)
        echo "Unknown command: $COMMAND" || exit 1
        ;;
esac
