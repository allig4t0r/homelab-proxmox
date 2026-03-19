# Global VM defaults
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
  ip_mask                   = "/24"
  dns                       = ["172.17.0.2"]
  gateway                   = "172.17.4.1"
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
  serial_enabled            = true
}

# tag-specific overrides
tag_defaults = {
  flatcar = {
    vm_template_id        = 904
    cpu_sockets           = 2
    memory                = 4096
    # hdd_size              = 10
    cloud_config_ssh_user = "core"
    on_boot               = false
    native_hdd_size       = true
  }
  talos = {
    vm_template_id            = 905
    cpu_sockets               = 2
    memory                    = 4096
    hdd_size                  = 14
    cloud_config_user_enabled = false
    on_boot                   = false
  }
}

# Physical Proxmox Node defaults
node_defaults = {
  node1 = {
    vlan_tag = 200
  }
  node2 = {
    vlan_tag = 300
    bridge   = "vmbr1"
  }
}

# Manually managed VM configurations
vms = {
  "haproxy" = {
    hostname    = "haproxy"
    cpu_sockets = 2
    ip_address  = "172.17.4.100"
    tags        = ["terraform", "ubuntu", "haproxy"]
  }

  "flatcar01" = {
    hostname   = "flatcar01"
    ip_address = "172.17.4.105"
    hdd2_size  = 40
    tags       = ["terraform", "k8s", "flatcar"]
  }

  "talos01" = {
    hostname   = "talos01"
    ip_address = "172.17.4.55"
    tags       = ["terraform", "k8s", "talos"]
  }
}
