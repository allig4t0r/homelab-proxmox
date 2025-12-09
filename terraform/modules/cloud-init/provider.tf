terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.89.1"
    }
  }
}

provider "proxmox" {
  insecure = true
  endpoint = "https://${var.proxmox_host}:8006/"
}