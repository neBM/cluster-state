FROM golang:1.25-alpine AS builder

RUN apk add git g++

WORKDIR /go/src/github.com/seaweedfs/seaweedfs-csi-driver
COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /seaweedfs-consumer-recycler ./cmd/seaweedfs-consumer-recycler/ \
    && go clean -cache -modcache

FROM alpine AS final
RUN apk add --no-cache coreutils
LABEL author="Ben Martin"
COPY --from=builder /seaweedfs-consumer-recycler /

RUN chmod +x /seaweedfs-consumer-recycler
ENTRYPOINT ["/seaweedfs-consumer-recycler"]
