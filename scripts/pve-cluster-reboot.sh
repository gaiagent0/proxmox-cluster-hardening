#!/bin/bash
# ============================================================
# PVE Homelab – Ordered Cluster Reboot Script v2
# Run on pve-01 as root: bash pve-cluster-reboot.sh
# ============================================================
# Source: https://github.com/YOUR_USER/proxmox-cluster-hardening
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../configs/env"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: configs/env not found. Copy configs/env.example to configs/env and edit it."
    exit 1
fi
# shellcheck source=../configs/env
source "$ENV_FILE"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
ok()     { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()    { echo -e "${RED}[ERROR]${NC} $1"; }
banner() { echo -e "\n${CYAN}============================================\n  $1\n============================================${NC}\n"; }

# -----------------------------------------------------------
# COROSYNC CONFIG SYNC — before reboot
# -----------------------------------------------------------
sync_corosync_config() {
    local target_ip=$1
    local node=$2
    log "Corosync config sync → $node..."

    local local_ver remote_ver
    local_ver=$(grep config_version /etc/corosync/corosync.conf | awk '{print $2}')
    remote_ver=$(ssh $SSH_OPTS root@"$target_ip" \
        "grep config_version /etc/corosync/corosync.conf" 2>/dev/null | awk '{print $2}')

    log "  local config_version: $local_ver | $node: $remote_ver"

    if [ "$local_ver" != "$remote_ver" ]; then
        warn "  Version mismatch — syncing to $node..."
        scp $SSH_OPTS /etc/corosync/corosync.conf root@"$target_ip":/etc/corosync/corosync.conf
        ok "  Corosync config updated → $node (v$local_ver)"
    else
        ok "  Corosync config version matches (v$local_ver)"
    fi

    local authkey_perm
    authkey_perm=$(ssh $SSH_OPTS root@"$target_ip" \
        "stat -c '%a' /etc/corosync/authkey" 2>/dev/null)
    if [ "$authkey_perm" != "400" ]; then
        warn "  authkey permissions wrong ($authkey_perm) → fixing..."
        ssh $SSH_OPTS root@"$target_ip" "chmod 400 /etc/corosync/authkey"
        ok "  authkey permissions fixed (400)"
    else
        ok "  authkey permissions OK (400)"
    fi
}

# -----------------------------------------------------------
# WAIT FOR NODE
# -----------------------------------------------------------
wait_for_node() {
    local ip=$1
    local node=$2
    local max=$(( NODE_WAIT_TIMEOUT / 10 ))
    log "Waiting for $node ($ip) to come back..."
    for i in $(seq 1 $max); do
        if ssh $SSH_OPTS root@"$ip" "exit" 2>/dev/null; then
            echo ""
            ok "$node reachable via SSH"
            log "Waiting for corosync sync (+${COROSYNC_SYNC_WAIT}s)..."
            sleep "$COROSYNC_SYNC_WAIT"
            return 0
        fi
        echo -n "."
        sleep 10
    done
    echo ""
    err "$node did not come back within ${NODE_WAIT_TIMEOUT}s!"
    exit 1
}

# -----------------------------------------------------------
# NETWORK CHECK POST-REBOOT
# -----------------------------------------------------------
check_network() {
    local ip=$1
    local node=$2
    log "$node network check..."
    local ifaces
    ifaces=$(ssh $SSH_OPTS root@"$ip" "ip a | grep 'inet 10.10'" 2>/dev/null)
    # Adapt grep patterns to your VLAN subnets
    if echo "$ifaces" | grep -q "10.10.40" && echo "$ifaces" | grep -q "10.10.99"; then
        ok "$node network OK (MGMT + Corosync VLANs up)"
    else
        warn "$node VLAN interface missing — restarting networking..."
        ssh $SSH_OPTS root@"$ip" "systemctl restart networking" 2>/dev/null
        sleep 10
        ifaces=$(ssh $SSH_OPTS root@"$ip" "ip a | grep 'inet 10.10'" 2>/dev/null)
        if echo "$ifaces" | grep -q "10.10.40" && echo "$ifaces" | grep -q "10.10.99"; then
            ok "$node network OK after networking restart"
        else
            err "$node network still missing! Manual intervention required."
            read -rp "Fixed? Continue? (yes/no): " fix
            [ "$fix" != "yes" ] && exit 1
        fi
    fi
}

# -----------------------------------------------------------
# COROSYNC CHECK POST-REBOOT
# -----------------------------------------------------------
check_corosync() {
    local ip=$1
    local node=$2
    log "$node corosync check..."
    local status
    status=$(ssh $SSH_OPTS root@"$ip" "systemctl is-active corosync" 2>/dev/null)
    if [ "$status" = "active" ]; then
        ok "$node corosync running"
    else
        warn "$node corosync not running — syncing config and restarting..."
        scp $SSH_OPTS /etc/corosync/corosync.conf root@"$ip":/etc/corosync/corosync.conf
        ssh $SSH_OPTS root@"$ip" "chmod 400 /etc/corosync/authkey && systemctl restart corosync"
        sleep 10
        status=$(ssh $SSH_OPTS root@"$ip" "systemctl is-active corosync" 2>/dev/null)
        if [ "$status" = "active" ]; then
            ok "$node corosync restarted OK"
        else
            err "$node corosync still not running! Manual intervention required."
            exit 1
        fi
    fi
}

# -----------------------------------------------------------
# QUORUM CHECK
# -----------------------------------------------------------
check_quorum() {
    local expected=$1
    log "Cluster quorum check..."
    local votes
    votes=$(pvecm status 2>/dev/null | grep "Total votes:" | awk '{print $3}')
    if [ "$votes" = "$expected" ]; then
        ok "Quorum OK — $votes/$expected nodes online"
    else
        err "Quorum FAIL — only $votes/$expected nodes online"
        exit 1
    fi
}

# -----------------------------------------------------------
# VM/LXC STATUS SUMMARY
# -----------------------------------------------------------
check_vms_running() {
    local node_ip=$1
    local node=$2
    log "$node — VM/LXC status:"
    ssh $SSH_OPTS root@"$node_ip" "qm list; pct list" 2>/dev/null | grep -v "^$" | \
        while read -r line; do echo "  $line"; done
}

# ===========================================================
# MAIN
# ===========================================================

clear
banner "PVE Homelab – Cluster Reboot v2"

echo -e "${YELLOW}Reboot order:${NC}"
echo "  1. pve-03 ($PVE03_IP) — lab / docker-host"
echo "  2. pve-02 ($PVE02_IP) — backup / PBS"
echo "  3. pve-01 (local)     — master / DNS / VPN"
echo ""
warn "WARNING: pve-01 reboot causes ~2 min DNS outage (AdGuard)!"
echo ""

# Step 0: Corosync sync to all nodes
banner "0/3 — Pre-flight: Corosync config sync"
sync_corosync_config "$PVE03_IP" "pve-03"
sync_corosync_config "$PVE02_IP" "pve-02"
ok "Corosync config in sync on all nodes"

echo ""
read -rp "Proceed with reboots? (yes/no): " confirm
[ "$confirm" != "yes" ] && echo "Aborted." && exit 0

# Step 1: pve-03
banner "1/3 — PVE-03 reboot (Lab)"
log "Rebooting pve-03..."
ssh $SSH_OPTS root@"$PVE03_IP" "reboot" 2>/dev/null || true
sleep 5
log "Waiting for pve-03 to go down..."
sleep "$POST_REBOOT_WAIT"
wait_for_node "$PVE03_IP" "pve-03"
check_network "$PVE03_IP" "pve-03"
check_corosync "$PVE03_IP" "pve-03"
sleep 10
check_quorum 3
check_vms_running "$PVE03_IP" "pve-03"
ok "pve-03 reboot DONE ✓"

read -rp "Proceed with pve-02? (yes/no): " c2
[ "$c2" != "yes" ] && echo "Aborted." && exit 0

# Step 2: pve-02
banner "2/3 — PVE-02 reboot (Backup)"
log "Stopping rclone-sync CT (204)..."
ssh $SSH_OPTS root@"$PVE02_IP" "pct shutdown 204 --timeout 30" 2>/dev/null || true
ok "rclone-sync stopped"
sleep 5

log "Rebooting pve-02..."
ssh $SSH_OPTS root@"$PVE02_IP" "reboot" 2>/dev/null || true
sleep 5
sleep "$POST_REBOOT_WAIT"
wait_for_node "$PVE02_IP" "pve-02"
check_network "$PVE02_IP" "pve-02"
check_corosync "$PVE02_IP" "pve-02"
sleep 10
check_quorum 3
check_vms_running "$PVE02_IP" "pve-02"
ok "pve-02 reboot DONE ✓"

read -rp "Proceed with pve-01 (local, SSH will drop)? (yes/no): " c3
[ "$c3" != "yes" ] && echo "Aborted." && exit 0

# Step 3: pve-01 (local)
banner "3/3 — PVE-01 reboot (Master)"
warn "Local node — SSH connection will drop!"
warn "After reboot, verify: pvecm status && pct list && qm list"
echo ""
log "Rebooting in 10 seconds... (Ctrl+C to cancel)"
for i in 10 9 8 7 6 5 4 3 2 1; do echo -ne "  $i...\r"; sleep 1; done
echo ""
reboot
