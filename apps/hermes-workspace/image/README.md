# Hermes SSH workspace image

This directory is the complete build context for a minimal SSH development workspace. It does **not** contain Hermes. The image has no Kubernetes API dependency or host integration, and `/workspace` is its only persistent project-data contract. Desired state now contains the isolated GitOps runtime candidate described below.

## Runtime contract

- `sshd` listens on unprivileged port `2222`. It runs as root only to start `sshd`, read the host identity, and let OpenSSH drop every authenticated shell/SFTP process to UID/GID `10000:10000` (`workspace`).
- `/workspace` must be a real directory owned by UID/GID `10000:10000`, mode `0700`, and writable by that user. Startup fails otherwise.
- Authentication is public-key only. Password, keyboard-interactive, root, host-based, GSSAPI, Kerberos, agent/TCP/Unix-socket/X11 forwarding, tunnels, gateway ports, user environment, and user rc files are disabled. The internal SFTP subsystem supports current OpenSSH `scp` clients.
- Key material is never built or generated. Mount one read-only Secret at `/run/secrets/hermes-workspace`; its `ssh_host_ed25519_key` item must be root-owned mode `0400` or `0600`, and its `authorized_keys` item must be root-owned, non-writable, non-executable, non-empty, and syntactically valid. The exact paths are `/run/secrets/hermes-workspace/ssh_host_ed25519_key` and `/run/secrets/hermes-workspace/authorized_keys`. Startup also verifies that both resolve inside that read-only Secret mount.
- The image supports a read-only root filesystem. A workload must mount writable ephemeral volumes at `/run` (root-owned `0755`) and `/tmp` (root-owned `1777`), then mount the read-only Secret below `/run/secrets/hermes-workspace`. `/run/sshd` is the only daemon runtime-state directory. Mount the persistent project volume only at `/workspace`.
- Do not mount a home directory, hostPath, kubeconfig, service-account token, container socket, or other credential. The image contains neither sudo nor a container engine/init system.
- The OCI health check opens localhost port `2222` and requires an SSH-2.0 banner without presenting credentials.

The bundled tools are the immediate repository workflow set: Bash/POSIX utilities, Git, curl, jq, Python 3, uv/uvx, glab, kubectl (including `kubectl kustomize`), make/build-essential, tar/gzip/unzip, patch/diff, proc tools, and shellcheck. Node/npm are intentionally omitted because this repository has no Node package manifest or Node-based project workflow in the workspace slice.

## GitOps runtime candidate

The init and main containers are pinned to the independently registry-qualified multi-architecture index `registry.brmartin.co.uk:443/ben/cluster-state/hermes-workspace@sha256:1e0a06ff8f3b75a0a0bfc2b3fd5858750a9e30d03e6d44afb7d360e445393bd1`. The Pod selects only `kubernetes.io/arch: arm64`, leaving both Heracles and Nyx eligible while excluding Hestia, and persists only `/workspace` on the new dynamically provisioned `hermes-workspace-windsor` RWX claim using `windsor-nfs-rwx`. Image publication alone is non-authorizing: the candidate is not deployed or activated merely because its index was published.

Runtime qualification remains pending. Do not activate this workspace as an agent backend until Flux applies the exact revision, dynamic NFS provisioning and the fail-closed init ownership gate succeed, the live container `imageID` proves the qualified arm64 child, SSH/SFTP and persistence checks pass, and the Cilium policy is verified.

## Supply-chain and publication contract

The maintained Ubuntu 24.04 base is pinned to the OCI index digest `sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517`. That authenticated index contains the exact native `linux/amd64` child `sha256:1e0a86e57d247923571b75e0aaf48a1449cf8c543d51fb3e07a4a7d7bfa79316` and `linux/arm64` child `sha256:95fa486768020359141f1318720f43e7982ef926c792891d984aef9aaf05e7ea`. Distro package names are fixed, installed with `--no-install-recommends`, and package indexes are removed in the installation layer. The build installs `openssh-client` and the other tools first, uses `dpkg-divert` to replace the exact `/usr/bin/ssh-keygen` path with a temporary no-op only while `openssh-server` is configured, and restores the packaged client binary through trap-safe cleanup. Standalone final assertions require real OpenSSH client behavior, no diversion or stub residue, and no host-key files.

Standalone downloads are version- and SHA-256-pinned for both native architectures from their primary release sources:

| Tool | Version | `linux/amd64` SHA-256 | `linux/arm64` SHA-256 |
| --- | --- | --- | --- |
| uv | 0.12.10 | `173d95a0c32d18c896c46ba6fafbf3cf9c14ab74b033f81b76c883ef492a976b` | `9ff6b9d4665edcdd3a88dcc73cd1eb641754deb927f14e8c62ebfde6bf4f5f5e` |
| glab | 1.116.0 | `173cc61ea94c562f2ccd831f320d25b73982192e82810064552282482e3713ea` | `3e59a0c5db5b281c552543cc1018873ecdd551b07737cfdb932c6543aa39d88c` |
| kubectl | v1.34.11 | `8efbb9435132a190920eb65a47a8c1ecf755ad85ab57a600c9bedbab460bb7a8` | `5b045a4712674c88a56fd98eef4285689738b7fbe8735e1b9ee3509521af5cb4` |

All five image jobs use Buildah from the authenticated multi-architecture index `quay.io/buildah/stable@sha256:56e6ebc9bb71c8303b1968fb51304d3512e14a1b8c730bd0b27ebdf772a34ceb`. Merge-request verification runs once on each of the native `amd64` and `arm64` runners, verifies the locally built image with no registry login or publication, and then removes local Buildah state.

On protected default-branch pipelines, the native package jobs build and verify once before pushing the architecture-separated transport tags `${CI_COMMIT_SHA}-amd64` and `${CI_COMMIT_SHA}-arm64`. Each leaf exports an exact repository-by-digest reference without a trailing newline. After both leaves and manifest validation succeed, an untagged metadata-only publisher lets Buildah add those two digest references to one Docker v2s2 multi-architecture manifest list/index and push it once under the full commit-SHA tag `${CI_COMMIT_SHA}`. Nothing in this pipeline publishes `latest` or a short-SHA tag.

The publisher artifact `hermes-workspace-image.ref` contains the repository plus final index digest and remains non-authorizing until independent exact-digest registry qualification verifies the Docker v2s2 media type and the two expected `linux/amd64` and `linux/arm64` platform descriptors and leaf digests before deployment. The architecture transport tags and their leaf artifacts are provenance inputs, not deployment authority. Publisher exit zero or artifact existence alone grants no deployment authority, and this image pipeline does not create or update a runtime workload.
