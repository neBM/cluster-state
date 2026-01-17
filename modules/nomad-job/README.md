# Nomad Job Module

A generic wrapper module for deploying Nomad jobs via Terraform.

## Features

- Simplified job deployment interface
- Support for HCL2 variable interpolation
- Consistent configuration across all jobs
- Reusable outputs for monitoring and debugging

## Usage

### Basic Job (without HCL2 variables)

```hcl
module "my_job" {
  source = "./modules/nomad-job"

  jobspec_path = "./jobspecs/my-job.nomad.hcl"
}
```

### Job with HCL2 Variables

```hcl
module "my_job_with_vars" {
  source = "./modules/nomad-job"

  jobspec_path = "./jobspecs/my-job.nomad.hcl"
  use_hcl2     = true
  hcl2_vars = {
    version = "1.2.3"
    replicas = "3"
  }
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| jobspec_path | Path to the Nomad jobspec file | string | - | yes |
| use_hcl2 | Whether to use HCL2 variable interpolation | bool | false | no |
| hcl2_vars | Variables to pass to HCL2 jobspec | map(string) | {} | no |
| purge_on_destroy | Whether to purge the job on destroy | bool | true | no |
| detach | Whether to detach from job monitoring | bool | false | no |

## Outputs

| Name | Description |
|------|-------------|
| id | The ID of the Nomad job |
| name | The name of the Nomad job |
| namespace | The namespace of the Nomad job |
| type | The type of the Nomad job |
| task_groups | The task groups of the job |
