FROM golang:1.25 AS builder

WORKDIR /build

RUN wget https://github.com/coredns/coredns/archive/refs/tags/v1.14.2.tar.gz -O core-dns.tgz && \
    tar -xzvf './core-dns.tgz' --strip-components 1 -C /build
COPY coredns/plugin.cfg /build/plugin.cfg
RUN GOFLAGS='-buildvcs=false' make

FROM scratch AS artifact
COPY --from=builder /build/coredns /coredns
