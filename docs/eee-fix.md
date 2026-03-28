# README-pve-e1000e-eee-fix
<!-- TARTALOM HIÁNYZIK — másolja be ide a claude.ai projektből -->
# PVE Cluster – Kernel Update Utáni Hálózati Kiesés – Teljes Diagnózis és Megoldás

> **Dátum:** 2026-02-25 / 2026-02-26  
> **Érintett node-ok:** pve-01, pve-02, pve-03  
> **Kernel:** 6.17.x-pve  
> **NIC driver:** Intel e1000e (I219-LM/V)

---

## TL;DR – Gyors összefoglaló

A kernel update utáni reboot után a node-ok hálózata kiesett, a corosync cluster szétesett. A gyökérok az **Intel e1000e driver EEE (Energy Efficient Ethernet) bug** volt, ami miatt a NIC reboot után **10 Mbps**-re lassult gigabit helyett. Poweroff javította, egyszerű reboot nem.

---

## 1. Tünetek

| Tünet | Megjelenés |
|-------|-----------|
| Reboot után hálózat kiesik | VLAN interfészek nem jönnek fel |
| Poweroff után minden OK, reboot után nem | PHY nem resetelődik rebootnál |
| Corosync "Activity blocked" | VLAN99 ping nem megy node-ok között |
| `pvecm status` → 1/3 vagy 2/3 votes | Quorum elveszett |
| `ethtool nic0 \| grep Speed` → **10 Mbps** | EEE bug aktív |
| Web UI shell másik node-on nem megy | Cluster SSH kulcs probléma |

---

## 2. Gyökérok – Intel e1000e EEE Bug

### Mi ez?

Az **Energy Efficient Ethernet (EEE)** egy energiatakarékossági funkció ami idle állapotban lekapcsolja a fizikai linket. Az Intel I219-LM/V chipeken (e1000e driver) egy ismert bug miatt Linux kernel reboot után a NIC **10 Mbps**-re tárgyal a switch-csel gigabit helyett.

### Miért javít a poweroff?

- **Reboot:** A PHY (fizikai réteg) nem resetelődik teljesen – az EEE state megmarad → 10 Mbps
- **Poweroff:** Az áramellátás megszakad → PHY teljes reset → gigabit újratárgyalás

### Hogyan diagnosztizálható?

```bash
# NIC sebesség ellenőrzés
ethtool nic0 | grep Speed
# BUG: Speed: 10Mb/s
# OK:  Speed: 1000Mb/s

# tcpdump - ARP kérések mennek ki de nem jön válasz
tcpdump -i nic0 -nn vlan and host 10.10.99.11 -c 5

# Kernel log - 10 Mbps jelzés
dmesg | grep -i "10 Mbps\|Link is Up\|e1000e"
```

---

## 3. Corosync Config Verzió Probléma

### Mi ez?

Ha egy node offline volt miközben a cluster configja változott, a `/etc/corosync/corosync.conf` fájl `config_version` értéke eltér. A corosync csatlakozáskor észleli és kilép:

```
[CMAP] Received config version (11) is different than my config version (7)! Exiting
```

### Diagnosztika

```bash
# Minden node-on futtasd:
grep config_version /etc/corosync/corosync.conf
# Értékeknek egyezni kell!
```

### Javítás

```bash
# pve-01-en futtasd:
scp /etc/corosync/corosync.conf root@10.10.40.12:/etc/corosync/corosync.conf
scp /etc/corosync/corosync.conf root@10.10.40.13:/etc/corosync/corosync.conf
```

---

## 4. Tartós Javítás – Minden Node-on Alkalmazandó

### 4.1 EEE Kikapcsolás – Azonnali

```bash
ethtool --set-eee nic0 eee off
ethtool nic0 | grep Speed
# Kell: Speed: 1000Mb/s
```

### 4.2 EEE Disable Systemd Service – Boot Utáni Auto Fix

```bash
cat > /etc/systemd/system/disable-eee.service << 'EOF'
[Unit]
Description=Disable EEE on nic0
After=network.target

[Service]
ExecStart=/sbin/ethtool --set-eee nic0 eee off
Type=oneshot
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now disable-eee.service
systemctl status disable-eee.service
```

### 4.3 e1000e Driver Interrupt Throttle – Modprobe

```bash
cat > /etc/modprobe.d/e1000e.conf << 'EOF'
options e1000e InterruptThrottleRate=3000
EOF

update-initramfs -u -k all
```

### 4.4 TSO/GSO Offload Kikapcsolás – /etc/network/interfaces

```bash
nano /etc/network/interfaces
```

Az `iface nic0 inet manual` sor alá add hozzá:

```
iface nic0 inet manual
    post-up ethtool -K nic0 tso off gso off gro off rxvlan off txvlan off
```

Alkalmaz:
```bash
ifreload -a
```

### 4.5 ifupdown2 Újratelepítés – VLAN Boot Timing Fix

```bash
apt install --reinstall ifupdown2 -y
ifreload -a
```

---

## 5. Corosync Helyreállítás – Sorban

```bash
# 1. Config verzió ellenőrzés
grep config_version /etc/corosync/corosync.conf

# 2. authkey jogosultság
chmod 400 /etc/corosync/authkey

# 3. Helyes sorrendű újraindítás
systemctl stop pve-cluster
systemctl stop corosync
pkill -9 corosync 2>/dev/null; true
sleep 3
systemctl daemon-reload
systemctl start corosync
sleep 10
systemctl start pve-cluster

# 4. Ellenőrzés
pvecm status
```

---

## 6. Biztonságos Cluster Reboot – Sorrend

### Reboot ELŐTT – minden node-ra (pve-01-en futtatva):

```bash
# Corosync config szinkron
scp /etc/corosync/corosync.conf root@10.10.40.12:/etc/corosync/corosync.conf
scp /etc/corosync/corosync.conf root@10.10.40.13:/etc/corosync/corosync.conf
ssh root@10.10.40.12 "chmod 400 /etc/corosync/authkey"
ssh root@10.10.40.13 "chmod 400 /etc/corosync/authkey"

# rclone-sync leállítás (pve-02-n)
ssh root@10.10.40.12 "qm shutdown 204 --timeout 30"
```

### Reboot sorrend:

```
1. pve-03 (docker-host, dev-environment)
2. pve-02 (pbs-server, grafana, rclone-sync)
3. pve-01 (adguard, tailscale, vaultwarden) ← UTOLJÁRA
```

### Reboot script futtatása:

```bash
bash pve-cluster-reboot.sh
```

### Reboot UTÁN – ellenőrzés:

```bash
pvecm status          # 3/3 Quorate: Yes
ethtool nic0 | grep Speed  # 1000Mb/s
pct list && qm list   # minden VM/LXC running
```

---

## 7. Konzol Vészhelyzeti Parancsok

Ha SSH nem elérhető – fizikai konzolról (Alt+F1/F2 váltás konzolok között):

```bash
# Hálózat kézi fel
systemctl restart networking
sleep 5
ip a | grep "10.10"

# Ha VLAN IP-k hiányoznak – kézi hozzáadás
ip link set vmbr0.40 up
ip addr add 10.10.40.XX/24 dev vmbr0.40
ip route add default via 10.10.40.1
ip link set vmbr0.99 up
ip addr add 10.10.99.XX/24 dev vmbr0.99

# EEE azonnali fix
ethtool --set-eee nic0 eee off
ethtool nic0 | grep Speed

# NIC sebesség kézi force
ethtool -s nic0 speed 1000 duplex full autoneg on
```

> **IP-k:** pve-01=.11, pve-02=.12, pve-03=.13

---

## 8. Ismert Hibák és Megoldásaik

| Hiba | Ok | Megoldás |
|------|-----|----------|
| `10 Mbps` reboot után | e1000e EEE bug | EEE disable service |
| `config_version` eltérés | Node offline volt config változáskor | scp corosync.conf pve-01-ről |
| `Activity blocked` quorum | VLAN99 nem elérhető | networking restart + EEE fix |
| `corosync.service not found` | daemon-reload hiányzik | `systemctl daemon-reload` |
| `Another corosync instance running` | Régi process él | `pkill -9 corosync` |
| VLAN interfészek hiányoznak boot után | ifupdown2 timing bug | `apt reinstall ifupdown2` |
| Web UI shell másik node-on nem megy | Cluster SSH kulcs sérült | `pvecm updatecerts --force` |
| AppArmor blokkolja tcpdump/corosync | Kernel update új policy | `systemctl stop apparmor` (debug) |
| Poweroff javít, reboot nem | PHY nem resetelődik | EEE + modprobe fix permanensen |

---

## 9. Node Referencia

| Node | IP (MGMT) | IP (Corosync) | VM-ek / LXC-k |
|------|-----------|----------------|----------------|
| pve-01-Master | 10.10.40.11 | 10.10.99.11 | adguard, tailscale, vaultwarden, npm, librenms |
| pve-02-Backup | 10.10.40.12 | 10.10.99.12 | pbs-server, grafana, rclone-sync |
| pve-03-LAB | 10.10.40.13 | 10.10.99.13 | docker-host, dev-environment |

---

## 10. Eszközök

| Fájl | Leírás |
|------|--------|
| `pve-cluster-reboot.sh` | Automatikus cluster reboot script – corosync sync + hálózat ellenőrzés |
| `pve-recovery-tool.html` | Offline GUI – böngészőben megnyitva egy kattintásos parancsok |

---

*Dokumentálva: 2026-02-26 | homelab cluster | Intel e1000e EEE bug fix*
