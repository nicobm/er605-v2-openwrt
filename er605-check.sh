#!/bin/ash
# er605-check.sh — Health check for ER605 v2 OpenWrt
# READ-ONLY. Does not modify anything.
# Compatible with ash/BusyBox (no bashisms)

OK="[ok]"
FAIL="[!!]"
WARN="[??]"

# helper: print result
check() {
    # $1 = status (ok/fail/warn)  $2 = description
    case "$1" in
        ok)   printf "  %s %s\n" "$OK" "$2" ;;
        fail) printf "  %s %s\n" "$FAIL" "$2" ;;
        warn) printf "  %s %s\n" "$WARN" "$2" ;;
    esac
}

separator() {
    echo ""
    echo "=== $1 ==="
    echo ""
}

# helper: clears the "loading..." line before printing the result
clear_line() {
    printf "\r                                                                              \r"
}

# =========================================
separator "SYSTEM"
# =========================================

# OpenWrt version
OWRT_VER=""
if [ -f /etc/openwrt_release ]; then
    OWRT_VER=$(. /etc/openwrt_release && echo "$DISTRIB_RELEASE")
fi
if [ -n "$OWRT_VER" ]; then
    check ok "OpenWrt version: $OWRT_VER"
else
    check fail "Could not read OpenWrt version"
fi

# Uptime
UPTIME=$(uptime | sed 's/.*up /up /' | sed 's/,.*load/ load/')
check ok "$UPTIME"

# RAM
if [ -f /proc/meminfo ]; then
    MEM_TOTAL=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
    MEM_AVAIL=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo)
    if [ -z "$MEM_AVAIL" ]; then
        # Fallback if MemAvailable is missing
        MEM_FREE=$(awk '/^MemFree:/{printf "%d", $2/1024}' /proc/meminfo)
        MEM_AVAIL="$MEM_FREE"
    fi
    if [ -n "$MEM_AVAIL" ] && [ "$MEM_AVAIL" -ge 40 ] 2>/dev/null; then
        check ok "RAM available: ${MEM_AVAIL}MB / ${MEM_TOTAL}MB total"
    elif [ -n "$MEM_AVAIL" ]; then
        check warn "RAM available: ${MEM_AVAIL}MB / ${MEM_TOTAL}MB total (low)"
    else
        check warn "Could not read RAM info"
    fi
fi

# Overlay space
OVERLAY_USE=$(df /overlay 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%')
if [ -n "$OVERLAY_USE" ]; then
    if [ "$OVERLAY_USE" -lt 80 ] 2>/dev/null; then
        check ok "Overlay usage: ${OVERLAY_USE}%"
    else
        check warn "Overlay usage: ${OVERLAY_USE}% (high)"
    fi
else
    check warn "Could not read overlay usage"
fi

# Timezone
TZ_VAL=$(uci -q get system.@system[0].timezone 2>/dev/null)
TZ_NAME=$(uci -q get system.@system[0].zonename 2>/dev/null)
if [ -n "$TZ_VAL" ] && [ -n "$TZ_NAME" ]; then
    check ok "Timezone: $TZ_NAME ($TZ_VAL)"
elif [ -n "$TZ_VAL" ]; then
    check warn "Timezone set ($TZ_VAL) but zonename missing"
else
    check warn "Timezone not configured (default UTC)"
fi

# =========================================
separator "SERVICES"
# =========================================

for SVC in dnsmasq dnscrypt-proxy chronyd dropbear firewall; do
    # Check if the init script exists
    if [ -f "/etc/init.d/$SVC" ]; then
        # Check if enabled on boot
        ENABLED="no"
        if /etc/init.d/$SVC enabled 2>/dev/null; then
            ENABLED="yes"
        fi
        # Check if running (look for process)
        RUNNING="no"
        # Some services have a different process name
        case "$SVC" in
            dnscrypt-proxy) PNAME="dnscrypt-proxy" ;;
            chronyd)        PNAME="chronyd" ;;
            *)              PNAME="$SVC" ;;
        esac

        if [ "$SVC" = "firewall" ]; then
            # Firewall is running if nftables has rules loaded
            if nft list ruleset >/dev/null 2>&1; then
                RUNNING="yes"
            fi
        elif [ -n "$PNAME" ]; then
            if pidof "$PNAME" >/dev/null 2>&1; then
                RUNNING="yes"
            fi
        fi

        if [ "$RUNNING" = "yes" ] && [ "$ENABLED" = "yes" ]; then
            check ok "$SVC  (running, enabled on boot)"
        elif [ "$RUNNING" = "yes" ] && [ "$ENABLED" = "no" ]; then
            check warn "$SVC  (running, but NOT enabled on boot)"
        elif [ "$RUNNING" = "no" ] && [ "$ENABLED" = "yes" ]; then
            check fail "$SVC  (NOT running, enabled on boot)"
        else
            check fail "$SVC  (NOT running, NOT enabled on boot)"
        fi
    else
        check fail "$SVC  (not installed)"
    fi
done

# odhcpd — needed only if IPv6 is in use
if [ -f "/etc/init.d/odhcpd" ]; then
    ODHCPD_ENABLED="no"
    if /etc/init.d/odhcpd enabled 2>/dev/null; then
        ODHCPD_ENABLED="yes"
    fi
    ODHCPD_RUNNING="no"
    if pidof odhcpd >/dev/null 2>&1; then
        ODHCPD_RUNNING="yes"
    fi
    HAS_IPV6="no"
    if ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
        HAS_IPV6="yes"
    fi
    if [ "$HAS_IPV6" = "yes" ]; then
        if [ "$ODHCPD_ENABLED" = "yes" ]; then
            check ok "odhcpd  (enabled — IPv6 detected on WAN)"
        else
            check warn "odhcpd  (disabled but IPv6 detected — may need odhcpd for IPv6 DHCP)"
        fi
    else
        if [ "$ODHCPD_ENABLED" = "no" ] && [ "$ODHCPD_RUNNING" = "no" ]; then
            check ok "odhcpd  (disabled + stopped — correct, no IPv6)"
        elif [ "$ODHCPD_ENABLED" = "yes" ] || [ "$ODHCPD_RUNNING" = "yes" ]; then
            check warn "odhcpd  (running but no IPv6 detected — can disable to save resources)"
        fi
    fi
fi

# =========================================
separator "DNS (dnsmasq + dnscrypt-proxy)"
# =========================================

# dnsmasq forwarding to dnscrypt-proxy
DNS_SERVER=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null)
if [ "$DNS_SERVER" = "127.0.0.1#5353" ]; then
    check ok "dnsmasq forward -> 127.0.0.1#5353"
else
    check fail "dnsmasq forward -> '$DNS_SERVER' (expected: 127.0.0.1#5353)"
fi

# noresolv
NORESOLV=$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null)
if [ "$NORESOLV" = "1" ]; then
    check ok "noresolv = 1 (ISP DNS not used)"
else
    check fail "noresolv = '$NORESOLV' (expected: 1 — ISP DNS may leak!)"
fi

# logqueries
LOGQUERIES=$(uci -q get dhcp.@dnsmasq[0].logqueries 2>/dev/null)
if [ "$LOGQUERIES" = "0" ]; then
    check ok "logqueries = 0 (DNS query logging disabled)"
elif [ -z "$LOGQUERIES" ]; then
    check warn "logqueries not set (default may log queries — set to 0)"
else
    check fail "logqueries = '$LOGQUERIES' (expected: 0 — DNS queries are being logged!)"
fi

# cachesize
CACHESIZE=$(uci -q get dhcp.@dnsmasq[0].cachesize 2>/dev/null)
if [ "$CACHESIZE" = "1000" ]; then
    check ok "dnsmasq cache = 1000 entries"
elif [ -n "$CACHESIZE" ]; then
    check warn "dnsmasq cache = $CACHESIZE (guide recommends 1000)"
else
    check warn "dnsmasq cache = default 150 (guide recommends 1000)"
fi

# dnscrypt-proxy listening on 5353
LISTENING_5353=$(netstat -tlnup 2>/dev/null | grep ":5353 " | head -1)
if [ -z "$LISTENING_5353" ]; then
    LISTENING_5353=$(ss -tlnup 2>/dev/null | grep ":5353 " | head -1)
fi
if [ -n "$LISTENING_5353" ]; then
    check ok "dnscrypt-proxy listening on port 5353"
else
    check fail "Nothing listening on port 5353 (no DNS! run: /etc/init.d/dnscrypt-proxy start)"
fi

# toml: single listen_addresses line
TOML="/etc/dnscrypt-proxy2/dnscrypt-proxy.toml"
if [ -f "$TOML" ]; then
    LISTEN_COUNT=$(grep -c "^listen_addresses" "$TOML" 2>/dev/null)
    LISTEN_VAL=$(grep "^listen_addresses" "$TOML" 2>/dev/null | head -1)
    if [ "$LISTEN_COUNT" = "1" ]; then
        if echo "$LISTEN_VAL" | grep -q "5353"; then
            check ok "dnscrypt-proxy.toml: listen_addresses on 5353 (single line)"
        else
            check fail "dnscrypt-proxy.toml: listen_addresses not pointing to 5353"
        fi
    elif [ "$LISTEN_COUNT" -gt 1 ] 2>/dev/null; then
        check fail "dnscrypt-proxy.toml: $LISTEN_COUNT listen_addresses lines (must be 1)"
    else
        check warn "dnscrypt-proxy.toml: listen_addresses not found"
    fi

    # server_names (Quad9)
    if grep -q "^server_names.*quad9" "$TOML" 2>/dev/null; then
        check ok "Resolver: Quad9"
    else
        RESOLVER=$(grep "^server_names" "$TOML" 2>/dev/null | head -1)
        check warn "Resolver: $RESOLVER (guide uses Quad9)"
    fi

    # require_nofilter
    if grep -q "^require_nofilter = false" "$TOML" 2>/dev/null; then
        check ok "require_nofilter = false (malware filter active)"
    else
        check warn "require_nofilter is not false"
    fi

    # block_ipv6 — the guide disables IPv6 entirely
    if grep -q "^block_ipv6 = true" "$TOML" 2>/dev/null; then
        check ok "block_ipv6 = true (IPv6 disabled as per guide)"
    else
        check fail "block_ipv6 is not true (guide disables IPv6)"
    fi

    # Duplicate key check — any duplicate top-level key causes a FATAL TOML crash
    TOML_DUP_FOUND="no"
    for DUP_KEY in block_ipv6 cert_ignore_timestamp listen_addresses server_names require_nofilter; do
        DUP_COUNT=$(grep -c "^${DUP_KEY}" "$TOML" 2>/dev/null)
        if [ "$DUP_COUNT" -gt 1 ] 2>/dev/null; then
            check fail "Duplicate '$DUP_KEY' in TOML ($DUP_COUNT found) — dnscrypt-proxy will crash"
            TOML_DUP_FOUND="yes"
        fi
    done

    # cache — check for duplicate [cache] / cache keys (causes FATAL crash)
    CACHE_SECTIONS=$(grep -c "^\[cache\]" "$TOML" 2>/dev/null)
    CACHE_KEYS=$(grep -c "^cache = " "$TOML" 2>/dev/null)
    if [ "$CACHE_SECTIONS" -gt 1 ] 2>/dev/null; then
        check fail "Duplicate [cache] sections in TOML ($CACHE_SECTIONS found) — dnscrypt-proxy will crash"
        TOML_DUP_FOUND="yes"
    elif [ "$CACHE_KEYS" -gt 1 ] 2>/dev/null; then
        check fail "Duplicate 'cache' keys in TOML ($CACHE_KEYS found) — dnscrypt-proxy will crash"
        TOML_DUP_FOUND="yes"
    elif grep -q "^cache = true" "$TOML" 2>/dev/null || grep -A1 "^\[cache\]" "$TOML" 2>/dev/null | grep -q "^cache = true"; then
        check ok "Cache enabled in dnscrypt-proxy"
    else
        check warn "Cache not enabled in dnscrypt-proxy"
    fi

    if [ "$TOML_DUP_FOUND" = "yes" ]; then
        check fail "  Fix: re-run er605-setup.sh or manually remove duplicate keys from $TOML"
    fi
else
    check fail "dnscrypt-proxy.toml not found"
fi

# Live DNS resolution test (may take a moment)
printf "  ...  Testing DNS resolution (dig @127.0.0.1 -p 5353 example.com)... "
if command -v dig >/dev/null 2>&1; then
    DIG_RESULT=$(dig @127.0.0.1 -p 5353 example.com +short +time=5 +tries=1 2>/dev/null)
    # Only accept valid IPv4/IPv6 addresses as success (not error messages)
    if echo "$DIG_RESULT" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        clear_line
        check ok "DNS resolves via dnscrypt-proxy (example.com -> $DIG_RESULT)"
    else
        clear_line
        # Also test via dnsmasq (port 53) which forwards to dnscrypt-proxy
        DIG_VIA_DNSMASQ=$(dig @127.0.0.1 example.com +short +time=5 +tries=1 2>/dev/null)
        if echo "$DIG_VIA_DNSMASQ" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            check ok "DNS resolves via dnsmasq->dnscrypt-proxy (example.com -> $DIG_VIA_DNSMASQ)"
        else
            check fail "DNS does NOT resolve (router has no working DNS!)"
            check fail "  Fix: /etc/init.d/dnscrypt-proxy start  (wait 30s for resolver list)"
            check fail "  Or run er605-setup.sh which bootstraps temporary DNS automatically"
        fi
    fi
else
    clear_line
    check warn "dig not installed (apk add bind-dig to test)"
fi

# =========================================
separator "AD BLOCKING (dnsmasq blocklist)"
# =========================================

# Check dnsmasq confdir includes /tmp/dnsmasq.d (and detect duplicates)
CONFDIR=$(uci -q get dhcp.@dnsmasq[0].confdir 2>/dev/null)
CONFDIR_COUNT=$(uci -q show dhcp.@dnsmasq[0].confdir 2>/dev/null | grep -c "/tmp/dnsmasq.d")
if [ "$CONFDIR_COUNT" -gt 1 ] 2>/dev/null; then
    check fail "dnsmasq confdir has DUPLICATE /tmp/dnsmasq.d entries (dnsmasq will crash! fix: uci delete dhcp.@dnsmasq[0].confdir; uci add_list dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'; uci commit dhcp)"
elif echo "$CONFDIR" | grep -q "/tmp/dnsmasq.d" 2>/dev/null; then
    check ok "dnsmasq confdir includes /tmp/dnsmasq.d"
else
    check fail "dnsmasq confdir missing /tmp/dnsmasq.d (run: uci add_list dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d')"
fi

# Check init script creates /tmp/dnsmasq.d before dnsmasq starts (critical)
if [ -x "/etc/init.d/mkdir-dnsmasq-confdir" ]; then
    if /etc/init.d/mkdir-dnsmasq-confdir enabled 2>/dev/null; then
        check ok "init.d/mkdir-dnsmasq-confdir enabled (creates /tmp/dnsmasq.d before dnsmasq)"
    else
        check fail "init.d/mkdir-dnsmasq-confdir exists but NOT enabled (run: /etc/init.d/mkdir-dnsmasq-confdir enable)"
    fi
else
    check fail "No init script to create /tmp/dnsmasq.d on boot (dnsmasq will crash on reboot! see guide)"
fi

# Check update-blocklist.sh script exists, is executable, and has correct content
if [ -x "/usr/sbin/update-blocklist.sh" ]; then

    # Verify script downloads to the right path
    if grep -q "/tmp/dnsmasq.d/blocklist.conf" /usr/sbin/update-blocklist.sh 2>/dev/null; then
        check ok "update-blocklist.sh installed and outputs to /tmp/dnsmasq.d/blocklist.conf"
    else
        check warn "update-blocklist.sh exists but output path is not /tmp/dnsmasq.d/blocklist.conf"

    fi
    # Verify it uses curl to download a blocklist
    if grep -q "curl" /usr/sbin/update-blocklist.sh 2>/dev/null; then
        BL_URL=$(grep -o 'https://[^ "]*' /usr/sbin/update-blocklist.sh 2>/dev/null | head -1)
        if [ -n "$BL_URL" ]; then
            check ok "Download URL: $BL_URL"
        else
            check warn "update-blocklist.sh has curl but no URL found"
        fi
    else
        check warn "update-blocklist.sh does not use curl (download may not work)"

    fi
    # Verify it restarts dnsmasq after download
    if grep -q "dnsmasq restart" /usr/sbin/update-blocklist.sh 2>/dev/null; then
        check ok "update-blocklist.sh restarts dnsmasq after download"
    else
        check warn "update-blocklist.sh does NOT restart dnsmasq (blocklist won't apply until manual restart)"

    fi
else
    check fail "update-blocklist.sh not found or not executable at /usr/sbin/update-blocklist.sh"
    BL_SCRIPT_OK=false
fi

# Check blocklist file exists and has entries
BLOCKLIST_FILE="/tmp/dnsmasq.d/blocklist.conf"
if [ -f "$BLOCKLIST_FILE" ]; then
    BL_LINES=$(wc -l < "$BLOCKLIST_FILE" 2>/dev/null)
    if [ -n "$BL_LINES" ] && [ "$BL_LINES" -gt 1000 ] 2>/dev/null; then
        check ok "Blocklist loaded: ~${BL_LINES} domains in $BLOCKLIST_FILE"
        check ok "Blocklist lives in RAM (/tmp) — re-downloaded on boot via hotplug + cron"
    elif [ -n "$BL_LINES" ] && [ "$BL_LINES" -gt 0 ] 2>/dev/null; then
        check warn "Blocklist has only $BL_LINES lines (expected ~240k for Hagezi Pro++)"
    else
        check fail "Blocklist file is empty"
    fi
else
    check fail "Blocklist file not found at $BLOCKLIST_FILE (run: /usr/sbin/update-blocklist.sh)"
fi

# Live ad blocking test (may take a moment)
if command -v nslookup >/dev/null 2>&1; then
    printf "  ...  Testing ad blocking (nslookup ads.google.com)... "
    NSL_RESULT=$(nslookup ads.google.com 127.0.0.1 2>&1)
    if echo "$NSL_RESULT" | grep -qi "NXDOMAIN\|0\.0\.0\.0\|127\.0\.0\.1\|Name or service not known\|server can't find" 2>/dev/null; then
        clear_line
        if [ -f "$BLOCKLIST_FILE" ] && [ -n "$BL_LINES" ] && [ "$BL_LINES" -gt 0 ] 2>/dev/null; then
            check ok "ads.google.com blocked (local dnsmasq blocklist)"
        else
            check warn "ads.google.com blocked by upstream DNS (Quad9), but local blocklist not active"
        fi
    else
        clear_line
        check fail "ads.google.com NOT blocked"
    fi
else
    check warn "nslookup not available (cannot test ad blocking live)"
fi

# Check hotplug script for auto-loading blocklist on WAN up
HOTPLUG_FILE="/etc/hotplug.d/iface/99-blocklist"
if [ -f "$HOTPLUG_FILE" ]; then
    HP_ISSUES=""
    # Must call update-blocklist.sh
    if ! grep -q "update-blocklist" "$HOTPLUG_FILE" 2>/dev/null; then
        HP_ISSUES="doesn't call update-blocklist.sh"
    fi
    # Must trigger on ACTION=ifup
    if ! grep -q 'ACTION.*ifup\|ifup.*ACTION' "$HOTPLUG_FILE" 2>/dev/null; then
        HP_ISSUES="${HP_ISSUES}${HP_ISSUES:+, }missing ACTION=ifup trigger"
    fi
    # Must trigger on INTERFACE=wan
    if ! grep -q 'INTERFACE.*wan\|wan.*INTERFACE' "$HOTPLUG_FILE" 2>/dev/null; then
        HP_ISSUES="${HP_ISSUES}${HP_ISSUES:+, }missing INTERFACE=wan trigger"
    fi
    # Must be executable
    if [ ! -x "$HOTPLUG_FILE" ]; then
        HP_ISSUES="${HP_ISSUES}${HP_ISSUES:+, }not executable (chmod +x needed)"
    fi
    if [ -z "$HP_ISSUES" ]; then
        check ok "Hotplug script OK: triggers on WAN up, calls update-blocklist.sh"
    else
        check warn "Hotplug script issues: $HP_ISSUES"
    fi
else
    check warn "No hotplug script at $HOTPLUG_FILE (blocklist won't auto-load after reboot)"
fi

# Cron for auto-updating blocklist
CRON_BL=$(grep -c "update-blocklist" /etc/crontabs/root 2>/dev/null)
if [ "$CRON_BL" -gt 0 ] 2>/dev/null; then
    CRON_LINE=$(grep "update-blocklist" /etc/crontabs/root 2>/dev/null | head -1)
    check ok "List update cron: $CRON_LINE"
else
    check warn "No cron job for update-blocklist.sh"
fi

# =========================================
separator "NTP + NTS (Chrony)"
# =========================================

# chrony-nts installed
if apk info -e chrony-nts >/dev/null 2>&1; then
    check ok "chrony-nts installed"
elif apk info -e chrony >/dev/null 2>&1; then
    check warn "chrony installed but without NTS (chrony-nts missing)"
else
    check fail "chrony not installed"
fi

# NTS server configured
CHRONY_HOST=$(uci -q get chrony.@server[-1].hostname 2>/dev/null)
CHRONY_NTS=$(uci -q get chrony.@server[-1].nts 2>/dev/null)
if [ "$CHRONY_HOST" = "time.cloudflare.com" ] && [ "$CHRONY_NTS" = "yes" ]; then
    check ok "NTS server: time.cloudflare.com with NTS=yes"
elif [ -n "$CHRONY_HOST" ]; then
    check warn "Server: $CHRONY_HOST (NTS=$CHRONY_NTS) — guide uses time.cloudflare.com + NTS"
else
    check warn "No chrony server found in config"
fi

# chronyc sources
printf "  ...  Querying chronyc sources... "
if command -v chronyc >/dev/null 2>&1; then
    CHRONY_SRC=$(chronyc sources -a 2>/dev/null)
    if echo "$CHRONY_SRC" | grep -q "^\^[\*]" 2>/dev/null; then
        SRC_NAME=$(echo "$CHRONY_SRC" | grep "^\^\*" | awk '{print $2}')
        clear_line
        check ok "Chrony synced to: $SRC_NAME"
    elif echo "$CHRONY_SRC" | grep -qi "cloudflare\|162\.159" 2>/dev/null; then
        clear_line
        check warn "Chrony sees Cloudflare but not synced yet (^* not present)"
    else
        clear_line
        check warn "Chrony sources does not show Cloudflare synced"
    fi

    # chronyc tracking — leap status should be Normal
    TRACKING=$(chronyc tracking 2>/dev/null)
    if [ -n "$TRACKING" ]; then
        LEAP=$(echo "$TRACKING" | grep "Leap status" | sed 's/.*: *//')
        if [ "$LEAP" = "Normal" ]; then
            check ok "Chrony leap status: Normal"
        elif [ -n "$LEAP" ]; then
            check warn "Chrony leap status: $LEAP (expected: Normal)"
        fi

        # Stratum check — Cloudflare is stratum 1, so this router should be stratum 2-3.
        # Stratum > 6 suggests a misconfiguration or an unusually long chain.
        STRATUM=$(echo "$TRACKING" | grep "^Stratum" | awk '{print $3}')
        if [ -n "$STRATUM" ] 2>/dev/null; then
            if [ "$STRATUM" -le 6 ] 2>/dev/null; then
                check ok "Stratum: $STRATUM"
            else
                check fail "Stratum: $STRATUM (too high — expected ≤ 6, check NTP source chain)"
            fi
        fi
    fi

    # NTS auth
    AUTH_DATA=$(chronyc -N authdata 2>/dev/null)
    if echo "$AUTH_DATA" | grep -q "NTS" 2>/dev/null; then
        NTS_COOK=$(echo "$AUTH_DATA" | grep "NTS" | awk '{print $9}' | head -1)
        if [ -n "$NTS_COOK" ] && [ "$NTS_COOK" -gt 0 ] 2>/dev/null; then
            check ok "NTS active, cookies: $NTS_COOK"
        else
            check warn "NTS configured but cookies = 0 (may still be starting)"
        fi
    else
        check warn "NTS not detected in authdata"
    fi

    # LAN NTP server stats
    printf "  ...  Querying chronyc serverstats... "
    SRVSTATS=$(chronyc serverstats 2>/dev/null)
    if [ -n "$SRVSTATS" ]; then
        NTP_RECV=$(echo "$SRVSTATS" | grep "NTP packets received" | awk '{print $NF}')
        clear_line
        if [ -n "$NTP_RECV" ] && [ "$NTP_RECV" -gt 0 ] 2>/dev/null; then
            check ok "LAN NTP server active, packets received: $NTP_RECV"
        else
            check warn "LAN NTP server: 0 packets received — configure clients to use 192.168.1.1 as NTP server"
        fi
    else
        clear_line
        check warn "Could not query serverstats"
    fi
else
    clear_line
    check fail "chronyc not available"
fi

# sysntpd should be disabled (chrony replaces it)
if [ -f "/etc/init.d/sysntpd" ]; then
    if /etc/init.d/sysntpd enabled 2>/dev/null; then
        check fail "sysntpd still enabled — disable it: /etc/init.d/sysntpd disable && /etc/init.d/sysntpd stop"
    elif pidof sysntpd >/dev/null 2>&1; then
        check warn "sysntpd disabled but still running — stop it: /etc/init.d/sysntpd stop"
    else
        check ok "sysntpd disabled + stopped (chrony handles NTP)"
    fi
fi

# chrony allow subnet (LAN NTP server)
# Check conf.d first (preferred), then fall back to UCI
NTP_CONF="/etc/chrony/conf.d/ntp-server.conf"
ALLOW_CONFD=$(grep '^allow ' "$NTP_CONF" 2>/dev/null | head -1)
ALLOW_UCI=$(uci -q get chrony.@allow[-1].subnet 2>/dev/null)
if [ -n "$ALLOW_CONFD" ]; then
    check ok "Chrony allows LAN clients: $ALLOW_CONFD (via conf.d)"
elif [ -n "$ALLOW_UCI" ]; then
    check warn "Chrony allow via UCI ($ALLOW_UCI) — but UCI 'subnet' is ignored by init script; use conf.d instead"
else
    check warn "No 'allow' in chrony config — LAN clients can't query NTP"
fi

# Port 123 listening — must be on 0.0.0.0 (all interfaces), not just 127.0.0.1
NTP_LISTEN=$(netstat -ulnp 2>/dev/null | grep ":123 ")
if [ -z "$NTP_LISTEN" ]; then
    NTP_LISTEN=$(ss -ulnp 2>/dev/null | grep ":123 ")
fi
if [ -n "$NTP_LISTEN" ]; then
    if echo "$NTP_LISTEN" | grep -q "0\.0\.0\.0:123\|:::123\|\*:123" 2>/dev/null; then
        check ok "UDP port 123 listening on all interfaces (NTP server)"
    elif echo "$NTP_LISTEN" | grep -q "127\.0\.0\.1:123" 2>/dev/null; then
        check fail "UDP port 123 only on 127.0.0.1 — LAN clients cannot reach it (check chrony allow subnet)"
    else
        check ok "UDP port 123 listening (NTP server)"
    fi
else
    check fail "UDP port 123 not listening — chrony may not be serving NTP to LAN"
    if grep -q '^port 123' /etc/chrony/chrony.conf 2>/dev/null; then
        check fail "  chrony.conf has port 123 but port not open — try: /etc/init.d/chronyd restart"
    elif grep -q '^port 0' /etc/chrony/chrony.conf 2>/dev/null; then
        check fail "  chrony.conf has port 0 (NTP disabled) — run er605-setup.sh or change to 'port 123'"
    else
        check fail "  Fix: add 'port 123' to /etc/chrony/chrony.conf and restart chronyd"
    fi
fi

# LAN zone input policy (must be ACCEPT for NTP from LAN clients)
LAN_INPUT=$(uci -q get firewall.@zone[0].input 2>/dev/null)
LAN_NAME=$(uci -q get firewall.@zone[0].name 2>/dev/null)
if [ "$LAN_NAME" = "lan" ]; then
    if [ "$LAN_INPUT" = "ACCEPT" ]; then
        check ok "LAN zone input = ACCEPT (NTP from LAN clients allowed)"
    else
        check fail "LAN zone input = $LAN_INPUT (should be ACCEPT — NTP from LAN will be dropped)"
    fi
else
    # Find the lan zone if it's not zone[0]
    ZONE_IDX=0
    LAN_FOUND="no"
    while true; do
        ZN=$(uci -q get "firewall.@zone[$ZONE_IDX].name" 2>/dev/null)
        [ -z "$ZN" ] && break
        if [ "$ZN" = "lan" ]; then
            LAN_FOUND="yes"
            ZI=$(uci -q get "firewall.@zone[$ZONE_IDX].input" 2>/dev/null)
            if [ "$ZI" = "ACCEPT" ]; then
                check ok "LAN zone input = ACCEPT (NTP from LAN clients allowed)"
            else
                check fail "LAN zone input = $ZI (should be ACCEPT — NTP from LAN will be dropped)"
            fi
            break
        fi
        ZONE_IDX=$((ZONE_IDX + 1))
    done
    if [ "$LAN_FOUND" = "no" ]; then
        check warn "Could not find LAN firewall zone"
    fi
fi

# =========================================
separator "FIREWALL"
# =========================================

# Drop invalid packets
DROP_INVALID=$(uci -q get firewall.@defaults[0].drop_invalid 2>/dev/null)
if [ "$DROP_INVALID" = "1" ]; then
    check ok "Drop invalid packets = enabled"
else
    check warn "Drop invalid packets not enabled (recommended)"
fi

# Software flow offloading
FLOW_OFF=$(uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null)
if [ "$FLOW_OFF" = "1" ]; then
    check ok "Software flow offloading = enabled"
else
    check fail "Software flow offloading NOT enabled (throughput reduced ~50%)"
fi

# Hardware flow offloading (should be OFF if using SQM)
HW_FLOW=$(uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null)
SQM_INSTALLED=0
if apk info -e luci-app-sqm >/dev/null 2>&1; then SQM_INSTALLED=1; fi
if [ "$HW_FLOW" = "1" ] && [ "$SQM_INSTALLED" -gt 0 ] 2>/dev/null; then
    check warn "HW flow offloading ON + SQM installed (incompatible, bypasses QoS)"
elif [ "$HW_FLOW" = "1" ]; then
    check ok "HW flow offloading = enabled"
else
    check ok "HW flow offloading = disabled (normal)"
fi

# =========================================
separator "PERFORMANCE"
# =========================================

# Packet steering
PKT_STEER=$(uci -q get network.globals.packet_steering 2>/dev/null)
if [ "$PKT_STEER" = "1" ]; then
    check ok "Packet Steering = enabled (uses both MT7621 cores)"
else
    check fail "Packet Steering NOT enabled (all on 1 core)"
fi

# Log buffer size
LOG_SIZE=$(uci -q get system.@system[0].log_size 2>/dev/null)
if [ "$LOG_SIZE" = "32" ]; then
    check ok "Log buffer = 32KB (reduced to save RAM)"
elif [ -n "$LOG_SIZE" ]; then
    check warn "Log buffer = ${LOG_SIZE}KB (guide recommends 32)"
else
    check warn "Log buffer = default 64KB (guide recommends 32)"
fi

# =========================================
separator "INSTALLED PACKAGES"
# =========================================

for PKG in dnscrypt-proxy2 chrony-nts ca-certificates bind-dig; do
    if apk info -e "$PKG" >/dev/null 2>&1; then
        PKG_VER=$(apk version "$PKG" 2>/dev/null | awk 'NR==2{print $1}')
        [ -z "$PKG_VER" ] && PKG_VER="installed"
        check ok "$PKG ($PKG_VER)"
    else
        case "$PKG" in
            bind-dig) check warn "$PKG not installed (optional, for diagnostics)" ;;
            *)        check fail "$PKG not installed" ;;
        esac
    fi
done

# Optional packages mentioned in the guide
for PKG in luci-app-sqm luci-proto-wireguard luci-app-statistics; do
    if apk info -e "$PKG" >/dev/null 2>&1; then
        check ok "$PKG (optional, installed)"
    fi
done

echo ""
echo "=== DONE ==="
echo ""
