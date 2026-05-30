#!/usr/bin/env bash
# =============================================================================
# drive-nmonit — Setup MergerFS Local Drive Pooling
# =============================================================================
# Detects all non-system block devices, mounts them under /mnt/drives/,
# and creates a mergerfs pool at /mnt/local-pool that unifies them.
#
# Run this on EVERY node (host + slaves).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

require_root

# --- Configuration ---
DRIVES_BASE="/mnt/drives"
POOL_MOUNT="/mnt/local-pool"
CONFIG_DIR="/etc/drive-nmonit"
EXCLUDE_FILE="${CONFIG_DIR}/excluded-drives"
MARKER_FILE="${CONFIG_DIR}/managed-drives.txt"
MERGERFS_OPTIONS="defaults,allow_other,category.create=mfs,minfreespace=1G,fsname=drive-nmonit-pool"

# --- Create required directories ---
ensure_dir "$DRIVES_BASE"
ensure_dir "$POOL_MOUNT"
ensure_dir "$CONFIG_DIR"
touch "$EXCLUDE_FILE" "$MARKER_FILE"

log_info "=== drive-nmonit: Local Drive Pooling ==="
log_info "Drives mount base: ${DRIVES_BASE}"
log_info "Pool mount point:  ${POOL_MOUNT}"
log_info ""

# --- Detect eligible drives ---
log_info "Scanning for eligible block devices..."
DRIVES_JSON=$(detect_drives)

# Parse drive count using jq (required dependency, installed by install-deps.sh)
if ! command_exists jq; then
    log_error "jq is required but not installed. Run ./scripts/install-deps.sh first."
    exit 1
fi
DRIVE_COUNT=$(echo "$DRIVES_JSON" | jq length)

if [[ "$DRIVE_COUNT" -eq 0 ]]; then
    log_warn "No eligible drives detected!"
    log_info "This means:"
    log_info "  - All non-system drives are already managed"
    log_info "  - Or no drives beyond the system disk were found"
    log_info ""
    log_info "The mergerfs pool will still be created (empty pool is valid)."
fi

# --- Process each drive ---
MANAGED_DRIVES=()
DRIVE_SOURCES=()

for i in $(seq 0 $((DRIVE_COUNT - 1))); do
    DEV=$(echo "$DRIVES_JSON" | jq -r ".[${i}].device")
    FSTYPE=$(echo "$DRIVES_JSON" | jq -r ".[${i}].fstype")
    LABEL=$(echo "$DRIVES_JSON" | jq -r ".[${i}].label")
    UUID=$(echo "$DRIVES_JSON" | jq -r ".[${i}].uuid")
    SIZE=$(echo "$DRIVES_JSON" | jq -r ".[${i}].size")

    log_info "Found drive: ${DEV} (${SIZE}) [${FSTYPE}] label='${LABEL}' uuid='${UUID:0:12}...'"

    # --- Check exclusion list ---
    if grep -qs "${UUID}" "$EXCLUDE_FILE" 2>/dev/null; then
        log_warn "  → Skipping (excluded in ${EXCLUDE_FILE})"
        continue
    fi

    # --- Check if already managed ---
    if grep -qs "${DEV}" "$MARKER_FILE" 2>/dev/null; then
        log_info "  → Already managed by this script"
        DRIVE_SOURCES+=("$DEV")
        continue
    fi

    # --- Create mount point ---
    MOUNT_NAME=$(get_mount_name "$LABEL" "$UUID" "$DEV")
    MOUNT_POINT="${DRIVES_BASE}/${MOUNT_NAME}"
    ensure_dir "$MOUNT_POINT"

    # --- Check if already mounted ---
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        log_info "  → Already mounted at ${MOUNT_POINT}"
    else
        # --- Mount the drive ---
        log_info "  → Mounting at ${MOUNT_POINT}..."

        # Determine mount options based on filesystem
        MOUNT_OPTS="defaults,nofail,noatime"
        if [[ "$FSTYPE" == "ntfs" ]] || [[ "$FSTYPE" == "ntfs3" ]]; then
            MOUNT_OPTS="${MOUNT_OPTS},uid=0,gid=0,umask=000,big_writes"
        elif [[ "$FSTYPE" == "vfat" ]]; then
            MOUNT_OPTS="${MOUNT_OPTS},uid=0,gid=0,umask=000"
        fi

        if ! mount -t "$FSTYPE" -o "$MOUNT_OPTS" "$DEV" "$MOUNT_POINT"; then
            log_error "  → Failed to mount ${DEV} at ${MOUNT_POINT}"
            continue
        fi
        log_ok "  → Mounted ${DEV} at ${MOUNT_POINT}"
    fi

    # --- Add to fstab (skip if already present) ---
    if ! grep -qs "${MOUNT_POINT}" /etc/fstab; then
        FSTAB_SPEC="UUID=${UUID}"
        FSTAB_OPTS="defaults,nofail,noatime"
        if [[ "$FSTYPE" == "ntfs" ]]; then
            FSTAB_OPTS="${FSTAB_OPTS},uid=0,gid=0,umask=000"
        elif [[ "$FSTYPE" == "vfat" ]]; then
            FSTAB_OPTS="${FSTAB_OPTS},uid=0,gid=0,umask=000"
        fi
        echo "${FSTAB_SPEC} ${MOUNT_POINT} ${FSTYPE} ${FSTAB_OPTS} 0 2" >> /etc/fstab
        log_ok "  → Added fstab entry for ${MOUNT_POINT}"
    fi

    # --- Record as managed ---
    echo "${DEV}" >> "$MARKER_FILE"
    MANAGED_DRIVES+=("$DEV")
    DRIVE_SOURCES+=("$MOUNT_POINT")
    log_ok "  → Registered in managed drives list"
done

# --- Build mergerfs pool ---
log_info ""
log_info "=== Configuring mergerfs pool ==="

# Gather all mounted drive directories
POOL_SOURCES=()
for dir in "${DRIVES_BASE}"/*/; do
    if mountpoint -q "$dir" 2>/dev/null; then
        POOL_SOURCES+=("$dir")
    fi
done

if [[ ${#POOL_SOURCES[@]} -eq 0 ]]; then
    log_warn "No drive mount points found for pooling"
    log_warn "Creating an empty mergerfs pool (add drives later with: mergerfs -o ${MERGERFS_OPTIONS} ${POOL_MOUNT})"
    POOL_SOURCES+=("${DRIVES_BASE}/.empty")
    ensure_dir "${DRIVES_BASE}/.empty"
fi

# Build mergerfs source string (colon-separated paths)
MERGED_SOURCES=""
for src in "${POOL_SOURCES[@]}"; do
    if [[ -n "$MERGED_SOURCES" ]]; then
        MERGED_SOURCES+=":"
    fi
    MERGED_SOURCES+="${src}"
done

log_info "Pool sources: ${MERGED_SOURCES}"

# --- Mount mergerfs pool ---
log_info "Mounting mergerfs pool at ${POOL_MOUNT}..."

# Check if already mounted
if mountpoint -q "$POOL_MOUNT" 2>/dev/null; then
    log_info "mergerfs pool already mounted. Updating..."
    umount "$POOL_MOUNT" 2>/dev/null || true
fi

if command_exists mergerfs; then
    mergerfs -o "$MERGERFS_OPTIONS" "$MERGED_SOURCES" "$POOL_MOUNT"
    log_ok "mergerfs pool mounted at ${POOL_MOUNT}"
else
    log_error "mergerfs command not found! Install mergerfs and try again."
    exit 1
fi

# --- Create/update systemd service ---
log_info ""
log_info "=== Installing systemd service ==="

SYSTEMD_SERVICE_DIR="/etc/systemd/system"

# Generate the systemd service file
cat > "${SYSTEMD_SERVICE_DIR}/mergerfs-pool.service" << SERVICE
[Unit]
Description=drive-nmonit mergerfs Local Drive Pool
After=local-fs.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$(command -v mergerfs) -o ${MERGERFS_OPTIONS} ${MERGED_SOURCES} ${POOL_MOUNT}
ExecStop=/bin/umount -l ${POOL_MOUNT}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable mergerfs-pool.service
log_ok "mergerfs-pool.service installed and enabled"

# --- Summary ---
log_info ""
log_info "=== Pool Summary ==="
df -h "$POOL_MOUNT" | tail -1
log_info ""
log_info "Pool sources:"
for src in "${POOL_SOURCES[@]}"; do
    echo "  • ${src}"
done
log_info ""
log_info "Total capacity:"
df -h "$POOL_MOUNT" | awk 'NR==2{print $2}'
log_info ""
log_ok "Local drive pooling setup complete!"
log_info ""
log_info "Next step:"
log_info "  • Primary node: sudo ./scripts/setup-glusterfs.sh --init"
log_info "  • Slave nodes:  sudo ./scripts/setup-glusterfs.sh --join <primary-ip>"
