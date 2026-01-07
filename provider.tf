terraform {
  required_providers {
    nomad = {
      source  = "hashicorp/nomad"
      version = "~> 2.5"
    }
  }
}

provider "nomad" {
  address = var.nomad_address
  # Token is configured via NOMAD_TOKEN environment variable
}
