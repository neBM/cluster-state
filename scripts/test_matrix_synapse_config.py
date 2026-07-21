#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "PyYAML==6.0.3",
# ]
# ///
"""Regression checks for the Synapse/MAS delegated-authentication contract."""

from __future__ import annotations

import subprocess
from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).resolve().parents[1]
MATRIX_PATH = REPO_ROOT / "apps" / "matrix"
MAS_SERVICE_ENDPOINT = "http://mas.default.svc.cluster.local:8081/"
MAS_SHARED_SECRET_PLACEHOLDER = "MAS_ADMIN_TOKEN_PLACEHOLDER"


def render_matrix() -> list[dict]:
    rendered = subprocess.run(
        ["kubectl", "kustomize", str(MATRIX_PATH)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [document for document in yaml.safe_load_all(rendered) if document]


def configmap(documents: list[dict], name: str) -> dict:
    matches = [
        document
        for document in documents
        if document.get("kind") == "ConfigMap"
        and document.get("metadata", {}).get("name") == name
    ]
    if len(matches) != 1:
        raise AssertionError(f"expected one ConfigMap/{name}, found {len(matches)}")
    return matches[0]


def main() -> None:
    documents = render_matrix()

    synapse_template = configmap(documents, "synapse-config")["data"]["homeserver.yaml"]
    synapse_config = yaml.safe_load(synapse_template)

    experimental = synapse_config.get("experimental_features", {})
    assert "msc3861" not in experimental, (
        "Synapse 1.157 removed experimental_features.msc3861; "
        "use matrix_authentication_service"
    )

    delegated_auth = synapse_config.get("matrix_authentication_service")
    assert delegated_auth == {
        "enabled": True,
        "endpoint": MAS_SERVICE_ENDPOINT,
        "secret": MAS_SHARED_SECRET_PLACEHOLDER,
    }, "Synapse must use the stable MAS delegated-authentication configuration"

    mas_template = configmap(documents, "mas-config-template")["data"]["config.yaml"]
    mas_config = yaml.safe_load(mas_template)
    assert mas_config["matrix"]["secret"] == delegated_auth["secret"], (
        "Synapse and MAS must use the same delegated-authentication shared secret"
    )

    print("Matrix Synapse/MAS delegated-authentication contract is valid")


if __name__ == "__main__":
    main()
