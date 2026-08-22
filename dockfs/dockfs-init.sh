#!/bin/bash

set -eou pipefail

ETCDCTL=(/usr/bin/etcdctl --endpoints="http://etcd.orbitlab.internal:2379" --dial-timeout=3s --command-timeout=5s)
NAMESPACE="/orbitlab/services/dockfs"
KEEPALIVED_CONFIG=/etc/keepalived/keepalived.conf
STATE_DIR=/var/lib/dockfs
CONFIG_RETRY_COUNT=30
CONFIG_RETRY_DELAY_SECONDS=2

HOSTNAME="$(hostname)"
CLUSTER_ID="${HOSTNAME%-*}"

fetchConfig() {
    local attempt
    local config

    for attempt in $(seq 1 "${CONFIG_RETRY_COUNT}"); do
        config="$("${ETCDCTL[@]}" get --print-value-only "${NAMESPACE}/${CLUSTER_ID}/orbitlab-config" || true)"
        if [ -n "${config}" ]; then
            printf '%s\n' "${config}"
            return 0
        fi

        sleep "${CONFIG_RETRY_DELAY_SECONDS}"
    done

    echo "No config from etcd for ${CLUSTER_ID}" >&2
    return 1
}

validateConfig() {
    local config
    config="${1}"

    echo "${config}" | jq -e '
        (.keepalived_password | type == "string" and length > 0)
        and (.virtual_router_id | type == "number")
        and (.vip | type == "string" and length > 0)
    ' >/dev/null
}

renderKeepalivedConfig() {
    local auth_secret
    local virtual_router_id
    local vip

    auth_secret="$(echo "${1}" | jq -r '.keepalived_password')"
    virtual_router_id="$(echo "${1}" | jq -r '.virtual_router_id')"
    vip="$(echo "${1}" | jq -r '.vip')"

    cat <<EOL
global_defs {
    router_id DOCKFS
    enable_script_security
    script_user root
}
vrrp_script dockfs_ready {
    script "/usr/bin/dockfs-check"
    interval 2
    fall 2
    rise 2
}
vrrp_instance DOCKFS_VIP {
    state BACKUP
    interface eth0
    virtual_router_id ${virtual_router_id}
    priority 100
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass ${auth_secret}
    }

    virtual_ipaddress {
        ${vip}
    }

    track_script {
        dockfs_ready
    }

    notify_fault "/usr/bin/dockfs-notify"
}
EOL
}

installKeepalivedConfig() {
    local config
    local temp_config

    config="${1}"
    temp_config="$(mktemp)"
    renderKeepalivedConfig "${config}" >"${temp_config}"

    if [ -f "${KEEPALIVED_CONFIG}" ] && cmp -s "${temp_config}" "${KEEPALIVED_CONFIG}"; then
        rm -f "${temp_config}"
        return 1
    fi

    install -m0644 "${temp_config}" "${KEEPALIVED_CONFIG}"
    rm -f "${temp_config}"
    return 0
}

main() {
    local config
    local config_changed

    mkdir -p "${STATE_DIR}"

    config="$(fetchConfig)"
    validateConfig "${config}"

    /usr/bin/dockfs-datadisk-config reconcile

    config_changed=0
    if installKeepalivedConfig "${config}"; then
        config_changed=1
    fi

    systemctl enable keepalived >/dev/null
    if systemctl is-active --quiet keepalived; then
        if [ "${config_changed}" -eq 1 ]; then
            systemctl restart keepalived
        fi
    else
        systemctl start keepalived
    fi
}

main
