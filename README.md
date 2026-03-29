# proxmox-cluster-hardening

> **Boot-stability hardening for a 3-node Proxmox VE cluster on mini-PC hardware.**  
> Covers Intel e1000e EEE bugs, Realtek r8169 TX-queue deadlocks, quorum auto-recovery, ordered reboot automation, and a post-boot health-check script.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![PVE](https://img.shields.io/badge/Proxmox_VE-8.x-orange)](https://www.proxmox.com)
[![Kernel](https://img.shields.io/badge/Kernel-6.8%2B-green)](https://kernel.org)

---

## Problem Statement

Mini-PC Proxmox clusters (e.g. N100/N305/Ryzen) share a common failure pattern after unplanned shutdowns or kernel updates:

| Root cause | Symptom | Affected hardware |
|---|---|---|
| Intel e1000e EEE bug | NIC retrains to 10 Mbps after reboot | I219-LM/V, I211-AT |
| Realtek r8169 TX watchdog deadlock | NIC disappears after networking.service race | RTL8111/8168 (kernel 6.8+) |
| Corosync `config_version` drift | Node refuses to rejoin cluster | All nodes |
| Single-node boot without quorum | All LXCs blocked at startup | All nodes |
| LXC `onboot` not set | Services silently absent after reboot | Any node |

This repo eliminates all five failure modes via persistent systemd services, udev rules, and automation scripts.

---

## Cluster Topology (reference)

```
pve-01  10.10.40.11   Intel e1000e   Master / CT: adguard, npm, tailscale, vaultwarden, librenms
pve-02  10.10.40.12   Intel e1000e   Backup / CT: pbs-server, grafana, rclone-sync
pve-03  10.10.40.13   Realtek r8169  Lab    / CT: docker-host, dev-environment
```

Adapt IP addresses and node roles to your environment. See [docs/variables.md](docs/variables.md).

---

## Quick Start

```bash
# 1. Clone on pve-01
git clone https://github.com/gaiagent0/proxmox-cluster-hardening.git
cd proxmox-cluster-hardening

# 2. Edit environment variables
cp configs/env.example configs/env
nano configs/env   # set NODE_IPs, NIC names

# 3. Apply Intel EEE fix (pve-01 and pve-02)
bash scripts/apply-eee-fix.sh

# 4. Apply r8169 fix (pve-03 only)
bash scripts/apply-r8169-fix.sh root@10.10.40.13

# 5. Apply quorum auto-recovery (pve-01)
bash scripts/apply-quorum-recovery.sh

# 6. Deploy boot-check script
cp scripts/boot-check.sh /root/boot-check.sh
chmod +x /root/boot-check.sh

# 7. Verify
/root/boot-check.sh
# Expected: ÖSSZEFOGLALÓ: 15 OK | 0 FAIL
```

---

## Repository Structure

```
proxmox-cluster-hardening/
├── README.md
├── docs/
│   ├── variables.md          — IP / NIC name substitution guide
│   ├── eee-fix.md            — Intel e1000e EEE deep-dive
│   ├── r8169-fix.md          — Realtek r8169 three-layer fix
│   ├── quorum-recovery.md    — Quorum auto-recovery design
│   ├── corosync-sync.md      — Corosync config_version drift prevention
│   ├── apparmor-bind-mounts.md — AppArmor LXC bind-mount rules
│   └── boot-recovery-runbook.md — Emergency recovery procedures
├── scripts/
│   ├── apply-eee-fix.sh      — Intel EEE disable (local node)
│   ├── apply-r8169-fix.sh    — r8169 three-layer fix (remote node)
│   ├── apply-quorum-recovery.sh
│   ├── pve-cluster-reboot.sh — Ordered cluster reboot with pre/post checks
│   └── boot-check.sh         — Post-boot health check (15 assertions)
├── templates/
│   ├── systemd/
│   │   ├── disable-eee.service
│   │   ├── r8169-reload.service
│   │   ├── r8169-fix.service
│   │   └── pve-quorum-recovery.service
│   ├── udev/
│   │   └── 99-r8169-fix.rules
│   └── apparmor/
│       └── lxc-default-cgns.patch — Bind-mount path additions
└── configs/
    └── env.example           — All configurable variables
```

---

## Hardening Components

### 1. Intel e1000e EEE Disable

**Problem:** After reboot (not poweroff), the I219-LM/V PHY re-negotiates at 10 Mbps due to an EEE state persistence bug. Corosync on VLAN 99 becomes unreachable → cluster split-brain.

**Fix:** Systemd oneshot service runs `ethtool --set-eee nic0 eee off` at every boot, before corosync starts.

```bash
cp templates/systemd/disable-eee.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now disable-eee.service
```

See [docs/eee-fix.md](docs/eee-fix.md) for full diagnosis and verification steps.

### 2. Realtek r8169 Three-Layer Fix

**Problem:** r8169 on kernel 6.8+ enters a TX watchdog deadlock during boot if `networking.service` starts before the NIC is stable. The r8168-dkms alternative does not compile on kernel 6.8+ (API breaking changes in `from_timer()`/`skb_gso_segment`). Long-term fix: replace with an Intel I210-AT PCIe NIC (~€10).

**Workaround (three independent layers):**

| Layer | File | Trigger | Effect |
|---|---|---|---|
| 1 | `r8169-reload.service` | `Before=networking.service` | Fresh driver load before network stack |
| 2 | `99-r8169-fix.rules` | udev `nic0 add` event | Immediate `txqueuelen` + offload disable |
| 3 | `r8169-fix.service` | `After=networking.service` | Backup: master re-attach + `ifreload` |

```bash
bash scripts/apply-r8169-fix.sh root@PVE03_IP
```

### 3. Quorum Auto-Recovery

**Problem:** If only one node boots (e.g. rolling restart or power failure), the 3-node cluster requires 2 votes for quorum. All LXCs with `onboot=1` remain blocked indefinitely.

**Fix:** `pve-quorum-recovery.service` waits 30 s post-boot, checks quorum, and runs `pvecm expected 1` if the node is alone. Once other nodes join, quorum self-corrects with no side effects.

### 4. Ordered Cluster Reboot

`scripts/pve-cluster-reboot.sh` performs a safe rolling reboot:

1. Syncs corosync `config_version` to all nodes
2. Reboots pve-03 → waits for SSH + corosync + quorum
3. Reboots pve-02 → same checks
4. Reboots pve-01 (local, last)

Includes interactive confirmation prompts and automatic corosync restart if a node comes back degraded.

### 5. Boot-Check Script

`scripts/boot-check.sh` runs 15 assertions across all three nodes:

- Cluster quorum (Quorate: Yes)
- All LXCs in `running` state
- NIC speed 1000 Mb/s on all nodes
- PBS datastore write-test

---

## Security Notes

- Scripts use `ssh -o StrictHostKeyChecking=no` for automation convenience — replace with proper host-key pinning in production.
- The quorum recovery service only acts when `Total votes < 2`. It cannot create a split-brain.
- All `corosync.conf` syncs copy from pve-01 (designated master). Never edit corosync config on secondary nodes directly.

---

## Known Limitations

| Issue | Status | Mitigation |
|---|---|---|
| r8169 fix is a workaround | Hardware dependent | Replace NIC: Intel I210-AT PCIe ~€10 |
| boot-check must run from pve-01 | Ops limitation | Add systemd timer for auto-run |
| Corosync sync is manual pre-reboot | Ops | `pve-cluster-reboot.sh` automates this |

---

## References

- [Proxmox VE Cluster Manager](https://pve.proxmox.com/wiki/Cluster_Manager)
- [Intel e1000e EEE bug report](https://bugzilla.kernel.org/show_bug.cgi?id=61471)
- [r8169 TX watchdog — kernel mailing list](https://lkml.org/lkml/2023/6/1/1)

---

*Tested on: Proxmox VE 8.3, kernel 6.8.12-4-pve / 6.17.x-pve | Intel N100 / N305 mini-PCs*
