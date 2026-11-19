#!/usr/bin/env bash
# Offline application contracts, independent of generic render/schema validation.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
if [[ $# != 1 ]]; then
  echo "Usage: $0 {safety|gitlab|runner|migrations|ibgateway|workspace|mail|matrix|temporal|factorio|restic|iris|firewall}" >&2
  exit 2
fi
case "$1" in
  safety)
    # Discovery spans all apps/infrastructure, including newly added consumers.
    "${repo_root}/scripts/validate_shared_postgres_budget.py"
    uv run --locked --script "${repo_root}/scripts/validate_ibgateway_manifest.py"
    uv --no-config run --locked --script "${repo_root}/scripts/validate_factorio_manifest.py"
    ;;
  gitlab)
    # Owns the native chart render plus Helm, upgrade-admission and NAS tests.
    "${repo_root}/scripts/validate_gitlab_helm.sh"
    ;;
  runner)
    "${repo_root}/scripts/validate_gitlab_runner_templates.py"
    uv --no-config run --script "${repo_root}/scripts/test_gitlab_runner_config.py"
    uv --no-config run --locked --script "${repo_root}/scripts/validate_hestia_ci_store_gc_alert.py"
    uv --no-config run --locked --script "${repo_root}/scripts/test_validate_hestia_ci_store_gc_alert.py"
    python3 "${repo_root}/scripts/test_hestia_ci_cache_retention.py"
    ;;
  migrations)
    uv --no-config run --locked --script "${repo_root}/scripts/validate_versioned_migration_jobs.py"
    uv --no-config run --locked --script "${repo_root}/scripts/test_validate_versioned_migration_jobs.py"
    ;;
  ibgateway)
    python3 "${repo_root}/scripts/test_validate_ibgateway_manifest.py"
    ;;
  workspace)
    uv --no-config run --script "${repo_root}/scripts/test_validate_hermes_workspace_foundation.py"
    uv --no-config run --script "${repo_root}/scripts/test_validate_hermes_workspace_deployment.py"
    python3 "${repo_root}/scripts/test_validate_hermes_workspace_image.py"
    ;;
  mail)
    uv --no-config run --locked --script "${repo_root}/scripts/test_sogo_manifest.py"
    ;;
  matrix)
    uv run --locked --script "${repo_root}/scripts/test_matrix_synapse_config.py"
    ;;
  temporal)
    uv run --locked --script "${repo_root}/scripts/validate_temporal_manifest.py"
    python3 "${repo_root}/scripts/test_validate_temporal_manifest.py"
    ;;
  factorio)
    python3 "${repo_root}/scripts/test_validate_factorio_manifest.py"
    "${repo_root}/scripts/test_factorio_startup.sh"
    ;;
  restic)
    "${repo_root}/scripts/test_restic_backup.sh"
    ;;
  iris)
    uv --no-config run --locked --script "${repo_root}/scripts/test_iris_media_dirs.py"
    ;;
  firewall)
    "${repo_root}/scripts/test_hestia_firewalld_setup.sh"
    ;;
  *) echo "Unknown contract suite: $1" >&2; exit 2 ;;
esac
