#!/usr/bin/env bash
# =============================================================================
# drive-nmonit — Add a New Peer to the GlusterFS Cluster
# =============================================================================
# Run this on the PRIMARY node after setting up a new slave node.
#
# Usage:
#   1. On the new slave:   sudo ./scripts/setup-glusterfs.sh --join <primary-ip>
#   2. On the primary:     sudo ./templates/glusterfs-peer-add.sh <slave-ip>
#   3. On the primary:     sudo gluster volume add-brick workspace <slave-ip>:/mnt/local-pool
#   4. On the new slave:   sudo ./scripts/mount-all.sh
# =============================================================================
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <new-node-ip-or-hostname>"
    exit 1
fi

NEW_NODE="$1"

echo "=== Adding new peer: ${NEW_NODE} ==="

# Step 1: Probe the new node
echo "→ Probing ${NEW_NODE}..."
if gluster peer probe "$NEW_NODE"; then
    echo "✓ Peer added successfully"
else
    echo "✗ Peer probe failed. Check connectivity and that glusterd is running on ${NEW_NODE}."
    exit 1
fi

# Step 2: Wait for peer to be connected
echo "→ Waiting for peer connection..."
sleep 3

# Step 3: Show peer status
echo ""
gluster pool list

# Step 4: Add the brick to the volume
echo ""
echo "→ Adding brick ${NEW_NODE}:/mnt/local-pool to volume 'workspace'..."
if gluster volume add-brick workspace "${NEW_NODE}:/mnt/local-pool" force; then
    echo "✓ Brick added successfully"
else
    echo "✗ Failed to add brick. Check the volume status."
    echo "  Run: gluster volume info workspace"
    exit 1
fi

# Step 5: Verify
echo ""
echo "=== Updated Volume Info ==="
gluster volume info workspace
gluster volume status workspace

echo ""
echo "✓ New node ${NEW_NODE} has been added to the cluster!"
echo "  Run on the new node: sudo ./scripts/mount-all.sh"
