#!/bin/bash

set -eou pipefail

TRAEFIK_VERSION=v3.7.1
TRAEFIK_ARCHIVE="traefik_${TRAEFIK_VERSION}_linux_amd64.tar.gz"
TRAEFIK_SHA256=e92bcfb03fa1e6a70c4e7ad4eb4f1604967e6fa3c21d8e7605aca5407a40162c

set -o xtrace

curl -fsSLo traefik.tar.gz \
    "https://github.com/traefik/traefik/releases/download/${TRAEFIK_VERSION}/${TRAEFIK_ARCHIVE}"
echo "${TRAEFIK_SHA256}  traefik.tar.gz" | sha256sum -c -
mkdir -p traefik-extract
tar xzvf traefik.tar.gz -C traefik-extract --no-same-owner
mv traefik-extract/traefik .
rm -f traefik.tar.gz
rm -rf traefik-extract
