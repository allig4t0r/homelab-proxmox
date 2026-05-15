set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']

scripts_dir := justfile_dir() + '/scripts'

[private]
default:
    just terraform -l

[doc('Check & apply the changes in terraform files')]
[group('terraform')]
sync: plan apply

[private]
init:
    terraform init -upgrade

[private]
plan:
    terraform plan -out=plan > /dev/null
    bash "{{ scripts_dir }}/tf-parser.sh" plan

[private]
[script]
apply:
    if [ ! -f plan ]; then
        exit 0
    fi
    if ! gum confirm "Are you sure to apply terraform changes?"; then
        rm -f plan plan.json
        exit 1
    fi
    terraform apply plan
    rm -f plan plan.json

[doc('Destroy Talos cluster')]
[group('terraform')]
[script]
destroy-talos:
    if [ ! -f talos.auto.tfvars ]; then
        just log info "talos.auto.tfvars was already removed"
        exit 0
    fi
    rm -f talos.auto.tfvars
    just tf plan
    just tf apply
