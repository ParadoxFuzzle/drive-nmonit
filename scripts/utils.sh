#!/usr/bin/env bash
# =============================================================================
# drive-nmonit — Shared Utility Functions
# =============================================================================
set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Logging ---
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Run as root check ---
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)."
        exit 1
    fi
}

# --- Get the system root device ---
# Returns the underlying device for the root filesystem (e.g., /dev/sda, /dev/nvme0n1)
get_system_device() {
    local root_dev
    root_dev=$(findmnt -n -o SOURCE / | sed 's/\[.*\]//' | sed 's/[0-9]*$//' | sed 's/p$//')
    if [[ -z "$root_dev" ]]; then
        root_dev=$(df / | awk 'NR==2{print $1}' | sed 's/[0-9]*$//' | sed 's/p$//')
    fi
    echo "$root_dev"
}

# --- Detect eligible block devices ---
# Finds all non-system, non-swap block devices that have filesystems.
# Outputs JSON array: [{"device":"/dev/sdb1","fstype":"ext4","label":"MyDrive","uuid":"...","size":"..."}]
detect_drives() {
    local exclude_dev
    exclude_dev=$(get_system_device)

    # Also exclude the boot/EFI partition and swap
    local exclude_partitions
    exclude_partitions=$(awk '$3 ~ /swap|vfat/ {print $1}' /proc/swaps /proc/mounts 2>/dev/null | sort -u)

    local drives_json="["
    local first=true

    while IFS= read -r -d '' dev; do
        local short_name
        short_name=$(basename "$dev")

        # Skip if it's the system device parent or a partition of it
        local parent_dev
        parent_dev=$(echo "$dev" | sed 's/[0-9]*$//' | sed 's/p$//')
        if [[ "$parent_dev" == "$exclude_dev" ]]; then
            continue
        fi

        # Skip if it's a swap or EFI partition
        if echo "$exclude_partitions" | grep -q "${dev}"; then
            continue
        fi

        # Skip if no filesystem detected
        local fstype
        fstype=$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)
        if [[ -z "$fstype" ]]; then
            continue
        fi

        # Skip LVM or other special devices
        if [[ "$fstype" == "LVM2_member" ]] || [[ "$fstype" == "crypto_LUKS" ]]; then
            continue
        fi

        local label uuid size
        label=$(blkid -o value -s LABEL "$dev" 2>/dev/null || echo "untitled")
        uuid=$(blkid -o value -s UUID "$dev" 2>/dev/null || echo "unknown")
        size=$(lsblk -dn -o SIZE "$dev" 2>/dev/null || echo "?")

        if [[ "$first" == true ]]; then
            first=false
        else
            drives_json+=","
        fi

        drives_json+="{\"device\":\"$dev\",\"fstype\":\"$fstype\",\"label\":\"$label\",\"uuid\":\"$uuid\",\"size\":\"$size\"}"
    done < <({ find /dev -regex '/dev/(sd|nvme|mmcblk|vd|hd)[a-z0-9]+' -print0; find /dev -regex '/dev/dm-[0-9]+' -print0; } 2>/dev/null | sort -z)

    drives_json+="]"
    echo "$drives_json"
}

# --- Get mount point name from device info ---
get_mount_name() {
    local label="$1"
    local uuid="$2"
    local dev="$3"

    if [[ "$label" != "untitled" ]] && [[ -n "$label" ]]; then
        # Sanitize label for use as a directory name
        echo "$label" | sed 's/[^a-zA-Z0-9._-]/_/g'
    else
        echo "disk-${uuid:0:8}"
    fi
}

# --- Check if a command exists ---
command_exists() {
    command -v "$1" &>/dev/null
}

# --- Ensure a directory exists ---
ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        log_ok "Created directory: $dir"
    fi
}

# --- Add fstab entry if not present ---
add_fstab_entry() {
    local spec="$1"
    local mount_point="$2"
    local fstype="$3"
    local options="$4"
    local dump="${5:-0}"
    local pass="${6:-2}"

    if grep -qs "${mount_point}" /etc/fstab; then
        log_warn "fstab entry for ${mount_point} already exists"
        return 0
    fi

    echo "${spec} ${mount_point} ${fstype} ${options} ${dump} ${pass}" >> /etc/fstab
    log_ok "Added fstab entry: ${spec} → ${mount_point}"
}
