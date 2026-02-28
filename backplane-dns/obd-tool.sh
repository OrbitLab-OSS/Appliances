#!/bin/bash

set -eou pipefail

createZoneFile() {
    local zone_type="$1"
    local dns_address="$2"
    cat >"/etc/coredns/$zone_type.zone" <<EOL
\$ORIGIN orbitlab.internal.
@	3600 IN	SOA ns.orbitlab.internal. admin.orbitlab.internal. 2026021801 3600 900 1209600 300

ns.orbitlab.internal. 300 IN A $dns_address
EOL
}

initializeBackplaneDNS() {
    [ -f /etc/coredns/Corefile ] && return 0
    local ADDRESS=$(ip addr show eth0 | grep "inet\b" | grep "brd" | awk '{print $2}' | cut -d'/' -f1)
    local CIDR="$(ipcalc -n $ADDRESS | awk '/Network/ {print $2}')"
    createZoneFile internal "${ADDRESS%/*}"
    createZoneFile external "${ADDRESS%/*}"
    createCorefile
}

createCorefile() {
    cat >/etc/coredns/Corefile <<EOL
. {
    view Internal {
        expr incidr(client_ip(), '$CIDR')
    }

    file /etc/coredns/internal.zone orbitlab.internal {
        reload 30s
        fallthrough
    }

    forward . /etc/resolv.conf {
        policy sequential
        max_concurrent 1000
    }

    cache 30
    reload
    log
    errors
    health
    ready
}
EOL
}

enableExternal() {
    cat >>/etc/coredns/Corefile <<EOL
. {

    file /etc/coredns/external.zone orbitlab.internal {
        reload 30s
        fallthrough
    }

    forward . /etc/resolv.conf {
        policy sequential
        max_concurrent 1000
    }

    cache 30
    reload
    log
    errors
    health
    ready
}
EOL
    systemctl restart coredns
}

getZoneFile() {
    local zone_type="$1"
    case "$zone_type" in
        internal)
            echo "/etc/coredns/internal.zone"
            ;;
        external)
            echo "/etc/coredns/external.zone"
            ;;
    esac
}

addRecord() {
    local zone_type="$1"
    local address="$2"
    local hostname="$3"
    zone_file=$(getZoneFile "$zone_type")
    echo "$hostname.orbitlab.internal. 300 IN A $address" >> "$zone_file"
}

cascadeDelete() {
    local address="$1"
    local zone_file="$2"
    local hosts=$(awk -v ip="$address" '$0 !~ /^;/ && $4 == "A" && $5 == ip { print $1 }' "$zone_file")
    [ -z "$hosts" ] && exit 0
    awk -v hosts="$hosts" -v ip="$address" '{ if ($4 == "A" && $5 == ip) next }{ if ($4 == "CNAME" && match(hosts, $5)) next }{ print }' "$zone_file" > "$zone_file.tmp"
    mv "$zone_file.tmp" "$zone_file"
}

deleteRecord() {
    local zone_type="$1"
    local address="$2"
    zone_file=$(getZoneFile "$zone_type")
    cascadeDelete "$address" "$zone_file"
}

addCname() {
    local zone_type="$1"
    local hostname="$2"
    local cname="$3"
    zone_file=$(getZoneFile "$zone_type")
    echo "$cname.orbitlab.internal. 300 IN CNAME $hostname.orbitlab.internal" >> "$zone_file"
}

deleteCname() {
    local zone_type="$1"
    local cname="$2"
    zone_file=$(getZoneFile "$zone_type")
    awk -v cname="$cname" '{ if ($4 == "CNAME" && match($1, cname)) next }{ print }' "$zone_file" > "$zone_file.tmp"
    mv "$zone_file.tmp" "$zone_file"
}

addSrv() {
    local service="$1"
    local proto="$2"
    local port="$3"
    local target="$4"
    zone_file=$(getZoneFile "internal")
    echo "_$service._$proto.orbitlab.internal. 300 IN SRV 0 0 $port $target.orbitlab.internal." >> "$zone_file"
}

deleteSrv() {
    local service="$1"
    local proto="$2"
    local port="$3"
    local target="$4"
    zone_file=$(getZoneFile "internal")
    awk -v record="_$service._$proto.orbitlab.internal." -v port="$port" -v target="$target.orbitlab.internal." \
        '{ if ($1 == record && $4 == "SRV" && $7 == port && $8 == target) next }{ print }' "$zone_file" > "$zone_file.tmp"
    mv "$zone_file.tmp" "$zone_file"
}

checkArg() {
    local arg="$1"
    local help="$2"
    local zone_type="$3"
    [ -z "$arg" ] && echo "$help" && exit 1
    if [ -n "$zone_type" ]; then
        [ "$arg" == "internal" ] && return
        [ "$arg" == "external" ] && return
        echo "$help" && exit 1
    fi
}


COMMAND="${1:-}"

case "$COMMAND" in
    init)
        initializeBackplaneDNS
        ;;
    add-record)
        ZONE_TYPE="$2"
        ADDRESS="$3"
        HOSTNAME="$4"
        checkArg "$ZONE_TYPE" "obd-tool add-record [internal|external] IPV4_ADDRESS HOSTNAME" "zone-type"
        checkArg "$ADDRESS" "obd-tool add-record [internal|external] IPV4_ADDRESS HOSTNAME" ""
        checkArg "$HOSTNAME" "obd-tool add-record [internal|external] IPV4_ADDRESS HOSTNAME" ""
        addRecord "$ZONE_TYPE" "$ADDRESS" "$HOSTNAME"
        ;;
    delete-record)
        ZONE_TYPE="$2"
        ADDRESS="$3"
        checkArg "$ZONE_TYPE" "obd-tool delete-record [internal|external] IPV4_ADDRESS" "zone-type"
        checkArg "$ADDRESS" "obd-tool delete-record [internal|external] IPV4_ADDRESS" ""
        deleteRecord "$ZONE_TYPE" "$ADDRESS"
        ;;
    add-cname)
        ZONE_TYPE="$2"
        HOSTNAME="$3"
        CNAME="$4"
        checkArg "$ZONE_TYPE" "obd-tool add-cname [internal|external] HOSTNAME CNAME" "zone-type"
        checkArg "$HOSTNAME" "obd-tool add-cname [internal|external] HOSTNAME CNAME" ""
        checkArg "$CNAME" "obd-tool add-cname [internal|external] HOSTNAME CNAME" ""
        addCname "$ZONE_TYPE" "$HOSTNAME" "$CNAME"
        ;;
    delete-cname)
        ZONE_TYPE="$2"
        CNAME="$3"
        checkArg "$ZONE_TYPE" "obd-tool delete-cname [internal|external] CNAME" "zone-type"
        checkArg "$CNAME" "obd-tool delete-cname [internal|external] CNAME" ""
        deleteCname "$ZONE_TYPE" "$CNAME"
        ;;
    add-srv)
        SERVICE="$2"
        PROTOCOL="$3"
        PORT="$4"
        TARGET="$5"
        checkArg "$SERVICE" "obd-tool add-srv SERVICE PROTOCOL PORT TARGET" ""
        checkArg "$PROTOCOL" "obd-tool add-srv SERVICE PROTOCOL PORT TARGET" ""
        checkArg "$PORT" "obd-tool add-srv SERVICE PROTOCOL PORT TARGET" ""
        checkArg "$TARGET" "obd-tool add-srv SERVICE PROTOCOL PORT TARGET" ""
        addSrv "$SERVICE" "$PROTOCOL" "$PORT" "$TARGET"
        ;;
    delete-srv)
        SERVICE="$2"
        PROTOCOL="$3"
        PORT="$4"
        TARGET="$5"
        checkArg "$SERVICE" "obd-tool delete-srv SERVICE PROTOCOL PORT TARGET" ""
        checkArg "$PROTOCOL" "obd-tool delete-srv SERVICE PROTOCOL PORT TARGET" ""
        checkArg "$PORT" "obd-tool delete-srv SERVICE PROTOCOL PORT TARGET" ""
        checkArg "$TARGET" "obd-tool delete-srv SERVICE PROTOCOL PORT TARGET" ""
        deleteSrv "$SERVICE" "$PROTOCOL" "$PORT" "$TARGET"
        ;;
    enable-external)
        grep -q "/etc/coredns/external.zone" /etc/coredns/Corefile || enableExternal
        ;;
    disable-external)
        createCorefile
        systemctl restart coredns
        ;;
    '')
        echo "obd-tool COMMAND [ARGUMENTS]"
        echo
        echo "Available Commands: "
        echo
        echo "init                  Initialize Backplane DNS"
        echo "add-record            Add an 'A' Record"
        echo "delete-record         Delete an 'A' Record and any referenced 'CNAME' records"
        echo "add-cname             Add an 'CNAME' Record"
        echo "delete-cname          Delete an 'CNAME' Record"
        echo "enable-external       Enable the external (vmbr0) zone"
        echo "disable-external      Disable the external (vmbr0) zone"
        echo
        echo "All HOSTNAME and CNAME arguments should not include the '.orbitlab.internal' as part of the string."
        echo "All IPV4_ADDRESS arguments should be given without prefix length (e.g. 192.168.0.1)"
        ;;
    *)
        echo "Unknown command: $COMMAND" || exit 1
        ;;
esac
