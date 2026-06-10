FROM alpine:3.24

ARG TARGETARCH

RUN apk add --no-cache ca-certificates \
  && addgroup -S -g 65532 goose \
  && adduser -S -D -H -u 65532 -G goose goose

COPY dist/goose-${TARGETARCH} /usr/local/bin/goose
COPY *.sql /migrations/

USER 65532:65532
WORKDIR /migrations

ENTRYPOINT ["goose"]
