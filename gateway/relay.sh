#!/bin/sh

set -eu

GATEWAY_ID="$(hostname)"
SECTOR_ID="$(printf '%s\n' "${GATEWAY_ID}" | sed -nE 's/^gateway-(olvn[1-9][0-9]{3})$/\1/p')"
[ -n "${SECTOR_ID}" ] || { echo "Invalid sector gateway hostname: ${GATEWAY_ID}" >&2; exit 1; }

# Update leases store so any replacement gateway can sync existing leases
leases="$(base64 -w0 /var/local/dnsmasq/dnsmasq.leases)"
/usr/bin/etcdctl --endpoints="http://etcd.orbitlab.internal:2379" --dial-timeout=3s --command-timeout=5s put "gateway/${SECTOR_ID}/dhcp/leases" "${leases}"

# The control plane will know sooner than DHCP when a host is deleted, so we ignore these.
[ "$1" = "del" ] && exit 0
# Send payload to the Orbital Relay to update the requisite sector DNS.
curl -X POST http://orbital-relay.orbitlab.internal/dns/v1/dhcp \
  --data "{\"sector\":\"$SECTOR_ID\",\"action\":\"$1\",\"mac\": \"$2\",\"address\": \"$3\"}"
