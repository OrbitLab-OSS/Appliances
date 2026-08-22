#!/bin/bash

set -eou pipefail

STATE_DIR=/var/lib/dockfs
NOTIFY_PENDING_FILE="${STATE_DIR}/notify-pending"
HOSTNAME="$(hostname)"
CLUSTER_ID="${HOSTNAME%-*}"

[ -f "${NOTIFY_PENDING_FILE}" ] || exit 0

ADDRESS="$(ip -o -4 addr show dev eth0 | awk '$0 !~ /proto keepalived/ {print $4; exit}')"
[ -n "${ADDRESS}" ] || { echo "No IPv4 address found on eth0" >&2; exit 1; }

if curl -fsS \
    --header 'Content-Type: application/json' \
    --data "{\"id\":\"${CLUSTER_ID}\", \"address\":\"${ADDRESS}\"}" \
    http://orbital-relay.orbitlab.internal/dockfs/v1/reconcile >/dev/null; then
    rm -f "${NOTIFY_PENDING_FILE}"
fi
