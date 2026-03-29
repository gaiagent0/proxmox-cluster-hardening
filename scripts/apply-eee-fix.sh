#!/bin/bash
# ============================================================
# apply-eee-fix.sh
# Applies the Intel e1000e EEE (Energy Efficient Ethernet) fix
# to the LOCAL node (run on pve-01 and pve-02 separately).
#
# Problem: After reboot (not poweroff), the I219-LM/V PHY
# re-negotiates at 10 Mbps due to an EEE state persistence bug.
# Corosync on VLAN 99 becomes unreachable → cluster split-brain.
#
# Usage: bash scripts/apply-eee-fix.sh
# Source: https://github.com/gaiagent0/proxmox-cluster-hardening
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../configs/env"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

# Detect NIC name from env or fallback to nic0
# On this node, check which variable applies (pve-01 or pve-02)
NODE_IP=$(ip -4 addr show | awk '/inet 10\.10\.40/ {print $2}' | cut -d/ -f1 | head -1)
case "$NODE_IP" in
    "${PVE01_IP:-10.10.40.11}") NIC="${PVE01_NIC:-nic0}" ;;
    "${PVE02_IP:-10.10.40.12}") NIC="${PVE02_NIC:-nic0}" ;;
    *)                           NIC="nic0" ;;
esac

TEMPLATE_DIR="${SCRIPT_DIR}/../templates/systemd"

echo "=== Intel e1000e EEE Fix ==="
echo "Node IP: $NODE_IP | NIC: $NIC"
echo ""

# ---- Step 1: Immediate EEE disable ----
echo "[1/5] Disabling EEE immediately..."
if ethtool --set-eee "$NIC" eee off 2>/dev/null; then
    SPEED=$(ethtool "$NIC" 2>/dev/null | awk '/Speed:/{print $2}')
    echo "      OK: EEE disabled. NIC speed: $SPEED"
    if [[ "$SPEED" != "1000Mb/s" ]]; then
        echo "      WARN: Speed is not 1000Mb/s — manual check needed"
    fi
else
    echo "      WARN: ethtool EEE set failed (NIC may not support it or name is wrong)"
    echo "      Check NIC name with: ip link show"
fi

# ---- Step 2: systemd service ----
echo "[2/5] Installing disable-eee.service..."
SERVICE_SRC="${TEMPLATE_DIR}/disable-eee.service"
SERVICE_DST="/etc/systemd/system/disable-eee.service"

if [ ! -f "$SERVICE_SRC" ]; then
    # Create inline if template not found
    cat > "$SERVICE_DST" << EOF
[Unit]
Description=Disable EEE on ${NIC}
After=network.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/sbin/ethtool --set-eee ${NIC} eee off

[Install]
WantedBy=multi-user.target
EOF
else
    # Use template, substitute NIC name
    sed "s/nic0/${NIC}/g" "$SERVICE_SRC" > "$SERVICE_DST"
fi

systemctl daemon-reload
systemctl enable disable-eee.service
systemctl start disable-eee.service
echo "      OK: disable-eee.service enabled and started"

# ---- Step 3: modprobe e1000e options ----
echo "[3/5] Setting e1000e interrupt throttle..."
cat > /etc/modprobe.d/e1000e.conf << 'EOF'
# Reduce interrupt rate to avoid TX watchdog issues under load
options e1000e InterruptThrottleRate=3000
EOF
echo "      OK: /etc/modprobe.d/e1000e.conf written"

# ---- Step 4: TSO/GSO offload disable in /etc/network/interfaces ----
echo "[4/5] Checking /etc/network/interfaces for offload settings..."
if grep -q "tso off" /etc/network/interfaces; then
    echo "      OK: Offload settings already present"
else
    # Check if the NIC iface line exists
    if grep -q "iface ${NIC} inet manual" /etc/network/interfaces; then
        sed -i "/iface ${NIC} inet manual/a\\    post-up ethtool -K ${NIC} tso off gso off gro off rxvlan off txvlan off" \
            /etc/network/interfaces
        echo "      OK: Offload disable added to /etc/network/interfaces"
    else
        echo "      INFO: NIC ${NIC} not found in /etc/network/interfaces — add manually if needed:"
        echo "            post-up ethtool -K ${NIC} tso off gso off gro off rxvlan off txvlan off"
    fi
fi

# ---- Step 5: update-initramfs ----
echo "[5/5] Updating initramfs (for modprobe options)..."
update-initramfs -u -k all 2>&1 | tail -3
echo "      OK: initramfs updated"

echo ""
echo "=== EEE Fix Applied ==="
echo ""
echo "Verify:"
echo "  ethtool $NIC | grep -E 'Speed|EEE'"
echo "  systemctl status disable-eee.service"
echo ""
echo "IMPORTANT: This fix is effective immediately."
echo "           After next reboot, verify: ethtool $NIC | grep Speed"
echo "           Expected: Speed: 1000Mb/s"
