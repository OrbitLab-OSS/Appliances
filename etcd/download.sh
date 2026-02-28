#!/bin/bash

set -eou pipefail

ETCD_VER=v3.6.8

set -o xtrace

# Download
curl -L "https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz" -o etcd.tar.gz
# Make extract dir
mkdir etcd-extract
# extract
tar xzvf etcd.tar.gz -C etcd-extract --strip-components=1 --no-same-owner
# Move binaries for easier use
mv etcd-extract/etcd .
mv etcd-extract/etcdctl .
mv etcd-extract/etcdutl .
# Cleanup
rm -f etcd.tar.gz
rm -rf etcd-extract
