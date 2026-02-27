# Create a local copy of the file, to transfer to Proxmox
resource "local_file" "cloud_init_user_file" {
  for_each = {
    for k, v in var.vms : k => v
      if v.cloud_config_ssh_user == null && v.cloud_config_user_enabled == true
  }

  filename = "${path.module}/generated/cloud_init_user_${each.value.hostname}.yaml"
  content = templatefile("${path.module}/templates/${each.value.vm_template_id != null ? each.value.vm_template_id : 910}_user.tftpl", {
    hostname                        = each.value.hostname
    ip_address                      = "${each.value.ip_address}${each.value.ip_mask}" //for flatcar ignition
    gateway                         = each.value.gateway
    dns                             = each.value.dns
    root_ssh_pub_key                = var.root_ssh_pub_key
    default_non_root_user           = var.default_non_root_user
    default_non_root_user_hashed_pw = var.default_non_root_user_hashed_pw
  })
}

resource "local_file" "cloud_init_network_file" {
  for_each = {
    for k, v in var.vms : k => v
      if v.cloud_config_network_enabled == true
  }

  filename = "${path.module}/generated/cloud_init_network_${each.value.hostname}.yaml"
  content = templatefile("${path.module}/templates/${each.value.vm_template_id != null ? each.value.vm_template_id : 910}_network.tftpl", {
    hostname                = each.value.hostname
    ip_address              = "${each.value.ip_address}${each.value.ip_mask}"
    gateway                 = each.value.gateway
    dns                     = each.value.dns
  })
}

# Transfer the file to the Proxmox Host
resource "terraform_data" "cloud_init_user_file" {
  depends_on = [
    local_file.cloud_init_user_file
  ]

  for_each = {
    for k, v in var.vms : k => v
      if v.cloud_config_ssh_user == null && v.cloud_config_user_enabled == true
  }

  connection {
    type        = "ssh"
    user        = var.proxmox_user
    private_key = var.proxmox_user_private_key
    host        = var.proxmox_host
    # host        = var.proxmox_host_ipv4_addrs[each.value.target_node]
  }

  provisioner "file" {
    source      = local_file.cloud_init_user_file[each.key].filename
    destination = "/var/lib/vz/snippets/cloud_init_${each.value.hostname}.yaml"
  }
}

resource "terraform_data" "cloud_init_network_file" {
  depends_on = [
    local_file.cloud_init_network_file
  ]

  for_each = {
    for k, v in var.vms : k => v
      if v.cloud_config_network_enabled == true
  }

  connection {
    type        = "ssh"
    user        = var.proxmox_user
    private_key = var.proxmox_user_private_key
    host        = var.proxmox_host
    # host        = var.proxmox_host_ipv4_addrs[each.value.target_node]
  }

  provisioner "file" {
    source      = local_file.cloud_init_network_file[each.key].filename
    destination = "/var/lib/vz/snippets/cloud_init_network_${each.value.hostname}.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "virtual_machines" {
  for_each = { for key, value in var.vms : key => value }

  reboot_after_update = each.value.reboot_after_update
  started             = each.value.started
  stop_on_destroy     = each.value.stop_on_destroy
  name                = each.value.hostname
  vm_id               = each.value.vm_id
  description         = each.value.description
  node_name           = each.value.target_node

  bios          = each.value.bios
  on_boot       = each.value.on_boot
  tags          = each.value.tags
  machine       = each.value.machine_type
  boot_order    = each.value.boot_order
  scsi_hardware = each.value.scsihw

  clone {
    vm_id = each.value.vm_template_id
  }
  
  agent {
    enabled = each.value.qemu_agent
    trim    = true
    wait_for_ip {
      ipv4 = each.value.wait_for_ipv4
    }
  }

  cpu {
    sockets = each.value.cpu_sockets
    cores   = each.value.cpu_cores
    type    = "host"
    units   = each.value.cpu_units
  }

  memory {
    dedicated = each.value.memory
    floating  = each.value.memory
  }
  
  operating_system {
    type = each.value.qemu_os
  }

  dynamic efi_disk {
    for_each = each.value.bios == "ovmf" ? [1] : []
    content {
      datastore_id      = each.value.hdd_storage
      type              = "4m"
      pre_enrolled_keys = each.value.secure_boot
    }
  }

  initialization {
    interface     = "scsi0"
    datastore_id  = each.value.hdd_storage
    
    dynamic dns {
      for_each = each.value.cloud_config_network_enabled == true ? [] : [1]
      content {
        domain  = each.value.dns_domain
        servers = each.value.dns
      }
    }

    dynamic ip_config {
      for_each = each.value.cloud_config_network_enabled == true ? [] : [1]
      content {
        ipv4 {
          address = "${each.value.ip_address}${each.value.ip_mask}"
          gateway = each.value.ip_address == "dhcp" ? null : each.value.gateway
        }
      }
    }

    dynamic user_account {
      for_each = each.value.cloud_config_ssh_user != null ? [1] : []
      content {
        keys     = [var.root_ssh_pub_key]
        username = each.value.cloud_config_ssh_user
      }
    }

    network_data_file_id = each.value.cloud_config_network_enabled == true ? "local:snippets/cloud_init_network_${each.value.hostname}.yaml" : null
    user_data_file_id = each.value.cloud_config_user_enabled == true && each.value.cloud_config_ssh_user == null ? "local:snippets/cloud_init_user_${each.value.hostname}.yaml" : null
  }

  dynamic disk {
    for_each = each.value.native_hdd_size == true ? [] : [1]
    content {
      interface    = "scsi1"
      size         = each.value.hdd_size
      datastore_id = each.value.hdd_storage
      iothread     = true
      ssd          = true
      discard      = "on"
    }
  }

  dynamic "disk" {
    for_each = var.extra_disks[each.key]
    content {
      interface    = disk.value.interface
      size         = disk.value.size
      datastore_id = each.value.hdd_storage
      iothread     = true
      ssd          = true
      discard      = "on"
    }
  }

  cdrom {
    interface = "ide2"
    file_id   = each.value.iso_image != null ? each.value.iso_image : "none"
  }

  network_device {
    bridge   = each.value.bridge
    firewall = each.value.firewall
    vlan_id  = each.value.vlan_tag
  }
}
