# PVE Homelab – Unplanned Shutdown Recovery & Boot Stabilitás

> **Dátum:** 2026-03-09  
> **Érintett node-ok:** pve-01, pve-02, pve-03  
> **Kernel:** 6.17.13-1-pve  
> **Esemény:** Tervezett leállítás + boot recovery session  
> **Végeredmény:** 15/15 OK — `boot-check.sh` clean pass ✅

---

## TL;DR

Az áramtalanítás utáni boot során **6 független kritikus hiba** lépett fel egyszerre. A rendszer 5+ óra alatt állt helyre teljesen. A hibák gyökéroka: nem tesztelt boot path, Realtek NIC driver instabilitás kernel 6.17.x-en, AppArmor profil hiány új bind mount path-ra, RO loop device blokkolta CT201 indítását, PBS ownership eltérés, és CT208 hiányzó onboot konfiguráció.

---

## 1. Infrastruktúra Referencia

| Node | IP (MGMT) | IP (Corosync) | NIC Driver | CT-k |
|------|-----------|----------------|------------|------|
| pve-01 | 10.10.40.11 | 10.10.99.11 | Intel e1000e | 101 adguard, 105 npm, 106 tailscale, 107 vaultwarden, 203 librenms |
| pve-02 | 10.10.40.12 | 10.10.99.12 | Intel e1000e | 201 pbs-server, 204 rclone-sync, 208 grafana |
| pve-03 | 10.10.40.13 | 10.10.99.13 | **Realtek r8169** | 302 docker-host, 303 dev-environment |

---

## 2. Boot Failure Analízis — Teljes Hibatérkép

### 2.1 pve-01 — Quorum Elveszett

**Tünet:**
```
pvecm status → Nodes: 1, Quorate: No, "Activity blocked"
CT-k nem indulnak automatikusan
```

**Root cause:** 3-node cluster 2 vote-ot vár quorumhoz. Egyedül induló pve-01 csak 1 vote-tal rendelkezik → minden CT startup blokkolva.

**Azonnali fix:**
```bash
pvecm expected 1
```

**Tartós fix:** `pve-quorum-recovery.service` → lásd 4.1

---

### 2.2 pve-03 — r8169 TX Queue Timeout → Nincs Hálózat

**Tünet:**
```
dmesg: r8169 NETDEV WATCHDOG: CPU: transmit queue timed out
       rtl_rxtx_empty_cond == 0 (loop: 42, delay: 100)
       can't disable ASPM; OS doesn't have ASPM control
ping 10.10.40.1 → 100% packet loss
ip link show → nic0 hiányzik (driver crash után az OS sem látja)
```

**Root cause — Boot Sequence Versenyhelyzet:**
```
T+0s   kernel: r8169 driver betölt → nic0 regisztrálódik
T+1s   r8169: TX watchdog timer indul
T+2s   networking.service fut: "bridge port nic0 does not exist"
        → vmbr0 slave nélkül konfigurálódik
T+3s   r8169: TX queue deadlock → rtl_rxtx_empty_cond freeze
T+4s   r8169-fix.service fut: "Cannot find device nic0"
        → driver már crash-elt, nic0 eltűnt
T+∞    Nincs hálózat, corosync nem csatlakozik, cluster 2/3
```

**Miért nem r8168-dkms?**

Az r8168/8.051.02 (Debian bookworm) nem fordítható kernel 6.17.x-en:
```
r8168_n.c: error: 'esd_timer' undeclared (from_timer() API törölve 6.16+-ban)
r8168_n.c: error: implicit declaration of function 'skb_gso_segment'
make: Error 2
```

**Hosszú távú megoldás:** Intel PCIe NIC csere (I210-AT ~10€).

**Tartós fix:** 3 rétegű megoldás → lásd 4.2

**Manuális helyreállítás fizikai konzolon:**
```bash
dmesg -n 1
modprobe -r r8169; sleep 2; modprobe r8169; sleep 3
systemctl restart networking
ping -c 3 10.10.40.1
```

---

### 2.3 pve-02 CT201 — Loop Device RO Mount

**Tünet:**
```
pct start 201 → "Failed to run lxc.hook.pre-start"
lxc: "unable to open file '/fastboot.tmp': Read-only file system"
losetup -l → /dev/loop3  RO=1
```

**Root cause:** Korábbi `losetup --read-only` hívás eredménye — a loop3 RO-ra csatolt állapotban maradt.

**Fix:**
```bash
losetup -d /dev/loop3
systemctl stop 'mnt-pbs\x2ddata.mount'
systemctl disable 'mnt-pbs\x2ddata.mount'
rm '/etc/systemd/system/mnt-pbs\x2ddata.mount'
systemctl daemon-reload
pct start 201
```

---

### 2.4 pve-02 CT201 — PBS Permission Denied

**Tünet:**
```
pct exec 201 -- touch /var/lib/proxmox-backup/backups/.test
→ Permission denied
```

**Root cause:** `/mnt/pbs-store/` ownership `root:root`. Unprivileged CT-n belül PBS UID 34 → host UID 100034 → nincs write jog.

**Fix:**
```bash
chown -R 100034:100034 /mnt/pbs-store
pct reboot 201
```

---

### 2.5 pve-02 CT204 — AppArmor DENIED Bind Mount

**Tünet:**
```
dmesg: apparmor="DENIED" operation="mount" error=-13
       profile="lxc-204_</var/lib/lxc>"
```

**Root cause:** `/mnt/pbs-store/` path nem szerepelt az AppArmor `lxc-default-cgns` profilban.

**Fix:**
```bash
# Szabályok hozzáadása a záró } elé
head -n -1 /etc/apparmor.d/lxc/lxc-default-cgns > /tmp/aa.tmp
cat >> /tmp/aa.tmp << 'EOF'
  mount options=(rw, rbind) /mnt/pbs-store/ -> /var/lib/proxmox-backup/backups/,
  mount options=(ro, rbind) /mnt/pbs-store/ -> /mnt/pbs-backup/,
}
EOF
mv /tmp/aa.tmp /etc/apparmor.d/lxc/lxc-default-cgns
# Betöltés parent profilon keresztül (standalone nem működik)
apparmor_parser -r /etc/apparmor.d/lxc-containers
```

---

### 2.6 CT208 Grafana — Hiányzó Onboot Konfiguráció

**Tünet:** CT208 minden boot után `stopped`.

**Fix:**
```bash
pct set 208 --onboot 1 --startup order=30,up=20
```

---

## 3. PBS Datastore Architektúra

### Helyes Architektúra

```
pve-02 host:
  /mnt/pbs-store/           ← fizikai host mappa
  ownership: 100034:100034
       │
       ├── bind mount (RW) → CT201 /var/lib/proxmox-backup/backups/
       └── bind mount (RO) → CT204 /mnt/pbs-backup/
```

### Bind Mount Konfiguráció

```bash
pct set 201 -mp0 /mnt/pbs-store,mp=/var/lib/proxmox-backup/backups
pct set 204 -mp0 /mnt/pbs-store,mp=/mnt/pbs-backup,ro=1
```

### Ellenőrzés

```bash
pct exec 201 -- bash -c 'touch /var/lib/proxmox-backup/backups/.test && echo "RW OK" && rm /var/lib/proxmox-backup/backups/.test'
pct exec 204 -- ls /mnt/pbs-backup/ | head -3
```

---

## 4. Telepített Boot-Stabilitás Megoldások

### 4.1 pve-01 — Quorum Auto-Recovery Service

**Fájl:** `/etc/systemd/system/pve-quorum-recovery.service`

```ini
[Unit]
Description=PVE Quorum Auto-Recovery
After=corosync.service pve-cluster.service
Requires=corosync.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 30
ExecStart=/bin/bash -c '\
  QUORATE=$(pvecm status 2>/dev/null | grep "Quorate:" | awk "{print \$2}"); \
  VOTES=$(pvecm status 2>/dev/null | grep "Total votes:" | awk "{print \$3}"); \
  if [ "$QUORATE" = "No" ] && [ "${VOTES:-0}" -lt 2 ]; then \
    logger "pve-quorum-recovery: setting expected=1"; \
    pvecm expected 1; \
  fi'
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload && systemctl enable pve-quorum-recovery.service
```

---

### 4.2 pve-03 — r8169 Háromrétegű Boot Fix

**Architektúra:**
```
Réteg 1: r8169-reload.service   Before=networking → driver reload, nic0 stabilizálás
Réteg 2: udev 99-r8169-fix.rules → nic0 add event → azonnali offload fix
Réteg 3: r8169-fix.service      After=networking → végső backup + ifreload
```

#### Réteg 1: r8169-reload.service

```ini
[Unit]
Description=r8169 driver reload before networking
DefaultDependencies=no
Before=networking.service ifupdown2.service
After=sysinit.target kmod.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/sbin/modprobe -r r8169
ExecStart=/bin/sleep 2
ExecStart=/sbin/modprobe r8169
ExecStart=/bin/bash -c 'for i in $(seq 1 20); do ip link show nic0 &>/dev/null && exit 0; sleep 1; done; exit 1'

[Install]
WantedBy=sysinit.target
```

#### Réteg 2: udev Rule

**Fájl:** `/etc/udev/rules.d/99-r8169-fix.rules`

```
ACTION=="add", SUBSYSTEM=="net", KERNEL=="nic0", \
  RUN+="/sbin/ip link set nic0 txqueuelen 10000", \
  RUN+="/sbin/ethtool -K nic0 tso off gso off gro off lro off rx off tx off"
```

#### Réteg 3: r8169-fix.service

```ini
[Unit]
Description=r8169 TX queue and offload fix
After=networking.service sys-subsystem-net-devices-nic0.device
Wants=sys-subsystem-net-devices-nic0.device

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/sbin/ip link set nic0 txqueuelen 10000
ExecStart=/sbin/ethtool -K nic0 tso off gso off gro off lro off rx off tx off
ExecStart=/sbin/ip link set nic0 master vmbr0
ExecStart=/usr/sbin/ifreload -a

[Install]
WantedBy=multi-user.target
```

#### Aktiválás

```bash
systemctl daemon-reload
systemctl enable r8169-reload.service r8169-fix.service
udevadm control --reload-rules
```

---

### 4.3 Boot-Check Script

**Fájl:** `/root/boot-check.sh` (pve-01-en)

```bash
#!/bin/bash
PASS=0; FAIL=0
ok()   { echo "  [OK]   $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
SSH="ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o LogLevel=ERROR"

echo "=== PVE Boot Check $(date) ==="

echo ""; echo "--- Cluster ---"
pvecm status | grep -E "Nodes:|Quorate:|Total votes:"
QUORATE=$(pvecm status 2>/dev/null | grep "Quorate:" | awk '{print $2}')
if [ "$QUORATE" = "Yes" ]; then ok "Quorum: Yes"; else fail "Quorum: No"; fi

echo ""; echo "--- CT Státusz ---"
for n in 10.10.40.11 10.10.40.12 10.10.40.13; do
  NODE=$($SSH root@$n hostname 2>/dev/null)
  if [ -z "$NODE" ]; then fail "Node $n nem elérhető"; continue; fi
  echo "  [$NODE]"
  while read -r line; do
    [ -z "$line" ] && continue
    STATUS=$(echo "$line" | awk '{print $2}')
    NAME=$(echo "$line" | awk '{print $3}')
    if [ "$STATUS" = "running" ]; then ok "  $NAME running"
    else fail "  $NAME → $STATUS"; fi
  done < <($SSH root@$n "pct list | grep -v VMID" 2>/dev/null)
done

echo ""; echo "--- NIC Sebesség ---"
for n in 10.10.40.11 10.10.40.12 10.10.40.13; do
  NODE=$($SSH root@$n hostname 2>/dev/null)
  SPEED=$($SSH root@$n "ethtool nic0 2>/dev/null | awk '/Speed:/{print \$2}'" 2>/dev/null)
  if echo "$SPEED" | grep -q "1000"; then ok "$NODE NIC: $SPEED"
  else fail "$NODE NIC: ${SPEED:-ismeretlen}"; fi
done

echo ""; echo "--- PBS Write Test ---"
PBSTEST=$($SSH root@10.10.40.12 \
  "pct exec 201 -- bash -c 'touch /var/lib/proxmox-backup/backups/.boot-test \
  && rm /var/lib/proxmox-backup/backups/.boot-test && echo OK'" 2>/dev/null)
if [ "$PBSTEST" = "OK" ]; then ok "PBS datastore RW"; else fail "PBS datastore RW"; fi

echo ""
echo "======================================="
echo "  ÖSSZEFOGLALÓ: ${PASS} OK  |  ${FAIL} FAIL"
echo "======================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
```

```bash
chmod +x /root/boot-check.sh
```

---

## 5. Vészhelyzeti Helyreállítás Runbook

### 5.1 Quorum elveszett

```bash
# pve-01 fizikai konzolon
pvecm expected 1
sleep 30 && pvecm status | grep Quorate
```

### 5.2 pve-03 hálózat nem jön fel

```bash
dmesg -n 1
modprobe -r r8169; sleep 2; modprobe r8169; sleep 3
systemctl restart networking
ping -c 3 10.10.40.1
```

### 5.3 CT201 loop device konfliktus

```bash
losetup -l
losetup -d /dev/loopX
systemctl stop 'mnt-pbs\x2ddata.mount' 2>/dev/null
pct start 201
```

### 5.4 CT204 AppArmor mount denied

```bash
aa-complain /usr/bin/lxc-start   # gyors workaround
apparmor_parser -r /etc/apparmor.d/lxc-containers  # végleges
pct restart 204
```

### 5.5 PBS permission denied

```bash
chown -R 100034:100034 /mnt/pbs-store
pct reboot 201
```

---

## 6. Rendszerállapot Összefoglaló

| Komponens | Helye | Státusz |
|---|---|---|
| EEE disable (pve-01/02) | `/etc/systemd/system/disable-eee.service` | ✅ enabled |
| r8169 driver reload (pve-03) | `/etc/systemd/system/r8169-reload.service` | ✅ enabled |
| r8169 udev fix (pve-03) | `/etc/udev/rules.d/99-r8169-fix.rules` | ✅ aktív |
| r8169 offload fix (pve-03) | `/etc/systemd/system/r8169-fix.service` | ✅ enabled |
| Quorum recovery (pve-01) | `/etc/systemd/system/pve-quorum-recovery.service` | ✅ enabled |
| PBS backing store | `/mnt/pbs-store/` pve-02 | ✅ RW, 100034 |
| CT201 bind mount | `mp0: /mnt/pbs-store,...` | ✅ RW |
| CT204 bind mount | `mp0: /mnt/pbs-store,...,ro=1` | ✅ RO |
| AppArmor profil | `/etc/apparmor.d/lxc/lxc-default-cgns` | ✅ pbs-store |
| CT startup order (pve-02) | 201→204→208, onboot=1 | ✅ mind beállítva |
| PBS retention policy | prune-job `default-backups-*` | ✅ 14d/8w/6m/1y |
| Boot-check script | `/root/boot-check.sh` (pve-01) | ✅ 15/15 OK |

---

*Dokumentálva: 2026-03-09 | homelab cluster | 6 boot failure → 15/15 OK*

