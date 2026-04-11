# SEAWEEDFS_COMMIT + SEAWEEDFS_REPO should match the replace directive in
# go.mod for reproducibility. Override via:
#   docker build --build-arg SEAWEEDFS_COMMIT=<hash> --build-arg SEAWEEDFS_REPO=<url>
# Currently pinned to neBM fork which carries the vidMap stale-relookup fix
# until it lands upstream.
ARG SEAWEEDFS_COMMIT=c6b9ccc8a1fb
ARG SEAWEEDFS_REPO=https://github.com/neBM/seaweedfs

FROM golang:1.25-alpine AS builder

RUN apk add git g++

# Build weed binary from a specific commit for reproducibility
ARG SEAWEEDFS_COMMIT
ARG SEAWEEDFS_REPO
RUN git clone ${SEAWEEDFS_REPO} /go/src/github.com/seaweedfs/seaweedfs \
    && cd /go/src/github.com/seaweedfs/seaweedfs \
    && git checkout ${SEAWEEDFS_COMMIT} \
    && cd weed \
    && go install \
    && go clean -cache -modcache

# Build seaweedfs-mount from current context
WORKDIR /go/src/github.com/seaweedfs/seaweedfs-csi-driver
COPY . .

RUN go build -ldflags="-s -w" -o /seaweedfs-mount ./cmd/seaweedfs-mount/main.go && go clean -cache -modcache

FROM alpine AS final
RUN apk add fuse
LABEL author="Chris Lu"
COPY --from=builder /go/bin/weed /usr/bin/
COPY --from=builder /seaweedfs-mount /

RUN chmod +x /seaweedfs-mount
ENTRYPOINT ["/seaweedfs-mount"]
