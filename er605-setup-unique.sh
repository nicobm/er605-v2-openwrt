#!/bin/sh
# er605-setup-unique.sh — Setup + verify for OpenWrt on TP-Link ER605 v2
#
# Each section follows a "write, verify" pattern:
#   1. Configure (idempotent)
#   2. Immediately check it took effect
#
# Safe to run multiple times. Compatible with ash/BusyBox.
#
# Usage:
#   ssh root@192.168.1.1
#   sh er605-setup-unique.sh
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
ok()      { printf "${GREEN}[ OK ]${NC} %s\n" "$1"; }
warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; WARN_COUNT=$((WARN_COUNT + 1)); }
err()     { printf "${RED}[FAIL]${NC} %s\n" "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
section() { printf "\n${BOLD}=== %s ===${NC}\n\n" "$1"; }
verify()  { printf "\n  ${BOLD}--- Verify ---${NC}\n"; }

FAIL_COUNT=0
WARN_COUNT=0

# Helper: check if something is listening on a port
port_listening() {
    netstat -tlnup 2>/dev/null | grep -q ":${1} " && return 0
    ss -tlnup 2>/dev/null | grep -q ":${1} " && return 0
    return 1
}

# Helper: clear loading line
clear_line() {
    printf "\r                                                                              \r"
}

# ==============================================================================
section "Pre-flight checks"
# ==============================================================================

if [ "$(id -u)" -ne 0 ]; then
    printf "${RED}[FAIL]${NC} This script must be run as root.\n"
    exit 1
fi

if ! grep -qi 'openwrt' /etc/os-release 2>/dev/null; then
    printf "${RED}[FAIL]${NC} This doesn't look like an OpenWrt system.\n"
    exit 1
fi

# System info
OWRT_VER=""
if [ -f /etc/openwrt_release ]; then
    OWRT_VER=$(. /etc/openwrt_release && echo "$DISTRIB_RELEASE")
fi
[ -n "$OWRT_VER" ] && ok "OpenWrt version: $OWRT_VER" || warn "Could not read OpenWrt version"

UPTIME=$(uptime | sed 's/.*up /up /' | sed 's/,.*load/ load/')
ok "$UPTIME"

if [ -f /proc/meminfo ]; then
    MEM_TOTAL=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
    MEM_AVAIL=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo)
    [ -z "$MEM_AVAIL" ] && MEM_AVAIL=$(awk '/^MemFree:/{printf "%d", $2/1024}' /proc/meminfo)
    if [ -n "$MEM_AVAIL" ] && [ "$MEM_AVAIL" -ge 40 ] 2>/dev/null; then
        ok "RAM available: ${MEM_AVAIL}MB / ${MEM_TOTAL}MB total"
    elif [ -n "$MEM_AVAIL" ]; then
        warn "RAM available: ${MEM_AVAIL}MB / ${MEM_TOTAL}MB total (low)"
    fi
fi

OVERLAY_USE=$(df /overlay 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%')
if [ -n "$OVERLAY_USE" ]; then
    [ "$OVERLAY_USE" -lt 80 ] 2>/dev/null && ok "Overlay usage: ${OVERLAY_USE}%" || warn "Overlay usage: ${OVERLAY_USE}% (high)"
fi

# Internet connectivity
info "Checking internet connectivity..."
if ! ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
    printf "${RED}[FAIL]${NC} No internet. Connect the WAN cable before running this script.\n"
    exit 1
fi
ok "Internet is reachable"

# Bootstrap DNS
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
        warn "dnsmasq forwarding not working yet — using direct resolv.conf fallback"
        echo "nameserver 9.9.9.9" > /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null || \
        echo "nameserver 9.9.9.9" > /tmp/resolv.conf.auto 2>/dev/null || true
        sleep 1
        if nslookup downloads.openwrt.org >/dev/null 2>&1; then
            ok "DNS working via resolv.conf fallback"
        else
            printf "${RED}[FAIL]${NC} DNS still not resolving — check your WAN connection.\n"
            exit 1
        fi
    fi
else
    ok "DNS already working"
fi

# ==============================================================================
section "Timezone configuration"
# ==============================================================================

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

# ==============================================================================
section "1/6 — Packages"
# ==============================================================================

# --- Configure ---

if ! nslookup downloads.openwrt.org >/dev/null 2>&1; then
    printf "${RED}[FAIL]${NC} DNS is not working — cannot download packages.\n"
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
        if [ "$pkg" = "chrony-nts" ]; then
            apk del chrony 2>/dev/null || true
        fi
        apk add "$pkg"
        ok "$pkg installed"
    fi
done

rm -f /etc/config/chrony-opkg

# --- Verify ---
verify

for PKG in dnscrypt-proxy2 chrony-nts ca-certificates bind-dig; do
    if apk info -e "$PKG" >/dev/null 2>&1; then
        PKG_VER=$(apk version "$PKG" 2>/dev/null | awk 'NR==2{print $1}')
        [ -z "$PKG_VER" ] && PKG_VER="installed"
        ok "$PKG ($PKG_VER)"
    else
        case "$PKG" in
            bind-dig) warn "$PKG not installed (optional, for diagnostics)" ;;
            *)        err "$PKG not installed" ;;
        esac
    fi
done

for PKG in luci-app-sqm luci-proto-wireguard luci-app-statistics; do
    if apk info -e "$PKG" >/dev/null 2>&1; then
        ok "$PKG (optional, installed)"
    fi
done

# ==============================================================================
section "2/6 — Encrypted DNS (dnscrypt-proxy2)"
# ==============================================================================

# --- Configure ---

TOML="/etc/dnscrypt-proxy2/dnscrypt-proxy.toml"

if [ -f "$TOML" ]; then
    info "Configuring $TOML..."

    [ ! -f "${TOML}.orig" ] && cp "$TOML" "${TOML}.orig"

    # Remove any previous er605-setup blocks FIRST
    sed -i '/^# --- er605-setup START/,/^# --- er605-setup END/d' "$TOML"
    sed -i '/^# --- er605-setup cache START/,/^# --- er605-setup cache END/d' "$TOML"

    # Comment out original defaults (only matches uncommented lines)
    sed -i "s/^listen_addresses/#listen_addresses/" "$TOML"
    sed -i "s/^server_names/#server_names/" "$TOML"
    sed -i "s/^require_nofilter/#require_nofilter/" "$TOML"
    sed -i "s/^block_ipv6/#block_ipv6/" "$TOML"
    sed -i "s/^cert_ignore_timestamp/#cert_ignore_timestamp/" "$TOML"
    sed -i "s/^tls_cipher_suite/#tls_cipher_suite/" "$TOML"
    sed -i "s/^\[cache\]/#[cache]/" "$TOML"
    sed -i "s/^cache = /#cache = /" "$TOML"
    sed -i "s/^cache_size/#cache_size/" "$TOML"
    sed -i "s/^cache_min_ttl/#cache_min_ttl/" "$TOML"
    sed -i "s/^cache_max_ttl/#cache_max_ttl/" "$TOML"
    sed -i "s/^cache_neg_min_ttl/#cache_neg_min_ttl/" "$TOML"
    sed -i "s/^cache_neg_max_ttl/#cache_neg_max_ttl/" "$TOML"

    # Insert config block BEFORE the first [section] header
    cat > /tmp/er605-dns-block << 'DNSEOF'

# --- er605-setup START ---
listen_addresses = ['127.0.0.1:5353']
server_names = ['quad9-doh-ip4-port443-filter-ecs-pri']
require_nofilter = false
cert_ignore_timestamp = true
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

    ok "dnscrypt-proxy2 configured (Quad9 DoH, port 5353)"
else
    printf "${RED}[FAIL]${NC} $TOML not found — dnscrypt-proxy2 may not have installed correctly.\n"
    exit 1
fi

# Enable and start dnscrypt-proxy
/etc/init.d/dnscrypt-proxy enable
/etc/init.d/dnscrypt-proxy stop 2>/dev/null || true
info "Starting dnscrypt-proxy..."
/etc/init.d/dnscrypt-proxy start 2>&1 | while IFS= read -r line; do
    [ -n "$line" ] && info "  dnscrypt-proxy: $line"
done

sleep 2
if ! pgrep -x dnscrypt-proxy >/dev/null 2>&1; then
    warn "dnscrypt-proxy process not found — checking logs..."
    logread -e dnscrypt 2>/dev/null | tail -5 | while IFS= read -r line; do
        warn "  $line"
    done
fi

# Wait for port 5353
info "Waiting for dnscrypt-proxy to start (up to 60s)..."
DNSCRYPT_READY="no"
RETRIES=0
while [ $RETRIES -lt 60 ]; do
    if port_listening 5353; then
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
    info "Retrying dnscrypt-proxy start..."
    /etc/init.d/dnscrypt-proxy stop 2>/dev/null || true
    sleep 2
    /etc/init.d/dnscrypt-proxy start 2>/dev/null || true
    RETRIES=0
    while [ $RETRIES -lt 30 ]; do
        if port_listening 5353; then
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

# --- Verify DNS ---
verify

# TOML config checks
if [ -f "$TOML" ]; then
    LISTEN_COUNT=$(grep -c "^listen_addresses" "$TOML" 2>/dev/null)
    LISTEN_VAL=$(grep "^listen_addresses" "$TOML" 2>/dev/null | head -1)
    if [ "$LISTEN_COUNT" = "1" ]; then
        if echo "$LISTEN_VAL" | grep -q "5353"; then
            ok "dnscrypt-proxy.toml: listen_addresses on 5353 (single line)"
        else
            err "dnscrypt-proxy.toml: listen_addresses not pointing to 5353"
        fi
    elif [ "$LISTEN_COUNT" -gt 1 ] 2>/dev/null; then
        err "dnscrypt-proxy.toml: $LISTEN_COUNT listen_addresses lines (must be 1)"
    else
        warn "dnscrypt-proxy.toml: listen_addresses not found"
    fi

    if grep -q "^server_names.*quad9" "$TOML" 2>/dev/null; then
        ok "Resolver: Quad9"
    else
        RESOLVER=$(grep "^server_names" "$TOML" 2>/dev/null | head -1)
        warn "Resolver: $RESOLVER (guide uses Quad9)"
    fi

    if grep -q "^require_nofilter = false" "$TOML" 2>/dev/null; then
        ok "require_nofilter = false (malware filter active)"
    else
        warn "require_nofilter is not false"
    fi

    if grep -q "^block_ipv6 = true" "$TOML" 2>/dev/null; then
        ok "block_ipv6 = true"
    else
        err "block_ipv6 is not true"
    fi

    # Duplicate key check
    TOML_DUP_FOUND="no"
    for DUP_KEY in block_ipv6 cert_ignore_timestamp listen_addresses server_names require_nofilter; do
        DUP_COUNT=$(grep -c "^${DUP_KEY}" "$TOML" 2>/dev/null)
        if [ "$DUP_COUNT" -gt 1 ] 2>/dev/null; then
            err "Duplicate '$DUP_KEY' in TOML ($DUP_COUNT found) — dnscrypt-proxy will crash"
            TOML_DUP_FOUND="yes"
        fi
    done

    CACHE_SECTIONS=$(grep -c "^\[cache\]" "$TOML" 2>/dev/null)
    CACHE_KEYS=$(grep -c "^cache = " "$TOML" 2>/dev/null)
    if [ "$CACHE_SECTIONS" -gt 1 ] 2>/dev/null; then
        err "Duplicate [cache] sections in TOML ($CACHE_SECTIONS found)"
        TOML_DUP_FOUND="yes"
    elif [ "$CACHE_KEYS" -gt 1 ] 2>/dev/null; then
        err "Duplicate 'cache' keys in TOML ($CACHE_KEYS found)"
        TOML_DUP_FOUND="yes"
    elif grep -q "^cache = true" "$TOML" 2>/dev/null; then
        ok "Cache enabled in dnscrypt-proxy"
    else
        warn "Cache not enabled in dnscrypt-proxy"
    fi

    [ "$TOML_DUP_FOUND" = "yes" ] && err "  TOML has duplicate keys — dnscrypt-proxy will crash. Check $TOML"
fi

# Port 5353
if port_listening 5353; then
    ok "dnscrypt-proxy listening on port 5353"
else
    err "dnscrypt-proxy NOT listening on port 5353"
    warn "Try: /etc/init.d/dnscrypt-proxy start  (may need 30s to fetch resolver list)"
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
fi

# noresolv
NORESOLV=$(uci get dhcp.@dnsmasq[0].noresolv 2>/dev/null)
if [ "$NORESOLV" = "1" ]; then
    ok "noresolv = 1 (ISP DNS blocked)"
else
    err "noresolv NOT set — DNS may leak to ISP!"
fi

# logqueries
LOGQUERIES=$(uci -q get dhcp.@dnsmasq[0].logqueries 2>/dev/null)
if [ "$LOGQUERIES" = "0" ]; then
    ok "logqueries = 0 (DNS query logging disabled)"
elif [ -z "$LOGQUERIES" ]; then
    warn "logqueries not set (default may log queries — set to 0)"
else
    err "logqueries = '$LOGQUERIES' (expected: 0)"
fi

# Live DNS test
printf "  ...  Testing DNS resolution (dig @127.0.0.1 -p 5353 example.com)... "
if command -v dig >/dev/null 2>&1; then
    sleep 2
    DIG_OUT=$(dig @127.0.0.1 -p 5353 example.com +short +time=5 +tries=1 2>/dev/null)
    if echo "$DIG_OUT" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        clear_line
        ok "DNS resolution working (via dnscrypt-proxy → $DIG_OUT)"
    elif dig @127.0.0.1 example.com +short +time=5 +tries=1 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        clear_line
        ok "DNS resolution working (via dnsmasq → dnscrypt-proxy)"
    else
        clear_line
        warn "DNS resolution test failed — dnscrypt-proxy may still be initializing (give it 30s)"
    fi
else
    clear_line
    warn "dig not installed (cannot test DNS live)"
fi

# ==============================================================================
section "3/6 — Ad blocking (Hagezi Pro++)"
# ==============================================================================

# --- Configure ---

mkdir -p /tmp/dnsmasq.d

# Ensure /tmp/dnsmasq.d is in confdir exactly once
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
# Download Hagezi Pro++ blocklist to a temp file first, then move on success.
TMPFILE="/tmp/dnsmasq.d/blocklist.conf.tmp"
OUTFILE="/tmp/dnsmasq.d/blocklist.conf"
URL="https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/dnsmasq/pro.plus.txt"

if curl -sf --retry 3 --retry-delay 5 --connect-timeout 10 -o "$TMPFILE" "$URL"; then
    mv -f "$TMPFILE" "$OUTFILE"
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
else
    rm -f "$TMPFILE"
    logger -t blocklist "Failed to download blocklist from $URL"
    exit 1
fi
EOF
chmod +x /usr/sbin/update-blocklist.sh
ok "Update script created at /usr/sbin/update-blocklist.sh"

# Hotplug script
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

# Cron job (idempotent: remove old then add)
if [ -f /etc/crontabs/root ]; then
    sed -i '/update-blocklist\.sh/d' /etc/crontabs/root
fi
mkdir -p /etc/crontabs
echo '0 4 * * * /usr/sbin/update-blocklist.sh' >> /etc/crontabs/root
/etc/init.d/cron restart
ok "Cron job set (daily at 4:00 AM)"

# Download blocklist
info "Blocklist is stored in RAM (/tmp) — not persistent, re-downloaded on boot via hotplug + daily via cron"
info "Downloading Hagezi Pro++ blocklist (this may take a moment)..."
DNS_WAIT=0
while [ $DNS_WAIT -lt 10 ]; do
    if nslookup cdn.jsdelivr.net 127.0.0.1 >/dev/null 2>&1; then
        break
    fi
    sleep 1
    DNS_WAIT=$((DNS_WAIT + 1))
done
if /usr/sbin/update-blocklist.sh; then
    LINES=$(wc -l < /tmp/dnsmasq.d/blocklist.conf 2>/dev/null || echo 0)
    ok "Blocklist loaded ($LINES domains)"
else
    warn "Could not download blocklist — will retry when WAN reconnects"
fi

# --- Verify ad blocking ---
verify

# confdir
CONFDIR=$(uci -q get dhcp.@dnsmasq[0].confdir 2>/dev/null)
CONFDIR_COUNT=$(uci -q show dhcp.@dnsmasq[0].confdir 2>/dev/null | grep -c "/tmp/dnsmasq.d")
if [ "$CONFDIR_COUNT" -gt 1 ] 2>/dev/null; then
    err "dnsmasq confdir has DUPLICATE /tmp/dnsmasq.d entries (dnsmasq will crash!)"
elif echo "$CONFDIR" | grep -q "/tmp/dnsmasq.d" 2>/dev/null; then
    ok "dnsmasq confdir includes /tmp/dnsmasq.d"
else
    err "dnsmasq confdir missing /tmp/dnsmasq.d"
fi

# init script
if [ -x "/etc/init.d/mkdir-dnsmasq-confdir" ]; then
    if /etc/init.d/mkdir-dnsmasq-confdir enabled 2>/dev/null; then
        ok "init.d/mkdir-dnsmasq-confdir enabled (creates /tmp/dnsmasq.d before dnsmasq)"
    else
        err "init.d/mkdir-dnsmasq-confdir exists but NOT enabled"
    fi
else
    err "No init script to create /tmp/dnsmasq.d on boot"
fi

# update-blocklist.sh script checks
if [ -x "/usr/sbin/update-blocklist.sh" ]; then
    if grep -q "/tmp/dnsmasq.d/blocklist.conf" /usr/sbin/update-blocklist.sh 2>/dev/null; then
        ok "update-blocklist.sh outputs to /tmp/dnsmasq.d/blocklist.conf"
    else
        warn "update-blocklist.sh output path unexpected"
    fi
    if grep -q "curl" /usr/sbin/update-blocklist.sh 2>/dev/null; then
        BL_URL=$(grep -o 'https://[^ "]*' /usr/sbin/update-blocklist.sh 2>/dev/null | head -1)
        [ -n "$BL_URL" ] && ok "Download URL: $BL_URL" || warn "No URL found in update-blocklist.sh"
    fi
    if grep -q "dnsmasq restart" /usr/sbin/update-blocklist.sh 2>/dev/null; then
        ok "update-blocklist.sh restarts dnsmasq after download"
    else
        warn "update-blocklist.sh does NOT restart dnsmasq"
    fi
else
    err "update-blocklist.sh not found or not executable"
fi

# Blocklist file
BLOCKLIST_FILE="/tmp/dnsmasq.d/blocklist.conf"
if [ -f "$BLOCKLIST_FILE" ]; then
    BL_LINES=$(wc -l < "$BLOCKLIST_FILE" 2>/dev/null)
    if [ -n "$BL_LINES" ] && [ "$BL_LINES" -gt 1000 ] 2>/dev/null; then
        ok "Blocklist loaded: ~${BL_LINES} domains (RAM — re-downloaded on boot)"
    elif [ -n "$BL_LINES" ] && [ "$BL_LINES" -gt 0 ] 2>/dev/null; then
        warn "Blocklist has only $BL_LINES lines (expected ~240k for Hagezi Pro++)"
    else
        err "Blocklist file is empty"
    fi
else
    warn "Blocklist file not found yet (will load on next WAN reconnect)"
fi

# Hotplug script checks
HOTPLUG_FILE="/etc/hotplug.d/iface/99-blocklist"
if [ -f "$HOTPLUG_FILE" ]; then
    HP_ISSUES=""
    if ! grep -q "update-blocklist" "$HOTPLUG_FILE" 2>/dev/null; then
        HP_ISSUES="doesn't call update-blocklist.sh"
    fi
    if ! grep -q 'ACTION.*ifup\|ifup.*ACTION' "$HOTPLUG_FILE" 2>/dev/null; then
        HP_ISSUES="${HP_ISSUES}${HP_ISSUES:+, }missing ACTION=ifup trigger"
    fi
    if ! grep -q 'INTERFACE.*wan\|wan.*INTERFACE' "$HOTPLUG_FILE" 2>/dev/null; then
        HP_ISSUES="${HP_ISSUES}${HP_ISSUES:+, }missing INTERFACE=wan trigger"
    fi
    if [ ! -x "$HOTPLUG_FILE" ]; then
        HP_ISSUES="${HP_ISSUES}${HP_ISSUES:+, }not executable"
    fi
    if [ -z "$HP_ISSUES" ]; then
        ok "Hotplug script OK: triggers on WAN up, calls update-blocklist.sh"
    else
        warn "Hotplug script issues: $HP_ISSUES"
    fi
else
    warn "No hotplug script at $HOTPLUG_FILE"
fi

# Cron
CRON_BL=$(grep -c "update-blocklist" /etc/crontabs/root 2>/dev/null)
if [ "$CRON_BL" -gt 0 ] 2>/dev/null; then
    CRON_LINE=$(grep "update-blocklist" /etc/crontabs/root 2>/dev/null | head -1)
    ok "Cron job: $CRON_LINE"
else
    err "No cron job for update-blocklist.sh"
fi

# Live ad blocking test
if command -v nslookup >/dev/null 2>&1; then
    printf "  ...  Testing ad blocking (nslookup ads.google.com)... "
    NSL_RESULT=$(nslookup ads.google.com 127.0.0.1 2>&1)
    if echo "$NSL_RESULT" | grep -qi "NXDOMAIN\|0\.0\.0\.0\|127\.0\.0\.1\|Name or service not known\|server can't find" 2>/dev/null; then
        clear_line
        if [ -f "$BLOCKLIST_FILE" ] && [ -n "$BL_LINES" ] && [ "$BL_LINES" -gt 0 ] 2>/dev/null; then
            ok "ads.google.com blocked (local dnsmasq blocklist)"
        else
            warn "ads.google.com blocked by upstream DNS (Quad9), but local blocklist not active"
        fi
    else
        clear_line
        warn "ads.google.com NOT blocked (blocklist may still be loading)"
    fi
fi

# ==============================================================================
section "4/6 — NTP + NTS (Chrony)"
# ==============================================================================

# --- Configure ---

# Disable built-in sysntpd
info "Disabling built-in sysntpd..."
/etc/init.d/sysntpd stop 2>/dev/null || true
/etc/init.d/sysntpd disable 2>/dev/null || true
ok "sysntpd disabled"

# Configure Cloudflare NTS
info "Adding Cloudflare NTS server..."

while uci -q get chrony.@pool[0] >/dev/null 2>&1; do
    uci delete chrony.@pool[0]
done
while uci -q get chrony.@server[0] >/dev/null 2>&1; do
    uci delete chrony.@server[0]
done

uci add chrony server
uci set chrony.@server[-1].hostname='time.cloudflare.com'
uci set chrony.@server[-1].iburst='yes'
uci set chrony.@server[-1].nts='yes'
ok "Cloudflare NTS server configured"

# Enable NTP server for LAN clients via conf.d
info "Enabling NTP server for LAN..."

CHRONY_CONF="/etc/chrony/chrony.conf"
CHRONY_CONFD="/etc/chrony/conf.d"
CHRONYD_INIT="/etc/init.d/chronyd"
NTP_SERVER_CONF="$CHRONY_CONFD/ntp-server.conf"

# Clean up old patches
if [ -f "$CHRONYD_INIT" ]; then
    sed -i '/echo "port 123" >> \/var\/etc\/chrony.conf/d' "$CHRONYD_INIT"
    sed -i '/sed -i "s\/\^port 0/d' "$CHRONYD_INIT"
fi
rm -f /var/etc/chrony.conf

# Remove stale UCI allow entries
while uci -q get chrony.@allow[0] >/dev/null 2>&1; do
    uci delete chrony.@allow[0]
done
uci commit chrony

# Remove any 'port 123' from main chrony.conf
if [ -f "$CHRONY_CONF" ]; then
    sed -i '/^port 123$/d' "$CHRONY_CONF"
fi

# Write NTP server config to conf.d
mkdir -p "$CHRONY_CONFD"
cat > "$NTP_SERVER_CONF" << 'EOF'
# Enable NTP server on standard port for LAN clients
port 123
allow 192.168.1.0/24
EOF
ok "NTP server config written to $NTP_SERVER_CONF"

# Ensure chrony.conf includes conf.d
if [ -f "$CHRONY_CONF" ] && ! grep -q "^confdir $CHRONY_CONFD" "$CHRONY_CONF" 2>/dev/null; then
    echo "confdir $CHRONY_CONFD" >> "$CHRONY_CONF"
fi

/etc/init.d/chronyd enable
/etc/init.d/chronyd restart
sleep 2

# Patch /var/etc/chrony.conf if needed
CHRONY_VAR_CONF="/var/etc/chrony.conf"
if [ -f "$CHRONY_VAR_CONF" ] && ! grep -q "^confdir" "$CHRONY_VAR_CONF" 2>/dev/null; then
    echo "confdir $CHRONY_CONFD" >> "$CHRONY_VAR_CONF"
    /etc/init.d/chronyd restart
    sleep 2
fi

if pidof chronyd >/dev/null 2>&1; then
    ok "Chrony configured with NTS + LAN server (running)"
else
    warn "Chrony configured but not yet running — check with: /etc/init.d/chronyd start"
fi

# --- Verify NTP ---
verify

# chrony-nts installed
if apk info -e chrony-nts >/dev/null 2>&1; then
    ok "chrony-nts installed"
elif apk info -e chrony >/dev/null 2>&1; then
    warn "chrony installed but without NTS (chrony-nts missing)"
else
    err "chrony not installed"
fi

# Leftover pool entries
if uci -q get chrony.@pool[0] >/dev/null 2>&1; then
    POOL_HOST=$(uci -q get chrony.@pool[0].hostname 2>/dev/null)
    err "Leftover pool entry: $POOL_HOST — pools override NTS"
else
    ok "No pool entries (correct — NTS uses server only)"
fi

# NTS server configured
CHRONY_HOST=$(uci -q get chrony.@server[-1].hostname 2>/dev/null)
CHRONY_NTS=$(uci -q get chrony.@server[-1].nts 2>/dev/null)
if [ "$CHRONY_HOST" = "time.cloudflare.com" ] && [ "$CHRONY_NTS" = "yes" ]; then
    ok "NTS server: time.cloudflare.com with NTS=yes"
elif [ -n "$CHRONY_HOST" ]; then
    warn "Server: $CHRONY_HOST (NTS=$CHRONY_NTS) — guide uses time.cloudflare.com + NTS"
else
    warn "No chrony server found in config"
fi

# sysntpd should be disabled
if [ -f "/etc/init.d/sysntpd" ]; then
    if /etc/init.d/sysntpd enabled 2>/dev/null; then
        err "sysntpd still enabled — should be disabled"
    elif pidof sysntpd >/dev/null 2>&1; then
        warn "sysntpd disabled but still running"
    else
        ok "sysntpd disabled + stopped (chrony handles NTP)"
    fi
fi

# Services check
for SVC in dnsmasq dnscrypt-proxy chronyd dropbear firewall; do
    if [ -f "/etc/init.d/$SVC" ]; then
        ENABLED="no"
        /etc/init.d/$SVC enabled 2>/dev/null && ENABLED="yes"
        RUNNING="no"
        case "$SVC" in
            dnscrypt-proxy) PNAME="dnscrypt-proxy" ;;
            chronyd)        PNAME="chronyd" ;;
            *)              PNAME="$SVC" ;;
        esac
        if [ "$SVC" = "firewall" ]; then
            nft list ruleset >/dev/null 2>&1 && RUNNING="yes"
        elif [ -n "$PNAME" ]; then
            pidof "$PNAME" >/dev/null 2>&1 && RUNNING="yes"
        fi
        if [ "$RUNNING" = "yes" ] && [ "$ENABLED" = "yes" ]; then
            ok "$SVC  (running, enabled on boot)"
        elif [ "$RUNNING" = "yes" ]; then
            warn "$SVC  (running, but NOT enabled on boot)"
        elif [ "$ENABLED" = "yes" ]; then
            err "$SVC  (NOT running, enabled on boot)"
        else
            err "$SVC  (NOT running, NOT enabled on boot)"
        fi
    else
        err "$SVC  (not installed)"
    fi
done

# chronyc sources
printf "  ...  Querying chronyc sources... "
if command -v chronyc >/dev/null 2>&1; then
    CHRONY_SRC=$(chronyc sources -a 2>/dev/null)
    if echo "$CHRONY_SRC" | grep -q "^\^[\*]" 2>/dev/null; then
        SRC_NAME=$(echo "$CHRONY_SRC" | grep "^\^\*" | awk '{print $2}')
        clear_line
        ok "Chrony synced to: $SRC_NAME"
    elif echo "$CHRONY_SRC" | grep -qi "cloudflare\|162\.159" 2>/dev/null; then
        clear_line
        warn "Chrony sees Cloudflare but not synced yet"
    else
        clear_line
        warn "Chrony sources does not show Cloudflare synced"
    fi

    TRACKING=$(chronyc tracking 2>/dev/null)
    if [ -n "$TRACKING" ]; then
        LEAP=$(echo "$TRACKING" | grep "Leap status" | sed 's/.*: *//')
        if [ "$LEAP" = "Normal" ]; then
            ok "Chrony leap status: Normal"
        elif [ -n "$LEAP" ]; then
            warn "Chrony leap status: $LEAP (expected: Normal)"
        fi
        STRATUM=$(echo "$TRACKING" | grep "^Stratum" | awk '{print $3}')
        if [ -n "$STRATUM" ] 2>/dev/null; then
            if [ "$STRATUM" -eq 0 ] 2>/dev/null; then
                warn "Stratum: 0 (not yet synchronized)"
            elif [ "$STRATUM" -le 6 ] 2>/dev/null; then
                ok "Stratum: $STRATUM"
            else
                err "Stratum: $STRATUM (too high — expected ≤ 6)"
            fi
        fi
    fi

    AUTH_DATA=$(chronyc -N authdata 2>/dev/null)
    if echo "$AUTH_DATA" | grep -q "NTS" 2>/dev/null; then
        NTS_COOK=$(echo "$AUTH_DATA" | grep "NTS" | awk '{print $9}' | head -1)
        if [ -n "$NTS_COOK" ] && [ "$NTS_COOK" -gt 0 ] 2>/dev/null; then
            ok "NTS active, cookies: $NTS_COOK"
        else
            warn "NTS configured but cookies = 0 (may still be starting)"
        fi
    else
        warn "NTS not detected in authdata"
    fi

    printf "  ...  Querying chronyc serverstats... "
    SRVSTATS=$(chronyc serverstats 2>/dev/null)
    if [ -n "$SRVSTATS" ]; then
        NTP_RECV=$(echo "$SRVSTATS" | grep "NTP packets received" | awk '{print $NF}')
        clear_line
        if [ -n "$NTP_RECV" ] && [ "$NTP_RECV" -gt 0 ] 2>/dev/null; then
            ok "LAN NTP server active, packets received: $NTP_RECV"
        else
            warn "LAN NTP server: 0 packets received — configure clients to use 192.168.1.1"
        fi
    else
        clear_line
        warn "Could not query serverstats"
    fi
else
    clear_line
    warn "chronyc not available"
fi

# chrony allow subnet via conf.d
ALLOW_CONFD=$(grep '^allow ' "$NTP_SERVER_CONF" 2>/dev/null | head -1)
ALLOW_UCI=$(uci -q get chrony.@allow[-1].subnet 2>/dev/null)
if [ -n "$ALLOW_CONFD" ]; then
    ok "Chrony allows LAN clients: $ALLOW_CONFD (via conf.d)"
elif [ -n "$ALLOW_UCI" ]; then
    warn "Chrony allow via UCI ($ALLOW_UCI) — but UCI 'subnet' is ignored by init script; use conf.d"
else
    warn "No 'allow' in chrony config — LAN clients can't query NTP"
fi

# Port 123 listening
NTP_LISTEN=$(netstat -ulnp 2>/dev/null | grep ":123 ")
[ -z "$NTP_LISTEN" ] && NTP_LISTEN=$(ss -ulnp 2>/dev/null | grep ":123 ")
if [ -n "$NTP_LISTEN" ]; then
    if echo "$NTP_LISTEN" | grep -q "0\.0\.0\.0:123\|:::123\|\*:123" 2>/dev/null; then
        ok "UDP port 123 listening on all interfaces (NTP server)"
    elif echo "$NTP_LISTEN" | grep -q "127\.0\.0\.1:123" 2>/dev/null; then
        err "UDP port 123 only on 127.0.0.1 — LAN clients cannot reach it"
    else
        ok "UDP port 123 listening (NTP server)"
    fi
else
    err "UDP port 123 not listening — chrony may not be serving NTP to LAN"
    if grep -q '^port 123' /etc/chrony/chrony.conf 2>/dev/null; then
        err "  chrony.conf has port 123 but port not open — try: /etc/init.d/chronyd restart"
    elif grep -rq '^port 123' /etc/chrony/conf.d/ 2>/dev/null; then
        err "  conf.d/ntp-server.conf has port 123 but chronyd isn't reading it"
        if [ -f /var/etc/chrony.conf ] && ! grep -q '^confdir' /var/etc/chrony.conf 2>/dev/null; then
            err "  /var/etc/chrony.conf missing 'confdir' — this should have been patched above"
        fi
    fi
fi

# LAN zone input policy
LAN_INPUT=$(uci -q get firewall.@zone[0].input 2>/dev/null)
LAN_NAME=$(uci -q get firewall.@zone[0].name 2>/dev/null)
if [ "$LAN_NAME" = "lan" ]; then
    if [ "$LAN_INPUT" = "ACCEPT" ]; then
        ok "LAN zone input = ACCEPT (NTP from LAN clients allowed)"
    else
        err "LAN zone input = $LAN_INPUT (should be ACCEPT — NTP from LAN will be dropped)"
    fi
else
    ZONE_IDX=0
    LAN_FOUND="no"
    while true; do
        ZN=$(uci -q get "firewall.@zone[$ZONE_IDX].name" 2>/dev/null)
        [ -z "$ZN" ] && break
        if [ "$ZN" = "lan" ]; then
            LAN_FOUND="yes"
            ZI=$(uci -q get "firewall.@zone[$ZONE_IDX].input" 2>/dev/null)
            if [ "$ZI" = "ACCEPT" ]; then
                ok "LAN zone input = ACCEPT (NTP from LAN clients allowed)"
            else
                err "LAN zone input = $ZI (should be ACCEPT)"
            fi
            break
        fi
        ZONE_IDX=$((ZONE_IDX + 1))
    done
    [ "$LAN_FOUND" = "no" ] && warn "Could not find LAN firewall zone"
fi

# ==============================================================================
section "5/6 — Firewall hardening"
# ==============================================================================

# --- Configure ---

info "Enabling drop invalid packets..."
uci set firewall.@defaults[0].drop_invalid='1'
ok "Drop invalid packets enabled"

info "Enabling software flow offloading..."
uci set firewall.@defaults[0].flow_offloading='1'
uci commit firewall
service firewall restart >/dev/null 2>&1
ok "Software flow offloading enabled"

# --- Verify firewall ---
verify

DROP_INVALID=$(uci -q get firewall.@defaults[0].drop_invalid 2>/dev/null)
if [ "$DROP_INVALID" = "1" ]; then
    ok "Drop invalid packets = enabled"
else
    err "Drop invalid packets not enabled"
fi

FLOW_OFF=$(uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null)
if [ "$FLOW_OFF" = "1" ]; then
    ok "Software flow offloading = enabled"
else
    err "Software flow offloading NOT enabled (throughput reduced ~50%)"
fi

HW_FLOW=$(uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null)
SQM_INSTALLED=0
apk info -e luci-app-sqm >/dev/null 2>&1 && SQM_INSTALLED=1
if [ "$HW_FLOW" = "1" ] && [ "$SQM_INSTALLED" -gt 0 ] 2>/dev/null; then
    warn "HW flow offloading ON + SQM installed (incompatible, bypasses QoS)"
elif [ "$HW_FLOW" = "1" ]; then
    ok "HW flow offloading = enabled"
else
    ok "HW flow offloading = disabled (normal)"
fi

# ==============================================================================
section "6/6 — Performance tweaks"
# ==============================================================================

# --- Configure ---

info "Enabling packet steering..."
uci set network.globals.packet_steering='1'
uci commit network
ok "Packet steering enabled"

info "Increasing dnsmasq cache to 1000 entries..."
uci set dhcp.@dnsmasq[0].cachesize='1000'
uci commit dhcp
ok "dnsmasq cache set to 1000"

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

info "Reducing system log buffer to 32KB..."
uci set system.@system[0].log_size='32'
uci commit system
/etc/init.d/log restart
ok "Log buffer reduced to 32KB"

# --- Verify performance ---
verify

PKT_STEER=$(uci -q get network.globals.packet_steering 2>/dev/null)
[ "$PKT_STEER" = "1" ] && ok "Packet steering: enabled" || err "Packet steering: not set"

FLOW_OFF_V=$(uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null)
[ "$FLOW_OFF_V" = "1" ] && ok "Flow offloading: enabled" || err "Flow offloading: not set"

CACHESIZE=$(uci -q get dhcp.@dnsmasq[0].cachesize 2>/dev/null)
if [ "$CACHESIZE" = "1000" ]; then
    ok "dnsmasq cache = 1000 entries"
elif [ -n "$CACHESIZE" ]; then
    warn "dnsmasq cache = $CACHESIZE (guide recommends 1000)"
else
    warn "dnsmasq cache = default 150 (guide recommends 1000)"
fi

LOG_SIZE=$(uci -q get system.@system[0].log_size 2>/dev/null)
if [ "$LOG_SIZE" = "32" ]; then
    ok "Log buffer = 32KB"
elif [ -n "$LOG_SIZE" ]; then
    warn "Log buffer = ${LOG_SIZE}KB (guide recommends 32)"
else
    warn "Log buffer = default 64KB (guide recommends 32)"
fi

TZ_SET=$(uci -q get system.@system[0].zonename 2>/dev/null)
if [ -n "$TZ_SET" ] && [ "$TZ_SET" != "UTC" ]; then
    ok "Timezone: $TZ_SET ($(uci -q get system.@system[0].timezone 2>/dev/null))"
else
    warn "Timezone: not configured (defaults to UTC)"
fi

# odhcpd check
if [ -f "/etc/init.d/odhcpd" ]; then
    ODHCPD_ENABLED="no"
    /etc/init.d/odhcpd enabled 2>/dev/null && ODHCPD_ENABLED="yes"
    ODHCPD_RUNNING="no"
    pidof odhcpd >/dev/null 2>&1 && ODHCPD_RUNNING="yes"
    HAS_IPV6="no"
    ip -6 addr show scope global 2>/dev/null | grep -q 'inet6' && HAS_IPV6="yes"
    if [ "$HAS_IPV6" = "yes" ]; then
        [ "$ODHCPD_ENABLED" = "yes" ] && ok "odhcpd enabled (IPv6 detected)" || warn "odhcpd disabled but IPv6 detected"
    else
        if [ "$ODHCPD_ENABLED" = "no" ] && [ "$ODHCPD_RUNNING" = "no" ]; then
            ok "odhcpd disabled + stopped (no IPv6)"
        else
            warn "odhcpd running but no IPv6 detected — can disable to save resources"
        fi
    fi
fi

# Final: if dnscrypt-proxy is now running, remove plain DNS fallback
if port_listening 5353; then
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

# ==============================================================================
section "Setup complete"
# ==============================================================================

printf "${GREEN}${BOLD}Your ER605 v2 is configured with:${NC}\n\n"
printf "  - Encrypted DNS     → Quad9 DoH via dnscrypt-proxy (port 5353)\n"
printf "  - Ad blocking       → Hagezi Pro++ (~240k domains)\n"
printf "  - NTP + NTS         → Cloudflare (time.cloudflare.com)\n"
printf "  - Firewall          → Drop invalid + software flow offloading\n"
printf "  - Performance       → Packet steering + DNS cache 1000\n"
if [ -n "$TIMEZONE_NAME" ]; then
    printf "  - Timezone          → %s (%s)\n" "$TIMEZONE_NAME" "$TIMEZONE_STRING"
fi
printf "\n"

if [ $FAIL_COUNT -eq 0 ] && [ $WARN_COUNT -eq 0 ]; then
    printf "${GREEN}${BOLD}All checks passed. No warnings.${NC}\n"
elif [ $FAIL_COUNT -eq 0 ]; then
    printf "${YELLOW}All checks passed with %d warning(s) — review output above.${NC}\n" "$WARN_COUNT"
else
    printf "${RED}%d check(s) failed, %d warning(s) — review the output above.${NC}\n" "$FAIL_COUNT" "$WARN_COUNT"
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
