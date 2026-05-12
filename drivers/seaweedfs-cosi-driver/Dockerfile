# NOTE: expects pre-compiled binaries in dist/. Not a self-contained build.
#
# CI:    compile:seaweedfs-cosi-driver cross-compiles both arches -> dist/ artifact
#        package:seaweedfs-cosi-driver runs this Dockerfile via buildah
#
# Local: CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o dist/seaweedfs-cosi-driver-amd64 ./cmd/seaweedfs-cosi-driver
#        CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o dist/seaweedfs-cosi-driver-arm64 ./cmd/seaweedfs-cosi-driver
#        docker build --build-arg TARGETARCH=arm64 .

FROM gcr.io/distroless/static:latest

ARG TARGETARCH

COPY --chown=65532:65532 dist/seaweedfs-cosi-driver-${TARGETARCH} /usr/bin/seaweedfs-cosi-driver
COPY --chown=65532:65532 docker/var-lib-cosi/ /var/lib/cosi/

# Set volume mount point for app socket.
VOLUME [ "/var/lib/cosi" ]

# Set the final UID:GID to non-root user.
USER 65532:65532

# Disable healthcheck.
HEALTHCHECK NONE

# Few Args for dynamically setting labels.
ARG QUAY_EXPIRATION=Never
ARG SEAWEEDFS_VERSION=Development

# Add labels.

## Standard opencontainers labels.
LABEL org.opencontainers.image.title="seaweedfs-cosi-driver"
LABEL org.opencontainers.image.description="COSI Driver for seaweedfs"
LABEL org.opencontainers.image.authors="seaweedfs maintainers"
LABEL org.opencontainers.image.vendor="seaweedfs-tech"
LABEL org.opencontainers.image.version="${SEAWEEDFS_VERSION}"
LABEL org.opencontainers.image.license="Apache-2.0"
LABEL org.opencontainers.image.source="github.com/seaweedfs/seaweedfs-cosi-driver"
LABEL org.opencontainers.image.documentation="https://seaweedfs.github.io/"
LABEL org.opencontainers.image.base.name="gcr.io/distroless/static:latest"

## Quay specific labels.
LABEL quay.expires-after="${QUAY_EXPIRATION}"

# Set the entrypoint.
ENTRYPOINT [ "/usr/bin/seaweedfs-cosi-driver" ]
CMD []
