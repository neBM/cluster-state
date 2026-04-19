# NOTE: expects pre-compiled binary in dist/. Not a self-contained build.
#
# CI:    compile:rpi5-dra-driver cross-compiles both arches → dist/ artifact
#        package:rpi5-dra-driver runs this Dockerfile via buildah
#
# Local: CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o dist/rpi5-dra-driver-amd64 ./cmd/rpi5-dra-driver
#        CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o dist/rpi5-dra-driver-arm64 ./cmd/rpi5-dra-driver
#        docker build --build-arg TARGETARCH=arm64 .

FROM alpine:3.21

ARG TARGETARCH
COPY dist/rpi5-dra-driver-${TARGETARCH} /rpi5-dra-driver
ENTRYPOINT ["/rpi5-dra-driver"]
