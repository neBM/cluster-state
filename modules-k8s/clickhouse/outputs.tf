output "http_url" {
  description = "ClickHouse HTTP endpoint"
  value       = "http://clickhouse.${var.namespace}.svc.cluster.local:8123"
}

output "native_url" {
  description = "ClickHouse native protocol endpoint"
  value       = "clickhouse://clickhouse.${var.namespace}.svc.cluster.local:9000"
}
