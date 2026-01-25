# Elasticsearch Cluster Health Contract

**Version**: 1.0  
**Date**: 2026-01-25

## Cluster Health Endpoints

### GET /_cluster/health

**Expected Response (GREEN - all nodes healthy)**:
```json
{
  "cluster_name": "docker-cluster",
  "status": "green",
  "timed_out": false,
  "number_of_nodes": 3,
  "number_of_data_nodes": 2,
  "active_primary_shards": 188,
  "active_shards": 376,
  "relocating_shards": 0,
  "initializing_shards": 0,
  "unassigned_shards": 0,
  "delayed_unassigned_shards": 0,
  "number_of_pending_tasks": 0,
  "number_of_in_flight_fetch": 0,
  "task_max_waiting_in_queue_millis": 0,
  "active_shards_percent_as_number": 100.0
}
```

### GET /_cat/nodes?v

**Expected Response**:
```
ip           heap.percent ram.percent cpu load_1m load_5m load_15m node.role   master name
192.168.1.5           45          78   5    0.50    0.45     0.40 dimh        *      elasticsearch-data-0
192.168.1.6           42          72   3    0.30    0.35     0.30 dimh        -      elasticsearch-data-1
192.168.1.7           12          35   1    0.10    0.15     0.10 mv          -      elasticsearch-tiebreaker-0
```

**Node Role Legend**:
- `d` = data
- `i` = ingest
- `m` = master-eligible
- `h` = data_hot
- `v` = voting_only

---

## Success Criteria Validation

### SC-001: Cluster GREEN Status
```bash
curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cluster/health" | jq -r '.status'
# Expected: green
```

### SC-002: Single Node Failure Tolerance
```bash
# Stop one data node
kubectl scale statefulset elasticsearch-data --replicas=1

# Cluster should be YELLOW (not RED)
curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cluster/health" | jq -r '.status'
# Expected: yellow

# All indices should remain readable
curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/.ds-logs-docker.container_logs-*/_count" | jq -r '.count'
# Expected: non-zero number
```

### SC-003: Flush Queue Below 5
```bash
curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_nodes/stats/thread_pool?filter_path=nodes.*.thread_pool.flush" \
  | jq '[.nodes[].thread_pool.flush.queue] | max'
# Expected: < 5
```

### SC-004: Node CPU Below 60%
```bash
curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_nodes/stats/os?filter_path=nodes.*.os.cpu.percent" \
  | jq '[.nodes[].os.cpu.percent] | max'
# Expected: < 60
```

### SC-005: Document Count Preserved
```bash
# Before migration (capture this)
curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/count?v"

# After migration (compare)
curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/count?v"
# Expected: identical counts
```

### SC-008: Tiebreaker Memory Below 300Mi
```bash
kubectl top pod elasticsearch-tiebreaker-0 -n default
# Expected: Memory < 300Mi
```

---

## Index Template Contract

All new indices MUST have at least 1 replica:

```json
PUT _index_template/default_replicas
{
  "index_patterns": ["*"],
  "priority": 1,
  "template": {
    "settings": {
      "number_of_replicas": 1
    }
  }
}
```

**Note**: Existing indices may need manual replica adjustment:
```bash
PUT */_settings
{
  "index": {
    "number_of_replicas": 1
  }
}
```

---

## Service Endpoints

| Service | Type | Endpoint | Purpose |
|---------|------|----------|---------|
| elasticsearch | ClusterIP | elasticsearch.default.svc:9200 | Internal HTTP API |
| elasticsearch-nodeport | NodePort | <any-node>:30092 | Elastic Agent/Fleet |
| elasticsearch-data-headless | Headless | elasticsearch-data-headless.default.svc | Node discovery |
| elasticsearch-tiebreaker-headless | Headless | elasticsearch-tiebreaker-headless.default.svc | Node discovery |

**External Access**:
- HTTPS: `https://es.brmartin.co.uk` (via Traefik IngressRoute)
