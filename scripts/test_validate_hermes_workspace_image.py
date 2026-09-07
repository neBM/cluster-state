#!/usr/bin/env python3
"""Validate the dedicated Hermes SSH workspace image production contract."""

from __future__ import annotations

import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parent.parent
IMAGE = ROOT / "apps/hermes-workspace/image"
CI = ROOT / ".gitlab-ci.yml"
VALIDATION_ENTRYPOINT = ROOT / "scripts/validate_kustomize.sh"
AMD64_EXECUTOR_NODE_SELECTOR = (
    ROOT
    / "infrastructure/shared-services/gitlab-runner/runners/amd64/fragments/80-node-selector.toml"
)
# Repository policy only; server registration and actual job-runner identity are live CI evidence.
HERMES_WORKSPACE_JOB_TAG = "amd64"

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
    "GLAB_VERSION": "1.116.0",
    "GLAB_AMD64_SHA256": "173cc61ea94c562f2ccd831f320d25b73982192e82810064552282482e3713ea",
    "KUBECTL_VERSION": "v1.34.11",
    "KUBECTL_AMD64_SHA256": "8efbb9435132a190920eb65a47a8c1ecf755ad85ab57a600c9bedbab460bb7a8",
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

    package_match = re.search(
        r"apt-get install --yes --no-install-recommends(?P<packages>.*?)&&\s*rm -rf /var/lib/apt/lists/\*",
        text,
        re.DOTALL,
    )
    if package_match is None:
        fail("missing deterministic no-recommends apt installation and index cleanup")
    package_words = set(re.findall(r"\b[a-z][a-z0-9.+-]*\b", package_match.group("packages")))
    missing_packages = REQUIRED_PACKAGES - package_words
    if missing_packages:
        fail(f"missing required distro packages: {sorted(missing_packages)!r}")

    for pattern in FORBIDDEN_TOOL_PATTERNS:
        forbid(package_match.group("packages"), pattern, "workspace package")

    ordered(
        text,
        (
            "printf '#!/bin/sh\\nexit 0\\n' > /usr/local/sbin/ssh-keygen",
            "chmod 0755 /usr/local/sbin/ssh-keygen",
            'test "$(command -v ssh-keygen)" = /usr/local/sbin/ssh-keygen',
            "apt-get install --yes --no-install-recommends",
            "rm -f /usr/local/sbin/ssh-keygen",
            "test -x /usr/bin/ssh-keygen",
            'test "$(command -v ssh-keygen)" = /usr/bin/ssh-keygen',
            'test -z "$(find /etc/ssh -maxdepth 1 -name \'ssh_host_*\' -print -quit)"',
        ),
        "temporary package-configuration ssh-keygen guard",
    )
    forbid(text, r"\bdpkg-divert\b", "ssh-keygen diversion residue")
    forbid(
        text,
        r"\brm\s+(?:-[A-Za-z]*f[A-Za-z]*\s+)?/etc/ssh/ssh_host_",
        "post-generation host-key deletion",
    )

    require(text, 'test "${TARGETARCH}" = amd64', "native amd64 build guard")
    forbid(text, r"\b(?:arm64|aarch64)\b", "foreign architecture support")

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
        "key_count == 0",
        '[[ "$host_mode" == 400 || "$host_mode" == 600 ]]',
        "/usr/sbin/sshd -t -f /etc/ssh/sshd_config",
        "exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config",
    ):
        require(text, needle, "startup safety check")
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
        "single-architecture `linux/amd64`",
        "`k8s-amd64`",
        "commit-SHA tag",
        "digest",
        "Agent Sandbox",
    ):
        require(text, needle, "documented image contract")


def validate_dockerignore(text: str) -> None:
    expected = "**\n!Dockerfile\n!entrypoint.sh\n!healthcheck.py\n!sshd_config\n"
    if text != expected:
        fail(".dockerignore must expose only the exact build inputs")


def validate_executor_node_selector(text: str) -> None:
    tables = re.findall(r"^\[[^\]\n]+\][ \t]*$", text, re.MULTILINE)
    expected_table = "[runners.kubernetes.node_selector]"
    if tables != [expected_table]:
        fail(f"executor fragment TOML tables must be exactly {[expected_table]!r}, got {tables!r}")

    entries = re.findall(
        r'^[ \t]*"kubernetes\.io/arch"[ \t]*=[^\n]*$',
        text,
        re.MULTILINE,
    )
    expected_entry = '  "kubernetes.io/arch" = "amd64"'
    if entries != [expected_entry]:
        fail(
            "executor job-pod architecture selector must be exactly "
            f"{expected_entry!r}, got {entries!r}"
        )


def validate_executor_node_selector_mutation(text: str) -> None:
    mutant = text.replace(
        '  "kubernetes.io/arch" = "amd64"',
        '  "kubernetes.io/arch" = "arm64"',
        1,
    )
    if mutant == text:
        fail("cannot construct the arm64 executor node-selector mutation")
    try:
        validate_executor_node_selector(mutant)
    except AssertionError:
        return
    fail("arm64 executor job-pod selector mutation escaped validation")


def validate_ci(ci: str, validation_entrypoint: str, executor_node_selector: str) -> None:
    require(ci, "HERMES_WORKSPACE_IMAGE: ${CI_REGISTRY_IMAGE}/hermes-workspace", "workspace image variable")
    require(ci, "HERMES_WORKSPACE_IMAGE_CACHE: ${CI_REGISTRY_IMAGE}/hermes-workspace/cache", "workspace cache variable")
    rules = top_level_block(ci, ".rules_hermes_workspace")
    require(rules, 'if: $CI_COMMIT_BRANCH == "main"', "main-only image publication")
    require(rules, "apps/hermes-workspace/image/**/*", "image publication change rule")
    validate_executor_node_selector(executor_node_selector)

    job = top_level_block(ci, "package:hermes-workspace")
    tags_match = re.search(r"^  tags:\n(?P<tags>(?:    - [^\n]+\n)+)", job, re.MULTILINE)
    if tags_match is None:
        fail("workspace package job must select the native amd64 runner")
    job_tags = re.findall(r"^    - ([^\s]+)\s*$", tags_match.group("tags"), re.MULTILINE)
    if job_tags != [HERMES_WORKSPACE_JOB_TAG]:
        fail(
            "workspace package job tags must be exactly "
            f"{[HERMES_WORKSPACE_JOB_TAG]!r}, got {job_tags!r}"
        )

    tagged_blocks = [
        key
        for key, block in top_level_blocks(ci).items()
        if re.search(r"^  tags:\s*$", block, re.MULTILINE)
    ]
    if tagged_blocks != ["package:hermes-workspace"]:
        fail(
            "only the native Hermes workspace package job may be architecture-routed, "
            f"got {tagged_blocks!r}"
        )

    for needle in (
        "stage: package",
        "image: quay.io/buildah/stable:latest",
        "before_script: *buildah_before",
        "--arch amd64",
        "--build-arg TARGETARCH=amd64",
        "--build-arg OCI_REVISION=${CI_COMMIT_SHA}",
        "-t ${HERMES_WORKSPACE_IMAGE}:${CI_COMMIT_SHA}",
        "apps/hermes-workspace/image/",
        "buildah push --format v2s2",
        "--digestfile apps/hermes-workspace/image/hermes-workspace-image.digest",
        "docker://${HERMES_WORKSPACE_IMAGE}:${CI_COMMIT_SHA}",
        'digest="$(cat apps/hermes-workspace/image/hermes-workspace-image.digest)"',
        'test "$(printf \'%s\' "${digest}" | wc -c)" -eq 71',
        "printf '%s\\n' \"${digest}\" | grep -Eq '^sha256:[0-9a-f]{64}$'",
        "${HERMES_WORKSPACE_IMAGE}:${CI_COMMIT_SHA}",
        "artifacts:",
        "apps/hermes-workspace/image/hermes-workspace-image.digest",
        "rules:",
        "*rules_hermes_workspace",
    ):
        require(job, needle, "workspace package job")
    if job.count("buildah build") != 1 or job.count("buildah push") != 1:
        fail("workspace package job must build and push exactly one native image")
    forbid(job, r"\b(?:arm64|aarch64)\b", "foreign workspace image build")
    forbid(job, r"\bbuildah\s+manifest\b", "multi-architecture workspace index")
    forbid(job, r"\bfor\s+ARCH\b", "workspace architecture loop")
    forbid(job, r"CI_COMMIT_SHORT_SHA", "short image tag")
    workspace_references = "\n".join(
        line for line in job.splitlines() if "HERMES_WORKSPACE_IMAGE" in line
    )
    forbid(workspace_references, r"(?:^|[/:])latest(?:\s|$)", "mutable workspace publication")

    validator_path = "scripts/test_validate_hermes_workspace_image.py"
    if ci.count(validator_path) != 2:
        fail("both manifest validation change lists must trigger the workspace validator")
    command = f'python3 "${{repo_root}}/{validator_path}"'
    if validation_entrypoint.count(command) != 1:
        fail("repository validation entrypoint must run the workspace image validator exactly once")


def validate() -> None:
    texts = validate_file_inventory()
    validate_dockerfile(texts["Dockerfile"])
    validate_sshd_config(texts["sshd_config"])
    validate_entrypoint(texts["entrypoint.sh"])
    validate_healthcheck(texts["healthcheck.py"])
    validate_readme(texts["README.md"])
    validate_dockerignore(texts[".dockerignore"])
    executor_node_selector = AMD64_EXECUTOR_NODE_SELECTOR.read_text()
    validate_ci(
        CI.read_text(),
        VALIDATION_ENTRYPOINT.read_text(),
        executor_node_selector,
    )
    validate_executor_node_selector_mutation(executor_node_selector)


if __name__ == "__main__":
    try:
        validate()
    except (AssertionError, OSError) as error:
        print(f"Hermes workspace image validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
    print("Hermes workspace image validation passed")
