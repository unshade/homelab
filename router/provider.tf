terraform {
  required_version = ">= 1.0"
  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "~> 1.0"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.0"
    }
  }
}

data "sops_file" "router_credentials" {
  source_file = "${path.module}/router-sops.yaml"
}

provider "routeros" {
  hosturl  = "https://${var.router_address}"
  username = data.sops_file.router_credentials.data["secrets.username"]
  password = data.sops_file.router_credentials.data["secrets.password"]
  insecure = true # self-signed cert on the router
}
