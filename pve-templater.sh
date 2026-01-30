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
#     less /var/log/pve_templater.log
# 
# Preferred way of using the script with multiple templates is to run all template functions in main():
#        main() {
#            <..>
#            log_info "================== pve-templater started (PID $$) =================="
#            talos "905" "talos-latest"
#            ubuntu "900" "ubuntu-latest"
#            flatcar "904" "flatcar-latest"
#            log_info "================== pve-templater finished successfully =================="
#        }

set -euo pipefail

LOG_TO_CONSOLE=1
LOG_FILE="/var/log/pve-templater.log"
DEBUG_ENABLED=0  #TODO get value from -v/--verbose?
LOCK_FILE="/tmp/pve-templater.lock"
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

############################# SYSTEM ##########################################

display_usage() {
  log_debug "Displaying usage"
  cat <<EOF
Usage: pve_templater.sh <ubuntu|talos|flatcar> <vm id> [--resize <size>] [--schematic <id>]

  --resize     What size template disk should be //TODO?
  --schematic  If you want to specify Talos schematic ID //TODO
  --codename   If you want to specify Ubuntu codename //TODO
EOF
}

check_requirements() {
    local missing=()

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

require_bin() {
    local bin="$1"

    log_debug "Checking if ${bin} is installed and working"
    if ! command -v "$bin" >/dev/null 2>&1; then
        if [ "$bin" = "virt-customize" ]; then
            log_crit "libguestfs-tools required for injecting qemu-guest-agent." >&2
        elif [ "$bin" = "qm" ]; then
            log_crit "Are we on Proxmox host? qm not found" >&2
        else
            log_crit "Required binary ${bin} not installed." >&2
        fi
        exit 1
    fi
    log_debug "${bin} is installed and working"
}

get_lock() {
    require_bin lsof

    log_debug "Trying to acquire the lock file"
    exec 9>"$LOCK_FILE" || exit 1
    flock -n 9 || {
        log_crit "Another pve_templater instance is running"
        log_info "Lock file: $LOCK_FILE"
        log_info "Processes holding or referencing the lock:"
        # lsof output is multiline → preserve formatting
        while IFS= read -r line; do
            log_info "$line"
        done < <(lsof "$LOCK_FILE" 2>/dev/null || true)
        exit 1
    }
    log_debug "Lock file was acquired"
}

################################## PVE ########################################

check_vm() {
    require_bin qm

    local vmid="$1"

    log_debug "Checking if VM ${vmid} exists"
    if qm status "$vmid" &>/dev/null; then
        log_warn "VM ${vmid} already exists. Removing old VM..."
        qm stop "$vmid" --skiplock 2>/dev/null || true
        qm destroy "$vmid" --purge 2>/dev/null || true
        log_info "VM ${vmid} was successfully removed"
    fi
}

create_vm() {
    require_bin qm

    local vmid="$1"
    local name="$2"

    check_vm $vmid
    log_info "Creating VM ${vmid} (${name})..."
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
    log_info "Successfully created new VM"
}

import_disk() {
    require_bin qm

    local vmid="$1"
    local image="$2"

    log_info "Importing disk..."
    qm importdisk "$vmid" "$image" "$STORAGE"
    log_debug "Initializing disk on SCSI1..."
    qm set "$vmid" \
        --scsi1 "${STORAGE}:vm-${vmid}-disk-1,iothread=1,discard=on,ssd=1" \
        --boot order=scsi1
    log_info "Disk was successfully imported"
}

get_template_info() {
    require_bin qm

    local mode="$1"
    local vmid="$2"
    local result

    log_info "Getting template information for VM ${vmid}..."
    if qm config "$vmid" >/dev/null 2>&1; then
        log_debug "Getting VM description..."
        local desc="$(
            qm config "$vmid" | \
            grep -i '^description:' | \
            sed 's/description: //'
        )"
        log_debug "Template info mode: ${mode}"
        case "$mode" in
            hash) result="$(echo "$desc" | \
                grep -Eo '\b[a-f0-9]{64}\b|\b[a-f0-9]{128}\b'
            )";;
            tag) result="$(echo "$desc" | \
                grep -Eo 'v?[0-9]+(\.[0-9]+)+'
            )";;
            *) log_warn "Unsupported get_template_info mode: ${mode}"; return 1;;
        esac
        if [ -n "$result" ]; then
            log_info "Successfully read template info for VM ${vmid}. Extracted data: ${result}"
            printf '%s' "$result"
        else
            log_warn "Template info is empty"
            echo ""
        fi
    else
        log_error "Cannot get VM ${vmid} config details"
        return 1
    fi
}

fetch() {
    require_bin curl
    curl -fsSL \
        "$@" \
        2> >(while IFS= read -r line; do
                log_error "$line"
            done)
}

################################# LOGS ########################################

_log() {
    local level="$1"
    local priority="$2"
    shift 2
    local msg="$*"
    local ts

    ts="$(date -Is)"

    # UTC timestamps
    # ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    # STDERR for console output
    if [[ "$LOG_TO_CONSOLE" -eq 1 ]]; then
        printf '[%s] %s\n' "$level" "$msg" >&2
    fi

    # File log
    printf '%s [%s] %s\n' "$ts" "$level" "$msg" >>"$LOG_FILE"

    # journald (native priority)
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

rotate_logs() {
    log_debug "Checking if log rotation is needed"
    if [[ -f "$LOG_FILE" ]]; then
        local size
        log_debug "Log file ${LOG_FILE} exists"
        size=$(stat -c%s "$LOG_FILE")
        log_debug "Log filesize: $(numfmt --to=iec "$size")"
        if (( size > "$MAX_LOG_SIZE" )); then
            log_debug "Log exceeds 1MB. Rotating the log..."
            mv "$LOG_FILE" "${LOG_FILE}.$(date -u +%Y%m%d%H%M%S)"
            log_debug "Creating new empty log file"
            touch "$LOG_FILE"
            log_notice "Log rotated due to size >1MB"
        fi
    fi
}

############################### GITHUB ########################################

get_latest_github() {
    local project="$1"
    local data

    log_info "Fetching latest GitHub release for ${project}"

    fetch \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${project}/releases/latest"
}

parse_field() {
    require_bin jq
    
    local field="$1"
    local data="$2"

    jq -er ".${field}" <<<"$data"
}

get_tag() {
    local tag=$(parse_field tag_name "$1")

    log_info "Latest GitHub release tag: ${tag}"

    printf '%s' "$tag"
}

get_published_at() {
    local published_at=$(parse_field published_at "$1")

    log_info "Latest GitHub release publish date: ${published_at}"

    printf '%s' "$published_at"
}

################################ IMAGES #######################################

dl_image() {
    require_bin wget

    local image_url="$1"
    local hash512
    local hash256
    local target_path="${CACHE_DIR%/}/$(basename "$image_url")"
    local tmp_path="${target_path}.tmp.$$"
    local wget_opts=(
        --timeout=30
        --tries=3
        --read-timeout=30
        -O "$tmp_path"
        -q
    )

    mkdir -p "$CACHE_DIR" || {
        log_error "Failed to create cache directory: $CACHE_DIR"
        return 1
    }

    log_info "Image URL: ${image_url}"
    log_debug "Target path: ${target_path}"
    log_debug "Temporary path: ${tmp_path}"

    if [[ "${LOG_TO_CONSOLE}" -eq 1 ]]; then
        wget_opts+=(--show-progress)
    fi

    if ! wget "${wget_opts[@]}" "$image_url"; then
        log_error "Download failed: ${image_url}"
        log_debug "Removing temporary file: ${tmp_path}"
        rm -f "$tmp_path"
        return 1
    fi

    if [ ! -s "$tmp_path" ]; then
        log_error "Downloaded file is empty: ${image_url}"
        log_debug "Removing temporary file: ${tmp_path}"
        rm -f "$tmp_path"
        return 1
    fi

    if ! hash512="$(get_hash sha512 "$tmp_path")"; then
        log_warn "Failed to calculate SHA512 hash for file: ${tmp_path}"
        # log_debug "Removing temporary file: ${tmp_path}"
        # rm -f "$tmp_path"
        # return 1
    else
        log_info "SHA512 checksum: ${hash512}"
    fi

    if ! hash256="$(get_hash sha256 "$tmp_path")"; then
        log_warn "Failed to calculate SHA256 hash for file: ${tmp_path}"
        # log_debug "Removing temporary file: ${tmp_path}"
        # rm -f "$tmp_path"
        # return 1
    else
        log_info "SHA256 checksum: ${hash256}"
    fi

    if ! mv -f "$tmp_path" "$target_path"; then
        log_error "Failed to move file into cache: ${target_path}"
        log_debug "Removing temporary file: ${tmp_path}"
        rm -f "$tmp_path"
        return 1
    fi

    log_info "Image cached successfully: ${target_path}"
}

get_hash() {
    local hash_type="$1"
    local file="$2"

    log_debug "Creating SHA hash for file ${2}"
    case "$hash_type" in
        sha256) sha256sum "$file" | awk '{print $1}';;
        sha512) sha512sum "$file" | awk '{print $1}';;
        *) log_warn "Unsupported hash type"; return 1;;
    esac
    log_debug "Hash was successfully created"
}

inject_qemu() {
    require_bin virt-customize

    local image="$1"

    log_info "Injecting qemu-guest-agent"
    virt-customize -a "$image" --install qemu-guest-agent
    log_info "Success! qemu-guest-agent was installed into image ${image}"
}

############################## TEMPLATES ######################################

talos() {
    require_bin xz

    local vmid="$1"
    local name="$2"

    local latest_data="$(get_latest_github "siderolabs/talos")"
    local latest_tag="$(get_tag "$latest_data")"
    local latest_date="$(get_published_at "$latest_data")"
    local current_tag="$(get_template_info tag "$vmid")"

    # echo $latest_data
    # echo $latest_tag
    # echo $latest_date
    # echo $current_tag

    if [[ -z "$latest_data" || -z "$latest_tag" ]]; then
        log_error "Empty latest tag from GitHub. Exiting."
        return 1
    elif [[ -n "$current_tag" && "$current_tag" == "$latest_tag" ]]; then
        log_info "Talos image already up-to-date (${latest_tag}). Exiting."
        return 0
    fi

    local talos_url="https://factory.talos.dev/image/${TALOS_SCHEMATIC_ID}/${latest_tag}/nocloud-amd64.raw.xz"
    local talos_image="${CACHE_DIR%/}/$(basename "${talos_url%.xz}")"

    log_info "Downloading Talos ${latest_tag} image..."
    dl_image "$talos_url"
    log_debug "Unpacking Talos image..."
    xz -dfk "${CACHE_DIR%/}/$(basename "$talos_url")"
    create_vm "$vmid" "$name"
    import_disk "$vmid" "$talos_image"
    log_info "Writing description with Talos image details"
    qm set "$vmid" --description "$(cat <<EOF
Talos Linux published at: ${latest_date}  
Version: *${latest_tag}*  
Date: $(date +"%a %b %d %H:%M:%S %Z %Y")
EOF
)"
    log_info "Converting VM ${vmid} to template..."
    qm template "$vmid"
    log_info "Deleting unpacked image ${talos_image} (archive is untouched)"
    rm -f "$talos_image"
}

# ubuntu() {

# }

###############################################################################

main() {
    trap 'log_error "Command failed: \"$BASH_COMMAND\" (line $LINENO)"' ERR
    trap 'rm -f "$LOCK_FILE"; log_debug "Lock file removed"' EXIT

    get_lock
    rotate_logs
    # parse_flags "$@"

    check_requirements \
        curl jq wget qm lsof numfmt logger stat

    log_info "================== pve-templater started (PID $$) =================="
    talos "905" "talos-latest"
    log_info "================== pve-templater finished successfully =================="
}

main "$@"