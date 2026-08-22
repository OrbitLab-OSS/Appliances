#!/bin/bash

set -eou pipefail

WARDLINK_ID="$(hostname)"
SECTOR_ID="$(printf '%s\n' "${WARDLINK_ID}" | sed -nE 's/^wardlink-([A-Za-z0-9][A-Za-z0-9-]*)$/\1/p')"
[ -n "${SECTOR_ID}" ] || { echo "Invalid WardLink hostname: ${WARDLINK_ID}" >&2; exit 1; }

ETCDCTL=(/usr/bin/etcdctl --endpoints="http://etcd.orbitlab.internal:2379" --dial-timeout=3s --command-timeout=5s)
INTERFACE_PREFIX="wardlink/${SECTOR_ID}/interface"
PEERS_PREFIX="wardlink/${SECTOR_ID}/peers"

INTERFACE_PRIVATE_KEY="$("${ETCDCTL[@]}" get --print-value-only "${INTERFACE_PREFIX}/private-key" 2>/dev/null)"
[ -n "${INTERFACE_PRIVATE_KEY}" ] || { echo "No interface private key at ${INTERFACE_PREFIX}/private-key" >&2; exit 1; }

INTERFACE_ADDRESS="$("${ETCDCTL[@]}" get --print-value-only "${INTERFACE_PREFIX}/address" 2>/dev/null)"
[ -n "${INTERFACE_ADDRESS}" ] || { echo "No interface address at ${INTERFACE_PREFIX}/address" >&2; exit 1; }

getPeerBlocks() {
    local prefix_output key value index public_key allowed_ips peer_blocks
    declare -A peer_indices=()
    declare -A peer_public_keys=()
    declare -A peer_addresses=()

    if ! prefix_output="$("${ETCDCTL[@]}" get --prefix "${PEERS_PREFIX}" 2>/dev/null)"; then
        return 1
    fi

    peer_blocks=""
    while IFS= read -r key || [ -n "${key}" ]; do
        if ! IFS= read -r value; then
            value=""
        fi

        case "${key}" in
            "${PEERS_PREFIX}"/*/public-key)
                index="${key#${PEERS_PREFIX}/}"
                index="${index%/public-key}"
                if [[ "${index}" =~ ^[0-9]+$ ]]; then
                    peer_indices["${index}"]=1
                    peer_public_keys["${index}"]="${value}"
                fi
                ;;
            "${PEERS_PREFIX}"/*/address)
                index="${key#${PEERS_PREFIX}/}"
                index="${index%/address}"
                if [[ "${index}" =~ ^[0-9]+$ ]]; then
                    peer_indices["${index}"]=1
                    peer_addresses["${index}"]="${value}"
                fi
                ;;
        esac
    done <<< "${prefix_output}"

    if [ "${#peer_indices[@]}" -eq 0 ]; then
        printf ''
        return 0
    fi

    while IFS= read -r index; do
        [ -n "${index}" ] || continue

        public_key="${peer_public_keys["${index}"]-}"
        allowed_ips="${peer_addresses["${index}"]-}"

        if [ -z "${public_key}" ] || [ -z "${allowed_ips}" ]; then
            continue
        fi

        peer_blocks+=$'[Peer]\n'
        peer_blocks+="PublicKey = ${public_key}"$'\n'
        peer_blocks+="AllowedIPs = ${allowed_ips}"$'\n\n'
    done < <(printf '%s\n' "${!peer_indices[@]}" | sort -n)

    printf '%s' "${peer_blocks}"
}

configureWireGuard() {
    local lanAddress cidr
    
    lanAddress="$(ip -o -4 addr show dev eth1 | awk '{print $4; exit}')"
    cidr="$(ipcalc -n "${INTERFACE_ADDRESS}" | awk '/Network/ {print $2}')"

    echo "Generating WireGuard wg0 config for ${INTERFACE_ADDRESS}"
    cat >/etc/wireguard/wg0.conf <<EOL
[Interface]
PrivateKey = ${INTERFACE_PRIVATE_KEY}
Address = ${INTERFACE_ADDRESS}
ListenPort = 51820

PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = nft -f /etc/wireguard/sector-access.nft
PostDown = nft delete table inet orbitlab_sector_access || true
EOL

    echo "Generating WireGuard nftables config for address ${lanAddress%/*} and cidr ${cidr}"
    cat >/etc/wireguard/sector-access.nft <<EOL
table inet orbitlab_sector_access {
    chain input {
        type filter hook input priority 0;
        policy accept;
        
        iifname "eth1" ip daddr ${lanAddress%/*} udp dport 51820 accept
        udp dport 51820 drop
    }

    chain forward {
        type filter hook forward priority 0;
        policy drop;
        
        iifname "wg0" oifname "eth0" udp dport 53 accept
        iifname "wg0" oifname "eth0" tcp dport 53 accept
        iifname "wg0" oifname "eth0" tcp dport 22 accept
        iifname "wg0" oifname "eth0" ip protocol icmp accept
        iifname "eth0" oifname "wg0" ct state established,related accept
    }

    chain postrouting {
        type nat hook postrouting priority srcnat;
        oifname "eth0" ip saddr ${cidr} masquerade
    }
}
EOL
    sync
}

writePeersConfig() {
    local peers
    peers="${1}"

    cat >/etc/wireguard/peers.conf <<EOL
[Interface]
PrivateKey = ${INTERFACE_PRIVATE_KEY}
ListenPort = 51820

${peers}
EOL
}

watchPeers() {
    currentFingerprint=""
    newFingerprint=""

    while true; do
        peers="$(getPeerBlocks)"
        newFingerprint="$(echo -n "${peers}" | sha256sum | awk '{print $1}')"

        if [ "$newFingerprint" != "$currentFingerprint" ]; then
            echo "Peer Count: $(echo "${peers}" | grep -Fx '[Peer]' | wc -l)"
            writePeersConfig "${peers}"
            sync
            currentFingerprint="$newFingerprint"
            /usr/bin/wg syncconf wg0 /etc/wireguard/peers.conf
            echo "Updated $currentFingerprint"
        fi

        sleep 10
    done
}

cleanup() {
    /usr/bin/wg-quick down wg0 || true
}

trap "cleanup" EXIT INT TERM
configureWireGuard
/usr/bin/wg-quick up wg0
watchPeers
