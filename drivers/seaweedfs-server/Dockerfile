# SeaweedFS server image built from the local neBM checkout so the current
# vidMap stale-entry invalidation fix reaches the running master / filer /
# volume / s3 binaries.
#
# The build context is injected from the local SeaweedFS repo by the
# cluster-state Makefile. That keeps this sideload path offline and avoids
# depending on an unpublished remote ref.
ARG SEAWEEDFS_COMMIT=local
ARG BUILDPLATFORM

FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS builder

RUN apk add --no-cache g++

ARG SEAWEEDFS_COMMIT
ARG TARGETOS
ARG TARGETARCH
COPY --from=seaweedfs . /go/src/github.com/seaweedfs/seaweedfs

RUN cd /go/src/github.com/seaweedfs/seaweedfs/weed \
    && export LDFLAGS="-X github.com/seaweedfs/seaweedfs/weed/util/version.COMMIT=${SEAWEEDFS_COMMIT}" \
    && CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH:-amd64} go build -ldflags "-extldflags -static ${LDFLAGS}" -o /go/bin/weed . \
    && go clean -cache -modcache

FROM alpine:3.24 AS final
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
