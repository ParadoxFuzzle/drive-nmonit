#!/usr/bin/env bash
# =============================================================================
# drive-nmonit — Setup GlusterFS Distributed Volume
# =============================================================================
# Two modes:
#   --init   : Run on PRIMARY node. Probes slaves and creates the distributed volume.
#   --join   : Run on SLAVE nodes. Starts glusterd and waits for the primary.
#
# Usage:
#   Primary: sudo ./scripts/setup-glusterfs.sh --init
#   Slave:   sudo ./scripts/setup-glusterfs.sh --join <primary-ip-or-hostname>
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

require_root

# --- Configuration ---
POOL_MOUNT="/mnt/local-pool"
WORKSPACE_MOUNT="/mnt/workspace"
VOLUME_NAME="workspace"
CONFIG_DIR="/etc/drive-nmonit"
NODE_LIST_FILE="${CONFIG_DIR}/gluster-nodes.txt"

ensure_dir "$CONFIG_DIR"

# --- Validate arguments ---
MODE="${1:-}"
if [[ "$MODE" != "--init" ]] && [[ "$MODE" != "--join" ]]; then
    log_error "Usage:"
    log_error "  Primary: $0 --init"
    log_error "  Slave:   $0 --join <primary-ip>"
    exit 1
fi

# --- Check prerequisites ---
if ! command_exists glusterd; then
    log_error "GlusterFS server (glusterd) is not installed."
    log_error "Run ./scripts/install-deps.sh first."
    exit 1
fi

if ! command_exists gluster; then
    log_error "GlusterFS CLI (gluster) is not installed."
    exit 1
fi

# --- Ensure local pool exists ---
if ! mountpoint -q "$POOL_MOUNT" 2>/dev/null; then
    log_error "The mergerfs pool at ${POOL_MOUNT} is not mounted."
    log_error "Run ./scripts/setup-mergerfs.sh first."
    exit 1
fi

# --- Utility: wait for glusterd to be ready ---
wait_for_glusterd() {
    local retries=30
    local i=0
    while ! systemctl is-active --quiet glusterd 2>/dev/null; do
        sleep 1
        i=$((i + 1))
        if [[ $i -ge $retries ]]; then
            log_error "glusterd failed to start after ${retries}s"
            exit 1
        fi
    done
    # Extra wait for the socket to be ready
    sleep 2
}

# =============================================================================
# MODE: --join (Slave Node)
# =============================================================================
if [[ "$MODE" == "--join" ]]; then
    PRIMARY_IP="${2:-}"
    if [[ -z "$PRIMARY_IP" ]]; then
        log_error "Usage: $0 --join <primary-ip-or-hostname>"
        exit 1
    fi

    MY_IP=$(hostname -I | awk '{print $1}')

    log_info "=== drive-nmonit: Joining GlusterFS Cluster ==="
    log_info "Primary node: ${PRIMARY_IP}"
    log_info "My address:   ${MY_IP}"
    log_info ""

    # --- Start glusterd ---
    log_info "Starting glusterd service..."
    systemctl enable glusterd 2>/dev/null || true
    systemctl start glusterd || {
        log_error "Failed to start glusterd. Check: journalctl -u glusterd"
        exit 1
    }
    wait_for_glusterd
    log_ok "glusterd is running"

    # --- Store primary IP for later use ---
    echo "$PRIMARY_IP" > "${CONFIG_DIR}/gluster-primary.txt"
    log_ok "Primary IP recorded: ${PRIMARY_IP}"

    # --- Configure firewall (if ufw is active) ---
    if command_exists ufw && ufw status | grep -q active; then
        log_info "Configuring UFW for GlusterFS..."
        ufw allow 24007/tcp 2>/dev/null || true
        ufw allow 24008/tcp 2>/dev/null || true
        ufw allow 49152:49251/tcp 2>/dev/null || true
        log_ok "UFW rules added for GlusterFS"
    fi

    log_info ""
    log_info "Firewall rules (if applicable):"
    log_info "  Ensure these ports are open:"
    log_info "    TCP 24007      — GlusterFS daemon"
    log_info "    TCP 24008      — GlusterFS management"
    log_info "    TCP 49152-49251 — Brick ports"
    log_info ""

    # --- Verify connection to primary ---
    log_info "Testing connection to primary (${PRIMARY_IP})..."
    if ping -c 1 -W 3 "$PRIMARY_IP" &>/dev/null; then
        log_ok "Primary is reachable"
    else
        log_warn "Primary is not responding to ping (may still work)"
    fi

    log_ok "Slave node setup complete!"
    log_info ""
    log_info "The primary node will now probe and add this node."
    log_info "Once the primary has created the volume, run:"
    log_info "  sudo ./scripts/mount-all.sh"
    exit 0
fi

# =============================================================================
# MODE: --init (Primary Node)
# =============================================================================
log_info "=== drive-nmonit: Initializing GlusterFS Cluster ==="

# --- Collect slave node addresses ---
log_info ""
log_info "Enter the IP addresses or hostnames of slave nodes."
log_info "Enter one per line. Press Ctrl+D (or type 'done') when finished."
log_info ""

SLAVE_NODES=()
if [[ -f "$NODE_LIST_FILE" ]]; then
    log_info "Existing node list found at ${NODE_LIST_FILE}:"
    cat "$NODE_LIST_FILE"
    log_info ""
    read -r -p "Use existing node list? [Y/n]: " USE_EXISTING
    if [[ "${USE_EXISTING,,}" != "n" ]] && [[ "${USE_EXISTING,,}" != "no" ]]; then
        mapfile -t SLAVE_NODES < "$NODE_LIST_FILE"
    fi
fi

if [[ ${#SLAVE_NODES[@]} -eq 0 ]]; then
    log_info "Enter slave node addresses (empty line to finish):"
    while IFS= read -r line; do
        line="${line// /}"
        if [[ -z "$line" ]]; then
            break
        fi
        if [[ "$line" == "done" ]]; then
            break
        fi
        SLAVE_NODES+=("$line")
    done

    if [[ ${#SLAVE_NODES[@]} -gt 0 ]]; then
        printf "%s\n" "${SLAVE_NODES[@]}" > "$NODE_LIST_FILE"
        log_ok "Saved node list to ${NODE_LIST_FILE}"
    fi
fi

# --- Print topology ---
log_info ""
log_info "=== Cluster Topology ==="
log_info "Primary node: $(hostname) ($(hostname -I | awk '{print $1}'))"
log_info "Local brick:  ${POOL_MOUNT}"
if [[ ${#SLAVE_NODES[@]} -gt 0 ]]; then
    log_info "Slave nodes:"
    for node in "${SLAVE_NODES[@]}"; do
        echo "  • ${node}"
    done
else
    log_warn "No slave nodes configured. Creating a single-node volume."
fi

# --- Start glusterd ---
log_info ""
log_info "Starting glusterd service..."
systemctl enable glusterd 2>/dev/null || true
systemctl start glusterd || {
    log_error "Failed to start glusterd. Check: journalctl -u glusterd"
    exit 1
}
wait_for_glusterd
log_ok "glusterd is running"

# --- Configure firewall ---
if command_exists ufw && ufw status | grep -q active; then
    log_info "Configuring UFW for GlusterFS..."
    ufw allow 24007/tcp 2>/dev/null || true
    ufw allow 24008/tcp 2>/dev/null || true
    ufw allow 49152:49251/tcp 2>/dev/null || true
    log_ok "UFW rules added for GlusterFS"
fi

# --- Probe slave nodes ---
if [[ ${#SLAVE_NODES[@]} -gt 0 ]]; then
    log_info ""
    log_info "=== Probing Slave Nodes ==="
    for node in "${SLAVE_NODES[@]}"; do
        log_info "Probing ${node}..."
        if gluster peer probe "$node"; then
            log_ok "→ ${node} added to cluster"
        else
            log_warn "→ ${node} probe failed (may already be in cluster or unreachable)"
        fi
    done
fi

# --- Wait for peers ---
log_info ""
log_info "Waiting for peer connections..."
sleep 3
gluster pool list
log_info ""

# --- Create the GlusterFS volume ---
log_info "=== Creating GlusterFS Volume ==="

# Build brick list
BRICKS="${HOSTNAME}:${POOL_MOUNT}"

for node in "${SLAVE_NODES[@]}"; do
    # Check if this node is actually a peer now
    if gluster pool list 2>/dev/null | grep -q "${node}"; then
        BRICKS+=" ${node}:${POOL_MOUNT}"
    else
        log_warn "Skipping ${node} — not a peer yet"
    fi
done

# Check if volume already exists
if gluster volume info "$VOLUME_NAME" &>/dev/null; then
    log_warn "Volume '${VOLUME_NAME}' already exists."
    gluster volume info "$VOLUME_NAME"
    log_info ""
    read -r -p "Delete and recreate? [y/N]: " RECREATE
    if [[ "${RECREATE,,}" == "y" ]]; then
        gluster volume stop "$VOLUME_NAME" --mode=script 2>/dev/null || true
        gluster volume delete "$VOLUME_NAME" --mode=script 2>/dev/null || true
    else
        log_info "Keeping existing volume."
        log_info ""
        gluster volume info "$VOLUME_NAME"
        log_info ""
        log_info "Run ./scripts/mount-all.sh to mount the volume."
        exit 0
    fi
fi

# Create the volume
log_info "Creating distributed volume '${VOLUME_NAME}'..."
log_info "Bricks: ${BRICKS}"
log_info ""

if gluster volume create "$VOLUME_NAME" transport tcp $BRICKS force; then
    log_ok "Volume '${VOLUME_NAME}' created"
else
    log_error "Failed to create volume. Check peer connectivity and brick paths."
    log_info "Debug:"
    gluster peer status 2>&1 || true
    exit 1
fi

# Start the volume
log_info "Starting volume '${VOLUME_NAME}'..."
if gluster volume start "$VOLUME_NAME"; then
    log_ok "Volume '${VOLUME_NAME}' started"
else
    log_error "Failed to start volume"
    exit 1
fi

# --- Display volume info ---
log_info ""
log_info "=== Volume Information ==="
gluster volume info "$VOLUME_NAME"
log_info ""

# --- Apply performance tuning profile ---
log_info ""
log_info "=== Performance Tuning ==="
log_info ""
log_info "Select a tuning profile for this volume:"
log_info "  balanced   — Good all-around performance for mixed workloads (recommended)"
log_info "  throughput — Optimized for large sequential reads/writes (media, backups)"
log_info "  metadata   — Optimized for many small files and directory operations"
log_info "  capacity   — Minimizes memory use for low-RAM or archival nodes"
log_info "  skip       — Skip tuning now (tune later with: sudo ./scripts/tune-glusterfs.sh workspace)"
log_info ""
read -r -p "Select profile [balanced]: " TUNE_PROFILE
TUNE_PROFILE="${TUNE_PROFILE:-balanced}"

if [[ "$TUNE_PROFILE" != "skip" ]]; then
    TUNE_SCRIPT="${SCRIPT_DIR}/tune-glusterfs.sh"
    if [[ -x "$TUNE_SCRIPT" ]]; then
        # Run in non-interactive mode for the sysctl prompt — skip it here
        if bash "$TUNE_SCRIPT" "$VOLUME_NAME" "$TUNE_PROFILE" --no-sysctl; then
            log_ok "Performance profile '${TUNE_PROFILE}' applied"
        else
            log_warn "Tuning script had issues; volume is usable without tuning"
        fi
    else
        log_warn "Tuning script not found at ${TUNE_SCRIPT}"
        log_warn "Run manually later: sudo ./scripts/tune-glusterfs.sh ${VOLUME_NAME} ${TUNE_PROFILE}"
    fi
else
    log_info "Skipping performance tuning. Run later:"
    log_info "  sudo ./scripts/tune-glusterfs.sh ${VOLUME_NAME} balanced"
fi

# --- Summary ---
log_info ""
log_info "=== GlusterFS Cluster Summary ==="
log_info "Primary node: $(hostname)"
log_info "Volume name:  ${VOLUME_NAME}"
log_info "Mount point:  ${WORKSPACE_MOUNT}"
log_info "Local pool:   ${POOL_MOUNT}"
log_info ""
log_info "Cluster peers:"
gluster pool list | tail -n +2 | while IFS= read -r line; do
    echo "  • ${line}"
done
log_info ""
log_ok "GlusterFS cluster initialized!"
log_info ""
log_info "Next steps:"
log_info "  • On ALL nodes, run: sudo ./scripts/mount-all.sh"
log_info "  • The unified workspace will be at: ${WORKSPACE_MOUNT}"
log_info ""
log_info "Adding more nodes later:"
log_info "  1. On slave: sudo ./scripts/setup-glusterfs.sh --join <primary-ip>"
log_info "  2. On primary: gluster peer probe <new-node-ip>"
log_info "  3. On primary: gluster volume add-brick workspace <new-node-ip>:${POOL_MOUNT}"
log_info "  4. On new node: sudo ./scripts/mount-all.sh"
