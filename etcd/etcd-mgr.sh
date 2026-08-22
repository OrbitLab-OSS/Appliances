#!/bin/bash

set -eou pipefail

ETCDCTL=(/usr/bin/etcdctl --endpoints=http://127.0.0.1:2379 --dial-timeout=3s --command-timeout=5s)
DATACORE_NAMESPACE=/orbitlab/services/datacore
DOCKFS_NAMESPACE=/orbitlab/services/dockfs
CONDUIT_NAMESPACE=/orbitlab/services/conduit
NAME="$(hostname)"

COMMAND="${1:-}"
[ -z "${COMMAND}" ] && { echo "Missing command"; exit 1; }

case $COMMAND in
    health-check)
        "${ETCDCTL[@]}" endpoint health
        ;;
    failover)
        ADDRESS="$(ip -o -4 addr show dev eth0 | awk '{print $4}')"
        curl -X POST http://orbital-relay.orbitlab.internal/etcd/v1/failover \
            --data "{\"name\":\"${NAME}\", \"address\": \"${ADDRESS%/*}\"}"
        ;;
    remove)
        MEMBER_TO_REMOVE="$2"
        MEMBER_ID="$("${ETCDCTL[@]}" member list -w json | jq -r ".members[] | select(.name==\"${MEMBER_TO_REMOVE}\") | .ID")"
        [ -z "${MEMBER_ID}" ] && { echo "Member not found"; exit 1; }
        "${ETCDCTL[@]}" member remove "$(printf '%x\n' "${MEMBER_ID}")"
        ;;
    create-datacore)
        CLUSTER="${2}"
        CONFIG="${3}"
        "${ETCDCTL[@]}" put "${DATACORE_NAMESPACE}/${CLUSTER}/orbitlab-config" "${CONFIG}"
        ;;
    delete-datacore)
        CLUSTER="${2}"
        if "${ETCDCTL[@]}" get --prefix "${DATACORE_NAMESPACE}/${CLUSTER}" --keys-only | grep -q .; then
            "${ETCDCTL[@]}" del "${DATACORE_NAMESPACE}/${CLUSTER}" --prefix
        fi
        ;;
    create-dockfs)
        CLUSTER="${2}"
        CONFIG="${3}"
        "${ETCDCTL[@]}" put "${DOCKFS_NAMESPACE}/${CLUSTER}/orbitlab-config" "${CONFIG}"
        ;;
    delete-dockfs)
        CLUSTER="${2}"
        if "${ETCDCTL[@]}" get --prefix "${DOCKFS_NAMESPACE}/${CLUSTER}" --keys-only | grep -q .; then
            "${ETCDCTL[@]}" del "${DOCKFS_NAMESPACE}/${CLUSTER}" --prefix
        fi
        ;;
    create-conduit)
        ID="${2}"
        CONFIG="${3}"
        "${ETCDCTL[@]}" put "${CONDUIT_NAMESPACE}/${ID}/config" "${CONFIG}"
        ;;
    delete-conduit)
        ID="${2}"
        if "${ETCDCTL[@]}" get --prefix "${CONDUIT_NAMESPACE}/${ID}" --keys-only | grep -q .; then
            "${ETCDCTL[@]}" del "${CONDUIT_NAMESPACE}/${ID}" --prefix
        fi
        ;;
esac
