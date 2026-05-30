#!/usr/bin/env bash
# =============================================================================
# drive-nmonit — Setup NFS Export
# =============================================================================
# Exports /mnt/workspace (or a custom path) via NFS to the network.
# Supports multiple export options, access control, and concurrent export setup.
#
# Usage:
#   sudo ./scripts/setup-nfs.sh                      # Interactive setup
#   sudo ./scripts/setup-nfs.sh --ro                  # Read-only export
#   sudo ./scripts/setup-nfs.sh --rw                  # Read-write export (default)
#   sudo ./scripts/setup-nfs.sh --clients 10.0.0.0/24 # CIDR for client access
#   sudo ./scripts/setup-nfs.sh --clients 10.0.0.1    # Single client IP
#   sudo ./scripts/setup-nfs.sh --clients @all        # All clients (*)
#   sudo ./scripts/setup-nfs.sh --path /mnt/data      # Export a custom path
#   sudo ./scripts/setup-nfs.sh --no-fs-cache         # Disable FS cache (sync, no_subtree_check)
#   sudo ./scripts/setup-nfs.sh --remove              # Remove the export
#   sudo ./scripts/setup-nfs.sh --dry-run             # Show what would be done
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# --- Configuration ---
EXPORT_PATH="/mnt/workspace"
EXPORT_NAME="workspace"
CONFIG_DIR="/etc/drive-nmonit"
EXPORTS_FILE="/etc/exports"
EXPORTS_BACKUP="${CONFIG_DIR}/exports.backup"
NFS_CONF_DIR="/etc/nfs.conf.d"

# --- Argument defaults ---
ACCESS_MODE="rw"        # rw, ro
CLIENT_SPEC=""
DRY_RUN=false
REMOVE=false
NO_FS_CACHE=false
ALLOW_INSECURE=false
SQUASH="root_squash"
NFS_VERSION="4.2"

# --- Parse arguments ---
NEXT_IS_CLIENTS=false
NEXT_IS_PATH=false

for arg in "$@"; do
    if [[ "$NEXT_IS_CLIENTS" == true ]]; then
        CLIENT_SPEC="$arg"
        NEXT_IS_CLIENTS=false
        continue
    fi
    if [[ "$NEXT_IS_PATH" == true ]]; then
        EXPORT_PATH="$arg"
        NEXT_IS_PATH=false
        continue
    fi

    case "$arg" in
        --ro)               ACCESS_MODE="ro" ;;
        --rw)               ACCESS_MODE="rw" ;;
        --remove)           REMOVE=true ;;
        --dry-run)          DRY_RUN=true ;;
        --no-fs-cache)      NO_FS_CACHE=true ;;
        --insecure)         ALLOW_INSECURE=true ;;
        --clients=*)        CLIENT_SPEC="${arg#*=}" ;;
        --clients)          NEXT_IS_CLIENTS=true ;;
        --path=*)           EXPORT_PATH="${arg#*=}" ;;
        --path)             NEXT_IS_PATH=true ;;
        -h|--help)
            cat << USAGE
Usage: $0 [OPTIONS]

Options:
  --ro              Export read-only
  --rw              Export read-write (default)
  --clients CIDR    Client access range (e.g. 10.0.0.0/24, 192.168.1.0/24)
                    Use @all for all clients (*)
                    Default: same subnet as primary interface
  --path DIR        Export a different path instead of /mnt/workspace
  --no-fs-cache     Disable filesystem caching (sync, no_subtree_check)
  --insecure        Allow NFS clients from ports above 1024
  --remove          Remove the export from /etc/exports
  --dry-run         Show what would be done without making changes
  -h, --help        Show this help

Examples:
  sudo $0                                          # Interactive, default settings
  sudo $0 --rw --clients 10.0.0.0/24               # Read-write for subnet
  sudo $0 --ro --clients 10.0.0.1                  # Read-only for single client
  sudo $0 --clients @all --no-fs-cache              # All clients, safe mode
  sudo $0 --path /mnt/data --rw                     # Custom path read-write
  sudo $0 --remove                                  # Remove the export
USAGE
            exit 0
            ;;
        *)
            log_error "Unknown option: $arg"
            echo "Usage: $0 [--ro|--rw] [--clients CIDR|@all] [--path DIR] [--remove] [--dry-run]"
            exit 1
            ;;
    esac
done

# =============================================================================
# Helpers
# =============================================================================

restart_nfs_services() {
    if systemctl is-active --quiet nfs-server 2>/dev/null; then
        systemctl reload nfs-server 2>/dev/null || systemctl restart nfs-server || true
        log_ok "nfs-server reloaded"
    elif systemctl is-active --quiet nfs-kernel-server 2>/dev/null; then
        systemctl reload nfs-kernel-server 2>/dev/null || systemctl restart nfs-kernel-server || true
        log_ok "nfs-kernel-server reloaded"
    elif systemctl is-active --quiet nfsd 2>/dev/null; then
        systemctl reload nfsd 2>/dev/null || systemctl restart nfsd || true
        log_ok "nfsd reloaded"
    fi

    # Also ensure rpcbind and nfs-mountd are running
    systemctl enable --now rpcbind 2>/dev/null || true
    systemctl enable --now nfs-mountd 2>/dev/null || true
}

detect_subnet() {
    local iface
    iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
    if [[ -n "$iface" ]]; then
        ip -o -f inet addr show "$iface" 2>/dev/null | awk '{print $4}' || echo ""
    fi
}

remove_export_line() {
    local path="$1"
    local file="$2"

    # Remove lines that start with the export path (with optional leading whitespace)
    # We use a marker approach: comment out matching lines, then uncomment ones that
    # are from other exports.
    local tmpfile
    tmpfile=$(mktemp /tmp/drive-nmonit-exports-XXXXXX)

    awk -v path="$path" '
        /^[[:space:]]*#/ { print; next }
        # Check if this line starts with the export path (possibly with leading whitespace)
        {
            # If line matches "^<whitespace>><path><whitespace or end>"
            if ($1 == path) {
                print "# REMOVED by drive-nmonit: " $0
            } else {
                print
            }
        }
    ' "$file" > "$tmpfile"

    mv "$tmpfile" "$file"
    chmod 644 "$file" 2>/dev/null || true
}

# =============================================================================
# Prerequisites
# =============================================================================

require_root

# --- Check path exists ---
if [[ "$REMOVE" != true ]]; then
    # For remove mode, path can be gone already
    if [[ ! -d "$EXPORT_PATH" ]]; then
        log_warn "Export path '${EXPORT_PATH}' does not exist yet."
        if [[ "$DRY_RUN" == false ]]; then
            read -r -p "Create directory '${EXPORT_PATH}'? [Y/n]: " CREATE_DIR
            if [[ "${CREATE_DIR,,}" != "n" ]] && [[ "${CREATE_DIR,,}" != "no" ]]; then
                mkdir -p "$EXPORT_PATH"
                log_ok "Created ${EXPORT_PATH}"
            else
                log_error "Export path must exist. Aborting."
                exit 1
            fi
        fi
    fi
fi

# =============================================================================
# Remove mode
# =============================================================================

if [[ "$REMOVE" == true ]]; then
    log_info "=== Removing NFS export for ${EXPORT_PATH} ==="

    if [[ ! -f "$EXPORTS_FILE" ]]; then
        log_warn "Exports file not found at ${EXPORTS_FILE} — nothing to remove"
        exit 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would remove export entries for ${EXPORT_PATH} from ${EXPORTS_FILE}"
        exit 0
    fi

    # Backup
    cp "$EXPORTS_FILE" "${EXPORTS_FILE}.bak.$(date +%s)" 2>/dev/null || true
    log_ok "Backup saved"

    # Remove lines referencing the export path
    remove_export_line "$EXPORT_PATH" "$EXPORTS_FILE"

    # Clean up any blank lines left behind
    sed -i '/^[[:space:]]*$/d' "$EXPORTS_FILE" 2>/dev/null || true

    log_ok "Export entries removed from ${EXPORTS_FILE}"

    # Re-export
    if command_exists exportfs; then
        exportfs -ra 2>/dev/null || true
        log_ok "NFS exports reloaded (exportfs -ra)"
    fi

    restart_nfs_services
    log_ok "NFS export removed"
    exit 0
fi

# =============================================================================
# Install NFS server if not present
# =============================================================================

if ! command_exists exportfs && ! command_exists nfsstat; then
    log_info "NFS server not found — installing..."

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would install nfs-kernel-server or nfs-utils"
    else
        if command_exists apt-get; then
            apt-get update -y >/dev/null 2>&1 || true
            apt-get install -y nfs-kernel-server 2>/dev/null || {
                log_error "Failed to install nfs-kernel-server. Try: apt-get install nfs-kernel-server"
                exit 1
            }
        elif command_exists dnf; then
            dnf install -y nfs-utils 2>/dev/null || {
                log_error "Failed to install nfs-utils. Try: dnf install nfs-utils"
                exit 1
            }
        elif command_exists yum; then
            yum install -y nfs-utils 2>/dev/null || {
                log_error "Failed to install nfs-utils. Try: yum install nfs-utils"
                exit 1
            }
        elif command_exists zypper; then
            zypper install -y nfs-kernel-server 2>/dev/null || {
                log_error "Failed to install NFS. Try: zypper install nfs-kernel-server"
                exit 1
            }
        else
            log_error "No supported package manager found. Install NFS server manually."
            exit 1
        fi
        log_ok "NFS server installed"
    fi
fi

# =============================================================================
# Determine client access specification
# =============================================================================

if [[ -z "$CLIENT_SPEC" ]]; then
    # Try to auto-detect the local subnet
    local_subnet=$(detect_subnet)
    if [[ -n "$local_subnet" ]]; then
        log_info "Detected local subnet: ${local_subnet}"
        read -r -p "Allow clients from this subnet? [Y/n]: " USE_SUBNET
        if [[ "${USE_SUBNET,,}" != "n" ]] && [[ "${USE_SUBNET,,}" != "no" ]]; then
            CLIENT_SPEC="$local_subnet"
        fi
    fi

    if [[ -z "$CLIENT_SPEC" ]]; then
        read -r -p "Client access specification (e.g. 10.0.0.0/24, or @all): " CLIENT_SPEC
        CLIENT_SPEC="${CLIENT_SPEC:-@all}"
    fi
fi

# Normalize @all to *
if [[ "$CLIENT_SPEC" == "@all" ]] || [[ "$CLIENT_SPEC" == "all" ]]; then
    CLIENT_SPEC="*"
fi

log_info "Client access: ${CLIENT_SPEC}"

# =============================================================================
# Build export options
# =============================================================================

# Basic export options
EXPORT_OPTS="${ACCESS_MODE}"

# Security flags
if [[ "$ALLOW_INSECURE" == true ]]; then
    EXPORT_OPTS+=",insecure"
fi

# Squash configuration
EXPORT_OPTS+=",${SQUASH}"

# Sync/async and subtree
if [[ "$NO_FS_CACHE" == true ]]; then
    EXPORT_OPTS+=",sync,no_subtree_check"
else
    EXPORT_OPTS+=",async,subtree_check"
fi

# Crossmnt — allow traversal to sub-mounts (important for mergerfs + GlusterFS layers)
EXPORT_OPTS+=",crossmnt"

# NFS version advertisement
EXPORT_OPTS+=",fsid=0"

# Build the export line
EXPORT_LINE="${EXPORT_PATH} ${CLIENT_SPEC}(${EXPORT_OPTS})"

# Show export line
log_info ""
log_info "=== NFS Export Configuration ==="
echo "  ${EXPORT_LINE}" 
log_info ""

# =============================================================================
# Apply configuration
# =============================================================================

if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] Would add the following to ${EXPORTS_FILE}:"
    echo ""
    echo "  ${EXPORT_LINE}"
    log_info ""
    log_info "[DRY-RUN] Would run: exportfs -ra"
    exit 0
fi

# Create config directory
ensure_dir "$CONFIG_DIR"

# Backup existing exports
if [[ -f "$EXPORTS_FILE" ]]; then
    cp "$EXPORTS_FILE" "${EXPORTS_FILE}.bak.$(date +%s)" 2>/dev/null || true
fi

# Check for existing export of this path
if grep -q "^${EXPORT_PATH}[[:space:]]" "$EXPORTS_FILE" 2>/dev/null; then
    log_warn "Export for '${EXPORT_PATH}' already exists in ${EXPORTS_FILE}"
    log_info "Existing entry:"
    grep "^${EXPORT_PATH}[[:space:]]" "$EXPORTS_FILE"
    log_info ""

    read -r -p "Replace existing export? [y/N]: " REPLACE
    if [[ "${REPLACE,,}" == "y" ]]; then
        remove_export_line "$EXPORT_PATH" "$EXPORTS_FILE"
        # Add a blank line if file isn't empty
        if [[ -s "$EXPORTS_FILE" ]]; then
            echo "" >> "$EXPORTS_FILE"
        fi
        echo "$EXPORT_LINE" >> "$EXPORTS_FILE"
        log_ok "Export updated in ${EXPORTS_FILE}"
    else
        log_info "Keeping existing export configuration."
    fi
else
    echo "$EXPORT_LINE" >> "$EXPORTS_FILE"
    log_ok "Export added to ${EXPORTS_FILE}"
fi

# =============================================================================
# Enable NFSv4.2 with optional configuration
# =============================================================================

# Create NFS config drop-in for performance tuning
ensure_dir "$NFS_CONF_DIR"

if [[ ! -f "${NFS_CONF_DIR}/drive-nmonit.conf" ]]; then
    cat > "${NFS_CONF_DIR}/drive-nmonit.conf" << 'NFSD'
# drive-nmonit NFS server tuning
# Installed by setup-nfs.sh — remove this file to reset to defaults

[nfsd]
# Thread count: set to 2× CPU cores for balanced throughput
threads=16

# Maximum number of concurrent connections
max_connections=256

# NFS version support (minimal set for compatibility + performance)
vers3=no
vers4=yes
vers4.0=yes
vers4.1=yes
vers4.2=yes

# Grace period for NFSv4 lease (seconds)
lease-grace-time=90

# Write delay (centiseconds) — 0 for maximum performance
write-delay=0
NFSD
    log_ok "NFS server tuning configuration created in ${NFS_CONF_DIR}/drive-nmonit.conf"
fi

# =============================================================================
# Firewall
# =============================================================================

log_info ""
log_info "=== Firewall Configuration ==="

# NFS relies on several ports:
#   TCP/UDP 111  — rpcbind / portmapper
#   TCP/UDP 2049 — NFS (kernel nfsd)
#   Various for rpc.mountd, rpc.lockd, rpc.statd (often dynamic)

if command_exists ufw && ufw status | grep -q active; then
    ufw allow 111/tcp 2>/dev/null || true
    ufw allow 111/udp 2>/dev/null || true
    ufw allow 2049/tcp 2>/dev/null || true
    ufw allow 2049/udp 2>/dev/null || true
    log_ok "UFW rules added for NFS (111, 2049)"
elif command_exists firewall-cmd; then
    firewall-cmd --permanent --add-service=nfs 2>/dev/null || true
    firewall-cmd --permanent --add-service=rpc-bind 2>/dev/null || true
    firewall-cmd --permanent --add-service=mountd 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    log_ok "firewalld rules added for NFS"
fi

log_info ""
log_info "If you have a custom firewall, ensure these ports are open:"
log_info "  TCP/UDP 111   — rpcbind / portmapper"
log_info "  TCP/UDP 2049  — NFS (nfsd)"

# =============================================================================
# Start NFS services
# =============================================================================

log_info ""
log_info "=== Starting NFS Services ==="

# Enable and start rpcbind
systemctl enable --now rpcbind 2>/dev/null || log_warn "Could not enable rpcbind"

# Enable and start the appropriate NFS service
if systemctl list-units --type=service 2>/dev/null | grep -q nfs-server; then
    systemctl enable --now nfs-server 2>/dev/null || {
        log_error "Failed to start nfs-server. Check: journalctl -u nfs-server"
        exit 1
    }
    log_ok "nfs-server started and enabled"
elif systemctl list-units --type=service 2>/dev/null | grep -q nfs-kernel-server; then
    systemctl enable --now nfs-kernel-server 2>/dev/null || {
        log_error "Failed to start nfs-kernel-server. Check: journalctl -u nfs-kernel-server"
        exit 1
    }
    log_ok "nfs-kernel-server started and enabled"
fi

# Enable nfs-mountd and nfs-idmapd
systemctl enable --now nfs-mountd 2>/dev/null || true
systemctl enable --now nfs-idmapd 2>/dev/null || true

# Apply exports
if command_exists exportfs; then
    exportfs -ra 2>/dev/null || {
        log_warn "exportfs -ra failed. Check: exportfs -v"
    }
    log_ok "NFS exports applied"
fi

# =============================================================================
# Set filesystem permissions
# =============================================================================

# Ensure the export path is at least readable
if [[ "$ACCESS_MODE" == "ro" ]]; then
    chmod 0755 "$EXPORT_PATH" 2>/dev/null || true
else
    chmod 0775 "$EXPORT_PATH" 2>/dev/null || true
fi
log_ok "Permissions set on ${EXPORT_PATH}"

# =============================================================================
# Verify
# =============================================================================

log_info ""
log_info "=== Verification ==="

# Show current exports
if command_exists exportfs; then
    log_info "Active NFS exports:"
    exportfs -v 2>/dev/null | while IFS= read -r line; do
        echo "  ${line}"
    done
    log_info ""
fi

# Show NFS server status
if command_exists nfsstat; then
    nfsstat -s 2>/dev/null | head -5 || true
fi

# Show mount path
log_info ""
log_info "Export path:  ${EXPORT_PATH}"
log_info "Access:       ${ACCESS_MODE}"
log_info "Clients:      ${CLIENT_SPEC}"

# Provide mount example
log_info ""
log_info "Client mount command example:"
log_info "  sudo mount -t nfs4 -o vers=4.2,noatime $(hostname -I | awk '{print $1}'):${EXPORT_PATH} /mnt/nfs-workspace"
log_info ""
log_info "Or in /etc/fstab on clients:"
log_info "  $(hostname -I | awk '{print $1}'):${EXPORT_PATH} /mnt/nfs-workspace nfs4 vers=4.2,noatime,_netdev 0 0"
log_info ""

log_ok "NFS export setup complete!"
