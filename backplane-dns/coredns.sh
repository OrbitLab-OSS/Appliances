#!/bin/bash

set -eou pipefail

set -o xtrace

wget https://github.com/coredns/coredns/releases/download/v1.13.2/coredns_1.13.2_linux_amd64.tgz -O "./core-dns.tgz"
tar -xzvf "./core-dns.tgz"
