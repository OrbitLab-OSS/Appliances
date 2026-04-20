#!/bin/bash

set -eou pipefail

BACKPLANE_DNS_IP=$(ip addr show eth0 | grep "inet\b" | grep "brd" | awk '{print $2}')
BACKPLANE_CIDR=$(ipcalc -n "$BACKPLANE_DNS_IP" | awk '/Network/ {print $2}')
# VMBR0_DNS_IP=$(ip addr show eth1 | grep "inet\b" | grep "brd" | awk '{print $2}')
# VMBR0_CIDR=$(ipcalc -n "$VMBR0_DNS_IP" | awk '/Network/ {print $2}')

[ -f /etc/coredns/Corefile ] && exit 0
cat >/etc/coredns/Corefile <<EOL
. {
    bind ${BACKPLANE_DNS_IP%/*}

    acl {
        allow net ${BACKPLANE_CIDR}
        drop
    }

    redis {
        address /var/redis/redis-server.sock
        database 10
        prefix _internal:
    }

    forward . /etc/resolv.conf {
        policy sequential
        max_concurrent 1000
    }

    log
    errors
}
EOL
# The Corefile server block below is for DNS resolution from the LAN outside of Proxmox (vmbr0)
# Keeping this here for now until support is enabled.
# . {

#     bind ${VMBR0_DNS_IP%/*}

#     acl {
#         allow net ${VMBR0_CIDR}
#         drop
#     }

#     redis {
#         address /var/redis/redis-server.sock
#         database 10
#         prefix _external:
#     }

#     forward . /etc/resolv.conf {
#         policy sequential
#         max_concurrent 1000
#     }

#     log
#     errors
# }
