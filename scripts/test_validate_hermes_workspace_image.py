#!/usr/bin/env python3
"""Validate the dedicated Hermes SSH workspace image production contract."""

from __future__ import annotations

import re
import subprocess
import sys
from collections import defaultdict
from collections.abc import Callable
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import NoReturn

ROOT = Path(__file__).resolve().parent.parent
IMAGE = ROOT / "apps/hermes-workspace/image"
CI = ROOT / ".gitlab-ci.yml"
VALIDATION_ENTRYPOINT = ROOT / "scripts/validate_kustomize.sh"
VERIFY_HELPER = ROOT / "scripts/verify_hermes_workspace_image.sh"
BUILDAH_IMAGE = (
    "quay.io/buildah/stable@sha256:"
    "56e6ebc9bb71c8303b1968fb51304d3512e14a1b8c730bd0b27ebdf772a34ceb"
)
DOCKER_LIST_MEDIA_TYPE = "application/vnd.docker.distribution.manifest.list.v2+json"
DOCKER_MANIFEST_MEDIA_TYPE = "application/vnd.docker.distribution.manifest.v2+json"
BUILDAH_LOGIN = (
    "printf '%s' \"$CI_REGISTRY_PASSWORD\" | buildah login "
    "--username \"$CI_REGISTRY_USER\" --password-stdin \"$CI_REGISTRY\""
)

EXPECTED_IMAGE_FILES = {
    ".dockerignore",
    "Dockerfile",
    "README.md",
    "entrypoint.sh",
    "healthcheck.py",
    "sshd_config",
}
BASE = (
    "ubuntu:24.04@sha256:"
    "33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517"
)
PINNED_ARGUMENTS = {
    "UV_VERSION": "0.12.10",
    "UV_AMD64_SHA256": "173d95a0c32d18c896c46ba6fafbf3cf9c14ab74b033f81b76c883ef492a976b",
    "UV_ARM64_SHA256": "9ff6b9d4665edcdd3a88dcc73cd1eb641754deb927f14e8c62ebfde6bf4f5f5e",
    "GLAB_VERSION": "1.116.0",
    "GLAB_AMD64_SHA256": "173cc61ea94c562f2ccd831f320d25b73982192e82810064552282482e3713ea",
    "GLAB_ARM64_SHA256": "3e59a0c5db5b281c552543cc1018873ecdd551b07737cfdb932c6543aa39d88c",
    "KUBECTL_VERSION": "v1.34.11",
    "KUBECTL_AMD64_SHA256": "8efbb9435132a190920eb65a47a8c1ecf755ad85ab57a600c9bedbab460bb7a8",
    "KUBECTL_ARM64_SHA256": "5b045a4712674c88a56fd98eef4285689738b7fbe8735e1b9ee3509521af5cb4",
}
REQUIRED_PACKAGES = {
    "bash",
    "build-essential",
    "ca-certificates",
    "coreutils",
    "curl",
    "diffutils",
    "findutils",
    "git",
    "gzip",
    "jq",
    "make",
    "openssh-client",
    "openssh-server",
    "patch",
    "procps",
    "python3",
    "shellcheck",
    "tar",
    "unzip",
    "util-linux",
}
FORBIDDEN_TOOL_PATTERNS = (
    r"\bsudo\b",
    r"\b(?:docker|podman|buildah|containerd|nerdctl)\b",
    r"\b(?:k3s|helm)\b",
    r"\bhermes(?:-agent)?\b",
    r"\b(?:nodejs|node|npm|yarn|pnpm)\b",
)


def fail(message: str) -> NoReturn:
    raise AssertionError(message)


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        fail(f"missing {label}: {needle!r}")


def forbid(text: str, pattern: str, label: str) -> None:
    if re.search(pattern, text, re.IGNORECASE | re.MULTILINE):
        fail(f"forbidden {label}: {pattern!r}")


def ordered(text: str, needles: tuple[str, ...], label: str) -> None:
    cursor = 0
    for needle in needles:
        found = text.find(needle, cursor)
        if found < 0:
            fail(f"incorrect {label} ordering: {needles!r}")
        cursor = found + len(needle)


def flattened_shell(text: str) -> str:
    return re.sub(r"\\\n\s*", " ", text)


def require_standalone_shell_command(
    text: str,
    command: str,
    label: str,
    *,
    count: int = 1,
) -> None:
    expected = f"{command}; \\"
    matches = [line.strip() for line in text.splitlines() if command in line]
    if matches != [expected] * count:
        fail(
            f"{label} must be a standalone fail-closed command exactly {count} time(s), "
            f"got {matches!r}"
        )


def top_level_block(text: str, key: str) -> str:
    match = re.search(
        rf"^{re.escape(key)}:[^\n]*\n(?P<body>.*?)(?=^[A-Za-z_.][^\n]*:[^\n]*\n|\Z)",
        text,
        re.MULTILINE | re.DOTALL,
    )
    if match is None:
        fail(f"missing CI block: {key}")
    return match.group(0)


def top_level_blocks(text: str) -> dict[str, str]:
    starts = list(
        re.finditer(
            r"^(?P<key>[A-Za-z_.][^\n]*):[^\n]*\n",
            text,
            re.MULTILINE,
        )
    )
    blocks: dict[str, str] = {}
    for index, match in enumerate(starts):
        end = starts[index + 1].start() if index + 1 < len(starts) else len(text)
        blocks[match.group("key")] = text[match.start() : end]
    return blocks


def validate_file_inventory() -> dict[str, str]:
    if not IMAGE.is_dir():
        fail("workspace image directory is absent: apps/hermes-workspace/image")
    actual = {path.name for path in IMAGE.iterdir() if path.is_file()}
    if actual != EXPECTED_IMAGE_FILES:
        fail(
            "workspace image file inventory mismatch: "
            f"expected {sorted(EXPECTED_IMAGE_FILES)!r}, got {sorted(actual)!r}"
        )
    if any(path.is_dir() for path in IMAGE.iterdir()):
        fail("workspace image context must not contain subdirectories")

    texts = {name: (IMAGE / name).read_text() for name in EXPECTED_IMAGE_FILES}
    combined = "\n".join(texts.values())
    for marker in (
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "-----BEGIN RSA PRIVATE KEY-----",
        "ssh-ed25519 ",
        "ssh-rsa ",
        "ecdsa-sha2-",
    ):
        forbid(combined, re.escape(marker), "embedded SSH key material")
    return texts


def validate_dockerfile(text: str) -> None:
    from_lines = re.findall(r"^FROM\s+(\S+)", text, re.MULTILINE)
    if from_lines != [BASE]:
        fail(f"Dockerfile must use exactly the authenticated base digest, got {from_lines!r}")

    for key, value in PINNED_ARGUMENTS.items():
        require(text, f"ARG {key}={value}", f"pinned {key}")

    for label in (
        "org.opencontainers.image.title",
        "org.opencontainers.image.description",
        "org.opencontainers.image.source",
        "org.opencontainers.image.revision",
        "org.opencontainers.image.licenses",
    ):
        require(text, f"{label}=", f"OCI label {label}")

    shell = flattened_shell(text)
    package_matches = re.findall(
        r"apt-get install --yes --no-install-recommends\s+(?P<packages>[^;]+);",
        shell,
    )
    if len(package_matches) != 2:
        fail("workspace packages must use exactly two no-recommends apt installations")
    package_sets = [
        set(re.findall(r"\b[a-z][a-z0-9.+-]*\b", packages))
        for packages in package_matches
    ]
    expected_client_packages = REQUIRED_PACKAGES - {"openssh-server"}
    if package_sets[0] != expected_client_packages:
        fail(
            "openssh-client and tool packages must be installed before diversion: "
            f"expected {sorted(expected_client_packages)!r}, got {sorted(package_sets[0])!r}"
        )
    if package_sets[1] != {"openssh-server"}:
        fail(
            "openssh-server must be the only package installed while ssh-keygen is diverted, "
            f"got {sorted(package_sets[1])!r}"
        )
    for packages in package_matches:
        for pattern in FORBIDDEN_TOOL_PATTERNS:
            forbid(packages, pattern, "workspace package")
    require(text, "rm -rf /var/lib/apt/lists/*", "apt index cleanup")

    cleanup_match = re.search(
        r"cleanup_ssh_keygen_diversion\(\) \{(?P<body>.*?)^    \}",
        text,
        re.MULTILINE | re.DOTALL,
    )
    if cleanup_match is None:
        fail("missing trap-safe ssh-keygen diversion cleanup function")
    ordered(
        cleanup_match.group("body"),
        (
            'diversion="$(dpkg-divert --list /usr/bin/ssh-keygen)"',
            'if [ -n "${diversion}" ]; then',
            "rm -f /usr/bin/ssh-keygen",
            "dpkg-divert --local --rename --remove /usr/bin/ssh-keygen",
        ),
        "ssh-keygen diversion cleanup",
    )
    for needle in (
        "trap cleanup_ssh_keygen_diversion EXIT",
        "trap 'exit 1' HUP INT TERM",
    ):
        require(text, needle, "trap-safe ssh-keygen diversion cleanup")

    operations = shell[shell.find("apt-get update;") :]
    ordered(
        operations,
        (
            "apt-get install --yes --no-install-recommends",
            'diversion="$(dpkg-divert --list /usr/bin/ssh-keygen)"',
            'test -z "${diversion}"',
            "trap cleanup_ssh_keygen_diversion EXIT",
            "trap 'exit 1' HUP INT TERM",
            "dpkg-divert --local --rename --add /usr/bin/ssh-keygen",
            "printf '#!/bin/sh\\nexit 0\\n' > /usr/bin/ssh-keygen",
            "chmod 0755 /usr/bin/ssh-keygen",
            'test "$(command -v ssh-keygen)" = /usr/bin/ssh-keygen',
            "apt-get install --yes --no-install-recommends openssh-server",
            "cleanup_ssh_keygen_diversion",
            "trap - EXIT HUP INT TERM",
            "test -x /usr/bin/ssh-keygen",
            'test "$(dpkg-query --search /usr/bin/ssh-keygen)" = "openssh-client: /usr/bin/ssh-keygen"',
            'key_types="$(ssh -Q key)"',
            'test -n "${key_types}"',
            "test ! -e /usr/bin/ssh-keygen.distrib",
            "test ! -e /usr/local/sbin/ssh-keygen",
            'diversion="$(dpkg-divert --list /usr/bin/ssh-keygen)"',
            'test -z "${diversion}"',
            'host_keys="$(find /etc/ssh -maxdepth 1 -name \'ssh_host_*\' -print -quit)"',
            'test -z "${host_keys}"',
            "rm -rf /var/lib/apt/lists/*",
        ),
        "keyless package installation and residue checks",
    )
    for command, label, count in (
        ('test -z "${diversion}"', "absent ssh-keygen diversion", 2),
        ('test "$(command -v ssh-keygen)" = /usr/bin/ssh-keygen', "exact ssh-keygen path", 2),
        ("test -x /usr/bin/ssh-keygen", "restored ssh-keygen executable", 1),
        (
            'test "$(dpkg-query --search /usr/bin/ssh-keygen)" = "openssh-client: /usr/bin/ssh-keygen"',
            "restored ssh-keygen package owner",
            1,
        ),
        ('test -n "${key_types}"', "OpenSSH client-suite behavior", 1),
        ("test ! -e /usr/bin/ssh-keygen.distrib", "absent diverted binary residue", 1),
        ("test ! -e /usr/local/sbin/ssh-keygen", "absent obsolete stub", 1),
        ('test -z "${host_keys}"', "absent generated host keys", 1),
    ):
        require_standalone_shell_command(text, command, label, count=count)
    for command, label, count in (
        ('diversion="$(dpkg-divert --list /usr/bin/ssh-keygen)"', "diversion query", 3),
        ('key_types="$(ssh -Q key)"', "OpenSSH client key-type query", 1),
        (
            'host_keys="$(find /etc/ssh -maxdepth 1 -name \'ssh_host_*\' -print -quit)"',
            "host-key query",
            1,
        ),
    ):
        require_standalone_shell_command(text, command, label, count=count)
    forbid(text, r"\bssh-keygen\s+-Q\s+key\b", "invalid ssh-keygen key-type query")
    forbid(text, r">\s*/usr/local/sbin/ssh-keygen", "PATH-shadow ssh-keygen stub")
    forbid(
        text,
        r"\brm\s+(?:-[A-Za-z]*f[A-Za-z]*\s+)?/etc/ssh/ssh_host_",
        "post-generation host-key deletion",
    )

    architecture_case = """    case "${TARGETARCH}" in \\
      amd64) \\
        UV_TARGET=x86_64-unknown-linux-gnu; \\
        UV_SHA256="${UV_AMD64_SHA256}"; \\
        GLAB_SHA256="${GLAB_AMD64_SHA256}"; \\
        KUBECTL_SHA256="${KUBECTL_AMD64_SHA256}"; \\
        ;; \\
      arm64) \\
        UV_TARGET=aarch64-unknown-linux-gnu; \\
        UV_SHA256="${UV_ARM64_SHA256}"; \\
        GLAB_SHA256="${GLAB_ARM64_SHA256}"; \\
        KUBECTL_SHA256="${KUBECTL_ARM64_SHA256}"; \\
        ;; \\
      *) \\
        echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; \\
        exit 1; \\
        ;; \\
    esac; \\"""
    require(text, architecture_case, "fail-closed amd64/arm64 selection")
    if text.count('case "${TARGETARCH}" in') != 1:
        fail("Dockerfile must have exactly one TARGETARCH case")
    forbid(
        text,
        r'test\s+"?\$\{TARGETARCH\}"?\s*=\s*"?amd64"?',
        "obsolete amd64-only guard",
    )

    for artifact in ("uv.tar.gz", "glab.tar.gz", "kubectl"):
        ordered(
            text,
            (f"/tmp/{artifact}", f'echo "${{{artifact.split(".")[0].upper()}_SHA256}}  /tmp/{artifact}" | sha256sum --check --strict -'),
            f"{artifact} checksum-before-install",
        )
    ordered(
        text,
        (
            'echo "${UV_SHA256}  /tmp/uv.tar.gz" | sha256sum --check --strict -',
            "tar -xzf /tmp/uv.tar.gz",
            'echo "${GLAB_SHA256}  /tmp/glab.tar.gz" | sha256sum --check --strict -',
            "tar -xzf /tmp/glab.tar.gz",
            'echo "${KUBECTL_SHA256}  /tmp/kubectl" | sha256sum --check --strict -',
            "install -m 0755 /tmp/kubectl /usr/local/bin/kubectl",
        ),
        "standalone download verification",
    )

    for needle in (
        "groupadd --gid 10000 workspace",
        "useradd --uid 10000 --gid 10000",
        "--home-dir /workspace",
        "--shell /bin/bash workspace",
        "usermod --password '*' workspace",
        "install -d -o 10000 -g 10000 -m 0700 /workspace",
        "EXPOSE 2222",
        'HEALTHCHECK CMD ["/usr/local/bin/hermes-workspace-healthcheck"]',
        'ENTRYPOINT ["/usr/local/sbin/hermes-workspace-entrypoint"]',
        "USER 0:0",
        "WORKDIR /workspace",
    ):
        require(text, needle, "runtime image contract")

    forbid(text, r"ssh-keygen\s+-A", "host-key generation")
    forbid(text, r"\bCOPY\s+(?:\.|/|apps/)", "broad build-context copy")
    forbid(text, r"(?:^|[/:])latest(?:\s|$)", "mutable latest reference")


def sshd_directives(text: str) -> dict[str, list[str]]:
    directives: dict[str, list[str]] = defaultdict(list)
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        key, separator, value = stripped.partition(" ")
        if not separator or not value.strip():
            fail(f"malformed sshd_config line: {line!r}")
        directives[key.lower()].append(value.strip())
    return dict(directives)


def validate_sshd_config(text: str) -> None:
    directives = sshd_directives(text)
    expected = {
        "port": ["2222"],
        "listenaddress": ["0.0.0.0", "::"],
        "hostkey": ["/run/secrets/hermes-workspace/ssh_host_ed25519_key"],
        "pidfile": ["/run/sshd/sshd.pid"],
        "allowusers": ["workspace"],
        "authenticationmethods": ["publickey"],
        "pubkeyauthentication": ["yes"],
        "authorizedkeysfile": ["/run/secrets/hermes-workspace/authorized_keys"],
        "passwordauthentication": ["no"],
        "kbdinteractiveauthentication": ["no"],
        "challengeresponseauthentication": ["no"],
        "permitemptypasswords": ["no"],
        "permitrootlogin": ["no"],
        "usepam": ["no"],
        "hostbasedauthentication": ["no"],
        "gssapiauthentication": ["no"],
        "kerberosauthentication": ["no"],
        "disableforwarding": ["yes"],
        "allowagentforwarding": ["no"],
        "allowtcpforwarding": ["no"],
        "allowstreamlocalforwarding": ["no"],
        "gatewayports": ["no"],
        "permittunnel": ["no"],
        "x11forwarding": ["no"],
        "permituserenvironment": ["no"],
        "permituserrc": ["no"],
        "strictmodes": ["yes"],
        "usedns": ["no"],
        "printmotd": ["no"],
        "printlastlog": ["no"],
        "loglevel": ["VERBOSE"],
        "subsystem": ["sftp internal-sftp"],
    }
    for key, values in expected.items():
        if directives.get(key) != values:
            fail(f"sshd_config {key} must be exactly {values!r}, got {directives.get(key)!r}")
    for forbidden in ("acceptenv", "setenv", "authorizedkeyscommand", "forcecommand"):
        if forbidden in directives:
            fail(f"sshd_config must not set {forbidden}")


def validate_entrypoint(text: str) -> None:
    require(text, "set -euo pipefail", "fail-closed shell mode")
    for path in (
        "/run/secrets/hermes-workspace/ssh_host_ed25519_key",
        "/run/secrets/hermes-workspace/authorized_keys",
        "/workspace",
        "/run/sshd",
    ):
        require(text, path, f"startup path {path}")
    for needle in (
        '[[ "$(id -u)" == 0 ]]',
        '[[ "$shadow_password" == \'*\' ]]',
        "stat -Lc '%u:%g:%a'",
        "findmnt --target",
        "read-only mount",
        "mode & 077",
        "mode & 022",
        "owner != 10000 || group != 10000",
        "runuser -u workspace -- test -w /workspace",
        'fail "/run must be root-owned and not group/other writable"',
        "ssh-keygen -l -f /dev/stdin",
        '(( key_count > 0 )) || fail "authorized_keys contains no public keys"',
        '[[ "$host_mode" == 400 || "$host_mode" == 600 ]]',
        "/usr/sbin/sshd -t -f /etc/ssh/sshd_config",
        "exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config",
    ):
        require(text, needle, "startup safety check")
    forbid(
        text,
        re.escape('(( key_count == 0 )) && fail "authorized_keys contains no public keys"'),
        "errexit-prone zero-count authorized-keys assertion",
    )
    forbid(text, r"ssh-keygen\s+-A", "startup host-key generation")
    forbid(text, r"(?:passwd|chpasswd|useradd|groupadd)", "runtime identity mutation")


def validate_healthcheck(text: str) -> None:
    for needle in (
        '("127.0.0.1", 2222)',
        "timeout=2.0",
        'banner.startswith(b"SSH-2.0-")',
    ):
        require(text, needle, "credential-free SSH health check")
    forbid(text, r"subprocess|os\.system|ssh\s", "health-check command execution")


def validate_readme(text: str) -> None:
    for needle in (
        "/workspace",
        "UID/GID `10000:10000`",
        "read-only root filesystem",
        "`/run`",
        "`/tmp`",
        "/run/secrets/hermes-workspace/ssh_host_ed25519_key",
        "/run/secrets/hermes-workspace/authorized_keys",
        "read-only Secret",
        "port `2222`",
        "SFTP",
        "root only to start `sshd`",
        "`linux/amd64`",
        "`linux/arm64`",
        "`amd64` and `arm64` runners",
        "exact `/usr/bin/ssh-keygen`",
        "`dpkg-divert`",
        "full commit-SHA tag",
        "`${CI_COMMIT_SHA}-amd64`",
        "`${CI_COMMIT_SHA}-arm64`",
        "`hermes-workspace-image.ref`",
        "Docker v2s2 multi-architecture manifest list/index",
        "final index digest",
        "not deployed",
    ):
        require(text, needle, "documented image contract")
    publication_contract = text[text.index("On protected default-branch pipelines") :]
    forbid(publication_contract, r"\bOCI index\b", "OCI-format final workspace artifact")


def validate_dockerignore(text: str) -> None:
    expected = "**\n!Dockerfile\n!entrypoint.sh\n!healthcheck.py\n!sshd_config\n"
    if text != expected:
        fail(".dockerignore must expose only the exact build inputs")


WORKSPACE_CHANGES = (
    "apps/hermes-workspace/image/**/*",
    "scripts/verify_hermes_workspace_image.sh",
    ".gitlab-ci.yml",
)
MR_CONDITION = '$CI_PIPELINE_SOURCE == "merge_request_event"'
MAIN_CONDITION = (
    '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH && $CI_COMMIT_REF_PROTECTED == "true"'
)


def job_tags(block: str) -> list[str]:
    match = re.search(r"^  tags:\n(?P<tags>(?:    - [^\n]+\n)+)", block, re.MULTILINE)
    if match is None:
        return []
    return re.findall(r"^    - ([^\s]+)\s*$", match.group("tags"), re.MULTILINE)


def require_direct_rules(block: str, condition: str, label: str) -> None:
    changes = "".join(f"        - {path}\n" for path in WORKSPACE_CHANGES)
    expected = f"  rules:\n    - if: '{condition}'\n      changes:\n{changes}"
    require(block, expected, f"direct {label} rules")
    if block.count("  rules:\n") != 1:
        fail(f"{label} must have exactly one direct rules list")
    actual = block[block.index("  rules:\n") :].strip()
    if actual != expected.strip():
        fail(f"{label} rules must contain only the exact pipeline condition and changes")
    forbid(block, r"^  rules:\s*\*", f"indirect {label} rules")


def validate_verify_helper(text: str) -> None:
    if VERIFY_HELPER.stat().st_mode & 0o111 == 0:
        fail("workspace image verification helper must be executable")
    for needle in (
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        'if (( $# != 3 )); then',
        'image="$1"',
        'expected_arch="$2"',
        'expected_revision="$3"',
        'case "${expected_arch}" in',
        "amd64 | arm64)",
        'container=""',
        'rootfs=""',
        "cleanup() {",
        'buildah umount "${container}"',
        'buildah rm "${container}"',
        "trap cleanup EXIT",
        "trap 'exit 1' HUP INT TERM",
        'container="$(buildah from "${image}")"',
        'rootfs="$(buildah mount "${container}")"',
        'host_keys="$(find "${rootfs}/etc/ssh" -maxdepth 1 -name \'ssh_host_*\' -print -quit)"',
        'test -z "${host_keys}"',
        'test -x "${rootfs}/usr/bin/ssh"',
        'test -x "${rootfs}/usr/bin/ssh-keygen"',
        'test -x "${rootfs}/usr/sbin/sshd"',
        'test ! -e "${rootfs}/usr/bin/ssh-keygen.distrib"',
        'test ! -e "${rootfs}/usr/local/sbin/ssh-keygen"',
        'diversion="$(buildah run "${container}" -- dpkg-divert --list /usr/bin/ssh-keygen)"',
        'test -z "${diversion}"',
        'test "$(buildah run "${container}" -- dpkg-query --search /usr/bin/ssh)" = "openssh-client: /usr/bin/ssh"',
        'test "$(buildah run "${container}" -- dpkg-query --search /usr/bin/ssh-keygen)" = "openssh-client: /usr/bin/ssh-keygen"',
        'test "$(buildah run "${container}" -- dpkg-query --search /usr/sbin/sshd)" = "openssh-server: /usr/sbin/sshd"',
        'key_types="$(buildah run "${container}" -- /usr/bin/ssh -Q key)"',
        'test -n "${key_types}"',
        'if buildah run "${container}" -- /usr/bin/ssh-keygen -l -f /etc/ssh/sshd_config >/dev/null 2>&1; then',
        "ssh-keygen unexpectedly accepted a non-key file",
        "bash cc c++ gcc g++ curl diff find git gzip jq make patch ps python3 shellcheck tar unzip lsblk ssh ssh-keygen sshd uv uvx glab kubectl",
        "command -v \"${tool}\" >/dev/null",
        "test -s /etc/ssl/certs/ca-certificates.crt",
        'buildah run "${container}" -- /usr/local/bin/uv --version',
        'buildah run "${container}" -- /usr/local/bin/uvx --version',
        'buildah run "${container}" -- /usr/local/bin/glab --version',
        'buildah run "${container}" -- /usr/local/bin/kubectl version --client',
        "{{.Docker.OS}}",
        "{{.Docker.Architecture}}",
        '{{index .Docker.Config.Labels "org.opencontainers.image.revision"}}',
        "{{.Docker.Config.User}}",
        "{{.Docker.Config.WorkingDir}}",
        "{{len .Docker.Config.Entrypoint}}",
        "{{index .Docker.Config.Entrypoint 0}}",
        "{{len .Docker.Config.ExposedPorts}}",
        "{{range $port, $_ := .Docker.Config.ExposedPorts}}{{$port}}{{end}}",
        "{{len .Docker.Config.Healthcheck.Test}}",
        "{{index .Docker.Config.Healthcheck.Test 0}}",
        "{{index .Docker.Config.Healthcheck.Test 1}}",
        "/usr/local/sbin/hermes-workspace-entrypoint",
        "/usr/local/bin/hermes-workspace-healthcheck",
    ):
        require(text, needle, "workspace image verification helper")
    forbid(
        text,
        re.escape('{{index .Docker.Config.ExposedPorts "2222/tcp"}}'),
        "typed string-index ExposedPorts lookup",
    )
    forbid(text, r"\bbuildah\s+rmi\b", "verification-helper image removal")
    forbid(text, r"\b(?:login|push)\b", "verification-helper registry access")
    ordered(
        text,
        (
            'container="$(buildah from "${image}")"',
            'rootfs="$(buildah mount "${container}")"',
            'buildah run "${container}" -- /usr/local/bin/uv --version',
            'buildah run "${container}" -- /usr/local/bin/uvx --version',
            'buildah run "${container}" -- /usr/local/bin/glab --version',
            'buildah run "${container}" -- /usr/local/bin/kubectl version --client',
        ),
        "verification-helper lifecycle",
    )


def validate_leaf_job(job: str, arch: str, *, publish: bool) -> None:
    host_arch = {"amd64": "x86_64", "arm64": "aarch64"}[arch]
    kind = "package" if publish else "verify"
    label = f"native {arch} workspace {kind} job"
    expected_stage = "package" if publish else "validate"
    expected_condition = MAIN_CONDITION if publish else MR_CONDITION
    image_var = "package_image" if publish else "verify_image"
    local_image = f'localhost/hermes-workspace-{kind}-{arch}:${{CI_COMMIT_SHA}}'

    if job_tags(job) != [arch]:
        fail(f"{label} tags must be exactly {[arch]!r}, got {job_tags(job)!r}")
    require_direct_rules(job, expected_condition, label)
    for needle in (
        f"stage: {expected_stage}",
        "needs: []",
        f"image: {BUILDAH_IMAGE}",
        "set -eu",
        f'test "$(uname -m)" = {host_arch}',
        f'{image_var}="{local_image}"',
        "trap cleanup EXIT",
        f'buildah rmi "${{{image_var}}}"',
        "buildah build",
        "--format docker",
        f"--arch {arch}",
        f'--build-arg "TARGETARCH={arch}"',
        '--build-arg "OCI_REVISION=${CI_COMMIT_SHA}"',
        f'-t "${{{image_var}}}"',
        "apps/hermes-workspace/image/",
        f'./scripts/verify_hermes_workspace_image.sh "${{{image_var}}}" {arch} "${{CI_COMMIT_SHA}}"',
    ):
        require(job, needle, label)
    if job.count("buildah build") != 1:
        fail(f"{label} must build exactly once")
    forbid(job, r"\bfor\s+(?:ARCH|arch)\b", f"{label} architecture loop")
    forbid(job, r"CI_COMMIT_SHORT_SHA", f"{label} short-SHA reference")

    foreign_arch = "arm64" if arch == "amd64" else "amd64"
    foreign_host = "aarch64" if arch == "amd64" else "x86_64"
    forbid(job, rf"\b(?:{foreign_arch}|{foreign_host})\b", f"{label} foreign architecture")
    ordered(
        job,
        (
            f'test "$(uname -m)" = {host_arch}',
            "buildah build",
            f'./scripts/verify_hermes_workspace_image.sh "${{{image_var}}}" {arch} "${{CI_COMMIT_SHA}}"',
        ),
        f"{label} build and verification",
    )

    if not publish:
        for needle in (
            "buildah rm --all",
            "buildah rmi --all",
        ):
            require(job, needle, f"{label} local Buildah cleanup")
        for pattern, forbidden_label in (
            (r"\bbuildah\s+(?:login|push|manifest)\b", "registry or publication command"),
            (r"CI_REGISTRY(?:_IMAGE|_USER|_PASSWORD)?", "registry credential/reference"),
            (r"--cache-(?:from|to)", "registry cache"),
            (r"before_script:\s*\*buildah_before", "authenticated setup"),
        ):
            forbid(job, pattern, f"{label} {forbidden_label}")
        return

    for needle in (
        "before_script: *buildah_before",
        f'--cache-from "${{HERMES_WORKSPACE_IMAGE_CACHE}}-{arch}"',
        f'--cache-to "${{HERMES_WORKSPACE_IMAGE_CACHE}}-{arch}"',
        'buildah push --format v2s2 \\',
        '--digestfile "${digest_file}"',
        f'"docker://${{HERMES_WORKSPACE_IMAGE}}:${{CI_COMMIT_SHA}}-{arch}"',
        'digest="$(cat "${digest_file}")"',
        "grep -Eq '^sha256:[0-9a-f]{64}$'",
        f'printf \'%s\' "${{HERMES_WORKSPACE_IMAGE}}@${{digest}}" > {arch}.ref',
        f'test "$(wc -l < {arch}.ref)" -eq 0',
        f'test "$(cat {arch}.ref)" = "${{HERMES_WORKSPACE_IMAGE}}@${{digest}}"',
        "artifacts:",
        f"- {arch}.ref",
    ):
        require(job, needle, label)
    if job.count("buildah push") != 1:
        fail(f"{label} must push exactly one immutable child")
    forbid(job, r"\bbuildah\s+manifest\b", f"{label} manifest publication")
    ordered(
        job,
        (
            f'./scripts/verify_hermes_workspace_image.sh "${{{image_var}}}" {arch} "${{CI_COMMIT_SHA}}"',
            "buildah push --format v2s2",
            f"printf '%s' \"${{HERMES_WORKSPACE_IMAGE}}@${{digest}}\" > {arch}.ref",
        ),
        f"{label} verify-before-push and digest artifact",
    )
    workspace_lines = "\n".join(
        line for line in job.splitlines() if "HERMES_WORKSPACE_IMAGE" in line
    )
    forbid(workspace_lines, r"(?:^|[/:])latest(?:\s|$)", f"{label} mutable publication")


def validate_buildah_before(ci: str) -> None:
    block = top_level_block(ci, ".buildah_before")
    require(block, f"  - {BUILDAH_LOGIN}\n", "stdin-only Buildah registry login")
    login_lines = "\n".join(line for line in block.splitlines() if "buildah login" in line)
    if login_lines.count("buildah login") != 1:
        fail("shared Buildah setup must log in exactly once")
    forbid(login_lines, r"(?:^|\s)-p(?:\s|=|$)", "Buildah password argv short option")
    forbid(login_lines, r"--password(?:\s|=)", "Buildah password argv long option")


def extract_inline_shell_function(job: str, name: str) -> str:
    match = re.search(
        rf"^      (?P<function>{re.escape(name)}\(\) \{{\n.*?^      \}})\n",
        job,
        re.MULTILINE | re.DOTALL,
    )
    if match is None:
        fail(f"cannot mechanically extract inline shell function: {name}")
    lines = match.group("function").splitlines()
    if any(line and not line.startswith("      ") for line in lines[1:]):
        fail(f"inline shell function has unexpected YAML indentation: {name}")
    return "\n".join([lines[0], *(line[6:] for line in lines[1:])]) + "\n"


def validate_assert_index_fixtures(job: str) -> None:
    function = extract_inline_shell_function(job, "assert_index")
    amd64_digest = "sha256:" + "a" * 64
    arm64_digest = "sha256:" + "b" * 64
    valid = f"""{{
    "schemaVersion": 2,
    "mediaType": "{DOCKER_LIST_MEDIA_TYPE}",
    "manifests": [
        {{
            "mediaType": "{DOCKER_MANIFEST_MEDIA_TYPE}",
            "digest": "{amd64_digest}",
            "size": 1000,
            "platform": {{
                "architecture": "amd64",
                "os": "linux"
            }}
        }},
        {{
            "mediaType": "{DOCKER_MANIFEST_MEDIA_TYPE}",
            "digest": "{arm64_digest}",
            "size": 1001,
            "platform": {{
                "architecture": "arm64",
                "os": "linux"
            }}
        }}
    ]
}}
"""
    swapped_pair = valid.replace(amd64_digest, "sha256:SWAP", 1)
    swapped_pair = swapped_pair.replace(arm64_digest, amd64_digest, 1)
    swapped_pair = swapped_pair.replace("sha256:SWAP", arm64_digest, 1)
    malformed_descriptor = f"""        {{
            "digest": "sha256:{'c' * 64}",
            "platform": {{
                "architecture": "s390x",
                "os": "linux"
            }}
        }}
"""
    extra_malformed_descriptor = valid.replace(
        "        }\n    ]\n",
        f"        }},\n{malformed_descriptor}    ]\n",
        1,
    )
    wrong_media_type = valid.replace(DOCKER_LIST_MEDIA_TYPE, "application/vnd.oci.image.index.v1+json", 1)
    fixtures = {
        "valid": (valid, True),
        "swapped-pair": (swapped_pair, False),
        "extra-malformed-descriptor": (extra_malformed_descriptor, False),
        "wrong-mediaType": (wrong_media_type, False),
    }
    script = (
        "set -u\n"
        f"amd64_digest={amd64_digest}\n"
        f"arm64_digest={arm64_digest}\n"
        f"{function}"
        'assert_index "$1"\n'
    )
    with TemporaryDirectory(prefix="hermes-workspace-index-fixtures-") as temporary:
        fixture_dir = Path(temporary).resolve()
        if fixture_dir == ROOT or ROOT in fixture_dir.parents:
            fail("index fixtures must be created outside the repository")
        for label, (contents, expected) in fixtures.items():
            fixture = fixture_dir / f"{label}.json"
            fixture.write_text(contents)
            result = subprocess.run(
                ["bash", "-c", script, "assert-index-fixture", str(fixture)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            accepted = result.returncode == 0
            if accepted != expected:
                outcome = "accepted" if accepted else "rejected"
                fail(
                    f"actual assert_index function {outcome} {label} fixture; "
                    f"stderr={result.stderr.strip()!r}"
                )


def validate_publisher(job: str) -> None:
    label = "workspace index publisher"
    if re.search(r"^  tags:", job, re.MULTILINE):
        fail(f"{label} must be untagged, got {job_tags(job)!r}")
    require_direct_rules(job, MAIN_CONDITION, label)
    expected_needs = """  needs:
    - job: package:hermes-workspace:amd64
      artifacts: true
    - job: package:hermes-workspace:arm64
      artifacts: true
    - job: validate:manifests
      artifacts: false
"""
    needs_match = re.search(r"^  needs:\n.*?(?=^  image:)", job, re.MULTILINE | re.DOTALL)
    if needs_match is None or needs_match.group(0) != expected_needs:
        fail("workspace index fan-in must need exactly both leaf artifacts and manifest validation")
    for needle in (
        "stage: publish",
        f"image: {BUILDAH_IMAGE}",
        "before_script: *buildah_before",
        'manifest="localhost/hermes-workspace-index-${CI_PIPELINE_ID}-${CI_JOB_ID}:${CI_COMMIT_SHA}"',
        'buildah manifest rm "${manifest}"',
        "trap cleanup EXIT",
        'amd64_ref="$(cat amd64.ref)"',
        'arm64_ref="$(cat arm64.ref)"',
        'test "$(wc -l < amd64.ref)" -eq 0',
        'test "$(wc -l < arm64.ref)" -eq 0',
        'test "${amd64_ref}" = "${HERMES_WORKSPACE_IMAGE}@${amd64_digest}"',
        'test "${arm64_ref}" = "${HERMES_WORKSPACE_IMAGE}@${arm64_digest}"',
        'test "${amd64_ref}" != "${arm64_ref}"',
        "grep -Eq '^sha256:[0-9a-f]{64}$'",
        "assert_index() {",
        "awk \\",
        f'expected_list = "{DOCKER_LIST_MEDIA_TYPE}"',
        f'expected_manifest = "{DOCKER_MANIFEST_MEDIA_TYPE}"',
        "finish_descriptor()",
        "descriptor_count == 2",
        "seen_amd64 == 1",
        "seen_arm64 == 1",
        "schema_count == 1",
        "top_media_count == 1",
        "manifest_array_count == 1",
        'buildah manifest create "${manifest}"',
        'buildah manifest add "${manifest}" "docker://${amd64_ref}"',
        'buildah manifest add "${manifest}" "docker://${arm64_ref}"',
        'buildah manifest inspect "${manifest}" > "${local_index_json}"',
        'buildah manifest push --all --format v2s2 \\',
        '--digestfile "${index_digest_file}"',
        '"docker://${HERMES_WORKSPACE_IMAGE}:${CI_COMMIT_SHA}"',
        'index_digest="$(cat "${index_digest_file}")"',
        'printf \'%s\' "${HERMES_WORKSPACE_IMAGE}@${index_digest}" > hermes-workspace-image.ref',
        'test "$(wc -l < hermes-workspace-image.ref)" -eq 0',
        'test "$(cat hermes-workspace-image.ref)" = "${HERMES_WORKSPACE_IMAGE}@${index_digest}"',
        'buildah manifest inspect "docker://${HERMES_WORKSPACE_IMAGE}@${index_digest}" > "${published_index_json}"',
        "- hermes-workspace-image.ref",
    ):
        require(job, needle, label)
    if job.count("buildah manifest add") != 2:
        fail(f"{label} must add exactly two digest-addressed children")
    if job.count("buildah manifest push") != 1:
        fail(f"{label} must push exactly one index")
    if job.count("buildah manifest inspect") != 2:
        fail(f"{label} must inspect the local and published index")
    for pattern, forbidden_label in (
        (r"\bbuildah\s+(?:build|run)\b", "image execution/build"),
        (r"CI_COMMIT_SHORT_SHA", "short-SHA reference"),
        (r"(?:^|[/:])latest(?:\s|$)", "mutable latest reference"),
        (r'docker://\$\{HERMES_WORKSPACE_IMAGE\}:\$\{CI_COMMIT_SHA\}-(?:amd64|arm64)', "tag-based child"),
        (r"\bgrep\s+-Ec\b", "independent descriptor field counts"),
        (r"\b(?:jq|python[0-9.]*)\b", "non-guaranteed JSON parser"),
    ):
        forbid(job, pattern, f"{label} {forbidden_label}")
    ordered(
        job,
        (
            'buildah manifest add "${manifest}" "docker://${amd64_ref}"',
            'buildah manifest add "${manifest}" "docker://${arm64_ref}"',
            'buildah manifest inspect "${manifest}" > "${local_index_json}"',
            'assert_index "${local_index_json}"',
            "buildah manifest push --all --format v2s2",
            'buildah manifest inspect "docker://${HERMES_WORKSPACE_IMAGE}@${index_digest}" > "${published_index_json}"',
            'assert_index "${published_index_json}"',
        ),
        "workspace index validation and publication",
    )


def validate_ci(ci: str, validation_entrypoint: str) -> None:
    require(ci, "HERMES_WORKSPACE_IMAGE: ${CI_REGISTRY_IMAGE}/hermes-workspace", "workspace image variable")
    require(ci, "HERMES_WORKSPACE_IMAGE_CACHE: ${CI_REGISTRY_IMAGE}/hermes-workspace/cache", "workspace cache variable")
    require(ci, "  - publish", "final publish stage")
    stages = top_level_block(ci, "stages")
    if stages.rstrip().splitlines()[-1] != "  - publish":
        fail("publish must be the final pipeline stage")
    validate_buildah_before(ci)
    blocks = top_level_blocks(ci)
    expected_jobs = {
        "verify:hermes-workspace:amd64",
        "verify:hermes-workspace:arm64",
        "package:hermes-workspace:amd64",
        "package:hermes-workspace:arm64",
        "publish:hermes-workspace:index",
    }
    actual_jobs = {key for key in blocks if "hermes-workspace" in key}
    if actual_jobs != expected_jobs:
        fail(f"workspace CI job set must be exactly {sorted(expected_jobs)!r}, got {sorted(actual_jobs)!r}")

    expected_tag_map = {
        "verify:hermes-workspace:amd64": ["amd64"],
        "verify:hermes-workspace:arm64": ["arm64"],
        "package:hermes-workspace:amd64": ["amd64"],
        "package:hermes-workspace:arm64": ["arm64"],
    }
    actual_tag_map = {key: job_tags(block) for key, block in blocks.items() if job_tags(block)}
    if actual_tag_map != expected_tag_map:
        fail(f"CI architecture tag map must be exactly {expected_tag_map!r}, got {actual_tag_map!r}")

    validate_leaf_job(blocks["verify:hermes-workspace:amd64"], "amd64", publish=False)
    validate_leaf_job(blocks["verify:hermes-workspace:arm64"], "arm64", publish=False)
    validate_leaf_job(blocks["package:hermes-workspace:amd64"], "amd64", publish=True)
    validate_leaf_job(blocks["package:hermes-workspace:arm64"], "arm64", publish=True)
    validate_publisher(blocks["publish:hermes-workspace:index"])
    buildah_refs = re.findall(
        r"quay\.io/buildah/stable@sha256:[0-9a-f]{64}",
        ci,
    )
    if buildah_refs != [BUILDAH_IMAGE] * 5:
        fail("exactly four native leaves and one index publisher must use pinned Buildah")

    validation_rules = top_level_block(ci, ".validate_manifest_rules")
    helper_path = "scripts/verify_hermes_workspace_image.sh"
    if validation_rules.count(helper_path) != 2:
        fail("both manifest validation rule lists must trigger on verification-helper changes")
    validator_path = "scripts/test_validate_hermes_workspace_image.py"
    if ci.count(validator_path) != 2:
        fail("both manifest validation change lists must trigger the workspace validator")
    command = f'python3 "${{repo_root}}/{validator_path}"'
    if validation_entrypoint.count(command) != 1:
        fail("repository validation entrypoint must run the workspace image validator exactly once")


def replaced(text: str, old: str, new: str, label: str) -> str:
    mutant = text.replace(old, new, 1)
    if mutant == text:
        fail(f"cannot construct mutation: {label}")
    return mutant


def mutated_block(ci: str, key: str, old: str, new: str, label: str) -> str:
    block = top_level_block(ci, key)
    mutant_block = replaced(block, old, new, label)
    return replaced(ci, block, mutant_block, label)


def require_rejected(check: Callable[[], None], label: str) -> None:
    try:
        check()
    except AssertionError:
        return
    fail(f"{label} mutation escaped validation")


def validate_dockerfile_mutations(text: str) -> None:
    mutations = {
        "missing arm64 checksum": replaced(
            text,
            f'ARG UV_ARM64_SHA256={PINNED_ARGUMENTS["UV_ARM64_SHA256"]}\n',
            "",
            "missing arm64 checksum",
        ),
        "swapped arm64 checksum mapping": replaced(
            text,
            'UV_SHA256="${UV_ARM64_SHA256}"; \\',
            'UV_SHA256="${UV_AMD64_SHA256}"; \\',
            "swapped arm64 checksum mapping",
        ),
        "unknown architecture fallback": replaced(
            text,
            'echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; \\\n        exit 1; \\',
            'UV_TARGET=x86_64-unknown-linux-gnu; \\\n        UV_SHA256="${UV_AMD64_SHA256}"; \\',
            "unknown architecture fallback",
        ),
    }
    for label, mutant in mutations.items():
        require_rejected(lambda mutant=mutant: validate_dockerfile(mutant), label)


def validate_ci_mutations(ci: str, validation_entrypoint: str) -> None:
    mutants: dict[str, str] = {}
    login_line = f"  - {BUILDAH_LOGIN}\n"
    mutants["short password argv"] = replaced(
        ci,
        login_line,
        '  - buildah login --username "$CI_REGISTRY_USER" -p "$CI_REGISTRY_PASSWORD" "$CI_REGISTRY"\n',
        "short password argv",
    )
    mutants["long password argv"] = replaced(
        ci,
        login_line,
        '  - buildah login --username "$CI_REGISTRY_USER" --password "$CI_REGISTRY_PASSWORD" "$CI_REGISTRY"\n',
        "long password argv",
    )
    mutants["wrong arm64 verifier tag"] = mutated_block(
        ci,
        "verify:hermes-workspace:arm64",
        "    - arm64\n",
        "    - amd64\n",
        "wrong arm64 verifier tag",
    )
    for command in ("buildah login registry.invalid", "buildah push local.invalid/image"):
        label = f"MR {command.split()[1]}"
        mutants[label] = mutated_block(
            ci,
            "verify:hermes-workspace:amd64",
            "      set -eu\n",
            f"      set -eu\n      {command}\n",
            label,
        )

    package_key = "package:hermes-workspace:amd64"
    helper_call = '      ./scripts/verify_hermes_workspace_image.sh "${package_image}" amd64 "${CI_COMMIT_SHA}"\n'
    package = top_level_block(ci, package_key)
    reordered = replaced(package, helper_call, "", "package push before verification")
    reordered = replaced(
        reordered,
        '      digest="$(cat "${digest_file}")"\n',
        f'{helper_call}      digest="$(cat "${{digest_file}}")"\n',
        "package push before verification",
    )
    mutants["package push before verification"] = replaced(
        ci, package, reordered, "package push before verification"
    )
    mutants["tagged publisher"] = mutated_block(
        ci,
        "publish:hermes-workspace:index",
        "  stage: publish\n",
        "  stage: publish\n  tags:\n    - amd64\n",
        "tagged publisher",
    )
    mutants["missing validate fan-in need"] = mutated_block(
        ci,
        "publish:hermes-workspace:index",
        "    - job: validate:manifests\n      artifacts: false\n",
        "",
        "missing validate fan-in need",
    )
    mutants["tag-based manifest child"] = mutated_block(
        ci,
        "publish:hermes-workspace:index",
        '"docker://${amd64_ref}"',
        '"docker://${HERMES_WORKSPACE_IMAGE}:${CI_COMMIT_SHA}-amd64"',
        "tag-based manifest child",
    )
    mutants["latest index tag"] = mutated_block(
        ci,
        "publish:hermes-workspace:index",
        '"docker://${HERMES_WORKSPACE_IMAGE}:${CI_COMMIT_SHA}"',
        '"docker://${HERMES_WORKSPACE_IMAGE}:latest"',
        "latest index tag",
    )
    mutants["short-SHA index tag"] = mutated_block(
        ci,
        "publish:hermes-workspace:index",
        '"docker://${HERMES_WORKSPACE_IMAGE}:${CI_COMMIT_SHA}"',
        '"docker://${HERMES_WORKSPACE_IMAGE}:${CI_COMMIT_SHORT_SHA}"',
        "short-SHA index tag",
    )
    mutants["OCI index publication"] = mutated_block(
        ci,
        "publish:hermes-workspace:index",
        "buildah manifest push --all --format v2s2",
        "buildah manifest push --all --format oci",
        "OCI index publication",
    )
    mutants["helper not invoked"] = mutated_block(
        ci,
        "package:hermes-workspace:arm64",
        '      ./scripts/verify_hermes_workspace_image.sh "${package_image}" arm64 "${CI_COMMIT_SHA}"\n',
        "",
        "helper not invoked",
    )
    for label, mutant in mutants.items():
        require_rejected(
            lambda mutant=mutant: validate_ci(mutant, validation_entrypoint),
            label,
        )


def validate() -> None:
    texts = validate_file_inventory()
    validate_dockerfile(texts["Dockerfile"])
    validate_dockerfile_mutations(texts["Dockerfile"])
    validate_sshd_config(texts["sshd_config"])
    validate_entrypoint(texts["entrypoint.sh"])
    validate_healthcheck(texts["healthcheck.py"])
    validate_readme(texts["README.md"])
    validate_dockerignore(texts[".dockerignore"])
    helper = VERIFY_HELPER.read_text()
    validate_verify_helper(helper)
    ci = CI.read_text()
    validation_entrypoint = VALIDATION_ENTRYPOINT.read_text()
    validate_ci(ci, validation_entrypoint)
    validate_ci_mutations(ci, validation_entrypoint)
    validate_assert_index_fixtures(top_level_block(ci, "publish:hermes-workspace:index"))


if __name__ == "__main__":
    try:
        validate()
    except (AssertionError, OSError) as error:
        print(f"Hermes workspace image validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
    print("Hermes workspace image validation passed")
