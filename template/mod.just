set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']
set working-directory := '..'

bootstrap_dir := justfile_dir() + '/bootstrap'
kubernetes_dir := justfile_dir() + '/kubernetes'
talos_dir := justfile_dir() + '/talos'
terraform_dir := justfile_dir() + '/terraform'

template_dir := justfile_dir() + '/template'
template_resources := template_dir + '/resources'
makejinja_config := justfile_dir() + '/makejinja.toml'

config_file := justfile_dir() + '/homelab.yaml'
sample_config_file := justfile_dir() + '/homelab.sample.yaml'
schema_file := template_resources + '/config.schema.cue'

[private]
default:
    just template -l

[doc('Render and validate configuration files')]
[group('template')]
configure: render encrypt-secrets validate-talos

[doc('Check that all prerequisite files exist and homelab.yaml validates against the schema')]
[group('template')]
[no-exit-message]
[script]
doctor:
    rc=0
    just template doctor-check "homelab.yaml"           "{{ config_file }}"           || rc=1
    just template doctor-check "homelab.sample.yaml"    "{{ sample_config_file }}"    || rc=1
    just template doctor-check "age.key"                "$SOPS_AGE_KEY_FILE"          || rc=1
    just template doctor-check "template/"              "{{ template_dir }}"          || rc=1
    just template doctor-check "makejinja.toml"         "{{ makejinja_config }}"      || rc=1
    just template doctor-check "config.schema.cue"      "{{ schema_file }}"           || rc=1
    if [ -f "{{ config_file }}" ] && [ -f "{{ schema_file }}" ]; then
        if cue export "{{ config_file }}" "{{ schema_file }}" --out yaml >/dev/null 2>&1; then
            just log info "ok" check schema
        else
            just log error "fail" check schema
            just log info "diagnose with: cue export {{ config_file }} {{ schema_file }}"
            rc=1
        fi
    fi
    [ "$rc" = 0 ] && just log info "all good"
    exit "$rc"

[doc('Initialize configuration files (cluster.toml, age key, deploy key, push token)')]
[group('template')]
init:
    [ -f "{{ config_file }}" ]     || cp "{{ sample_config_file }}" "{{ config_file }}"
    [ -f "$SOPS_AGE_KEY_FILE" ]    || age-keygen --output "$SOPS_AGE_KEY_FILE"

[doc('Remove rendered files (bootstrap/, kubernetes/, talos/, terraform *.auto, .sops.yaml)')]
[group('template')]
[script]
reset:
    if ! gum confirm "Are you sure to remove all templated files and directories?"; then
        exit 1
    fi
    rm -rf "{{ bootstrap_dir }}" "{{ kubernetes_dir }}" "{{ talos_dir }}" "{{ terraform_dir }}/*.auto.tfvars" "{{ justfile_dir() }}/.sops.yaml" "{{ justfile_dir() }}/.env"

[no-exit-message]
[private]
[script]
doctor-check label path:
    if [ -e "{{ path }}" ]; then
        just log info "ok" file "{{ label }}"
    else
        just log error "missing" file "{{ label }}"
        exit 1
    fi

[private]
[script]
encrypt-secrets:
    find "{{ bootstrap_dir }}" "{{ kubernetes_dir }}" "{{ talos_dir }}" -type f -name '*.sops.*' -print0 \
        | while IFS= read -r -d '' f; do
            if [ "$(sops filestatus "$f" | jq '.encrypted')" = "false" ]; then
                sops --encrypt --in-place "$f"
            fi
        done

[private]
render:
    test -f "{{ schema_file }}"
    test -f "{{ template_dir }}/scripts/plugin.py"
    test -f "{{ makejinja_config }}"
    PYTHONDONTWRITEBYTECODE=1 makejinja

[private]
validate-kubernetes:
    test -f "{{ template_resources }}/kubeconform.sh"
    bash "{{ template_resources }}/kubeconform.sh" "{{ kubernetes_dir }}"

[private]
[working-directory('talos')]
validate-talos:
    test -f talconfig.yaml
    talhelper validate talconfig talconfig.yaml
