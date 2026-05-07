# SeaweedFS Released PV Audit

This note records the live audit completed on 2026-05-07 for `PersistentVolume`
objects in `status.phase=Released` with `storageClassName=seaweedfs`.

## Summary

- `9` SeaweedFS PVs were in `Released`.
- `6` are cleanup candidates from test or validation work.
- `3` are retained archives from abandoned ClickHouse-on-SeaweedFS attempts.
- Current ClickHouse does **not** use any of these PVs. Its live claim is
  `default/clickhouse-data` on `storageClassName=local-path`.

## Cleanup Candidates

These PVs do not back any live claim and do not represent current application
data.

| PV | Former claim | Observed state | Decision |
| --- | --- | --- | --- |
| `pvc-19fee9dd-72d5-467e-b641-e75856f5f74e` | `seaweedfs-test-pvc` | `512B`, contains `test.txt` | Delete when convenient |
| `pvc-491ee5ab-1070-47a1-be4e-708bd44bfc06` | `mountroot-test2` | filer path missing | Delete when convenient |
| `pvc-57108ac4-ce6f-408a-b4df-1638380bfbb4` | `v014-verify-test` | filer path missing | Delete when convenient |
| `pvc-a79be158-1505-4d3b-a387-6b1518c9e719` | `mountroot-test` | filer path missing | Delete when convenient |
| `pvc-f2f007d3-03aa-4546-b4cf-f2de24f6971e` | `swfs-validate-attr-fix` | empty directory | Delete when convenient |
| `pvc-f4982c39-d4cc-4076-b0ba-4bd543d21d1e` | `v015-verify-test` | filer path missing | Delete when convenient |

## Retained Archives

These PVs all belong to repeated `clickhouse-data-sw` attempts from the
LangFuse/ClickHouse SeaweedFS work. They are not mounted by any live PVC, but
they still contain ClickHouse datadirs.

| PV | Former claim | Filer path | Observed size | Decision |
| --- | --- | --- | --- | --- |
| `pvc-3075519f-976d-4f33-93e7-a71b93b870a2` | `clickhouse-data-sw` | `/buckets/pvc-3075519f-976d-4f33-93e7-a71b93b870a2` | `35.7M` | Retain until ClickHouse SeaweedFS history is intentionally discarded |
| `pvc-51ee49fc-aa36-4ccf-af88-36a85480e30f` | `clickhouse-data-sw` | `/buckets/pvc-51ee49fc-aa36-4ccf-af88-36a85480e30f` | `19.1M` | Retain until ClickHouse SeaweedFS history is intentionally discarded |
| `pvc-eafe2560-338b-4f56-a1b3-f001231348f7` | `clickhouse-data-sw` | `/buckets/pvc-eafe2560-338b-4f56-a1b3-f001231348f7` | `109.0M` | Retain until ClickHouse SeaweedFS history is intentionally discarded |

## Audit Method

- Enumerate released PVs:

```bash
kubectl get pv -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName,STATUS:.status.phase
```

- Inspect filer-root content using the read-only backup PVC:

```bash
kubectl exec -n default storage-pv-audit -- sh
du -sh /data-seaweedfs/<volume-handle-dir>
find /data-seaweedfs/<volume-handle-dir> -maxdepth 2
```

## Cleanup Rule

Delete released SeaweedFS PVs only after answering two questions:

1. Does a live PVC still reference the data path?
2. Does the filer path still contain data worth keeping as an archive?

If the answer to both is no, the PV is a cleanup candidate. If the data still
has operator value, keep it explicitly as retained archive state instead of
leaving the decision implicit.
