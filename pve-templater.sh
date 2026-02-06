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

LOG_TO_CONSOLE=0
LOG_FILE="/var/log/pve-templater.log"
DEBUG_ENABLED=0
LOCK_FILE="/tmp/pve-templater.lock"
MAX_LOG_SIZE=1048576   # 1MB
CACHE_DIR="/var/lib/vz/template/images"
WORK_DIR="/var/tmp/pve-templater"
STORAGE="nvme"
MEMORY=2048
CORES=2
DEFAULT_DISK_SLOT="scsi1"
DEFAULT_BOOT_ORDER="scsi1"
UBUNTU_CODENAME="noble"

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

############################# SYSTEM ##########################################

display_usage() {
  log_debug "Displaying usage"
  cat <<EOF
Usage: pve_templater.sh <vm id> <ubuntu|talos|flatcar> <vm name> [--codename <codename>] [--debug] [--resize <size>] [--schematic <id>] [--version <version>]

  --codename   if you want to specify Ubuntu codename (noble/jammy/plucky/etc), default is noble (24.04 LTS) //TODO
  --debug, -v  enable DEBUG logging
  --resize     takes <+|-><size>[K|M|G|T] to change size, i.e. +10G adds 10GB, 10G equals total 10G size
  --schematic  if you want to specify Talos schematic ID
  --version    override the latest version check with a specific version (e.g. v1.2.3)
EOF
}

parse_flags() {
    RESIZE_VALUE=""
    OVERRIDE_VERSION=""

    # Enable console logging only if running interactively
    if [[ -t 1 && -t 2 ]]; then
        LOG_TO_CONSOLE=1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                display_usage
                exit 0
                ;;
            --codename)
                [[ -n "${2:-}" ]] || {
                    log_crit "--codename requires a Ubuntu codename (e.g. noble)"
                    exit 1
                }
                UBUNTU_CODENAME="$2"
                log_info "Ubuntu codename set to: ${UBUNTU_CODENAME}"
                shift 2
                ;;
            --resize)
                [[ -n "${2:-}" ]] || {
                    log_crit "--resize requires a value (e.g. 30G)"
                    exit 1
                }
                RESIZE_VALUE="$2"
                shift 2
                ;;
            --schematic)
                [[ -n "${2:-}" ]] || {
                    log_crit "--schematic requires Talos schematic ID"
                    exit 1
                }
                TALOS_SCHEMATIC_ID="$2"
                log_info "Overriding Talos schematic ID: ${TALOS_SCHEMATIC_ID}"
                shift 2
                ;;
            -v|--debug)
                DEBUG_ENABLED=1
                log_info "DEBUG logging mode enabled"
                shift
                ;;
            --version)
                [[ -n "${2:-}" ]] || {
                    log_crit "--version requires a value to override the latest version check (e.g. v1.2.3)"
                    exit 1
                }
                OVERRIDE_VERSION="$2"
                log_info "Version override enabled: ${OVERRIDE_VERSION}"
                shift 2
                ;;
            --*)
                log_crit "Unknown option: $1"
                display_usage
                exit 1
                ;;
            *)
                # Positional arguments (vmid, template name, etc.)
                POSITIONAL_ARGS+=("$1")
                shift
                ;;
        esac
    done

    # Restore positional parameters for main()
    set -- "${POSITIONAL_ARGS[@]}"
}

dispatch_template() {
    local vmid="$1"
    local template="$2"
    local name="$3"

    [[ -n "$vmid" && -n "$template" && -n "$name" ]] || {
        log_crit "Usage: <vm id> <template> <name>"
        display_usage
        exit 1
    }

    [[ "$vmid" =~ ^[0-9]+$ ]] || {
        log_crit "VMID must be numeric: ${vmid}"
        exit 1
    }

    log_info "Dispatching template: ${template} (VM ID ${vmid}, name ${name})"

    case "$template" in
        talos)
            talos "$vmid" "$name"
            ;;
        ubuntu)
            ubuntu "$vmid" "$name"
            ;;
        flatcar)
            flatcar "$vmid" "$name"
            ;;
        *)
            log_crit "Unknown template: ${template}"
            display_usage
            exit 1
            ;;
    esac
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

prepare_work_image() {    
    local vmid="$1"
    local image="$2"

    mkdir -p "$WORK_DIR" || {
        log_crit "Failed to create work directory: ${WORK_DIR}"
        return 1
    }

    local work_image="${WORK_DIR%/}/$(basename "$image").${vmid}.tmp.img"

    log_info "Creating working image copy"
    cp --reflink=auto "$image" "$work_image" || {
        log_crit "Failed to create working image"
        return 1
    }

    printf '%s' "$work_image"
}


resize_disk() {
    require_bin qemu-img

    local image="$1"
    local new_size="$2"

    [[ -f "$image" ]] || {
        log_crit "resize_disk: image ${image} not found"
        return 1
    }

    [[ -n "$new_size" ]] || {
        log_warn "resize_disk: not resizing disk because new size is empty"
        return 0
    }

    log_info "Resizing disk image ${image} to ${new_size}"
    # add virt-resize? //TODO
    if ! qemu-img resize "$image" "$new_size"; then
        log_crit "resize_disk: failed to resize image"
        return 1
    fi

    log_info "Disk was successfully resized"
}

import_disk() {
    require_bin qm

    local vmid="$1"
    local image="$2"

    [[ -f "$image" ]] || {
        log_crit "Disk image not found: ${image}"
        return 1
    }

    if [[ -n "$RESIZE_VALUE" ]]; then
        local work_image="$(prepare_work_image "$vmid" "$image")"
    fi

    log_info "Importing disk into VM ${vmid}"
    qm importdisk "$vmid" "$image" "$STORAGE"
    log_debug "Attaching disk and setting boot order"
    qm set "$vmid" \
        --"${DEFAULT_DISK_SLOT}" "${STORAGE}:vm-${vmid}-disk-1,iothread=1,discard=on,ssd=1" \
        --boot order="${DEFAULT_BOOT_ORDER}"

    log_info "Disk was successfully imported"

    if [[ -n "$work_image" ]]; then
        log_debug "Removing working image ${work_image}"
        rm -f "$work_image"
    fi
}

get_template_info() {
    require_bin qm

    local vmid="$1"
    local mode="$2"
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
    curl -fsSL "$@" \
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
        log_debug "Removing temporary file: ${tmp_path}"
        rm -f "$tmp_path"
        return 1
    else
        log_info "SHA512 checksum: ${hash512}"
    fi

    if ! hash256="$(get_hash sha256 "$tmp_path")"; then
        log_warn "Failed to calculate SHA256 hash for file: ${tmp_path}"
        log_debug "Removing temporary file: ${tmp_path}"
        rm -f "$tmp_path"
        return 1
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
    ###
    # talos()
    # └── import_disk()
    #     ├── prepare_work_image()
    #     ├── resize_disk()
    #     ├── qm importdisk
    #     └── cleanup
    ###
    require_bin xz

    local vmid="$1"
    local name="$2"
    local required_tag

    local current_tag="$(get_template_info "$vmid" tag)"

    if [[ -n "$OVERRIDE_VERSION" ]]; then
        required_tag="$OVERRIDE_VERSION"
    else
        local latest_data="$(get_latest_github "siderolabs/talos")"
        required_tag="$(get_tag "$latest_data")"
        local latest_date="$(get_published_at "$latest_data")"
    fi

    if [[ -z "$required_tag" ]]; then
        log_error "Empty latest tag from GitHub. Exiting."
        return 1
    elif [[ -n "$current_tag" && "$current_tag" == "$required_tag" ]]; then
        log_info "Talos image already up-to-date (${current_tag}). Exiting."
        return 0
    fi

    # echo $latest_data
    # echo $required_tag
    # echo $latest_date
    # echo $current_tag

    local talos_url="https://factory.talos.dev/image/${TALOS_SCHEMATIC_ID}/${required_tag}/nocloud-amd64.raw.xz"
    local talos_image="${CACHE_DIR%/}/$(basename "${talos_url%.xz}")"

    log_info "Downloading Talos ${required_tag} image..."
    dl_image "$talos_url"
    log_debug "Unpacking Talos image..."
    xz -dfk "${CACHE_DIR%/}/$(basename "$talos_url")"
    create_vm "$vmid" "$name"
    import_disk "$vmid" "$talos_image"
    log_info "Writing description with Talos image details"
    qm set "$vmid" --description "$(cat <<EOF
Talos Linux published at: ${latest_date}  
Version: **${required_tag}**  
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

    # Parse CLI flags and positional arguments
    parse_flags "$@"

    get_lock
    rotate_logs

    check_requirements \
        curl jq wget qm lsof numfmt logger stat

    log_info "================== pve-templater started (PID $$) =================="

    if [[ $# -eq 0 ]]; then
        # -------------------------------
        # Batch / cron mode
        # -------------------------------
        log_info "Running in batch mode (no CLI parameters)"
        log_info "For help and usage instructions, run with -h or --help flag"

        # ubuntu  "910" "ubuntu-latest"
        # flatcar "901" "flatcar-latest"
        # talos   "905" "talos-latest"
    else
        # -------------------------------
        # CLI / dispatch mode
        # -------------------------------
        dispatch_template "$@"
    fi

    log_info "================== pve-templater finished successfully =================="
}

main "$@"