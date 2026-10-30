# Host process metrics

The existing Alloy DaemonSet uses the generally available
`prometheus.exporter.process` component (embedded upstream process-exporter),
`prometheus.scrape`, and `prometheus.remote_write` to send host-visible process
metrics to `http://victoriametrics.default.svc.cluster.local:8428/api/v1/write`.
There is no separate exporter, script, public process endpoint, or application
instrumentation. Existing node-exporter and Kubernetes metrics remain in place.
Alloy's existing Service `/metrics` remains the self-metrics endpoint; do not
configure VictoriaMetrics to scrape an undocumented internal exporter URL.

## Scope and overhead

- Host `/proc` is mounted read-only at `/host/proc`. No host PID namespace,
  privileged mode, or new capabilities are added. Existing resources, logging
  mounts, storage path, and security settings are unchanged.
- Scrapes run every 15 seconds with a 10-second timeout and a 2,000-sample
  safety limit per node. Exceeding the limit fails the scrape, rather than
  silently accepting a partial process inventory.
- Child inheritance, per-thread collection, smaps, and name rechecking on each
  scrape are disabled. Group totals still include thread counts from process
  stat; no dynamic thread-name labels are emitted. State metrics with thread
  scanning disabled describe process leaders, not an exhaustive thread census.
- Every process matches at most one of **18 fixed groups** (first match wins):
  `k3s`, `containerd`, `runtime-shim`, `seaweedfs`, `victoriametrics`, `alloy`,
  `loki`, `cilium`, `traefik`, `browser`, `ffmpeg`, `js-tests`, `node`, `postgres`,
  `redis`, `gitlab`, `python`, `other`. There are at most **54 group/node pairs**
  across the three current nodes, not 54 total time series. Upstream metric
  names and finite CPU-mode, memory-type, context-switch-type, and state labels
  create multiple series per group. Scrape limits allow at most 6,000 exporter
  samples per three-node scrape, plus Alloy-generated scrape health series.
- `cluster="k3s-homelab"`, `job="node/processes"`, and `node`/`instance` equal
  the Kubernetes node name. No PIDs, cgroups, start times, command lines, or
  process environment values are exported as labels. Upstream's oldest-start-time
  gauge is a numeric value, not an identity label.
- `comm` matching uses Linux's 15-character process name. Chromium process-title
  rewriting does not affect the browser matcher. The specific JavaScript test
  matcher recognizes known Playwright/Vitest/Jest package path segments in the
  joined command line, including Node's `MainThread` name, before the fixed
  `node` fallback. It does not promise per-project/coordinator attribution;
  unrecognized renamed titles fall into `other`. No arbitrary argument text
  becomes a label or log field in this collection configuration.
- Empty groups remain after first observation until Alloy restarts, permitting
  zero process counts without growing label cardinality. Never-seen groups
  need not exist. Short-lived processes between scrapes may be missed.

The remote-write WAL lives in its own component directory below the existing
`/var/lib/alloy/data` hostPath, alongside but separate from log positions. Its
age policy keeps samples at least 5 minutes, truncates every 15 minutes, and
forcibly expires samples older than 1 hour at cleanup. Extended outages can
therefore lose metrics. This is **not a byte quota**: segment/cleanup granularity
can retain data longer, and node disk headroom must be observed. Queue concurrency
is capped at two shards; other supported queue defaults are retained. No new
PVC or memory/CPU allowance is introduced. Cost still scales with host process
count and churn; the `other` group trades broader visibility for scanning all
readable processes.

## Rollout acceptance (operator-owned)

Native config validation and manifest rendering cannot prove runtime `/proc`
permissions. On **each of hestia, heracles, and nyx**, verify after GitOps rollout:

1. The desired Alloy image/config and read-only host-proc mount are present;
   the DaemonSet is fully available and existing pod/journal/syslog logs still
   arrive in Loki with their previous labels. Compare CPU, working set, restarts,
   and log dropped-entry counters against the pre-rollout baseline.
2. Query VictoriaMetrics/Grafana, not just Alloy component health:

   ```promql
   up{cluster="k3s-homelab",job="node/processes"}
   count by (node) (namedprocess_namegroup_num_procs{job="node/processes"})
   sum by (node, groupname) (rate(namedprocess_namegroup_cpu_seconds_total{job="node/processes"}[5m]))
   namedprocess_namegroup_num_threads{job="node/processes"}
   namedprocess_namegroup_states{job="node/processes"}
   namedprocess_namegroup_memory_bytes{job="node/processes",memtype="resident"}
   ```

   Require three fresh `up=1` series, known host processes (not just Alloy's
   container), bounded groups, and fresh group CPU/count/thread/state samples.
   Observe several scrapes; component health alone does not establish ingestion.
3. Check `namedprocess_scrape_errors`, `namedprocess_scrape_partial_errors`, and
   `namedprocess_scrape_procread_errors` for the same job, and Alloy logs for
   permission errors. Process exits can race collection; persistent failures or
   missing groups need investigation. Some private proc files (`io`, `fd`, etc.)
   can remain unreadable under kernel ptrace, hidepid, user-namespace, or LSM
   restrictions despite container root. Zero I/O is not proof of no I/O. Do not
   silently suppress errors or grant broad privileges to make counters green.
4. Check Alloy self metrics `prometheus_remote_storage_samples_failed_total`,
   `prometheus_remote_storage_samples_pending`, and
   `prometheus_remote_storage_queue_highest_sent_timestamp_seconds`, plus WAL
   disk growth under `/var/lib/alloy/data`. Require successful delivery without
   a growing backlog. This path uses the normal Prometheus v1 remote-write
   protocol supported by single-node VictoriaMetrics on port 8428.

If private proc access cannot be established with the retained security context,
record exactly which files/metrics fail and return to the owner before changing
privileges. Do not enable hostPID/privileged speculatively. To roll back, revert
the collection commit through GitOps; do not erase Alloy's shared data/positions
directory. Removing the metrics component stops new writes; unused component WAL
data can be assessed separately without disturbing log positions.

## Local native checks

Extract the ConfigMap's `data["config.alloy"]` to a task-local file and run
`alloy validate <file>` using the pinned official `grafana/alloy:v1.21.1` image
(no service or cluster required), then:

```sh
kubectl kustomize infrastructure/observability-core > /dev/null
git diff --check
```

The ConfigMap uses a readable YAML literal block. The existing Loki config is
unchanged except replacing deprecated `env("NODE_NAME")` with supported
`sys.env("NODE_NAME")`, preserving lookup semantics; Alloy 1.21.1 native validation
rejects the deprecated function. The full repository `validate:manifests` CI gate
remains separate and requires its canonical Helm 4.2.4 toolchain.

References: [Alloy process component](https://grafana.com/docs/alloy/v1.21/reference/components/prometheus/prometheus.exporter.process/),
[remote-write WAL/queue](https://grafana.com/docs/alloy/v1.21/reference/components/prometheus/prometheus.remote_write/),
[embedded process-exporter v0.8.7](https://github.com/ncabatoff/process-exporter/tree/v0.8.7),
[VictoriaMetrics remote-write path](https://docs.victoriametrics.com/victoriametrics/url-examples/#apiv1write).
