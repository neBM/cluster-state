# Home Lab Cluster State

![Terraform Badge](https://img.shields.io/badge/Terraform-844FBA?logo=terraform&logoColor=fff&style=for-the-badge)
![Kubernetes Badge](https://img.shields.io/badge/Kubernetes-326CE5?logo=kubernetes&logoColor=fff&style=for-the-badge)
![K3s Badge](https://img.shields.io/badge/K3s-FFC61C?logo=k3s&logoColor=000&style=for-the-badge)

## Overview

Infrastructure as Code for my home lab K3s cluster. Terraform manages Kubernetes resources with state stored in PostgreSQL.

## Services

| Category | Services |
|----------|----------|
| **Media** | Plex (GPU transcoding), Overseerr, PlexTraktSync |
| **AI/ML** | Ollama, Open WebUI |
| **Identity** | Keycloak |
| **Communication** | Matrix |
| **Storage** | MinIO, NFS Provisioner, Restic Backup |
| **Git & CI** | GitLab, GitLab Runner |
| **Monitoring** | ELK Stack, Elastic Agent, Goldilocks (VPA) |
| **Web** | Nginx Sites, SearXNG, Vaultwarden |
| **Other** | AppFlowy, Nextcloud, Renovate |

## Architecture

- **Cluster**: K3s on bare metal
- **IaC**: Terraform with PostgreSQL backend
- **Secrets**: External Secrets Operator + Vault
- **Storage**: GlusterFS via NFS subdir provisioner
- **Ingress**: Traefik (with OAuth middleware)
- **Network**: Cilium (with Hubble UI)
- **CI/CD**: GitLab pipelines (validate → plan → apply)

## Project Structure

```
.
├── main.tf                 # Root module (migration notes)
├── kubernetes.tf           # K8s provider + all module calls
├── provider.tf             # Provider versions
├── variables.tf            # Input variables
├── locals.tf               # Local values
├── outputs.tf              # Output values
├── k8s/
│   └── core/               # Core K8s infrastructure
├── modules-k8s/            # Service modules
│   ├── media-centre/
│   ├── ollama/
│   ├── elk/
│   └── ...
├── specs/                  # Historical specs & migrations
├── .gitlab-ci.yml          # CI/CD pipeline
├── renovate.json           # Automated dependency updates
└── .pre-commit-config.yaml # Code quality hooks
```

## Getting Started

### Prerequisites

- Terraform >= 1.2.0
- K3s cluster with kubeconfig at `~/.kube/k3s-config`
- PostgreSQL database for Terraform state
- NFS/GlusterFS storage

### Setup

```bash
# Clone
git clone https://git.brmartin.co.uk/ben/cluster-state.git
cd cluster-state

# Configure
cp .env.example .env
cp terraform.tfvars.example terraform.tfvars
# Edit both files with your values

# Deploy
terraform init
terraform plan
terraform apply
```

### Environment Variables

```bash
PG_CONN_STR=postgres://user:password@host:port/database?sslmode=disable
```

## Development

### Pre-commit Hooks

```bash
pip install pre-commit
pre-commit install
```

### CI/CD

The GitLab pipeline runs:
- **validate**: `terraform fmt -check` + `terraform validate`
- **plan**: generates plan on MRs
- **apply**: applies on `main` (manual trigger)

CI uses a limited-RBAC service account (`terraform-ci`) for cluster access.

## History

This repo originally managed a Nomad cluster. Migration to K3s was completed in January 2026. Historical specs are preserved in `specs/`.
