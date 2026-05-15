# homelab-proxmox
Repository for all things Proxmox and using homelab as DevOps

## Acknowledgments
Based on the great guide from https://codingpackets.com/blog/proxmox-cloud-init-with-terraform-and-saltstack/ and also great provider from bpg https://registry.terraform.io/providers/bpg/proxmox/latest/docs/resources/virtual_environment_vm which is miles better than telmate in my opinion, especially in terms of documentation.

This video is a little bit old but still helped to visualize what needs to be done in order to create Ubuntu template https://www.youtube.com/watch?v=MJgIm03Jxdo.

Mise task system and talos configuration influenced by https://github.com/onedr0p/cluster-template.

## Intro
Highly opionionated Terraform module for HomeLabs with Proxmox. Tested on a single-node Proxmox 9.0.17 with Xeon E5-2680 v4, Terraform v1.13.5, zsh 5.9 and 0.86.0 version of the provider. Defaults were taken mostly from the Proxmox VM creation wizard itself along with the best-practices described in the Proxmox official documentation.

This repo will be interesting for people who want to quickly start using terraform in their homelab even without any prior experience with it as 99% of terraform specifics is hidden in the module and the rest is pretty much self-explanatory. Stop making hundreds of non-needed clicks every day!

All the disk settings are based on the configuration when you have either SSD or NVMe drive for VM disks that allows sending TRIM commands. I highly recommend using LVM-Thin type for your VMS/LXCs and Directory type for backups/snippets/ISOs.

## Directory structure
```bash
.
├── main.tf
├── modules
│   └── cloud-init
│       ├── main.tf
│       ├── provider.tf
│       ├── templates
│       │   ├── 902_user.tftpl
│       │   └── 910_user.tftpl
│       └── variables.tf
├── terragrunt.hcl
└── variables.tf
```

For multiple-node proxmox:
1. Uncomment **proxmox_host_ipv4_addrs** in variables.tf (both module and non-module ones)
2. Uncomment all lines with **proxmox_host_ipv4_addrs** in *terraform/modules/cloud-init/main.tf* and comment one line above
3. Be sure to specify **target_node** for every vm either in **base_defaults**, **tag_defaults** or **vms** variable and also check **node_defaults** in *terraform/variables.tf*
 
Generated cloud-init files can be checked in the folder called **generated** along templates.

## Proxmox preparation

You need to create a role for terraform, a user and a token for this user with these commands:

```bash
pveum role add Terraform -privs "Mapping.Audit Mapping.Modify Mapping.Use Permissions.Modify Pool.Allocate Pool.Audit Realm.AllocateUser Realm.Allocate SDN.Allocate SDN.Audit Sys.Audit Sys.bash Sys.Incoming Sys.Modify Sys.AccessNetwork Sys.PowerMgmt Sys.Syslog User.Modify Group.Allocate SDN.Use VM.Allocate VM.Audit VM.Backup VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.bash VM.Migrate VM.GuestAgent.Unrestricted VM.PowerMgmt VM.Snapshot.Rollback VM.Snapshot Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit"
pveum user add terraform@pve
pveum aclmod / -user terraform@pve -role Terraform
pveum user token add terraform@pve provider --privsep=0
```
Add the token to your .bashrc or .zshrc file like this:

```bash
export PROXMOX_VE_API_TOKEN="terraform@pve!provider=<token>"
```

## Templates preparation

This tf module is built around using templates so we need to make at least one template. Please use so called **cloud images** that have built-in support for cloud-init configuration files. More on that here https://cloudinit.readthedocs.io/en/latest/index.html

My most used template is Ubuntu 24.04 LTS so I wrote a script **ubuntu_template.sh** that runs every time proxmox node starts and updates the image to the latest one.

We need these tools so we can build qemu-guest-agent right into our template image
```bash
apt install libguestfs-tools -y
```

Feel free to change these values at the start of the script
```bash
VMID=910
VM_NAME="ubuntu-2404-latest"
STORAGE="nvme"
MEMORY=2048
CPUS=2
IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
```

Run the script. be sure that default VMID 910 is free or vm will be DELETED
```bash
chmod +x ubuntu_template.sh
bash ubuntu_template.sh
```

To run this script every time your proxmox node starts (mine doesn't run 24/7, otherwise you can run this via schedule using crontab -e)

```bash
nano /etc/systemd/system/update-ubuntu-template.service
```

Contents of the service file
```bash
[Unit]
Description=Updates ubuntu 24.04 template to the latest one
After=network.target

[Service]
Type=oneshot
ExecStart=/root/ubuntu_template.sh
RemainAfterExit=yes
StandardOutput=append:/root/template_updater.log
StandardError=append:/root/template_updater.log

[Install]
WantedBy=multi-user.target
```

Run these after service file was created
```bash
systemctl daemon-reload
systemctl enable update-template.service
systemctl start update-template.service
```

Logs will be written to **/root/template_updater.log**.

## Almost there

What needs to be changed in *terraform/variables.tf*:
1. change proxmox_host, proxmox_user
2. change these default_non_root_user, default_non_root_user_hashed_pw (generate hash using **apt install whois & & mkpasswd -m sha-512**) for cloud-init ubuntu template *910_user.tftpl*
3. change base_defaults according to your vm_template_id, dns, gateway, same goes for tag_defaults
4. be sure that all vms in variable vms do look like vms you're planning to create

What needs to be changed in *terraform/main.tf*:
1. change the path to the private key for root on the proxmox node in proxmox_user_private_key
2. change the path to the public key for root to put into /root/.ssh/authorized_keys

## Using terraform

Finally, here's the main deal. It's super fast and easy! Just don't forget to check what will be deleted or removed in the outputs.

```bash
cd homelab-proxmox/terraform
terraform init
terraform apply
```

You would need to write "yes" and hit Enter for actually applying the changes.

## Possible VM variables

```bash
    hostname           = string
    ip_address         = string
    gateway            = string
    dns                = list(string)
    vm_template_id     = number
    cpu_cores          = number
    cpu_sockets        = number
    memory             = string
    target_node        = string
    tags               = optional(list(string))
    machine_type       = optional(string) //"q35" is used in base_defaults as it is newer and better
    qemu_os            = optional(string) //"l26" is used in base_defaults cause it is linux in the end
    qemu_agent         = optional(bool) //whether or not there is qemu-agent inside the vm
    hdd_storage        = optional(string) //"local-lvm" by prodiver defaults, disk goes to scsi1
    hdd_size           = optional(string)
    firewall           = optional(bool)
    bios               = optional(string) //"ovmf" is used in base_defaults as I prefer to have UEFI on all my VMs
    secure_boot        = optional(bool) //false in base_defaults, enables pre-enroll-keys option to preload Microsoft Standard Secure Boot keys
    bridge             = optional(string)
    reboot_after_update = optional(bool) //tf provider option, I keep it at false to not mess with working VMs
    description        = optional(string)
    vlan_tag           = optional(number)
    vm_id              = optional(number)
    native_hdd_size    = optional(bool) //false by default, allows to keep original cloud image size. conflicts with hdd_size
    boot_order         = optional(string) //["scsi1", "ide2"] by default as I keep scsi0 for cloudInit drive and ide2 for cdrom
    cloud_config_user_enabled = optional(bool) //allows to generate and set cicustom cloud-init user file
    cloud_config_network_enabled = optional(bool) //allows to generate and set cicustom cloud-init network file
    cloud_config_ssh_user = optional(string) //user that is going to be used for proxmox own cloud-init settings (can be seen in UI)
    started            = optional(bool)
    on_boot            = optional(bool) //allows vm to boot automatically when proxmox node starts
    scsihw             = optional(string) //"virtio-scsi-single" in base_defaults as this gives best performance per proxmox documentation
```

## Recommendations & Notes

1. Do not use DHCP on proxmox node. Always use static addresses.
2. Use q35 machine type with ovmf bios and UEFI without pre_enrolled_keys. Unless you have Windows VMs those keys are not needed and can actually make your life harder when installing NVIDIA drivers etc.
3. VMs are always created with memory ballooning enabled and I see no reason to disable this.
4. NVMe is a way to go in case you want to have real fast cloning. Proxmox can live on any old SSD you have and you partition NVMe as LVM-Thin solely for VMs. LVM-Thin type enables most modern features like Snapshots and will save you a ton of space.
5. When you specify cloud_config_ssh_user, it fully disables generation of cloud-config user file even with cloud_config_user_enabled = true. cloud_config_ssh_user should be null (non-existent) for cloud-config user file to be generated
6. KISS. Or don't overthink s#it — I really wanted everything to be as simple as possible for describing new vms. Thus I came to the point when you can specify only a VM name, static IP and tag and everything else will be taken from defaults. Concise and cozy. I tried to move vms var to vms.tfvars file but you'd need to run terraform with -var-file=vms.tfvars and that definitely feels worse than just **tf apply**.
7. I recommend to keep provider fresh and check for new versions from time to time. It's enough to change the version in terraform/modules/cloud-init/provider.tf and run terraform init -upgrade after that. Check new releases here https://github.com/bpg/terraform-provider-proxmox/releases
8. Cloud-init files are not automatically deleted from proxmox node. However they will be fully overwritten in case you have a vm with the same hostname so this isn't an issue for me. Generated cloud-init files in generated folder are removed automatically.
9. Try to put as much configuration settings in cloud-init files, that will make your life super easy. I.e. creation of certain configs or installing packages. Make your homelab real cozy!
