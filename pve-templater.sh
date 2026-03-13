#!/usr/bin/env bash
#
# Alexander Gerasimov allig4t0r[@]gmail.com
#
# Bash framework to create VM templates on Proxmox nodes with ease.
# Especially suited to keep those templates up-to-date with the latest versions.
# Where applicable, hash sums and other metadata is saved in the Notes section of the template vm.
#
# Requires:
# libguestfs-tools to install qemu-guest-agent inside cloud images
# wget to download the images
# xz to unzip talos images
# curl and jq for getting the metadata, latest version info, etc
# lsof for checking lock file descriptors
#
# Check logs using:
#     journalctl -t pve-templater
#     less /var/log/pve-templater.log
# 
# Preferred way of using the script with multiple templates is to run all template functions in main():
#        main() {
#            <..>
#            log_info "================== pve-templater started (PID $$) =================="
#
#            if [[ $# -eq 0 ]]; then
#                log_info "Running in batch mode (no CLI parameters)"
#                if [[ $LOG_TO_CONSOLE -eq 1 ]]; then log_info "For help and usage instructions, run with -h or --help flag"; fi
#                # Put your batch mode templates here
#                # provider_ubuntu  "910" "ubuntu-latest"
#                # provider_flatcar "901" "flatcar-latest"
#                # provider_talos   "905" "talos-latest"
#                # Batch mode end

set -euo pipefail

############################# GLOBALS #########################################

LOG_TO_CONSOLE=0
LOG_FILE="/var/log/pve-templater.log"
DEBUG_ENABLED=0
LOCK_FILE="/tmp/pve-templater.lock"
MAX_LOG_SIZE=1048576   # 1MB
FORCE_DOWNLOAD=0
CACHE_DIR="/var/lib/vz/template/images"
WORK_DIR="/var/tmp/pve-templater"
STORAGE="nvme"
MEMORY=2048
CORES=2
DEFAULT_DISK_SLOT="scsi1"
DEFAULT_BOOT_ORDER="scsi1"
UBUNTU_CODENAME="noble"
SOCKS5_PROXY="172.17.0.22:1080"

# Global array to track files for cleanup on exit
CLEANUP_FILES=()

# Talos ID for such configuration, UEFI only
# customization:
#     extraKernelArgs:
#         - console=ttyS0
#     systemExtensions:
#         officialExtensions:
#             - siderolabs/intel-ucode
#             - siderolabs/qemu-guest-agent
#             - siderolabs/util-linux-tools
#     bootloader: sd-boot
TALOS_SCHEMATIC_ID="cfd24ff03f3a694b19911cb656d76636339f25b45ff1f46931095bbaad2ca9e5"

############################# SYSTEM / CORE ###################################

cleanup() {
    local exit_code=$?
    
    if [[ ${#CLEANUP_FILES[@]} -gt 0 ]]; then
        log_debug "Cleaning up tracked temporary files: ${CLEANUP_FILES[*]}"
        rm -f "${CLEANUP_FILES[@]}"
    fi

    if [[ -d "$CACHE_DIR" ]]; then
        log_debug "Searching for orphaned .tmp.<PID> files in CACHE_DIR"
        find "$CACHE_DIR" -type f -regex ".*\.tmp\.[0-9]+$" -exec rm -f {} + 2>/dev/null || true
    fi
    
    if [[ -d "$WORK_DIR" ]]; then
        log_debug "Searching for orphaned .tmp.<PID> files in WORK_DIR"
        find "$WORK_DIR" -type f -regex ".*\.tmp\.[0-9]+$" -exec rm -f {} + 2>/dev/null || true
    fi

    rm -f "$LOCK_FILE"
    log_debug "Lock file removed"
    exit $exit_code
}

sys_require_bin() {
    local bin="$1"
    log_debug "Checking if ${bin} is installed and working"
    if ! command -v "$bin" >/dev/null 2>&1; then
        if [ "$bin" = "virt-customize" ]; then
            log_crit "libguestfs-tools are required for injecting qemu-guest-agent" >&2
        elif [ "$bin" = "qm" ]; then
            log_crit "Are we on Proxmox host? qm not found" >&2
        else
            log_crit "Required binary ${bin} not installed" >&2
        fi
        exit 1
    fi
}

sys_check_requirements() {
    local missing=()
    log_debug "Checking script requirements"
    for bin in "$@"; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done
    if (( ${#missing[@]} > 0 )); then
        log_crit "Missing required dependencies:"
        for bin in "${missing[@]}"; do
            log_crit "  - ${bin}"
        done
        exit 1
    fi
}

sys_get_lock() {
    # sys_require_bin lsof
    log_debug "Trying to acquire the lock file"
    exec 9>"$LOCK_FILE" || exit 1
    flock -n 9 || {
        log_crit "Another pve-templater instance is running"
        log_info "Lock file: $LOCK_FILE"
        log_info "Processes holding or referencing the lock:"
        while IFS= read -r line; do log_info "$line"; done < <(lsof "$LOCK_FILE" 2>/dev/null || true)
        exit 1
    }
    log_debug "Lock file was acquired"
}

display_usage() {
  log_debug "Displaying usage"
  cat <<EOF
Usage: $0 <vm id> <os> <vm name> [options]

Available OS templates:
EOF
  for func in $(declare -F | awk '{print $3}' | grep '^provider_'); do
      echo "  - ${func#provider_}"
  done
  cat <<EOF

Options:
  --codename   if you want to specify Ubuntu codename (noble/jammy/plucky/etc), default is noble (24.04 LTS)
  --debug, -v  enable DEBUG logging
  --resize     takes <+|-><size>[K|M|G|T] to change size, i.e. +10G adds 10GB, 10G equals total 10G size
  --schematic  if you want to specify Talos schematic ID
  --force      forces image download and template creation
  --version    override the latest version check with a specific version (e.g. v1.2.3)
EOF
}

parse_flags() {
    RESIZE_VALUE=""
    OVERRIDE_VERSION=""

    if [[ -t 1 && -t 2 ]]; then
        LOG_TO_CONSOLE=1
    else
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) display_usage; exit 0 ;;
            --codename) UBUNTU_CODENAME="${2:-}"; shift 2 ;;
            --force) FORCE_DOWNLOAD=1; shift ;;
            --resize) RESIZE_VALUE="${2:-}"; shift 2 ;;
            --schematic) TALOS_SCHEMATIC_ID="${2:-}"; shift 2 ;;
            -v|--debug) DEBUG_ENABLED=1; shift ;;
            --version) OVERRIDE_VERSION="${2:-}"; shift 2 ;;
            --*|-*) log_crit "Unknown option: $1"; display_usage; exit 1 ;;
            *) POSITIONAL_ARGS+=("$1"); shift ;;
        esac
    done
    set -- "${POSITIONAL_ARGS[@]:-}"
}

dispatch_template() {
    local vmid="${1:-}" template="${2:-}" name="${3:-}"
    [[ -n "$vmid" && -n "$template" && -n "$name" ]] || { display_usage; exit 1; }
    [[ "$vmid" =~ ^[0-9]+$ ]] || { log_crit "VMID must be numeric: ${vmid}"; exit 1; }

    local provider_func="provider_${template}"
    if declare -f "$provider_func" > /dev/null; then
        log_info "Dispatching template: ${template} (VM ID ${vmid}, name ${name})"
        "$provider_func" "$vmid" "$name"
    else
        log_crit "Unknown template provider: ${template}"
        display_usage
        exit 1
    fi
}

############################# LOGS ############################################

_log() {
    local level="$1" priority="$2"; shift 2; local msg="$*"
    local ts="$(date -Is)"
    if [[ "$LOG_TO_CONSOLE" -eq 1 ]]; then printf '[%s] %s\n' "$level" "$msg" >&2; fi
    printf '%s [%s] %s\n' "$ts" "$level" "$msg" >>"$LOG_FILE"
    logger -t pve-templater -p "user.${priority}" "$msg"
}
log_debug() {
    [[ "$DEBUG_ENABLED" -eq 1 ]] || return 0
    _log DEBUG debug "$@"
}
log_info()    { _log INFO    info    "$@"; }
log_notice()  { _log NOTICE  notice  "$@"; }
log_warn()    { _log WARN    warning "$@"; }
log_error()   { _log ERROR   err     "$@"; }
log_crit()    { _log CRIT    crit    "$@"; }

log_rotate() {
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size=$(stat -c%s "$LOG_FILE")
        if (( size > "$MAX_LOG_SIZE" )); then
            mv "$LOG_FILE" "${LOG_FILE}.$(date -u +%Y%m%d%H%M%S)"
            touch "$LOG_FILE"
            log_notice "Log rotated due to size >1MB"
        fi
    fi
}

############################# NETWORK / HELPERS ###############################

sys_fetch() {
    curl -fsSL "$@" 2> >(while IFS= read -r line; do log_error "$line"; done)
}

sys_get_latest_github_release() {
    local project="$1" field="$2"
    # sys_require_bin jq
    log_debug "Fetching Github latest data: project ${project} field ${field}"
    sys_fetch -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${project}/releases/latest" | jq -er ".${field}"
}

sys_compute_hash() {
    local hash_type="$1" file="$2"
    case "$hash_type" in
        sha256) sha256sum "$file" | awk '{print $1}';;
        sha512) sha512sum "$file" | awk '{print $1}';;
        *) log_warn "Unsupported hash type"; return 1;;
    esac
}

sys_download_file() {
    # sys_require_bin wget
    local image_url="$1" tool="${2:-wget}" expected_hash="${3:-}" hash_type="${4:-sha256}" 
    local target_path="${CACHE_DIR%/}/$(basename "$image_url")"
    local tmp_path="${target_path}.tmp.$$"
    local wget_opts=(--timeout=30 --tries=3 --read-timeout=30 -O "$tmp_path" -q)
    local curl_opts=(-fSL -x socks5h://"${SOCKS5_PROXY}" -o "$tmp_path")
    local download_success=0

    # Register the temp file for automatic cleanup if the script is interrupted
    CLEANUP_FILES+=("$tmp_path")

    mkdir -p "$CACHE_DIR" || { log_error "Failed to create cache dir: $CACHE_DIR"; return 1; }
    [[ "$LOG_TO_CONSOLE" -eq 1 ]] && { wget_opts+=(--show-progress); curl_opts+=(--progress-bar); } || curl_opts+=(--silent)

    log_info "URL: ${image_url} using ${tool}"
    
    if [[ "$tool" == "curl" ]]; then
        log_debug "curl opts: ${curl_opts[*]}"

        if curl "${curl_opts[@]}" "$image_url"; then
            download_success=1
        fi
    else
        log_debug "wget opts: ${wget_opts[*]}"

        if wget "${wget_opts[@]}" "$image_url"; then
            download_success=1
        fi
    fi

    if [[ $download_success -eq 0 ]]; then
        log_error "Download failed: ${image_url}"
        rm -f "$tmp_path"
        return 1
    fi    
    
    if [ ! -s "$tmp_path" ]; then
        log_error "Downloaded file is empty"; rm -f "$tmp_path"; return 1
    fi

    if [[ -n "$expected_hash" ]]; then
        local actual_hash
        actual_hash="$(sys_compute_hash "$hash_type" "$tmp_path")"
        if [[ "$actual_hash" != "$expected_hash" ]]; then
            log_error "Hash mismatch! Expected: $expected_hash, Got: $actual_hash"
            rm -f "$tmp_path"; return 1
        fi
        log_info "Checksum verified (${hash_type}): ${actual_hash}"
    fi

    mv -f "$tmp_path" "$target_path"
    log_info "Image cached: ${target_path}"
    printf '%s' "$target_path"
}

############################# IMAGES ##########################################

img_inject_qga() {
    sys_require_bin virt-customize
    local image="$1"
    log_info "Injecting qemu-guest-agent into $image"
    virt-customize -a "$image" --install qemu-guest-agent
}

img_resize() {
    sys_require_bin qemu-img
    local image="$1" new_size="$2"
    log_info "Resizing disk image ${image} to ${new_size}"
    qemu-img resize "$image" "$new_size" || { log_crit "Failed to resize image"; return 1; }
}

############################# PVE API #########################################

pve_get_metadata() {
    # sys_require_bin qm
    local vmid="$1" search_key="$2"
    if qm config "$vmid" >/dev/null 2>&1; then
        if [[ "$search_key" == "hash" ]]; then
            qm config "$vmid" | grep -i '^description:' | grep -Eo '\b[a-f0-9]{64}\b|\b[a-f0-9]{128}\b' || true
        elif [[ "$search_key" == "tag" ]]; then
            qm config "$vmid" | grep -i '^description:' | grep -Eo 'v?[0-9]+(\.[0-9]+)+' || true
        fi
    fi
}

pve_is_template_outdated() {
    local vmid="$1" expected_value="$2" search_key="$3"
    if [[ "$FORCE_DOWNLOAD" -eq 1 ]]; then return 0; fi # "Outdated" if --force
    local current_value="$(pve_get_metadata "$vmid" "$search_key")"
    if [[ -z "$expected_value" ]]; then return 0; fi # Outdated if no expected
    if [[ -n "$current_value" && "$current_value" == "$expected_value" ]]; then
        return 1 # False (Not outdated)
    fi
    return 0 # True (Outdated)
}

pve_create_vm() {
    # sys_require_bin qm
    local vmid="$1" name="$2"
    if qm status "$vmid" &>/dev/null; then
        log_warn "VM ${vmid} already exists. Removing old VM..."
        qm stop "$vmid" --skiplock 2>/dev/null || true
        qm destroy "$vmid" --purge 2>/dev/null || true
    fi
    log_info "Creating VM ${vmid} (${name})..."
    qm create "$vmid" --name "$name" --ostype l26 --machine q35 --bios ovmf \
        --efidisk0 "${STORAGE}:0,efitype=4m" --agent enabled=1 --onboot 1 \
        --memory "$MEMORY" --cores "$CORES" --cpu host --scsihw virtio-scsi-single --tags template
}

pve_import_disk() {
    # sys_require_bin qm
    local vmid="$1" image="$2"
    log_info "Importing disk into VM ${vmid}"
    qm importdisk "$vmid" "$image" "$STORAGE"
    qm set "$vmid" --"${DEFAULT_DISK_SLOT}" "${STORAGE}:vm-${vmid}-disk-1,iothread=1,discard=on,ssd=1" \
                   --boot order="${DEFAULT_BOOT_ORDER}"
}

pve_build_template() {
    local vmid="$1" name="$2" image="$3" desc="$4" resize="${5:-}"
    
    pve_create_vm "$vmid" "$name"
    if [[ -n "$resize" ]]; then img_resize "$image" "$resize"; fi
    pve_import_disk "$vmid" "$image"
    
    log_info "Writing template metadata"
    qm set "$vmid" --description "$desc"
    
    log_info "Converting VM ${vmid} to template..."
    qm template "$vmid"
}

############################# PROVIDERS #######################################

provider_talos() {
    sys_require_bin xz
    local vmid="$1" name="$2" talos_version latest_date xz_file

    if [[ -n "$OVERRIDE_VERSION" ]]; then
        talos_version="$OVERRIDE_VERSION"
        latest_date="N/A"
    else
        log_info "Fetching Talos latest version"
        talos_version="$(sys_get_latest_github_release "siderolabs/talos" "tag_name")"
        latest_date="$(sys_get_latest_github_release "siderolabs/talos" "published_at")"
    fi

    if [[ -z "$talos_version" ]]; then log_error "Empty tag, cannot download. Exiting."; return 1; fi
    
    if ! pve_is_template_outdated "$vmid" "$talos_version" "tag"; then
        log_info "Talos image already up-to-date (${talos_version}). Exiting."
        return 0
    fi

    log_info "Upstream Talos version: ${talos_version}"

    local talos_url="https://factory.talos.dev/image/${TALOS_SCHEMATIC_ID}/${talos_version}/nocloud-amd64.raw.xz"
    xz_file="$(sys_download_file "$talos_url" "curl")"
    
    local raw_img="${WORK_DIR}/talos_${vmid}.raw"
    mkdir -p "$WORK_DIR"
    CLEANUP_FILES+=("$raw_img")

    log_debug "Unpacking Talos image..."
    xz -dfk "$xz_file" -c > "$raw_img"

    local desc="$(cat <<EOF
Talos Linux published at: **${latest_date}**  
Version: **${talos_version}**  
Date: **$(date -Is)**  
EOF
)"
    
    pve_build_template "$vmid" "$name" "$raw_img" "$desc" "${RESIZE_VALUE}"
    
    log_info "Talos template ${name} (${vmid}) successfully created"
}

provider_ubuntu() {
    local vmid="$1" name="$2" codename="$UBUNTU_CODENAME" remote_hash cached_image image_date
    local image_name="${codename}-server-cloudimg-amd64.img"
    local image_url="https://cloud-images.ubuntu.com/${codename}/current/${image_name}"
    local checksum_url="https://cloud-images.ubuntu.com/${codename}/current/SHA256SUMS"

    log_info "Preparing Ubuntu template (${codename})"
    log_info "Fetching Ubuntu checksums"
    remote_hash="$(sys_fetch "$checksum_url" | awk "/${image_name}$/ {print \$1}")"

    if [[ -z "$remote_hash" ]]; then log_error "Failed to obtain upstream SHA256"; return 1; fi

    if ! pve_is_template_outdated "$vmid" "$remote_hash" "hash"; then
        log_info "Ubuntu image already up-to-date (${remote_hash}). Exiting."
        return 0
    fi

    log_info "Upstream Ubuntu SHA256: ${remote_hash}"

    cached_image="$(sys_download_file "$image_url" "wget" "$remote_hash" "sha256")"
    image_date="$(sys_fetch -I "$image_url" | awk -F': ' 'tolower($1)=="last-modified" {print $2}' | tr -d '\r')"
    image_date="$(date -d "$image_date" +%Y-%m-%d 2>/dev/null || echo "${image_date:-Unknown}")"

    mkdir -p "$WORK_DIR"
    local work_image="${WORK_DIR}/${vmid}_${image_name}"
    CLEANUP_FILES+=("$work_image")
    
    log_info "Creating working copy of image..."
    cp --reflink=auto "$cached_image" "$work_image"
    
    img_inject_qga "$work_image"

    local desc="$(cat <<EOF
Ubuntu **${codename^}** Cloud Image  
Build date: **${image_date}**  
Checksum (SHA256): **${remote_hash}**  
Date: **$(date -Is)**  
EOF
)"
    
    pve_build_template "$vmid" "$name" "$work_image" "$desc" "${RESIZE_VALUE}"

    log_info "Ubuntu template ${name} (${vmid}) successfully created"
}

provider_flatcar() {
    local vmid="$1" name="$2"

    local base_url="https://stable.release.flatcar-linux.net/amd64-usr/current"
    local version_url="${base_url}/version.txt"
    
    log_info "Fetching Flatcar latest version"
    local version_info
    version_info="$(sys_fetch "$version_url" || true)"

    local flatcar_version
    flatcar_version="$(echo "$version_info" | grep '^FLATCAR_VERSION=' | cut -d= -f2 || true)"
    
    local flatcar_build_id
    flatcar_build_id="$(echo "$version_info" | grep '^FLATCAR_BUILD_ID=' | cut -d= -f2 | tr -d '"' || true)"
    
    if [[ -z "$flatcar_version" ]]; then
        log_error "Failed to obtain Flatcar version"
        return 1
    fi

    if ! pve_is_template_outdated "$vmid" "$flatcar_version" "tag"; then
        log_info "Flatcar image already up-to-date (${flatcar_version}). Exiting."
        return 0
    fi

    log_info "Upstream Flatcar version: ${flatcar_version}"

    local img_name="flatcar_production_proxmoxve_image.img"
    local img_url="${base_url}/${img_name}"
    local digests_url="${img_url}.DIGESTS"

    log_info "Fetching Flatcar SHA512 hash"
    local remote_hash
    remote_hash="$(sys_fetch "$digests_url" | awk '/^# SHA512 HASH/{getline; print $1}')"

    if [[ -z "$remote_hash" ]]; then
        log_error "Failed to obtain upstream SHA512 hash"
        return 1
    fi

    log_info "Downloading Flatcar ${flatcar_version} Proxmox VE image..."
    local cached_image
    cached_image="$(sys_download_file "$img_url" "curl" "$remote_hash" "sha512")"

    mkdir -p "$WORK_DIR"
    local work_image="${WORK_DIR}/${vmid}_${img_name}"
    CLEANUP_FILES+=("$work_image")
    
    log_info "Creating working copy of image..."
    cp --reflink=auto "$cached_image" "$work_image"

    local desc="$(cat <<EOF
Flatcar Container Linux (Proxmox VE)  
Version: **${flatcar_version}**  
Build ID: **${flatcar_build_id}**  
Checksum (SHA512): **${remote_hash}**  
Date: **$(date -Is)**  
EOF
)"
    
    # Flatcar Proxmox image already includes qemu-guest-agent, so no injection needed.
    pve_build_template "$vmid" "$name" "$work_image" "$desc" "${RESIZE_VALUE}"

    log_info "Flatcar template ${name} (${vmid}) successfully created"
}

############################# MAIN ############################################

main() {
    trap 'log_error "Command failed: \"$BASH_COMMAND\" (line $LINENO)"' ERR
    trap 'cleanup' EXIT

    parse_flags "$@"
    sys_get_lock
    log_rotate
    sys_check_requirements curl jq wget qm lsof logger stat

    log_info "================== pve-templater started (PID $$) =================="

    if [[ $# -eq 0 ]]; then
        log_info "Running in batch mode (no CLI parameters)"
        if [[ $LOG_TO_CONSOLE -eq 1 ]]; then log_info "For help and usage instructions, run with -h or --help flag"; fi
        # Put your batch mode templates here
        provider_ubuntu  "910" "ubuntu-latest"
        provider_flatcar "904" "flatcar-latest"
        provider_talos   "905" "talos-latest"
        # Batch mode end
    else
        dispatch_template "${POSITIONAL_ARGS[@]}"
    fi

    log_info "================== pve-templater finished successfully =================="
}

main "$@"
