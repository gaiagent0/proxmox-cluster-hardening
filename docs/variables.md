# Variables Reference — IP and NIC Name Substitution

> Adapt the scripts and templates in this repo to your cluster by editing `configs/env`.

---

## How to Configure

```bash
# Copy the example config:
cp configs/env.example configs/env

# Edit your values:
nano configs/env
```

The `configs/env` file is loaded by all scripts (`pve-cluster-reboot.sh`, `boot-check.sh`, `apply-eee-fix.sh`, `apply-r8169-fix.sh`, `apply-quorum-recovery.sh`) via:

```bash
source "$(dirname "$0")/../configs/env"
```

`configs/env` is listed in `.gitignore` — never commit it.

---

## Variable Reference

### Node IP Addresses

| Variable | Default | Description |
|---|---|---|
| `PVE01_IP` | `10.10.40.11` | pve-01 management IP (SERVERS VLAN) |
| `PVE02_IP` | `10.10.40.12` | pve-02 management IP |
| `PVE03_IP` | `10.10.40.13` | pve-03 management IP |
| `PVE01_COROSYNC_IP` | `10.10.99.11` | pve-01 Corosync ring IP (dedicated VLAN) |
| `PVE02_COROSYNC_IP` | `10.10.99.12` | pve-02 Corosync ring IP |
| `PVE03_COROSYNC_IP` | `10.10.99.13` | pve-03 Corosync ring IP |

### NIC Names

| Variable | Default | Description |
|---|---|---|
| `PVE01_NIC` | `nic0` | Primary NIC name on pve-01 |
| `PVE02_NIC` | `nic0` | Primary NIC name on pve-02 |
| `PVE03_NIC` | `nic0` | Primary NIC name on pve-03 (Realtek r8169) |

**Find your NIC names:**

```bash
# On each Proxmox node:
ip link show | grep -E '^[0-9]+:' | awk '{print $2}' | tr -d ':'
# Common values: nic0, eth0, eno1, enp3s0, enp0s31f6
```

### SSH and Timing

| Variable | Default | Description |
|---|---|---|
| `SSH_OPTS` | `-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o LogLevel=ERROR` | SSH options for node-to-node automation |
| `POST_REBOOT_WAIT` | `20` | Seconds after issuing `reboot` before polling SSH |
| `NODE_WAIT_TIMEOUT` | `240` | Max seconds to wait for a node to come back |
| `COROSYNC_SYNC_WAIT` | `30` | Seconds after SSH returns, before checking corosync |

### LXC IDs (for boot-check)

| Variable | Default | Description |
|---|---|---|
| `PVE01_CT_IDS` | `"101 105 106 107 203"` | Space-separated LXC IDs to verify on pve-01 |
| `PVE02_CT_IDS` | `"201 204 208"` | LXC IDs to verify on pve-02 |
| `PVE03_CT_IDS` | `"302 303"` | LXC IDs to verify on pve-03 |

### PBS Write Test

| Variable | Default | Description |
|---|---|---|
| `PBS_CT_ID` | `201` | PBS server LXC ID |
| `PBS_TEST_PATH` | `/var/lib/proxmox-backup/backups/.boot-test` | Temporary test file path inside CT |

---

## Reference Cluster Topology

This repo is developed and tested against:

```
pve-01  10.10.40.11   Intel e1000e   Master / CT: adguard, npm, tailscale, vaultwarden, librenms
pve-02  10.10.40.12   Intel e1000e   Backup / CT: pbs-server, grafana, rclone-sync
pve-03  10.10.40.13   Realtek r8169  Lab    / CT: docker-host, dev-environment

Corosync ring: VLAN 99 (10.10.99.0/24)
Management:    VLAN 40 (10.10.40.0/24)
```

---

## Adapting to Your Cluster

Typical substitutions needed:

| If your setup has... | Change these variables |
|---|---|
| Different IP subnet | `PVE01_IP`, `PVE02_IP`, `PVE03_IP` + Corosync IPs |
| Different NIC names | `PVE01_NIC`, `PVE02_NIC`, `PVE03_NIC` |
| Different CT IDs | `PVE01_CT_IDS`, `PVE02_CT_IDS`, `PVE03_CT_IDS` |
| All Intel NICs | Set all `*_NIC` variables, skip r8169 fix on pve-03 |
| 2-node cluster | Adjust `check_quorum` calls in scripts to expect 2 |
| Different PBS CT ID | `PBS_CT_ID` |

---

*All scripts source `configs/env` and fall back to the default values shown above if the file is not present.*
