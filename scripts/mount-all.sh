#!/usr/bin/env bash
# =============================================================================
# drive-nmonit — Mount GlusterFS Distributed Volume
# =============================================================================
# Mounts the GlusterFS distributed volume on the local node.
# Run this on ALL nodes (host + slaves) after the volume is created.
#
# Usage: sudo ./scripts/mount-all.sh [--fuse] [--nfs]
#   --fuse   Mount via GlusterFS FUSE client (default, recommended)
#   --nfs    Mount via NFS (requires gluster-nfs or separate NFS server)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

require_root

# --- Configuration ---
VOLUME_NAME="workspace"
WORKSPACE_MOUNT="/mnt/workspace"
CONFIG_DIR="/etc/drive-nmonit"
PRIMARY_FILE="${CONFIG_DIR}/gluster-primary.txt"
FSTAB_OPTS="defaults,_netdev,noatime,direct-io-mode=disable,log-level=WARNING,fetch-attempts=10,use-readdirp=yes,backupvolfile-server=localhost"

# --- Determine mount type ---
MOUNT_TYPE="fuse"
for arg in "$@"; do
    case "$arg" in
        --nfs) MOUNT_TYPE="nfs" ;;
        --fuse) MOUNT_TYPE="fuse" ;;
    esac
done

# --- Get primary server address ---
PRIMARY_SERVER="localhost"
if [[ -f "$PRIMARY_FILE" ]]; then
    # This is a slave node — mount from the primary
    PRIMARY_SERVER=$(head -1 "$PRIMARY_FILE" | tr -d '[:space:]')
    log_info "This node is a slave. Connecting to primary: ${PRIMARY_SERVER}"
else
    log_info "This node appears to be the primary. Using localhost."
fi

log_info "=== drive-nmonit: Mounting Distributed Volume ==="
log_info "Volume:     ${VOLUME_NAME}"
log_info "Mount type: ${MOUNT_TYPE}"
log_info "Mount to:   ${WORKSPACE_MOUNT}"
log_info "Server:     ${PRIMARY_SERVER}"
log_info ""

# --- Create mount point ---
ensure_dir "$WORKSPACE_MOUNT"

# --- Check if already mounted ---
if mountpoint -q "$WORKSPACE_MOUNT" 2>/dev/null; then
    log_info "Volume already mounted at ${WORKSPACE_MOUNT}"
    df -h "$WORKSPACE_MOUNT"
    log_info ""
    log_ok "Already mounted!"
    exit 0
fi

# --- Mount via GlusterFS FUSE ---
if [[ "$MOUNT_TYPE" == "fuse" ]]; then
    if ! command_exists mount.glusterfs && ! command_exists glusterfs; then
        log_error "GlusterFS FUSE client not found (mount.glusterfs or glusterfs)"
        log_error "Run ./scripts/install-deps.sh"
        exit 1
    fi

    log_info "Mounting GlusterFS volume via FUSE..."

    MOUNT_CMD="mount -t glusterfs"
    if command_exists mount.glusterfs; then
        MOUNT_CMD="mount -t glusterfs"
    elif command_exists glusterfs; then
        MOUNT_CMD="glusterfs --log-level=WARNING"
    fi

    # Try mounting with the primary server as the volfile server
    if $MOUNT_CMD "${PRIMARY_SERVER}:/${VOLUME_NAME}" "$WORKSPACE_MOUNT" -o "$FSTAB_OPTS"; then
        log_ok "GlusterFS volume mounted at ${WORKSPACE_MOUNT}"
    else
        log_error "Failed to mount GlusterFS volume (FUSE)."
        log_error "Check:"
        log_error "  • Is glusterd running on the primary?  systemctl status glusterd"
        log_error "  • Is the volume created?               gluster volume info ${VOLUME_NAME}"
        log_error "  • Network connectivity to ${PRIMARY_SERVER}"
        exit 1
    fi
fi

# --- Mount via NFS ---
if [[ "$MOUNT_TYPE" == "nfs" ]]; then
    if ! command_exists mount.nfs; then
        log_error "NFS client (mount.nfs) not found."
        log_error "Install nfs-common or nfs-utils."
        exit 1
    fi

    # GlusterFS NFS mount: glusterfs-nfs server runs on port 2049
    # The NFS export path is typically: /<volume-name>
    log_info "Mounting GlusterFS volume via NFS..."

    if mount -t nfs -o "$FSTAB_OPTS" "${PRIMARY_SERVER}:/${VOLUME_NAME}" "$WORKSPACE_MOUNT"; then
        log_ok "GlusterFS volume mounted via NFS at ${WORKSPACE_MOUNT}"
    else
        log_error "Failed to mount via NFS."
        log_error "Check if gluster-nfs is available on the server."
        exit 1
    fi
fi

# --- Add to fstab ---
if ! grep -qs "${WORKSPACE_MOUNT}" /etc/fstab; then
    log_info "Adding fstab entry for persistence on boot..."
    FSTAB_LINE=""
    if [[ "$MOUNT_TYPE" == "fuse" ]]; then
        FSTAB_LINE="${PRIMARY_SERVER}:/${VOLUME_NAME} ${WORKSPACE_MOUNT} glusterfs ${FSTAB_OPTS} 0 0"
    else
        FSTAB_LINE="${PRIMARY_SERVER}:/${VOLUME_NAME} ${WORKSPACE_MOUNT} nfs ${FSTAB_OPTS} 0 0"
    fi
    echo "$FSTAB_LINE" >> /etc/fstab
    log_ok "fstab entry added for ${WORKSPACE_MOUNT}"
else
    log_info "fstab entry already exists for ${WORKSPACE_MOUNT}"
fi

# --- Create systemd mount unit (alternative to fstab) ---
log_info ""
log_info "=== Installing systemd mount unit ==="

# Convert mount path to systemd unit name: /mnt/workspace → mnt-workspace.mount
UNIT_NAME="$(echo "${WORKSPACE_MOUNT}" | sed 's/^\///' | sed 's/\//-/g').mount"

cat > "/etc/systemd/system/${UNIT_NAME}" << MOUNT_UNIT
[Unit]
Description=drive-nmonit GlusterFS Distributed Workspace
After=network.target glusterd.service
Wants=network.target glusterd.service
Requires=glusterd.service

[Mount]
What=${PRIMARY_SERVER}:/${VOLUME_NAME}
Where=${WORKSPACE_MOUNT}
Type=glusterfs
Options=${FSTAB_OPTS}

[Install]
WantedBy=multi-user.target
MOUNT_UNIT

systemctl daemon-reload
systemctl enable "${UNIT_NAME}" 2>/dev/null || true
log_ok "systemd mount unit installed: ${UNIT_NAME}"

# --- Summary ---
log_info ""
log_info "=== Mount Summary ==="
df -h "$WORKSPACE_MOUNT" | tail -1
log_info ""
log_info "Total unified storage available:"
df -h "$WORKSPACE_MOUNT" | awk 'NR==2{print "  " $2 " total, " $4 " available"}'
log_info ""
log_ok "Setup complete!"
log_info ""
log_info "Your unified network-distributed workspace is at:"
log_info "  ${WORKSPACE_MOUNT}"
log_info ""
log_info "All nodes in the cluster share this same directory."
log_info "Any file written by any node is visible to all others."
