#!/bin/bash

set -eou pipefail

ETCD_ENDPOINT="etcd.orbitlab.internal:2379"
DATACORE_NAMESPACE=/orbitlab/services/datacore

configurePatroni() {
    local config="$1"
    local cluster="$2"
    local superuser_password=$(echo "$config" | jq -r '.superuser_password')
    local replication_password=$(echo "$config" | jq -r '.replication_password')
    local address="$(ip addr show eth0 | grep "inet\b" | awk '{print $2}')"
    local cidr="$(ipcalc -n $address | awk '/Network/ {print $2}')"
    rm -rf /var/lib/postgresql/17/main
    mkdir -p /var/lib/postgresql/17/main
    chown postgres:postgres /var/lib/postgresql/17/main
    chmod 700 /var/lib/postgresql/17/main
    cat >/etc/datacore/patroni.yaml <<EOL
scope: $cluster
namespace: $DATACORE_NAMESPACE
name: $(hostname)

etcd3:
  host: $ETCD_ENDPOINT

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
      password: $superuser_password
    replication:
      password: $replication_password
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
      password: $superuser_password
    replication:
      username: replicator
      password: $replication_password

  pg_hba:
    - local all postgres peer
    - host replication replicator 127.0.0.1/32 md5
    - host replication replicator $cidr md5
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
    systemctl enable --now patroni
}

configureKeepalived() {
    local config="$1"
    local keepalived_password=$(echo "$config" | jq -r '.keepalived_password')
    local rw_virtual_router_id=$(echo "$config" | jq -r '.rw_virtual_router_id')
    local ro_virtual_router_id=$(echo "$config" | jq -r '.ro_virtual_router_id')
    local rw_vip=$(echo "$config" | jq -r '.rw_vip')
    local ro_vip=$(echo "$config" | jq -r '.ro_vip')
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
    virtual_router_id $rw_virtual_router_id
    priority 100
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass $keepalived_password
    }

    virtual_ipaddress {
        $rw_vip
    }

    track_script {
        chk_primary
    }
}
vrrp_instance RO_VIP {
    state BACKUP
    interface eth0
    virtual_router_id $ro_virtual_router_id
    priority 100
    advert_int 1

    nopreempt

    authentication {
        auth_type PASS
        auth_pass $keepalived_password
    }

    virtual_ipaddress {
        $ro_vip
    }

    track_script {
        chk_replica
    }
}
EOL
    systemctl enable --now keepalived
}

configureDatabase() {
    if curl -sf "http://127.0.0.1:8080/patroni" | jq -e '.role=="primary"' > /dev/null; then
        echo "I am the Leader. Waiting for PostgreSQL to accept connections..."
        until pg_isready -h "127.0.0.1" -p 5432 -U postgres > /dev/null 2>&1; do
            sleep 2
        done
        echo "PostgreSQL is ready. Configuring application database..."
        local cluster="datacore-$(hostname | awk -F- '{print $2}')"
        local config=$(etcdctl --endpoints="http://$ETCD_ENDPOINT" get --print-value-only "$DATACORE_NAMESPACE/$cluster/orbitlab-config")
        local application_database="--variable=app_db='$(echo "$config" | jq -r '.application_database')'"
        local application_user="--variable=app_user='$(echo "$config" | jq -r '.application_user')'"
        local application_password="--variable=app_password='$(echo "$config" | jq -r '.application_password')'"
        su postgres -c "psql $application_database $application_user $application_password -f /etc/datacore/provision_application_db.sql"
        echo "Database configured."
    fi
}

initialize() {
    ip link set dev eth0 mtu 1450
    local cluster="datacore-$(hostname | awk -F- '{print $2}')"
    local config=$(etcdctl --endpoints="http://$ETCD_ENDPOINT" get --print-value-only "$DATACORE_NAMESPACE/$cluster/orbitlab-config")
    if [ -f /etc/datacore/patroni.yaml ]; then
        echo "Patroni already configured."
    else
        configurePatroni "$config" "$cluster"
    fi
    until curl -sf "http://127.0.0.1:8080/patroni" | jq -e '.state=="running"' > /dev/null; do
        echo "Waiting for local patroni to reach 'running' state..."
        sleep 2
    done
    if [ -f /etc/keepalived.conf ]; then
        echo "Keepalived already configured"
    else
        configureKeepalived "$config"
    fi
    configureDatabase
}

COMMAND="$1"
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
    on_role_change)
        ROLE="$2"
        CLUSTER="$3"
        curl -X POST http://orbital-relay.orbitlab.internal/datacore/v1/event \
            --data "{\"node\":\"$(hostname)\",\"role\": \"$ROLE\",\"manifest\": \"$CLUSTER\",\"event\": \"on_role_change\"}"
        ;;
    on_start)
        ROLE="$2"
        CLUSTER="$3"
        curl -X POST http://orbital-relay.orbitlab.internal/datacore/v1/event \
            --data "{\"node\":\"$(hostname)\",\"role\": \"$ROLE\",\"manifest\": \"$CLUSTER\",\"event\": \"on_start\"}"
        ;;
    on_stop)
        ROLE="$2"
        CLUSTER="$3"
        curl -X POST http://orbital-relay.orbitlab.internal/datacore/v1/event \
            --data "{\"node\":\"$(hostname)\",\"role\": \"$ROLE\",\"manifest\": \"$CLUSTER\",\"event\": \"on_stop\"}"
        ;;
    *)
        echo "Unknown command: $COMMAND" && exit 1
        ;;
esac
