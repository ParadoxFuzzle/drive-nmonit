#!/usr/bin/env bash
# =============================================================================
# drive-nmonit — GlusterFS Performance Tuning
# =============================================================================
# Applies performance tuning profiles to a GlusterFS volume.
# Can be run independently after volume creation.
#
# Usage:
#   sudo ./scripts/tune-glusterfs.sh <volume-name> [profile]
#
# Profiles:
#   balanced     — Good all-around performance (default)
#   throughput   — Optimized for large sequential reads/writes
#   metadata     — Optimized for many small files and directory operations
#   capacity     — Minimizes memory use, suitable for low-RAM nodes
#   custom       — Interactive mode where you select individual options
#
# Examples:
#   sudo ./scripts/tune-glusterfs.sh workspace balanced
#   sudo ./scripts/tune-glusterfs.sh workspace metadata
#   sudo ./scripts/tune-glusterfs.sh workspace throughput
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

require_root

# --- Validate arguments ---
VOLUME_NAME="${1:-}"
if [[ -z "$VOLUME_NAME" ]]; then
    log_error "Usage: $0 <volume-name> [profile]"
    log_error "Profiles: balanced, throughput, metadata, capacity, custom"
    exit 1
fi

PROFILE="${2:-balanced}"
SKIP_SYSCTL=false
for arg in "$@"; do
    if [[ "$arg" == "--no-sysctl" ]]; then
        SKIP_SYSCTL=true
    fi
done

# --- Check prerequisites ---
if ! command_exists gluster; then
    log_error "GlusterFS CLI (gluster) not found."
    exit 1
fi

if ! gluster volume info "$VOLUME_NAME" &>/dev/null; then
    log_error "Volume '${VOLUME_NAME}' does not exist."
    gluster volume list
    exit 1
fi

# --- Get system info for adaptive tuning ---
TOTAL_RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "4096")
CPU_CORES=$(nproc 2>/dev/null || echo "4")

log_info "=== drive-nmonit: GlusterFS Performance Tuning ==="
log_info "Volume:     ${VOLUME_NAME}"
log_info "Profile:    ${PROFILE}"
log_info "CPU cores:  ${CPU_CORES}"
log_info "RAM:        ${TOTAL_RAM_MB} MB"
log_info ""

# =============================================================================
# Apply a set of volume options
# =============================================================================
apply_volume_options() {
    local desc="$1"
    shift

    log_info "Applying ${desc}..."

    while [[ $# -gt 0 ]]; do
        local key="$1"
        local val="$2"
        shift 2

        if gluster volume set "$VOLUME_NAME" "$key" "$val" 2>/dev/null; then
            log_ok "  ${key} = ${val}"
        else
            log_warn "  ${key} = ${val} — failed (may not be supported in this version)"
        fi
    done
}

# =============================================================================
# Profile definitions
# =============================================================================
apply_profile_balanced() {
    log_info "== Balanced Profile =="
    log_info "Good all-around performance for mixed workloads."
    log_info ""

    # --- Caching ---
    gluster volume set "$VOLUME_NAME" group metadata-cache 2>/dev/null || true
    log_ok "  Applied group: metadata-cache"

    apply_volume_options "caching settings" \
        performance.readdir-ahead on \
        performance.parallel-readdir on \
        performance.md-cache-timeout 600 \
        performance.cache-size "$((TOTAL_RAM_MB / 4))MB" \
        performance.cache-refresh-timeout 4

    # --- I/O Threading ---
    local io_threads=$(( CPU_CORES * 4 ))
    [[ $io_threads -gt 64 ]] && io_threads=64
    [[ $io_threads -lt 8 ]] && io_threads=8

    apply_volume_options "I/O threading (${io_threads} threads)" \
        performance.io-thread-count "$io_threads" \
        client.event-threads 4 \
        server.event-threads 4

    # --- Read/Write Behavior ---
    apply_volume_options "read/write behavior" \
        performance.read-ahead-page-count 4 \
        performance.strict-write-ordering off \
        performance.strict-o-direct on \
        performance.client-io-threads on

    # --- Network ---
    apply_volume_options "network settings" \
        network.ping-timeout 30 \
        network.frame-timeout 60 \
        network.remote-dio-write-behind on

    # --- Metadata ---
    apply_volume_options "metadata settings" \
        network.inode-lru-limit 50000 \
        features.cache-invalidation on \
        performance.nl-cache on \
        performance.nl-cache-timeout 600

    # --- Writeback optimization for mergerfs backing ---
    # Since mergerfs adds latency, allow more in-flight writes
    apply_volume_options "writeback (mergerfs-aware)" \
        performance.write-behind-window-size 4MB \
        performance.flush-behind on

    # --- Storage ---
    apply_volume_options "storage settings" \
        storage.fips-mode-rchecksum on \
        cluster.lookup-optimize on \
        cluster.read-hash-mode 2
}

apply_profile_throughput() {
    log_info "== Throughput Profile =="
    log_info "Optimized for large sequential reads/writes (media, backups, ISOs)."
    log_info ""

    local cache_mb=$(( TOTAL_RAM_MB / 3 ))
    [[ $cache_mb -gt 4096 ]] && cache_mb=4096

    local io_threads=$(( CPU_CORES * 2 ))
    [[ $io_threads -gt 32 ]] && io_threads=32
    [[ $io_threads -lt 4 ]] && io_threads=4

    # Aggressive read-ahead and write-behind
    apply_volume_options "aggressive read/write caching" \
        performance.cache-size "${cache_mb}MB" \
        performance.read-ahead-page-count 16 \
        performance.write-behind-window-size 8MB \
        performance.read-ahead on \
        performance.write-behind on \
        performance.flush-behind on \
        performance.strict-write-ordering off \
        performance.client-io-threads on \
        performance.io-cache on \
        performance.io-cache-size 512MB \
        performance.io-thread-count "$io_threads"

    # Disable metadata features that add overhead for large files
    apply_volume_options "metadata simplification (large files)" \
        performance.md-cache-timeout 0 \
        performance.nl-cache off \
        performance.parallel-readdir off \
        performance.readdir-ahead off \
        features.cache-invalidation off \
        network.inode-lru-limit 16384

    # Network: crank up timeouts for long transfers
    apply_volume_options "network (long-transfer tuning)" \
        network.ping-timeout 60 \
        network.frame-timeout 120 \
        client.event-threads 2 \
        server.event-threads 2

    # Storage
    apply_volume_options "storage settings" \
        storage.fips-mode-rchecksum on \
        cluster.lookup-optimize on \
        cluster.min-free-disk 5%
}

apply_profile_metadata() {
    log_info "== Metadata Profile =="
    log_info "Optimized for many small files, directories, stat() calls."
    log_info ""

    local cache_mb=$(( TOTAL_RAM_MB / 2 ))
    [[ $cache_mb -gt 8192 ]] && cache_mb=8192

    local io_threads=$(( CPU_CORES * 8 ))
    [[ $io_threads -gt 128 ]] && io_threads=128
    [[ $io_threads -lt 16 ]] && io_threads=16

    # Aggressive metadata caching
    gluster volume set "$VOLUME_NAME" group metadata-cache 2>/dev/null || true
    gluster volume set "$VOLUME_NAME" group nl-cache 2>/dev/null || true
    log_ok "  Applied groups: metadata-cache, nl-cache"

    apply_volume_options "aggressive metadata caching" \
        performance.md-cache-timeout 3600 \
        performance.nl-cache on \
        performance.nl-cache-timeout 3600 \
        performance.cache-invalidation on \
        performance.cache-refresh-timeout 10 \
        network.inode-lru-limit 200000 \
        performance.cache-size "${cache_mb}MB" \
        performance.io-cache on \
        performance.io-cache-size 512MB

    # High thread count for concurrent small I/O
    apply_volume_options "high concurrency threading" \
        performance.io-thread-count "$io_threads" \
        client.event-threads 8 \
        server.event-threads 8

    # Directory operations
    apply_volume_options "directory optimization" \
        performance.readdir-ahead on \
        performance.parallel-readdir on \
        performance.readdir-ahead-fetch-ahead on \
        performance.read-ahead-page-count 2 \
        performance.write-behind-window-size 512KB

    # Network
    apply_volume_options "network (low-latency)" \
        network.ping-timeout 10 \
        network.frame-timeout 30 \
        network.remote-dio-write-behind on

    # Storage
    apply_volume_options "storage settings" \
        storage.fips-mode-rchecksum on \
        cluster.lookup-optimize on \
        cluster.read-hash-mode 2 \
        cluster.min-free-disk 10%

    log_warn "Note: Metadata profile uses significant RAM for caching."
    log_warn "      Monitor memory: free -h"
}

apply_profile_capacity() {
    log_info "== Capacity Profile =="
    log_info "Minimal memory usage, suitable for low-RAM nodes or max storage density."
    log_info ""

    apply_volume_options "minimal caching" \
        performance.cache-size 16MB \
        performance.io-cache off \
        performance.read-ahead off \
        performance.write-behind off \
        performance.readdir-ahead off \
        performance.parallel-readdir off \
        performance.md-cache-timeout 0 \
        performance.nl-cache off \
        performance.cache-invalidation off \
        network.inode-lru-limit 4096

    apply_volume_options "low thread count" \
        performance.io-thread-count 4 \
        client.event-threads 1 \
        server.event-threads 1

    apply_volume_options "network (conservative)" \
        network.ping-timeout 30 \
        network.frame-timeout 60

    apply_volume_options "storage" \
        storage.fips-mode-rchecksum on \
        cluster.lookup-optimize on

    log_warn "Capacity profile disables caching — expect lower performance."
    log_warn "Recommended for archival or bulk-storage workloads only."
}

apply_profile_custom() {
    log_info "== Custom Profile =="
    log_info "Interactive selection of individual tuning options."
    log_info ""

    # Interactive tuning menu
    echo ""
    echo "Select options to toggle (comma-separated, e.g., 1,3,5):"

    local options=(
        "I/O thread count"
        "Cache size"
        "Read-ahead page count"
        "Write-behind window size"
        "Metadata cache on/off"
        "Negative lookup cache on/off"
        "Parallel readdir on/off"
        "Client event threads"
        "Server event threads"
        "Ping timeout"
    )

    for i in "${!options[@]}"; do
        echo "  $((i+1)). ${options[$i]}"
    done
    echo ""
    read -r -p "Enter selections: " selections

    # Parse selections and apply corresponding settings
    # This is a simple interface — users who want full control can use gluster volume set directly
    for sel in ${selections//,/ }; do
        case "$sel" in
            1)
                read -r -p "  I/O thread count [8-128]: " val
                gluster volume set "$VOLUME_NAME" performance.io-thread-count "${val:-16}"
                ;;
            2)
                read -r -p "  Cache size (e.g., 256MB, 1GB): " val
                gluster volume set "$VOLUME_NAME" performance.cache-size "${val:-256MB}"
                ;;
            3)
                read -r -p "  Read-ahead page count [1-16]: " val
                gluster volume set "$VOLUME_NAME" performance.read-ahead-page-count "${val:-4}"
                ;;
            4)
                read -r -p "  Write-behind window size (e.g., 512KB, 1MB, 8MB): " val
                gluster volume set "$VOLUME_NAME" performance.write-behind-window-size "${val:-1MB}"
                ;;
            5)
                read -r -p "  Metadata cache (on/off): " val
                gluster volume set "$VOLUME_NAME" performance.md-cache "${val:-on}"
                ;;
            6)
                read -r -p "  Negative lookup cache (on/off): " val
                gluster volume set "$VOLUME_NAME" performance.nl-cache "${val:-on}"
                ;;
            7)
                read -r -p "  Parallel readdir (on/off): " val
                gluster volume set "$VOLUME_NAME" performance.parallel-readdir "${val:-on}"
                ;;
            8)
                read -r -p "  Client event threads [1-8]: " val
                gluster volume set "$VOLUME_NAME" client.event-threads "${val:-2}"
                ;;
            9)
                read -r -p "  Server event threads [1-8]: " val
                gluster volume set "$VOLUME_NAME" server.event-threads "${val:-2}"
                ;;
            10)
                read -r -p "  Ping timeout (seconds) [10-120]: " val
                gluster volume set "$VOLUME_NAME" network.ping-timeout "${val:-30}"
                ;;
            *)
                log_warn "  Unknown selection: ${sel}"
                ;;
        esac
    done
}

# =============================================================================
# Apply sysctl tuning
# =============================================================================
apply_sysctl_tuning() {
    log_info ""
    log_info "=== Kernel Tuning ==="

    if [[ -f "${SCRIPT_DIR}/sysctl-glusterfs.conf" ]]; then
        local sysctl_dest="/etc/sysctl.d/90-glusterfs.conf"

        if [[ -f "$sysctl_dest" ]]; then
            log_info "Sysctl config already exists at ${sysctl_dest}"
            read -r -p "Overwrite? [y/N]: " OVERWRITE
            if [[ "${OVERWRITE,,}" != "y" ]]; then
                log_info "Skipping sysctl tuning."
                return
            fi
        fi

        cp "${SCRIPT_DIR}/sysctl-glusterfs.conf" "$sysctl_dest"
        chmod 644 "$sysctl_dest"
        log_ok "Installed ${sysctl_dest}"

        log_info "Applying sysctl settings..."
        if sysctl --system 2>/dev/null || sysctl -p "$sysctl_dest" 2>/dev/null; then
            log_ok "Kernel parameters applied"
        else
            log_warn "Some sysctl settings could not be applied (may need different syntax)"
        fi
    else
        log_warn "sysctl-glusterfs.conf not found at ${SCRIPT_DIR}/sysctl-glusterfs.conf"
        log_warn "Kernel tuning skipped. Copy the file manually if desired."
    fi
}

# =============================================================================
# Display current settings
# =============================================================================
show_current_settings() {
    log_info ""
    log_info "=== Current Volume Options ==="
    log_info ""
    gluster volume info "$VOLUME_NAME"
    log_info ""
    log_info ""
    log_info "=== Effective Performance Options ==="
    gluster volume get "$VOLUME_NAME" all 2>/dev/null | grep -E 'performance\.|network\.|client\.|server\.|cluster\.|features\.|storage\.' || \
        log_warn "Could not list effective options"
}

# =============================================================================
# Main
# =============================================================================
case "$PROFILE" in
    balanced|default)
        apply_profile_balanced
        ;;
    throughput|large-file|seq)
        apply_profile_throughput
        ;;
    metadata|small-file|many-files)
        apply_profile_metadata
        ;;
    capacity|minimal|low-ram)
        apply_profile_capacity
        ;;
    custom|interactive)
        apply_profile_custom
        ;;
    *)
        log_error "Unknown profile: ${PROFILE}"
        log_error "Valid profiles: balanced, throughput, metadata, capacity, custom"
        exit 1
        ;;
esac

# --- Sysctl tuning (skip in custom/interactive mode, or with --no-sysctl) ---
if [[ "$PROFILE" != "custom" ]] && [[ "$SKIP_SYSCTL" != "true" ]]; then
    log_info ""
    read -r -p "Apply kernel sysctl tuning (network/memory)? [Y/n]: " APPLY_SYSCTL
    if [[ "${APPLY_SYSCTL,,}" != "n" ]] && [[ "${APPLY_SYSCTL,,}" != "no" ]]; then
        apply_sysctl_tuning
    fi
elif [[ "$SKIP_SYSCTL" == "true" ]]; then
    log_info "Kernel sysctl tuning skipped (--no-sysctl flag)"
fi

# --- Display results ---
show_current_settings

# --- Guidance ---
log_info ""
log_info "=== Post-Tuning Guidance ==="
log_info ""

case "$PROFILE" in
    balanced)
        log_info "Profile applied: Balanced"
        log_info "→ Test with: fio --name=test --ioengine=libaio --rw=randrw --size=1G --numjobs=4 --group_reporting"
        log_info "→ If write performance is poor, reduce performance.cache-size or adjust performance.strict-o-direct"
        ;;
    throughput)
        log_info "Profile applied: Throughput"
        log_info "→ Test with: dd if=/dev/zero of=/mnt/workspace/test bs=1M count=4096 conv=fdatasync"
        log_info "→ For maximum throughput, consider jumbo frames (MTU 9000) on your network"
        ;;
    metadata)
        log_info "Profile applied: Metadata"
        log_info "→ Test with: scripts/benchmark-metadata.sh (if available) or 'ls -laR' on a large directory"
        log_info "→ Monitor RAM: free -h — this profile caches heavily"
        ;;
    capacity)
        log_info "Profile applied: Capacity"
        log_info "→ Expect lower I/O performance — this profile trades speed for memory efficiency"
        ;;
esac

log_info ""
log_info "Mount options for client nodes:"
log_info "  sudo mount -t glusterfs -o noatime,direct-io-mode=disable,log-level=WARNING,fetch-attempts=10,use-readdirp=yes \\"
log_info "    <server>:/${VOLUME_NAME} /mnt/workspace"
log_info ""
log_info "Benchmarking:"
log_info "  gluster volume profile ${VOLUME_NAME} info    # Show operation latencies"
log_info "  gluster volume top ${VOLUME_NAME} read open    # Show open file count"
log_info ""

if [[ "$PROFILE" != "custom" ]]; then
    log_ok "Profile '${PROFILE}' applied to volume '${VOLUME_NAME}'"
fi
