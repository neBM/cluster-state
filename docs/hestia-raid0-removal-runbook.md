# Hestia RAID0 Removal and Storage-Isolation Runbook

Status: executed on 2026-07-09. Hestia no longer uses mixed-device btrfs RAID0; root is single-device btrfs on NVMe and noisy container/CI paths are bind-mounted from a separate XFS filesystem on the SATA SSD.

## Purpose

Remove Hestia's mixed-device btrfs RAID0 root topology and split latency-sensitive etcd/control-plane state from noisy container/CI/runtime storage using the existing NVMe + SATA SSD hardware.

This runbook is motivated by embedded-etcd latency incidents where ordinary Renovate, image-pull/unpack, and metadata traversal caused `apply request took too long`, `slow fdatasync`, and Raft heartbeat symptoms. The root problem is shared storage failure domain, not one bad CI job.

## Execution record: 2026-07-09

Outcome:

- Removed `/dev/sda1` from the root btrfs filesystem.
- Completed btrfs data conversion; root now reports `Data,single`, `Multiple profiles: no`, and `Total devices 1`.
- Root remains btrfs on `/dev/nvme0n1p3` with UUID `07d51adb-8799-4879-b7af-35e8813d390b`.
- Reformatted `/dev/sda1` as XFS label `HESTIA_NOISY`, UUID `a6431c20-a445-41c7-a5a5-dd3f3ec5111f`.
- Mounted `/srv/noisy` from `/dev/sda1` and bind-mounted:
  - `/srv/noisy/containerd` -> `/var/lib/rancher/k3s/agent/containerd`
  - `/srv/noisy/ci-builds-nocow` -> `/var/lib/ci-builds-nocow`
  - `/srv/noisy/ci-cache-nocow` -> `/var/lib/ci-cache-nocow`
  - `/srv/noisy/ci-containers-nocow` -> `/var/lib/ci-containers-nocow`
- Persisted those mounts in `/etc/fstab`; `findmnt --verify --verbose` passed.
- Deleted temporary `*.pre-noisy-20260709T134554Z` source copies after validating the bind-mounted copies and recovering from Kubernetes `DiskPressure`.
- Restarted k3s and Docker, uncordoned Hestia, and confirmed all nodes Ready.
- Docker containers restored to running state.

Final validation snapshot:

- Hestia node conditions: `Ready=True`, `DiskPressure=False`, `MemoryPressure=False`, `PIDPressure=False`, `EtcdIsVoter=True`.
- etcd endpoint health after settle: Hestia/Heracles/Nyx all healthy at about 5.6-5.9 ms.
- etcd alarms: none.
- No fresh `slow fdatasync`, ReadIndex, or heartbeat warnings in the final settled window; one low-level `apply request took too long` read warning at 119 ms was observed.
- Filesystem free space after cleanup:
  - `/`: 229G size, 103G used, 120G available, 47% used.
  - `/srv/noisy`: 112G size, 58G used, 55G available, 52% used.
- Low-impact 4 KiB fsync probe after migration:
  - `etcd-parent-root-nvme`: p50 8.698 ms, p95 19.605 ms, p99 19.971 ms, max 22.060 ms.
  - `noisy-sata-xfs`: p50 1.073 ms, p95 2.050 ms, p99 20.927 ms, max 21.141 ms.

Known caveats:

- The migration used an in-place btrfs device removal/split rather than a full OS reinstall. Root remains single-device btrfs on NVMe, not XFS/ext4.
- During workload rescheduling and image pulls immediately after uncordon, Hestia still emitted transient read-latency warnings, including ReadIndex retries and `apply request took too long` up to about 1.6 s. These stopped after workload settle.
- Controlled runtime validation pulled and ran `ghcr.io/renovatebot/renovate:42` on Hestia with `imagePullPolicy: Always`; the image pull took 29.09 s, the pod completed successfully, Hestia emitted no scary etcd warnings during the validation, and final etcd endpoint health was about 7.2 ms on all three endpoints.
- A full Renovate workload validation was run manually via GitLab scheduled pipeline play on project `infrastructure/renovate-runner`:
  - Pipeline `4770` / IID `1632` succeeded.
  - Job `18580` (`renovate`) ran on runner `kubernetes-any` for about 655 seconds.
  - The runner pod landed on Hestia: `runner-txxslbb-m-project-24-concurrent-0-qkzz67gz`.
  - No `slow fdatasync`, Raft heartbeat, or dropped-message symptoms were observed.
  - During and shortly after the run, Hestia still emitted transient sub-second etcd read/apply warnings, including one ReadIndex retry around 500 ms and `apply request took too long` up to about 584 ms during pod cleanup.
  - After a final settle window, etcd health was about 6.6-6.9 ms on all three endpoints; only low-level 100-400 ms apply warnings remained.
  - The hourly Renovate schedule was re-enabled after validation (`active=true`); next scheduled run was `2026-07-09T17:19:00+01:00`.
- Loki and VictoriaMetrics history preservation was intentionally deprioritized for this personal cluster.
- Docker data was not moved to `/srv/noisy`; Docker remains a separate host-service concern.

## Pre-migration Hestia evidence

- Node: `hestia` / `192.168.1.5`, Fedora 43, K3s control-plane/etcd.
- Pre-migration root: btrfs filesystem UUID `07d51adb-8799-4879-b7af-35e8813d390b` spanning:
  - `/dev/sda1` — Kingston SA400 SATA SSD, 111.8 GiB.
  - `/dev/nvme0n1p3` — Samsung MZVLB256HAHQ NVMe, 230 GiB.
- Pre-migration btrfs profile:
  - `Data,RAID0`, 303.21 GiB total.
  - `Metadata,DUP`, 7 GiB total.
  - `/dev/sda1` had only ~1 MiB unallocated; NVMe still had ~23 GiB unallocated.
- btrfs device stats currently show historical corruption counters:
  - `/dev/sda1 corruption_errs=1`
  - `/dev/nvme0n1p3 corruption_errs=14`
- Last known scrub shown by `btrfs scrub status /` was January 2026 and found no errors; run a fresh scrub before migration if the system can tolerate it.
- etcd path, kubelet, containerd, CI host paths, Loki, VictoriaMetrics, local PVs, and Docker all currently share `/`.

## Desired post-migration layout

Use separate block/filesystem failure domains, not btrfs RAID0:

| Device | Role | Notes |
|---|---|---|
| NVMe | OS, `/boot`, `/boot/efi`, `/`, K3s server state, etcd WAL/data | Prefer single-device filesystem. Keep etcd and core control-plane state away from CI/container churn. |
| SATA SSD | Noisy/rebuildable runtime storage | Mount at e.g. `/srv/noisy` and bind or configure containerd, GitLab Runner host paths, and optional Docker data/cache paths here. |

Do not put generic CI/containerd image unpack back onto the same filesystem as etcd.

## Current local state inventory

### K3s / etcd

- K3s service: enabled and active.
- K3s launch args include `--cluster-init`, `--flannel-backend=none`, `--disable-network-policy`, `--disable=traefik`, `--disable=servicelb`, TLS SANs for `k8s.brmartin.co.uk` and `192.168.1.5`, and OIDC API server args.
- `/etc/rancher/k3s/config.yaml` currently contains:
  - `node-ip: "192.168.1.5"`
  - kubelet reserved memory/CPU args
  - `etcd-arg: snapshot-count=100000`
- etcd endpoints healthy before runbook drafting:
  - Hestia endpoint DB ~37 MB, not leader.
  - Heracles endpoint DB ~32 MB, leader.
  - Nyx endpoint DB ~25 MB.
- No etcd alarms observed.
- Existing local snapshots on Hestia include scheduled snapshots through `2026-07-09 00:00`, but create a fresh manual snapshot immediately before maintenance.

### Hestia local-path PVs to preserve or deliberately recreate

| Namespace | PVC | PV | Class | Size | Path | Current user | Preserve? |
|---|---|---|---|---:|---|---|---|
| `default` | `data-loki-0` | `pvc-e5763180-f8ee-49a2-ba23-ee0fdd00e376` | `local-path-retain` | 20Gi | `/var/lib/rancher/k3s/storage/pvc-e5763180-f8ee-49a2-ba23-ee0fdd00e376_default_data-loki-0` | `loki-0` | Optional but preferred; telemetry history. |
| `default` | `plex-data` | `pvc-492755b5-f561-4087-9844-d89dfea7b266` | `local-path` | 2Gi | `/var/lib/rancher/k3s/storage/pvc-492755b5-f561-4087-9844-d89dfea7b266_default_plex-data` | `plex`, `plex-db-backup` jobs | Preserve. |
| `default` | `postfix-spool-local` | `pvc-4bf09cfc-bd5a-4df1-8952-35db0e3a6644` | `local-path-retain` | 5Gi | `/var/lib/rancher/k3s/storage/pvc-4bf09cfc-bd5a-4df1-8952-35db0e3a6644_default_postfix-spool-local` | `postfix` | Preserve; mail queue/spool. |
| `default` | `victoriametrics-data` | `pvc-bff7f107-1aee-4c58-944f-65b80290d8aa` | `local-path-retain` | 20Gi | `/var/lib/rancher/k3s/storage/pvc-bff7f107-1aee-4c58-944f-65b80290d8aa_default_victoriametrics-data` | `victoriametrics` | Optional but preferred; metrics history. |

Do not rely only on PVC requested sizes for backup sizing. Avoid broad `du/find` scans during active incidents; run backup sizing after cordon/drain or from a quiesced environment.

### Runtime/noisy paths

These are candidates for the SATA/noisy filesystem after rebuild:

- `/var/lib/rancher/k3s/agent/containerd` — current containerd image/snapshot store; rebuildable by image pulls, but expensive/noisy.
- `/var/lib/ci-builds-nocow`
- `/var/lib/ci-cache-nocow`
- `/var/lib/ci-containers-nocow`
- `/var/lib/kubelet` only if deliberately configured; be careful because kubelet path also carries pod volume mounts.
- `/var/lib/docker` or selected Docker data paths if Docker remains on Hestia.

### Docker caveat

Hestia still runs host Docker containers outside Kubernetes, including Immich, media apps, Traefik, Pi-hole, and related volumes. Container labels show the compose source of truth is mounted from Synology NFS under `/mnt/docker`:

- `/mnt/docker/downloads/docker-compose.yml` — downloads/media stack.
- `/mnt/docker/immich/docker-compose.yml` and `/mnt/docker/immich/compose.override.yml` — Immich stack.
- `/mnt/docker/pihole/docker-compose.yml` — Pi-hole.
- `/mnt/docker/traefik/docker-compose.yaml` — Traefik and related services.

Treat Docker state as a separate host-service migration item; do not wipe `/var/lib/docker` without confirming whether the current local Docker volumes are rebuildable from these compose files and their NFS-backed data paths.

### Host config to preserve

- `/etc/rancher/k3s/config.yaml`
- `/etc/rancher/k3s/k3s.yaml` if local kubectl access should be preserved.
- `/etc/systemd/system/k3s.service` and `/etc/systemd/system/k3s.service.env` if present.
- `/etc/fstab`, including Synology mounts:
  - `192.168.1.10:/volume1/docker /mnt/docker nfs defaults,soft,timeo=100,retrans=3`
  - `192.168.1.10:/volume1/csi /mnt/csi nfs defaults,soft,timeo=100,retrans=3`
- Firewalld state: `cilium_host`, `cilium_net`, `cilium_vxlan`, and `lxc+` are in trusted zone; this is required on Hestia.
- Docker service and volume metadata if Docker services are retained.
- GPU/NVIDIA/DRA host packages/config.

## Pre-maintenance containment

Keep these in place until the storage split is proven:

1. Keep Renovate schedule disabled.
2. Keep generic GitLab Runner node affinity removed.
3. Avoid intentional image-pull-heavy CI on Hestia.
4. If Hestia etcd latency becomes dangerous during prep, pause GitLab Runner intake temporarily rather than reintroducing Hestia-only affinity.

## Phase 0: final preflight, no destructive changes

Run from a trusted admin shell:

```bash
sudo kubectl get nodes -o wide
sudo kubectl get --raw='/readyz?verbose' | tail -12
ETCDCTL_API=3 sudo etcdctl \
  --endpoints=https://127.0.0.1:2379,https://192.168.1.6:2379,https://192.168.1.7:2379 \
  --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/k3s/server/tls/etcd/server-client.crt \
  --key=/var/lib/rancher/k3s/server/tls/etcd/server-client.key \
  endpoint status --write-out=table
ETCDCTL_API=3 sudo etcdctl ... alarm list
sudo kubectl -n flux-system get gitrepositories,kustomizations -o wide
sudo kubectl drain hestia --ignore-daemonsets --delete-emptydir-data --force --dry-run=server
sudo btrfs device stats /
sudo btrfs scrub status /
```

Go/no-go gate:

- Heracles and Nyx must be Ready.
- etcd must have no alarms.
- Hestia must not be etcd leader, or leadership must be transferable before shutdown.
- Dry-run drain must not reveal an unexpected un-evictable workload.
- Decide whether to run a fresh scrub before backup. If scrub reports new errors, stop and switch to data-recovery mode.

## Phase 1: GitOps and workload quiescing

1. Pause the noisy/scheduled jobs:
   - Renovate schedule remains disabled.
   - Pause or disable generic CI runner intake if needed.
   - Temporarily suspend Hestia-local backup CronJobs that would touch local PVs during backup.
2. Cordon Hestia:
   ```bash
   sudo kubectl cordon hestia
   ```
3. Drain movable pods:
   ```bash
   sudo kubectl drain hestia --ignore-daemonsets --delete-emptydir-data --force --timeout=10m
   ```
4. For local PV users that cannot move, scale down controllers cleanly before backing up their volumes:
   - `loki-0`
   - `plex`
   - `postfix`
   - `victoriametrics`

Use GitOps-aware scale/suspend procedures where possible. If live scale-down is used, record every live change for restoration.

## Phase 2: backups

Create a timestamp and backup root outside the RAID0 filesystem if possible, preferably Synology NFS under `/mnt/csi` or another confirmed external target:

```bash
TS=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_ROOT=/mnt/csi/backups/hestia-raid0-removal-$TS
sudo mkdir -p "$BACKUP_ROOT"/{host,k3s,pvs,docker,inventory}
```

### Inventory capture

```bash
sudo kubectl get nodes -o wide > "$BACKUP_ROOT/inventory/nodes.txt"
sudo kubectl get pv,pvc -A -o wide > "$BACKUP_ROOT/inventory/pv-pvc.txt"
sudo kubectl get pods -A -o wide > "$BACKUP_ROOT/inventory/pods.txt"
sudo kubectl -n flux-system get gitrepositories,kustomizations -o wide > "$BACKUP_ROOT/inventory/flux.txt"
sudo lsblk -o NAME,PATH,MODEL,SERIAL,TRAN,ROTA,SCHED,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS > "$BACKUP_ROOT/inventory/lsblk.txt"
sudo findmnt -R / > "$BACKUP_ROOT/inventory/findmnt-root.txt"
sudo btrfs filesystem usage / > "$BACKUP_ROOT/inventory/btrfs-usage.txt"
sudo btrfs device stats / > "$BACKUP_ROOT/inventory/btrfs-device-stats.txt"
sudo systemctl cat k3s > "$BACKUP_ROOT/inventory/k3s-systemd.txt"
```

Do not publish the backup directory contents without redacting secrets.

### etcd snapshot

Create a fresh K3s snapshot:

```bash
sudo k3s etcd-snapshot save --name "pre-hestia-storage-split-$TS"
sudo find /var/lib/rancher/k3s/server/db/snapshots -maxdepth 1 -type f -name "pre-hestia-storage-split-$TS*" -ls
sudo cp -a /var/lib/rancher/k3s/server/db/snapshots/pre-hestia-storage-split-$TS* "$BACKUP_ROOT/k3s/"
```

Also copy recent scheduled snapshots if space allows.

On the current Hestia install, standalone `etcdutl` and `k3s etcdutl` are not available. `etcdctl` 3.6 on this host supports `snapshot save` but not `snapshot status`. If stronger pre-destructive validation is required, install/use a matching `etcdutl` binary or perform a restore drill on an isolated node. At minimum, verify that the copied snapshot hash matches the local snapshot:

```bash
sudo sha256sum /var/lib/rancher/k3s/server/db/snapshots/pre-hestia-storage-split-$TS* "$BACKUP_ROOT"/k3s/pre-hestia-storage-split-$TS*
```

### host config backup

```bash
sudo rsync -aHAX --numeric-ids \
  /etc/rancher/k3s/ \
  /etc/systemd/system/k3s.service \
  /etc/systemd/system/k3s.service.env \
  /etc/fstab \
  "$BACKUP_ROOT/host/"

sudo firewall-cmd --get-active-zones > "$BACKUP_ROOT/host/firewalld-active-zones.txt" || true
sudo firewall-cmd --zone=trusted --list-all > "$BACKUP_ROOT/host/firewalld-trusted-zone.txt" || true
```

If Docker services are retained:

```bash
sudo docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' > "$BACKUP_ROOT/docker/containers.txt"
sudo docker volume ls > "$BACKUP_ROOT/docker/volumes.txt"
```

Do not copy Docker volumes blindly until compose/source-of-truth is located or service retention is confirmed.

### local PV backup

Stop writers first, then copy preserving xattrs/ownership:

```bash
sudo rsync -aHAX --numeric-ids --info=progress2 \
  /var/lib/rancher/k3s/storage/pvc-e5763180-f8ee-49a2-ba23-ee0fdd00e376_default_data-loki-0/ \
  "$BACKUP_ROOT/pvs/pvc-e5763180-f8ee-49a2-ba23-ee0fdd00e376_default_data-loki-0/"

sudo rsync -aHAX --numeric-ids --info=progress2 \
  /var/lib/rancher/k3s/storage/pvc-492755b5-f561-4087-9844-d89dfea7b266_default_plex-data/ \
  "$BACKUP_ROOT/pvs/pvc-492755b5-f561-4087-9844-d89dfea7b266_default_plex-data/"

sudo rsync -aHAX --numeric-ids --info=progress2 \
  /var/lib/rancher/k3s/storage/pvc-4bf09cfc-bd5a-4df1-8952-35db0e3a6644_default_postfix-spool-local/ \
  "$BACKUP_ROOT/pvs/pvc-4bf09cfc-bd5a-4df1-8952-35db0e3a6644_default_postfix-spool-local/"

sudo rsync -aHAX --numeric-ids --info=progress2 \
  /var/lib/rancher/k3s/storage/pvc-bff7f107-1aee-4c58-944f-65b80290d8aa_default_victoriametrics-data/ \
  "$BACKUP_ROOT/pvs/pvc-bff7f107-1aee-4c58-944f-65b80290d8aa_default_victoriametrics-data/"
```

Verify backups with file counts/checksums if the storage is stable enough. At minimum run targeted `rsync --dry-run --checksum` for the smaller critical volumes, especially `postfix-spool-local` and `plex-data`.

## Phase 3: stop Hestia services and remove it from active quorum path

1. Confirm Hestia is still not etcd leader:
   ```bash
   ETCDCTL_API=3 sudo etcdctl ... endpoint status --write-out=table
   ```
2. Stop Hestia K3s:
   ```bash
   sudo systemctl stop k3s
   ```
3. Confirm Heracles and Nyx remain Ready enough to preserve quorum/API from another node or client context.
4. Stop Docker if Docker data will be touched:
   ```bash
   sudo systemctl stop docker
   ```

## Phase 4: rebuild storage layout

This is destructive. Confirm backups before continuing.

Recommended fresh layout:

- NVMe:
  - EFI partition: preserve/recreate.
  - `/boot`: xfs or ext4.
  - `/`: single-device filesystem, preferably boring and predictable for etcd. Use XFS/ext4 unless there is a strong reason to keep btrfs single-device.
- SATA:
  - one filesystem mounted at `/srv/noisy` or similar.
  - subdirs/bind mounts for containerd and CI paths.

Example target mounts:

```text
/                                      NVMe root
/var/lib/rancher/k3s/server/db          NVMe root, no shared CI/runtime FS
/srv/noisy                              SATA filesystem
/var/lib/rancher/k3s/agent/containerd   bind mount to /srv/noisy/k3s-containerd
/var/lib/ci-builds-nocow                bind mount to /srv/noisy/ci-builds-nocow
/var/lib/ci-cache-nocow                 bind mount to /srv/noisy/ci-cache-nocow
/var/lib/ci-containers-nocow            bind mount to /srv/noisy/ci-containers-nocow
```

For btrfs paths used by CI, set no-CoW before data exists:

```bash
sudo mkdir -p /srv/noisy/{k3s-containerd,ci-builds-nocow,ci-cache-nocow,ci-containers-nocow}
sudo chattr +C /srv/noisy/{k3s-containerd,ci-builds-nocow,ci-cache-nocow,ci-containers-nocow}
```

If using XFS/ext4 for `/srv/noisy`, no btrfs no-CoW attribute is needed.

## Phase 5: restore host and K3s

1. Reinstall base OS/packages or restore minimal host config.
2. Restore `/etc/fstab` with the new UUIDs and bind mounts.
3. Restore firewalld trusted-zone config before expecting pod networking on Hestia:
   ```bash
   sudo firewall-cmd --permanent --zone=trusted --add-interface=cilium_host
   sudo firewall-cmd --permanent --zone=trusted --add-interface=cilium_net
   sudo firewall-cmd --permanent --zone=trusted --add-interface=cilium_vxlan
   sudo firewall-cmd --permanent --zone=trusted --add-interface='lxc+'
   sudo firewall-cmd --reload
   ```
   Or use `scripts/hestia-firewalld-setup.sh` from this repo.
4. Restore K3s config files, then install/start the same K3s version.
5. Prefer rejoining Hestia to the existing cluster rather than restoring the whole cluster from Hestia's snapshot, because Heracles and Nyx preserve quorum.
6. If Hestia identity/certs cannot be reused cleanly, remove/re-add Hestia as an etcd member following K3s documented server replacement procedure.

## Phase 6: restore local PV data

Before uncordoning, recreate local-path directories with exact names and ownership:

```bash
sudo mkdir -p /var/lib/rancher/k3s/storage
sudo rsync -aHAX --numeric-ids "$BACKUP_ROOT/pvs/pvc-e5763180-f8ee-49a2-ba23-ee0fdd00e376_default_data-loki-0/" /var/lib/rancher/k3s/storage/pvc-e5763180-f8ee-49a2-ba23-ee0fdd00e376_default_data-loki-0/
sudo rsync -aHAX --numeric-ids "$BACKUP_ROOT/pvs/pvc-492755b5-f561-4087-9844-d89dfea7b266_default_plex-data/" /var/lib/rancher/k3s/storage/pvc-492755b5-f561-4087-9844-d89dfea7b266_default_plex-data/
sudo rsync -aHAX --numeric-ids "$BACKUP_ROOT/pvs/pvc-4bf09cfc-bd5a-4df1-8952-35db0e3a6644_default_postfix-spool-local/" /var/lib/rancher/k3s/storage/pvc-4bf09cfc-bd5a-4df1-8952-35db0e3a6644_default_postfix-spool-local/
sudo rsync -aHAX --numeric-ids "$BACKUP_ROOT/pvs/pvc-bff7f107-1aee-4c58-944f-65b80290d8aa_default_victoriametrics-data/" /var/lib/rancher/k3s/storage/pvc-bff7f107-1aee-4c58-944f-65b80290d8aa_default_victoriametrics-data/
```

## Phase 7: bring Hestia back

1. Start K3s:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now k3s
   ```
2. Verify node and etcd health:
   ```bash
   sudo kubectl get nodes -o wide
   sudo kubectl get --raw='/readyz?verbose' | tail -12
   ETCDCTL_API=3 sudo etcdctl ... endpoint health --write-out=table
   ETCDCTL_API=3 sudo etcdctl ... endpoint status --write-out=table
   ```
3. Verify mounts:
   ```bash
   findmnt -T /var/lib/rancher/k3s/server/db/etcd
   findmnt -T /var/lib/rancher/k3s/agent/containerd
   findmnt -T /var/lib/ci-builds-nocow
   ```
4. Uncordon:
   ```bash
   sudo kubectl uncordon hestia
   ```
5. Restore scaled workloads and resume suspended Kustomizations/CronJobs.

## Phase 8: validation workload

Run in increasing risk order:

1. Idle fsync probes on etcd path and noisy paths.
2. Small GitLab CI job.
3. Image-pull-heavy CI job.
4. Manual Renovate run only after the first three pass.
5. Full scheduled Renovate re-enable only after a clean monitored manual run.

Monitor during each step:

```bash
sudo journalctl -u k3s --since '<start>' --no-pager \
  | grep -E 'slow fdatasync|leader failed to send out heartbeat|dropped internal Raft message|apply request took too long'
```

Also watch VictoriaMetrics/node-exporter for:

- `node_disk_written_bytes_total`
- `node_disk_writes_completed_total`
- `node_disk_write_time_seconds_total`
- `node_disk_io_time_weighted_seconds_total`
- `node_disk_flush_requests_time_seconds_total`
- `node_cpu_seconds_total{mode="iowait"}`

Success criteria:

- No `slow fdatasync` above 1s during CI/image-pull validation.
- No Raft heartbeat/dropped-message warnings.
- `apply request took too long` returns to rare, sub-second noise, not bursts of multi-second reads.
- Hestia etcd endpoint health remains consistently low ms.
- CI jobs remain multi-node eligible; no Hestia-only affinity is reintroduced.

## Rollback paths

Preferred rollback before destructive disk work: abort, uncordon Hestia, resume workloads.

After disk rebuild:

- If Hestia cannot rejoin but Heracles/Nyx quorum is healthy, leave Hestia cordoned and run the cluster on two members while repairing/reinstalling Hestia.
- If etcd quorum is unhealthy, use the latest verified snapshot and K3s restore procedure. Do not improvise member removal/addition while quorum state is unclear.
- If local PV restore fails, keep affected workloads scaled down and restore from the PV backup paths. Do not let empty local-path directories start stateful workloads unless data loss is explicitly accepted.

## Open decisions before execution

1. Confirm filesystem choice for NVMe root: XFS/ext4 preferred for predictable etcd latency; btrfs single-device is acceptable only if snapshots/features are worth the risk.
2. Confirm whether Docker services are in scope for this maintenance or should be stopped/restored separately.
3. Confirm whether Loki and VictoriaMetrics history must be preserved or can be dropped/rebuilt.
4. Confirm whether to run a fresh btrfs scrub before backup despite current latency fragility.
5. Confirm maintenance window and expected Hestia downtime.
