FROM golang:1.25-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -a -ldflags '-s -w' \
    -o /rpi5-dra-driver ./cmd/rpi5-dra-driver

FROM alpine:3.21
COPY --from=builder /rpi5-dra-driver /rpi5-dra-driver
ENTRYPOINT ["/rpi5-dra-driver"]
