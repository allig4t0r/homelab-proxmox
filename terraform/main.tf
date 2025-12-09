module "proxmox_vms" {
  source                          = "./modules/cloud-init"
  proxmox_host                    = var.proxmox_host
  # proxmox_host_ipv4_addrs         = var.proxmox_host_ipv4_addrs
  proxmox_user                    = var.proxmox_user
  proxmox_user_private_key        = file("~/.ssh/id_ed25519")
  root_ssh_pub_key                = file("~/.ssh/id_ed25519.pub")
  default_non_root_user           = var.default_non_root_user
  default_non_root_user_hashed_pw = var.default_non_root_user_hashed_pw
  vms                             = local.vms_with_defaults
  extra_disks                     = local.extra_disks
}
