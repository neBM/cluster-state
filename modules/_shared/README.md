# Shared Module Configurations

This module contains shared configurations, templates, and common patterns used across multiple Nomad job modules.

## Purpose

- Define reusable configuration blocks
- Maintain consistency across services
- Reduce code duplication
- Provide standard resource profiles

## Contents

### templates.tf

Contains local values for:

- **NFS Mount Configuration**: Standard NFS volume mount settings
- **Common Environment Variables**: Standard container environment (timezone, etc.)
- **Traefik Tag Patterns**: Consistent Traefik service mesh tags
- **Consul Service Template**: Standard Consul Connect sidecar configuration
- **Resource Profiles**: Predefined CPU/memory allocation tiers
- **Common Ports**: Standard port mappings
- **PostgreSQL Connection**: Database connection defaults

## Usage

Reference these configurations in your modules:

```hcl
# In your module's main.tf
locals {
  shared_config = {
    nfs_options = "addr=martinibar.lan,nolock,soft,rw"
  }
}

# Or source it as a module
module "shared" {
  source = "../_shared"
}
```

## Resource Profiles

Available profiles:
- `micro`: 50 MHz CPU, 64-128 MB memory
- `small`: 100 MHz CPU, 128-256 MB memory
- `medium`: 200 MHz CPU, 256-512 MB memory
- `large`: 500 MHz CPU, 512-1024 MB memory
- `xlarge`: 1000 MHz CPU, 1024-2048 MB memory
