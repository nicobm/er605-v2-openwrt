# TP-Link ER605 v2 → OpenWrt

Two-part project:

1. **Flash OpenWrt on the ER605** — replace the stock TP-Link firmware with OpenWrt 25.12.2. ER605-specific instructions.
2. **OpenWrt Security Hardening** — harden a fresh OpenWrt install with encrypted DNS, ad blocking, authenticated NTP, a closed WAN firewall, and an optional WireGuard VPN. Hardware-agnostic — works on any OpenWrt device.

> **Full walkthrough (with screenshots, troubleshooting, and every command explained in depth):** [nicobm.github.io/er605-v2-openwrt](https://nicobm.github.io/er605-v2-openwrt)
>
> This README is the condensed version. The site is the complete guide.

---

## 1. Flash OpenWrt on the ER605

### Requirements

- ER605 v2 with firmware **≤ 2.2.5** (2.2.6+ is blocked, no downgrade possible)
- Linux PC, ethernet cable, `ssh`, `curl`, `python3`, `md5sum`

### ⚠ Warnings

- **Keep WAN disconnected** the entire time — if the router reaches the internet, the local password stops working.
- **No factory recovery after flashing** — back up MTD partitions first (see full guide).
- **Power loss = brick** — use a stable power source.

### Password generation

Passwords are derived from the router's MAC address (`AA:BB:CC:DD:EE:FF` format, uppercase):

| Password | Formula |
|---|---|
| Root | `md5(MAC + username)` → first 16 chars |
| CLI debug (fw ≤ 2.1.2) | `md5(MAC + "admin")` → first 16 chars |
| CLI debug (fw 2.2.x) | `md5(MAC + "admin" + MAC + "admin")` → first 16 chars |

Use the [interactive password generator](https://nicobm.github.io/er605-v2-openwrt/#password-gen) to get your passwords instantly.

### Flash steps

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

## 2. OpenWrt Security Hardening

Once OpenWrt is running on the router, the `openwrt-setup.sh` script turns a vanilla install into a privacy-conscious, hardened configuration. It's idempotent — safe to run multiple times; it only applies changes that are missing and doesn't restart services when nothing changes. The optional `openwrt-setup-custom-blocklist.sh` companion lets you block extra domains on top of the main ad/tracker list.

### What the hardening does

**Encrypted DNS (DNS-over-HTTPS via Quad9)**
The router's DNS queries are forwarded to a local dnscrypt-proxy instance that talks to Quad9 over HTTPS with malware filtering and ECS enabled. Your ISP cannot see which domains anyone on the network visits, cannot redirect lookups, and cannot inject ads or tracking. The router also refuses the ISP's DNS servers entirely, so nothing leaks even if a client requests DNS directly.

**Local DNSSEC validation (strict mode)**
On top of Quad9's upstream validation, the router verifies DNSSEC signatures locally in dnsmasq. This removes the need to trust Quad9 — even if the resolver were compromised or coerced, the router independently verifies each response against the chain of cryptographic signatures up to the root zone. Strict mode (`dnssec_check_unsigned=1`) also rejects unsigned responses for domains whose parent zone requires DNSSEC, preventing downgrade attacks. Because OpenWrt ships a minimal `dnsmasq` build without DNSSEC support, the wizard auto-detects this and transparently upgrades to `dnsmasq-full` during package installation. Verified end-to-end via `sigfail.verteiltesysteme.net` (a test domain with deliberately invalid signatures) — the router returns SERVFAIL, confirming validation is enforced.

**Network-wide ad and tracker blocking (Hagezi Pro++)**
A ~250,000-domain blocklist is loaded into dnsmasq and applied to every device on the LAN. The list is re-downloaded automatically when WAN comes up and refreshed daily by cron, with a 3-mirror fallback (jsDelivr, GitHub, Codeberg). No per-device software needed. A separate custom blocklist lets you add specific domains (e.g. a site you want to keep yourself off of) alongside the main list.

**Authenticated time synchronization (NTP with NTS)**
Instead of plain NTP (which can be tampered with in transit), the router syncs against Cloudflare's time servers using NTS — cryptographically signed time. LAN clients can also use the router itself as a local NTP server.

**Hardened firewall**
WAN input policy is set to DROP (silent — no RST or unreachable responses), making the router invisible to internet-wide port scanners. Explicit DROP rules block DNS, SSH, HTTP, and HTTPS from WAN as defense in depth. ICMP echo-request from WAN is blocked for full stealth (TruStealth pass on GRC ShieldsUp). Invalid packet dropping is enabled, plus software flow offloading for better throughput.

**Service lockdown (defense in depth)**
Beyond the firewall, every local service is bound to the LAN interface or IP only — not listening on the WAN side at all. This applies to dnsmasq (DNS/DHCP), uhttpd (LuCI web UI), and dropbear (SSH). Even a misconfigured firewall rule wouldn't expose these to the internet.

**IPv6 stack consistency**
If your ISP doesn't provide usable IPv6, the wizard cleanly disables the entire IPv6 stack (WAN6 interface, odhcpd, ULA prefix). This avoids the half-working state where clients get IPv6 addresses but DNS only ever returns A records (a harmless but inconsistent default).

**Performance tuning**
Packet steering is enabled to distribute network processing across both MT7621 cores. The dnsmasq DNS cache is increased to 1000 entries. The system log buffer is reduced to 32 KB to free RAM on the 128 MB device.

**Optional WireGuard VPN (road warrior setup)**
The wizard includes an optional WireGuard module that turns the router into a personal VPN endpoint. When enabled, it installs the required packages (`wireguard-tools`, `kmod-wireguard`, `qrencode`, `ddns-scripts`), configures a Dynamic DNS client (dynv6 is recommended — free, FLOSS-friendly), generates a server keypair plus one keypair per peer device (up to 10), brings up the `wg0` interface on `10.8.0.0/24`, adds a firewall zone with masquerading and forwarding to WAN and LAN, and opens UDP 51820 on WAN. A scannable QR code is printed in the terminal for each peer so phones and laptops can import the tunnel configuration directly. Because WireGuard uses cryptokey routing, the open WAN port silently drops any packet not signed with a known peer key — to an external scanner it's indistinguishable from no service at all. All tunnel traffic inherits the router's encrypted DNS, ad blocking, and NTS time, so a phone on public Wi-Fi or mobile data sees the exact same filtered, privacy-respecting network as if it were sitting on the LAN. The WireGuard setup is fully menu-driven — run `sh openwrt-setup.sh wg` to jump straight to it for adding/removing peers, re-printing QR codes, or checking the DDNS sync status without touching the rest of the wizard.

### Running the wizard

Transfer `openwrt-setup.sh` to the router over `scp` and run it with `sh openwrt-setup.sh`. It asks for your timezone and whether to disable IPv6, then verifies or applies every setting. At the end, it offers to configure WireGuard — answer `n` to skip that step entirely. The final summary reports what was already configured, what was fixed, and what (if anything) still needs attention.

For WireGuard-only operations (adding peers, re-printing QR codes, reviewing DDNS config), run `sh openwrt-setup.sh wg` to jump directly to the WireGuard menu and skip the base hardening checks.

See the [full guide's hardening section](https://nicobm.github.io/er605-v2-openwrt/#hardening) for the complete rationale behind each choice and verification checklist.

---

Based on [chill1Penguin/er605v2_openwrt_install](https://github.com/chill1Penguin/er605v2_openwrt_install). Licensed under [GPL-2.0](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html).
