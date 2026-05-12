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

[group: 'PVE']
mod? pve 'pve'

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

[doc('Recreate Talos k8s cluster')]
[group('Talos')]
recreate-talos:
    just tf destroy-talos
    just template reset
    just configure
    just tf sync
    just bootstrap talos
    just bootstrap apps
