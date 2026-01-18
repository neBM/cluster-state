# Plex service defaults
# Use HTTP protocol for L7 features in service mesh
Kind     = "service-defaults"
Name     = "media-centre-plex"
Protocol = "http"

# Configure upstream connection to MinIO for litestream backups
# L2/L3 compaction requires long-running connections for large uploads
UpstreamConfig {
  Overrides = [
    {
      Name             = "minio-minio"
      Protocol         = "http"
      ConnectTimeoutMs = 30000 # 30s connection timeout
    }
  ]
}
