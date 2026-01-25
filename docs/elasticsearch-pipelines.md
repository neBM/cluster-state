# Elasticsearch Ingest Pipelines

Documentation for the K8s log processing ingest pipelines deployed to Elasticsearch.

## Current Implementation

The `logs-kubernetes.container_logs@custom` pipeline is now live with:

### Noise Reduction
- Drop kube-probe health checks (~11% of logs)
- Drop VPA "Skipping VPA object" messages
- Drop K8s reflector "Watch close" messages
- Drop DEBUG/TRACE level logs

### Sampling (v2 - More Aggressive)
High-volume infrastructure services are aggressively sampled:
- `elastic-agent` - **1%** (~500/hr from ~44k/hr = **98.8% reduction**)
- `goldilocks` - **1%** (~90/hr from ~24k/hr = **99.6% reduction**)
- `admission-controller` - **5%** (~180/hr from ~9k/hr = **98% reduction**)
- `recommender` - **5%** (~570/hr from ~8k/hr = **93% reduction**)
- `updater` - **5%**
- `kibana` - **10%**

**Note:** ERROR logs are always kept (100%) regardless of sampling rate.

### Noise Dropping
- Matrix "don't share a room" device list warnings (very common, low value)

### Service-Specific Sub-Pipelines
- `logs-kubernetes.gitlab-sidekiq@custom` - GitLab Sidekiq job processing
- `logs-kubernetes.gitlab-webservice@custom` - GitLab HTTP request processing (NEW)
- `logs-kubernetes.matrix-synapse@custom` - Matrix federation processing

### ECS Field Enrichments
- `log.level` - extracted from JSON (severity, level, log.level)
- `event.severity` - numeric (3=error, 4=warn, 6=info)
- `event.duration` - from duration_s in nanoseconds
- `db.duration_s` - database query time
- `http.request.method`, `http.response.status_code`, `url.path`
- `source.ip` + `source.geo.*` via GeoIP
- `trace.id` from correlation_id
- `labels.worker_class`, `labels.job_status`
- `error.message`, `error.fingerprint`, `error.category` (NEW)

### Smart Labeling (NEW)
- `labels.slow_query` - DB queries taking >1 second
- `labels.rate_limited` - HTTP 429 responses
- `labels.server_error` - HTTP 5xx responses

### Error Categorization (NEW)
Errors are automatically categorized for alerting:
- `timeout` - Request/connection timeouts
- `connection` - Connection refused/reset
- `auth` - Permission denied, unauthorized, forbidden
- `not_found` - 404, file not found
- `resource` - Out of memory, OOM
- `storage` - Disk space, quota issues
- `other` - Uncategorized errors

### Storage Reduction
- Removed: kubernetes.node.labels, kubernetes.namespace_labels
- Removed: log.file.*, elastic_agent.*, kubernetes.node.uid, container.runtime

---

## Future Ideas to Implement

### 1. ~~Sampling for High-Volume Services~~ IMPLEMENTED

Sampling is now live in the main pipeline. See "Current Implementation" above.

### 2. ~~Service-Specific Parsers~~ PARTIALLY IMPLEMENTED

#### ~~Synapse (Matrix) Parser~~ IMPLEMENTED
Now extracts via `logs-kubernetes.matrix-synapse@custom`:
- `matrix.request_id` - from `request` field
- `matrix.server_name` - local server
- `matrix.namespace` - Python module (e.g., `synapse.handlers.device`)
- `matrix.federation.source` - from `authenticated_entity`
- `matrix.federation.requester` - federation source server
- `matrix.is_federation` - boolean flag
- `matrix.log_message` - extracted log text
- `user_agent.original` + parsed UA fields
- `labels.noise_category` - flags "device list" warnings

#### GitLab Sidekiq Parser
Now extracts via `logs-kubernetes.gitlab-sidekiq@custom`:
- `gitlab.job.id`, `gitlab.job.queue`, `gitlab.job.urgency`
- `gitlab.job.queue_duration_s`, `gitlab.job.scheduling_latency_s`
- `gitlab.job.target_duration_s` - SLO target
- `gitlab.redis.duration_s`, `gitlab.redis.calls`
- `gitlab.db.count`, `gitlab.db.primary_duration_s`
- `process.cpu.seconds`, `process.memory.bytes`
- `event.outcome` - success/failure
- `labels.slow_job` - boolean if exceeds SLO

#### GitLab Webservice Parser (NEW)
Now extracts via `logs-kubernetes.gitlab-webservice@custom`:
- `gitlab.http.controller`, `gitlab.http.action`, `gitlab.http.route`
- `gitlab.http.urgency`, `gitlab.http.target_duration_s`
- `gitlab.http.view_duration_s`
- `gitlab.feature_category` - GitLab feature area
- `gitlab.redis.duration_s`, `gitlab.redis.calls`
- `gitlab.db.count`
- `process.cpu.seconds`, `process.memory.bytes`
- `user_agent.original`
- `labels.slow_request` - boolean if exceeds SLO
- `labels.health_check` - flags /-/liveness, /-/readiness endpoints

#### Nginx Access Log Parser
Use grok to parse nginx access logs:
```json
{
  "grok": {
    "field": "message",
    "patterns": ["%{IPORHOST:source.ip} - %{DATA:user.name} \\[%{HTTPDATE:timestamp}\\] \"%{WORD:http.request.method} %{DATA:url.path} HTTP/%{NUMBER:http.version}\" %{NUMBER:http.response.status_code} %{NUMBER:http.response.body.bytes}"],
    "ignore_failure": true
  }
}
```

#### Plex/Tautulli Parser
Extract media playback events:
- `media.title`
- `media.type` (movie/episode)
- `media.user`
- `media.quality`

### 3. Conditional Routing by Log Level

Route ERROR logs to a separate index for longer retention:
```json
{
  "reroute": {
    "if": "ctx.log?.level == 'error'",
    "dataset": "kubernetes.container_logs.errors",
    "tag": "route-errors"
  }
}
```

### 4. User Agent Parsing

For logs with user_agent field:
```json
{
  "user_agent": {
    "field": "parsed.user_agent",
    "target_field": "user_agent",
    "ignore_missing": true
  }
}
```

### 5. URL Parsing

Break down URLs into components:
```json
{
  "uri_parts": {
    "field": "url.path",
    "target_field": "url",
    "keep_original": true,
    "ignore_failure": true
  }
}
```

### 6. Registered Domain Extraction

For Matrix federation - extract domain from server names:
```json
{
  "registered_domain": {
    "field": "parsed.authenticated_entity",
    "target_field": "source.registered_domain",
    "ignore_missing": true
  }
}
```

### 7. ~~Error Categorization~~ IMPLEMENTED

Error categorization is now live. Errors are categorized into: timeout, connection, auth, not_found, resource, storage, other.

### 8. ~~Rate Limiting Detection~~ IMPLEMENTED

HTTP 429 responses are now flagged with `labels.rate_limited = true`.

### 9. ~~Slow Query Flagging~~ IMPLEMENTED

DB queries >1 second are now flagged with `labels.slow_query = true`.

### 10. Request Size Tracking

Extract and convert request/response sizes:
```json
{
  "convert": {
    "if": "ctx.parsed?.written_bytes != null",
    "field": "parsed.written_bytes",
    "target_field": "http.response.body.bytes",
    "type": "long"
  }
}
```

### 11. Container Restart Detection

Flag logs from recently restarted containers:
```json
{
  "set": {
    "if": "ctx.message?.contains('Starting') || ctx.message?.contains('Listening')",
    "field": "event.action",
    "value": "container_start"
  }
}
```

### 12. Sensitive Data Redaction

Redact potential sensitive data:
```json
{
  "redact": {
    "field": "message",
    "patterns": ["%{EMAILADDRESS:email}", "%{IP:ip}"],
    "pattern_definitions": {
      "EMAILADDRESS": "[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\\.[a-zA-Z0-9-.]+"
    }
  }
}
```

### 13. ~~Per-Service Pipelines~~ IMPLEMENTED

Service-specific sub-pipelines are now live:
- `logs-kubernetes.gitlab-sidekiq@custom` - for `sidekiq` container
- `logs-kubernetes.gitlab-webservice@custom` - for `webservice` container
- `logs-kubernetes.matrix-synapse@custom` - for `synapse` container

The main pipeline calls these conditionally based on `kubernetes.container.name`.

### 14. Metric Extraction for TSDB

Extract numeric metrics for time-series analysis:
- CPU usage from logs
- Memory allocation
- Queue depths
- Connection counts

### 15. Anomaly Tagging

Flag unusual patterns:
```json
{
  "set": {
    "if": "ctx.http?.response?.status_code >= 500 && ctx.event?.duration > 5000000000",
    "field": "labels.anomaly",
    "value": "slow_error"
  }
}
```

---

## Index Lifecycle Management (ILM) Ideas

Consider different retention for different log types:
- Errors: 90 days
- Warnings: 30 days
- Info: 7 days
- Sampled logs: 3 days

---

## Kibana Dashboard Ideas

With enriched fields, create dashboards for:
1. **Performance Overview** - p50/p95/p99 durations by service
2. **Error Tracker** - errors grouped by fingerprint
3. **HTTP Analytics** - status codes, methods, paths
4. **Worker Jobs** - Sidekiq job status and duration
5. **Geographic Map** - source.geo for federation traffic
6. **Slow Query Report** - db.duration_s > threshold

---

## Commands to Check Pipeline

```bash
# List all custom pipelines
curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_ingest/pipeline/logs-kubernetes.*@custom" | jq 'keys'

# View main pipeline
curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_ingest/pipeline/logs-kubernetes.container_logs@custom?pretty"

# View sub-pipelines
curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_ingest/pipeline/logs-kubernetes.gitlab-sidekiq@custom?pretty"
curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_ingest/pipeline/logs-kubernetes.matrix-synapse@custom?pretty"

# Check sampling stats (look for sample-* tags)
curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_nodes/stats/ingest?pretty" | grep -A5 "sample-elastic-agent"

# Test GitLab Sidekiq pipeline
curl -sk -X POST -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_ingest/pipeline/logs-kubernetes.gitlab-sidekiq@custom/_simulate?pretty" \
  -H "Content-Type: application/json" -d '{
    "docs": [{"_source": {"parsed": {"jid": "abc123", "queue": "default", "job_status": "done", "duration_s": 1.5, "target_duration_s": 300}}}]
  }' | jq '.docs[0].doc._source | {gitlab, event_outcome: .event.outcome, labels}'

# Test Matrix Synapse pipeline
curl -sk -X POST -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_ingest/pipeline/logs-kubernetes.matrix-synapse@custom/_simulate?pretty" \
  -H "Content-Type: application/json" -d '{
    "docs": [{"_source": {"parsed": {"namespace": "synapse.handlers", "authenticated_entity": "matrix.org", "user_agent": "Synapse/1.146.0"}}}]
  }' | jq '.docs[0].doc._source | {matrix, user_agent}'

# Check container log volumes (last hour)
curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/.ds-logs-kubernetes.container_logs-*/_search" \
  -H "Content-Type: application/json" -d '{
    "size": 0, "query": {"range": {"@timestamp": {"gte": "now-1h"}}},
    "aggs": {"by_container": {"terms": {"field": "kubernetes.container.name", "size": 20}}}
  }' | jq '.aggregations.by_container.buckets | map({key, doc_count})'
```

---

## Session Summary

### Session 1 (Initial Pipeline)
1. Created `logs-kubernetes.container_logs@custom` pipeline
2. Added elastic.co/dataset annotations to 27 K8s deployments for log routing
3. Implemented noise reduction (health checks, VPA, watch close, debug logs)
4. Added ECS field enrichments (log.level, event.severity, event.duration, http.*, url.*, source.*, trace.id, labels.*, error.*)
5. Added GeoIP enrichment for source IPs
6. Removed verbose/redundant fields for storage savings
7. Added error fingerprinting for deduplication

### Session 2 (Sampling & Sub-Pipelines)
1. Added sampling for high-volume infrastructure services:
   - elastic-agent (5%), goldilocks (5%), admission-controller (10%)
   - recommender (10%), updater (10%), kibana (25%)
   - ERROR logs always kept at 100%
2. Created `logs-kubernetes.gitlab-sidekiq@custom` sub-pipeline:
   - Extracts job metrics (queue duration, scheduling latency)
   - Extracts resource usage (CPU, memory, Redis, DB)
   - Flags slow jobs exceeding SLO target
   - Sets event.outcome for success/failure
3. Created `logs-kubernetes.matrix-synapse@custom` sub-pipeline:
   - Extracts federation metadata (source server, requester)
   - Parses user agent for federation analysis
   - Flags device list warnings as noise
   - Sets matrix.is_federation boolean

### Session 3 (Aggressive Sampling & More Features)
1. **Increased sampling aggressiveness:**
   - elastic-agent: 5% -> **1%** (98.8% reduction, ~500/hr)
   - goldilocks: 5% -> **1%** (99.6% reduction, ~90/hr)
   - admission-controller: 10% -> **5%** (98% reduction)
   - recommender: 10% -> **5%** (93% reduction)
   - kibana: 25% -> **10%**
2. **Created `logs-kubernetes.gitlab-webservice@custom` sub-pipeline:**
   - Extracts controller, action, route
   - Extracts feature category, request urgency
   - Extracts view duration, Redis/DB metrics
   - Flags slow requests exceeding SLO
   - Flags health check endpoints
3. **Added noise dropping:**
   - Matrix "don't share a room" device list warnings
4. **Added smart labeling:**
   - `labels.slow_query` - DB queries >1 second
   - `labels.rate_limited` - HTTP 429 responses
   - `labels.server_error` - HTTP 5xx responses
5. **Added error categorization:**
   - timeout, connection, auth, not_found, resource, storage, other

**Total pipelines deployed:** 4
- `logs-kubernetes.container_logs@custom` (main, 49 processors)
- `logs-kubernetes.gitlab-sidekiq@custom` (16 processors)
- `logs-kubernetes.gitlab-webservice@custom` (16 processors)
- `logs-kubernetes.matrix-synapse@custom` (11 processors)

All changes are live and processing new logs!
