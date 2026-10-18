#!/usr/bin/env bash
# Native chart render only; never talks to a Kubernetes API or installs a release.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
helm="${HELM:-helm}"
version="$("${helm}" version --template '{{.Version}}')"
[[ "${version%%+*}" == v4.2.4 ]] || { echo "Helm v4.2.4 required; got ${version}" >&2; exit 1; }
command -v kustomize >/dev/null || { echo 'Standalone kustomize required' >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
export HELM_CACHE_HOME="${work}/cache" HELM_CONFIG_HOME="${work}/config" HELM_DATA_HOME="${work}/data"
"${helm}" repo add gitlab https://charts.gitlab.io
if [[ -n "${GITLAB_HELM_CHART_ARCHIVE:-}" ]]; then
  cp "${GITLAB_HELM_CHART_ARCHIVE}" "${work}/gitlab-10.5.0.tgz"
else
  "${helm}" pull gitlab/gitlab --version 10.5.0 --destination "${work}"
fi
uv --no-config run --locked --script scripts/validate_gitlab_helm.py \
  --check-archive "${work}/gitlab-10.5.0.tgz" --index "${HELM_CACHE_HOME}/repository/gitlab-index.yaml" \
  --write-values "${work}/values.yaml"
"${helm}" lint "${work}/gitlab-10.5.0.tgz" -f "${work}/values.yaml"
"${helm}" template gitlab-helm "${work}/gitlab-10.5.0.tgz" \
  --is-upgrade --namespace default --kube-version 1.36.0 -f "${work}/values.yaml" > "${work}/rendered.yaml"
uv --no-config run --locked --script scripts/validate_gitlab_helm.py \
  --rendered "${work}/rendered.yaml" --write-postrender "${work}/postrendered.yaml"
GITLAB_HELM_RENDERED="${work}/rendered.yaml" uv --no-config run --locked --script scripts/test_validate_gitlab_helm.py
bash -n apps/gitlab-helm/files/upgrade-admission.sh
python3 scripts/test_gitlab_upgrade_admission.py
python3 scripts/test_gitlab_nas_export.py
