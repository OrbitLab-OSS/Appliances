#!/bin/bash

set -eou pipefail

ENDPOINT=http://etcd.orbitlab.internal:2379
DATACORE_NAMESPACE=/orbitlab/services/datacore

createServices() {
    mkdir -p /var/local/etcd
    cat >/usr/lib/systemd/system/etcd.service <<EOL
[Unit]
Description=etcd
Documentation=https://etcd.io/docs/v3.6/
Wants=network.target
After=network.target
OnFailure=etcd-failure-notify.service

[Service]
EnvironmentFile=/etc/default/etcd
WorkingDirectory=/var/local/etcd
ExecStart=etcd
ExecStopPost=/usr/bin/etcd-mgr failover
Restart=always
RefuseManualStop=true

[Install]
WantedBy=multi-user.target
EOL
    cat >/usr/lib/systemd/system/etcd-failure-notify.service <<EOL
[Unit]
Description=ETCD Notify Control Plane on Failure
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/etcd-mgr failover

[Install]
WantedBy=multi-user.target
EOL
    systemctl enable --now etcd.service
}

bootstrapCluster() {
    local name="$1"
    local address="$2"
    cat >/etc/default/etcd <<EOL
ETCD_NAME=$name
ETCD_DISCOVERY_SRV=orbitlab.internal
ETCD_INITIAL_ADVERTISE_PEER_URLS=http://$name.orbitlab.internal:2380
ETCD_INITIAL_CLUSTER_TOKEN=orbitlab-etcd-cluster
ETCD_INITIAL_CLUSTER_STATE=new
ETCD_ADVERTISE_CLIENT_URLS=http://$name.orbitlab.internal:2379
ETCD_LISTEN_CLIENT_URLS=http://$address:2379
ETCD_LISTEN_PEER_URLS=http://$address:2380
ETCD_LOG_FORMAT=console
EOL
    createServices
}

addMember() {
    local address="$1"
    local name=$(hostname)
    local output=$(etcdctl --endpoints="$ENDPOINT" member add "$name" --peer-urls="http://$name.orbitlab.internal:2380")
    echo "$output" | awk '{ if (match($1, "ETCD")) print $1 }' > /etc/default/etcd
    echo "ETCD_ADVERTISE_CLIENT_URLS=http://$name.orbitlab.internal:2379" >> /etc/default/etcd
    echo "ETCD_LISTEN_CLIENT_URLS=http://$address:2379" >> /etc/default/etcd
    echo "ETCD_LISTEN_PEER_URLS=http://$address:2380" >> /etc/default/etcd
    echo "ETCD_LOG_FORMAT=console" >> /etc/default/etcd
    createServices
}

initializeMember() {
    ADDRESS=$(ip addr show eth0 | grep "inet\b" | awk '{print $2}')
    if timeout 3 etcdctl --endpoints="$ENDPOINT" endpoint health >/dev/null 2>&1; then
        addMember "${ADDRESS%/*}"
    else
        bootstrapCluster "$(hostname)" "${ADDRESS%/*}"
    fi
}

removeMember() {
    local name="$1"
    [ -z "$name" ] && echo "Missing member name: 'etcd-mgr remove NAME'" && exit 1
    local member_id=$(etcdctl --endpoints="$ENDPOINT" member list | awk -v member="$name," '{ if ($3 == member) print $1 }')
    etcdctl --endpoints="$ENDPOINT" member remove "${member_id%,*}"
}

emitFailureEvent() {
    ADDRESS=$(ip addr show eth0 | grep "inet\b" | awk '{print $2}')
    curl -X POST http://orbital-relay.orbitlab.internal/etcd/v1/failover --data "{\"name\":\"$(hostname)\", \"address\": \"$ADDRESS\"}"
}

createDataCoreCluster() {
    local cluster="$1"
    [ -z "$cluster" ] && echo "No DataCore name provided" && exit 1
    local config="$2"
    [ -z "$config" ] && echo "No DataCore config provided" && exit 1
    etcdctl --endpoints="$ENDPOINT" put "$DATACORE_NAMESPACE/$cluster/orbitlab-config" "$config"
}

deleteDataCoreCluster() {
    local cluster="$1"
    [ -z "$cluster" ] && echo "No DataCore name provided" && exit 1

    local data=$(etcdctl --endpoints="$ENDPOINT" get --prefix "$DATACORE_NAMESPACE/$cluster")
    [ -n "$data" ] && etcdctl --endpoints="$ENDPOINT" del "$DATACORE_NAMESPACE/$cluster"
}

COMMAND="${1:-}"

case $COMMAND in
    init)
        initializeMember
        ;;
    failover)
        emitFailureEvent
        ;;
    remove)
        removeMember "${2:-}"
        ;;
    create-datacore)
        createDataCoreCluster "${2:-}" "${3:-}"
        ;;
    delete-datacore)
        deleteDataCoreCluster "${2:-}"
        ;;
esac
