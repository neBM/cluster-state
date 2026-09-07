# Hermes SSH workspace image

This directory is the complete build context for a minimal SSH development workspace. It does **not** contain Hermes. The image has no Kubernetes API dependency or host integration, and `/workspace` is its only persistent project-data contract, so the same image can be used by an ordinary Deployment now and a future Kubernetes SIG Agent Sandbox PodTemplate later.

## Runtime contract

- `sshd` listens on unprivileged port `2222`. It runs as root only to start `sshd`, read the host identity, and let OpenSSH drop every authenticated shell/SFTP process to UID/GID `10000:10000` (`workspace`).
- `/workspace` must be a real directory owned by UID/GID `10000:10000`, mode `0700`, and writable by that user. Startup fails otherwise.
- Authentication is public-key only. Password, keyboard-interactive, root, host-based, GSSAPI, Kerberos, agent/TCP/Unix-socket/X11 forwarding, tunnels, gateway ports, user environment, and user rc files are disabled. The internal SFTP subsystem supports current OpenSSH `scp` clients.
- Key material is never built or generated. Mount one read-only Secret at `/run/secrets/hermes-workspace`; its `ssh_host_ed25519_key` item must be root-owned mode `0400` or `0600`, and its `authorized_keys` item must be root-owned, non-writable, non-executable, non-empty, and syntactically valid. The exact paths are `/run/secrets/hermes-workspace/ssh_host_ed25519_key` and `/run/secrets/hermes-workspace/authorized_keys`. Startup also verifies that both resolve inside that read-only Secret mount.
- The image supports a read-only root filesystem. A later workload must mount writable ephemeral volumes at `/run` (root-owned `0755`) and `/tmp` (root-owned `1777`), then mount the read-only Secret below `/run/secrets/hermes-workspace`. `/run/sshd` is the only daemon runtime-state directory. Mount the persistent project volume only at `/workspace`.
- Do not mount a home directory, hostPath, kubeconfig, service-account token, container socket, or other credential. The image contains neither sudo nor a container engine/init system.
- The OCI health check opens localhost port `2222` and requires an SSH-2.0 banner without presenting credentials.

The bundled tools are the immediate repository workflow set: Bash/POSIX utilities, Git, curl, jq, Python 3, uv/uvx, glab, kubectl (including `kubectl kustomize`), make/build-essential, tar/gzip/unzip, patch/diff, proc tools, and shellcheck. Node/npm are intentionally omitted because this repository has no Node package manifest or Node-based project workflow in the workspace slice.

## Supply-chain and publication contract

The maintained Ubuntu 24.04 base is pinned to the OCI index digest `sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517`. Docker Hub's primary registry index was checked for its native `linux/amd64` manifest (`sha256:1e0a86e57d247923571b75e0aaf48a1449cf8c543d51fb3e07a4a7d7bfa79316`). Distro package names are fixed, installed with `--no-install-recommends`, and package indexes are removed in the installation layer. A temporary no-op `ssh-keygen` shadows the maintainer-script call only while `openssh-server` is configured, then is removed; the final real client binary remains and the layer asserts that no host-key file was created.

Standalone downloads are version- and SHA-256-pinned for `linux/amd64` from their primary release sources:

| Tool | Version | Primary evidence |
| --- | --- | --- |
| uv | 0.12.10 | `https://github.com/astral-sh/uv/releases/tag/0.12.10` and each archive's adjacent `.sha256` |
| glab | 1.116.0 | `https://gitlab.com/gitlab-org/cli/-/releases/v1.116.0` and release `checksums.txt` |
| kubectl | v1.34.11 | `https://dl.k8s.io/release/v1.34.11/bin/linux/amd64/kubectl{,.sha256}` |

CI routes the package job to the repository's `k8s-amd64` lane and publishes one single-architecture `linux/amd64` image under the full immutable commit-SHA tag; it never publishes this image as `latest` or creates a multi-architecture index. The package job records the registry-produced image-manifest digest as an artifact. A future deployment must use `repository@sha256:...` from that successful CI artifact rather than treating the commit-SHA tag as deployment authority.
