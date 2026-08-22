#!/bin/bash

set -eou pipefail

BACKPLANE_DNS_IP=$(ip addr show eth0 | grep "inet\b" | grep "brd" | awk '{print $2}')
BACKPLANE_CIDR=$(ipcalc -n "$BACKPLANE_DNS_IP" | awk '/Network/ {print $2}')

[ -f /etc/coredns/Corefile ] && exit 0
cat >/etc/coredns/Corefile <<EOL
. {
    bind lo
    bind ${BACKPLANE_DNS_IP%/*}

    acl {
        allow net ${BACKPLANE_CIDR} 127.0.0.1/32
        drop
    }

    redis {
        address /var/redis/redis-server.sock
        database 10
        prefix _internal:
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
