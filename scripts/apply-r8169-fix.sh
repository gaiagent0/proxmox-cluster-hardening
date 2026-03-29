#!/bin/bash
# ============================================================
# apply-r8169-fix.sh
# Applies the three-layer Realtek r8169 TX watchdog fix to
# a REMOTE node (pve-03) via SSH.
#
# Problem: r8169 on kernel 6.8+ enters a TX watchdog deadlock
# during boot if networking.service starts before the NIC is
# stable. r8168-dkms does not compile on kernel 6.8+ (API break).
# Long-term fix: replace with Intel I210-AT PCIe NIC (~EUR 10).
#
# Usage: bash scripts/apply-r8169-fix.sh root@10.10.40.13
# Source: https://github.com/gaiagent0/proxmox-cluster-hardening
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../configs/env"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
    echo "Usage: $0 root@<pve03-ip>"
    echo "Example: $0 root@${PVE03_IP:-10.10.40.13}"
    exit 1
fi

SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o ConnectTimeout=5 -o LogLevel=ERROR}"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"

# Detect NIC name from env
NIC="${PVE03_NIC:-nic0}"

echo "=== Realtek r8169 Three-Layer Fix ==="
echo "Target: $TARGET | NIC: $NIC"
echo ""

# ---- Verify SSH access ----
if ! ssh $SSH_OPTS "$TARGET" "hostname" &>/dev/null; then
    echo "ERROR: Cannot SSH to $TARGET"
    exit 1
fi
NODE=$(ssh $SSH_OPTS "$TARGET" "hostname")
echo "Connected: $NODE"
echo ""

# ---- Layer 1: r8169-reload.service ----
echo "[1/6] Installing r8169-reload.service (before networking)..."
ssh $SSH_OPTS "$TARGET" "cat > /etc/systemd/system/r8169-reload.service" << EOF
[Unit]
Description=r8169 driver reload before networking (TX watchdog prevention)
DefaultDependencies=no
Before=networking.service ifupdown2.service
After=sysinit.target kmod.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/sbin/modprobe -r r8169
ExecStart=/bin/sleep 2
ExecStart=/sbin/modprobe r8169
ExecStart=/bin/bash -c 'for i in \$(seq 1 20); do ip link show ${NIC} &>/dev/null && exit 0; sleep 1; done; exit 1'

[Install]
WantedBy=sysinit.target
EOF
echo "      OK: r8169-reload.service"

# ---- Layer 2: udev rule ----
echo "[2/6] Installing udev rule 99-r8169-fix.rules..."
ssh $SSH_OPTS "$TARGET" "cat > /etc/udev/rules.d/99-r8169-fix.rules" << EOF
# Immediately applies TX queue and offload fixes when nic appears
ACTION=="add", SUBSYSTEM=="net", KERNEL=="${NIC}", \\
  RUN+="/sbin/ip link set ${NIC} txqueuelen 10000", \\
  RUN+="/sbin/ethtool -K ${NIC} tso off gso off gro off lro off rx off tx off"
EOF
echo "      OK: 99-r8169-fix.rules"

# ---- Layer 3: r8169-fix.service ----
echo "[3/6] Installing r8169-fix.service (after networking)..."
ssh $SSH_OPTS "$TARGET" "cat > /etc/systemd/system/r8169-fix.service" << EOF
[Unit]
Description=r8169 TX queue length and offload fix (post-networking)
After=networking.service sys-subsystem-net-devices-${NIC}.device
Wants=sys-subsystem-net-devices-${NIC}.device

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/sbin/ip link set ${NIC} txqueuelen 10000
ExecStart=/sbin/ethtool -K ${NIC} tso off gso off gro off lro off rx off tx off
ExecStart=/sbin/ip link set ${NIC} master vmbr0
ExecStart=/usr/sbin/ifreload -a

[Install]
WantedBy=multi-user.target
EOF
echo "      OK: r8169-fix.service"

# ---- Enable services ----
echo "[4/6] Enabling services..."
ssh $SSH_OPTS "$TARGET" "systemctl daemon-reload && \
    systemctl enable r8169-reload.service r8169-fix.service"
echo "      OK: services enabled"

# ---- Reload udev ----
echo "[5/6] Reloading udev rules..."
ssh $SSH_OPTS "$TARGET" "udevadm control --reload-rules"
echo "      OK: udev reloaded"

# ---- Apply TX queue immediately ----
echo "[6/6] Applying TX queue fix immediately (no reboot needed)..."
ssh $SSH_OPTS "$TARGET" "
    ip link set ${NIC} txqueuelen 10000 2>/dev/null && echo '      OK: txqueuelen=10000' || echo '      WARN: txqueuelen set failed'
    ethtool -K ${NIC} tso off gso off gro off lro off rx off tx off 2>/dev/null && echo '      OK: offloads disabled' || echo '      WARN: offload set failed'
"

echo ""
echo "=== r8169 Fix Applied to $NODE ==="
echo ""
echo "Verify:"
echo "  ssh $TARGET 'systemctl list-unit-files | grep r8169'"
echo "  ssh $TARGET 'ip -s link show ${NIC}'"
echo ""
echo "NOTE: The fix becomes fully effective after the next reboot."
echo "      After reboot, verify NIC comes up within 60 seconds."
echo "      Long-term: replace NIC with Intel I210-AT PCIe (~EUR 10)"
