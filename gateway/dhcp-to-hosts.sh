#!/bin/sh

ACTION="$1"
IP="$3"
HOST="$4"
TMP="$(mktemp)"

HOSTS_FILE="/var/local/dnsmasq/sector.hosts"
DOMAIN="sector.internal"

[ -f "$HOSTS_FILE" ] || touch "$HOSTS_FILE"

cp "$HOSTS_FILE" "$TMP"

case "$ACTION" in
  add|old)
    sed -i "/[[:space:]]$HOST\./d" "$TMP"
    echo "$IP $HOST.$DOMAIN $HOST" >> "$TMP"
    ;;
  del)
    sed -i "/^$IP[[:space:]]/d" "$TMP"
    ;;
esac

mv "$TMP" "$HOSTS_FILE"
