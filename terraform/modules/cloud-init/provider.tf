terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      version = "0.86.0"
    }
  }
}

provider "proxmox" {
  insecure = true
  endpoint = "https://${var.proxmox_host}:8006/"
}