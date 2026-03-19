variable "proxmox_host" {
  type        = string
  description = "The IP address or hostname of the Proxmox server."
}

# variable "proxmox_host_ipv4_addrs" {
#   type = map(string)
#   description = "A map of Proxmox host IP addresses for multi-node clusters."
#   default = {
#     pmx01 = "10.100.52.11"
#     pmx02 = "10.100.52.12"
#     pmx03 = "10.100.52.13"
#   }
# }

variable "proxmox_user" {
  type        = string
  description = "The SSH username used to connect to the Proxmox host."
  default     = "root"
}

variable "proxmox_ssh_private_key_path" {
  type        = string
  description = "Path to the private SSH key used to connect to the Proxmox host."
}

variable "proxmox_ssh_pub_key_path" {
  type        = string
  description = "Path to the public SSH key used to connect to the Proxmox host."
}

variable "default_non_root_user" {
  type        = string
  description = "The default username for non-root users created in the VMs."
  sensitive   = true
}

variable "default_non_root_user_hashed_pw" {
  type        = string
  description = "The SHA512 hashed password for the default non-root user."
  sensitive   = true
}

variable "vms" {
  type        = map(any)
  description = "A map of VM configurations, manually managed in terraform.tfvars."
}

variable "base_defaults" {
  type        = any
  description = "Global defaults for all VMs, manually managed in terraform.tfvars."
}

variable "tag_defaults" {
  type        = any
  description = "OS-specific default overrides, manually managed in terraform.tfvars."
}

variable "node_defaults" {
  type        = any
  description = "Hardware-specific defaults for each Proxmox node, manually managed in terraform.tfvars."
}

locals {
  # Merge order: base_defaults <- tag_defaults <- node_defaults <- vm_specific
  vms_with_defaults = {
    for vm_name, vm_spec in var.vms : vm_name => merge(
      var.base_defaults,
      merge([
        for tag in lookup(vm_spec, "tags", []) :
          lookup(var.tag_defaults, tag, {})
      ]...),
      merge([
        lookup(var.node_defaults, lookup(vm_spec, "target_node", "proxmox"), {})
      ]...),
      vm_spec
    )
  }

  extra_disks = {
    for vm_name, vm_spec in var.vms : vm_name => [
      for key, value in vm_spec :
      {
        interface = "scsi${regex("\\d+", key)}"
        size      = value
      }
      if can(regex("^hdd[2-9]+_size$", key)) && value != null
    ]
  }
}

output "extra_disks" {
  value       = local.extra_disks
  description = "List of extra disks configured for each VM."
}
