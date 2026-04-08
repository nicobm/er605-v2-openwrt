# Flash OpenWrt on TP-Link ER605 v2

> **Full guide (with post-install, encrypted DNS, ad blocking, NTP/NTS, and more):** [nicobm.github.io/er605-v2-openwrt](https://nicobm.github.io/er605-v2-openwrt)

## Requirements

- ER605 v2 with firmware **≤ 2.2.5** (2.2.6+ is blocked, no downgrade possible)
- Linux PC, ethernet cable, `ssh`, `curl`, `python3`, `md5sum`

## ⚠ Warnings

- **Keep WAN disconnected** the entire time — if the router reaches the internet, the local password stops working.
- **No factory recovery after flashing** — back up MTD partitions first (see full guide).
- **Power loss = brick** — use a stable power source.

## Password generation

Passwords are derived from the router's MAC address (`AA:BB:CC:DD:EE:FF` format, uppercase):

| Password | Formula |
|---|---|
| Root | `md5(MAC + username)` → first 16 chars |
| CLI debug (fw ≤ 2.1.2) | `md5(MAC + "admin")` → first 16 chars |
| CLI debug (fw 2.2.x) | `md5(MAC + "admin" + MAC + "admin")` → first 16 chars |

Use the [interactive password generator](https://nicobm.github.io/er605-v2-openwrt/#password-gen) to get your passwords instantly.

## Flash steps

**1. Download files (with internet)**

```bash
mkdir -p ~/er605_flash && cd ~/er605_flash
curl -o er605v2_write_initramfs.sh https://raw.githubusercontent.com/chill1Penguin/er605v2_openwrt_install/main/er605v2_write_initramfs.sh
curl -o openwrt-initramfs-compact.bin https://raw.githubusercontent.com/chill1Penguin/er605v2_openwrt_install/main/openwrt-initramfs-compact.bin
curl -o openwrt-25.12.2-sysupgrade.bin https://downloads.openwrt.org/releases/25.12.2/targets/ramips/mt7621/openwrt-25.12.2-ramips-mt7621-tplink_er605-v2-squashfs-sysupgrade.bin
```

**2. Disconnect WAN, connect PC to LAN, verify firmware ≤ 2.2.5** at `http://192.168.0.1`.

**3. Enable SSH** — System Tools → Diagnostics → Remote Assistance.

**4. SSH into the router**

```bash
ssh -o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa -c aes128-ctr admin@192.168.0.1
```

**5. Enter debug mode**

```
enable
debug
```

Paste the CLI debug password. You now have a root shell.

**6. Back up MTD partitions** — Without this, restoring stock requires soldering a UART console. See the [full guide's flash section](https://nicobm.github.io/er605-v2-openwrt/#flash-guide) for network and USB backup methods. Don't skip this.

**7. Serve files from your PC**

```bash
cd ~/er605_flash
python3 -m http.server 8080
```

> If curl times out: Fedora `sudo firewall-cmd --add-port=8080/tcp` / Ubuntu `sudo ufw allow 8080/tcp`.

**8. Download files on the router**

```bash
cd /tmp
curl -o er605v2_write_initramfs.sh http://YOUR_PC_IP:8080/er605v2_write_initramfs.sh
curl -o openwrt-initramfs-compact.bin http://YOUR_PC_IP:8080/openwrt-initramfs-compact.bin
chmod +x er605v2_write_initramfs.sh
```

**9. Verify checksum**

```bash
md5sum openwrt-initramfs-compact.bin
# Must be: e06dd6da68b739b2544931a0203292db
```

**10. Flash and reboot** ⚠ Point of no return

```bash
./er605v2_write_initramfs.sh openwrt-initramfs-compact.bin
reboot
```

Wait 2–3 minutes. The IP changes to **192.168.1.1**.

**11. Adjust UBI layout & flash sysupgrade 25.12.2** — Open `http://192.168.1.1`, click "Adjust UBI Layout" if it says "NOT ADJUSTED", upload the 25.12.2 sysupgrade image, **uncheck "Keep settings"**, and click Flash.

**Done.** LuCI is at `http://192.168.1.1` — login: **root**, password: *empty*.

---

Based on [chill1Penguin/er605v2_openwrt_install](https://github.com/chill1Penguin/er605v2_openwrt_install). Licensed under [GPL-2.0](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html).
