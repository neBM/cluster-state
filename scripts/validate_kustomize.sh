#!/usr/bin/env bash

# Offline render/schema checks only; application contracts have separate launchers.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec uv --no-config run --locked --script "${repo_root}/scripts/validate_render_schema.py" "$@"
