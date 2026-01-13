# MinIO service resolver
# Increase request timeout for large file operations (L2/L3 compaction)
Kind           = "service-resolver"
Name           = "minio-minio"
RequestTimeout = "300s"
ConnectTimeout = "30s"
