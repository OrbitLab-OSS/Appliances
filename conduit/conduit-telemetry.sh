#!/bin/bash

set -eou pipefail

CONDUIT_ID="$(hostname)"
TRAEFIK_METRICS_URL="http://127.0.0.1:8080/metrics"
REPORT_URL="http://orbital-relay.orbitlab.internal/conduit/v1/health"
CHECK_INTERVAL_SECONDS=5
UNCHANGED_REPORT_INTERVAL_SECONDS=60

renderPayload() {
    curl -fsS "${TRAEFIK_METRICS_URL}" \
        | awk '
            /^traefik_service_server_up\{/ {
                service = ""
                url = ""
                status = $NF

                if (match($0, /service="[^"]+"/)) {
                    service = substr($0, RSTART + 9, RLENGTH - 10)
                }

                if (match($0, /url="[^"]+"/)) {
                    url = substr($0, RSTART + 5, RLENGTH - 6)
                }

                if (service != "" && url != "") {
                    printf "%s\t%s\t%s\n", service, url, status
                }
            }
        ' \
        | jq -Rsc --arg conduit_id "${CONDUIT_ID}" '
            {
                id: $conduit_id,
                targets: (
                    split("\n")
                    | map(select(length > 0))
                    | map(split("\t"))
                    | map({
                        service: .[0],
                        url: .[1],
                        name: (
                            .[1]
                            | sub("^https?://"; "")
                            | split("/")[0]
                            | split(":")[0]
                            | if endswith(".sector.internal") then sub("\\.sector\\.internal$"; "") else . end
                        ),
                        status: (if .[2] == "1" then "UP" else "DOWN" end)
                    })
                    | sort_by(.service, .name)
                )
            }
        '
}

postPayload() {
    local payload
    payload="${1}"

    if ! curl -fsS \
        --header 'Content-Type: application/json' \
        --data "${payload}" \
        "${REPORT_URL}" >/dev/null; then
        echo "Failed to report Conduit health to ${REPORT_URL}" >&2
        return 1
    fi
}

main() {
    local last_observed_payload
    local unchanged_checks_since_report
    local payload

    last_observed_payload=""
    unchanged_checks_since_report=0

    until curl -fsS "${TRAEFIK_METRICS_URL}" >/dev/null; do
        sleep 1
    done

    while true; do
        payload="$(renderPayload)"

        if [ "${payload}" != "${last_observed_payload}" ]; then
            unchanged_checks_since_report=0

            postPayload "${payload}" || true
        else
            unchanged_checks_since_report=$((unchanged_checks_since_report + 1))

            if [ "${unchanged_checks_since_report}" -ge $((UNCHANGED_REPORT_INTERVAL_SECONDS / CHECK_INTERVAL_SECONDS)) ]; then
                unchanged_checks_since_report=0

                postPayload "${payload}" || true
            fi
        fi

        last_observed_payload="${payload}"
        sleep "${CHECK_INTERVAL_SECONDS}"
    done
}

main
