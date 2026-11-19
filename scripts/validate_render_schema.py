#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML==6.0.3"]
# ///
"""Render repository entrypoints, then validate their actual YAML (never a cluster)."""

import hashlib
import io
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

import yaml

ROOT = Path(__file__).resolve().parent.parent
FLUX_SCHEMA_VERSION = "0.17.0"
# Official immutable release assets and their published SHA256 checksums:
# https://github.com/fluxcd/flux-schema/releases/tag/v0.17.0
ARCHIVE_SHA256 = {
    "linux_amd64": "d9a429f6c1c5fe687a1eee25a0c130e4d7abbc560d497a4ee9054ef4dff621ee",
    "linux_arm64": "305a717fc4bcdff3e117aa269e7d6f8224db98c399b5db7ac1cd7da02960db2f",
    "darwin_amd64": "991099f2ebdfca60a5d9d4a64578d0259dfcda2ac388fb0a698ee31950f04e81",
    "darwin_arm64": "f98afcba4ef7a135d967c1e724645bdd4fc49aa579ebe85149aa9daab79c9098",
}
# "latest" is a directory name INSIDE an immutable release commit, not a
# moving catalog. Do not use the CLI's default/ecosystem aliases here.
SCHEMA_LOCATIONS = (
    "https://raw.githubusercontent.com/fluxcd/flux-schema/"
    "4c71b2098ba84b738d811877463f5a2b2bfe443f/catalog/latest",
    "https://raw.githubusercontent.com/controlplaneio-fluxcd/schema-catalog/"
    "f6d98a45bed8110f8359ca0045370eeb9519c57b/catalog",
)
BOOTSTRAP = "clusters/k3s-homelab/flux-system"
# Retain the supported storage aggregate as well as its real Flux leaf paths.
# The GitLab candidates are intentionally NOT active in the Flux root.
EXTRA_PATHS = ("infrastructure/storage", "apps/gitlab-helm", "apps/gitlab-redis")
CLUSTER_SCOPED = {
    "Bucket", "BucketAccessClass", "BucketClass", "ClusterIssuer", "ClusterRole",
    "ClusterRoleBinding", "CSIDriver", "CustomResourceDefinition", "DeviceClass",
    "MutatingWebhookConfiguration", "Namespace", "Node", "PersistentVolume",
    "StorageClass", "ValidatingWebhookConfiguration",
}
OFFLINE_ENV = {**os.environ, "KUBECONFIG": os.devnull}


def schema_tool(directory):
    """Use an exact-version tool or download a verified release into task scratch."""
    executable = os.environ.get("FLUX_SCHEMA_BIN") or shutil.which("flux-schema")
    if not executable:
        machine = {"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(platform.machine())
        target = f"{platform.system().lower()}_{machine}"
        if target not in ARCHIVE_SHA256:
            raise ValueError(f"unsupported platform {target}; supply FLUX_SCHEMA_BIN v{FLUX_SCHEMA_VERSION}")
        asset = f"flux-schema_{FLUX_SCHEMA_VERSION}_{target}.tar.gz"
        url = f"https://github.com/fluxcd/flux-schema/releases/download/v{FLUX_SCHEMA_VERSION}/{asset}"
        print(f"Fetching checksum-pinned {asset} into task scratch", flush=True)
        with urllib.request.urlopen(url, timeout=60) as response:
            archive = response.read()
        if hashlib.sha256(archive).hexdigest() != ARCHIVE_SHA256[target]:
            raise ValueError(f"checksum mismatch for {url}")
        executable = str(directory / "flux-schema")
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as bundle:
            # Read just the binary; never extract archive paths onto the filesystem.
            source = bundle.extractfile("flux-schema")
            if source is None:
                raise ValueError(f"binary missing from {asset}")
            with source:
                Path(executable).write_bytes(source.read())
        Path(executable).chmod(0o700)
    version = subprocess.check_output([executable, "version"], text=True, env=OFFLINE_ENV).strip()
    if version != FLUX_SCHEMA_VERSION:
        raise ValueError(f"flux-schema {FLUX_SCHEMA_VERSION} required, got {version!r}")
    return executable


def local_path(path):
    candidate = (ROOT / path).resolve()
    if not candidate.is_relative_to(ROOT) or not candidate.is_dir():
        raise ValueError(f"not a repository Kustomize directory: {path}")
    return candidate.relative_to(ROOT).as_posix()


def render(path):
    command = ["kustomize", "build"] if shutil.which("kustomize") else ["kubectl", "kustomize"]
    print(f"Rendering {path}", flush=True)
    return subprocess.check_output(command + [str(ROOT / path)], text=True, env=OFFLINE_ENV)


def children(documents):
    """Follow only Flux paths from this repository, not arbitrary YAML files."""
    for doc in documents:
        if doc.get("kind") != "Kustomization" or not doc.get("apiVersion", "").startswith("kustomize.toolkit.fluxcd.io/"):
            continue
        source = doc["spec"]["sourceRef"]
        if (source.get("kind"), source.get("name"), source.get("namespace", "flux-system")) != (
            "GitRepository", "cluster-state", "flux-system"
        ):
            raise ValueError(f"cannot cover external Flux sourceRef: {source}")
        yield local_path(doc["spec"]["path"])


def check_namespaces(path, documents):
    # Preserve the existing explicit-namespace contract; JSON Schema alone
    # cannot require a namespace on otherwise valid namespaced resources.
    for doc in documents:
        if doc["kind"] not in CLUSTER_SCOPED and not doc.get("metadata", {}).get("namespace"):
            raise ValueError(f"{path}: {doc['kind']}/{doc.get('metadata', {}).get('name', '')} "
                             "is namespaced but metadata.namespace is missing")


def rendered_paths(requested):
    # Explicit paths mean ONLY those paths: do not discover/recurse into Flux
    # children or launch application tests. Defaults walk the rendered root graph.
    queue = [local_path(path) for path in requested] if requested else [BOOTSTRAP, *EXTRA_PATHS]
    seen = set()
    for path in queue:
        if path in seen:
            continue
        seen.add(path)
        output = render(path)
        documents = [doc for doc in yaml.safe_load_all(output) if doc is not None]
        if not documents:
            raise ValueError(f"{path}: render produced no resources")
        check_namespaces(path, documents)
        if not requested:
            queue.extend(children(documents))
        yield path, output


def validate(requested):
    with tempfile.TemporaryDirectory(prefix="cluster-render-schema-") as temporary:
        directory = Path(temporary)
        tool = schema_tool(directory)
        # Always pass our own config. Neither an ambient FLUX_SCHEMA_CONFIG nor
        # executable-adjacent config may silently add skips or moving catalogs.
        config = directory / "config.yaml"
        config.write_text(yaml.safe_dump({
            "apiVersion": "schema.plugin.fluxcd.io/v1beta1", "kind": "Config",
            "validate": {"schemaLocation": list(SCHEMA_LOCATIONS),
                         "skipMissingSchemas": False, "skipCELRules": False},
        }))
        files = []
        for index, (path, output) in enumerate(rendered_paths(requested)):
            rendered = directory / f"{index:02d}-{path.replace('/', '_')}.yaml"
            rendered.write_text(output)
            files.append(str(rendered))
        print(f"Schema-checking {len(files)} rendered entrypoints with flux-schema {FLUX_SCHEMA_VERSION}", flush=True)
        # Independent files preserve overlap between aggregates/leaf entrypoints;
        # validating Flux objects is not counted as validating their children.
        subprocess.run([tool, "validate", "--config", str(config), *files], check=True, env=OFFLINE_ENV)


if __name__ == "__main__":
    try:
        validate(sys.argv[1:])
    except (OSError, ValueError, subprocess.CalledProcessError, yaml.YAMLError) as error:
        sys.exit(f"render/schema validation failed: {error}")
