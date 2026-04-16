# SeaweedFS server image built from the neBM fork so the vidMap stale-entry
# invalidation fix (ReadChunkWithReLookup) reaches the running master /
# filer / volume / s3 binaries. Mirrors the pin pattern used in the
# sibling drivers/seaweedfs-csi-driver/cmd/seaweedfs-mount/Dockerfile.
#
# Override for upstream-merge cleanup:
#   docker build --build-arg SEAWEEDFS_COMMIT=<merged-sha> --build-arg SEAWEEDFS_REPO=https://github.com/seaweedfs/seaweedfs
ARG SEAWEEDFS_COMMIT=d4cb0322979c80e9ba4fe614db118f5bb70aaee1
ARG SEAWEEDFS_REPO=https://github.com/neBM/seaweedfs

FROM golang:1.25-alpine AS builder

RUN apk add --no-cache git g++

ARG SEAWEEDFS_COMMIT
ARG SEAWEEDFS_REPO
RUN git clone ${SEAWEEDFS_REPO} /go/src/github.com/seaweedfs/seaweedfs \
    && cd /go/src/github.com/seaweedfs/seaweedfs \
    && git checkout ${SEAWEEDFS_COMMIT}

RUN cd /go/src/github.com/seaweedfs/seaweedfs/weed \
    && export LDFLAGS="-X github.com/seaweedfs/seaweedfs/weed/util/version.COMMIT=$(git -C /go/src/github.com/seaweedfs/seaweedfs rev-parse --short HEAD)" \
    && CGO_ENABLED=0 go install -ldflags "-extldflags -static ${LDFLAGS}" \
    && go clean -cache -modcache

FROM alpine:3.23 AS final
LABEL author="Chris Lu"
COPY --from=builder /go/bin/weed /usr/bin/
RUN mkdir -p /etc/seaweedfs
COPY --from=builder /go/src/github.com/seaweedfs/seaweedfs/docker/filer.toml /etc/seaweedfs/filer.toml
COPY --from=builder /go/src/github.com/seaweedfs/seaweedfs/docker/entrypoint.sh /entrypoint.sh

RUN apk upgrade --no-cache zlib && \
    apk add --no-cache fuse curl su-exec && \
    addgroup -g 1000 seaweed && \
    adduser -D -u 1000 -G seaweed seaweed

# volume grpc / http
EXPOSE 18080 8080
# filer grpc / http
EXPOSE 18888 8888
# master grpc / http
EXPOSE 19333 9333
# s3 http
EXPOSE 8333
# webdav http
EXPOSE 7333

RUN mkdir -p /data/filerldb2 && \
    chown -R seaweed:seaweed /data && \
    chown -R seaweed:seaweed /etc/seaweedfs && \
    chmod 755 /entrypoint.sh

VOLUME /data
WORKDIR /data

ENTRYPOINT ["/entrypoint.sh"]
