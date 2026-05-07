#!/usr/bin/env python3

from __future__ import annotations

import argparse
import base64
import json
import re
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REPO_SEARCH_PATHS = [
    REPO_ROOT / "apps",
    REPO_ROOT / "infrastructure",
    REPO_ROOT / "clusters",
]
DEFAULT_DOC_SEARCH_PATHS = [
    REPO_ROOT / "docs" / "seaweedfs-s3-identities.md",
]
DEFAULT_OBJECT_TYPES = [
    "deploy",
    "statefulset",
    "daemonset",
    "cronjob",
    "job",
    "configmap",
    "secret",
]
TEXT_EXTENSIONS = {
    ".json",
    ".md",
    ".py",
    ".sh",
    ".tf",
    ".toml",
    ".txt",
    ".yaml",
    ".yml",
}
CONTEXT_HINTS = (
    "bucket",
    "bucketname",
    "bucketnames",
    "litestream",
    "minio",
    "s3",
    "seaweed",
)
LOGICAL_SIZE_RE = re.compile(r"logical size:\s*(\d+)")


@dataclass
class BucketReport:
    name: str
    logical_size: int
    repo_refs: list[str]
    live_refs: list[str]
    docs_refs: list[str]

    @property
    def status(self) -> str:
        return "active" if self.repo_refs or self.live_refs else "abandoned-candidate"


def run_command(args: list[str], input_text: str | None = None) -> str:
    result = subprocess.run(
        args,
        input=input_text,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        stderr = result.stderr.strip()
        stdout = result.stdout.strip()
        detail = stderr or stdout or f"exit status {result.returncode}"
        raise RuntimeError(f"{' '.join(args)} failed: {detail}")
    return result.stdout


def bucket_token_pattern(bucket: str) -> re.Pattern[str]:
    return re.compile(rf"(?<![A-Za-z0-9_-]){re.escape(bucket)}(?![A-Za-z0-9_-])")


def contains_bucket_token(text: str, bucket: str) -> bool:
    return bool(bucket_token_pattern(bucket).search(text))


def strip_weed_shell_output(raw: str) -> list[str]:
    lines: list[str] = []
    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith(("I", "W", "E")) and len(stripped) > 4 and stripped[1:5].isdigit():
            continue
        if stripped.startswith("master:"):
            continue
        if stripped == ">":
            continue
        if stripped.startswith("> "):
            stripped = stripped[2:]
        if stripped:
            lines.append(stripped)
    return lines


def weed_shell(commands: list[str], namespace: str, pod: str, master: str) -> list[str]:
    raw = run_command(
        [
            "kubectl",
            "exec",
            "-i",
            "-n",
            namespace,
            pod,
            "--",
            "sh",
            "-c",
            f"weed shell -master={master}",
        ],
        input_text="\n".join(commands) + "\n",
    )
    return strip_weed_shell_output(raw)


def list_bucket_entries(namespace: str, pod: str, master: str) -> list[str]:
    return weed_shell(["fs.ls /buckets"], namespace, pod, master)


def get_bucket_logical_size(bucket: str, namespace: str, pod: str, master: str) -> int:
    lines = weed_shell([f"fs.du /buckets/{bucket}"], namespace, pod, master)
    for line in lines:
        match = LOGICAL_SIZE_RE.search(line)
        if match:
            return int(match.group(1))
    raise RuntimeError(f"unable to parse logical size for bucket {bucket}")


def get_bound_seaweedfs_handles() -> list[str]:
    raw = run_command(["kubectl", "get", "pv", "-o", "json"])
    data = json.loads(raw)
    handles = []
    for item in data.get("items", []):
        if item.get("status", {}).get("phase") != "Bound":
            continue
        if item.get("spec", {}).get("storageClassName") != "seaweedfs":
            continue
        handle = item.get("spec", {}).get("csi", {}).get("volumeHandle")
        if handle:
            handles.append(handle)
    return sorted(handles)


def normalize_pvc_handle(handle: str) -> str | None:
    if handle == "/buckets":
        return None
    name = Path(handle).name
    if name.startswith("pvc-"):
        return name
    return None


def load_live_objects(object_types: list[str]) -> list[dict[str, Any]]:
    raw = run_command(["kubectl", "get", ",".join(object_types), "-A", "-o", "json"])
    data = json.loads(raw)
    return data.get("items", [])


def iter_text_files(paths: list[Path]) -> list[Path]:
    files: list[Path] = []
    for path in paths:
        if not path.exists():
            continue
        if path.is_file():
            files.append(path)
            continue
        for candidate in path.rglob("*"):
            if not candidate.is_file():
                continue
            if candidate.suffix.lower() not in TEXT_EXTENSIONS:
                continue
            files.append(candidate)
    return sorted(files)


def search_text_paths(paths: list[Path], bucket: str, require_context: bool) -> list[str]:
    matches: list[str] = []
    for path in iter_text_files(paths):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError:
            continue
        for idx, line in enumerate(lines):
            if not contains_bucket_token(line, bucket):
                continue
            if require_context:
                window = "\n".join(lines[max(0, idx - 1) : min(len(lines), idx + 2)]).lower()
                if not any(hint in window for hint in CONTEXT_HINTS):
                    continue
                stripped = line.strip()
                if stripped.startswith("name:"):
                    continue
                if any(stripped.startswith(prefix) for prefix in ("image:", "mountPath:", "subPath:")) and not any(
                    hint in stripped.lower() for hint in CONTEXT_HINTS
                ):
                    continue
            rel = path.relative_to(REPO_ROOT)
            matches.append(f"{rel}:{idx + 1}: {line.strip()}")
    return matches


def has_context_hint(text: str) -> bool:
    lowered = text.lower()
    return any(hint in lowered for hint in CONTEXT_HINTS)


def live_env_hits(bucket: str, env: list[dict[str, Any]]) -> list[str]:
    hits: list[str] = []
    for item in env:
        if not isinstance(item, dict):
            continue
        name = str(item.get("name", ""))
        value = str(item.get("value", ""))
        if contains_bucket_token(value, bucket) and (has_context_hint(name) or has_context_hint(value)):
            hits.append("env.value")
    return hits


def live_container_hits(bucket: str, container: dict[str, Any]) -> list[str]:
    hits: list[str] = []
    hits.extend(live_env_hits(bucket, container.get("env") or []))
    for key in ("args", "command"):
        values = container.get(key) or []
        if not isinstance(values, list):
            continue
        for value in values:
            if isinstance(value, str) and contains_bucket_token(value, bucket) and has_context_hint(value):
                hits.append(key)
    return hits


def search_live_objects(bucket: str, objects: list[dict[str, Any]]) -> list[str]:
    refs: list[str] = []
    for item in objects:
        kind = item.get("kind", "Unknown")
        metadata = item.get("metadata", {})
        namespace = metadata.get("namespace", "-")
        name = metadata.get("name", "unknown")

        if kind == "ConfigMap":
            for key, value in (item.get("data") or {}).items():
                if contains_bucket_token(value, bucket) and has_context_hint(value):
                    refs.append(f"{kind}/{namespace}/{name} data.{key}")
            continue

        if kind == "Secret":
            for key, value in (item.get("data") or {}).items():
                try:
                    decoded = base64.b64decode(value).decode("utf-8", errors="ignore")
                except Exception:
                    continue
                key_has_bucket_hint = "bucket" in key.lower()
                if (key_has_bucket_hint and decoded.strip() == bucket) or (
                    contains_bucket_token(decoded, bucket) and has_context_hint(decoded)
                ):
                    refs.append(f"{kind}/{namespace}/{name} data.{key}")
            continue

        spec = item.get("spec") or {}
        pod_spec = spec.get("template", {}).get("spec", {})
        for container in pod_spec.get("containers") or []:
            for hit in live_container_hits(bucket, container):
                refs.append(f"{kind}/{namespace}/{name} spec.template.spec.containers.{hit}")
        for container in pod_spec.get("initContainers") or []:
            for hit in live_container_hits(bucket, container):
                refs.append(f"{kind}/{namespace}/{name} spec.template.spec.initContainers.{hit}")

        if kind == "CronJob":
            job_pod_spec = spec.get("jobTemplate", {}).get("spec", {}).get("template", {}).get("spec", {})
            for container in job_pod_spec.get("containers") or []:
                for hit in live_container_hits(bucket, container):
                    refs.append(f"{kind}/{namespace}/{name} spec.jobTemplate.spec.template.spec.containers.{hit}")
            for container in job_pod_spec.get("initContainers") or []:
                for hit in live_container_hits(bucket, container):
                    refs.append(f"{kind}/{namespace}/{name} spec.jobTemplate.spec.template.spec.initContainers.{hit}")

    return sorted(set(refs))


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    bucket_entries = list_bucket_entries(args.namespace, args.master_pod, args.weed_master)
    pvc_dirs = sorted(entry for entry in bucket_entries if entry.startswith("pvc-"))
    named_buckets = sorted(entry for entry in bucket_entries if not entry.startswith("pvc-"))

    raw_bound_handles = get_bound_seaweedfs_handles()
    pvc_bound_handles = sorted(
        handle
        for handle in (normalize_pvc_handle(raw) for raw in raw_bound_handles)
        if handle is not None
    )
    non_pvc_bound_handles = sorted(raw for raw in raw_bound_handles if normalize_pvc_handle(raw) is None)
    live_objects = load_live_objects(args.object_types)

    named_bucket_reports: list[BucketReport] = []
    repo_paths = [REPO_ROOT / path for path in args.repo_paths]
    doc_paths = [REPO_ROOT / path for path in args.doc_paths]

    for bucket in named_buckets:
        named_bucket_reports.append(
            BucketReport(
                name=bucket,
                logical_size=get_bucket_logical_size(bucket, args.namespace, args.master_pod, args.weed_master),
                repo_refs=search_text_paths(repo_paths, bucket, require_context=True),
                live_refs=search_live_objects(bucket, live_objects),
                docs_refs=search_text_paths(doc_paths, bucket, require_context=False),
            )
        )

    report = {
        "summary": {
            "pvc_dirs": len(pvc_dirs),
            "bound_handles": len(pvc_bound_handles),
            "non_pvc_bound_handles": len(non_pvc_bound_handles),
            "orphaned_pvc_dirs": len(sorted(set(pvc_dirs) - set(pvc_bound_handles))),
            "missing_live_pvc_dirs": len(sorted(set(pvc_bound_handles) - set(pvc_dirs))),
            "named_buckets": len(named_bucket_reports),
            "active_named_buckets": sum(1 for bucket in named_bucket_reports if bucket.status == "active"),
            "abandoned_named_buckets": sum(1 for bucket in named_bucket_reports if bucket.status != "active"),
        },
        "pvc": {
            "dirs": pvc_dirs,
            "bound_handles": pvc_bound_handles,
            "non_pvc_bound_handles": non_pvc_bound_handles,
            "orphaned_dirs": sorted(set(pvc_dirs) - set(pvc_bound_handles)),
            "missing_live_dirs": sorted(set(pvc_bound_handles) - set(pvc_dirs)),
        },
        "named_buckets": [
            {
                **asdict(bucket),
                "status": bucket.status,
            }
            for bucket in named_bucket_reports
        ],
    }
    return report


def render_text(report: dict[str, Any]) -> str:
    lines = []
    summary = report["summary"]
    pvc = report["pvc"]

    lines.append("SeaweedFS /buckets audit")
    lines.append("")
    lines.append(
        "PVC-backed filer dirs: "
        f"{summary['pvc_dirs']} live, {summary['bound_handles']} bound handles, "
        f"{summary['orphaned_pvc_dirs']} orphaned, {summary['missing_live_pvc_dirs']} missing"
    )
    if summary["non_pvc_bound_handles"]:
        lines.append("Non-pvc SeaweedFS volume handles not compared against /buckets/pvc-*:")
        lines.extend(f"  - {name}" for name in pvc["non_pvc_bound_handles"])
    if pvc["orphaned_dirs"]:
        lines.append("Orphaned pvc dirs:")
        lines.extend(f"  - {name}" for name in pvc["orphaned_dirs"])
    if pvc["missing_live_dirs"]:
        lines.append("Missing live pvc dirs:")
        lines.extend(f"  - {name}" for name in pvc["missing_live_dirs"])

    lines.append("")
    lines.append(
        "Named buckets: "
        f"{summary['named_buckets']} total, {summary['active_named_buckets']} active, "
        f"{summary['abandoned_named_buckets']} abandoned candidates"
    )

    for bucket in report["named_buckets"]:
        lines.append("")
        lines.append(
            f"- {bucket['name']} [{bucket['status']}] logical_size={bucket['logical_size']}"
        )
        if bucket["repo_refs"]:
            lines.append("  repo refs:")
            lines.extend(f"    - {ref}" for ref in bucket["repo_refs"])
        if bucket["live_refs"]:
            lines.append("  live refs:")
            lines.extend(f"    - {ref}" for ref in bucket["live_refs"])
        if bucket["docs_refs"]:
            lines.append("  docs refs:")
            lines.extend(f"    - {ref}" for ref in bucket["docs_refs"])

    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Audit SeaweedFS filer /buckets entries against live PVC handles and named-bucket consumers."
    )
    parser.add_argument("--namespace", default="default", help="Namespace containing the SeaweedFS master pod")
    parser.add_argument("--master-pod", default="seaweedfs-master-0", help="SeaweedFS master pod name")
    parser.add_argument("--weed-master", default="seaweedfs-master:9333", help="SeaweedFS master address passed to weed shell")
    parser.add_argument(
        "--object-types",
        nargs="+",
        default=DEFAULT_OBJECT_TYPES,
        help="Kubectl resource types to search for named-bucket consumers",
    )
    parser.add_argument(
        "--repo-paths",
        nargs="+",
        default=[str(path.relative_to(REPO_ROOT)) for path in DEFAULT_REPO_SEARCH_PATHS],
        help="Repo paths to scan for checked-in named-bucket references",
    )
    parser.add_argument(
        "--doc-paths",
        nargs="+",
        default=[str(path.relative_to(REPO_ROOT)) for path in DEFAULT_DOC_SEARCH_PATHS],
        help="Documentation paths to scan for named-bucket references",
    )
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON instead of text")
    parser.add_argument(
        "--fail-on-findings",
        action="store_true",
        help="Exit non-zero when orphaned PVC dirs, missing PVC dirs, or abandoned named buckets are present",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    report = build_report(args)

    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(render_text(report))

    summary = report["summary"]
    if args.fail_on_findings and (
        summary["orphaned_pvc_dirs"] or summary["missing_live_pvc_dirs"] or summary["abandoned_named_buckets"]
    ):
        return 2
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
