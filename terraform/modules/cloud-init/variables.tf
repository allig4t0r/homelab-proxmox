variable "proxmox_host" {
  type = string
}

# variable "proxmox_host_ipv4_addrs" {
#   type = map(string)
# }

variable "proxmox_user" {
  type = string
}

variable "proxmox_user_private_key" {
  type = string
  sensitive = true
}

variable "root_ssh_pub_key" {
  type = string
}

variable "default_non_root_user" {
  type = string
  sensitive = true
}

variable "default_non_root_user_hashed_pw" {
  type = string
  sensitive = true
}

variable "extra_disks" {
  type = map(any)
}

variable "vms" {
  type = map(object({
    hostname                     = string
    ip_address                   = string
    ip_mask                      = string
    vm_template_id               = number
    cpu_cores                    = number
    cpu_sockets                  = number
    memory                       = string
    target_node                  = string
    gateway                      = optional(string)
    dns                          = optional(list(string))
    tags                         = optional(list(string))
    machine_type                 = optional(string)
    qemu_os                      = optional(string)
    qemu_agent                   = optional(bool)
    hdd_storage                  = optional(string)
    firewall                     = optional(bool)
    bios                         = optional(string)
    bridge                       = optional(string)
    reboot_after_update          = optional(bool)
    description                  = optional(string)
    vlan_tag                     = optional(number)
    vm_id                        = optional(number)
    native_hdd_size              = optional(bool)
    hdd_size                     = optional(string)
    boot_order                   = optional(list(string))
    cloud_config_user_enabled    = optional(bool)
    cloud_config_network_enabled = optional(bool)
    cloud_config_ssh_user        = optional(string)
    secure_boot                  = optional(bool)
    started                      = optional(bool)
    on_boot                      = optional(bool)
    scsihw                       = optional(string)
    wait_for_ipv4                = optional(bool)
    stop_on_destroy              = optional(bool)
    cpu_units                    = optional(number)
    dns_domain                   = optional(string)
    iso_image                    = optional(string)
    serial_enabled               = optional(bool)
  }))
}