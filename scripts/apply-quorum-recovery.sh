#!/bin/bash
# ============================================================
# apply-quorum-recovery.sh
# Installs the pve-quorum-recovery.service on the LOCAL node
# (intended for pve-01, the cluster master).
#
# Problem: If only one node boots (e.g. rolling restart or power
# failure), the 3-node cluster requires 2 votes for quorum.
# All LXCs with onboot=1 remain blocked indefinitely.
#
# Fix: This service waits 30s post-boot, checks quorum, and runs
# `pvecm expected 1` if the node is alone. Once other nodes join,
# quorum self-corrects with no side effects.
#
# Usage: bash scripts/apply-quorum-recovery.sh
# Source: https://github.com/gaiagent0/proxmox-cluster-hardening
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates/systemd"
SERVICE_DST="/etc/systemd/system/pve-quorum-recovery.service"

echo "=== PVE Quorum Auto-Recovery Setup ==="
echo ""

# ---- Check: running on a PVE node? ----
if ! command -v pvecm &>/dev/null; then
    echo "ERROR: pvecm not found. Run this on a Proxmox VE node."
    exit 1
fi

# ---- Install service ----
echo "[1/3] Installing pve-quorum-recovery.service..."

SERVICE_SRC="${TEMPLATE_DIR}/pve-quorum-recovery.service"

if [ -f "$SERVICE_SRC" ]; then
    cp "$SERVICE_SRC" "$SERVICE_DST"
    echo "      OK: copied from template"
else
    # Create inline
    cat > "$SERVICE_DST" << 'EOF'
[Unit]
Description=PVE Quorum Auto-Recovery
Documentation=https://github.com/gaiagent0/proxmox-cluster-hardening
After=corosync.service pve-cluster.service
Requires=corosync.service

[Service]
Type=oneshot
# Wait for corosync to attempt syncing with other nodes
ExecStartPre=/bin/sleep 30
# If node is alone and quorum is lost, temporarily set expected=1
# to allow LXCs to start. Quorum auto-heals when other nodes join.
ExecStart=/bin/bash -c '\
  QUORATE=$(pvecm status 2>/dev/null | grep "Quorate:" | awk "{print \$2}"); \
  VOTES=$(pvecm status 2>/dev/null | grep "Total votes:" | awk "{print \$3}"); \
  if [ "$QUORATE" = "No" ] && [ "${VOTES:-0}" -lt 2 ]; then \
    logger -t pve-quorum-recovery "Alone node detected (votes=${VOTES}) — setting expected=1"; \
    pvecm expected 1; \
  else \
    logger -t pve-quorum-recovery "Quorum OK (Quorate=$QUORATE, votes=$VOTES) — no action needed"; \
  fi'
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF
    echo "      OK: created inline"
fi

# ---- Enable service ----
echo "[2/3] Enabling pve-quorum-recovery.service..."
systemctl daemon-reload
systemctl enable pve-quorum-recovery.service
echo "      OK: service enabled (will activate on next boot)"

# ---- Verify ----
echo "[3/3] Verifying..."
IS_ENABLED=$(systemctl is-enabled pve-quorum-recovery.service 2>/dev/null)
if [ "$IS_ENABLED" = "enabled" ]; then
    echo "      OK: pve-quorum-recovery.service is enabled"
else
    echo "      WARN: unexpected state: $IS_ENABLED"
fi

echo ""
echo "=== Quorum Recovery Setup Complete ==="
echo ""
echo "Current cluster status:"
pvecm status 2>/dev/null | grep -E "Nodes:|Quorate:|Total votes:" || echo "  (pvecm status unavailable)"
echo ""
echo "Behavior on next boot:"
echo "  - If all 3 nodes are up:          no action taken"
echo "  - If this node boots alone:        pvecm expected 1 (LXCs start)"
echo "  - When other nodes rejoin:         quorum auto-heals (expected resets)"
echo ""
echo "View logs:  journalctl -u pve-quorum-recovery"
echo "Check:      systemctl status pve-quorum-recovery.service"
