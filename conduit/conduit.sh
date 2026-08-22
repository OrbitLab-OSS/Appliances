#!/bin/bash

set -eou pipefail
shopt -s extglob

CONDUIT_ID="$(hostname)"
SECTOR_ID="$(printf '%s\n' "${CONDUIT_ID}" | sed -nE 's/^conduit-([A-Za-z0-9][A-Za-z0-9-]*)$/\1/p')"
LAN_INTERFACE="eth1"
LAN_ADDRESS="$(ip -o -4 addr show dev "${LAN_INTERFACE}" | awk '{print $4; exit}')"
ETCD_ENDPOINT="etcd.orbitlab.internal:2379"
ETCDCTL_BIN="/usr/bin/etcdctl"
ETCDCTL=("${ETCDCTL_BIN}" --endpoints="http://${ETCD_ENDPOINT}" --dial-timeout=3s --command-timeout=5s)
ENTRYPOINTS_PREFIX="${CONDUIT_ID}/entrypoints"
TLS_RESOLVERS_PREFIX="${CONDUIT_ID}/resolvers"
TLS_ACME_FILES_PREFIX="${CONDUIT_ID}/acme-files"
CONFIG_DIR="/etc/traefik"
CONFIG_FILE="${CONFIG_DIR}/traefik.yaml"
STATE_DIR="/var/lib/traefik"
LOG_DIR="/var/log/traefik"
CONDUIT_ENV_FILE="/etc/default/conduit"
NOTIFICATION_URL="http://orbital-relay.orbitlab.internal/notifications/v1/event"
ACME_SYNC_INTERVAL_SECONDS="30"
CONDUIT_NOTIFY_WARNINGS="1"

declare -A EMITTED_WARNINGS=()
declare -A ACME_FILE_CHECKSUMS=()

[ -n "${SECTOR_ID}" ] || { echo "Invalid conduit hostname: ${CONDUIT_ID}" >&2; exit 1; }
[ -n "${LAN_ADDRESS}" ] || { echo "No IPv4 address found on ${LAN_INTERFACE}" >&2; exit 1; }

logWarning() {
    echo "Warning: $*" >&2
}

markWarningSeen() {
    local message="${1}"

    if [ "${EMITTED_WARNINGS["${message}"]+x}" ]; then
        return 1
    fi

    EMITTED_WARNINGS["${message}"]=1
    return 0
}

emitNotification() {
    local level="${1}"
    local message="${2}"
    local payload

    payload="$(jq -cn \
        --arg level "${level}" \
        --arg message "${message}" \
        '{level: $level, message: $message}')"

    curl -fsS \
        --header 'Content-Type: application/json' \
        --data "${payload}" \
        "${NOTIFICATION_URL}" >/dev/null
}

warnOnce() {
    local message="${1}"

    if ! markWarningSeen "${message}"; then
        return 1
    fi

    logWarning "${message}"
    return 0
}

warnResolver() {
    local resolver_id="${1}"
    local detail="${2}"
    local message="Skipping TLS resolver ${resolver_id}: ${detail}"

    if warnOnce "${message}"; then
        if [ "${CONDUIT_NOTIFY_WARNINGS}" = "1" ]; then
            emitNotification WARN "${message}" || true
        fi
    fi
}

fetchEtcdPrefixJson() {
    local prefix="${1}"
    local description="${2}"

    if [ ! -x "${ETCDCTL_BIN}" ]; then
        printf '{"kvs":[]}\n'
        return 0
    fi

    if ! "${ETCDCTL[@]}" get --prefix -w json "${prefix}" 2>/dev/null; then
        logWarning "failed to fetch ${description} from etcd; continuing without them"
        printf '{"kvs":[]}\n'
    fi
}

fetchEtcdKeyJson() {
    local key="${1}"
    local description="${2}"

    if [ ! -x "${ETCDCTL_BIN}" ]; then
        printf '{"kvs":[]}\n'
        return 0
    fi

    if ! "${ETCDCTL[@]}" get -w json "${key}" 2>/dev/null; then
        logWarning "failed to fetch ${description} from etcd"
        printf '{"kvs":[]}\n'
    fi
}

storageMirrorKey() {
    local storage_path="${1}"
    local encoded_path

    encoded_path="$(printf '%s' "${storage_path}" | base64 | tr -d '\n')"
    printf '%s/%s\n' "${TLS_ACME_FILES_PREFIX}" "${encoded_path}"
}

credentialsToEnvironmentFile() {
    local credentials_json="${1}"

    jq -r '
        to_entries
        | sort_by(.key)
        | .[]
        | "\(.key)=\(.value | tojson)"
    ' <<<"${credentials_json}"
}

fetchResolverCandidates() {
    local resolvers_json

    resolvers_json="$(fetchEtcdPrefixJson "${TLS_RESOLVERS_PREFIX}" "Traefik TLS resolvers")"

    jq -cr \
        --arg prefix "${TLS_RESOLVERS_PREFIX}" '
        [
          .kvs[]?
          | {
              key: (.key | @base64d),
              value: (.value | @base64d)
            }
          | select(.key | startswith($prefix + "/"))
          | .relative_key = (.key | ltrimstr($prefix + "/"))
          | .parts = (.relative_key | split("/"))
          | select((.parts | length) == 3)
          | select(.parts[1] == "acme")
          | select(
              .parts[2] == "email"
              or .parts[2] == "storage"
              or .parts[2] == "provider"
              or .parts[2] == "credentials"
            )
          | {
              id: .parts[0],
              field: .parts[2],
              value: .value
            }
        ]
        | sort_by(.id, .field)
        | group_by(.id)
        | map(reduce .[] as $item ({id: .[0].id}; .[$item.field] = $item.value))
        | .[]
    ' <<<"${resolvers_json}"
}

buildValidatedResolverState() {
    local candidate_json
    local resolver_id
    local email
    local storage
    local provider
    local credentials_raw
    local credentials_json
    local mirror_key
    local -a valid_resolvers=()

    while IFS= read -r candidate_json; do
        [ -n "${candidate_json}" ] || continue

        resolver_id="$(jq -er '.id | strings | select(length > 0)' <<<"${candidate_json}" 2>/dev/null || true)"
        if [ -z "${resolver_id}" ]; then
            if warnOnce "Skipping TLS resolver with an empty resolver id"; then
                if [ "${CONDUIT_NOTIFY_WARNINGS}" = "1" ]; then
                    emitNotification WARN "Skipping TLS resolver with an empty resolver id" || true
                fi
            fi
            continue
        fi

        email="$(jq -er '.email | strings | select(length > 0)' <<<"${candidate_json}" 2>/dev/null || true)"
        storage="$(jq -er '.storage | strings | select(length > 0)' <<<"${candidate_json}" 2>/dev/null || true)"
        provider="$(jq -er '.provider | strings | select(length > 0)' <<<"${candidate_json}" 2>/dev/null || true)"
        credentials_raw="$(jq -er '.credentials | strings | select(length > 0)' <<<"${candidate_json}" 2>/dev/null || true)"

        if [ -z "${email}" ] || [ -z "${storage}" ] || [ -z "${provider}" ] || [ -z "${credentials_raw}" ]; then
            warnResolver "${resolver_id}" "missing or invalid required ACME settings"
            continue
        fi

        if [[ "${storage}" != /* ]]; then
            warnResolver "${resolver_id}" "acme/storage must be an absolute file path"
            continue
        fi

        if ! credentials_json="$(jq -cer '.' <<<"${credentials_raw}" 2>/dev/null)"; then
            warnResolver "${resolver_id}" "acme/credentials must be valid JSON"
            continue
        fi

        if ! jq -e '
            type == "object"
            and all(
                to_entries[]?;
                (.key | test("^[A-Za-z_][A-Za-z0-9_]*$"))
                and (.value | type == "string")
            )
        ' <<<"${credentials_json}" >/dev/null; then
            warnResolver "${resolver_id}" "acme/credentials must be a JSON object with string values keyed by valid environment variable names"
            continue
        fi

        mirror_key="$(storageMirrorKey "${storage}")"
        valid_resolvers+=("$(jq -cn \
            --arg id "${resolver_id}" \
            --arg email "${email}" \
            --arg storage "${storage}" \
            --arg provider "${provider}" \
            --arg mirror_key "${mirror_key}" \
            --argjson credentials "${credentials_json}" '
            {
              id: $id,
              email: $email,
              storage: $storage,
              provider: $provider,
              mirror_key: $mirror_key,
              credentials: $credentials
            }
        ')")
    done < <(fetchResolverCandidates)

    if [ "${#valid_resolvers[@]}" -eq 0 ]; then
        printf '[]\n'
        return 0
    fi

    printf '%s\n' "${valid_resolvers[@]}" | jq -cs 'sort_by(.id)'
}

ensureStorageParentDirectory() {
    local storage_path="${1}"
    local storage_dir

    storage_dir="$(dirname -- "${storage_path}")"
    install -d -m 0700 "${storage_dir}"
}

pushAcmeStorageFileToEtcd() {
    local resolver_id="${1}"
    local storage_path="${2}"
    local mirror_key="${3}"
    local payload

    if [ ! -f "${storage_path}" ]; then
        return 0
    fi

    if ! payload="$(base64 -w0 < "${storage_path}" 2>/dev/null)"; then
        logWarning "failed to read ACME storage file for resolver ${resolver_id} at ${storage_path}"
        return 1
    fi

    if ! "${ETCDCTL[@]}" put "${mirror_key}" "${payload}" >/dev/null 2>&1; then
        logWarning "failed to mirror ACME storage file for resolver ${resolver_id} into etcd"
        return 1
    fi
}

restoreAcmeStorageFileFromEtcd() {
    local resolver_id="${1}"
    local storage_path="${2}"
    local mirror_key="${3}"
    local mirror_json
    local payload
    local count
    local temp_file

    mirror_json="$(fetchEtcdKeyJson "${mirror_key}" "mirrored ACME storage file for resolver ${resolver_id}")"
    count="$(jq -r '.count // 0' <<<"${mirror_json}" 2>/dev/null || printf '0\n')"
    if [ "${count}" = "0" ]; then
        return 1
    fi

    if ! payload="$(jq -er '.kvs[0].value | @base64d' <<<"${mirror_json}" 2>/dev/null)"; then
        logWarning "failed to read mirrored ACME storage payload for resolver ${resolver_id} from etcd"
        return 1
    fi

    temp_file="$(mktemp)"
    if ! printf '%s' "${payload}" | base64 -d > "${temp_file}" 2>/dev/null; then
        logWarning "failed to decode mirrored ACME storage payload for resolver ${resolver_id}"
        rm -f "${temp_file}"
        return 1
    fi

    if ! install -m 0600 "${temp_file}" "${storage_path}"; then
        logWarning "failed to restore ACME storage file for resolver ${resolver_id} at ${storage_path}"
        rm -f "${temp_file}"
        return 1
    fi

    rm -f "${temp_file}"
}

prepareResolversForRender() {
    local resolver_state_json="${1}"
    local resolver_json
    local resolver_id
    local storage_path
    local mirror_key
    local -a prepared_resolvers=()

    while IFS= read -r resolver_json; do
        [ -n "${resolver_json}" ] || continue

        resolver_id="$(jq -r '.id' <<<"${resolver_json}")"
        storage_path="$(jq -r '.storage' <<<"${resolver_json}")"
        mirror_key="$(jq -r '.mirror_key' <<<"${resolver_json}")"

        if ! ensureStorageParentDirectory "${storage_path}"; then
            warnResolver "${resolver_id}" "failed to create parent directory for acme/storage at ${storage_path}"
            continue
        fi

        if [ -e "${storage_path}" ] && [ ! -f "${storage_path}" ]; then
            warnResolver "${resolver_id}" "acme/storage path ${storage_path} exists but is not a regular file"
            continue
        fi

        if [ -f "${storage_path}" ]; then
            chmod 0600 "${storage_path}" 2>/dev/null || true
            pushAcmeStorageFileToEtcd "${resolver_id}" "${storage_path}" "${mirror_key}" || true
        else
            restoreAcmeStorageFileFromEtcd "${resolver_id}" "${storage_path}" "${mirror_key}" || true
            if [ -f "${storage_path}" ]; then
                chmod 0600 "${storage_path}" 2>/dev/null || true
            fi
        fi

        prepared_resolvers+=("${resolver_json}")
    done < <(jq -cr '.[]' <<<"${resolver_state_json}")

    if [ "${#prepared_resolvers[@]}" -eq 0 ]; then
        printf '[]\n'
        return 0
    fi

    printf '%s\n' "${prepared_resolvers[@]}" | jq -cs 'sort_by(.id)'
}

renderSynthesizedEntryPoints() {
    local entrypoints_json

    entrypoints_json="$(fetchEtcdPrefixJson "${ENTRYPOINTS_PREFIX}" "additional Traefik entryPoints")"

    if ! jq -r \
        --arg address "${LAN_ADDRESS%/*}" \
        --arg entrypoints_prefix "${ENTRYPOINTS_PREFIX}" '
        [
          .kvs[]?
          | {
              key: (.key | @base64d),
              value: (.value | @base64d)
            }
          | select(.key | startswith($entrypoints_prefix + "/"))
          | .relative_key = (.key | ltrimstr($entrypoints_prefix + "/"))
          | select((.relative_key | split("/")) | length == 2)
          | select(.relative_key | split("/")[1] == "port")
          | {
              name: (.relative_key | split("/")[0]),
              port: .value
            }
          | select(.name != "web" and .name != "traefik")
          | select(.port | test("^[0-9]+(/udp)?$"))
        ]
        | sort_by(.name)
        | .[]
        | "  \(.name):\n    address: \"\($address):\(.port)\""
    ' <<<"${entrypoints_json}"; then
        logWarning "failed to render additional Traefik entryPoints from etcd; continuing with static entryPoints only"
        return 0
    fi
}

renderSynthesizedCertificatesResolvers() {
    local resolver_state_json="${1}"
    local resolver_json
    local resolver_id_json
    local email_json
    local storage_json
    local provider_json

    while IFS= read -r resolver_json; do
        [ -n "${resolver_json}" ] || continue

        resolver_id_json="$(jq -c '.id' <<<"${resolver_json}")"
        email_json="$(jq -c '.email' <<<"${resolver_json}")"
        storage_json="$(jq -c '.storage' <<<"${resolver_json}")"
        provider_json="$(jq -c '.provider' <<<"${resolver_json}")"

        cat <<EOF
  ${resolver_id_json}:
    acme:
      email: ${email_json}
      storage: ${storage_json}
      dnsChallenge:
        provider: ${provider_json}
EOF
    done < <(jq -cr '.[]' <<<"${resolver_state_json}")
}

renderConfig() {
    local resolver_state_json="${1}"
    local synthesized_entrypoints
    local synthesized_resolvers

    synthesized_entrypoints="$(renderSynthesizedEntryPoints)"
    synthesized_resolvers="$(renderSynthesizedCertificatesResolvers "${resolver_state_json}")"

    cat <<EOF
global:
  checkNewVersion: false
  sendAnonymousUsage: false

api:
  dashboard: true
  insecure: true

ping: {}

log:
  level: INFO
  format: json
  filePath: "${LOG_DIR}/traefik.log"

accessLog:
  format: json
  filePath: "${LOG_DIR}/access.log"
  bufferingSize: 100

entryPoints:
  web:
    address: "${LAN_ADDRESS%/*}:80"
    asDefault: true
  websecure:
    address: "${LAN_ADDRESS%/*}:443"
    asDefault: true
  traefik:
    address: ":8080"
${synthesized_entrypoints:+${synthesized_entrypoints}}

${synthesized_resolvers:+certificatesResolvers:
${synthesized_resolvers}
}
http:
  routers:
    dashboard:
      rule: "PathPrefix(\`/api\`) || PathPrefix(\`/dashboard\`)"
      service: api@internal

metrics:
  prometheus:
    entryPoint: traefik

providers:
  providersThrottleDuration: 2s
  etcd:
    endpoints:
      - ${ETCD_ENDPOINT}
    rootKey: ${CONDUIT_ID}
EOF
}

installRuntimeDirectories() {
    install -d -m 0755 "${CONFIG_DIR}" "${STATE_DIR}" "${LOG_DIR}"
    install -d -m 0755 "$(dirname -- "${CONDUIT_ENV_FILE}")"
}

installEnvironmentFile() {
    local resolver_state_json="${1}"
    local temp_environment_file
    local resolver_json
    local credentials_json

    temp_environment_file="$(mktemp)"
    : > "${temp_environment_file}"

    while IFS= read -r resolver_json; do
        [ -n "${resolver_json}" ] || continue

        credentials_json="$(jq -c '.credentials' <<<"${resolver_json}")"
        credentialsToEnvironmentFile "${credentials_json}" >> "${temp_environment_file}"
    done < <(jq -cr '.[]' <<<"${resolver_state_json}")

    install -m 0600 "${temp_environment_file}" "${CONDUIT_ENV_FILE}"
    rm -f "${temp_environment_file}"
}

installConfig() {
    local resolver_state_json="${1}"
    local temp_config

    temp_config="$(mktemp)"

    renderConfig "${resolver_state_json}" > "${temp_config}"

    if [ -f "${CONFIG_FILE}" ] && cmp -s "${temp_config}" "${CONFIG_FILE}"; then
        rm -f "${temp_config}"
        return 0
    fi

    install -m 0644 "${temp_config}" "${CONFIG_FILE}"
    rm -f "${temp_config}"
}

syncAcmeFilesOnce() {
    local resolver_state_json="${1}"
    local resolver_json
    local resolver_id
    local storage_path
    local mirror_key
    local checksum
    local -A current_paths=()

    while IFS= read -r resolver_json; do
        [ -n "${resolver_json}" ] || continue

        resolver_id="$(jq -r '.id' <<<"${resolver_json}")"
        storage_path="$(jq -r '.storage' <<<"${resolver_json}")"
        mirror_key="$(jq -r '.mirror_key' <<<"${resolver_json}")"
        current_paths["${storage_path}"]=1

        if ! ensureStorageParentDirectory "${storage_path}"; then
            logWarning "failed to create parent directory for ACME storage path ${storage_path}"
            continue
        fi

        if [ -e "${storage_path}" ] && [ ! -f "${storage_path}" ]; then
            logWarning "ACME storage path ${storage_path} for resolver ${resolver_id} exists but is not a regular file"
            continue
        fi

        if [ ! -f "${storage_path}" ]; then
            unset 'ACME_FILE_CHECKSUMS["'"${storage_path}"'"]'
            continue
        fi

        chmod 0600 "${storage_path}" 2>/dev/null || true
        checksum="$(sha256sum "${storage_path}" | awk '{print $1}')"
        if [ "${ACME_FILE_CHECKSUMS["${storage_path}"]-}" = "${checksum}" ]; then
            continue
        fi

        if pushAcmeStorageFileToEtcd "${resolver_id}" "${storage_path}" "${mirror_key}"; then
            ACME_FILE_CHECKSUMS["${storage_path}"]="${checksum}"
        fi
    done < <(jq -cr '.[]' <<<"${resolver_state_json}")

    for storage_path in "${!ACME_FILE_CHECKSUMS[@]}"; do
        if [ -z "${current_paths["${storage_path}"]+x}" ]; then
            unset 'ACME_FILE_CHECKSUMS["'"${storage_path}"'"]'
        fi
    done
}

watchAcmeFiles() {
    local resolver_state_json

    installRuntimeDirectories

    while true; do
        resolver_state_json="$(buildValidatedResolverState)"
        syncAcmeFilesOnce "${resolver_state_json}"
        sleep "${ACME_SYNC_INTERVAL_SECONDS}"
    done
}

installConduitConfig() {
    local resolver_state_json

    installRuntimeDirectories
    resolver_state_json="$(buildValidatedResolverState)"
    resolver_state_json="$(prepareResolversForRender "${resolver_state_json}")"
    installEnvironmentFile "${resolver_state_json}"
    installConfig "${resolver_state_json}"
}

main() {
    local command="${1:-render}"

    case "${command}" in
        render)
            installConduitConfig
            ;;
        watch-acme)
            watchAcmeFiles
            ;;
        *)
            echo "Unknown command: ${command}" >&2
            exit 1
            ;;
    esac
}

main "$@"
