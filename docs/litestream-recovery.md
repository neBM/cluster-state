# Litestream Backup Corruption Recovery

If litestream backup in MinIO is corrupted (decode errors on restore), recover from restic:

```bash
# 1. Stop the affected service
KUBECONFIG=~/.kube/k3s-config kubectl scale statefulset/<name> --replicas=0 -n default

# 2. Wipe corrupted litestream backup from MinIO
/usr/bin/ssh 192.168.1.5 "sudo rm -rf /storage/v/glusterfs_minio_data/<bucket>/db/*"

# 3. Find latest good restic snapshot
set -a && source .env && set +a
RESTIC_PW=$(vault kv get -format=json nomad/default/restic-backup | jq -r '.data.data.RESTIC_PASSWORD')
/usr/bin/ssh 192.168.1.5 "docker run --rm -v /mnt/csi/backups/restic:/repo \
  -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD='$RESTIC_PW' \
  restic/restic:0.18.1 snapshots --latest 5"

# 4. Restore litestream LTX files from restic
/usr/bin/ssh 192.168.1.5 "docker run --rm -v /mnt/csi/backups/restic:/repo \
  -v /tmp/restore:/restore \
  -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD='$RESTIC_PW' \
  restic/restic:0.18.1 restore <snapshot-id> \
  --include '/data/glusterfs_minio_data/<bucket>/' --target /restore"

# 5. Move restored data to MinIO volume
/usr/bin/ssh 192.168.1.5 "sudo mv /tmp/restore/data/glusterfs_minio_data/<bucket>/db/* \
  /storage/v/glusterfs_minio_data/<bucket>/db/"

# 6. Clean up and restart
/usr/bin/ssh 192.168.1.5 "sudo rm -rf /tmp/restore"
KUBECONFIG=~/.kube/k3s-config kubectl scale statefulset/<name> --replicas=1 -n default
```
