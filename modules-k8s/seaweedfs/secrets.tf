# SeaweedFS S3 credentials are configured via weed shell and persisted in
# filer metadata. Consumer services reference per-service K8s Secrets.
#
# 1. Configure S3 identity in SeaweedFS:
#
#   kubectl -n default exec -it sts/seaweedfs-master -- weed shell
#   > s3.configure -access_key=<key> -secret_key=<secret> -actions=Admin -apply
#
# 2. Create per-service secrets (same credentials, separate secrets):
#
#   for svc in loki-s3 victoriametrics-s3 gitlab-runner-cache-s3 \
#              overseerr-secrets media-centre-secrets; do
#     kubectl -n default create secret generic "$svc" \
#       --from-literal=MINIO_ACCESS_KEY=<key> \
#       --from-literal=MINIO_SECRET_KEY=<secret> \
#       --dry-run=client -o yaml | kubectl apply -f -
#   done
#
#   Note: gitlab-runner-cache-s3 uses keys 'accesskey' and 'secretkey'.
