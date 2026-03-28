# PVE Homelab – Új Cluster Setup: Boot-Stabilitás Hardening Guide

> **Cél:** Ebbe a dokumentumba kerül minden konfiguráció amelyet egy fresh Proxmox cluster telepítésekor el kell végezni — **mielőtt** az első éles workload fut — hogy a 2026-03-09-es session során azonosított összes boot-stabilitási probléma elő sem fordulhasson.
>
> **Érvényes konfiguráció:** 3-node PVE cluster, Intel e1000e (pve-01/02), Realtek r8169 (pve-03), LXC unprivileged containers, PBS datastore, rclone offsite backup.

---

## Sorrend Áttekintés

```
1. PVE alap telepítés (minden node)
2. Cluster létrehozás + Corosync
3. Hálózati driver hardening (node-specifikus)
4. Quorum auto-recovery (pve-01)
5. PBS datastore helyes architektúra (pve-02)
6. LXC container konfiguráció
7. AppArmor hardening (pve-02)
8. CT startup order + onboot
9. Boot-check script telepítés
10. Első boot teszt
```

---

## 1. PVE Alap Telepítés (Minden Node)

### 1.1 Alapcsomagok

```bash
apt update && apt upgrade -y
apt install -y \
  ethtool \
  apparmor-utils \
  ifupdown2 \
  dkms \
  build-essential \
  curl wget git
```

### 1.2 ifupdown2 Telepítés — Boot Timing Fix

A standard `ifupdown` VLAN interfészek boot-time timing problémákat okoz. Az `ifupdown2` atomikusan hozza fel az összes interfészt:

```bash
apt install -y ifupdown2
ifreload -a
# Ellenőrzés
ip link show | grep "state UP"
```

### 1.3 SSH Kulcs Alapú Hozzáférés Node-ok Között

```bash
# pve-01-en: kulcs generálás
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""

# Kulcs másolás mindkét másik node-ra
ssh-copy-id root@10.10.40.12
ssh-copy-id root@10.10.40.13

# Teszt
ssh -o ConnectTimeout=3 root@10.10.40.12 hostname
ssh -o ConnectTimeout=3 root@10.10.40.13 hostname
```

---

## 2. Cluster Létrehozás + Corosync

### 2.1 Cluster Létrehozás (pve-01-en)

```bash
pvecm create homelab-cluster --link0 10.10.99.11
```

### 2.2 Node-ok Csatlakoztatása

```bash
# pve-02-n:
pvecm add 10.10.40.11 --link0 10.10.99.12

# pve-03-n:
pvecm add 10.10.40.11 --link0 10.10.99.13
```

### 2.3 Corosync Config Szinkron — Boot Előtti Kötelező Lépés

**Minden reboot előtt** szinkronizálni kell — ha nem egyezik a `config_version`, a corosync kilép:

```bash
# pve-01-en futtatva:
scp /etc/corosync/corosync.conf root@10.10.40.12:/etc/corosync/corosync.conf
scp /etc/corosync/corosync.conf root@10.10.40.13:/etc/corosync/corosync.conf
ssh root@10.10.40.12 "chmod 400 /etc/corosync/authkey"
ssh root@10.10.40.13 "chmod 400 /etc/corosync/authkey"
```

### 2.4 Corosync Verifikáció

```bash
pvecm status
# Nodes:       3
# Quorate:     Yes
# Total votes: 3
```

---

## 3. Hálózati Driver Hardening

### 3.1 Intel e1000e Nodes (pve-01, pve-02) — EEE Disable

**Probléma:** Az e1000e driver EEE (Energy Efficient Ethernet) bug miatt reboot után 10 Mbps-re lassulhat a link, megakadályozva a corosync kommunikációt.

```bash
# Alkalmazni kell MINDKÉT Intel NIC-es node-ra

# Azonnali fix
ethtool --set-eee nic0 eee off

# Systemd service — boot-perzisztens
cat > /etc/systemd/system/disable-eee.service << 'EOF'
[Unit]
Description=Disable EEE on nic0
After=network.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/sbin/ethtool --set-eee nic0 eee off

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now disable-eee.service

# Modprobe interrupt throttle
cat > /etc/modprobe.d/e1000e.conf << 'EOF'
options e1000e InterruptThrottleRate=3000
EOF

update-initramfs -u -k all

# Ellenőrzés
ethtool nic0 | grep Speed
# Speed: 1000Mb/s  ← kötelező
```

### 3.2 Realtek r8169 Node (pve-03) — Háromrétegű Fix

**Probléma:** A Realtek r8169 driver kernel 6.16+-on TX queue deadlockba kerülhet boot közben — a networking.service és a driver inicializáció versenyhelyzete miatt. Az r8168-dkms kernel 6.17.x-en nem fordítható (API breaking changes). Végleges megoldás Intel NIC csere.

**Workaround: 3 független, egymást kiegészítő réteg:**

```
Réteg 1: r8169-reload.service   → Before=networking, driver fresh reload
Réteg 2: udev 99-r8169-fix.rules → nic0 megjelenésekor azonnal offload fix
Réteg 3: r8169-fix.service      → After=networking, végső backup + ifreload
```

#### Réteg 1 — r8169-reload.service (pve-03)

```bash
cat > /etc/systemd/system/r8169-reload.service << 'EOF'
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
EOF
```

#### Réteg 2 — udev Rule (pve-03)

```bash
cat > /etc/udev/rules.d/99-r8169-fix.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="net", KERNEL=="nic0", \
  RUN+="/sbin/ip link set nic0 txqueuelen 10000", \
  RUN+="/sbin/ethtool -K nic0 tso off gso off gro off lro off rx off tx off"
EOF
```

#### Réteg 3 — r8169-fix.service (pve-03)

```bash
cat > /etc/systemd/system/r8169-fix.service << 'EOF'
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
EOF
```

#### Aktiválás (pve-03)

```bash
systemctl daemon-reload
systemctl enable r8169-reload.service r8169-fix.service
udevadm control --reload-rules

# Verifikáció
systemctl list-unit-files | grep r8169
# r8169-fix.service      enabled
# r8169-reload.service   enabled
```

---

## 4. Quorum Auto-Recovery (pve-01)

**Probléma:** Ha pve-01 egyedül bootol (pl. áramszünet után pve-02/03 még nem jött vissza), a 3-node cluster quorum nélkül indul — a CT-k blokkolva vannak.

```bash
cat > /etc/systemd/system/pve-quorum-recovery.service << 'EOF'
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
EOF

systemctl daemon-reload
systemctl enable pve-quorum-recovery.service
```

**Viselkedés:** Boot után 30s-cel ellenőriz. Ha csak 1 node online → `pvecm expected 1` → CT-k elindulnak. Amint a többi node csatlakozik, a quorum automatikusan helyreáll — nincs negatív mellékhatás.

---

## 5. PBS Datastore Helyes Architektúra (pve-02)

### 5.1 Miért NEM loop mount

A loop mount alapú PBS datastore architektúra strukturálisan hibás:

| Probléma | Oka |
|---|---|
| CT201 fut → loop device foglalt | Kettős mount nem lehetséges |
| CT204 üres forrásból szinkronizál | rclone törlési veszély pCloud-on |
| Boot-time timing | fstab loop mount és CT startup versenye |
| RO mount veszélye | `losetup --read-only` véletlenül is alkalmazható |

### 5.2 Helyes Architektúra — Host Shared Mappa

```bash
# 1. Host mappa létrehozás
mkdir -p /mnt/pbs-store

# 2. Ownership — unprivileged CT PBS UID mapping
# CT-n belül PBS user UID=34 → host-on UID=100034 (100000 + 34)
chown -R 100034:100034 /mnt/pbs-store

# 3. CT201 bind mount (RW — PBS ír)
pct set 201 -mp0 /mnt/pbs-store,mp=/var/lib/proxmox-backup/backups

# 4. CT204 bind mount (RO — rclone csak olvas)
pct set 204 -mp0 /mnt/pbs-store,mp=/mnt/pbs-backup,ro=1

# 5. Ellenőrzés
pct start 201
sleep 20
pct exec 201 -- bash -c 'touch /var/lib/proxmox-backup/backups/.test && echo "RW OK" && rm /var/lib/proxmox-backup/backups/.test'
```

### 5.3 PBS Retention Policy

```bash
# PBS 4.1.4+: csak prune job szinten konfigurálható
# (datastore update --keep-* már nem működik)
pct exec 201 -- proxmox-backup-manager prune-job update <JOB_ID> \
  --keep-last 3 \
  --keep-daily 14 \
  --keep-weekly 8 \
  --keep-monthly 6 \
  --keep-yearly 1
```

---

## 6. LXC Container Konfiguráció

### 6.1 Unprivileged Container Ownership Szabály

**Minden** host-mount esetén az ownership-et a container UID mapping szerint kell beállítani:

```
Host UID = 100000 + Container UID
Pl.: PBS daemon UID 34 → host chown 100034:100034
     www-data UID 33   → host chown 100033:100033
     root UID 0        → host chown 100000:100000
```

```bash
# Ellenőrzés — mi futtatja a service-t a CT-n belül?
pct exec <CTID> -- id <SERVICE_USER>
# Majd host-on:
chown -R 10000X:10000X /mnt/<host-dir>
```

### 6.2 Startup Order — pve-02

A startup order garantálja hogy a PBS elérhető mielőtt az rclone sync elindulna:

```bash
# CT201 pbs-server — elsőként, 60s várakozás (PBS init lassú)
pct set 201 --onboot 1 --startup order=10,up=60

# CT204 rclone-sync — PBS után
pct set 204 --onboot 1 --startup order=20,up=30

# CT208 grafana — utoljára, nem kritikus
pct set 208 --onboot 1 --startup order=30,up=20
```

### 6.3 Startup Order — pve-01

```bash
# CT101 adguard — DNS, elsőként kell
pct set 101 --onboot 1 --startup order=10,up=30

# CT106 tailscale — hálózat
pct set 106 --onboot 1 --startup order=20,up=30

# CT107 vaultwarden
pct set 107 --onboot 1 --startup order=30,up=20

# CT105 npm
pct set 105 --onboot 1 --startup order=40,up=20

# CT203 librenms
pct set 203 --onboot 1 --startup order=50,up=30
```

### 6.4 Startup Order — pve-03

```bash
# CT302 docker-host
pct set 302 --onboot 1 --startup order=10,up=60

# CT303 dev-environment
pct set 303 --onboot 1 --startup order=20,up=30
```

---

## 7. AppArmor Hardening (pve-02)

**Probléma:** Minden új host-szintű bind mount path-t explicit engedélyezni kell az AppArmor LXC profilban, különben a CT indítása DENIED hibával jár.

### 7.1 Profil Módosítás

```bash
# Backup
cp /etc/apparmor.d/lxc/lxc-default-cgns /etc/apparmor.d/lxc/lxc-default-cgns.bak

# Új bind mount path hozzáadása a záró } elé
# Módszer: tail/head kombináció — SOSEM sima append (}} utánra kerülne)
head -n -1 /etc/apparmor.d/lxc/lxc-default-cgns > /tmp/aa.tmp
cat >> /tmp/aa.tmp << 'EOF'
  # PBS store bind mount — /mnt/pbs-store
  mount options=(rw, rbind) /mnt/pbs-store/ -> /var/lib/proxmox-backup/backups/,
  mount options=(ro, rbind) /mnt/pbs-store/ -> /mnt/pbs-backup/,
}
EOF
mv /tmp/aa.tmp /etc/apparmor.d/lxc/lxc-default-cgns

# Szintaxis ellenőrzés
apparmor_parser -p /etc/apparmor.d/lxc/lxc-default-cgns && echo "SYNTAX OK"

# Betöltés — KÖTELEZŐEN parent profilon keresztül!
# (standalone betöltés sikertelen: @{PROC} változó nincs definiálva)
apparmor_parser -r /etc/apparmor.d/lxc-containers

# Verifikáció
aa-status | grep "lxc-container-default-cgns"
```

### 7.2 Általános Szabály Új Bind Mount-okhoz

```
Minden alkalommal, amikor új mp-t adsz egy CT-hez:
  1. Ellenőrizd: apparmor_parser -p /etc/apparmor.d/lxc/lxc-default-cgns
  2. Add hozzá a path-t a } elé
  3. Töltsd újra: apparmor_parser -r /etc/apparmor.d/lxc-containers
  4. Teszteld: pct stop X && pct start X
```

---

## 8. Boot-Check Script (pve-01)

Telepítés után az első boot ellenőrzése — és minden jövőbeli reboot után:

```bash
cat > /root/boot-check.sh << 'EOF'
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
EOF

chmod +x /root/boot-check.sh
```

**Elvárt clean output:**
```
ÖSSZEFOGLALÓ: 15 OK  |  0 FAIL
```

---

## 9. Ellenőrzési Checklist — Setup Befejezése Után

Futtasd sorban, minden pontnak PASS-t kell mutatni:

```bash
# 1. Cluster quorum
pvecm status | grep -E "Nodes|Quorate|Total votes"

# 2. NIC sebesség minden node-on
for n in 10.10.40.11 10.10.40.12 10.10.40.13; do
  ssh root@$n "echo \$HOSTNAME: && ethtool nic0 | grep Speed"
done

# 3. EEE státusz (pve-01, pve-02)
for n in 10.10.40.11 10.10.40.12; do
  ssh root@$n "echo \$HOSTNAME: && systemctl is-active disable-eee.service"
done

# 4. r8169 fix statusok (pve-03)
ssh root@10.10.40.13 "systemctl is-active r8169-reload.service r8169-fix.service"

# 5. Quorum recovery service (pve-01)
systemctl is-enabled pve-quorum-recovery.service

# 6. PBS write teszt
pct exec 201 -- bash -c 'touch /var/lib/proxmox-backup/backups/.test && echo "PBS RW OK" && rm /var/lib/proxmox-backup/backups/.test'

# 7. PBS ownership
ls -lan /mnt/pbs-store | head -3  # → 100034 100034

# 8. AppArmor profil (pve-02)
aa-status | grep "lxc-container-default-cgns"

# 9. CT onboot konfig
for n in 10.10.40.11 10.10.40.12 10.10.40.13; do
  ssh root@$n "pct list | grep -v VMID | while read vmid status lock name; do
    pct config \$vmid | grep -q 'onboot: 1' && echo \"CT\$vmid \$name: onboot OK\" || echo \"CT\$vmid \$name: HIÁNYZIK onboot\"
  done"
done

# 10. Teljes boot-check
./boot-check.sh
```

---

## 10. Ismert Korlátok és Ajánlott Fejlesztések

| Korlát | Kategória | Ajánlott Megoldás |
|---|---|---|
| pve-03 r8169 workaround | Hardware | Intel I210-AT PCIe NIC ~10€ |
| 3-node quorum single-boot | Design | UPS + watchdog vagy 5-node cluster |
| PBS single-node tárolás | DR | PBS replikáció második node-ra |
| Manuális corosync szinkron | Ops | `pve-cluster-reboot.sh` script automatizálja |
| Boot-check csak pve-01-ről | Ops | Crontab / systemd timer boot után automatikusan |

---

## Gyors Referencia — Fájlok és Helyek

| Fájl | Node | Funkció |
|---|---|---|
| `/etc/systemd/system/disable-eee.service` | pve-01, pve-02 | Intel e1000e EEE disable |
| `/etc/systemd/system/r8169-reload.service` | pve-03 | r8169 driver reload before network |
| `/etc/systemd/system/r8169-fix.service` | pve-03 | r8169 TX + offload fix after network |
| `/etc/udev/rules.d/99-r8169-fix.rules` | pve-03 | nic0 add event → azonnali fix |
| `/etc/systemd/system/pve-quorum-recovery.service` | pve-01 | Quorum auto-recovery |
| `/etc/apparmor.d/lxc/lxc-default-cgns` | pve-02 | LXC bind mount AppArmor profil |
| `/mnt/pbs-store/` | pve-02 | PBS datastore fizikai backing dir |
| `/root/boot-check.sh` | pve-01 | Post-boot cluster health check |
| `/usr/local/bin/pve-cluster-reboot.sh` | pve-01 | Ordered cluster reboot script |

---

*Dokumentálva: 2026-03-09 | homelab cluster | Fresh setup hardening guide*

