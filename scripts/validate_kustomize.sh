#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

render() {
  local path="$1"

  echo "Validating ${path}"
  if command -v kustomize >/dev/null 2>&1; then
    kustomize build "${path}" >/dev/null
  else
    kubectl kustomize "${path}" >/dev/null
  fi
}

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

for path in "${paths[@]}"; do
  render "${path}"
done
