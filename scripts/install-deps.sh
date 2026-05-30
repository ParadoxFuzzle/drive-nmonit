#!/usr/bin/env bash
# =============================================================================
# drive-nmonit — Install Dependencies
# =============================================================================
# Installs mergerfs, GlusterFS server & client, and supporting utilities.
# Supports apt (Debian/Ubuntu), yum/dnf (RHEL/Fedora), and zypper (SUSE).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

require_root

log_info "Installing drive-nmonit dependencies..."

# --- Detect package manager ---
PKG_MANAGER=""
INSTALL_CMD=""
if command_exists apt-get; then
    PKG_MANAGER="apt"
    INSTALL_CMD="apt-get install -y"
    UPDATE_CMD="apt-get update -y"
elif command_exists dnf; then
    PKG_MANAGER="dnf"
    INSTALL_CMD="dnf install -y"
    UPDATE_CMD="dnf check-update || true"
elif command_exists yum; then
    PKG_MANAGER="yum"
    INSTALL_CMD="yum install -y"
    UPDATE_CMD="yum check-update || true"
elif command_exists zypper; then
    PKG_MANAGER="zypper"
    INSTALL_CMD="zypper install -y"
    UPDATE_CMD="zypper refresh"
else
    log_error "No supported package manager found (apt, dnf, yum, zypper)."
    exit 1
fi

log_info "Detected package manager: ${PKG_MANAGER}"

# --- Add mergerfs repository (if needed) ---
# mergerfs is available in universe repo on Ubuntu, EPEL on RHEL, etc.
if [[ "$PKG_MANAGER" == "apt" ]]; then
    # Ensure universe repo is enabled (Ubuntu)
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y software-properties-common >/dev/null 2>&1 || true

    # Add the Trapexit/mergerfs PPA for the latest version
    if ! add-apt-repository -y ppa:trapexit/mergerfs 2>/dev/null; then
        log_warn "Could not add mergerfs PPA; will use repository version (may be older)"
    fi

    # Add GlusterFS PPA
    if ! add-apt-repository -y ppa:gluster/glusterfs-11 2>/dev/null; then
        log_warn "Could not add GlusterFS PPA; will use repository version (may be older)"
    fi
elif [[ "$PKG_MANAGER" == "dnf" ]] || [[ "$PKG_MANAGER" == "yum" ]]; then
    # Enable EPEL for mergerfs and GlusterFS
    if ! rpm -q epel-release &>/dev/null; then
        $INSTALL_CMD epel-release 2>/dev/null || log_warn "Could not install EPEL; some packages may not be found"
    fi
fi

# --- Update package lists ---
log_info "Updating package lists..."
$UPDATE_CMD 2>/dev/null || log_warn "Package update had non-zero exit (may be normal)"

# --- Install mergerfs ---
log_info "Installing mergerfs..."
MERGERFS_PKG="mergerfs"
if [[ "$PKG_MANAGER" == "apt" ]]; then
    if ! $INSTALL_CMD mergerfs 2>/dev/null; then
        log_warn "mergerfs package not found in repositories"
        log_warn "See https://github.com/trapexit/mergerfs#debian--ubuntu for manual install"
    fi
else
    $INSTALL_CMD "$MERGERFS_PKG" 2>/dev/null || log_warn "mergerfs not found; may need manual install"
fi

# --- Install GlusterFS ---
log_info "Installing GlusterFS server and client..."

if [[ "$PKG_MANAGER" == "apt" ]]; then
    # GlusterFS server package
    $INSTALL_CMD glusterfs-server glusterfs-client 2>/dev/null || {
        log_warn "glusterfs-server not found; trying alternate package names..."
        $INSTALL_CMD glusterfs 2>/dev/null || log_warn "GlusterFS not found in repositories"
    }
elif [[ "$PKG_MANAGER" == "dnf" ]] || [[ "$PKG_MANAGER" == "yum" ]]; then
    $INSTALL_CMD glusterfs-server glusterfs-client glusterfs-fuse 2>/dev/null || {
        log_warn "GlusterFS packages not found; may need to enable additional repositories"
    }
elif [[ "$PKG_MANAGER" == "zypper" ]]; then
    $INSTALL_CMD glusterfs glusterfs-server glusterfs-client 2>/dev/null || {
        log_warn "GlusterFS packages not found"
    }
fi

# --- Install supporting utilities ---
log_info "Installing supporting utilities..."
UTILS="jq pv"
if [[ "$PKG_MANAGER" == "apt" ]]; then
    $INSTALL_CMD $UTILS util-linux 2>/dev/null || true
elif [[ "$PKG_MANAGER" == "dnf" ]] || [[ "$PKG_MANAGER" == "yum" ]]; then
    $INSTALL_CMD $UTILS 2>/dev/null || true
elif [[ "$PKG_MANAGER" == "zypper" ]]; then
    $INSTALL_CMD $UTILS 2>/dev/null || true
fi

# --- Install Samba ---
log_info "Installing Samba/CIFS..."
if [[ "$PKG_MANAGER" == "apt" ]]; then
    $INSTALL_CMD samba samba-common smbclient 2>/dev/null || log_warn "Samba packages not found"
elif [[ "$PKG_MANAGER" == "dnf" ]] || [[ "$PKG_MANAGER" == "yum" ]]; then
    $INSTALL_CMD samba samba-common samba-client 2>/dev/null || log_warn "Samba packages not found"
elif [[ "$PKG_MANAGER" == "zypper" ]]; then
    $INSTALL_CMD samba samba-client 2>/dev/null || log_warn "Samba packages not found"
fi

# --- Install NFS server ---
log_info "Installing NFS server..."
if [[ "$PKG_MANAGER" == "apt" ]]; then
    $INSTALL_CMD nfs-kernel-server 2>/dev/null || log_warn "NFS packages not found"
elif [[ "$PKG_MANAGER" == "dnf" ]] || [[ "$PKG_MANAGER" == "yum" ]]; then
    $INSTALL_CMD nfs-utils 2>/dev/null || log_warn "NFS packages not found"
elif [[ "$PKG_MANAGER" == "zypper" ]]; then
    $INSTALL_CMD nfs-kernel-server 2>/dev/null || log_warn "NFS packages not found"
fi

# --- Verify installations ---
log_info ""
log_info "=== Installation Summary ==="

if command_exists mergerfs; then
    log_ok "mergerfs: $(mergerfs --version 2>&1 | head -1)"
else
    log_error "mergerfs NOT installed"
fi

if command_exists glusterfs; then
    log_ok "GlusterFS client: $(glusterfs --version 2>&1 | head -1)"
else
    log_error "GlusterFS client NOT installed"
fi

if command_exists glusterd; then
    log_ok "GlusterFS server (glusterd): found"
else
    log_error "GlusterFS server (glusterd) NOT installed"
fi

if command_exists gluster; then
    log_ok "GlusterFS CLI: found"
fi

if command_exists smbd || command_exists smb; then
    log_ok "Samba: found"
else
    log_warn "Samba NOT installed"
fi

if command_exists exportfs || command_exists nfsstat; then
    log_ok "NFS server: found"
else
    log_warn "NFS server NOT installed"
fi

log_info ""
log_info "Installation complete!"
log_info ""
log_info "Next steps:"
log_info "  1. Run ./scripts/setup-mergerfs.sh on ALL nodes to pool local drives"
log_info "  2. On the primary node, run: sudo ./scripts/setup-glusterfs.sh --init"
log_info "  3. On each slave node, run:  sudo ./scripts/setup-glusterfs.sh --join <primary-ip>"
log_info "  4. Run ./scripts/mount-all.sh on ALL nodes"
log_info "  5. (Optional) Run ./scripts/setup-samba.sh to expose workspace via SMB/CIFS"
log_info "  6. (Optional) Run ./scripts/setup-nfs.sh to expose workspace via NFS"
