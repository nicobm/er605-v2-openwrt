# TP-Link ER605 v2 → OpenWrt — flashing + GUI configuration

Two-part repo to get a **TP-Link ER605 v2** running OpenWrt and hardened,
without needing SSH for the configuration:

1. **Flashing** — replace TP-Link's stock firmware with OpenWrt. Specific to the ER605 v2 hardware.
2. **Minimal GUI configuration (LuCI)** — closed firewall, encrypted DNS (DoH), AdBlock, WireGuard and NTP with NTS. **All through the web, no SSH.**

> **Full interactive guide:** open **[`https://nicobm.github.io/er605-v2-openwrt`](https://nicobm.github.io/er605-v2-openwrt)** — it includes the password generator (runs 100% in your browser) and the GUI configuration step by step. The page is bilingual: English by default, with a toggle to Spanish.
>
> This README is the condensed version.

The idea is minimalist: **I only list what I change. Everything else I don't mention is fine on its defaults.**

---

## 1. Flashing OpenWrt on the ER605

> This is the only part that needs a PC and SSH, and only once. The whole configuration below (Part 2) is done entirely through the LuCI web GUI.

### Requirements

- ER605 v2 on firmware **≤ 2.2.5** (2.2.6+ is locked, no downgrade possible).
- A Linux PC, an ethernet cable, `ssh`, `curl`, `python3`, `md5sum`.

### ⚠ Warnings

- **Keep WAN disconnected** the whole time — if the router reaches the internet, TP-Link requires an online-signed token and the locally generated password stops working.
- **No factory recovery after flashing** — back up the MTD partitions first (see the full guide). Without that backup, restoring stock requires soldering a UART serial console.
- **Power loss = brick** — use a stable power source (a UPS if you have one) and don't unplug anything.

### Firmware compatibility

The hardware revision (V2.0, V2.20, etc.) does **not** matter; only the firmware version does.

| Firmware | Status | Root access |
|---|---|---|
| ≤ 2.0.1 | ✅ Works | Direct root login with the "root password" |
| 2.1.1 – 2.2.5 | ✅ Works | GUI login + `enable` + `debug` + CLI debug password |
| 2.2.6 | ❌ Locked | Local password generator patched out |
| 2.3.0 – 2.3.3 | ❌ Locked | RSA-signed tokens + anti-rollback |

### Password generation

Derived from the router's MAC (format `AA:BB:CC:DD:EE:FF`, uppercase). The generator in the HTML computes them in your browser, nothing is sent anywhere.

| Password | Formula |
|---|---|
| Root | `md5(MAC + username)` → first 16 chars |
| CLI debug (fw ≤ 2.1.2) | `md5(MAC + "admin")` → first 16 chars |
| CLI debug (fw 2.2.x) | `md5(MAC + "admin" + MAC + "admin")` → first 16 chars |

### Flash steps (condensed)

1. **Download everything (with internet)** — initramfs image, flash script and sysupgrade:
   ```bash
   mkdir -p ~/er605_flash && cd ~/er605_flash
   curl -o openwrt-initramfs-compact.bin https://raw.githubusercontent.com/chill1Penguin/er605v2_openwrt_install/main/openwrt-initramfs-compact.bin
   curl -LO https://downloads.openwrt.org/releases/25.12.4/targets/ramips/mt7621/openwrt-25.12.4-ramips-mt7621-tplink_er605-v2-squashfs-sysupgrade.bin
   ```
   For the flash script, the full guide ships a safer POSIX rewrite (validates the image, verifies every write byte by byte and asks for confirmation). As an alternative, the original script:
   ```bash
   curl -o er605v2_write_initramfs.sh https://raw.githubusercontent.com/chill1Penguin/er605v2_openwrt_install/main/er605v2_write_initramfs.sh
   chmod +x er605v2_write_initramfs.sh
   ```
   Verify the initramfs: `md5sum openwrt-initramfs-compact.bin` → `e06dd6da68b739b2544931a0203292db`.

2. **Disconnect WAN**, connect the PC to a LAN port and confirm firmware ≤ 2.2.5 at `http://192.168.0.1`.

3. **Enable SSH** — System Tools → Diagnostics → Remote Assistance.

4. **Connect over SSH** (with legacy-algorithm flags):
   ```bash
   ssh -o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa -c aes128-ctr admin@192.168.0.1
   ```
   Then: `enable`, `debug`, and paste the CLI debug password → root shell.

5. **Back up the MTD partitions** (strongly recommended). Network methods (netcat) are in the full guide.

6. **Serve the files** from your PC and pull them onto the router:
   ```bash
   cd ~/er605_flash && python3 -m http.server 8080
   ```

7. **Flash** (point of no return, don't cut the power):
   ```bash
   ./er605v2_write_initramfs.sh openwrt-initramfs-compact.bin
   reboot
   ```

8. **OpenWrt installer** — open `http://192.168.1.1` (the IP changed from `192.168.0.1`), do **Adjust UBI Layout** if needed, upload the **25.12.4** sysupgrade with **"Keep settings" unchecked** and Flash. After the reboot: **LuCI** at `http://192.168.1.1`, log in as `root`.

### Back to stock

The restore command depends on **how the backup was made** (`ubiformat` vs `mtd write`). Using the wrong one can destroy the NAND bad-block table and brick the router. Check the [MTD backup documentation](https://github.com/chill1Penguin/er605v2_openwrt_install/blob/main/MTD_backup/README.md) before restoring.

---

## 2. Minimal GUI configuration (LuCI)

With OpenWrt up and LuCI at `http://192.168.1.1`. **Everything here is done in the web GUI — no SSH, no CLI.** Only what I change:

1. **Password** — log in as `root` and change the router password.
2. **Firmware online checking → off.**
3. **Firewall: WAN → DROP** — Network → Firewall → Zones → the `wan` zone → **Input: drop** (it ships as `reject`).
4. **Kill the ping** — Network → Firewall → Traffic Rules → **Allow-Ping** → disable.
5. **Software flow offloading** — this one is **not** a traffic rule, it's a single checkbox: **Network → Firewall → General Settings** → under **Routing/NAT Offloading** tick **Software flow offloading**. It puts established connections on a kernel fastpath — on the MT7621 it's roughly the difference between ~300 Mbps and near-gigabit routing.
6. **Disable IPv6** — we don't use it, so remove it in two places:
   - **Network → Interfaces** → delete the `wan6` interface (the IPv6 one on WAN).
   - **Network → Interfaces → LAN → Edit → DHCP Server → IPv6 Settings**: set `RA-Service` to `disabled` and `DHCPv6-Service` to `disabled`. The LAN stops handing out IPv6 and the router runs IPv4-only.
7. **DNS over HTTPS** — in **System → Software**, install `luci-app-https-dns-proxy`. Installing it is enough (the router's DNS now leaves encrypted to Cloudflare). **Then make it exclusive:** by default the WAN still injects your ISP's plaintext DNS, so some queries leak unencrypted. Go to **Network → Interfaces → WAN → Edit → Advanced Settings** and untick **Use DNS servers advertised by peer**. Now the router only forwards to the encrypted proxy.
8. **AdBlock** — install `luci-app-adblock-fast` → enable the service → pick **Hagezi Pro**. To make it run faster, also install these packages from **System → Software**: `gawk`, `grep`, `sed` and `coreutils-sort`.
9. **DDNS** (needed by WireGuard) — install `luci-app-ddns`. In Services → Dynamic DNS:

   ```
   name              myddns
   service provider  duckdns.org   (from the list, not custom)
   lookup hostname   YOURNAME.duckdns.org
   domain            YOURNAME       (just the subdomain)
   username          YOURNAME.duckdns.org   (LuCI won't accept empty; duckdns ignores it)
   password          <your duckdns token>
   HTTPS             on
   ```

10. **WireGuard** — install `luci-proto-wireguard`. Network → Interfaces → Add:

   ```
   Name wg0 · Protocol WireGuard VPN · Generate a new key pair (only this once)
   Listen Port 53320 · IP address 10.8.0.1/24
   ```

   - **Traffic Rule — DNS for the peers:** `Allow-VPN-DNS`, source `vpn`, destination Device (input), protocol TCP+UDP, port `53`.
   - **Traffic Rule — open the WG port:** `Allow-WireGuard`, source `wan`, destination Device (input), protocol UDP, port `53320`.
   - **`vpn` zone** (Firewall → Zones): input `drop`, output `accept`, intra-zone forward `reject`, masquerading on, MSS clamping on, covered networks `wg0`, allow forward to dest `wan`. Peers reach the internet but can't see the LAN.
   - **Peer** (one per device): generate key pair + preshared key **for the peer only**, Allowed IPs `10.8.0.2/32` (next one `10.8.0.3/32`, always `/32`), endpoint host/port empty, Persistent Keep Alive `25`.
   - **Generate configuration → QR.** In the phone app, **DNS Servers `10.8.0.1`** (the tunnel IP, **not** `192.168.1.1`).

11. **NTP with NTS** — install `luci-app-chrony` and `chrony-nts`. Build a server `time.cloudflare.com` with `iburst` and `nts` on, delete the default `pool`, and in System → Startup disable `sysntpd`.

---

Flashing part based on [chill1Penguin/er605v2_openwrt_install](https://github.com/chill1Penguin/er605v2_openwrt_install). Licensed under [GPL-2.0](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html).
