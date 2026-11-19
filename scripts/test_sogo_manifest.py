#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML==6.0.3"]
# ///
"""Focused SOGo packaging contracts; run with uv run --locked --script this-file."""

from __future__ import annotations

import copy
from pathlib import Path
import subprocess
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


def check_contract(documents: list[dict]) -> None:
    def resource(kind: str, name: str = "sogo") -> dict:
        matches = [d for d in documents if d["kind"] == kind and d["metadata"]["name"] == name]
        assert len(matches) == 1, f"expected one {kind}/{name}"
        return matches[0]

    pod = resource("Deployment")["spec"]["template"]["spec"]
    main = next(c for c in pod["containers"] if c["name"] == "sogo")
    init = next(c for c in pod["initContainers"] if c["name"] == "init-config")
    http = next(p for p in main["ports"] if p["name"] == "http")
    assert http["containerPort"] == 8080 and http["protocol"] == "TCP", "nonroot HTTP listener must be 8080/TCP"
    env = {e["name"]: e.get("value") for e in main.get("env", [])}
    assert env.get("HTTP_PORT", "8080") == "8080", "HTTP_PORT must match the port chain"
    for probe in ("livenessProbe", "readinessProbe"):
        request = main[probe]["httpGet"]
        assert request["port"] == "http" and request["path"] == "/SOGo", "probes must follow named http /SOGo"
    service = resource("Service")["spec"]
    port = next(p for p in service["ports"] if p["name"] == "http")
    assert port["port"] == 80 and port["targetPort"] == "http", "preserve external port 80, target named http"
    assert service["selector"].items() <= resource("Deployment")["spec"]["template"]["metadata"]["labels"].items()
    policy = resource("CiliumNetworkPolicy")["spec"]
    ingress = policy["ingress"]
    assert len(ingress) == 1, "keep the single restricted ingress rule"
    assert ingress[0]["fromEndpoints"] == [{"matchLabels": {
        "app.kubernetes.io/name": "traefik",
        "k8s:io.kubernetes.pod.namespace": "traefik",
    }}], "do not broaden ingress sources"
    allowed = [p for group in ingress[0]["toPorts"] for p in group["ports"]]
    assert allowed == [{"port": str(http["containerPort"]), "protocol": "TCP"}], "policy must allow only backend HTTP"

    security = pod["securityContext"]
    expected = {"runAsNonRoot": True, "runAsUser": 999, "runAsGroup": 999, "fsGroup": 999}
    assert all(security.get(k) == v for k, v in expected.items()), "pod must supply nonroot 999 identity and fsGroup"
    for container in (init, main):
        effective = security | container.get("securityContext", {})
        assert all(effective.get(k) == v for k, v in expected.items()), "container must not override nonroot identity"
        assert not effective.get("privileged", False), "no privileged permission bootstrap"
    volumes = {v["name"]: v for v in pod["volumes"]}
    mounts = [{m["mountPath"]: m for m in c["volumeMounts"]} for c in (init, main)]
    shared = mounts[0]["/srv/etc"]["name"]
    assert mounts[1]["/srv/etc"]["name"] == shared and "emptyDir" in volumes[shared], "init and main must share fresh emptyDir config"
    assert not any(m["/srv/etc"].get("readOnly", False) for m in mounts), "main also creates Apache config"
    assert mounts[0]["/tmpl"].get("readOnly") is True, "template remains read-only"
    assert init["image"] == main["image"], "qualify init and main using the same image"
    assert init["command"] == ["/bin/sh", "-c"], "use the image's native shell/envsubst"
    assert init["args"] == [
        "umask 027; envsubst '$$SOGO_DB_URL $$LDAP_BIND_PW' < /tmpl/sogo.conf.tmpl > /srv/etc/sogo.conf && echo 'sogo.conf written'"
    ], "render existing template with restricted secret-file permissions, no root/chown"
    assert not main.get("command") and not main.get("args"), "preserve ordinary image entrypoint"
    assert "DISABLE_CRON" not in env and env.get("CRON_TMPWATCH") == "0", "use supported no-jobs switch"
    assert all(v in ("", "0") for k, v in env.items() if k.startswith("CRON_")), "all other jobs remain disabled"


class SogoManifestTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        result = subprocess.run(
            ["kubectl", "kustomize", str(ROOT / "apps/mail")],
            check=True, capture_output=True, text=True, timeout=60,
        )
        cls.documents = [d for d in yaml.safe_load_all(result.stdout) if d]

    def test_rendered_runtime_contract(self) -> None:
        check_contract(self.documents)

    def test_regression_controls(self) -> None:
        # Each mutation represents an independent migration failure, not a full manifest snapshot.
        def mutate(kind, change):
            docs = copy.deepcopy(self.documents)
            target = next(d for d in docs if d["kind"] == kind and d["metadata"]["name"] == "sogo")
            change(target)
            with self.assertRaises(AssertionError):
                check_contract(docs)

        mutations = [
            ("Service", lambda d: d["spec"]["ports"][0].update(targetPort=80)),
            ("CiliumNetworkPolicy", lambda d: d["spec"]["ingress"][0]["toPorts"][0]["ports"][0].update(port="80")),
            ("Deployment", lambda d: d["spec"]["template"]["spec"]["containers"][0]["readinessProbe"]["httpGet"].update(port=80)),
            ("Deployment", lambda d: d["spec"]["template"]["spec"]["securityContext"].pop("fsGroup", None)),
            ("Deployment", lambda d: d["spec"]["template"]["spec"]["initContainers"][0]["args"].__setitem__(0, "envsubst < /tmpl/sogo.conf.tmpl > /srv/etc/sogo.conf")),
            ("Deployment", lambda d: d["spec"]["template"]["spec"]["containers"][0].update(env=[{"name": "DISABLE_CRON", "value": "1"}])),
        ]
        for index, (kind, change) in enumerate(mutations):
            with self.subTest(control=index, kind=kind):
                mutate(kind, change)


if __name__ == "__main__":
    unittest.main()
