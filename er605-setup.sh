#!/bin/sh
# er605-setup.sh — Automated post-install setup for OpenWrt on TP-Link ER605 v2
#
# Run this script via SSH on the router AFTER flashing OpenWrt (tested on 25.12.x).
# It configures: encrypted DNS, ad blocking, NTP with NTS, firewall
# hardening, and performance tweaks.
#
# Usage:
#   ssh root@192.168.1.1
#   # transfer this script to the router, then:
#   sh er605-setup.sh
#
# Based on: https://github.com/chill1Penguin/er605v2_openwrt_install
# Guide:    https://github.com/nicobm/er605-v2-openwrt
# License:  GPL-2.0

set -e

# --- Colors and helpers -------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { printf "${CYAN}[INFO]${NC} %s\n" "$1"; }
ok()      { printf "${GREEN}[OK]${NC}   %s\n" "$1"; }
warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
err()     { printf "${RED}[ERR]${NC}  %s\n" "$1"; }
section() { printf "\n${BOLD}=== %s ===${NC}\n\n" "$1"; }

# --- Pre-flight checks --------------------------------------------------------

section "Pre-flight checks"

if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root."
    exit 1
fi

if ! grep -qi 'openwrt' /etc/os-release 2>/dev/null; then
    err "This doesn't look like an OpenWrt system."
    exit 1
fi

# Check for internet connectivity
info "Checking internet connectivity..."
if ! ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
    err "No internet. Connect the WAN cable before running this script."
    exit 1
fi
ok "Internet is reachable"

# Bootstrap DNS: ensure the router can resolve hostnames for package downloads.
# If dnscrypt-proxy is not yet running (first run or after reboot), dnsmasq
# has nowhere to forward DNS queries.  Temporarily point dnsmasq at public
# resolvers so apk/curl can work.  The script replaces this with encrypted DNS
# in step 2.
info "Bootstrapping temporary DNS for package downloads..."
NEED_BOOTSTRAP="no"
if ! nslookup downloads.openwrt.org 127.0.0.1 >/dev/null 2>&1; then
    NEED_BOOTSTRAP="yes"
    uci set dhcp.@dnsmasq[0].noresolv='0'
    uci delete dhcp.@dnsmasq[0].server 2>/dev/null || true
    uci add_list dhcp.@dnsmasq[0].server='9.9.9.9'
    uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
    uci commit dhcp
    service dnsmasq restart >/dev/null 2>&1

    # Wait and retry — dnsmasq may take a few seconds after restart
    DNS_OK="no"
    for i in 1 2 3 4 5; do
        sleep 2
        if nslookup downloads.openwrt.org 127.0.0.1 >/dev/null 2>&1; then
            DNS_OK="yes"
            break
        fi
    done

    if [ "$DNS_OK" = "yes" ]; then
        ok "Temporary DNS active (plain 9.9.9.9 + 1.1.1.1 — will switch to encrypted later)"
    else
        # Fallback: write resolv.conf directly so wget/curl can work even
        # if dnsmasq forwarding isn't cooperating yet
        warn "dnsmasq forwarding not working yet — using direct resolv.conf fallback"
        echo "nameserver 9.9.9.9" > /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null || \
        echo "nameserver 9.9.9.9" > /tmp/resolv.conf.auto 2>/dev/null || true
        sleep 1
        if nslookup downloads.openwrt.org >/dev/null 2>&1; then
            ok "DNS working via resolv.conf fallback"
        else
            err "DNS still not resolving — package downloads will likely fail"
            err "Check your WAN connection and try again"
            exit 1
        fi
    fi
else
    ok "DNS already working"
fi

# --- Timezone configuration (interactive) -------------------------------------

section "Timezone configuration"

printf "${CYAN}Enter your timezone name.${NC}\n"
printf "  Examples:\n"
printf "    America/New_York    America/Argentina/Buenos_Aires    Europe/London\n"
printf "    Europe/Madrid       Asia/Tokyo                       Australia/Sydney\n"
printf "  Full list: https://openwrt.org/docs/guide-user/base-system/system_configuration#time_zones\n"
printf "> "
read -r TIMEZONE_NAME
printf "\n"
printf "${CYAN}Enter your POSIX timezone string.${NC}\n"
printf "  This tells the system the UTC offset and DST rules for your zone.\n"
printf "  Examples:\n"
printf "    America/New_York          → EST5EDT,M3.2.0,M11.1.0\n"
printf "    America/Argentina/Buenos_Aires → ART3\n"
printf "    Europe/London             → GMT0BST,M3.5.0/1,M10.5.0\n"
printf "    Europe/Madrid             → CET-1CEST,M3.5.0,M10.5.0/3\n"
printf "    Asia/Tokyo                → JST-9\n"
printf "    Australia/Sydney          → AEST-10AEDT,M10.1.0,M4.1.0/3\n"
printf "  Find yours at: https://openwrt.org/docs/guide-user/base-system/system_configuration#time_zones\n"
printf "> "
read -r TIMEZONE_STRING

if [ -z "$TIMEZONE_NAME" ] || [ -z "$TIMEZONE_STRING" ]; then
    warn "Timezone not set — skipping (you can set it later in LuCI: System > System > Timezone)"
else
    info "Timezone will be set to: $TIMEZONE_NAME ($TIMEZONE_STRING)"
fi

# --- 1. Install packages ------------------------------------------------------

section "1/6 — Installing packages"

# Final DNS sanity check before attempting downloads
if ! nslookup downloads.openwrt.org >/dev/null 2>&1; then
    err "DNS is not working — cannot download packages"
    err "Check your WAN connection and try again"
    exit 1
fi

info "Updating package lists..."
apk update

PACKAGES="dnscrypt-proxy2 chrony-nts ca-certificates curl bind-dig"

for pkg in $PACKAGES; do
    if apk info -e "$pkg" >/dev/null 2>&1; then
        ok "$pkg already installed"
    else
        info "Installing $pkg..."
        # chrony-nts needs chrony removed first
        if [ "$pkg" = "chrony-nts" ]; then
            apk del chrony 2>/dev/null || true
        fi
        apk add "$pkg"
        ok "$pkg installed"
    fi
done

# Clean up leftover config
rm -f /etc/config/chrony-opkg

# --- 2. Encrypted DNS (dnscrypt-proxy2) ----------------------------------------

section "2/6 — Configuring encrypted DNS (dnscrypt-proxy2)"

TOML="/etc/dnscrypt-proxy2/dnscrypt-proxy.toml"

if [ -f "$TOML" ]; then
    info "Configuring $TOML..."

    # Backup original
    [ ! -f "${TOML}.orig" ] && cp "$TOML" "${TOML}.orig"

    # Remove any previous er605-setup blocks FIRST (before commenting originals)
    sed -i '/^# --- er605-setup START/,/^# --- er605-setup END/d' "$TOML"
    sed -i '/^# --- er605-setup cache START/,/^# --- er605-setup cache END/d' "$TOML"

    # Comment out original defaults (only matches uncommented lines)
    sed -i "s/^listen_addresses/#listen_addresses/" "$TOML"
    sed -i "s/^server_names/#server_names/" "$TOML"
    sed -i "s/^require_nofilter/#require_nofilter/" "$TOML"
    sed -i "s/^block_ipv6/#block_ipv6/" "$TOML"
    sed -i "s/^cert_ignore_timestamp/#cert_ignore_timestamp/" "$TOML"
    sed -i "s/^tls_cipher_suite/#tls_cipher_suite/" "$TOML"

    # Comment out the existing [cache] section to avoid "Key 'cache' already
    # defined" TOML errors — we replace it with our own settings below.
    sed -i "s/^\[cache\]/#[cache]/" "$TOML"
    sed -i "s/^cache = /#cache = /" "$TOML"
    sed -i "s/^cache_size/#cache_size/" "$TOML"
    sed -i "s/^cache_min_ttl/#cache_min_ttl/" "$TOML"
    sed -i "s/^cache_max_ttl/#cache_max_ttl/" "$TOML"
    sed -i "s/^cache_neg_min_ttl/#cache_neg_min_ttl/" "$TOML"
    sed -i "s/^cache_neg_max_ttl/#cache_neg_max_ttl/" "$TOML"

    # Insert our configuration block BEFORE the first [section] header.
    # Appending at the end would place settings inside [static], causing
    # "type mismatch for main.StaticConfig" crashes.
    # NOTE: cache settings are top-level keys in dnscrypt-proxy 2.x,
    # NOT inside a [cache] section (which would create a TOML table and crash).
    cat > /tmp/er605-dns-block << 'DNSEOF'

# --- er605-setup START ---
listen_addresses = ['127.0.0.1:5353']
server_names = ['quad9-dnscrypt-ip4-filter-ecs-pri']
require_nofilter = false
cert_ignore_timestamp = true
tls_cipher_suite = [52392, 49199]
block_ipv6 = true
cache = true
cache_size = 1024
cache_min_ttl = 600
cache_max_ttl = 86400
# --- er605-setup END ---

DNSEOF
    awk -v blockfile="/tmp/er605-dns-block" '
        /^\[/ && !done { while ((getline line < blockfile) > 0) print line; done=1 }
        { print }
    ' "$TOML" > "${TOML}.tmp" && mv "${TOML}.tmp" "$TOML"
    rm -f /tmp/er605-dns-block

    ok "dnscrypt-proxy2 configured (Quad9, port 5353)"
else
    err "$TOML not found — dnscrypt-proxy2 may not have installed correctly"
    exit 1
fi

# Helper: check if something is listening on port 5353
port_5353_listening() {
    netstat -tlnup 2>/dev/null | grep -q ':5353 ' && return 0
    ss -tlnup 2>/dev/null | grep -q ':5353 ' && return 0
    return 1
}

# Enable and start dnscrypt-proxy FIRST (while temporary DNS is still active
# so it can download the resolver list)
/etc/init.d/dnscrypt-proxy enable
/etc/init.d/dnscrypt-proxy stop  2>/dev/null || true
info "Starting dnscrypt-proxy..."
/etc/init.d/dnscrypt-proxy start 2>&1 | while IFS= read -r line; do
    [ -n "$line" ] && info "  dnscrypt-proxy: $line"
done

# Check if the process is actually running
sleep 2
if ! pgrep -x dnscrypt-proxy >/dev/null 2>&1; then
    warn "dnscrypt-proxy process not found — checking logs..."
    logread -e dnscrypt 2>/dev/null | tail -5 | while IFS= read -r line; do
        warn "  $line"
    done
fi

# Wait for dnscrypt-proxy to bind to port 5353 (needs to fetch resolver list,
# which can take 30+ seconds on first run)
info "Waiting for dnscrypt-proxy to start (up to 60s)..."
DNSCRYPT_READY="no"
RETRIES=0
while [ $RETRIES -lt 60 ]; do
    if port_5353_listening; then
        DNSCRYPT_READY="yes"
        break
    fi
    sleep 1
    RETRIES=$((RETRIES + 1))
done

if [ "$DNSCRYPT_READY" = "yes" ]; then
    ok "dnscrypt-proxy started and listening on port 5353"
else
    warn "dnscrypt-proxy not yet listening after 60s"
    # Try restarting once more
    info "Retrying dnscrypt-proxy start..."
    /etc/init.d/dnscrypt-proxy stop  2>/dev/null || true
    sleep 2
    /etc/init.d/dnscrypt-proxy start 2>/dev/null || true
    RETRIES=0
    while [ $RETRIES -lt 30 ]; do
        if port_5353_listening; then
            DNSCRYPT_READY="yes"
            break
        fi
        sleep 1
        RETRIES=$((RETRIES + 1))
    done
    if [ "$DNSCRYPT_READY" = "yes" ]; then
        ok "dnscrypt-proxy started on retry"
    else
        warn "dnscrypt-proxy still not listening — showing recent logs:"
        logread -e dnscrypt 2>/dev/null | tail -10 | while IFS= read -r line; do
            warn "  $line"
        done
    fi
fi

# Redirect dnsmasq to dnscrypt-proxy
info "Redirecting dnsmasq to dnscrypt-proxy..."
uci delete dhcp.@dnsmasq[0].server 2>/dev/null || true
uci set dhcp.@dnsmasq[0].logqueries='0'

if [ "$DNSCRYPT_READY" = "yes" ]; then
    uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'
    uci set dhcp.@dnsmasq[0].noresolv='1'
    ok "dnsmasq forwarding to 127.0.0.1#5353"
else
    # Keep dnscrypt-proxy as primary but add plain DNS fallback
    # so the system isn't left without working DNS
    uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'
    uci add_list dhcp.@dnsmasq[0].server='9.9.9.9'
    uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
    uci set dhcp.@dnsmasq[0].noresolv='1'
    warn "dnsmasq forwarding to dnscrypt-proxy + plain DNS fallback"
    warn "Once dnscrypt-proxy is running, remove fallback with:"
    warn "  uci delete dhcp.@dnsmasq[0].server && uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353' && uci commit dhcp && service dnsmasq restart"
fi

uci commit dhcp
service dnsmasq restart >/dev/null 2>&1

# --- 3. Ad blocking (dnsmasq + Hagezi Pro++) -----------------------------------

section "3/6 — Setting up ad blocking (Hagezi Pro++)"

# Create confdir for dnsmasq in /tmp (RAM)
mkdir -p /tmp/dnsmasq.d

# Ensure /tmp/dnsmasq.d is in confdir exactly once (idempotent: remove then re-add)
uci del_list dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d' 2>/dev/null || true
uci add_list dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'
uci commit dhcp

# Init script to recreate /tmp/dnsmasq.d before dnsmasq starts (priority 18)
info "Creating init script for /tmp/dnsmasq.d..."
cat > /etc/init.d/mkdir-dnsmasq-confdir << 'EOF'
#!/bin/sh /etc/rc.common
START=18
start() {
    mkdir -p /tmp/dnsmasq.d
}
EOF
chmod +x /etc/init.d/mkdir-dnsmasq-confdir
/etc/init.d/mkdir-dnsmasq-confdir enable
ok "Init script created (priority 18)"

# Update script
info "Creating blocklist update script..."
cat > /usr/sbin/update-blocklist.sh << 'EOF'
#!/bin/sh
curl -s -o /tmp/dnsmasq.d/blocklist.conf \
  https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/dnsmasq/pro.plus.txt && \
/etc/init.d/dnsmasq restart >/dev/null 2>&1
EOF
chmod +x /usr/sbin/update-blocklist.sh
ok "Update script created at /usr/sbin/update-blocklist.sh"

# Hotplug script to reload blocklist when WAN comes up
info "Creating hotplug script for WAN..."
mkdir -p /etc/hotplug.d/iface
cat > /etc/hotplug.d/iface/99-blocklist << 'EOF'
#!/bin/sh
[ "$ACTION" = ifup ] && [ "$INTERFACE" = wan ] && {
  sleep 5
  /usr/sbin/update-blocklist.sh
}
EOF
chmod +x /etc/hotplug.d/iface/99-blocklist
ok "Hotplug script created"

# Cron job for daily update at 4 AM (idempotent: remove old then add)
if [ -f /etc/crontabs/root ]; then
    sed -i '/update-blocklist\.sh/d' /etc/crontabs/root
fi
mkdir -p /etc/crontabs
echo '0 4 * * * /usr/sbin/update-blocklist.sh' >> /etc/crontabs/root
/etc/init.d/cron restart
ok "Cron job set (daily at 4:00 AM)"

# Download the blocklist now
info "Downloading Hagezi Pro++ blocklist (this may take a moment)..."
if /usr/sbin/update-blocklist.sh; then
    LINES=$(wc -l < /tmp/dnsmasq.d/blocklist.conf 2>/dev/null || echo 0)
    ok "Blocklist loaded ($LINES domains)"
else
    warn "Could not download blocklist — will retry when WAN reconnects"
fi

# --- 4. NTP + NTS (Chrony with Cloudflare) -------------------------------------

section "4/6 — Configuring NTP + NTS (Chrony)"

# Disable built-in sysntpd
info "Disabling built-in sysntpd..."
/etc/init.d/sysntpd stop 2>/dev/null || true
/etc/init.d/sysntpd disable 2>/dev/null || true
ok "sysntpd disabled"

# Configure Cloudflare NTS
info "Adding Cloudflare NTS server..."

# Remove existing server entries to avoid duplicates
while uci -q get chrony.@server[0] >/dev/null 2>&1; do
    uci delete chrony.@server[0]
done

uci add chrony server
uci set chrony.@server[-1].hostname='time.cloudflare.com'
uci set chrony.@server[-1].iburst='yes'
uci set chrony.@server[-1].nts='yes'
ok "Cloudflare NTS server configured"

# Allow LAN clients to query NTP
info "Enabling NTP server for LAN..."

# Remove existing allow entries to avoid duplicates
while uci -q get chrony.@allow[0] >/dev/null 2>&1; do
    uci delete chrony.@allow[0]
done

uci add chrony allow
uci set chrony.@allow[-1].subnet='192.168.1.0/24'
uci commit chrony

# Ensure chrony listens on port 123 for LAN NTP clients.
# The main chrony config is /etc/chrony/chrony.conf (static file, not auto-generated).
# By default it has no 'port' directive, so chrony defaults to port 0 (NTP server disabled).
# We add 'port 123' so chrony serves NTP to LAN clients.
CHRONY_CONF="/etc/chrony/chrony.conf"
CHRONYD_INIT="/etc/init.d/chronyd"

# Clean up any previous init script patches (from older versions of this script)
if [ -f "$CHRONYD_INIT" ]; then
    sed -i '/echo "port 123" >> \/var\/etc\/chrony.conf/d' "$CHRONYD_INIT"
    sed -i '/sed -i "s\/\^port 0/d' "$CHRONYD_INIT"
fi
# Remove ghost file created by old append-style patches
rm -f /var/etc/chrony.conf

if [ -f "$CHRONY_CONF" ]; then
    if grep -q '^port 0' "$CHRONY_CONF"; then
        sed -i 's/^port 0$/port 123/' "$CHRONY_CONF"
        ok "Changed port 0 → port 123 in $CHRONY_CONF"
    elif grep -q '^port 123' "$CHRONY_CONF"; then
        ok "Chrony already configured with port 123"
    else
        # No port directive found — add one
        echo "port 123" >> "$CHRONY_CONF"
        ok "Added port 123 to $CHRONY_CONF"
    fi
else
    warn "$CHRONY_CONF not found — chrony may not serve NTP to LAN"
fi

/etc/init.d/chronyd enable
/etc/init.d/chronyd restart
sleep 2
if pidof chronyd >/dev/null 2>&1; then
    ok "Chrony configured with NTS + LAN server (running)"
else
    warn "Chrony configured but not yet running — check with: /etc/init.d/chronyd start"
fi

# --- 5. Firewall hardening -----------------------------------------------------

section "5/6 — Firewall hardening + performance tweaks"

# Drop invalid packets
info "Enabling drop invalid packets..."
uci set firewall.@defaults[0].drop_invalid='1'
ok "Drop invalid packets enabled"

# Software flow offloading
info "Enabling software flow offloading..."
uci set firewall.@defaults[0].flow_offloading='1'
uci commit firewall
service firewall restart >/dev/null 2>&1
ok "Software flow offloading enabled"

# --- 6. Performance tweaks -----------------------------------------------------

# Packet steering (distribute across both MT7621 cores)
info "Enabling packet steering..."
uci set network.globals.packet_steering='1'
uci commit network
ok "Packet steering enabled"

# Increase dnsmasq cache
info "Increasing dnsmasq cache to 1000 entries..."
uci set dhcp.@dnsmasq[0].cachesize='1000'
uci commit dhcp
ok "dnsmasq cache set to 1000"

# Restart dnsmasq once (picks up all changes: forwarding, confdir, cache)
info "Restarting dnsmasq with all new settings..."
service dnsmasq restart >/dev/null 2>&1
ok "dnsmasq restarted"

# Disable odhcpd if no IPv6
info "Checking for IPv6..."
if ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
    ok "IPv6 detected — keeping odhcpd enabled"
else
    info "No IPv6 detected — disabling odhcpd to save resources..."
    service odhcpd stop 2>/dev/null || true
    service odhcpd disable 2>/dev/null || true
    ok "odhcpd disabled (no IPv6)"
fi

# Set timezone (if provided)
if [ -n "$TIMEZONE_NAME" ] && [ -n "$TIMEZONE_STRING" ]; then
    info "Setting timezone to $TIMEZONE_NAME..."
    uci set system.@system[0].zonename="$TIMEZONE_NAME"
    uci set system.@system[0].timezone="$TIMEZONE_STRING"
    ok "Timezone set to $TIMEZONE_NAME ($TIMEZONE_STRING)"
fi

# Reduce log buffer
info "Reducing system log buffer to 32KB..."
uci set system.@system[0].log_size='32'
uci commit system
/etc/init.d/log restart
ok "Log buffer reduced to 32KB"

# --- Verification --------------------------------------------------------------

section "Verification"

FAIL=0

# dnscrypt-proxy listening
if port_5353_listening; then
    ok "dnscrypt-proxy listening on port 5353"
else
    err "dnscrypt-proxy NOT listening on port 5353"
    warn "Try: /etc/init.d/dnscrypt-proxy start  (may need 30s to fetch resolver list)"
    FAIL=1
fi

# dnsmasq forwarding
DNSMASQ_SERVER=$(uci get dhcp.@dnsmasq[0].server 2>/dev/null)
if echo "$DNSMASQ_SERVER" | grep -q '127.0.0.1#5353'; then
    ok "dnsmasq forwarding to dnscrypt-proxy"
    if echo "$DNSMASQ_SERVER" | grep -q '9.9.9.9'; then
        warn "Plain DNS fallback still active (dnscrypt-proxy was not ready during setup)"
    fi
else
    err "dnsmasq NOT forwarding correctly (got: $DNSMASQ_SERVER)"
    FAIL=1
fi

# noresolv
NORESOLV=$(uci get dhcp.@dnsmasq[0].noresolv 2>/dev/null)
if [ "$NORESOLV" = "1" ]; then
    ok "dnsmasq noresolv=1 (ISP DNS blocked)"
else
    err "dnsmasq noresolv NOT set — DNS may leak to ISP!"
    FAIL=1
fi

# Blocklist
if [ -f /tmp/dnsmasq.d/blocklist.conf ]; then
    LINES=$(wc -l < /tmp/dnsmasq.d/blocklist.conf)
    ok "Blocklist loaded ($LINES domains)"
else
    warn "Blocklist not loaded yet (will load on next WAN reconnect)"
fi

# Chrony
if /etc/init.d/chronyd status 2>/dev/null | grep -q 'running'; then
    ok "chronyd is running"
else
    warn "chronyd may still be starting up"
fi

# Performance
PS=$(uci get network.globals.packet_steering 2>/dev/null)
FO=$(uci get firewall.@defaults[0].flow_offloading 2>/dev/null)
CS=$(uci get dhcp.@dnsmasq[0].cachesize 2>/dev/null)

[ "$PS" = "1" ] && ok "Packet steering: enabled" || warn "Packet steering: not set"
[ "$FO" = "1" ] && ok "Flow offloading: enabled" || warn "Flow offloading: not set"
[ "$CS" = "1000" ] && ok "dnsmasq cache: 1000" || warn "dnsmasq cache: $CS"

# Timezone
TZ_SET=$(uci get system.@system[0].zonename 2>/dev/null)
if [ -n "$TZ_SET" ] && [ "$TZ_SET" != "UTC" ]; then
    ok "Timezone: $TZ_SET ($(uci get system.@system[0].timezone 2>/dev/null))"
else
    warn "Timezone: not configured (defaults to UTC)"
fi

# Final check: if dnscrypt-proxy is now running, remove plain DNS fallback
if port_5353_listening; then
    CURRENT_SERVERS=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null)
    if echo "$CURRENT_SERVERS" | grep -q '9.9.9.9'; then
        info "dnscrypt-proxy is up — removing plain DNS fallback..."
        uci delete dhcp.@dnsmasq[0].server 2>/dev/null || true
        uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'
        uci commit dhcp
        service dnsmasq restart >/dev/null 2>&1
        ok "Fallback DNS removed, dnsmasq forwarding only to dnscrypt-proxy"
    fi
fi

# DNS resolution test
info "Testing DNS resolution..."
sleep 2
DIG_OUT=$(dig @127.0.0.1 -p 5353 example.com +short +time=5 +tries=1 2>/dev/null)
if echo "$DIG_OUT" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    ok "DNS resolution working (via dnscrypt-proxy → $DIG_OUT)"
elif dig @127.0.0.1 example.com +short +time=5 +tries=1 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    ok "DNS resolution working (via dnsmasq → dnscrypt-proxy)"
else
    warn "DNS resolution test failed — dnscrypt-proxy may still be initializing (give it 30s)"
fi

# Summary
section "Setup complete"

printf "${GREEN}${BOLD}Your ER605 v2 is configured with:${NC}\n\n"
printf "  - Encrypted DNS     → Quad9 via dnscrypt-proxy (port 5353)\n"
printf "  - Ad blocking       → Hagezi Pro++ (~240k domains)\n"
printf "  - NTP + NTS         → Cloudflare (time.cloudflare.com)\n"
printf "  - Firewall          → Drop invalid + software flow offloading\n"
printf "  - Performance       → Packet steering + DNS cache 1000\n"
if [ -n "$TIMEZONE_NAME" ]; then
    printf "  - Timezone          → %s (%s)\n" "$TIMEZONE_NAME" "$TIMEZONE_STRING"
fi
printf "\n"

if [ $FAIL -eq 0 ]; then
    printf "${GREEN}All checks passed.${NC}\n"
else
    printf "${YELLOW}Some checks failed — review the output above.${NC}\n"
fi

printf "\n"
printf "Next steps:\n"
printf "  1. Set a root password:  passwd\n"
printf "  2. Verify DNS leak test: https://dnsleaktest.com\n"
printf "  3. Reboot and re-verify: reboot\n"
printf "\n"

# Restart network last (applies packet steering).
# This may briefly drop the SSH session — all config is already saved.
info "Restarting network to apply packet steering (SSH may drop briefly)..."
service network restart
