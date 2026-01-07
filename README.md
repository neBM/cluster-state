# Home Lab Cluster State

![Terraform Badge](https://img.shields.io/badge/Terraform-844FBA?logo=terraform&logoColor=fff&style=for-the-badge)
![Nomad Badge](https://img.shields.io/badge/Nomad-00CA8E?logo=nomad&logoColor=fff&style=for-the-badge)
![Consul Badge](https://img.shields.io/badge/Consul-F24C53?logo=consul&logoColor=fff&style=for-the-badge)
![Docker Badge](https://img.shields.io/badge/Docker-2496ED?logo=docker&logoColor=fff&style=for-the-badge)

## Overview

This repository contains the Infrastructure as Code (IaC) for my home lab cluster. It uses [Terraform](https://www.terraform.io/) to manage [Nomad](https://www.nomadproject.io/) job deployments with state stored in a [PostgreSQL](https://www.postgresql.org/) database.

## Architecture

The cluster runs various services including:
- **Media Centre**: Plex media server with GPU transcoding
- **ELK Stack**: Elasticsearch, Logstash, and Kibana for logging
- **Matrix**: Self-hosted Matrix communication server
- **Keycloak**: Identity and access management
- **Forgejo**: Self-hosted Git service
- **Ollama**: Local LLM inference
- **MinIO**: S3-compatible object storage
- **AppFlowy**: Collaborative workspace
- **Renovate**: Automated dependency updates

## Prerequisites

- Terraform >= 1.2.0
- Nomad cluster (with Consul for service mesh)
- PostgreSQL database for Terraform state
- Access to NFS storage at `martinibar.lan`

## Getting Started

### 1. Clone the Repository

```bash
git clone <repository-url>
cd cluster-state
```

### 2. Configure Environment

Copy the example files and customize them:

```bash
cp .env.example .env
cp terraform.tfvars.example terraform.tfvars
```

Edit `.env` with your PostgreSQL connection string:
```bash
PG_CONN_STR=postgres://user:password@host:port/database?sslmode=disable
NOMAD_ADDR=http://your-nomad-server:4646
```

Edit `terraform.tfvars` with your specific values.

### 3. Initialize Terraform

```bash
terraform init
```

### 4. Plan and Apply

```bash
terraform plan
terraform apply
```

## Project Structure

```
.
├── main.tf              # Root module configuration
├── provider.tf          # Provider configuration
├── variables.tf         # Input variables
├── locals.tf            # Local values
├── outputs.tf           # Output values
├── modules/
│   ├── nomad-job/       # Generic Nomad job wrapper module
│   ├── _shared/         # Shared configurations and templates
│   ├── media-centre/    # Individual service modules
│   ├── elk/
│   └── ...
├── .tflint.hcl          # TFLint configuration
├── .pre-commit-config.yaml  # Pre-commit hooks
└── renovate.json        # Renovate bot configuration
```

## Development

### Pre-commit Hooks

Install pre-commit hooks for code quality:

```bash
pip install pre-commit
pre-commit install
```

Hooks include:
- Terraform formatting
- Terraform validation
- TFLint
- Nomad formatting and validation
- Security checks

### CI/CD

The repository uses GitHub Actions (Gitea Actions) for continuous integration:
- Terraform format checking
- Nomad format checking
- Nomad job validation
- TFLint analysis
- Terraform validation
- Automatic deployment on main branch

### Adding a New Service

1. Create a new module directory in `modules/`
2. Add a `jobspec.nomad.hcl` file with your Nomad job definition
3. Use the `nomad-job` wrapper module in `main.tf`:

```hcl
module "my-service" {
  source = "./modules/nomad-job"

  jobspec_path = "./modules/my-service/jobspec.nomad.hcl"
  use_hcl2     = true  # If using HCL2 variables
  hcl2_vars = {
    version = "1.0.0"
  }
}
```

## Modules

### Generic Nomad Job Wrapper

The `modules/nomad-job` wrapper provides a consistent interface for deploying Nomad jobs with optional HCL2 variable support.

### Shared Configurations

The `modules/_shared` module contains reusable configuration patterns:
- NFS mount configurations
- Traefik service mesh tags
- Resource profiles (micro, small, medium, large, xlarge)
- Common environment variables

## Maintenance

### Dependency Updates

Renovate bot automatically creates PRs for:
- Docker image updates in Nomad jobspecs
- Terraform provider updates
- Grouped updates by category

Updates are scheduled during off-peak hours (weeknights and weekends).

### State Management

Terraform state is stored in PostgreSQL. Ensure regular backups of the state database.

## Troubleshooting

### Common Issues

**Terraform Init Fails**
- Check PostgreSQL connection string in `.env`
- Verify network connectivity to state database

**Nomad Job Fails to Deploy**
- Check Nomad logs: `nomad job status <job-name>`
- Verify NFS mounts are accessible
- Check resource availability on nodes

**Module Not Found**
- Run `terraform init` to download modules
- Check module source paths in `main.tf`

## Contributing

1. Create a feature branch
2. Make your changes
3. Run pre-commit checks
4. Submit a pull request

## License

Private homelab infrastructure - not for redistribution.
