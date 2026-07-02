#!/bin/sh
# check-er605.sh — READ-ONLY health check for the OpenWrt config of the ER605 v2
#
# Read-only by design: uci -q get, pgrep, wg show, chronyc and a couple of
# nslookup probes. It never modifies a single setting.
#
# Usage (as root on the router):   sh check-er605.sh
# Covers the 11 points of Part 2 of the guide, in order.

# ---- colors (auto-disabled when the output is not a terminal) ----
if [ -t 1 ]; then
  R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'; B='\033[1;34m'; Z='\033[0m'
else
  R=''; G=''; Y=''; B=''; Z=''
fi

ok=0; fail=0

# result LABEL STATUS [detail]      STATUS = OK | FAIL | WARN
result() {
  case "$2" in
    OK)   c=$G; t="OK";     ok=$((ok+1)) ;;
    FAIL) c=$R; t="FAILED";  fail=$((fail+1)) ;;
    *)    c=$Y; t="CHECK" ;;
  esac
  printf "%-27s: ${c}%-10s${Z} %s\n" "$1" "$t" "$3"
}

running() { pgrep "$1" >/dev/null 2>&1; }

# input policy of the firewall zone named $1
fw_zone_input() {
  i=0
  while n=$(uci -q get firewall.@zone[$i].name); do
    [ "$n" = "$1" ] && { uci -q get firewall.@zone[$i].input; return 0; }
    i=$((i+1)); [ "$i" -gt 30 ] && break
  done
  return 1
}

# state of traffic rule $1:  0=active  1=disabled  2=not found
fw_rule_enabled() {
  i=0
  while n=$(uci -q get firewall.@rule[$i].name); do
    if [ "$n" = "$1" ]; then
      [ "$(uci -q get firewall.@rule[$i].enabled)" = "0" ] && return 1
      return 0
    fi
    i=$((i+1)); [ "$i" -gt 80 ] && break
  done
  return 2
}

printf "\n${B}== OpenWrt config check · ER605 v2 ==${Z}\n\n"

# 1. Root password
h=$(awk -F: '/^root:/{print $2}' /etc/shadow 2>/dev/null)
case "$h" in
  ""|"*"|"!"|"!!") result "1. Root password" FAIL "root has NO password" ;;
  *)               result "1. Root password" OK ;;
esac

# 2. Firmware online check -> off
if uci -q get attendedsysupgrade.client >/dev/null 2>&1; then
  if [ "$(uci -q get attendedsysupgrade.client.auto_search)" = "0" ]; then
    result "2. Firmware online check" OK "auto_search off"
  else
    result "2. Firmware online check" WARN "auto_search enabled"
  fi
else
  result "2. Firmware online check" OK "no auto-updater installed"
fi

# 3. Firewall WAN -> DROP
wi=$(fw_zone_input wan)
if [ "$wi" = "DROP" ]; then
  result "3. Firewall WAN = DROP" OK
else
  result "3. Firewall WAN = DROP" FAIL "input=${wi:-?}"
fi

# 4. Kill the ping (Allow-Ping disabled or deleted)
fw_rule_enabled Allow-Ping; r=$?
if [ "$r" = "0" ]; then
  result "4. Ping blocked" FAIL "Allow-Ping is still active"
else
  result "4. Ping blocked" OK
fi

# 5. Hardware flow offloading
if [ "$(uci -q get firewall.@defaults[0].flow_offloading)" = "1" ] && \
   [ "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" = "1" ]; then
  result "5. Flow offloading (HW)" OK
else
  result "5. Flow offloading (HW)" FAIL
fi

# 6. IPv6 disabled on the LAN: wan6 removed + RA and DHCPv6 not served.
#    odhcpd treats 'ra'/'dhcpv6' as 'disabled' by default when empty, so
#    empty == disabled (no RAs sent, no DHCPv6 handed out). It's only a
#    problem if they are set to server/relay/hybrid.
ra=$(uci -q get dhcp.lan.ra)
d6=$(uci -q get dhcp.lan.dhcpv6)
ra_off=no; case "$ra" in ""|disabled) ra_off=yes ;; esac
d6_off=no; case "$d6" in ""|disabled) d6_off=yes ;; esac
if uci -q get network.wan6 >/dev/null 2>&1; then
  result "6. IPv6 disabled" FAIL "wan6 still exists"
elif [ "$ra_off" = yes ] && [ "$d6_off" = yes ]; then
  result "6. IPv6 disabled" OK "wan6 gone; LAN not serving RA/DHCPv6 (ra=${ra:-empty} dhcpv6=${d6:-empty})"
else
  result "6. IPv6 disabled" WARN "LAN is serving IPv6: ra=${ra:-empty} dhcpv6=${d6:-empty} (set to disabled)"
fi

# 7. DNS over HTTPS + exclusive encrypted egress (no plaintext leak to the ISP)
doh=no;  running https-dns-proxy && doh=yes
res=no;  nslookup openwrt.org 127.0.0.1 >/dev/null 2>&1 && res=yes
peerdns=$(uci -q get network.wan.peerdns)
if [ "$doh" = yes ] && [ "$res" = yes ] && [ "$peerdns" = "0" ]; then
  result "7. Encrypted DNS (DoH)" OK "resolves + no leak to ISP"
elif [ "$doh" = yes ] && [ "$res" = yes ]; then
  result "7. Encrypted DNS (DoH)" WARN "works, but peerdns!=0 (possible leak)"
else
  result "7. Encrypted DNS (DoH)" FAIL "proxy=$doh resolves=$res"
fi

# 8. AdBlock — enabled + functional test across several ad/tracker domains
ab=$(uci -q get adblock-fast.config.enabled)
blocked=no
for d in doubleclick.net googleadservices.com google-analytics.com ads.yahoo.com; do
  a=$(nslookup "$d" 127.0.0.1 2>/dev/null)
  if echo "$a" | grep -qiE '0\.0\.0\.0|NXDOMAIN|no answer|can.t|refused'; then
    blocked=yes; break
  fi
done
if [ "$ab" = "1" ] && [ "$blocked" = yes ]; then
  result "8. AdBlock" OK "blocks ad domains"
elif [ "$ab" = "1" ]; then
  result "8. AdBlock" WARN "enabled but blocked none of the tests (list not loaded?)"
else
  result "8. AdBlock" FAIL "service disabled"
fi

# 9. NTP with NTS (chrony), verified at RUNTIME (not just config):
#      - chronyd running, synchronized (chronyc tracking) and using NTS
#      - NO BusyBox ntpd process alive (if it runs, it steals port 123)
#      - real state of the "Enable NTP client" checkbox (system.ntp.enabled) = 0
#    Note: the Startup-page symlink is irrelevant; what decides whether it runs
#    is this flag. With it at 0, even hitting "Restart" on sysntpd makes the
#    init script exit right away and leaves NO ntpd alive -> that's why we look
#    at the real process, not the config alone.
if running chronyd; then
  sync=no;  chronyc -n tracking 2>/dev/null | grep -q "Leap status.*Normal" && sync=yes
  nts=no;   chronyc -N authdata 2>/dev/null | grep -qi "NTS" && nts=yes
  stray=no; pgrep ntpd >/dev/null 2>&1 && stray=yes
  ntpcli=$(uci -q get system.ntp.enabled); [ -z "$ntpcli" ] && ntpcli=1
  if [ "$stray" = yes ]; then
    result "9. NTP + NTS (chrony)" FAIL "BusyBox ntpd is alive: port 123 conflict"
  elif [ "$sync" = yes ] && [ "$nts" = yes ] && [ "$ntpcli" = "0" ]; then
    result "9. NTP + NTS (chrony)" OK "sync + NTS; no rival ntpd; NTP client off"
  elif [ "$sync" = yes ] && [ "$nts" = yes ]; then
    result "9. NTP + NTS (chrony)" WARN "works with NTS, but 'Enable NTP client' still ticked (enabled=$ntpcli)"
  elif [ "$sync" = yes ]; then
    result "9. NTP + NTS (chrony)" WARN "sync ok; nts=$nts (NTS handshake not yet?)"
  else
    result "9. NTP + NTS (chrony)" WARN "chrony running, not synced yet"
  fi
else
  result "9. NTP + NTS (chrony)" FAIL "chronyd not running"
fi

# 10. DDNS
dd=$(uci -q get ddns.@service[0].enabled)
ip=$(cat /var/run/ddns/*.ip 2>/dev/null | head -n1)
if [ "$dd" = "1" ] && [ -n "$ip" ]; then
  result "10. DDNS" OK "last IP: $ip"
elif [ "$dd" = "1" ]; then
  result "10. DDNS" WARN "enabled, no update recorded yet"
else
  result "10. DDNS" FAIL "service disabled"
fi

# 11. WireGuard (wg0 up + at least 1 peer)
if command -v wg >/dev/null 2>&1 && wg show wg0 >/dev/null 2>&1; then
  peers=$(wg show wg0 peers 2>/dev/null | grep -c .)
  port=$(wg show wg0 listen-port 2>/dev/null)
  if [ "$peers" -ge 1 ]; then
    result "11. WireGuard" OK "port $port, $peers peer(s)"
  else
    result "11. WireGuard" WARN "wg0 up, no peers"
  fi
else
  result "11. WireGuard" FAIL "wg0 is not up"
fi

printf "\n${B}Summary:${Z} ${G}%s OK${Z} · ${R}%s with issues${Z}\n\n" "$ok" "$fail"
