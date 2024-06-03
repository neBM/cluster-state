terraform {
  required_providers {
    nomad = {
      source  = "hashicorp/nomad"
      version = "2.2.0"
    }
  }
}

provider "nomad" {
  address = "http://hestia.lan:4646"
}
