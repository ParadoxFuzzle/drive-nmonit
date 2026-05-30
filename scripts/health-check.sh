#!/usr/bin/env bash
# =============================================================================
# drive-nmonit — Cluster Health Check & Monitoring
# =============================================================================
# Monitors GlusterFS volume status, peer connectivity, disk space per brick,
# mergerfs pool health, and system services. Supports multiple output formats
# and configurable alert thresholds.
#
# Usage:
#   sudo ./scripts/health-check.sh                    # Human-readable output
#   sudo ./scripts/health-check.sh --json             # Machine-parseable JSON
#   sudo ./scripts/health-check.sh --nagios           # Nagios/Icinga compatible
#   sudo ./scripts/health-check.sh --quiet            # Only output on warnings/errors
#   sudo ./scripts/health-check.sh --watch            # Continuous watch mode (re-runs every 5s)
#   sudo ./scripts/health-check.sh --send-alert       # Send notification on issues
#
# Exit codes:
#   0 — All healthy
#   1 — Warnings (non-critical issues)
#   2 — Critical (service down, data at risk)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# =============================================================================
# Configuration
# =============================================================================
VOLUME_NAME="workspace"
POOL_MOUNT="/mnt/local-pool"
WORKSPACE_MOUNT="/mnt/workspace"
DRIVES_BASE="/mnt/drives"
CONFIG_DIR="/etc/drive-nmonit"
ALERT_SCRIPT="${CONFIG_DIR}/alert.sh"

# --- Thresholds (customizable via environment variables) ---
WARN_DISK_PCT="${WARN_DISK_PCT:-80}"       # Warning at 80% disk usage
CRIT_DISK_PCT="${CRIT_DISK_PCT:-90}"       # Critical at 90% disk usage
WARN_INODE_PCT="${WARN_INODE_PCT:-80}"     # Warning at 80% inode usage
CRIT_INODE_PCT="${CRIT_INODE_PCT:-90}"     # Critical at 90% inode usage
WARN_BRICK_LAG="${WARN_BRICK_LAG:-30}"     # Warning if brick is behind by 30+ entries in changelog
CRIT_BRICK_OFFLINE="${CRIT_BRICK_OFFLINE:-1}" # Critical if any brick is offline

# --- State tracking for alert deduplication ---
STATE_DIR="${CONFIG_DIR}/health-state"
ensure_dir "$STATE_DIR"

# --- Parse arguments ---
OUTPUT_MODE="human"
QUIET=false
WATCH=false
SEND_ALERT=false

for arg in "$@"; do
    case "$arg" in
        --json)    OUTPUT_MODE="json" ;;
        --nagios)  OUTPUT_MODE="nagios" ;;
        --quiet)   QUIET=true ;;
        --watch)   WATCH=true ;;
        --send-alert) SEND_ALERT=true ;;
    esac
done

# --- Globals for JSON output ---
OVERALL_STATUS="healthy"  # healthy, warning, critical
EXIT_CODE=0
ALERTS=()

# --- Metrics captured for JSON output (populated during checks) ---
VOLUME_STATUS=""
VOLUME_TYPE=""
BRICK_COUNT=0
PEER_COUNT=0
PEER_DISCONNECTED=0
MEM_TOTAL_MB=0
MEM_AVAIL_MB=0
MEM_PCT=0
CPU_LOAD_1=""
CPU_CORES=0
POOL_DISK_PCT=0
POOL_DISK_USED=""
POOL_DISK_SIZE=""
BRICK_PROCESSES=0

# =============================================================================
# Helper: set overall status
# =============================================================================
set_status() {
    local level="$1"  # warning or critical
    local msg="$2"
    ALERTS+=("$level: $msg")

    if [[ "$level" == "critical" ]] && [[ "$OVERALL_STATUS" != "critical" ]]; then
        OVERALL_STATUS="critical"
        EXIT_CODE=2
    elif [[ "$level" == "warning" ]] && [[ "$OVERALL_STATUS" == "healthy" ]]; then
        OVERALL_STATUS="warning"
        [[ $EXIT_CODE -lt 1 ]] && EXIT_CODE=1
    fi
}

# =============================================================================
# Helper: print section headers
# =============================================================================
section() {
    if [[ "$OUTPUT_MODE" == "human" ]] && [[ "$QUIET" == false ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  $1"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi
}

# =============================================================================
# Helper: print a check result
# =============================================================================
print_check() {
    local status="$1"   # OK, WARN, CRIT, SKIP
    local label="$2"
    local detail="${3:-}"

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        # JSON accumulates results in an array
        return
    fi

    if [[ "$QUIET" == true ]] && [[ "$status" == "OK" ]]; then
        return
    fi

    local icon
    case "$status" in
        OK)   icon="✔" ;;
        WARN) icon="⚠" ;;
        CRIT) icon="✘" ;;
        SKIP) icon="—" ;;
    esac

    printf "  %s  %-50s" "$icon" "$label"
    if [[ -n "$detail" ]]; then
        echo "$detail"
    else
        echo ""
    fi
}

# =============================================================================
# Check 1: System Services
# =============================================================================
check_services() {
    section "System Services"

    local services=(
        "glusterd:glusterd.service:GlusterFS daemon"
        "mergerfs:mergerfs-pool.service:MergerFS pool (if installed)"
    )

    for entry in "${services[@]}"; do
        local bin="${entry%%:*}"
        local rest="${entry#*:}"
        local svc="${rest%%:*}"
        local desc="${rest#*:}"

        if command_exists "$bin"; then
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                print_check "OK" "$desc" "(active)"
            else
                print_check "CRIT" "$desc" "(inactive)"
                set_status "critical" "Service ${svc} is not running"
            fi
        else
            print_check "SKIP" "$desc" "(not installed)"
        fi
    done

    # Check workspace mount
    if mountpoint -q "$WORKSPACE_MOUNT" 2>/dev/null; then
        print_check "OK" "Workspace mount" "(${WORKSPACE_MOUNT})"
    else
        print_check "CRIT" "Workspace mount" "(${WORKSPACE_MOUNT} — NOT MOUNTED)"
        set_status "critical" "Workspace ${WORKSPACE_MOUNT} is not mounted"
    fi
}

# =============================================================================
# Check 2: GlusterFS Volume Status
# =============================================================================
check_gluster_volume() {
    section "GlusterFS Volume: ${VOLUME_NAME}"

    if ! command_exists gluster; then
        print_check "SKIP" "GlusterFS CLI" "(not installed)"
        return
    fi

    # --- Volume info ---
    local vol_info
    vol_info=$(gluster volume info "$VOLUME_NAME" 2>/dev/null) || {
        print_check "CRIT" "Volume info retrieval"
        set_status "critical" "Cannot retrieve volume info for ${VOLUME_NAME}"
        return
    }

    local vol_status
    vol_status=$(echo "$vol_info" | grep -i "^Status:" | awk '{print $2}')
    VOLUME_STATUS="$vol_status"
    if [[ "$vol_status" == "Started" ]]; then
        print_check "OK" "Volume status" "(${vol_status})"
    else
        print_check "CRIT" "Volume status" "(${vol_status})"
        set_status "critical" "Volume ${VOLUME_NAME} status is ${vol_status}"
    fi

    # --- Volume type ---
    local vol_type
    vol_type=$(echo "$vol_info" | grep -i "^Type:" | awk '{print $2}')
    VOLUME_TYPE="$vol_type"
    print_check "OK" "Volume type" "(${vol_type})"

    # --- Number of bricks ---
    local brick_count
    brick_count=$(echo "$vol_info" | grep -c "^Brick")
    BRICK_COUNT=$brick_count
    print_check "OK" "Configured bricks" "(${brick_count})"

    # --- Split-brain check ---
    local split_brain
    split_brain=$(gluster volume heal "$VOLUME_NAME" info split-brain 2>/dev/null | grep -c "Number of entries:" || echo "0")
    if [[ "$split_brain" -gt 0 ]]; then
        print_check "CRIT" "Split-brain entries" "(${split_brain} files)"
        set_status "critical" "${split_brain} split-brain entries in volume ${VOLUME_NAME}"
    else
        print_check "OK" "Split-brain entries" "(none)"
    fi

    # --- Heal pending (for replicated volumes) ---
    if [[ "$vol_type" == *"Replicate"* ]]; then
        local heal_pending
        heal_pending=$(gluster volume heal "$VOLUME_NAME" info 2>/dev/null | grep -c "Number of entries:" || echo "0")
        if [[ "$heal_pending" -gt 0 ]]; then
            print_check "WARN" "Pending heal entries" "(${heal_pending})"
            set_status "warning" "${heal_pending} pending heal entries"
        else
            print_check "OK" "Heal status" "(clean)"
        fi
    fi

    # --- Rebalance status ---
    local rebalance_status
    rebalance_status=$(gluster volume rebalance "$VOLUME_NAME" status 2>/dev/null | awk 'NR>1 {print $NF}' | sort -u | head -1)
    if [[ -n "$rebalance_status" ]] && [[ "$rebalance_status" != "completed" ]]; then
        print_check "WARN" "Rebalance status" "(${rebalance_status})"
        set_status "warning" "Rebalance in progress: ${rebalance_status}"
    else
        print_check "OK" "Rebalance status" "(completed or not needed)"
    fi

    # --- Quorum check (for replicated volumes) ---
    if [[ "$vol_type" == *"Replicate"* ]]; then
        local quorum_info bricks_up bricks_total
        quorum_info=$(gluster volume status "$VOLUME_NAME" detail 2>/dev/null) || true
        bricks_up=$(echo "$quorum_info" | grep -c "Online" || echo "0")
        bricks_total=$(echo "$quorum_info" | grep -cE "(Online|Offline)" || echo "0")

        if [[ "$bricks_total" -gt 0 ]] && [[ "$bricks_up" -lt $((bricks_total / 2 + 1)) ]]; then
            print_check "CRIT" "Quorum status" "(${bricks_up}/${bricks_total} bricks online — quorum lost)"
            set_status "critical" "Quorum lost for ${VOLUME_NAME}: ${bricks_up}/${bricks_total} bricks online"
        elif [[ "$bricks_up" -lt "$bricks_total" ]]; then
            print_check "WARN" "Quorum status" "(${bricks_up}/${bricks_total} bricks online)"
            set_status "warning" "${bricks_up}/${bricks_total} bricks online for ${VOLUME_NAME}"
        else
            print_check "OK" "Quorum status" "(${bricks_up}/${bricks_total} bricks online)"
        fi
    fi
}

# =============================================================================
# Check 3: Peer Connectivity
# =============================================================================
check_peers() {
    section "GlusterFS Peers"

    if ! command_exists gluster; then
        return
    fi

    local peer_list
    peer_list=$(gluster pool list 2>/dev/null) || {
        print_check "CRIT" "Peer list retrieval"
        set_status "critical" "Cannot retrieve peer list"
        return
    }

    local peer_count
    peer_count=$(echo "$peer_list" | tail -n +2 | wc -l)
    PEER_COUNT=$peer_count

    if [[ "$peer_count" -eq 0 ]]; then
        print_check "OK" "Connected peers" "(standalone node — no peers expected)"
        return
    fi

    print_check "OK" "Total peers" "(${peer_count})"

    # Check each peer
    local disconnected=0
    while IFS= read -r line; do
        # Skip header
        [[ "$line" == *"Hostname"* ]] && continue
        [[ -z "$line" ]] && continue

        local hostname state
        hostname=$(echo "$line" | awk '{print $1}')
        state=$(echo "$line" | awk '{print $2}')

        if [[ "$state" != "Connected" ]]; then
            print_check "CRIT" "Peer: ${hostname}" "(state: ${state})"
            set_status "critical" "Peer ${hostname} is ${state}"
            disconnected=$((disconnected + 1))
        else
            print_check "OK" "Peer: ${hostname}" "(connected)"
        fi
    done <<< "$peer_list"

    PEER_DISCONNECTED=$disconnected
    if [[ "$disconnected" -gt 0 ]]; then
        set_status "critical" "${disconnected} peer(s) disconnected"
    fi
}

# =============================================================================
# Check 4: Disk Space Per Brick
# =============================================================================
check_disk_space() {
    section "Disk Space & Capacity"

    # --- MergerFS pool space ---
    if mountpoint -q "$POOL_MOUNT" 2>/dev/null; then
        local pool_usage pool_pct
        pool_usage=$(df -h "$POOL_MOUNT" | awk 'NR==2{print $3"/"$2}')
        pool_pct=$(df "$POOL_MOUNT" | awk 'NR==2{print $5}' | sed 's/%//')
        POOL_DISK_PCT=$pool_pct
        POOL_DISK_USED=$(df -h "$POOL_MOUNT" | awk 'NR==2{print $3}')
        POOL_DISK_SIZE=$(df -h "$POOL_MOUNT" | awk 'NR==2{print $2}')

        if [[ "$pool_pct" -ge "$CRIT_DISK_PCT" ]]; then
            print_check "CRIT" "MergerFS pool (${POOL_MOUNT})" "(${pool_usage} = ${pool_pct}%)"
            set_status "critical" "Pool disk usage at ${pool_pct}% (threshold: ${CRIT_DISK_PCT}%)"
        elif [[ "$pool_pct" -ge "$WARN_DISK_PCT" ]]; then
            print_check "WARN" "MergerFS pool (${POOL_MOUNT})" "(${pool_usage} = ${pool_pct}%)"
            set_status "warning" "Pool disk usage at ${pool_pct}% (threshold: ${WARN_DISK_PCT}%)"
        else
            print_check "OK" "MergerFS pool (${POOL_MOUNT})" "(${pool_usage})"
        fi

        # Inode usage
        local inode_pct
        inode_pct=$(df -i "$POOL_MOUNT" | awk 'NR==2{print $5}' | sed 's/%//')
        if [[ "$inode_pct" -ge "$CRIT_INODE_PCT" ]]; then
            print_check "CRIT" "Pool inode usage" "(${inode_pct}%)"
            set_status "critical" "Pool inode usage at ${inode_pct}%"
        elif [[ "$inode_pct" -ge "$WARN_INODE_PCT" ]]; then
            print_check "WARN" "Pool inode usage" "(${inode_pct}%)"
            set_status "warning" "Pool inode usage at ${inode_pct}%"
        else
            print_check "OK" "Pool inode usage" "(${inode_pct}%)"
        fi
    else
        print_check "WARN" "MergerFS pool" "(not mounted — cannot check space)"
    fi

    # --- Workspace (GlusterFS) space ---
    if mountpoint -q "$WORKSPACE_MOUNT" 2>/dev/null; then
        local ws_usage ws_pct
        ws_usage=$(df -h "$WORKSPACE_MOUNT" | awk 'NR==2{print $3"/"$2}')
        ws_pct=$(df "$WORKSPACE_MOUNT" | awk 'NR==2{print $5}' | sed 's/%//')

        if [[ "$ws_pct" -ge "$CRIT_DISK_PCT" ]]; then
            print_check "CRIT" "Workspace (${WORKSPACE_MOUNT})" "(${ws_usage} = ${ws_pct}%)"
            set_status "critical" "Workspace disk usage at ${ws_pct}%"
        elif [[ "$ws_pct" -ge "$WARN_DISK_PCT" ]]; then
            print_check "WARN" "Workspace (${WORKSPACE_MOUNT})" "(${ws_usage} = ${ws_pct}%)"
            set_status "warning" "Workspace disk usage at ${ws_pct}%"
        else
            print_check "OK" "Workspace (${WORKSPACE_MOUNT})" "(${ws_usage})"
        fi
    else
        print_check "SKIP" "Workspace" "(not mounted)"
    fi

    # --- Individual brick drives ---
    section "Individual Drive Status"

    if [[ -d "$DRIVES_BASE" ]]; then
        local drive_count=0
        for dir in "$DRIVES_BASE"/*/; do
            [[ -d "$dir" ]] || continue
            drive_count=$((drive_count + 1))

            local label
            label=$(basename "$dir")

            if mountpoint -q "$dir" 2>/dev/null; then
                local dev_size dev_pct
                dev_size=$(df -h "$dir" | awk 'NR==2{print $2}')
                dev_pct=$(df "$dir" | awk 'NR==2{print $5}' | sed 's/%//')
                dev_avail=$(df -h "$dir" | awk 'NR==2{print $4}')

                if [[ "$dev_pct" -ge "$CRIT_DISK_PCT" ]]; then
                    print_check "CRIT" "  ${label}" "(${dev_pct}% used, ${dev_avail} free)"
                    set_status "warning" "Drive ${label} at ${dev_pct}% usage"
                elif [[ "$dev_pct" -ge "$WARN_DISK_PCT" ]]; then
                    print_check "WARN" "  ${label}" "(${dev_pct}% used, ${dev_avail} free)"
                    set_status "warning" "Drive ${label} at ${dev_pct}% usage"
                else
                    print_check "OK" "  ${label}" "(${dev_pct}% used, ${dev_avail} free of ${dev_size})"
                fi
            else
                print_check "CRIT" "  ${label}" "(NOT MOUNTED)"
                set_status "critical" "Drive mount ${label} is missing"
            fi
        done

        if [[ "$drive_count" -eq 0 ]]; then
            print_check "SKIP" "No individual drives" "(pooled via mergerfs)"
        fi
    fi
}

# =============================================================================
# Check 5: MergerFS Pool Health
# =============================================================================
check_mergerfs() {
    section "MergerFS Pool Health"

    if ! command_exists mergerfs; then
        print_check "SKIP" "MergerFS" "(not installed)"
        return
    fi

    # Check if the pool mount exists
    if ! mountpoint -q "$POOL_MOUNT" 2>/dev/null; then
        print_check "CRIT" "Pool mount" "(${POOL_MOUNT} — NOT MOUNTED)"
        set_status "critical" "MergerFS pool ${POOL_MOUNT} is not mounted"
        return
    fi

    print_check "OK" "Pool mount" "(${POOL_MOUNT})"

    # Check mergerFS filesystem type on the mount
    local pool_fs
    pool_fs=$(df -T "$POOL_MOUNT" | awk 'NR==2{print $2}')
    if [[ "$pool_fs" == "fuse.mergerfs" ]] || [[ "$pool_fs" == "mergerfs" ]]; then
        print_check "OK" "Filesystem type" "(${pool_fs})"
    else
        print_check "WARN" "Filesystem type" "(${pool_fs} — expected fuse.mergerfs)"
    fi

    # Count underlying drives in the pool
    local source_count=0
    if [[ -d "$DRIVES_BASE" ]]; then
        source_count=$(find "$DRIVES_BASE" -maxdepth 1 -type d | wc -l)
        source_count=$((source_count - 1))  # subtract the base dir itself
    fi

    if [[ "$source_count" -gt 0 ]]; then
        print_check "OK" "Source drives" "(${source_count})"
    else
        print_check "WARN" "Source drives" "(none found — pool may be empty)"
    fi

    # Samba/NFS exports check (if applicable)
    if command_exists smbstatus; then
        local smb_count
        smb_count=$(smbstatus -L 2>/dev/null | grep -c "$POOL_MOUNT" || echo "0")
        if [[ "$smb_count" -gt 0 ]]; then
            print_check "OK" "Samba exports" "(${smb_count} connections)"
        fi
    fi
}

# =============================================================================
# Check 6: Network Connectivity (to peers)
# =============================================================================
check_network() {
    section "Network Latency (to peers)"

    if ! command_exists gluster; then
        return
    fi

    local peer_list
    peer_list=$(gluster pool list 2>/dev/null | tail -n +2) || return

    local has_peers=false
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local hostname state
        hostname=$(echo "$line" | awk '{print $1}')
        state=$(echo "$line" | awk '{print $2}')

        # Skip localhost
        [[ "$hostname" == "localhost" ]] && continue
        has_peers=true

        if ping -c 1 -W 2 "$hostname" &>/dev/null; then
            local rtt
            rtt=$(ping -c 1 -W 2 "$hostname" 2>/dev/null | tail -1 | awk -F/ '{print $5}' | sed 's/\..*//')
            if [[ -n "$rtt" ]] && [[ "$rtt" -gt 50 ]]; then
                print_check "WARN" "  ${hostname}" "(RTT: ${rtt}ms — high latency)"
                set_status "warning" "High latency to peer ${hostname}: ${rtt}ms"
            else
                print_check "OK" "  ${hostname}" "(RTT: ${rtt:-?}ms)"
            fi
        else
            print_check "WARN" "  ${hostname}" "(unreachable via ping)"
            set_status "warning" "Cannot ping peer ${hostname}"
        fi
    done <<< "$peer_list"

    if [[ "$has_peers" == false ]]; then
        print_check "OK" "No remote peers" "(standalone node)"
    fi
}

# =============================================================================
# Check 7: System Resources
# =============================================================================
check_system_resources() {
    section "System Resources"

    # Memory
    local mem_total mem_avail mem_pct
    mem_total=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
    mem_avail=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
    mem_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
    MEM_TOTAL_MB=$mem_total
    MEM_AVAIL_MB=$mem_avail
    MEM_PCT=$mem_pct

    if [[ "$mem_pct" -gt 90 ]]; then
        print_check "CRIT" "Memory usage" "(${mem_pct}% — ${mem_avail}MB free of ${mem_total}MB)"
        set_status "critical" "Memory usage at ${mem_pct}%"
    elif [[ "$mem_pct" -gt 80 ]]; then
        print_check "WARN" "Memory usage" "(${mem_pct}% — ${mem_avail}MB free of ${mem_total}MB)"
        set_status "warning" "Memory usage at ${mem_pct}%"
    else
        print_check "OK" "Memory usage" "(${mem_pct}% — ${mem_avail}MB free of ${mem_total}MB)"
    fi

    # CPU load
    local load_1 load_5 load_15 cpu_cores
    read -r load_1 load_5 load_15 _ < /proc/loadavg
    cpu_cores=$(nproc 2>/dev/null || echo 1)
    CPU_LOAD_1="$load_1"
    CPU_CORES=$cpu_cores

    if [[ "$(echo "$load_1 > $cpu_cores * 2" | bc 2>/dev/null)" == "1" ]]; then
        print_check "CRIT" "CPU load (1m)" "(${load_1} — ${cpu_cores} cores)"
        set_status "critical" "CPU load at ${load_1} (${cpu_cores} cores)"
    elif [[ "$(echo "$load_1 > $cpu_cores * 1.5" | bc 2>/dev/null)" == "1" ]]; then
        print_check "WARN" "CPU load (1m)" "(${load_1} — ${cpu_cores} cores)"
        set_status "warning" "CPU load at ${load_1}"
    else
        print_check "OK" "CPU load (1m)" "(${load_1} — ${cpu_cores} cores)"
    fi

    # GlusterFS process
    if command_exists glusterfsd; then
        local gf_processes
        gf_processes=$(pgrep -c glusterfsd 2>/dev/null || echo 0)
        BRICK_PROCESSES=$gf_processes
        if [[ "$gf_processes" -eq 0 ]]; then
            print_check "WARN" "GlusterFS process" "(no glusterfsd found)"
        else
            print_check "OK" "GlusterFS bricks" "(${gf_processes} glusterfsd processes)"
        fi
    fi
}

# =============================================================================
# JSON Output Builder
# =============================================================================
output_json() {
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    cat << JSON
{
  "timestamp": "${timestamp}",
  "hostname": "$(hostname)",
  "status": "${OVERALL_STATUS}",
  "exit_code": ${EXIT_CODE},
  "volume_name": "${VOLUME_NAME}",
  "volume_status": "${VOLUME_STATUS}",
  "volume_type": "${VOLUME_TYPE}",
  "brick_count": ${BRICK_COUNT},
  "peer_count": ${PEER_COUNT},
  "peer_disconnected": ${PEER_DISCONNECTED},
  "pool_mount": "${POOL_MOUNT}",
  "workspace_mount": "${WORKSPACE_MOUNT}",
  "disk_usage_pct": ${POOL_DISK_PCT},
  "disk_used": "${POOL_DISK_USED}",
  "disk_size": "${POOL_DISK_SIZE}",
  "memory_total_mb": ${MEM_TOTAL_MB},
  "memory_avail_mb": ${MEM_AVAIL_MB},
  "memory_pct": ${MEM_PCT},
  "cpu_load_1m": "${CPU_LOAD_1}",
  "cpu_cores": ${CPU_CORES},
  "brick_processes": ${BRICK_PROCESSES},
  "alerts": [
JSON
    local first=true
    for alert in "${ALERTS[@]}"; do
        [[ "$first" == false ]] && echo ","
        first=false
        local level="${alert%%:*}"
        local msg="${alert#*: }"
        echo -n "    {\"level\": \"${level}\", \"message\": \"${msg}\"}"
    done
    echo ""
    echo "  ]"
    echo "}"
}

# =============================================================================
# Nagios Output Builder
# =============================================================================
output_nagios() {
    local nagios_status nagios_code
    case "$OVERALL_STATUS" in
        healthy)  nagios_status="OK";       nagios_code=0 ;;
        warning)  nagios_status="WARNING";  nagios_code=1 ;;
        critical) nagios_status="CRITICAL"; nagios_code=2 ;;
    esac

    local summary="${nagios_status}: ${OVERALL_STATUS^} — "
    if [[ ${#ALERTS[@]} -eq 0 ]]; then
        summary+="All checks passed"
    else
        summary+="${#ALERTS[@]} issue(s): "
        local first=true
        for alert in "${ALERTS[@]}"; do
            [[ "$first" == false ]] && summary+=", "
            first=false
            summary+="${alert#*: }"
        done
    fi

    echo "${summary}"
    echo "Status: ${OVERALL_STATUS} | exit_code=${EXIT_CODE}"

    return "$nagios_code"
}

# =============================================================================
# Alert Sender
# =============================================================================
send_alert() {
    if [[ "$SEND_ALERT" == false ]]; then
        return
    fi

    if [[ "$OVERALL_STATUS" == "healthy" ]]; then
        # Only send recovery if we previously had an issue
        if [[ -f "${STATE_DIR}/last_status" ]]; then
            local last
            last=$(cat "${STATE_DIR}/last_status")
            if [[ "$last" != "healthy" ]]; then
                log_info "Recovery detected — sending recovery notification"
                exec_alert_script "RECOVERY" "All systems healthy after previous ${last} state"
            fi
        fi
        echo "healthy" > "${STATE_DIR}/last_status"
        return
    fi

    # Check for alert deduplication: only send if status changed or N checks since last alert
    if [[ -f "${STATE_DIR}/last_alert" ]]; then
        local last_alert
        last_alert=$(cat "${STATE_DIR}/last_alert")
        if [[ "$last_alert" == "$OVERALL_STATUS" ]]; then
            # Same status — check counter
            local count=0
            [[ -f "${STATE_DIR}/alert_count" ]] && count=$(cat "${STATE_DIR}/alert_count")
            count=$((count + 1))
            # Only resend every 6th consecutive same-status check (30 min at 5-min intervals)
            if [[ $((count % 6)) -ne 0 ]]; then
                echo "$count" > "${STATE_DIR}/alert_count"
                return
            fi
        fi
    fi

    echo "$OVERALL_STATUS" > "${STATE_DIR}/last_alert"
    echo "1" > "${STATE_DIR}/alert_count"

    # Build a summary of all alerts
    local summary=""
    for alert in "${ALERTS[@]}"; do
        summary+="  - ${alert}"$'\n'
    done

    exec_alert_script "$OVERALL_STATUS" "$summary"
}

exec_alert_script() {
    local status="$1"
    local message="$2"

    if [[ -x "$ALERT_SCRIPT" ]]; then
        export ALERT_STATUS="$status"
        export ALERT_MESSAGE="$message"
        export ALERT_HOSTNAME=$(hostname)
        export ALERT_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        bash "$ALERT_SCRIPT" 2>/dev/null || log_warn "Alert script failed"
    else
        # Fallback: log to syslog
        logger -t "drive-nmonit-health" "${status}: ${message}"
        log_info "Alert logged to syslog (${ALERT_SCRIPT} not found)"
    fi
}

# =============================================================================
# Watch Mode
# =============================================================================
watch_mode() {
    local interval="${1:-5}"
    log_info "Watch mode — re-running every ${interval}s. Press Ctrl+C to stop."
    log_info ""

    while true; do
        clear 2>/dev/null || true
        echo "drive-nmonit Health Check — $(date) — refreshing every ${interval}s"
        echo ""
        OVERALL_STATUS="healthy"
        EXIT_CODE=0
        ALERTS=()

        run_all_checks

        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Overall status: ${OVERALL_STATUS}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        sleep "$interval"
    done
}

# =============================================================================
# Run all checks
# =============================================================================
run_all_checks() {
    check_services
    check_gluster_volume
    check_peers
    check_disk_space
    check_mergerfs
    check_network
    check_system_resources
}

# =============================================================================
# Main
# =============================================================================

# Root check
require_root

# Watch mode
if [[ "$WATCH" == true ]]; then
    watch_mode "${2:-5}"
    exit 0
fi

# Header
if [[ "$OUTPUT_MODE" == "human" ]]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  drive-nmonit Health Check — $(hostname)"
    echo "  $(date)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

# Run all checks
run_all_checks

# Footer
if [[ "$OUTPUT_MODE" == "human" ]]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Status: ${OVERALL_STATUS}"
    if [[ ${#ALERTS[@]} -gt 0 ]]; then
        echo "  Alerts:"
        for alert in "${ALERTS[@]}"; do
            local level="${alert%%:*}"
            local msg="${alert#*: }"
            if [[ "$level" == "critical" ]]; then
                echo "    [CRIT] ${msg}"
            else
                echo "    [WARN] ${msg}"
            fi
        done
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

# Output in requested format
if [[ "$OUTPUT_MODE" == "json" ]]; then
    output_json
elif [[ "$OUTPUT_MODE" == "nagios" ]]; then
    output_nagios
fi

# Send alert if requested
send_alert

# Store last status
echo "$OVERALL_STATUS" > "${STATE_DIR}/last_status"

exit "$EXIT_CODE"
