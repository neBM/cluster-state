# syntax=docker/dockerfile:1
FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

ARG TARGETARCH
ARG OCI_REVISION=unknown
ARG UV_VERSION=0.12.10
ARG UV_AMD64_SHA256=173d95a0c32d18c896c46ba6fafbf3cf9c14ab74b033f81b76c883ef492a976b
ARG UV_ARM64_SHA256=9ff6b9d4665edcdd3a88dcc73cd1eb641754deb927f14e8c62ebfde6bf4f5f5e
ARG GLAB_VERSION=1.116.0
ARG GLAB_AMD64_SHA256=173cc61ea94c562f2ccd831f320d25b73982192e82810064552282482e3713ea
ARG GLAB_ARM64_SHA256=3e59a0c5db5b281c552543cc1018873ecdd551b07737cfdb932c6543aa39d88c
ARG KUBECTL_VERSION=v1.34.11
ARG KUBECTL_AMD64_SHA256=8efbb9435132a190920eb65a47a8c1ecf755ad85ab57a600c9bedbab460bb7a8
ARG KUBECTL_ARM64_SHA256=5b045a4712674c88a56fd98eef4285689738b7fbe8735e1b9ee3509521af5cb4

LABEL org.opencontainers.image.title="Hermes SSH workspace" \
      org.opencontainers.image.description="Dedicated least-privilege SSH development workspace for Hermes" \
      org.opencontainers.image.source="https://git.brmartin.co.uk/ben/cluster-state" \
      org.opencontainers.image.revision="${OCI_REVISION}" \
      org.opencontainers.image.licenses="LicenseRef-Internal"

ENV HOME=/workspace \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    UV_CACHE_DIR=/workspace/.cache/uv

RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) \
        UV_TARGET=x86_64-unknown-linux-gnu; \
        UV_SHA256="${UV_AMD64_SHA256}"; \
        GLAB_SHA256="${GLAB_AMD64_SHA256}"; \
        KUBECTL_SHA256="${KUBECTL_AMD64_SHA256}"; \
        ;; \
      arm64) \
        UV_TARGET=aarch64-unknown-linux-gnu; \
        UV_SHA256="${UV_ARM64_SHA256}"; \
        GLAB_SHA256="${GLAB_ARM64_SHA256}"; \
        KUBECTL_SHA256="${KUBECTL_ARM64_SHA256}"; \
        ;; \
      *) \
        echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; \
        exit 1; \
        ;; \
    esac; \
    export DEBIAN_FRONTEND=noninteractive; \
    cleanup_ssh_keygen_diversion() { \
      diversion="$(dpkg-divert --list /usr/bin/ssh-keygen)"; \
      if [ -n "${diversion}" ]; then \
        rm -f /usr/bin/ssh-keygen; \
        dpkg-divert --local --rename --remove /usr/bin/ssh-keygen; \
      fi; \
    }; \
    apt-get update; \
    apt-get install --yes --no-install-recommends \
      bash \
      build-essential \
      ca-certificates \
      coreutils \
      curl \
      diffutils \
      findutils \
      git \
      gzip \
      jq \
      make \
      openssh-client \
      patch \
      procps \
      python3 \
      shellcheck \
      tar \
      unzip \
      util-linux; \
    diversion="$(dpkg-divert --list /usr/bin/ssh-keygen)"; \
    test -z "${diversion}"; \
    trap cleanup_ssh_keygen_diversion EXIT; \
    trap 'exit 1' HUP INT TERM; \
    dpkg-divert --local --rename --add /usr/bin/ssh-keygen; \
    printf '#!/bin/sh\nexit 0\n' > /usr/bin/ssh-keygen; \
    chmod 0755 /usr/bin/ssh-keygen; \
    test "$(command -v ssh-keygen)" = /usr/bin/ssh-keygen; \
    apt-get install --yes --no-install-recommends openssh-server; \
    cleanup_ssh_keygen_diversion; \
    trap - EXIT HUP INT TERM; \
    test -x /usr/bin/ssh-keygen; \
    test "$(command -v ssh-keygen)" = /usr/bin/ssh-keygen; \
    test "$(dpkg-query --search /usr/bin/ssh-keygen)" = "openssh-client: /usr/bin/ssh-keygen"; \
    key_types="$(ssh -Q key)"; \
    test -n "${key_types}"; \
    test ! -e /usr/bin/ssh-keygen.distrib; \
    test ! -e /usr/local/sbin/ssh-keygen; \
    diversion="$(dpkg-divert --list /usr/bin/ssh-keygen)"; \
    test -z "${diversion}"; \
    host_keys="$(find /etc/ssh -maxdepth 1 -name 'ssh_host_*' -print -quit)"; \
    test -z "${host_keys}"; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd --gid 10000 workspace; \
    useradd --uid 10000 --gid 10000 --home-dir /workspace --no-create-home --shell /bin/bash workspace; \
    usermod --password '*' workspace; \
    install -d -o 10000 -g 10000 -m 0700 /workspace; \
    install -d -o 0 -g 0 -m 0755 /run/sshd; \
    curl --fail --location --proto '=https' --tlsv1.2 \
      "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${UV_TARGET}.tar.gz" \
      --output /tmp/uv.tar.gz; \
    echo "${UV_SHA256}  /tmp/uv.tar.gz" | sha256sum --check --strict -; \
    mkdir /tmp/uv; \
    tar -xzf /tmp/uv.tar.gz -C /tmp/uv; \
    install -m 0755 "/tmp/uv/uv-${UV_TARGET}/uv" /usr/local/bin/uv; \
    install -m 0755 "/tmp/uv/uv-${UV_TARGET}/uvx" /usr/local/bin/uvx; \
    curl --fail --location --proto '=https' --tlsv1.2 \
      "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${TARGETARCH}.tar.gz" \
      --output /tmp/glab.tar.gz; \
    echo "${GLAB_SHA256}  /tmp/glab.tar.gz" | sha256sum --check --strict -; \
    mkdir /tmp/glab; \
    tar -xzf /tmp/glab.tar.gz -C /tmp/glab; \
    install -m 0755 /tmp/glab/bin/glab /usr/local/bin/glab; \
    curl --fail --location --proto '=https' --tlsv1.2 \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
      --output /tmp/kubectl; \
    echo "${KUBECTL_SHA256}  /tmp/kubectl" | sha256sum --check --strict -; \
    install -m 0755 /tmp/kubectl /usr/local/bin/kubectl; \
    rm -rf /tmp/uv /tmp/uv.tar.gz /tmp/glab /tmp/glab.tar.gz /tmp/kubectl

COPY --chmod=0644 sshd_config /etc/ssh/sshd_config
COPY --chmod=0755 entrypoint.sh /usr/local/sbin/hermes-workspace-entrypoint
COPY --chmod=0755 healthcheck.py /usr/local/bin/hermes-workspace-healthcheck

USER 0:0
WORKDIR /workspace
EXPOSE 2222
HEALTHCHECK CMD ["/usr/local/bin/hermes-workspace-healthcheck"]
ENTRYPOINT ["/usr/local/sbin/hermes-workspace-entrypoint"]
