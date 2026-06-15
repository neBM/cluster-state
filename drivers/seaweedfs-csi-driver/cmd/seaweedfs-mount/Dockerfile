# Build `weed` from the local SeaweedFS checkout so the mount daemon picks up
# the current vidMap stale-relookup fix without depending on a remote clone.
ARG SEAWEEDFS_COMMIT=local

FROM golang:1.26-alpine AS builder

RUN apk add g++

ARG SEAWEEDFS_COMMIT
COPY --from=seaweedfs . /go/src/github.com/seaweedfs/seaweedfs

RUN cd /go/src/github.com/seaweedfs/seaweedfs/weed \
    && export LDFLAGS="-X github.com/seaweedfs/seaweedfs/weed/util/version.COMMIT=${SEAWEEDFS_COMMIT}" \
    && CGO_ENABLED=0 go install -ldflags "-extldflags -static ${LDFLAGS}" \
    && go clean -cache -modcache

# Build seaweedfs-mount from current context
WORKDIR /go/src/github.com/seaweedfs/seaweedfs-csi-driver
COPY . .

RUN go build -ldflags="-s -w" -o /seaweedfs-mount ./cmd/seaweedfs-mount && go clean -cache -modcache

FROM alpine AS final
RUN apk add fuse
LABEL author="Chris Lu"
COPY --from=builder /go/bin/weed /usr/bin/
COPY --from=builder /seaweedfs-mount /

RUN chmod +x /seaweedfs-mount
ENTRYPOINT ["/seaweedfs-mount"]
