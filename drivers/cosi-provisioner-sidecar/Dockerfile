# NOTE: expects pre-compiled binaries in dist/. Not a self-contained build.
#
# CI:    compile:cosi-provisioner-sidecar cross-compiles both arches -> dist/ artifact
#        package:cosi-provisioner-sidecar runs this Dockerfile via buildah
#
# Local: CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o dist/objectstorage-sidecar-amd64 ./cmd/objectstorage-sidecar
#        CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o dist/objectstorage-sidecar-arm64 ./cmd/objectstorage-sidecar
#        docker build --build-arg TARGETARCH=arm64 .

FROM gcr.io/distroless/static:latest

ARG TARGETARCH

COPY --chown=65532:65532 dist/objectstorage-sidecar-${TARGETARCH} /objectstorage-sidecar
USER 65532:65532

LABEL maintainers="Kubernetes COSI Authors"
LABEL description="Object Storage Sidecar"
ENTRYPOINT ["/objectstorage-sidecar"]
