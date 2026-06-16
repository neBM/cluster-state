#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

render() {
  local path="$1"
  local rendered
  rendered="$(mktemp)"

  echo "Validating ${path}"
  if command -v kustomize >/dev/null 2>&1; then
    if ! kustomize build "${path}" >"${rendered}"; then
      rm -f "${rendered}"
      return 1
    fi
  else
    if ! kubectl kustomize "${path}" >"${rendered}"; then
      rm -f "${rendered}"
      return 1
    fi
  fi

  validate_explicit_namespaces "${path}" "${rendered}"
  rm -f "${rendered}"
}

validate_explicit_namespaces() {
  local path="$1"
  local rendered="$2"

  awk -v path="${path}" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }

    function cluster_scoped(kind) {
      return kind ~ /^(Bucket|BucketAccessClass|BucketClass|ClusterIssuer|ClusterRole|ClusterRoleBinding|CustomResourceDefinition|DeviceClass|MutatingWebhookConfiguration|Namespace|Node|PersistentVolume|StorageClass|ValidatingWebhookConfiguration)$/
    }

    function flush() {
      if (kind != "" && !cluster_scoped(kind) && namespace == "") {
        resource = name == "" ? kind : kind "/" name
        printf "%s: %s is namespaced but metadata.namespace is missing\n", path, resource > "/dev/stderr"
        failed = 1
      }
      kind = ""
      name = ""
      namespace = ""
      in_metadata = 0
    }

    /^---[[:space:]]*$/ {
      flush()
      next
    }

    /^kind:[[:space:]]*/ {
      kind = trim(substr($0, index($0, ":") + 1))
      next
    }

    /^metadata:[[:space:]]*$/ {
      in_metadata = 1
      next
    }

    /^[^[:space:]]/ {
      in_metadata = 0
    }

    in_metadata && /^  name:[[:space:]]*/ {
      name = trim(substr($0, index($0, ":") + 1))
      next
    }

    in_metadata && /^  namespace:[[:space:]]*/ {
      namespace = trim(substr($0, index($0, ":") + 1))
      next
    }

    END {
      flush()
      exit failed
    }
  ' "${rendered}"
}

if [ "$#" -gt 0 ]; then
  paths=("$@")
else
  paths=(
    "clusters/k3s-homelab/flux-system"
    "clusters/k3s-homelab"
    "infrastructure/storage"
    "infrastructure/platform"
    "infrastructure/shared-services"
    "infrastructure/observability-core"
    "infrastructure/observability-ui"
    "apps"
  )
fi

for path in "${paths[@]}"; do
  render "${path}"
done

"${repo_root}/scripts/validate_gitlab_runner_templates.py"
