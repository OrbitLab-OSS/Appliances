#!/bin/bash

set -eou pipefail

GATEWAY_ID="$(hostname)"
SECTOR_ID="$(printf '%s\n' "${GATEWAY_ID}" | sed -nE 's/^gateway-(olvn[1-9][0-9]{3})$/\1/p')"
[ -n "${SECTOR_ID}" ] || { echo "Invalid sector gateway hostname: ${GATEWAY_ID}" >&2; exit 1; }

ETCDCTL=(/usr/bin/etcdctl --endpoints="http://etcd.orbitlab.internal:2379" --dial-timeout=3s --command-timeout=5s)
SECTOR_ADDRESS=$(ip addr show eth0 | grep "inet\b" | grep "brd" | awk '{print $2}')
SECTOR_CIDR=$(ipcalc -n "${SECTOR_ADDRESS}" | awk '/Network/ {print $2}')
BACKPLANE_ADDRESS=$(ip addr show eth1 | grep "inet\b" | grep "brd" | awk '{print $2}')
BACKPLANE_CIDR=$(ipcalc -n "${BACKPLANE_ADDRESS}" | awk '/Network/ {print $2}')
DNS_ADDRESS=$(ip addr show eth2 | grep "inet\b" | grep "brd" | awk '{print $2}')

configureFrr() {
  IFS=. read -r a b c d <<< "${BACKPLANE_CIDR%/*}"
  local backplane_gateway
  backplane_gateway="$a.$b.$c.1"

  echo "Creating /etc/frr/frr.conf with ${SECTOR_ADDRESS%/*}, ${BACKPLANE_ADDRESS%/*}, and ${backplane_gateway}"
  cat >/etc/frr/frr.conf <<EOL
frr defaults traditional
log syslog warning
ip forwarding
!
interface eth0
 ip address ${SECTOR_ADDRESS%/*}
 no shutdown
!
interface eth1
 ip address ${BACKPLANE_ADDRESS%/*}
 no shutdown
!
ip route 0.0.0.0/0 ${backplane_gateway}
!
end
EOL
}

configureNftables() {
  echo "Creating /etc/nftables.conf with ${BACKPLANE_CIDR} and ${SECTOR_ADDRESS%/*}"
  cat >/etc/nftables.conf <<EOL
flush ruleset

table ip nat {
  chain prerouting {
    type nat hook prerouting priority -100;
    iif "eth1" ip daddr ${BACKPLANE_CIDR} dnat to ${SECTOR_ADDRESS%/*}
  }
  chain postrouting {
    type nat hook postrouting priority 100;
    oif "eth1" masquerade
  }
}

table inet filter {
  chain forward {
    type filter hook forward priority 0;
  }
  chain input {
    type filter hook input priority 0;
    policy accept;
  }
  chain output {
    type filter hook output priority 0;
    policy accept;
  }
}
EOL
}

configureCoreDNS() {
  echo "Creating ${SECTOR_ID} /etc/coredns/Corefile with ${DNS_ADDRESS%/*} and ${SECTOR_CIDR}"
  cat >/etc/coredns/Corefile <<EOL
. {
  bind ${DNS_ADDRESS%/*}

  acl {
    allow net ${SECTOR_CIDR}
    drop
  }

  rewrite stop {
    name suffix sector.internal. ${SECTOR_ID}.sector.internal.
    answer auto
  }

  forward . /etc/resolv.conf {
    policy sequential
    max_concurrent 1000
  }

  log
  errors
}
EOL
}

loadLeasesFromETCD() {
  local leases decoded
  leases=$("${ETCDCTL[@]}" get --print-value-only "gateway/${SECTOR_ID}/dhcp/leases")

  if [ -n "${leases}" ]; then
    # If this is a new Sector, there won't be existing leases. So, this will be an empty string.
    echo "Loading existing leases..."
    decoded=$(base64 -w0 -d <<< "$leases")
    cat >/var/local/dnsmasq/dnsmasq.leases <<EOL        
${decoded}
EOL
  sync
  fi
}

configureDnsmasq() {
  local broadcast
  broadcast=$(ipcalc "${SECTOR_CIDR}" | awk '/Broadcast/ {print $2}')

  local netmask
  netmask=$(ipcalc "${SECTOR_CIDR}" | awk '/Netmask/ {print $2}')

  if [ ! -f /var/local/dnsmasq/dnsmasq.leases ]; then
    # Only pull existing leases from ETCD if the file doesn't exist, i.e. a new replacement gateway.
    loadLeasesFromETCD
  fi

  # shellcheck disable=SC2034
  IFS=. read -r a b c d <<< "${SECTOR_CIDR%/*}"
  local dhcp_start
  dhcp_start="$a.$b.$c.50"
  
  # shellcheck disable=SC2034
  IFS=. read -r a b c d <<< "${broadcast}"
  local dhcp_end
  dhcp_end="$a.$b.$c.250"
  
  echo "Creating /etc/dnsmasq.conf with ${dhcp_start}, ${dhcp_end}, ${netmask}, ${SECTOR_ADDRESS%/*}, and ${DNS_ADDRESS%/*}"
  cat >/etc/dnsmasq.conf <<EOL
port=0
bind-interfaces
interface=eth0
except-interface=lo

dhcp-script=/var/local/dnsmasq/relay.sh
dhcp-authoritative
dhcp-leasefile=/var/local/dnsmasq/dnsmasq.leases
dhcp-range=${dhcp_start},${dhcp_end},${netmask},12h
domain=sector.internal,${SECTOR_CIDR},local
dhcp-option=option:dns-server,${DNS_ADDRESS%/*}
dhcp-option-force=option:domain-search,sector.internal

dhcp-mac=set:dual-home,02:4*:*:*:*:*
dhcp-option=tag:dual-home,121,${BACKPLANE_CIDR},${SECTOR_ADDRESS%/*}

dhcp-option=tag:!dual-home,option:router,${SECTOR_ADDRESS%/*}
dhcp-option=tag:!dual-home,121,0.0.0.0/0,${SECTOR_ADDRESS%/*},${BACKPLANE_CIDR},${SECTOR_ADDRESS%/*}
EOL
}

echo "Assigned eth0 ${SECTOR_ADDRESS} from ${SECTOR_CIDR}"
echo "Assigned eth1 ${BACKPLANE_ADDRESS} from ${BACKPLANE_CIDR}"
echo "Assigned eth2 ${DNS_ADDRESS} from ${SECTOR_CIDR}"

set -o xtrace

configureFrr
configureNftables
configureCoreDNS
configureDnsmasq

mkdir -p /run/orbitlab
touch /run/orbitlab/gateway-ready
