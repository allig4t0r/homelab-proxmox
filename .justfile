#!/usr/bin/env -S just --justfile

# set lazy
set quiet
set dotenv-load
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']

[group: 'Bootstrap']
mod? bootstrap 'bootstrap'

[group: 'Kube']
mod? kube 'kubernetes'

[group: 'Talos']
mod? talos 'talos'

[group: 'Terraform']
mod? tf 'terraform'

[private]
default:
    just -l

[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}

# === template ===

[group: 'Template']
mod template 'template'

[doc('Render and validate configuration files')]
[group('Template')]
configure:
    just template configure

[doc('Initialize configuration files (homelab.yaml, age key)')]
[group('Template')]
init:
    just template init
    just tf init

[private]
templates file *args:
    minijinja-cli "{{ file }}" {{ args }} | op inject

[doc('Apply terraform manifests')]
[group('Terraform')]
sync:
    just tf sync

[doc('Recreate Talos k8s cluster')]
[group('Talos')]
recreate-talos:
    just tf destroy-talos
    just template reset
    just configure
    just tf sync
    just bootstrap talos
    just bootstrap apps

[doc('Install pve-templater')]
[group('PVE')]
[script]
install-templater:
    if ! gum confirm "Are you sure to install pve-templater?"; then
        exit 1
    fi
    ssh -i "$PROXMOX_SSH_PRIVATE_KEY_PATH" "$PROXMOX_USER@$PROXMOX_HOST" "apt update && apt install -y curl jq wget libguestfs-tools xz"
    scp -i "$PROXMOX_SSH_PRIVATE_KEY_PATH" scripts/pve-templater.sh "$PROXMOX_USER@$PROXMOX_HOST:/usr/local/bin/pve-templater"
    ssh -i "$PROXMOX_SSH_PRIVATE_KEY_PATH" "$PROXMOX_USER@$PROXMOX_HOST" "chmod +x /usr/local/bin/pve-templater"
