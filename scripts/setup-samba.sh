#!/usr/bin/env bash
# =============================================================================
# drive-nmonit — Setup Samba/CIFS Share
# =============================================================================
# Creates a Samba share exposing /mnt/workspace (or a custom path) to the
# network. Supports multiple share profiles and access control options.
#
# Usage:
#   sudo ./scripts/setup-samba.sh                    # Interactive setup
#   sudo ./scripts/setup-samba.sh --public           # Public guest-access share
#   sudo ./scripts/setup-samba.sh --auth             # Auth-required share (default)
#   sudo ./scripts/setup-samba.sh --remove           # Remove the share config
#   sudo ./scripts/setup-samba.sh --path /mnt/data   # Custom share path
#   sudo ./scripts/setup-samba.sh --dry-run          # Show what would be done
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# --- Configuration ---
SHARE_PATH="/mnt/workspace"
SHARE_NAME="workspace"
CONFIG_DIR="/etc/drive-nmonit"
SAMBA_CONF="/etc/samba/smb.conf"
SAMBA_BACKUP="${CONFIG_DIR}/smb.conf.backup"

# --- Argument defaults ---
ACCESS_MODE="auth"   # auth, public
DRY_RUN=false
REMOVE=false

# --- Parse arguments ---
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --public) ACCESS_MODE="public" ;;
        --auth)   ACCESS_MODE="auth" ;;
        --remove) REMOVE=true ;;
        --dry-run) DRY_RUN=true ;;
        --path=*) SHARE_PATH="${arg#*=}" ;;
        --path)
            # Next arg is the path
            ;;
        *)
            if [[ -z "${NEXT_IS_PATH:-}" ]]; then
                POSITIONAL+=("$arg")
            else
                SHARE_PATH="$arg"
                NEXT_IS_PATH=""
            fi
            ;;
    esac
    if [[ "$arg" == "--path" && "${NEXT_IS_PATH:-}" != "true" ]]; then
        NEXT_IS_PATH="true"
    fi
done

# Handle --path as the last arg
if [[ -z "${NEXT_IS_PATH:-}" ]]; then
    NEXT_IS_PATH="false"
fi
for arg in "${POSITIONAL[@]}"; do
    if [[ "$NEXT_IS_PATH" == "true" ]]; then
        SHARE_PATH="$arg"
        NEXT_IS_PATH="false"
    fi
done

# =============================================================================
# Helpers
# =============================================================================

usage() {
    cat << USAGE
Usage: $0 [OPTIONS]

Options:
  --public          Create a public (guest-access) share — no auth required
  --auth            Create an authenticated share — requires Samba user (default)
  --remove          Remove the share configuration from smb.conf
  --path DIR        Share a different path instead of /mnt/workspace
  --dry-run         Show what would be done without making changes
  -h, --help        Show this help

Examples:
  sudo $0 --auth           # Default authenticated share
  sudo $0 --public         # Guest-accessible share
  sudo $0 --path /mnt/data # Share a custom directory
  sudo $0 --remove         # Remove the workspace share
USAGE
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        -h|--help) usage ;;
    esac
done

# =============================================================================
# Prerequisites
# =============================================================================

require_root

# --- Remove mode ---
if [[ "$REMOVE" == true ]]; then
    log_info "=== Removing Samba '$SHARE_NAME' share ==="

    if [[ ! -f "$SAMBA_CONF" ]]; then
        log_warn "Samba config not found at ${SAMBA_CONF} — nothing to remove"
        exit 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would remove [$SHARE_NAME] section from ${SAMBA_CONF}"
        exit 0
    fi

    # Backup first
    cp "$SAMBA_CONF" "${SAMBA_CONF}.bak.$(date +%s)"
    log_ok "Backup saved"

    # Remove the share section using sed
    if grep -q "^\[${SHARE_NAME}\]" "$SAMBA_CONF"; then
        sed -i "/^\[${SHARE_NAME}\]/,/^\[/ { /^\[${SHARE_NAME}\]/,/^\[/ { /^\[/!d; /^\[${SHARE_NAME}\]/d; } }" "$SAMBA_CONF"
        # Clean up trailing blank lines
        sed -i '/^$/{ N; /^\n$/d; }' "$SAMBA_CONF"
        log_ok "Removed [$SHARE_NAME] section from smb.conf"
    else
        log_info "Share [$SHARE_NAME] not found in smb.conf"
    fi

    # Restart Samba
    if systemctl is-active --quiet smbd 2>/dev/null; then
        systemctl reload smbd || systemctl restart smbd
        log_ok "Samba reloaded"
    elif systemctl is-active --quiet smb 2>/dev/null; then
        systemctl reload smb || systemctl restart smb
        log_ok "Samba reloaded"
    fi

    log_ok "Samba share removed"
    exit 0
fi

# =============================================================================
# Install Samba if not present
# =============================================================================

if ! command_exists smbd && ! command_exists smb; then
    log_info "Samba not found — installing..."

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would install samba package"
    else
        if command_exists apt-get; then
            apt-get update -y >/dev/null 2>&1 || true
            apt-get install -y samba samba-common smbclient 2>/dev/null || {
                log_error "Failed to install samba. Try: apt-get install samba"
                exit 1
            }
        elif command_exists dnf; then
            dnf install -y samba samba-common samba-client 2>/dev/null || {
                log_error "Failed to install samba. Try: dnf install samba"
                exit 1
            }
        elif command_exists yum; then
            yum install -y samba samba-common samba-client 2>/dev/null || {
                log_error "Failed to install samba. Try: yum install samba"
                exit 1
            }
        elif command_exists zypper; then
            zypper install -y samba samba-client 2>/dev/null || {
                log_error "Failed to install samba. Try: zypper install samba"
                exit 1
            }
        else
            log_error "No supported package manager found. Install samba manually."
            exit 1
        fi
        log_ok "Samba installed"
    fi
fi

# =============================================================================
# Validate share path
# =============================================================================

if [[ ! -d "$SHARE_PATH" ]]; then
    log_warn "Share path '${SHARE_PATH}' does not exist yet."
    if [[ "$DRY_RUN" == false ]]; then
        read -r -p "Create directory '${SHARE_PATH}'? [Y/n]: " CREATE_DIR
        if [[ "${CREATE_DIR,,}" != "n" ]] && [[ "${CREATE_DIR,,}" != "no" ]]; then
            mkdir -p "$SHARE_PATH"
            log_ok "Created ${SHARE_PATH}"
        else
            log_error "Share path must exist. Aborting."
            exit 1
        fi
    fi
fi

# =============================================================================
# Build share configuration
# =============================================================================

ensure_dir "$CONFIG_DIR"

# Backup existing smb.conf
if [[ -f "$SAMBA_CONF" ]] && [[ "$DRY_RUN" == false ]]; then
    cp "$SAMBA_CONF" "$SAMBA_BACKUP" 2>/dev/null || true
fi

# Check if share already exists
if [[ "$DRY_RUN" == false ]] && grep -q "^\[${SHARE_NAME}\]" "$SAMBA_CONF" 2>/dev/null; then
    log_warn "Share [$SHARE_NAME] already exists in ${SAMBA_CONF}"
    read -r -p "Overwrite existing share configuration? [y/N]: " OVERWRITE
    if [[ "${OVERWRITE,,}" != "y" ]]; then
        log_info "Keeping existing configuration."
        exit 0
    fi
    # Remove the old section
    sed -i "/^\[${SHARE_NAME}\]/,/^\[/ { /^\[${SHARE_NAME}\]/,/^\[/ { /^\[/!d; /^\[${SHARE_NAME}\]/d; } }" "$SAMBA_CONF"
    sed -i '/^$/{ N; /^\n$/d; }' "$SAMBA_CONF"
fi

# --- Generate share block ---
SHARE_BLOCK="[${SHARE_NAME}]
   comment = drive-nmonit Cluster Workspace
   path = ${SHARE_PATH}
   browseable = yes
   inherit permissions = yes
   veto files = /lost+found/
   hide unreadable = yes
"

if [[ "$ACCESS_MODE" == "public" ]]; then
    SHARE_BLOCK+="
   # Public guest share — no authentication required
   guest ok = yes
   read only = no
   force user = nobody
   force group = nogroup
   create mask = 0777
   directory mask = 0777
"
else
    SHARE_BLOCK+="
   # Authenticated share — requires valid Samba user
   guest ok = no
   read only = no
   valid users = @smbgroup
   force user = nobody
   force group = nogroup
   create mask = 0775
   directory mask = 0775
"
fi

# --- Apply configuration ---
if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] Would add the following to ${SAMBA_CONF}:"
    echo ""
    echo "$SHARE_BLOCK"
    exit 0
fi

# Add to global section of smb.conf if not present
if ! grep -q "^\[${SHARE_NAME}\]" "$SAMBA_CONF" 2>/dev/null; then
    echo "" >> "$SAMBA_CONF"
    echo "$SHARE_BLOCK" >> "$SAMBA_CONF"
    log_ok "Share [$SHARE_NAME] added to ${SAMBA_CONF}"
fi

# --- Ensure global settings are present ---
if ! grep -q "^[[:space:]]*server min protocol" "$SAMBA_CONF" 2>/dev/null; then
    # Add recommended global settings at the top of [global]
    sed -i '/^\[global\]/a\\n   # drive-nmonit recommended settings\n   server min protocol = SMB2_10\n   min receivefile size = 16384\n   write cache size = 262144\n   socket options = TCP_NODELAY IPTOS_LOWDELAY\n   use sendfile = yes\n   aio read size = 16384\n   aio write size = 16384' "$SAMBA_CONF"
    log_ok "Global performance settings added to smb.conf"
fi

# =============================================================================
# Create Samba user (for auth mode)
# =============================================================================

if [[ "$ACCESS_MODE" == "auth" ]]; then
    log_info ""
    log_info "=== Samba User Setup ==="
    log_info "For authenticated access, create a Samba user account."
    log_info "You can also add users later with: smbpasswd -a <username>"
    log_info ""

    # Check if any smb users exist
    EXISTING_USER=$(pdbedit -L 2>/dev/null | head -1 || true)
    if [[ -n "$EXISTING_USER" ]]; then
        log_info "Existing Samba users:"
        pdbedit -L 2>/dev/null | awk '{print "  • " $1}'
        log_info ""
    fi

    read -r -p "Create a new Samba user? [y/N]: " CREATE_USER
    if [[ "${CREATE_USER,,}" == "y" ]]; then
        read -r -p "Username: " SMB_USER
        if [[ -n "$SMB_USER" ]]; then
            # Ensure Unix user exists
            if ! id "$SMB_USER" &>/dev/null; then
                log_info "Creating system user '${SMB_USER}'..."
                useradd -M -s /sbin/nologin -g nogroup "$SMB_USER" || {
                    log_warn "Could not create system user. Try manually: smbpasswd -a ${SMB_USER}"
                }
            fi
            # Add to smbgroup if it exists
            if grep -q "^smbgroup:" /etc/group 2>/dev/null; then
                usermod -aG smbgroup "$SMB_USER" 2>/dev/null || true
            fi
            # Set Samba password
            log_info "Enter password for Samba user '${SMB_USER}':"
            smbpasswd -a "$SMB_USER" || {
                log_warn "Failed to set Samba password. Try: smbpasswd -a ${SMB_USER}"
            }
            log_ok "Samba user '${SMB_USER}' created"
        fi
    fi
fi

# =============================================================================
# Set filesystem permissions
# =============================================================================

log_info ""
log_info "Setting permissions on ${SHARE_PATH}..."

if [[ "$ACCESS_MODE" == "public" ]]; then
    chmod 0777 "$SHARE_PATH" 2>/dev/null || true
else
    chmod 0775 "$SHARE_PATH" 2>/dev/null || true
fi
log_ok "Permissions set on ${SHARE_PATH}"

# =============================================================================
# Firewall
# =============================================================================

log_info ""
log_info "=== Firewall Configuration ==="

# Samba ports: 139/tcp (NetBIOS), 445/tcp (CIFS), 137-138/udp (NetBIOS)
if command_exists ufw && ufw status | grep -q active; then
    ufw allow 139/tcp 2>/dev/null || true
    ufw allow 445/tcp 2>/dev/null || true
    ufw allow 137/udp 2>/dev/null || true
    ufw allow 138/udp 2>/dev/null || true
    log_ok "UFW rules added for Samba"
elif command_exists firewall-cmd; then
    firewall-cmd --permanent --add-service=samba 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    log_ok "firewalld rules added for Samba"
fi

log_info ""
log_info "Ensure these ports are open if you have a custom firewall:"
log_info "  TCP 139, 445  — SMB/CIFS file sharing"
log_info "  UDP 137, 138  — NetBIOS name resolution"

# =============================================================================
# Start Samba services
# =============================================================================

log_info ""
log_info "=== Starting Samba Services ==="

# Enable and start the Samba daemon
if [[ -e /lib/systemd/system/smbd.service ]]; then
    systemctl enable smbd 2>/dev/null || true
    systemctl restart smbd 2>/dev/null || {
        log_error "Failed to start smbd. Check: journalctl -u smbd"
        exit 1
    }
    log_ok "smbd started and enabled"

    # Enable NetBIOS if available
    if [[ -e /lib/systemd/system/nmbd.service ]]; then
        systemctl enable nmbd 2>/dev/null || true
        systemctl restart nmbd 2>/dev/null || true
        log_ok "nmbd (NetBIOS) started"
    fi
elif [[ -e /lib/systemd/system/smb.service ]]; then
    systemctl enable smb 2>/dev/null || true
    systemctl restart smb 2>/dev/null || {
        log_error "Failed to start smb. Check: journalctl -u smb"
        exit 1
    }
    log_ok "smb started and enabled"
fi

# =============================================================================
# Verify
# =============================================================================

log_info ""
log_info "=== Verification ==="

# Check if share is accessible
if command_exists smbclient; then
    log_info "Listing local shares:"
    smbclient -L localhost -N 2>/dev/null | grep -E "^[[:space:]]+${SHARE_NAME}" || {
        log_info "  Could not list shares via smbclient (may need auth)"
    }
fi

# Show share path
log_info ""
log_info "Share:  \\\\$(hostname -I | awk '{print $1}')\\${SHARE_NAME}"
log_info "Path:   ${SHARE_PATH}"
if [[ "$ACCESS_MODE" == "public" ]]; then
    log_info "Access: Public (no authentication required)"
else
    log_info "Access: Authenticated (Samba user required)"
    log_info "Add users: smbpasswd -a <username>"
fi

log_ok "Samba share setup complete!"
