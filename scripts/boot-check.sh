#!/bin/bash
# ============================================================
# PVE Boot Check — 15-assertion cluster health verification
# Run on pve-01 as root after any cluster reboot.
# Source: https://github.com/YOUR_USER/proxmox-cluster-hardening
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../configs/env"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

# Defaults if env not loaded
PVE01_IP=${PVE01_IP:-10.10.40.11}
PVE02_IP=${PVE02_IP:-10.10.40.12}
PVE03_IP=${PVE03_IP:-10.10.40.13}
SSH_OPTS=${SSH_OPTS:-"-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o LogLevel=ERROR"}
PBS_CT_ID=${PBS_CT_ID:-201}
PBS_TEST_PATH=${PBS_TEST_PATH:-"/var/lib/proxmox-backup/backups/.boot-test"}

PASS=0
FAIL=0
SSH="ssh $SSH_OPTS"

ok()   { echo "  [OK]   $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "=== PVE Boot Check $(date) ==="

# ---- 1. Cluster quorum ----
echo ""
echo "--- Cluster ---"
pvecm status 2>/dev/null | grep -E "Nodes:|Quorate:|Total votes:" || true
QUORATE=$(pvecm status 2>/dev/null | grep "Quorate:" | awk '{print $2}')
[ "$QUORATE" = "Yes" ] && ok "Quorum: Yes" || fail "Quorum: No (run: pvecm expected 1)"

# ---- 2–10. LXC status per node ----
echo ""
echo "--- LXC Status ---"
for n in "$PVE01_IP" "$PVE02_IP" "$PVE03_IP"; do
    NODE=$($SSH root@"$n" hostname 2>/dev/null)
    if [ -z "$NODE" ]; then
        fail "Node $n unreachable via SSH"
        continue
    fi
    echo "  [$NODE]"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        STATUS=$(echo "$line" | awk '{print $2}')
        NAME=$(echo "$line"   | awk '{print $3}')
        if [ "$STATUS" = "running" ]; then
            ok "  $NAME running"
        else
            fail "  $NAME → $STATUS"
        fi
    done < <($SSH root@"$n" "pct list | grep -v VMID" 2>/dev/null)
done

# ---- 11–13. NIC speed ----
echo ""
echo "--- NIC Speed ---"
for n in "$PVE01_IP" "$PVE02_IP" "$PVE03_IP"; do
    NODE=$($SSH root@"$n" hostname 2>/dev/null)
    SPEED=$($SSH root@"$n" "ethtool nic0 2>/dev/null | awk '/Speed:/{print \$2}'" 2>/dev/null)
    if echo "$SPEED" | grep -q "1000"; then
        ok "$NODE NIC: $SPEED"
    else
        fail "$NODE NIC: ${SPEED:-unknown} (expected 1000Mb/s — check EEE fix)"
    fi
done

# ---- 14. Corosync on all nodes ----
echo ""
echo "--- Corosync ---"
for n in "$PVE01_IP" "$PVE02_IP" "$PVE03_IP"; do
    NODE=$($SSH root@"$n" hostname 2>/dev/null)
    STATUS=$($SSH root@"$n" "systemctl is-active corosync" 2>/dev/null)
    [ "$STATUS" = "active" ] && ok "$NODE corosync: active" || fail "$NODE corosync: $STATUS"
done

# ---- 15. PBS write test ----
echo ""
echo "--- PBS Datastore ---"
PBSTEST=$($SSH root@"$PVE02_IP" \
    "pct exec $PBS_CT_ID -- bash -c \
    'touch $PBS_TEST_PATH && rm $PBS_TEST_PATH && echo OK'" 2>/dev/null)
[ "$PBSTEST" = "OK" ] && ok "PBS datastore RW" || fail "PBS datastore RW failed"

# ---- Summary ----
echo ""
echo "======================================="
echo "  RESULT: ${PASS} OK  |  ${FAIL} FAIL"
echo "======================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
