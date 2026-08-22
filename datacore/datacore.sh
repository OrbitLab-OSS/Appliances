#!/bin/bash

set -eou pipefail

ETCD_ENDPOINT="etcd.orbitlab.internal:2379"
ETCDCTL=(/usr/bin/etcdctl --endpoints="http://${ETCD_ENDPOINT}" --dial-timeout=3s --command-timeout=5s)
DATACORE_NAMESPACE=/orbitlab/services/datacore
PATRONI_SENTINEL=/etc/datacore/.patroni-configured
HOSTNAME="$(hostname)"
CLUSTER_ID="${HOSTNAME%-*}"

configurePatroni() {
    local config
    config="${1}"

    local superuser_password
    superuser_password=$(echo "${config}" | jq -r '.superuser_password')

    local replication_password
    replication_password=$(echo "${config}" | jq -r '.replication_password')

    local address
    address="$(ip -o -4 addr show dev eth0 | awk '$0 !~ /proto keepalived/ {print $4; exit}')"

    local cidr
    cidr="$(ipcalc -n "${address}" | awk '/Network/ {print $2}')"

    if [ -f "${PATRONI_SENTINEL}" ]; then
        echo "Refusing to reinitialize Patroni node without /etc/datacore/patroni.yaml"
        exit 1
    fi
    rm -rf /var/lib/postgresql/17/main
    mkdir -p /var/lib/postgresql/17/main
    chown postgres:postgres /var/lib/postgresql/17/main
    chmod 700 /var/lib/postgresql/17/main
    cat >/etc/datacore/patroni.yaml <<EOL
scope: ${CLUSTER_ID}
namespace: ${DATACORE_NAMESPACE}
name: ${HOSTNAME}

etcd3:
  host: ${ETCD_ENDPOINT}

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576

    postgresql:
      use_pg_rewind: true
      use_slots: true

  initdb:
    - encoding: UTF8
    - data-checksums

  users:
    postgres:
      password: ${superuser_password}
    replicator:
      password: ${replication_password}
      options:
        - replication

restapi:
  connect_address: ${address%/*}:8080
  listen: 0.0.0.0:8080

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${address%/*}:5432
  data_dir: /var/lib/postgresql/17/main
  bin_dir: /usr/lib/postgresql/17/bin

  authentication:
    superuser:
      username: postgres
      password: ${superuser_password}
    replication:
      username: replicator
      password: ${replication_password}

  pg_hba:
    - local all postgres peer
    - host replication replicator 127.0.0.1/32 md5
    - host replication replicator ${cidr} md5
    - host all all 0.0.0.0/0 md5

  callbacks:
    on_stop: /usr/bin/datacore
    on_start: /usr/bin/datacore
    on_role_change: /usr/bin/datacore

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOL
    touch "${PATRONI_SENTINEL}"
    systemctl enable --now patroni
}

configureKeepalived() {
    local config
    config="${1}"

    local keepalived_password
    keepalived_password=$(echo "$config" | jq -r '.keepalived_password')

    local rw_virtual_router_id
    rw_virtual_router_id=$(echo "$config" | jq -r '.rw_virtual_router_id')

    local ro_virtual_router_id
    ro_virtual_router_id=$(echo "$config" | jq -r '.ro_virtual_router_id')

    local rw_vip
    rw_vip=$(echo "$config" | jq -r '.rw_vip')

    local ro_vip
    ro_vip=$(echo "$config" | jq -r '.ro_vip')

    cat >/etc/keepalived/keepalived.conf <<EOL
vrrp_script chk_primary {
    script "/usr/bin/datacore is-primary"
    interval 2
    timeout 1
    fall 2
    rise 1
}
vrrp_script chk_replica {
    script "/usr/bin/datacore is-replica"
    interval 2
    timeout 1
    fall 2
    rise 1
}
vrrp_instance RW_VIP {
    state BACKUP
    interface eth0
    virtual_router_id ${rw_virtual_router_id}
    priority 100
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass ${keepalived_password}
    }

    virtual_ipaddress {
        ${rw_vip}
    }

    track_script {
        chk_primary
    }
}
vrrp_instance RO_VIP {
    state BACKUP
    interface eth0
    virtual_router_id ${ro_virtual_router_id}
    priority 100
    advert_int 1

    nopreempt

    authentication {
        auth_type PASS
        auth_pass ${keepalived_password}
    }

    virtual_ipaddress {
        ${ro_vip}
    }

    track_script {
        chk_replica
    }
}
EOL
    systemctl enable --now keepalived
}

initialize() {
    local config
    config=$("${ETCDCTL[@]}" get --print-value-only "${DATACORE_NAMESPACE}/${CLUSTER_ID}/orbitlab-config")

    [ -n "${config}" ] || { echo "No config from etcd"; exit 1; }

    if [ -f /etc/datacore/patroni.yaml ]; then
        echo "Patroni already configured."
    elif [ -f "${PATRONI_SENTINEL}" ]; then
        echo "Patroni sentinel exists but /etc/datacore/patroni.yaml is missing; refusing to reinitialize node"
        exit 1
    else
        configurePatroni "${config}"
    fi

    until curl -sf "http://127.0.0.1:8080/patroni" | jq -e '.state=="running"' > /dev/null; do
        echo "Waiting for local patroni to reach 'running' state..."
        sleep 2
    done

    if [ -f /etc/keepalived/keepalived.conf ]; then
        echo "Keepalived already configured"
    else
        configureKeepalived "${config}"
    fi
}

healthCheck() {
    while true; do
        if systemctl is-active --quiet patroni; then
            break
        fi

        if systemctl is-failed --quiet patroni; then
            echo "patroni failed."
            systemctl status patroni --no-pager || true
            exit 1
        fi

        sleep 2
    done

    local patroni_ctl
    patroni_ctl="patronictl -c /etc/datacore/patroni.yaml"
    if ! $patroni_ctl list | grep "$(hostname)" > /dev/null; then
        echo "DataCore node $(hostname) not in Patroni cluster."
        exit 1
    fi
    if ! su -c "psql -d postgres -Atqc 'SELECT 1;'" - postgres > /dev/null; then
        echo "Unable to connect to postgres."
        exit 1
    fi
    if [ "$($patroni_ctl list | grep "$(hostname)" | awk '{print $6}')" == "Leader" ]; then
        if [ "$(su -c "psql -d postgres -Atqc 'SELECT pg_is_in_recovery();'" - postgres)" != "f" ]; then
            echo "Leader is in recovery but it shouldn't be."
            exit 1
        fi
    else
        if [ "$($patroni_ctl list | grep "$(hostname)" | awk '{print $8}')" != "streaming" ]; then
            CLUSTER=$($patroni_ctl list | grep "Cluster" | awk '{print $3}')
            $patroni_ctl reinit "$CLUSTER" "$(hostname)" --force --wait
            if [ "$($patroni_ctl list | grep "$(hostname)" | awk '{print $8}')" != "streaming" ]; then
                echo "Failed to reinit Replica node $(hostname)."
                exit 1
            fi
        fi
    fi
}

COMMAND="${1}"
case $COMMAND in
    init)
        initialize
        ;;
    is-primary)
        # exits with code 22 if replica
        curl -sf http://127.0.0.1:8080/primary > /dev/null
        ;;
    is-replica)
        # exits with code 22 if primary
        curl -sf http://127.0.0.1:8080/replica > /dev/null
        ;;
    health-check)
        healthCheck
        ;;
    on_role_change)
        ROLE="${2}"
        curl -X POST http://orbital-relay.orbitlab.internal/datacore/v1/event \
            --data "{\"node\":\"${HOSTNAME}\",\"role\": \"${ROLE}\",\"id\": \"${CLUSTER_ID}\",\"event\": \"on_role_change\"}"
        ;;
    on_start)
        ROLE="${2}"
        curl -X POST http://orbital-relay.orbitlab.internal/datacore/v1/event \
            --data "{\"node\":\"${HOSTNAME}\",\"role\": \"${ROLE}\",\"id\": \"${CLUSTER_ID}\",\"event\": \"on_start\"}"
        ;;
    on_stop)
        ROLE="${2}"
        curl -X POST http://orbital-relay.orbitlab.internal/datacore/v1/event \
            --data "{\"node\":\"${HOSTNAME}\",\"role\": \"${ROLE}\",\"id\": \"${CLUSTER_ID}\",\"event\": \"on_stop\"}"
        ;;
    *)
        echo "Unknown command: ${COMMAND}" && exit 1
        ;;
esac
