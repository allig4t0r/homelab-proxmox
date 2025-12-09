variable "proxmox_host" {
  default = "10.100.52.11"
}

# variable "proxmox_host_ipv4_addrs" {
#   type = map(string)
#   default = {
#     pmx01 = "10.100.52.11"
#     pmx02 = "10.100.52.12"
#     pmx03 = "10.100.52.13"
#   }
# }

variable "proxmox_user" {
  default = "root"
}

variable "default_non_root_user" {
  default = "atata"
  sensitive = true
}

variable "default_non_root_user_hashed_pw" {
  default = "$6$guedV4b0gW0M.EXx$nxfHNK/BeaJ2oCRh5jfZoNaOLUi/EQ33osFm7GW9oNfY0QxwqSRGLqOd7FY5879F3iJxCd6MXVfEjiJ3uzqi10"
  sensitive = true
}

locals {
  base_defaults = {
    vm_template_id            = 910
    cpu_sockets               = 1
    cpu_cores                 = 2
    memory                    = 2048
    machine_type              = "q35"
    secure_boot               = false
    reboot_after_update       = false
    # started                   = true
    target_node               = "proxmox"
    qemu_os                   = "l26"
    qemu_agent                = true
    bios                      = "ovmf"
    on_boot                   = true
    scsihw                    = "virtio-scsi-single"
    hdd_storage               = "nvme"
    hdd_size                  = 30
    dns                       = ["10.100.52.2"]
    gateway                   = "10.100.52.1"
    bridge                    = "vmbr0"
    firewall                  = false
    cloud_config_user_enabled = true
    description               = "Managed by Terraform by //AG"
    tags                      = ["terraform", "ubuntu"]
    stop_on_destroy           = true
    wait_for_ipv4             = true
    dns_domain                = "ag"
    cpu_units                 = 100
    boot_order                = ["scsi1", "ide2"]
  }

  # one tag from here PER VM!
  tag_defaults = {
    flatcar = {
      vm_template_id        = 904 # flatcar
      cpu_sockets           = 2
      memory                = 4096
      # hdd_size              = 10
      cloud_config_ssh_user = "core"
      on_boot               = false
      native_hdd_size       = true
    }

    talos = {
      vm_template_id            = 906 # talos v1.11.5
      cpu_sockets               = 2
      memory                    = 4096
      hdd_size                  = 14
      cloud_config_user_enabled = false
      on_boot                   = false
    }
  }

  node_defaults = {
    "node1" = {
      vlan_tag = 200
    }
    "node2" = {
      vlan_tag = 300
      bridge   = "vmbr1"
    }
  }

  vms_with_defaults = {
    for vm_name, vm_spec in var.vms : vm_name => merge(
      local.base_defaults,
      merge([
        for tag in lookup(vm_spec, "tags", {}) :
          lookup(local.tag_defaults, tag, {})
      ]...),
      merge([
        lookup(local.node_defaults, "target_node", {})
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
      if can(regex("^hdd[0-9]+_size$", key)) && value != null
    ]
  }
}

output "extra_disks" {
  value = local.extra_disks
  description = "Show what extra disks are configured."
}

variable vms {
  default = {
    "haproxy" = {
      hostname           = "haproxy"
      cpu_sockets        = 2
      ip_address         = "10.100.52.100/24"
      tags               = ["terraform", "ubuntu", "haproxy"]
    }

    "flatcar01" = {
      hostname           = "flatcar01"
      ip_address         = "10.100.52.105/24"
      tags               = ["terraform", "k8s", "flatcar"]
    }

    "talos01" = {
      hostname           = "talos01"
      ip_address         = "10.100.52.55/24"
      tags               = ["terraform", "k8s", "talos"]
    }
  }
}
