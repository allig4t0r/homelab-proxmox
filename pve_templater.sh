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
# xz to unzip talos images
# curl and jq for getting the metadata, latest version info, etc

set -euo pipefail

LOG_FILE="/var/log/pve_templater.log"
LOCK_FILE="/tmp/pve_templater.lock"
TMP_LOG=$(mktemp -t pve_templater_logXXXXXXXXXX)
MAX_LOG_SIZE=1048576   # 1MB
CACHE_DIR="/var/lib/vz/template/images"
STORAGE="nvme"
MEMORY=2048
CORES=2

# Talos ID for such configuration
# customization:
#     extraKernelArgs:
#         - console=ttyS0
#     systemExtensions:
#         officialExtensions:
#             - siderolabs/intel-ucode
#             - siderolabs/qemu-guest-agent
#             - siderolabs/util-linux-tools
TALOS_SCHEMATIC_ID="46d4c1f71ea8a0d5deeb85c27e5f4e9479ae592a532de2856f96926949294324"

display_usage() {
  cat <<EOF
Usage: pve_templater.sh <ubuntu|talos|flatcar> <vm id> [--resize <size>]

  --resize   What size template disk should be //TODO
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

check_vm() {
    require_bin qm
    local vmid="$1"
    if qm status "$vmid" &>/dev/null; then
        echo "[WARN] VM ${vmid} already exists. Removing old VM..."
        qm stop "$vmid" --skiplock 2>/dev/null || true
        qm destroy "$vmid" --purge 2>/dev/null || true
    fi
}

create_vm() {
    require_bin qm
    local vmid="$1"
    local name="$2"
    check_vm $vmid
    echo "Creating VM $vmid ($name)"
    qm create "$vmid" \
        --name "$name" \
        --ostype l26 \
        --machine q35 \
        --bios ovmf \
        --efidisk0 "${STORAGE}:0,efitype=4m" \
        --agent enabled=1 \
        --onboot 1 \
        --memory "$MEMORY" \
        --cores "$CORES" \
        --cpu host \
        --scsihw virtio-scsi-single \
        --tags template
}

import_disk() {
    require_bin qm
    local vmid="$1"
    local image="$2"
    echo "[INFO] Importing disk..."
    qm importdisk "$vmid" "$image" "$STORAGE"
    qm set "$vmid" \
        --scsi1 "${STORAGE}:vm-${vmid}-disk-1,iothread=1,discard=on,ssd=1" \
        --boot order=scsi1
}

get_vm_hash() {
    require_bin qm
    local vmid="$1"
    if qm config "$vmid" >/dev/null 2>&1; then
        local desc="$(
            qm config "$vmid" | \
            grep -i '^description:' | \
            sed 's/description: //'
        )"
        local hash="$(
            echo "$desc" | \
            grep -oP '\b[a-f0-9]{64}\b|\b[a-f0-9]{128}\b'
        )"
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
    echo "[INFO] Finished flushing logs. Removing tmp file..."
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
    local target_path
    mkdir -p "$CACHE_DIR"
    target_path="${CACHE_DIR%/}/$(basename "$image_url")"
    wget -q -O "$target_path" "$image_url"
    hash="$(compute_hash sha512 "$target_path")"
}

compute_hash() {
    local hash_type="$1"
    local file="$2"
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

###############################TEMPLATES#######################################

talos() {
    require_bin jq
    require_bin xz
    local vmid="$1"
    local name="$2"
    local talos_url
    local talos_image
    local latest_data
    local latest_tag
    local latest_date
    latest_data="$(get_latest_github "siderolabs/talos")"
    latest_tag="$(get_tag "$latest_data")"
    latest_date="$(get_published_at "$latest_data")"
    talos_url="https://factory.talos.dev/image/${TALOS_SCHEMATIC_ID}/${latest_tag}/nocloud-amd64.raw.xz"
    talos_image="${CACHE_DIR%/}/$(basename "${talos_url%.xz}")"
    dl_image "$talos_url"
    xz -dfk "${CACHE_DIR%/}/$(basename "$talos_url")"
    create_vm "$vmid" "$name"
    import_disk "$vmid" "$talos_image"
    qm set "$vmid" --description "$(cat <<EOF
Talos Linux published at: ${latest_date}  
Version: ${latest_tag}  
Date: $(date)
EOF
)"
    echo "[INFO] Converting VM ${vmid} to template..."
    qm template "$vmid"
    echo "Removing image ${talos_image}"
    rm -f "$talos_image"
}

###############################################################################

main() {
    trap flush_logs EXIT
#   rotate_logs
#   parse_flags "$@"
#   log_info "###############################################################################"
#   log_info "Start time:" __ts
    talos "944" "talos-latest"
}

main "$@"