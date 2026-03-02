#!/bin/bash

set -eou pipefail

SECTOR_ADDRESS=$(ip addr show eth0 | grep "inet\b" | grep "brd" | awk '{print $2}')
SECTOR_CIDR=$(ipcalc -n $SECTOR_ADDRESS | awk '/Network/ {print $2}')
BACKPLANE_ADDRESS=$(ip addr show eth1 | grep "inet\b" | grep "brd" | awk '{print $2}')
BACKPLANE_CIDR=$(ipcalc -n $BACKPLANE_ADDRESS | awk '/Network/ {print $2}')
DNS_ADDRESS=$(ip addr show eth2 | grep "inet\b" | grep "brd" | awk '{print $2}')

configureFrr() {
  IFS=. read -r a b c d <<< "${BACKPLANE_CIDR%/*}"
  local backplane_gateway="$a.$b.$c.1"
  echo "Creating /etc/frr/frr.conf with ${SECTOR_ADDRESS%/*}, ${BACKPLANE_ADDRESS%/*}, and $backplane_gateway"
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
ip route 0.0.0.0/0 $backplane_gateway
!
end
EOL
}

configureNftables() {
  echo "Creating /etc/nftables.conf with $BACKPLANE_CIDR and ${SECTOR_ADDRESS%/*}"
  cat >/etc/nftables.conf <<EOL
flush ruleset

table ip nat {
  chain prerouting {
    type nat hook prerouting priority -100;
    iif "eth1" ip daddr $BACKPLANE_CIDR dnat to ${SECTOR_ADDRESS%/*}
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
  echo "Creating /etc/coredns/Corefile with ${DNS_ADDRESS%/*} and $SECTOR_CIDR"
  cat >/etc/coredns/Corefile <<EOL
. {
  bind ${DNS_ADDRESS%/*}

  acl {
    allow net $SECTOR_CIDR
    drop
  }

  hosts /var/local/dnsmasq/sector.hosts sector.internal {
    ttl 30
    reload 5s
    fallthrough
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

configureDnsmasq() {
  IFS=. read -r a b c d <<< "${SECTOR_CIDR%/*}"
  local dhcp_start="$a.$b.$c.50"
  local broadcast=$(ipcalc "$SECTOR_CIDR" | awk '/Broadcast/ {print $2}')
  IFS=. read -r a b c d <<< "$broadcast"
  local dhcp_end="$a.$b.$c.250"
  local netmask=$(ipcalc "$SECTOR_CIDR" | awk '/Netmask/ {print $2}')
  echo "Creating /etc/dnsmasq.conf with $dhcp_start, $dhcp_end, $netmask, ${SECTOR_ADDRESS%/*}, and ${DNS_ADDRESS%/*}"
  cat >/etc/dnsmasq.conf <<EOL
port=0
bind-interfaces
interface=eth0
except-interface=lo

dhcp-script=/var/local/dnsmasq/dhcp-to-hosts.sh
dhcp-authoritative
dhcp-leasefile=/var/local/dnsmasq/dnsmasq.leases

dhcp-range=$dhcp_start,$dhcp_end,$netmask,12h
dhcp-option=option:router,${SECTOR_ADDRESS%/*}
dhcp-option=option:dns-server,${DNS_ADDRESS%/*}
EOL
}

COMMAND="$1"
case $COMMAND in
  init)
    echo "Assigned eth0 $SECTOR_ADDRESS from $SECTOR_CIDR"
    echo "Assigned eth1 $BACKPLANE_ADDRESS from $BACKPLANE_CIDR"
    echo "Assigned eth2 $DNS_ADDRESS from $SECTOR_CIDR"

    set -o xtrace
    
    configureFrr
    configureNftables
    configureCoreDNS
    configureDnsmasq

    mkdir -p /run/orbitlab
    touch /run/orbitlab/gateway-ready
    ;;
  add-record)
    IP="${2:-}"
    HOST="${3:-}"
    [ -z "$IP" ] && echo "sgwtool add-record IPV4_ADDRESS HOST" && exit 1
    [ -z "$HOST" ] && echo "sgwtool add-record IPV4_ADDRESS HOST" && exit 1
    /var/local/dnsmasq/dhcp-to-hosts.sh add record "$IP" "$HOST"
    ;;
  delete-record)
    IP="${2:-}"
    [ -z "$IP" ] && echo "sgwtool delete-record IPV4_ADDRESS" && exit 1
    /var/local/dnsmasq/dhcp-to-hosts.sh del record "$IP"
    ;;
  *)
    echo "Unknown command: $COMMAND" && exit 1
    ;;
esac
