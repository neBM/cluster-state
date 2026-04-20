# LangFuse Claude Code Observability — Design

**Date:** 2026-04-20  
**Status:** Approved

## Goal

Add observability for Claude Code API calls (request/response logging, trace dashboard) without switching from Claude Max subscription to API billing.

## Approach

Hook-based tracing via LangFuse. Claude Code's Stop hook fires after each response, reads the session transcript, and ships traces to LangFuse. No proxy required — Pro/Max OAuth billing preserved.

## Architecture

```
Claude Code → Stop hook (Python) → LangFuse API (langfuse.brmartin.co.uk)
                                         │
                                   ┌─────┴──────┐
                              langfuse-web   langfuse-worker
                                   └─────┬──────┘
                        ┌────────────────┼────────────────┐
                   ClickHouse       martinibar:5433    SeaweedFS S3
                   (traces)         (PostgreSQL)        (blobs)
                                         │
                                   Valkey (existing)
```

## Infrastructure

### New: `modules-k8s/clickhouse`

Single-node ClickHouse for trace/observation storage (OLAP workload).

- Image: `clickhouse/clickhouse-server:24-alpine` (pinned via `var.image_tag`)
- Storage: 10Gi PVC on SeaweedFS
- Service: ClusterIP only, port 8123 (HTTP) + 9000 (native)
- Health check: `GET /ping` on port 8123
- No external exposure

### New: `modules-k8s/langfuse`

Two containers: `langfuse-web` (dashboard) and `langfuse-worker` (async event processing).

- Images: `langfuse/langfuse:latest` pinned via `var.image_tag`
- Service: ClusterIP port 3000
- IngressRoute: `langfuse.brmartin.co.uk`, Traefik websecure, `wildcard-brmartin-tls`
- Auth: Keycloak OIDC via `AUTH_CUSTOM_*` env vars (issuer: `https://sso.brmartin.co.uk/realms/prod`)

**Env wiring:**

| Env var | Value |
|---|---|
| `DATABASE_URL` | martinibar PostgreSQL (from secret) |
| `CLICKHOUSE_URL` | `http://clickhouse.default.svc.cluster.local:8123` |
| `REDIS_CONNECTION_STRING` | `redis://valkey.default.svc.cluster.local:6379` |
| `LANGFUSE_S3_ENDPOINT` | SeaweedFS S3 endpoint |
| `NEXTAUTH_URL` | `https://langfuse.brmartin.co.uk` |
| `AUTH_CUSTOM_CLIENT_ID` | Keycloak client ID (from secret) |
| `AUTH_CUSTOM_CLIENT_SECRET` | Keycloak client secret (from secret) |
| `AUTH_CUSTOM_ISSUER` | `https://sso.brmartin.co.uk/realms/prod` |

**K8s Secret `langfuse-secrets` (managed outside TF):**
- `DATABASE_URL`
- `NEXTAUTH_SECRET`
- `SALT`
- `CLICKHOUSE_PASSWORD`
- `AUTH_CUSTOM_CLIENT_ID`
- `AUTH_CUSTOM_CLIENT_SECRET`
- `LANGFUSE_S3_ACCESS_KEY_ID`
- `LANGFUSE_S3_SECRET_ACCESS_KEY`

### New: `modules-k8s/valkey`

Shared Valkey instance extracted from open-webui into a standalone module.

- Image: `valkey/valkey:8-alpine` (pinned via `var.image_tag`)
- Service: ClusterIP, port 6379, name `valkey`
- No persistence required (cache/queue — loss on restart acceptable)
- `open-webui` module updated to reference `valkey.default.svc.cluster.local:6379` and remove its own Valkey deployment/service resources

Both open-webui and LangFuse use `redis://valkey.default.svc.cluster.local:6379`.

### Existing (reused, no changes)

| Service | How used |
|---|---|
| martinibar PostgreSQL (192.168.1.10:5433) | LangFuse transactional DB |
| SeaweedFS | S3 blob storage for LangFuse events/exports |

## Claude Code Hook

**File:** `~/.claude/hooks/langfuse_hook.py`  
**Trigger:** Stop hook — runs after every Claude Code response  
**Mechanism:** Reads `$CLAUDE_TRANSCRIPT_PATH`, sends trace to LangFuse via Python SDK  
**Dependency:** `pip install langfuse` (user's machine)

**Global registration in `~/.claude/settings.json`:**
```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "python3 ~/.claude/hooks/langfuse_hook.py"
          }
        ]
      }
    ]
  }
}
```

**Per-project opt-in via `.claude/settings.local.json`:**
```json
{
  "env": {
    "TRACE_TO_LANGFUSE": "true"
  }
}
```

**Shell env required (e.g. `~/.zshrc`):**
```bash
export LANGFUSE_HOST="https://langfuse.brmartin.co.uk"
export LANGFUSE_PUBLIC_KEY="pk-lf-..."
export LANGFUSE_SECRET_KEY="sk-lf-..."
```

Hook runs asynchronously after response — zero latency impact on Claude Code.

## Out of Scope

- Open WebUI routing through LangFuse (future)
- LiteLLM / API proxy (investigated, incompatible with Pro/Max billing)
- ClickHouse clustering (single-node sufficient for personal use)
