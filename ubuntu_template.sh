#!/bin/bash
set -euo pipefail

# ----------------------------------------
# Proxmox Ubuntu 24.04 Cloud Image Template Builder (Smart Cached)
# ----------------------------------------
# Features:
#   - Downloads Ubuntu 24.04 LTS cloud image only if updated upstream
#   - Installs qemu-guest-agent and resizes image
#   - Imports directly into Proxmox VM (ID 910) on storage "nvme"
#   - Attaches metadata: build date + checksum
# ----------------------------------------

# --- CONFIGURATION ---
VMID=910
VM_NAME="ubuntu-2404-latest"
STORAGE="nvme"
MEMORY=2048
CPUS=2
CACHE_DIR="/root/templates"
DISK_SIZE="30G"

IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMG_FILE="${CACHE_DIR}/noble-server-cloudimg-amd64.img"
RESIZED_IMG="${CACHE_DIR}/ubuntu-2404-cloudimg-amd64-resized.img"

# --- CLEANUP HANDLER ---
cleanup() {
    echo "[INFO] Cleaning temporary files..."
    rm -f "${RESIZED_IMG}"
}
trap cleanup EXIT

echo "[INFO] Today is $(date)"
echo "[INFO] Checking for Ubuntu 24.04 image update..."

# --- Get remote checksum from Ubuntu server ---
CHECKSUM_URL="$(dirname "$IMG_URL")/SHA256SUMS"
REMOTE_SHA256=$(curl -s "$CHECKSUM_URL" | grep "$(basename "$IMG_URL")" | awk '{print $1}')

if [[ -f "$IMG_FILE" ]]; then
    LOCAL_SHA256=$(sha256sum "$IMG_FILE" | awk '{print $1}')
    if [[ "$REMOTE_SHA256" == "$LOCAL_SHA256" ]]; then
        echo "[INFO] Image already up-to-date. Exiting."
        exit 0
    else
        echo "[INFO] New image detected. Downloading..."
        wget -q -O "$IMG_FILE" "$IMG_URL"
    fi
else
    echo "[INFO] No cached image found. Downloading fresh copy..."
    wget -q -O "$IMG_FILE" "$IMG_URL"
fi

# --- Copy img file ---
cp "$IMG_FILE" "$RESIZED_IMG"

# --- Get HTTP header date ---
echo "[INFO] Fetching cloud image metadata"
DATE_HEADER=$(curl -sI "$IMG_URL" | grep -i '^last-modified:' | sed 's/Last-Modified: //I' | tr -d '\r' || true)
if [[ -z "$DATE_HEADER" ]]; then
    IMG_DATE="Unknown date"
else
    IMG_DATE=$(date -d "$DATE_HEADER" +%Y-%m-%d 2>/dev/null || echo "$DATE_HEADER")
fi
echo "Cloud image date: $IMG_DATE"

# --- Install qemu-guest-agent ---
echo "[INFO] Installing qemu-guest-agent into image..."
virt-customize -a "$RESIZED_IMG" --install qemu-guest-agent

# --- Resize image to 30G ---
echo "[INFO] Resizing image to 30G..."
qemu-img resize "$RESIZED_IMG" "${DISK_SIZE}"

# --- If VM already exists, remove it ---
if qm status "$VMID" &>/dev/null; then
    echo "[WARN] VM ${VMID} already exists. Removing old VM..."
    qm stop "$VMID" --skiplock 2>/dev/null || true
    qm destroy "$VMID" --purge 2>/dev/null || true
fi

# --- Create new VM ---
echo "[INFO] Creating new VM ${VMID}..."
qm create "$VMID" \
    --name "$VM_NAME" \
    --ostype l26 \
    --machine q35 \
    --bios ovmf \
    --efidisk0 "${STORAGE}:0,efitype=4m" \
    --agent enabled=1 \
    --onboot 1 \
    --memory "$MEMORY" \
    --cores "$CPUS" \
    --cpu host \
    --scsihw virtio-scsi-single \
    --tags template

# --- Import disk directly ---
echo "[INFO] Importing disk..."
qm importdisk "$VMID" "$RESIZED_IMG" "$STORAGE"

# --- Attach disk and add metadata ---
qm set "$VMID" \
    --scsi1 "${STORAGE}:vm-${VMID}-disk-1,iothread=1,discard=on,ssd=1" \
    --boot order=scsi1

qm set "$VMID" --description "$(cat <<EOF
Ubuntu 24.04 LTS Cloud Image built on: ${IMG_DATE}
Checksum (SHA256): ${REMOTE_SHA256}
EOF
)"

# --- Convert to template ---
echo "[INFO] Converting VM ${VMID} to template..."
qm template "$VMID"

echo "[DONE] Template '${VM_NAME}' (ID ${VMID}) ready!"
echo "       Build date: ${IMG_DATE}"
echo "       SHA256: ${REMOTE_SHA256}"
echo "       Cached at: ${IMG_FILE}"
