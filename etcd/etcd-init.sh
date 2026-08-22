#!/bin/bash

set -eou pipefail

ENDPOINT=http://etcd.orbitlab.internal:2379
ETCDCTL=(/usr/bin/etcdctl --endpoints="${ENDPOINT}" --dial-timeout=3s --command-timeout=5s)
TOKEN="orbitlab-etcd-cluster"
ADDRESS="$(ip -o -4 addr show dev eth0 | awk '{print $4}')"
NAME="$(hostname)"


is_initial_member() {
    local srv_records
    srv_records=$(dig +short _etcd-server._tcp.orbitlab.internal SRV 2>/dev/null)
    if [ -z "${srv_records}" ]; then
        return 1
    else
        echo "${srv_records}" | awk '{print $4}' | sed 's/\.$//' | grep -q "^${NAME}\.orbitlab\.internal$"
    fi
}

[ -d /var/local/etcd ] || mkdir -p /var/local/etcd

if timeout 3 "${ETCDCTL[@]}" endpoint health >/dev/null 2>&1; then
    if [ -d /var/local/etcd/member ]; then
        echo "Already a cluster member."
        ETCD_NAME="${NAME}"
        ETCD_INITIAL_CLUSTER=$("${ETCDCTL[@]}" member list -w json | jq -r '[.members[] | "\(.name)=\(.peerURLs[0])"] | join(",")')
        ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${NAME}.orbitlab.internal:2380"
    else
        eval "$("${ETCDCTL[@]}" member add "${NAME}" --peer-urls="http://${NAME}.orbitlab.internal:2380" | grep '^ETCD_')"
        
    fi
    cat >/etc/default/etcd <<EOL
ETCD_NAME=${ETCD_NAME}
ETCD_DATA_DIR=/var/local/etcd
ETCD_INITIAL_CLUSTER=${ETCD_INITIAL_CLUSTER}
ETCD_INITIAL_ADVERTISE_PEER_URLS=${ETCD_INITIAL_ADVERTISE_PEER_URLS}
ETCD_INITIAL_CLUSTER_STATE=existing
ETCD_INITIAL_CLUSTER_TOKEN=${TOKEN}
ETCD_ADVERTISE_CLIENT_URLS=http://${NAME}.orbitlab.internal:2379
ETCD_LISTEN_CLIENT_URLS=http://${ADDRESS%/*}:2379,http://127.0.0.1:2379
ETCD_LISTEN_PEER_URLS=http://${ADDRESS%/*}:2380
ETCD_LOG_FORMAT=console
EOL
    
    systemctl restart etcd
elif is_initial_member; then
    cat >/etc/default/etcd <<EOL
ETCD_NAME=${NAME}
ETCD_DATA_DIR=/var/local/etcd
ETCD_DISCOVERY_SRV=orbitlab.internal
ETCD_INITIAL_ADVERTISE_PEER_URLS=http://${NAME}.orbitlab.internal:2380
ETCD_INITIAL_CLUSTER_TOKEN=${TOKEN}
ETCD_INITIAL_CLUSTER_STATE=new
ETCD_ADVERTISE_CLIENT_URLS=http://${NAME}.orbitlab.internal:2379
ETCD_LISTEN_CLIENT_URLS=http://${ADDRESS%/*}:2379,http://127.0.0.1:2379
ETCD_LISTEN_PEER_URLS=http://${ADDRESS%/*}:2380
ETCD_LOG_FORMAT=console
EOL
    systemctl restart etcd
else
    echo "Cluster at ${ENDPOINT} did not respond and I'm not an initial member"
    exit 1
fi
