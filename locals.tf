locals {
  # NFS configuration
  nfs_options       = "addr=${var.nfs_server},nolock,soft,rw"
  nfs_docker_device = ":/volume1/docker"
  nfs_share_device  = ":/volume1/Share"

  # Common environment variables for containers
  common_env = {
    TZ = var.timezone
  }

  # Common resource defaults
  resource_defaults = {
    cpu        = var.default_cpu
    memory     = var.default_memory
    memory_max = var.default_memory_max
  }

  # PostgreSQL connection configuration
  postgres_config = {
    host = var.postgres_host
    port = var.postgres_port
  }

  # Common Traefik tags for services
  traefik_base_tags = [
    "traefik.enable=true",
    "traefik.consulcatalog.connect=true",
  ]

  # Envoy metrics configuration
  envoy_metrics_config = {
    port = 9102
    path = "/metrics"
  }

  # Consul service provider
  service_provider = "consul"

  # Common network configuration
  network_mode = "bridge"

  # Node constraints
  node_constraints = {
    hestia = "Hestia"
  }

  # Common tags with environment
  tags = merge(
    var.common_tags,
    {
      environment = var.environment
    }
  )
}
