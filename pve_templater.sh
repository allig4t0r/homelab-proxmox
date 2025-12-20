#!/usr/bin/env bash
#
# Alexander Gerasimov allig4t0r[@]gmail.com
#
# Script to create vm templates on Proxmox node with ease.
# Especially suited to keep those templates up-to-date with the latest versions.
# Where applicable, hash sums and other metadata is saved in the Notes section of the template vm.
#
# Requires:
# libguestfs-tools to install qemu-guest-agent inside cloud images
# wget to download the images
# curl and jq for getting the metadata, latest version info, etc

set -euo pipefail

LOG_FILE="/var/log/pve_templater.log"
LOCK_FILE="/tmp/pve_templater.lock"
TMP_LOG=$(mktemp -t pve_templater_logXXXXXXXXXX)
MAX_LOG_SIZE=1048576   # 1MB
CACHE_DIR="/var/lib/pve_templater_cache"

display_usage() {
  cat <<EOF
Usage: pve_templater.sh <linux flavor> <vm id> [--resize <size>]

  --resize   What size template disk should be
EOF
}

require_bin() {
    if ! command -v "$1" >/dev/null 2>&1; then
        if [ "$1" = "virt-customize" ]; then
            echo "ERROR: libguestfs-tools required for injecting qemu-guest-agent." >&2
        elif [ "$1" = "qm" ]; then
            echo "ERROR: Are we on Proxmox host? qm not found" >&2
        else
            echo "ERROR: Required binary '$1' not installed." >&2
        fi
        exit 1
    fi
}

###################################PVE#########################################

get_vm_hash() {
    require_bin qm
    local vmid="$1"
    if qm config "$vmid" >/dev/null 2>&1; then
        local desc=$(qm config "$vmid" | grep -i '^description:' | sed 's/description: //')
        local hash=$(echo "$desc" | grep -oP '\b[a-f0-9]{64}\b|\b[a-f0-9]{128}\b')
        if [ -n "$hash" ]; then
            echo "$hash"
        else
            echo ""
        fi
    else
        echo ""
    fi
}

fetch() {
  curl --silent --show-error --fail "$@"
}

#################################LOGS##########################################

# UTC timestamp
__ts() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

rotate_logs() {
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size=$(stat -c%s "$LOG_FILE")
        if (( size > "$MAX_LOG_SIZE" )); then
            mv "$LOG_FILE" "${LOG_FILE}.$(date -u +%Y%m%d%H%M%S)"
            touch "$LOG_FILE"
            log_info "Log rotated due to size >1MB"
        fi
    fi
}

flush_logs() {
    exec 300>>"$LOG_FILE"
    flock 300
    cat "$TMP_LOG" >&300
    rm -f "$TMP_LOG"
}

############################GITHUB#############################################

get_latest_github() {
    require_bin curl
    local project="$1"
    local data
    data="$(
        curl --silent --fail --show-error \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/${project}/releases/latest"
    )"
    echo $data
}

get_tag() {
    require_bin jq
    local data="$1"
    local tag
    tag="$(jq -er '.tag_name' <<<"$data")"
    echo $tag
}

get_published_at() {
    require_bin jq
    local data="$1"
    local published_at
    published_at="$(jq -er '.published_at' <<<"$data")"
    echo $published_at
}

#################################IMAGES########################################

dl_image() {
    require_bin wget
    local image_url="$1"
    local hash
    wget -q -O "$(dirname "CACHE_DIR")/$(basename "$image_url")" "$image_url"
    hash="$(sha512sum $(basename "$image_url"))"
    echo $hash
    echo $image_url
}

compute_hash() {
    local file="$1"
    local hash_type="$2"
    case "$hash_type" in
        sha256) sha256sum "$file" | awk '{print $1}';;
        sha512) sha512sum "$file" | awk '{print $1}';;
        *) echo "Unsupported hash type"; exit 1;;
    esac
}

inject_qemu() {
    require_bin virt-customize
    local image="$1"
    echo "Injecting qemu-guest-agent"
    virt-customize -a "$image" --install qemu-guest-agent
}

###############################################################################

main() {
  trap flush_logs EXIT
  rotate_logs
  parse_flags "$@"
  log_info "###############################################################################"
  log_info "Start time:" __ts
}

main "$@"