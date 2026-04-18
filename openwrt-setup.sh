#!/bin/sh
# openwrt-setup.sh — Privacy-hardening setup wizard for OpenWrt routers
#
# Hardware-agnostic: works on any OpenWrt device (x86, MIPS, ARM — tested on
# TP-Link ER605 v2 but no device-specific assumptions). 100% POSIX shell, no
# bashisms, no external dependencies beyond the OpenWrt base system.
#
# Idempotent: checks every item first, only applies fixes to what's missing or
# misconfigured, re-checks after fix. Safe to run repeatedly.
#
# Usage:
#   ssh root@192.168.1.1
#   sh openwrt-setup.sh              # Full wizard: base setup + optional WG at end
#   sh openwrt-setup.sh wg           # Skip base setup, go directly to WireGuard menu
#   sh openwrt-setup.sh wireguard    # Alias for 'wg'
#
# Language detection:
#   Automatic based on system timezone (Spanish for ES/LatAm timezones, English
#   for everything else). Override with:
#     OPENWRT_SETUP_LANG=es sh openwrt-setup.sh   # force Spanish
#     OPENWRT_SETUP_LANG=en sh openwrt-setup.sh   # force English
#
# Prompts only for: timezone (if not set), IPv6 disable (if not already disabled),
# and the WireGuard menu (optional, at the end).
#
# License: GPL-2.0

# --- CLI mode -----------------------------------------------------------------
# WG_ONLY=1         → jump to WireGuard menu (skip base setup)
# BLOCKLIST_ONLY=1  → jump to custom blocklist manager (skip base setup)
# (no arg)          → full wizard

WG_ONLY=0
BLOCKLIST_ONLY=0

# Fast-path: 'blocklist apply' is called by the hotplug hook at boot time.
# It needs to be fast and silent — skip i18n, pre-flight, everything.
# Just regenerate /tmp/dnsmasq.d/custom-blocklist.conf from /etc/custom-blocklist.txt
if [ "${1:-}" = "blocklist" ] && [ "${2:-}" = "apply" ]; then
    _bl_persist="/etc/custom-blocklist.txt"
    _bl_conf="/tmp/dnsmasq.d/custom-blocklist.conf"
    if [ -s "$_bl_persist" ]; then
        mkdir -p /tmp/dnsmasq.d
        sed '/^$/d' "$_bl_persist" | while read -r _d; do
            echo "local=/$_d/"
        done > "$_bl_conf"
    fi
    exit 0
fi

case "${1:-}" in
    wg|wireguard|-wg|--wg|--wireguard)
        WG_ONLY=1
        ;;
    blocklist|bl|--blocklist)
        BLOCKLIST_ONLY=1
        ;;
    '')
        : # Default: full wizard
        ;;
    -h|--help|help)
        if [ "${OPENWRT_SETUP_LANG:-}" = "es" ] || [ "${OPENWRT_SETUP_LANG:-}" = "ES" ]; then
            printf "Uso: sh %s [wg|wireguard|blocklist]\n" "$0"
            printf "  sin args   — wizard completo (base + WireGuard opcional)\n"
            printf "  wg         — ir directo al menú WireGuard (saltear base)\n"
            printf "  blocklist  — abrir el gestor de blocklist personalizada\n"
        else
            printf "Usage: sh %s [wg|wireguard|blocklist]\n" "$0"
            printf "  no args    — full wizard (base setup + optional WireGuard)\n"
            printf "  wg         — go directly to WireGuard menu (skip base setup)\n"
            printf "  blocklist  — open the custom blocklist manager\n"
        fi
        exit 0
        ;;
esac

# --- Internationalization (i18n) ---------------------------------------------
# Language detection: auto-detect from timezone. Override via OPENWRT_SETUP_LANG env:
#   OPENWRT_SETUP_LANG=es sh openwrt-setup.sh   # force Spanish
#   OPENWRT_SETUP_LANG=en sh openwrt-setup.sh   # force English

LANG_ES=0

_tz_is_spanish() {
    case "$1" in
        America/Argentina/*|America/Mexico_City|America/Bogota|America/Lima| \
        America/Santiago|America/Caracas|America/La_Paz|America/Asuncion| \
        America/Montevideo|America/Guayaquil|America/Guatemala| \
        America/Tegucigalpa|America/El_Salvador|America/Managua| \
        America/Costa_Rica|America/Panama|America/Havana| \
        America/Santo_Domingo|America/Puerto_Rico|Europe/Madrid| \
        Atlantic/Canary|Africa/Ceuta|Pacific/Easter)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

if [ -n "${OPENWRT_SETUP_LANG:-}" ]; then
    case "$OPENWRT_SETUP_LANG" in
        es|ES|es_*|ES_*) LANG_ES=1 ;;
        *) LANG_ES=0 ;;
    esac
elif command -v uci >/dev/null 2>&1; then
    _detected_tz=$(uci -q get system.@system[0].zonename 2>/dev/null)
    if [ -n "$_detected_tz" ] && _tz_is_spanish "$_detected_tz"; then
        LANG_ES=1
    fi
fi

_load_strings() {
    if [ "$LANG_ES" = "1" ]; then
        # --- Pre-flight ---
        L_RUNNING_AS_ROOT="Ejecutando como root"
        L_MUST_BE_ROOT="Debe ejecutarse como root"
        L_OPENWRT_DETECTED="OpenWrt detectado"
        L_NOT_OPENWRT="No es un sistema OpenWrt — este wizard no funcionará"
        L_LAN_CONFIG="LAN:"
        L_LAN_NOT_FOUND="No se encontró interfaz LAN — router mal configurado"
        L_WAN_REACHABLE="WAN alcanzable"
        L_WAN_UNREACHABLE="WAN inalcanzable — revisá el cable y el ISP"
        L_DNS_RESOLVING="DNS resolviendo"
        L_DNS_FALLBACK="Fallback DNS temporal OK (/tmp/resolv.conf — Quad9 filtered+ECS)"
        L_DNS_NOT_RESOLVING="DNS no resuelve — revisá conectividad WAN y reintentá"
        # --- Timezone ---
        L_TZ_LABEL="Zona horaria:"
        L_TZ_NOT_SET="Zona horaria no configurada (o en UTC)"
        L_TZ_PROMPT_NAME="  Ingresá el nombre de zona horaria (ej: Europe/Madrid, America/Argentina/Buenos_Aires) o vacío para saltar: "
        L_TZ_PROMPT_STRING="  Ingresá el POSIX timezone string (ej: CET-1CEST,M3.5.0,M10.5.0/3 para Madrid, <-03>3 para Argentina): "
        L_TZ_SET="Zona horaria configurada:"
        L_TZ_SKIPPED="Zona horaria saltada (sigue en UTC)"
        # --- IPv6 ---
        L_IPV6_TITLE="Elección IPv6"
        L_IPV6_PROMPT="  ¿Deshabilitar IPv6 completamente?"
        L_IPV6_DISABLED="IPv6 deshabilitado (wan6.disabled=1) — stack solo IPv4"
        L_IPV6_KEPT="IPv6 mantenido habilitado"
        L_IPV6_WAN6_DISABLED="network.wan6.disabled=1"
        L_IPV6_ULA_REMOVED="Prefijo ULA eliminado"
        L_IPV6_ODHCPD_DISABLED="odhcpd deshabilitado (daemon IPv6 DHCP/RA)"
        # --- Packages ---
        L_PKG_INSTALLED="Paquete:"
        L_PKG_NO_STALE_CHRONY="Sin config chrony-opkg huérfana"
        L_PKG_REMOVED_STALE="Eliminado /etc/config/chrony-opkg huérfano"
        # --- Encrypted DNS ---
        L_TOML_OK="TOML: listen=:5353 + Quad9 + config de caché"
        L_DNSCRYPT_ENABLED_BOOT="dnscrypt-proxy habilitado al boot"
        L_DNSMASQ_FORWARD="dnsmasq forward → 127.0.0.1#5353"
        L_DNSMASQ_NORESOLV="dnsmasq noresolv=1 (ignorar DNS del ISP)"
        L_DNSMASQ_LOGQUERIES="dnsmasq logqueries=0"
        L_WAN_PEERDNS="network.wan.peerdns=0"
        L_WAN_DNS="network.wan.dns=127.0.0.1"
        # --- Ad blocking ---
        L_CONFDIR_OK="dnsmasq confdir = /tmp/dnsmasq.d (entry única)"
        L_INITD_MKDIR="init.d/mkdir-dnsmasq-confdir (crea el dir al boot)"
        L_UPDATE_SCRIPT="/usr/sbin/update-blocklist.sh (fallback 3 mirrors)"
        L_HOTPLUG="Hotplug /etc/hotplug.d/iface/99-blocklist"
        L_CRON="Cron: refresh diario de blocklist a las 4 AM"
        L_BLOCKLIST_LOADED="Blocklist cargada (>100k dominios)"
        # --- NTP + NTS ---
        L_SYSNTPD_DISABLED="sysntpd deshabilitado (sin conflicto con chrony)"
        L_CHRONY_NTS="chrony: solo Cloudflare NTS (sin pools default)"
        L_CHRONY_NTS_YES="chrony server nts=yes"
        L_CHRONY_CONFD="chrony conf.d: port 123 + allow 192.168.1.0/24"
        L_CHRONY_CONFDIR="/etc/chrony/chrony.conf tiene 'confdir /etc/chrony/conf.d'"
        L_CHRONYD_BOOT="chronyd habilitado al boot"
        # --- Port security ---
        L_DNSMASQ_LAN="dnsmasq bindeado a LAN (interface=lan, notinterface=wan/wan6)"
        L_UHTTPD_LAN="uhttpd (LuCI) bindeado solo a LAN (192.168.1.1:80/443)"
        L_DROPBEAR_LAN="dropbear (SSH) bindeado a LAN"
        # --- Firewall ---
        L_LAN_ACCEPT="LAN zone input=ACCEPT (los clientes LAN pueden usar servicios del router)"
        L_WAN_DROP="WAN zone input policy = DROP"
        L_BLOCK_DNS="Rule: Block-WAN-DNS (tcpudp/53)"
        L_BLOCK_SSH="Rule: Block-WAN-SSH (tcp/22)"
        L_BLOCK_HTTP="Rule: Block-WAN-HTTP (tcp/80)"
        L_BLOCK_HTTPS="Rule: Block-WAN-HTTPS (tcp/443)"
        L_ALLOW_PING_DISABLED="Allow-Ping deshabilitado (regla stock default)"
        L_BLOCK_PING="Rule: Block-WAN-Ping (ICMP echo-request/ipv4)"
        L_DROP_INVALID="firewall drop_invalid=1"
        L_FLOW_OFFLOAD="firewall flow_offloading=1 (fastpath para flows establecidos)"
        # --- Performance ---
        L_PACKET_STEERING="packet_steering=1 (distribución en 2 cores)"
        L_DNSMASQ_CACHESIZE="dnsmasq cachesize=1000"
        L_LOG_BUFFER="Buffer de log del sistema = 32KB"
        # --- IPv6 verify ---
        L_IPV6_VERIFY_TITLE="IPv6 disable (verificando)"
        # --- Applying changes ---
        L_APPLY_TITLE="Aplicando cambios"
        L_NO_CHANGES="Sin cambios aplicados — ningún servicio necesita restart"
        L_RESTARTING="Reiniciando servicios que fueron modificados..."
        L_WAITING_SETTLE="Esperando 2s para que los servicios se estabilicen..."
        # --- Runtime verification ---
        L_RV_TITLE="Verificación en runtime"
        L_RV_5353="Puerto 5353 escuchando (dnscrypt-proxy)"
        L_RV_5353_FAIL="Puerto 5353 NO escuchando — dnscrypt-proxy no arrancó"
        L_RV_CHRONYD="chronyd proceso corriendo"
        L_RV_CHRONYD_FAIL="chronyd NO está corriendo"
        L_RV_RESOLV="/etc/resolv.conf usa solo 127.0.0.1 (sin leak al ISP)"
        L_RV_RESOLV_FAIL="/etc/resolv.conf tiene DNS del ISP — verificar wan.peerdns"
        L_RV_DNS_E2E="Resolución DNS: example.com via dnscrypt-proxy (cifrado)"
        L_RV_DNS_E2E_FAIL="Resolución DNS falló end-to-end"
        L_RV_DIG_MISSING="dig no disponible — saltando test E2E de DNS"
        # --- Summary ---
        L_SUMMARY_TITLE="Resumen"
        L_SUMMARY_TOML="  Config dnscrypt-proxy (/etc/dnscrypt-proxy2/dnscrypt-proxy.toml):"
        L_SUMMARY_ALREADY_OK="ya configurados"
        L_SUMMARY_FIXED_BY="arreglados por el wizard"
        L_SUMMARY_STILL_FAILING="siguen fallando"
        L_SUMMARY_TOTAL="checks en total"
        L_SUMMARY_ALL_PASSED="Todos los checks pasaron — tu router OpenWrt está configurado."
        L_SUMMARY_NEXT_STEPS="Próximos pasos:"
        L_SUMMARY_STEP1="1. Poné un password de root:"
        L_SUMMARY_STEP2="2. Verificá que no haya DNS leak:"
        L_SUMMARY_STEP3="3. Verificá stealth desde WAN:"
        L_SUMMARY_STEP4="4. Reiniciá y volvé a correr el wizard para confirmar persistencia:"
        L_SUMMARY_SOME_FAILED="check(s) aún fallan."
        L_SUMMARY_REVIEW="Revisá las entradas [!!] arriba."
        # --- WireGuard menu ---
        L_WG_TITLE_OPT="WireGuard VPN (opcional)"
        L_WG_TITLE_DIRECT="WireGuard VPN (modo directo)"
        L_WG_INTRO="  WireGuard VPN te permite conectarte a tu casa desde afuera."
        L_WG_REQUIREMENTS="  Requisitos:"
        L_WG_REQ_2="    2. Hostname/zona DDNS creado"
        L_WG_REQ_3="    3. Password del snippet de ddclient del servicio"
        L_WG_ALREADY_CFG="WireGuard ya configurado con"
        L_WG_ALREADY_CFG_SUFFIX="peer(s)"
        L_WG_Q_ENTER_MENU="  ¿Entrar al menú de WireGuard?"
        L_WG_Q_CONFIGURE="  ¿Configurar WireGuard?"
        L_WG_SKIPPING="Saltando WireGuard."
        L_WG_MENU_Q="  ¿Qué querés hacer?"
        L_WG_OPT_1="Instalar / reparar WireGuard"
        L_WG_OPT_1_HINT="(idempotente — setup completo)"
        L_WG_OPT_2="Ver / modificar configuración DDNS"
        L_WG_OPT_3="Ver peers / QR / agregar / eliminar"
        L_WG_OPT_4="Salir"
        L_WG_CHOOSE="  Elegí [1-4]: "
        L_WG_INVALID_OPT="Opción inválida."
        L_WG_EXIT_DIRECT="  Salida del modo WireGuard directo."
        L_WG_FULL_WIZARD="  Para el wizard completo (sin args):"
        # --- WG Option 1 ---
        L_WG1_TITLE="Opción 1: Instalar / reparar WireGuard"
        L_WG1_PKGS_OK="Todos los paquetes de WireGuard están instalados"
        L_WG1_PKGS_INSTALLING="Instalando paquetes faltantes:"
        L_WG1_APK_UPDATE_FAIL="apk update falló — ¿tenés internet?"
        L_WG1_PKGS_FAILED="Paquetes que NO se instalaron:"
        L_WG1_PKG_INSTALLED="Paquete instalado:"
        L_WG1_KMOD_LOADED="Módulo kernel WireGuard cargado"
        L_WG1_KMOD_FAIL="No se pudo cargar el módulo kernel WireGuard"
        L_WG1_DDNS_PRESENT="Config DDNS ya presente:"
        L_WG1_DDNS_MISSING="No hay config DDNS válida — vas a ingresarla ahora"
        L_WG1_DDNS_SAVED="Config DDNS guardada"
        L_WG1_DDNS_UCI="DDNS configurado en UCI"
        L_WG1_DDNS_ENABLED="DDNS servicio habilitado al boot"
        L_WG1_SERVER_KEYS_EXIST="Keys del servidor ya existen"
        L_WG1_SERVER_KEYS_GENERATED="Keys del servidor generadas"
        L_WG1_PEERS_TITLE="  --- Dispositivos (peers) ---"
        L_WG1_PEERS_INTRO1="  Cada dispositivo que se conecte al VPN necesita su propio peer."
        L_WG1_PEERS_INTRO2="  Usá nombres genéricos sin datos personales"
        L_WG1_PEERS_COUNT_Q="  ¿Cuántos dispositivos? [1-"
        L_WG1_PEERS_MUST_BE_NUM="Debe ser un número."
        L_WG1_PEERS_OUT_OF_RANGE="Debe ser entre 1 y"
        L_WG1_PEER_NAME_Q="  Nombre del dispositivo"
        L_WG1_PEER_NAME_HINT="(3-20 chars, [a-z0-9-])"
        L_WG1_PEER_NAME_DUP="Ya usaste ese nombre."
        L_WG1_PEER_NAME_INVALID="Inválido (ej válidos: peer-alpha, phone1, laptop-work)."
        L_WG1_KEYPAIR_EXISTS="Keypair existente para peer:"
        L_WG1_KEYPAIR_GENERATED="Keypair generado para peer:"
        L_WG1_DNSMASQ_WG0="dnsmasq escucha en wg0 (DNS para peers via tunnel)"
        L_WG1_ZONE="Zona firewall 'vpn' (wg0, ACCEPT+masq)"
        L_WG1_FW_VPN_WAN="Forwarding: vpn → wan (internet via tunnel)"
        L_WG1_FW_VPN_LAN="Forwarding: vpn → lan (acceso a red local)"
        L_WG1_APPLYING="Aplicando cambios..."
        L_WG1_NO_CHANGES="Sin cambios — nada que reiniciar"
        L_WG1_RV_TITLE="  --- WireGuard verificación en runtime ---"
        L_WG1_RV_WG0_UP="Interfaz wg0 up"
        L_WG1_RV_WG0_DOWN="Interfaz wg0 NO up"
        L_WG1_RV_PEERS="WireGuard tiene"
        L_WG1_RV_PEERS_SUFFIX="peer(s) configurados"
        L_WG1_COMPLETED="Instalación/reparación completada."
        L_WG1_SEE_QRS="  Para ver los QR de los peers, corré:"
        # --- WG Option 2 ---
        L_WG2_TITLE="Opción 2: DDNS (ver / modificar)"
        L_WG2_NO_VALID="No hay config DDNS válida guardada — tenés que ingresar los datos"
        L_WG2_CURRENT="  Configuración DDNS actual:"
        L_WG2_COMPARE="  Compará estos valores con el snippet de ddclient de tu servicio DDNS."
        L_WG2_Q_MODIFY="  ¿Modificar estos datos?"
        L_WG2_NO_CHANGES="Sin cambios"
        L_WG2_UPDATED="Config DDNS actualizada"
        L_WG2_NOT_MODIFIED="Datos sin modificar"
        # --- WG Option 3 ---
        L_WG3_TITLE="Opción 3: Peers"
        L_WG3_NO_DDNS="No hay config DDNS — corré primero la opción 1 o 2"
        L_WG3_NO_SERVER_KEY="No hay server.public — corré primero la opción 1 para generar keys"
        L_WG3_NO_PEERS="No hay peers configurados. Corré la opción 1 para crear el primero."
        L_WG3_REGISTERED="  Peers registrados:"
        L_WG3_ACTIONS="  Acciones:"
        L_WG3_A_SHOW_QR="Mostrar QR del peer"
        L_WG3_A_ADD="Agregar nuevo peer"
        L_WG3_A_REMOVE="Eliminar un peer"
        L_WG3_A_BACK="Volver al menú anterior"
        L_WG3_CHOOSE="  Elegí: "
        L_WG3_QR_WARNING="  ⚠ El QR contiene la private key — no compartas ni screenshotees."
        L_WG3_OUT_OF_RANGE="Número fuera de rango."
        L_WG3_NEW_NAME_Q="  Nombre del nuevo peer"
        L_WG3_NEW_NAME_HINT="(3-20 chars, [a-z0-9-], sin data sensible)"
        L_WG3_NEW_DUP="Ya existe un peer con ese nombre."
        L_WG3_MAX_REACHED="Máximo de"
        L_WG3_MAX_REACHED_SUFFIX="peers alcanzado"
        L_WG3_ADDED="Peer agregado:"
        L_WG3_NEW_QR="  QR del nuevo peer:"
        L_WG3_DEL_Q="  ¿Qué peer eliminar? [1-"
        L_WG3_NUM_INVALID="Número inválido."
        L_WG3_DEL_CONFIRM="  Confirmá eliminar"
        L_WG3_DEL_CONFIRM_SUFFIX="(perderá acceso)"
        L_WG3_CANCELLED="Cancelado"
        L_WG3_REMOVED="Peer eliminado:"
        L_WG3_NO_MORE="Sin peers. Saliendo de menú de peers."
        # --- DDNS fields prompt ---
        L_WGF_TITLE="  --- Datos del DDNS (del snippet de ddclient) ---"
        L_WGF_HINT_ENTER="  Apretá Enter para aceptar los valores por defecto [entre corchetes]."
        L_WGF_HINT_DOMAIN_FULL="  El campo \${BOLD}dominio\${NC} es el hostname que creaste en tu servicio DDNS."
        L_WGF_TOKEN_INVALID="Token inválido. Copiá lo que está entre comillas en"
        L_WGF_TOKEN_INVALID_HINT="         (solo letras y números, sin http://, sin < >)."
        L_WGF_DOMAIN_INVALID="Dominio inválido (debe tener al menos un punto, ej:"
        L_WGF_PS_EMPTY="protocol y server no pueden estar vacíos"
        L_WG_LBL_DOMAIN="dominio"
        # --- Section names ---
        L_SEC_PREFLIGHT="Pre-flight"
        L_SEC_TIMEZONE="Zona horaria"
        L_SEC_IPV6_CHOICE="Elección IPv6"
        L_SEC_PACKAGES="Paquetes"
        L_SEC_ENCRYPTED_DNS="DNS cifrado"
        L_SEC_AD_BLOCKING="Bloqueo de ads"
        L_SEC_NTP_NTS="NTP + NTS"
        L_SEC_PORT_SECURITY="Seguridad de puertos"
        L_SEC_FIREWALL="Firewall"
        L_SEC_PERFORMANCE="Rendimiento"
        # --- Custom Blocklist Manager ---
        L_BL_TITLE="Blocklist Personalizada"
        L_BL_ADD_TITLE="Blocklist Personalizada — Agregar Dominios"
        L_BL_LIST_TITLE="Blocklist Personalizada — Dominios Bloqueados"
        L_BL_REMOVE_TITLE="Blocklist Personalizada — Eliminar Dominios"
        L_BL_MENU_TITLE="Blocklist Personalizada — Menú"
        L_BL_SUBDOMAIN_INFO="Cada dominio va a ser bloqueado junto con todos sus subdominios."
        L_BL_EXAMPLE="Ejemplo:"
        L_BL_EXAMPLE_BLOCKS="bloquea reddit.com, www.reddit.com, old.reddit.com, etc."
        L_BL_CURRENT_COUNT="Dominios personalizados actualmente bloqueados:"
        L_BL_PROMPT_DOMAIN="Dominio a bloquear:"
        L_BL_PROMPT_ANOTHER="¿Otro dominio? (dominio / N para terminar):"
        L_BL_PROMPT_REMOVE="Dominio a eliminar (o N para terminar):"
        L_BL_INVALID="Formato de dominio inválido:"
        L_BL_ALREADY_BLOCKED="Ya está bloqueado:"
        L_BL_NOT_FOUND="No encontrado:"
        L_BL_QUEUED="Ya está en cola:"
        L_BL_WILL_REMOVE="Se eliminará:"
        L_BL_BLOCKED="Bloqueado:"
        L_BL_SUBDOMAINS_TOO="(+ todos los subdominios)"
        L_BL_EMPTY_LIST="No hay dominios personalizados bloqueados."
        L_BL_EMPTY_REMOVE="No hay dominios personalizados para eliminar."
        L_BL_NO_ADDED="No se agregaron dominios."
        L_BL_COUNT_COL="#"
        L_BL_DOMAIN_COL="Dominio"
        L_BL_TOTAL="Total:"
        L_BL_DOMAINS_SUFFIX="dominio(s)"
        L_BL_ADDED="Agregados"
        L_BL_REMOVED="Eliminados"
        L_BL_DOMAINS_RESTART="dominio(s) — dnsmasq reiniciado"
        L_BL_MENU_Q="¿Qué querés hacer?"
        L_BL_OPT_ADD="Agregar dominio(s)"
        L_BL_OPT_LIST="Listar dominios bloqueados"
        L_BL_OPT_REMOVE="Eliminar dominio(s)"
        L_BL_OPT_EXIT="Salir"
        L_BL_CHOOSE="Elegí [1-4]:"
        L_BL_INVALID_OPT="Opción inválida."
        L_BL_INSTALLING="Instalando en /usr/sbin/ para persistencia al boot..."
        L_BL_INSTALLED="Script instalado en"
        L_BL_HOTPLUG_PATCHED="Hook hotplug parcheado — la blocklist custom se cargará al boot"
        L_BL_HOTPLUG_EXISTS="Hook hotplug ya configurado"
        L_BL_HOTPLUG_CREATED="Hook hotplug creado (custom-blocklist)"
        L_BL_REMOVE_NOT_IN_LIST="Dominio no encontrado en la blocklist custom:"
        L_BL_REMOVED_SINGLE="Eliminado:"
    else
        # --- English (default) ---
        L_RUNNING_AS_ROOT="Running as root"
        L_MUST_BE_ROOT="Must be run as root"
        L_OPENWRT_DETECTED="OpenWrt detected"
        L_NOT_OPENWRT="Not an OpenWrt system — this wizard won't work"
        L_LAN_CONFIG="LAN:"
        L_LAN_NOT_FOUND="LAN interface not found — router misconfigured"
        L_WAN_REACHABLE="WAN reachable"
        L_WAN_UNREACHABLE="WAN unreachable — check cable and ISP"
        L_DNS_RESOLVING="DNS resolving"
        L_DNS_FALLBACK="Temporary DNS fallback working (/tmp/resolv.conf — Quad9 filtered+ECS)"
        L_DNS_NOT_RESOLVING="DNS still not resolving — check WAN connectivity and retry"
        L_TZ_LABEL="Timezone:"
        L_TZ_NOT_SET="Timezone is not configured (or UTC)"
        L_TZ_PROMPT_NAME="  Enter timezone name (e.g. Europe/Madrid, America/New_York, Asia/Tokyo) or empty to skip: "
        L_TZ_PROMPT_STRING="  Enter POSIX timezone string (e.g. CET-1CEST,M3.5.0,M10.5.0/3 for Madrid, EST5EDT,M3.2.0,M11.1.0 for NY, JST-9 for Tokyo): "
        L_TZ_SET="Timezone set:"
        L_TZ_SKIPPED="Timezone skipped (still UTC)"
        L_IPV6_TITLE="IPv6 choice"
        L_IPV6_PROMPT="  Disable IPv6 completely?"
        L_IPV6_DISABLED="IPv6 disabled (wan6.disabled=1) — IPv4-only stack"
        L_IPV6_KEPT="IPv6 kept enabled"
        L_IPV6_WAN6_DISABLED="network.wan6.disabled=1"
        L_IPV6_ULA_REMOVED="ULA prefix removed"
        L_IPV6_ODHCPD_DISABLED="odhcpd disabled (IPv6 DHCP/RA daemon)"
        L_PKG_INSTALLED="Package:"
        L_PKG_NO_STALE_CHRONY="No stale chrony-opkg config"
        L_PKG_REMOVED_STALE="Removed stale /etc/config/chrony-opkg"
        L_TOML_OK="TOML: listen=:5353 + Quad9 + cache config"
        L_DNSCRYPT_ENABLED_BOOT="dnscrypt-proxy enabled at boot"
        L_DNSMASQ_FORWARD="dnsmasq forward → 127.0.0.1#5353"
        L_DNSMASQ_NORESOLV="dnsmasq noresolv=1 (ignore ISP DNS)"
        L_DNSMASQ_LOGQUERIES="dnsmasq logqueries=0"
        L_WAN_PEERDNS="network.wan.peerdns=0"
        L_WAN_DNS="network.wan.dns=127.0.0.1"
        L_CONFDIR_OK="dnsmasq confdir = /tmp/dnsmasq.d (single entry)"
        L_INITD_MKDIR="init.d/mkdir-dnsmasq-confdir (creates dir on boot)"
        L_UPDATE_SCRIPT="/usr/sbin/update-blocklist.sh (3-mirror fallback)"
        L_HOTPLUG="Hotplug /etc/hotplug.d/iface/99-blocklist"
        L_CRON="Cron: daily blocklist refresh at 4 AM"
        L_BLOCKLIST_LOADED="Blocklist loaded (>100k domains)"
        L_SYSNTPD_DISABLED="sysntpd disabled (no conflict with chrony)"
        L_CHRONY_NTS="chrony: Cloudflare NTS only (no default pools)"
        L_CHRONY_NTS_YES="chrony server nts=yes"
        L_CHRONY_CONFD="chrony conf.d: port 123 + allow 192.168.1.0/24"
        L_CHRONY_CONFDIR="/etc/chrony/chrony.conf has 'confdir /etc/chrony/conf.d'"
        L_CHRONYD_BOOT="chronyd enabled at boot"
        L_DNSMASQ_LAN="dnsmasq bound to LAN (interface=lan, notinterface=wan/wan6)"
        L_UHTTPD_LAN="uhttpd (LuCI) bound to LAN only (192.168.1.1:80/443)"
        L_DROPBEAR_LAN="dropbear (SSH) bound to LAN"
        L_LAN_ACCEPT="LAN zone input=ACCEPT (LAN clients can use router services)"
        L_WAN_DROP="WAN zone input policy = DROP"
        L_BLOCK_DNS="Rule: Block-WAN-DNS (tcpudp/53)"
        L_BLOCK_SSH="Rule: Block-WAN-SSH (tcp/22)"
        L_BLOCK_HTTP="Rule: Block-WAN-HTTP (tcp/80)"
        L_BLOCK_HTTPS="Rule: Block-WAN-HTTPS (tcp/443)"
        L_ALLOW_PING_DISABLED="Allow-Ping disabled (default stock rule)"
        L_BLOCK_PING="Rule: Block-WAN-Ping (ICMP echo-request/ipv4)"
        L_DROP_INVALID="firewall drop_invalid=1"
        L_FLOW_OFFLOAD="firewall flow_offloading=1 (fastpath for established flows)"
        L_PACKET_STEERING="packet_steering=1 (2-core distribution)"
        L_DNSMASQ_CACHESIZE="dnsmasq cachesize=1000"
        L_LOG_BUFFER="System log buffer = 32KB"
        L_IPV6_VERIFY_TITLE="IPv6 disable (verifying)"
        L_APPLY_TITLE="Applying changes"
        L_NO_CHANGES="No changes applied — no services need restart"
        L_RESTARTING="Restarting services that were modified..."
        L_WAITING_SETTLE="Waiting 2s for services to settle..."
        L_RV_TITLE="Runtime verification"
        L_RV_5353="Port 5353 listening (dnscrypt-proxy)"
        L_RV_5353_FAIL="Port 5353 NOT listening — dnscrypt-proxy didn't start"
        L_RV_CHRONYD="chronyd process running"
        L_RV_CHRONYD_FAIL="chronyd NOT running"
        L_RV_RESOLV="/etc/resolv.conf uses only 127.0.0.1 (no ISP DNS leak)"
        L_RV_RESOLV_FAIL="/etc/resolv.conf has ISP DNS — check wan.peerdns"
        L_RV_DNS_E2E="DNS resolution: example.com via dnscrypt-proxy (encrypted)"
        L_RV_DNS_E2E_FAIL="End-to-end DNS resolution failed"
        L_RV_DIG_MISSING="dig not available — skipping end-to-end DNS test"
        L_SUMMARY_TITLE="Summary"
        L_SUMMARY_TOML="  dnscrypt-proxy config (/etc/dnscrypt-proxy2/dnscrypt-proxy.toml):"
        L_SUMMARY_ALREADY_OK="already configured"
        L_SUMMARY_FIXED_BY="fixed by wizard"
        L_SUMMARY_STILL_FAILING="still failing"
        L_SUMMARY_TOTAL="total checks"
        L_SUMMARY_ALL_PASSED="All checks passed — your OpenWrt router is configured."
        L_SUMMARY_NEXT_STEPS="Next steps:"
        L_SUMMARY_STEP1="1. Set a root password:"
        L_SUMMARY_STEP2="2. Verify no DNS leak:"
        L_SUMMARY_STEP3="3. Verify stealth from WAN:"
        L_SUMMARY_STEP4="4. Reboot and re-run this wizard to confirm persistence:"
        L_SUMMARY_SOME_FAILED="check(s) still failing."
        L_SUMMARY_REVIEW="Review the [!!] entries above."
        L_WG_TITLE_OPT="WireGuard VPN (optional)"
        L_WG_TITLE_DIRECT="WireGuard VPN (direct mode)"
        L_WG_INTRO="  WireGuard VPN lets you connect to your home from anywhere."
        L_WG_REQUIREMENTS="  Requirements:"
        L_WG_REQ_2="    2. DDNS hostname/zone created"
        L_WG_REQ_3="    3. Password from the service's ddclient snippet"
        L_WG_ALREADY_CFG="WireGuard already configured with"
        L_WG_ALREADY_CFG_SUFFIX="peer(s)"
        L_WG_Q_ENTER_MENU="  Enter the WireGuard menu?"
        L_WG_Q_CONFIGURE="  Configure WireGuard?"
        L_WG_SKIPPING="Skipping WireGuard."
        L_WG_MENU_Q="  What do you want to do?"
        L_WG_OPT_1="Install / repair WireGuard"
        L_WG_OPT_1_HINT="(idempotent — full setup)"
        L_WG_OPT_2="View / modify DDNS configuration"
        L_WG_OPT_3="View peers / QR / add / remove"
        L_WG_OPT_4="Exit"
        L_WG_CHOOSE="  Choose [1-4]: "
        L_WG_INVALID_OPT="Invalid option."
        L_WG_EXIT_DIRECT="  Exiting WireGuard direct mode."
        L_WG_FULL_WIZARD="  For the full wizard (no args):"
        L_WG1_TITLE="Option 1: Install / repair WireGuard"
        L_WG1_PKGS_OK="All WireGuard packages are installed"
        L_WG1_PKGS_INSTALLING="Installing missing packages:"
        L_WG1_APK_UPDATE_FAIL="apk update failed — do you have internet?"
        L_WG1_PKGS_FAILED="Packages that FAILED to install:"
        L_WG1_PKG_INSTALLED="Package installed:"
        L_WG1_KMOD_LOADED="WireGuard kernel module loaded"
        L_WG1_KMOD_FAIL="Could not load WireGuard kernel module"
        L_WG1_DDNS_PRESENT="DDNS config already present:"
        L_WG1_DDNS_MISSING="No valid DDNS config — you'll enter it now"
        L_WG1_DDNS_SAVED="DDNS config saved"
        L_WG1_DDNS_UCI="DDNS configured in UCI"
        L_WG1_DDNS_ENABLED="DDNS service enabled at boot"
        L_WG1_SERVER_KEYS_EXIST="Server keys already exist"
        L_WG1_SERVER_KEYS_GENERATED="Server keys generated"
        L_WG1_PEERS_TITLE="  --- Devices (peers) ---"
        L_WG1_PEERS_INTRO1="  Each device connecting to the VPN needs its own peer."
        L_WG1_PEERS_INTRO2="  Use generic names without personal data"
        L_WG1_PEERS_COUNT_Q="  How many devices? [1-"
        L_WG1_PEERS_MUST_BE_NUM="Must be a number."
        L_WG1_PEERS_OUT_OF_RANGE="Must be between 1 and"
        L_WG1_PEER_NAME_Q="  Name for device"
        L_WG1_PEER_NAME_HINT="(3-20 chars, [a-z0-9-])"
        L_WG1_PEER_NAME_DUP="You already used that name."
        L_WG1_PEER_NAME_INVALID="Invalid (valid examples: peer-alpha, phone1, laptop-work)."
        L_WG1_KEYPAIR_EXISTS="Existing keypair for peer:"
        L_WG1_KEYPAIR_GENERATED="Keypair generated for peer:"
        L_WG1_DNSMASQ_WG0="dnsmasq listens on wg0 (DNS for tunnel peers)"
        L_WG1_ZONE="Firewall zone 'vpn' (wg0, ACCEPT+masq)"
        L_WG1_FW_VPN_WAN="Forwarding: vpn → wan (internet via tunnel)"
        L_WG1_FW_VPN_LAN="Forwarding: vpn → lan (local network access)"
        L_WG1_APPLYING="Applying changes..."
        L_WG1_NO_CHANGES="No changes — nothing to restart"
        L_WG1_RV_TITLE="  --- WireGuard runtime verification ---"
        L_WG1_RV_WG0_UP="Interface wg0 up"
        L_WG1_RV_WG0_DOWN="Interface wg0 NOT up"
        L_WG1_RV_PEERS="WireGuard has"
        L_WG1_RV_PEERS_SUFFIX="peer(s) configured"
        L_WG1_COMPLETED="Install/repair completed."
        L_WG1_SEE_QRS="  To see peer QR codes, run:"
        L_WG2_TITLE="Option 2: DDNS (view / modify)"
        L_WG2_NO_VALID="No valid DDNS config saved — you need to enter the data"
        L_WG2_CURRENT="  Current DDNS configuration:"
        L_WG2_COMPARE="  Compare these values against your DDNS service's ddclient snippet."
        L_WG2_Q_MODIFY="  Modify this data?"
        L_WG2_NO_CHANGES="No changes"
        L_WG2_UPDATED="DDNS config updated"
        L_WG2_NOT_MODIFIED="Data unchanged"
        L_WG3_TITLE="Option 3: Peers"
        L_WG3_NO_DDNS="No DDNS config — first run option 1 or 2"
        L_WG3_NO_SERVER_KEY="No server.public — first run option 1 to generate keys"
        L_WG3_NO_PEERS="No peers configured. Run option 1 to create the first one."
        L_WG3_REGISTERED="  Registered peers:"
        L_WG3_ACTIONS="  Actions:"
        L_WG3_A_SHOW_QR="Show peer's QR"
        L_WG3_A_ADD="Add new peer"
        L_WG3_A_REMOVE="Remove a peer"
        L_WG3_A_BACK="Back to previous menu"
        L_WG3_CHOOSE="  Choose: "
        L_WG3_QR_WARNING="  ⚠ The QR contains the private key — do not share or screenshot."
        L_WG3_OUT_OF_RANGE="Number out of range."
        L_WG3_NEW_NAME_Q="  New peer name"
        L_WG3_NEW_NAME_HINT="(3-20 chars, [a-z0-9-], no sensitive data)"
        L_WG3_NEW_DUP="A peer with that name already exists."
        L_WG3_MAX_REACHED="Maximum of"
        L_WG3_MAX_REACHED_SUFFIX="peers reached"
        L_WG3_ADDED="Peer added:"
        L_WG3_NEW_QR="  QR for the new peer:"
        L_WG3_DEL_Q="  Which peer to delete? [1-"
        L_WG3_NUM_INVALID="Invalid number."
        L_WG3_DEL_CONFIRM="  Confirm deleting"
        L_WG3_DEL_CONFIRM_SUFFIX="(will lose access)"
        L_WG3_CANCELLED="Cancelled"
        L_WG3_REMOVED="Peer removed:"
        L_WG3_NO_MORE="No more peers. Leaving peers menu."
        L_WGF_TITLE="  --- DDNS fields (from ddclient snippet) ---"
        L_WGF_HINT_ENTER="  Press Enter to accept the default values [in brackets]."
        L_WGF_HINT_DOMAIN_FULL="  The \${BOLD}domain\${NC} field is the hostname you created at your DDNS service."
        L_WGF_TOKEN_INVALID="Invalid token. Copy what's between the quotes in"
        L_WGF_TOKEN_INVALID_HINT="         (letters and digits only, no http://, no < >)."
        L_WGF_DOMAIN_INVALID="Invalid domain (needs at least one dot, e.g."
        L_WGF_PS_EMPTY="protocol and server cannot be empty"
        L_WG_LBL_DOMAIN="domain"
        L_SEC_PREFLIGHT="Pre-flight"
        L_SEC_TIMEZONE="Timezone"
        L_SEC_IPV6_CHOICE="IPv6 choice"
        L_SEC_PACKAGES="Packages"
        L_SEC_ENCRYPTED_DNS="Encrypted DNS"
        L_SEC_AD_BLOCKING="Ad blocking"
        L_SEC_NTP_NTS="NTP + NTS"
        L_SEC_PORT_SECURITY="Port security"
        L_SEC_FIREWALL="Firewall"
        L_SEC_PERFORMANCE="Performance"
        # --- Custom Blocklist Manager ---
        L_BL_TITLE="Custom Blocklist"
        L_BL_ADD_TITLE="Custom Blocklist — Add Domains"
        L_BL_LIST_TITLE="Custom Blocklist — Blocked Domains"
        L_BL_REMOVE_TITLE="Custom Blocklist — Remove Domains"
        L_BL_MENU_TITLE="Custom Blocklist — Menu"
        L_BL_SUBDOMAIN_INFO="Each domain will be blocked with all of its subdomains."
        L_BL_EXAMPLE="Example:"
        L_BL_EXAMPLE_BLOCKS="blocks reddit.com, www.reddit.com, old.reddit.com, etc."
        L_BL_CURRENT_COUNT="Custom domains currently blocked:"
        L_BL_PROMPT_DOMAIN="Domain to block:"
        L_BL_PROMPT_ANOTHER="Another domain? (domain / N to finish):"
        L_BL_PROMPT_REMOVE="Domain to remove (or N to finish):"
        L_BL_INVALID="Invalid domain format:"
        L_BL_ALREADY_BLOCKED="Already blocked:"
        L_BL_NOT_FOUND="Not found:"
        L_BL_QUEUED="Already queued for removal:"
        L_BL_WILL_REMOVE="Will remove:"
        L_BL_BLOCKED="Blocked:"
        L_BL_SUBDOMAINS_TOO="(+ all subdomains)"
        L_BL_EMPTY_LIST="No custom blocked domains."
        L_BL_EMPTY_REMOVE="No custom blocked domains to remove."
        L_BL_NO_ADDED="No domains added."
        L_BL_COUNT_COL="#"
        L_BL_DOMAIN_COL="Domain"
        L_BL_TOTAL="Total:"
        L_BL_DOMAINS_SUFFIX="domain(s)"
        L_BL_ADDED="Added"
        L_BL_REMOVED="Removed"
        L_BL_DOMAINS_RESTART="domain(s) — dnsmasq restarted"
        L_BL_MENU_Q="What do you want to do?"
        L_BL_OPT_ADD="Add domain(s)"
        L_BL_OPT_LIST="List blocked domains"
        L_BL_OPT_REMOVE="Remove domain(s)"
        L_BL_OPT_EXIT="Exit"
        L_BL_CHOOSE="Choose [1-4]:"
        L_BL_INVALID_OPT="Invalid option."
        L_BL_INSTALLING="Installing to /usr/sbin/ for boot persistence..."
        L_BL_INSTALLED="Script installed to"
        L_BL_HOTPLUG_PATCHED="Hotplug hook patched — custom blocklist will load on boot"
        L_BL_HOTPLUG_EXISTS="Hotplug hook already configured"
        L_BL_HOTPLUG_CREATED="Hotplug hook created (custom-blocklist)"
        L_BL_REMOVE_NOT_IN_LIST="Domain not found in custom blocklist:"
        L_BL_REMOVED_SINGLE="Removed:"
    fi
}

_load_strings

# Note: no `set -e` — many idempotent/optional commands legitimately return
# non-zero (uci -q get on missing fields, service stop on non-running services,
# etc.). Critical errors are caught explicitly with `if` + `exit 1`.

# --- Colors and result markers ------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BRIGHT_CYAN='\033[1;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# --- Counters for final summary -----------------------------------------------

TOTAL_OK=0
TOTAL_FIXED=0
TOTAL_FAIL=0

# --- Dirty flags: services that need restart at the end -----------------------
# Each fix marks which services it affected. At the end we restart each service
# exactly once, but only if something was actually changed.

DIRTY_NETWORK=0
DIRTY_DNSMASQ=0
DIRTY_FIREWALL=0
DIRTY_DNSCRYPT=0
DIRTY_CHRONYD=0
DIRTY_UHTTPD=0
DIRTY_DROPBEAR=0
DIRTY_LOG=0

# --- Pretty-printing helpers --------------------------------------------------

section() {
    printf "\n${BOLD}${BLUE}=== %s ===${NC}\n\n" "$1"
}

info() {
    printf "  ${CYAN}[i]${NC}    %s\n" "$1"
}

ok() {
    printf "  ${GREEN}[ok]${NC}   %s\n" "$1"
    TOTAL_OK=$((TOTAL_OK + 1))
}

fixed() {
    printf "  ${YELLOW}[fix]${NC}  %s\n" "$1"
    TOTAL_FIXED=$((TOTAL_FIXED + 1))
}

fail() {
    printf "  ${RED}[!!]${NC}   %s\n" "$1"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
}

warn() {
    # Purely informational, doesn't count toward any total
    printf "  ${YELLOW}[??]${NC}   %s\n" "$1"
}

# Special markers for IPv6 choice (not an error — it's a user choice).
# These count as "ok" in the totals since the config is intentional.

ipv4() {
    printf "  ${MAGENTA}[ipv4]${NC} %s\n" "$1"
    TOTAL_OK=$((TOTAL_OK + 1))
}

ipv6() {
    printf "  ${BRIGHT_CYAN}[ipv6]${NC} %s\n" "$1"
    TOTAL_OK=$((TOTAL_OK + 1))
}

# --- The core check_and_fix pattern -------------------------------------------
#
# Usage:
#   check_and_fix "label" check_function fix_function [marker]
#
# where:
#   - check_function returns 0 if the item is correctly configured, non-zero otherwise
#   - fix_function applies the fix (no need to return anything meaningful)
#   - marker (optional) = "ipv4" to use [ipv4] instead of [ok] for passing checks
#
# Flow:
#   1. Run check. If passes → print [ok] (or [ipv4]) and return.
#   2. If fails → run fix silently.
#   3. Re-run check. If now passes → print [fix]. If still fails → print [!!].

check_and_fix() {
    label="$1"
    check_fn="$2"
    fix_fn="$3"
    marker="${4:-ok}"

    if "$check_fn"; then
        if [ "$marker" = "ipv4" ]; then
            ipv4 "$label"
        else
            ok "$label"
        fi
        return 0
    fi

    # Run fix (silently — any output would be noise if the fix worked)
    "$fix_fn" >/dev/null 2>&1

    if "$check_fn"; then
        fixed "$label"
        return 0
    fi

    fail "$label"
    return 1
}

# --- Yes/no prompt helper -----------------------------------------------------

prompt_yn() {
    # $1 = question, $2 = default (y or n)
    _default="${2:-n}"
    if [ "$_default" = "y" ]; then
        _hint="[Y/n]"
    else
        _hint="[y/N]"
    fi
    printf "%s %s " "$1" "$_hint"
    read -r _reply
    [ -z "$_reply" ] && _reply="$_default"
    case "$_reply" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}
# =============================================================================
# WireGuard VPN module — menu-driven, idempotent, POSIX
# =============================================================================
#
# Invoked either:
#   • at the end of the full wizard via a y/n prompt (wg_entry_point), OR
#   • directly via `sh openwrt-setup.sh wg` which sets WG_ONLY=1
#
# Menu options (after the initial y/n):
#   [1] Install / repair WireGuard (idempotent — the main action)
#   [2] View or modify DDNS (dynv6) config
#   [3] View peers / regenerate QR / add / remove
#   [4] Exit
#
# Data files owned by this module:
#   /etc/openwrt-setup-wireguard.conf      — DDNS hostname + token (mode 600)
#   /etc/wireguard/peers.list      — "name:ip" one per line (mode 600)
#   /etc/wireguard/<name>.private  — peer private key (mode 600)
#   /etc/wireguard/<name>.public   — peer public key (mode 644)
#   /etc/wireguard/server.private  — server private key (mode 600)
#   /etc/wireguard/server.public   — server public key (mode 644)

# --- WireGuard constants ------------------------------------------------------

WG_CONF_FILE="/etc/openwrt-setup-wireguard.conf"
WG_DIR="/etc/wireguard"
WG_PEERS_LIST="$WG_DIR/peers.list"
WG_SUBNET_BASE="10.8.0"
WG_SERVER_IP="10.8.0.1"
WG_PORT="51820"
WG_KEEPALIVE="25"
WG_MAX_PEERS=10

WG_PACKAGES="wireguard-tools kmod-wireguard luci-proto-wireguard qrencode ddns-scripts ddns-scripts-services luci-app-ddns"

# Dirty flags specific to WG operations. Shared with base-wizard flags if running
# in full-wizard mode (DIRTY_NETWORK, DIRTY_FIREWALL, DIRTY_DNSMASQ). In WG_ONLY
# mode, these are independent and applied at the end of the WG action.
WG_DIRTY_DDNS=0

# --- Low-level helpers --------------------------------------------------------

wg_prompt_field() {
    # Prompt with a default value shown in brackets.
    # $1 label, $2 default, $3 output var name
    _label="$1"
    _default="$2"
    _varname="$3"
    if [ -n "$_default" ]; then
        printf "  ${BOLD}%-10s${NC} [${CYAN}%s${NC}]: " "$_label" "$_default"
    else
        printf "  ${BOLD}%-10s${NC}: " "$_label"
    fi
    read -r _input
    if [ -z "$_input" ]; then
        _input="$_default"
    fi
    # Strip surrounding quotes (people often copy password='xxx' with the quotes)
    _input=$(printf "%s" "$_input" | sed "s/^['\"]//;s/['\"]$//")
    eval "$_varname=\"\$_input\""
}

wg_validate_token() {
    _t="$1"
    case "$_t" in
        ''|'<'*|*'>'*) return 1 ;;
        http*|*'?'*|*'&'*|*'='*|*' '*|*'/'*) return 1 ;;
    esac
    _len=$(printf "%s" "$_t" | wc -c)
    [ "$_len" -ge 20 ]
}

wg_validate_hostname() {
    _h="$1"
    case "$_h" in
        ''|*' '*|http*|*'/'*) return 1 ;;
    esac
    case "$_h" in
        *.*) return 0 ;;
        *)   return 1 ;;
    esac
}

wg_validate_peer_name() {
    # Must be 3-20 chars, [a-z0-9-], start with letter
    _n="$1"
    case "$_n" in
        ''|*[!a-z0-9-]*) return 1 ;;
        [!a-z]*) return 1 ;;
    esac
    _len=$(printf "%s" "$_n" | wc -c)
    [ "$_len" -ge 3 ] && [ "$_len" -le 20 ]
}

wg_obfuscate_token() {
    # Show only first 4 + last 4 chars of a token, preserving length info
    _tok="$1"
    _len=$(printf "%s" "$_tok" | wc -c)
    if [ "$_len" -lt 10 ]; then
        printf "(too short: %d chars)" "$_len"
    else
        _first=$(printf "%s" "$_tok" | cut -c1-4)
        _last=$(printf "%s" "$_tok" | awk '{print substr($0, length($0)-3)}')
        printf "%s...%s (length=%d)" "$_first" "$_last" "$_len"
    fi
}

wg_is_configured() {
    # Truthy if WG server keys exist AND wg0 UCI section is present
    [ -s "$WG_DIR/server.private" ] && \
    [ "$(uci -q get network.wg0)" = "interface" ]
}

wg_load_peers() {
    # Reads $WG_PEERS_LIST into $PEER_NAMES and $PEER_IPS (space-separated).
    # Both are set to empty if file missing.
    PEER_NAMES=""
    PEER_IPS=""
    if [ -f "$WG_PEERS_LIST" ]; then
        while IFS=':' read -r _pname _pip; do
            [ -z "$_pname" ] && continue
            case "$_pname" in '#'*) continue ;; esac
            PEER_NAMES="$PEER_NAMES $_pname"
            PEER_IPS="$PEER_IPS $_pip"
        done < "$WG_PEERS_LIST"
    fi
}

wg_save_peers() {
    # Writes $PEER_NAMES / $PEER_IPS to $WG_PEERS_LIST
    umask 077
    : > "$WG_PEERS_LIST"
    _i=1
    for _n in $PEER_NAMES; do
        _ip=$(echo "$PEER_IPS" | awk -v idx=$_i '{print $idx}')
        echo "$_n:$_ip" >> "$WG_PEERS_LIST"
        _i=$((_i + 1))
    done
    chmod 600 "$WG_PEERS_LIST"
}

wg_gen_keypair() {
    _priv="$1"
    _pub="$2"
    umask 077
    wg genkey | tee "$_priv" | wg pubkey > "$_pub"
    chmod 600 "$_priv"
    chmod 644 "$_pub"
}

wg_next_free_ip_octet() {
    # Returns next available .N for $WG_SUBNET_BASE.N (2 through WG_MAX_PEERS+1)
    _next=2
    for _ip in $PEER_IPS; do
        _octet="${_ip##*.}"
        [ "$_octet" -ge "$_next" ] && _next=$((_octet + 1))
    done
    echo "$_next"
}

wg_peer_uci_section_name() {
    # UCI section names can't contain dashes; strip them
    echo "wg_peer_$(echo "$1" | tr -d '-')"
}

# --- DDNS config: load, validate, persist -------------------------------------

wg_load_ddns_config() {
    # Populates DYNV6_HOSTNAME and DYNV6_TOKEN from $WG_CONF_FILE.
    # Returns 0 if both values loaded AND valid; 1 otherwise.
    DYNV6_HOSTNAME=""
    DYNV6_TOKEN=""

    if [ -f "$WG_CONF_FILE" ]; then
        # shellcheck disable=SC1090
        . "$WG_CONF_FILE" 2>/dev/null || true
    fi

    # Validate loaded values (may be empty, may be stale/broken)
    _valid=1
    if [ -n "${DYNV6_TOKEN:-}" ] && ! wg_validate_token "$DYNV6_TOKEN"; then
        _valid=0
    fi
    if [ -n "${DYNV6_HOSTNAME:-}" ] && ! wg_validate_hostname "$DYNV6_HOSTNAME"; then
        _valid=0
    fi

    [ "$_valid" = "1" ] && [ -n "${DYNV6_HOSTNAME:-}" ] && [ -n "${DYNV6_TOKEN:-}" ]
}

wg_save_ddns_config() {
    umask 077
    cat > "$WG_CONF_FILE" << EOF
# openwrt-setup WireGuard configuration — do not share this file
DYNV6_HOSTNAME="$DYNV6_HOSTNAME"
DYNV6_TOKEN="$DYNV6_TOKEN"
EOF
    chmod 600 "$WG_CONF_FILE"
}

wg_prompt_ddns_fields() {
    # Asks for all 5 DDNS fields via prompts.
    # Uses existing $DYNV6_HOSTNAME and $DYNV6_TOKEN as defaults if set.
    echo ""
    printf "  ${BOLD}%s${NC}\n\n" "$L_WGF_TITLE"
    printf "  ${CYAN}%s${NC}\n" "$L_WGF_HINT_ENTER"
    if [ "$LANG_ES" = "1" ]; then
        printf "  ${CYAN}El campo ${BOLD}dominio${NC}${CYAN} es el hostname que creaste en tu servicio DDNS.${NC}\n\n"
    else
        printf "  ${CYAN}The ${BOLD}domain${NC}${CYAN} field is the hostname you created at your DDNS service.${NC}\n\n"
    fi

    wg_prompt_field "protocol"  "dyndns2"    DYNV6_PROTOCOL
    wg_prompt_field "server"    "dynv6.com"  DYNV6_SERVER
    wg_prompt_field "login"     "none"       DYNV6_LOGIN

    while true; do
        wg_prompt_field "password"  "${DYNV6_TOKEN:-}"  DYNV6_TOKEN
        if wg_validate_token "$DYNV6_TOKEN"; then
            break
        fi
        printf "  ${RED}[!!]${NC}   %s ${BOLD}password='...'${NC}\n" "$L_WGF_TOKEN_INVALID"
        printf "%s\n\n" "$L_WGF_TOKEN_INVALID_HINT"
    done

    while true; do
        wg_prompt_field "dominio"  "${DYNV6_HOSTNAME:-}"  DYNV6_HOSTNAME
        if wg_validate_hostname "$DYNV6_HOSTNAME"; then
            break
        fi
        printf "  ${RED}[!!]${NC}   %s ${BOLD}sub.ejemplo.com${NC}).\n\n" "$L_WGF_DOMAIN_INVALID"
    done

    # protocol + server must be non-empty; the script has been tested with
    # the dyndns2 protocol on dynv6.com. Other combinations may work if
    # ddns-scripts-services has the matching template file, but are untested.
    if [ -z "$DYNV6_PROTOCOL" ] || [ -z "$DYNV6_SERVER" ]; then
        fail "$L_WGF_PS_EMPTY"
        return 1
    fi
    return 0
}

# --- Packages -----------------------------------------------------------------

wg_ensure_packages() {
    # Returns 0 if all packages are installed (or install succeeded); 1 otherwise.
    _missing=""
    for _pkg in $WG_PACKAGES; do
        if ! apk info -e "$_pkg" >/dev/null 2>&1; then
            _missing="$_missing $_pkg"
        fi
    done

    if [ -z "$_missing" ]; then
        ok "$L_WG1_PKGS_OK"
        return 0
    fi

    info "$L_WG1_PKGS_INSTALLING$_missing"
    if ! apk update >/dev/null 2>&1; then
        fail "$L_WG1_APK_UPDATE_FAIL"
        return 1
    fi
    # shellcheck disable=SC2086
    apk add $_missing >/dev/null 2>&1
    _install_rc=$?
    _still_missing=""
    for _pkg in $_missing; do
        if ! apk info -e "$_pkg" >/dev/null 2>&1; then
            _still_missing="$_still_missing $_pkg"
        fi
    done
    if [ -n "$_still_missing" ]; then
        fail "$L_WG1_PKGS_FAILED$_still_missing"
        return 1
    fi
    for _pkg in $_missing; do
        fixed "$L_WG1_PKG_INSTALLED $_pkg"
    done
    return 0
}

wg_ensure_kernel_module() {
    if ! lsmod | grep -q '^wireguard'; then
        modprobe wireguard 2>/dev/null || true
        sleep 1
    fi
    if lsmod | grep -q '^wireguard'; then
        ok "$L_WG1_KMOD_LOADED"
        return 0
    fi
    fail "$L_WG1_KMOD_FAIL"
    return 1
}

# --- DDNS service (UCI) checks ------------------------------------------------

wg_check_ddns_service() {
    [ "$(uci -q get ddns.dynv6_v4.enabled)" = "1" ] || return 1
    [ "$(uci -q get ddns.dynv6_v4.service_name)" = "dynv6.com" ] || return 1
    [ "$(uci -q get ddns.dynv6_v4.lookup_host)" = "$DYNV6_HOSTNAME" ] || return 1
    [ "$(uci -q get ddns.dynv6_v4.domain)" = "$DYNV6_HOSTNAME" ] || return 1
    [ "$(uci -q get ddns.dynv6_v4.password)" = "$DYNV6_TOKEN" ] || return 1
    [ "$(uci -q get ddns.dynv6_v4.use_ipv6)" = "0" ] || return 1
    return 0
}

wg_fix_ddns_service() {
    uci -q delete ddns.dynv6_v4 2>/dev/null || true
    uci set ddns.dynv6_v4=service
    uci set ddns.dynv6_v4.enabled='1'
    uci set ddns.dynv6_v4.service_name='dynv6.com'
    uci set ddns.dynv6_v4.lookup_host="$DYNV6_HOSTNAME"
    uci set ddns.dynv6_v4.domain="$DYNV6_HOSTNAME"
    uci set ddns.dynv6_v4.username='none'
    uci set ddns.dynv6_v4.password="$DYNV6_TOKEN"
    uci set ddns.dynv6_v4.use_ipv6='0'
    uci set ddns.dynv6_v4.ip_source='web'
    uci set ddns.dynv6_v4.ip_url='https://api.ipify.org'
    uci set ddns.dynv6_v4.interface='wan'
    uci set ddns.dynv6_v4.check_interval='10'
    uci set ddns.dynv6_v4.check_unit='minutes'
    uci set ddns.dynv6_v4.force_interval='72'
    uci set ddns.dynv6_v4.force_unit='hours'
    uci set ddns.dynv6_v4.retry_count='5'
    uci commit ddns
    WG_DIRTY_DDNS=1
}

wg_check_ddns_enabled() {
    /etc/init.d/ddns enabled 2>/dev/null
}

wg_fix_ddns_enabled() {
    /etc/init.d/ddns enable
    WG_DIRTY_DDNS=1
}

# --- wg0 interface ------------------------------------------------------------

wg_check_wg0_iface() {
    [ "$(uci -q get network.wg0)" = "interface" ] || return 1
    [ "$(uci -q get network.wg0.proto)" = "wireguard" ] || return 1
    [ "$(uci -q get network.wg0.private_key)" = "$SERVER_PRIVATE_KEY" ] || return 1
    [ "$(uci -q get network.wg0.listen_port)" = "$WG_PORT" ] || return 1
    uci -q get network.wg0.addresses 2>/dev/null | grep -q "$WG_SERVER_IP/24" || return 1
    return 0
}

wg_fix_wg0_iface() {
    uci -q delete network.wg0 2>/dev/null || true
    uci set network.wg0=interface
    uci set network.wg0.proto='wireguard'
    uci set network.wg0.private_key="$SERVER_PRIVATE_KEY"
    uci set network.wg0.listen_port="$WG_PORT"
    uci add_list network.wg0.addresses="$WG_SERVER_IP/24"
    uci commit network
    DIRTY_NETWORK=1
}

# --- Firewall helpers ---------------------------------------------------------

wg_find_zone_idx() {
    _target="$1"
    _idx=0
    while uci -q get "firewall.@zone[$_idx].name" >/dev/null 2>&1; do
        _zn=$(uci -q get "firewall.@zone[$_idx].name")
        if [ "$_zn" = "$_target" ]; then
            echo "$_idx"
            return 0
        fi
        _idx=$((_idx + 1))
    done
    return 1
}

wg_check_vpn_zone() {
    _idx=$(wg_find_zone_idx "vpn") || return 1
    [ "$(uci -q get "firewall.@zone[$_idx].input")" = "ACCEPT" ] || return 1
    [ "$(uci -q get "firewall.@zone[$_idx].output")" = "ACCEPT" ] || return 1
    [ "$(uci -q get "firewall.@zone[$_idx].forward")" = "ACCEPT" ] || return 1
    [ "$(uci -q get "firewall.@zone[$_idx].masq")" = "1" ] || return 1
    uci -q get "firewall.@zone[$_idx].network" 2>/dev/null | grep -q "wg0" || return 1
    return 0
}

wg_fix_vpn_zone() {
    _idx=$(wg_find_zone_idx "vpn")
    if [ -n "$_idx" ]; then
        uci -q delete "firewall.@zone[$_idx]" 2>/dev/null || true
    fi
    uci add firewall zone >/dev/null
    uci set firewall.@zone[-1].name='vpn'
    uci set firewall.@zone[-1].input='ACCEPT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].forward='ACCEPT'
    uci set firewall.@zone[-1].masq='1'
    uci set firewall.@zone[-1].mtu_fix='1'
    uci add_list firewall.@zone[-1].network='wg0'
    uci commit firewall
    DIRTY_FIREWALL=1
}

wg_check_forwarding_exists() {
    _src="$1"
    _dest="$2"
    _idx=0
    while uci -q get "firewall.@forwarding[$_idx]" >/dev/null 2>&1; do
        _s=$(uci -q get "firewall.@forwarding[$_idx].src")
        _d=$(uci -q get "firewall.@forwarding[$_idx].dest")
        if [ "$_s" = "$_src" ] && [ "$_d" = "$_dest" ]; then
            return 0
        fi
        _idx=$((_idx + 1))
    done
    return 1
}

wg_fix_forwarding() {
    _src="$1"
    _dest="$2"
    uci add firewall forwarding >/dev/null
    uci set firewall.@forwarding[-1].src="$_src"
    uci set firewall.@forwarding[-1].dest="$_dest"
    uci commit firewall
    DIRTY_FIREWALL=1
}

wg_check_fw_vpn_wan() { wg_check_forwarding_exists "vpn" "wan"; }
wg_fix_fw_vpn_wan() { wg_fix_forwarding "vpn" "wan"; }
wg_check_fw_vpn_lan() { wg_check_forwarding_exists "vpn" "lan"; }
wg_fix_fw_vpn_lan() { wg_fix_forwarding "vpn" "lan"; }

wg_check_allow_wg_rule() {
    [ "$(uci -q get firewall.allow_wireguard)" = "rule" ] || return 1
    [ "$(uci -q get firewall.allow_wireguard.src)" = "wan" ] || return 1
    [ "$(uci -q get firewall.allow_wireguard.proto)" = "udp" ] || return 1
    [ "$(uci -q get firewall.allow_wireguard.dest_port)" = "$WG_PORT" ] || return 1
    [ "$(uci -q get firewall.allow_wireguard.target)" = "ACCEPT" ] || return 1
    return 0
}

wg_fix_allow_wg_rule() {
    # Delete any anonymous 'Allow-WireGuard' rules first
    _idx=0
    while uci -q get "firewall.@rule[$_idx]" >/dev/null 2>&1; do
        _name=$(uci -q get "firewall.@rule[$_idx].name")
        if [ "$_name" = "Allow-WireGuard" ]; then
            uci -q delete "firewall.@rule[$_idx]"
            continue
        fi
        _idx=$((_idx + 1))
    done
    uci -q delete firewall.allow_wireguard 2>/dev/null || true
    uci set firewall.allow_wireguard=rule
    uci set firewall.allow_wireguard.name='Allow-WireGuard'
    uci set firewall.allow_wireguard.src='wan'
    uci set firewall.allow_wireguard.proto='udp'
    uci set firewall.allow_wireguard.dest_port="$WG_PORT"
    uci set firewall.allow_wireguard.target='ACCEPT'
    uci commit firewall
    DIRTY_FIREWALL=1
}

# --- dnsmasq on wg0 -----------------------------------------------------------

wg_check_dnsmasq_wg0() {
    _iflist=$(uci -q get dhcp.@dnsmasq[0].interface 2>/dev/null)
    for _if in $_iflist; do
        [ "$_if" = "wg0" ] && return 0
    done
    return 1
}

wg_fix_dnsmasq_wg0() {
    uci add_list dhcp.@dnsmasq[0].interface='wg0'
    uci commit dhcp
    DIRTY_DNSMASQ=1
}

# --- Apply changes (only restart services that changed) -----------------------

wg_apply_changes() {
    _total=$((DIRTY_NETWORK + DIRTY_FIREWALL + DIRTY_DNSMASQ + WG_DIRTY_DDNS))
    if [ "$_total" -eq 0 ]; then
        info "$L_WG1_NO_CHANGES"
        return 0
    fi
    info "$L_WG1_APPLYING"
    if [ "$DIRTY_NETWORK" = "1" ]; then
        info "  → network (wg0 up)"
        service network reload 2>/dev/null || service network restart
        sleep 3
        # Defensive: `service network reload` doesn't always materialize newly-created
        # interfaces like wg0 (only modifies existing ones). If wg0 doesn't exist yet
        # at kernel level, force it up explicitly. This is a no-op when wg0 already exists.
        if ! ip link show wg0 >/dev/null 2>&1; then
            ifup wg0 2>/dev/null
            sleep 2
        fi
    fi
    if [ "$DIRTY_FIREWALL" = "1" ]; then
        info "  → firewall"
        service firewall reload 2>/dev/null || service firewall restart
    fi
    if [ "$DIRTY_DNSMASQ" = "1" ]; then
        info "  → dnsmasq"
        service dnsmasq restart
    fi
    if [ "$WG_DIRTY_DDNS" = "1" ]; then
        info "  → ddns"
        /etc/init.d/ddns restart 2>/dev/null || true
    fi
    sleep 2
}

# --- Print QR + config for a single peer --------------------------------------

wg_print_peer_qr() {
    _name="$1"
    _ip="$2"

    if [ ! -s "$WG_DIR/$_name.private" ]; then
        if [ "$LANG_ES" = "1" ]; then fail "No hay private key para peer '$_name' en $WG_DIR/"; else fail "No private key for peer '$_name' in $WG_DIR/"; fi
        return 1
    fi

    _peer_priv=$(cat "$WG_DIR/$_name.private")
    SERVER_PUBLIC_KEY=$(cat "$WG_DIR/server.public" 2>/dev/null)

    if [ -z "$SERVER_PUBLIC_KEY" ]; then
        if [ "$LANG_ES" = "1" ]; then fail "No hay server.public key en $WG_DIR/"; else fail "No server.public key in $WG_DIR/"; fi
        return 1
    fi

    printf "\n${BOLD}${BRIGHT_CYAN}━━━ %s (%s) ━━━${NC}\n\n" "$_name" "$_ip"

    _config=$(cat << EOF
[Interface]
PrivateKey = $_peer_priv
Address = $_ip/24
DNS = $WG_SERVER_IP

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $DYNV6_HOSTNAME:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = $WG_KEEPALIVE
EOF
)

    printf "%s\n\n" "$_config" | qrencode -t ansiutf8
    echo ""
    return 0
}

# =============================================================================
# Menu option 1: Install / repair WireGuard (the main action)
# =============================================================================

wg_option_install() {
    echo ""
    printf "${BOLD}=== %s ===${NC}\n\n" "$L_WG1_TITLE"

    # 1. Packages + kernel module
    if ! wg_ensure_packages; then return 1; fi
    if ! wg_ensure_kernel_module; then return 1; fi

    # 2. DDNS config — prompt if missing/invalid
    if ! wg_load_ddns_config; then
        info "$L_WG1_DDNS_MISSING"
        if ! wg_prompt_ddns_fields; then return 1; fi
        wg_save_ddns_config
        ok "$L_WG1_DDNS_SAVED"
    else
        ok "$L_WG1_DDNS_PRESENT $DYNV6_HOSTNAME"
    fi

    # 3. DDNS service
    check_and_fix "$L_WG1_DDNS_UCI"   wg_check_ddns_service  wg_fix_ddns_service
    check_and_fix "$L_WG1_DDNS_ENABLED" wg_check_ddns_enabled  wg_fix_ddns_enabled

    # 4. Server keys
    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"
    if [ ! -s "$WG_DIR/server.private" ] || [ ! -s "$WG_DIR/server.public" ]; then
        wg_gen_keypair "$WG_DIR/server.private" "$WG_DIR/server.public"
        DIRTY_NETWORK=1
        fixed "$L_WG1_SERVER_KEYS_GENERATED"
    else
        ok "$L_WG1_SERVER_KEYS_EXIST"
    fi
    SERVER_PRIVATE_KEY=$(cat "$WG_DIR/server.private")
    SERVER_PUBLIC_KEY=$(cat "$WG_DIR/server.public")

    # 5. Peers — if no peers.list, prompt for initial setup
    wg_load_peers
    if [ -z "$PEER_NAMES" ]; then
        echo ""
        printf "  ${BOLD}%s${NC}\n" "$L_WG1_PEERS_TITLE"
        printf "  ${CYAN}%s${NC}\n" "$L_WG1_PEERS_INTRO1"
        printf "  ${CYAN}%s${NC}\n" "$L_WG1_PEERS_INTRO2"
        printf "  ${CYAN}(ej: ${BOLD}peer-alpha${NC}${CYAN}, ${BOLD}phone1${NC}${CYAN}, ${BOLD}laptop-work${NC}${CYAN})${NC}\n\n"

        while true; do
            printf "  ${BOLD}%s%s]:${NC} " "$L_WG1_PEERS_COUNT_Q" "$WG_MAX_PEERS"
            read -r _num_peers
            case "$_num_peers" in
                ''|*[!0-9]*)
                    printf "  ${RED}[!!]${NC}   %s\n\n" "$L_WG1_PEERS_MUST_BE_NUM"
                    continue
                    ;;
            esac
            if [ "$_num_peers" -ge 1 ] && [ "$_num_peers" -le $WG_MAX_PEERS ]; then
                break
            fi
            printf "  ${RED}[!!]${NC}   %s %s.\n\n" "$L_WG1_PEERS_OUT_OF_RANGE" "$WG_MAX_PEERS"
        done

        _i=1
        while [ "$_i" -le "$_num_peers" ]; do
            while true; do
                printf "  ${BOLD}%s %s${NC} ${DIM}%s${NC}: " "$L_WG1_PEER_NAME_Q" "$_i" "$L_WG1_PEER_NAME_HINT"
                read -r _pname
                _dup=0
                for _existing in $PEER_NAMES; do
                    [ "$_existing" = "$_pname" ] && _dup=1 && break
                done
                if [ "$_dup" = "1" ]; then
                    printf "  ${RED}[!!]${NC}   %s\n" "$L_WG1_PEER_NAME_DUP"
                    continue
                fi
                if wg_validate_peer_name "$_pname"; then
                    break
                fi
                printf "  ${RED}[!!]${NC}   %s\n" "$L_WG1_PEER_NAME_INVALID"
            done
            _pip="$WG_SUBNET_BASE.$((_i + 1))"
            PEER_NAMES="$PEER_NAMES $_pname"
            PEER_IPS="$PEER_IPS $_pip"
            _i=$((_i + 1))
        done
        wg_save_peers
        DIRTY_NETWORK=1
    fi

    # 6. Peer keypairs (one per peer)
    for _n in $PEER_NAMES; do
        if [ ! -s "$WG_DIR/$_n.private" ] || [ ! -s "$WG_DIR/$_n.public" ]; then
            wg_gen_keypair "$WG_DIR/$_n.private" "$WG_DIR/$_n.public"
            DIRTY_NETWORK=1
            fixed "$L_WG1_KEYPAIR_GENERATED $_n"
        else
            ok "$L_WG1_KEYPAIR_EXISTS $_n"
        fi
    done

    # 7. wg0 interface
    check_and_fix "Interfaz wg0 ($WG_SERVER_IP/24, port $WG_PORT)" wg_check_wg0_iface wg_fix_wg0_iface

    # 8. Peer UCI sections (dynamic — one check per peer)
    _i=1
    for _n in $PEER_NAMES; do
        _ip=$(echo "$PEER_IPS" | awk -v idx=$_i '{print $idx}')
        _section=$(wg_peer_uci_section_name "$_n")
        _pubkey=$(cat "$WG_DIR/$_n.public" 2>/dev/null)

        # Build dynamic check/fix via eval
        eval "wg_cp_$_i() {
            [ \"\$(uci -q get network.$_section)\" = \"wireguard_wg0\" ] || return 1
            [ \"\$(uci -q get network.$_section.public_key)\" = \"$_pubkey\" ] || return 1
            [ \"\$(uci -q get network.$_section.persistent_keepalive)\" = \"$WG_KEEPALIVE\" ] || return 1
            uci -q get network.$_section.allowed_ips 2>/dev/null | grep -q \"$_ip/32\" || return 1
            return 0
        }"

        eval "wg_fp_$_i() {
            uci -q delete network.$_section 2>/dev/null || true
            uci set network.$_section=wireguard_wg0
            uci set network.$_section.public_key=\"$_pubkey\"
            uci set network.$_section.description=\"$_n\"
            uci set network.$_section.persistent_keepalive=\"$WG_KEEPALIVE\"
            uci add_list network.$_section.allowed_ips=\"$_ip/32\"
            uci commit network
            DIRTY_NETWORK=1
        }"

        check_and_fix "Peer: $_n ($_ip)" "wg_cp_$_i" "wg_fp_$_i"
        _i=$((_i + 1))
    done

    # 9. dnsmasq listening on wg0 (DNS for tunnel peers)
    check_and_fix "$L_WG1_DNSMASQ_WG0" wg_check_dnsmasq_wg0 wg_fix_dnsmasq_wg0

    # 10. Firewall
    check_and_fix "$L_WG1_ZONE"     wg_check_vpn_zone      wg_fix_vpn_zone
    check_and_fix "$L_WG1_FW_VPN_WAN" wg_check_fw_vpn_wan    wg_fix_fw_vpn_wan
    check_and_fix "$L_WG1_FW_VPN_LAN" wg_check_fw_vpn_lan    wg_fix_fw_vpn_lan
    check_and_fix "Rule: Allow-WireGuard (UDP $WG_PORT en WAN)" wg_check_allow_wg_rule wg_fix_allow_wg_rule

    # 11. Apply changes
    wg_apply_changes

    # 12. Runtime verification
    echo ""
    printf "${BOLD}%s${NC}\n" "$L_WG1_RV_TITLE"
    if ip link show wg0 >/dev/null 2>&1; then
        ok "$L_WG1_RV_WG0_UP"
    else
        fail "$L_WG1_RV_WG0_DOWN"
    fi
    _peer_count=$(wg show wg0 peers 2>/dev/null | wc -l)
    _peer_count=${_peer_count:-0}
    _expected=$(echo "$PEER_NAMES" | wc -w)
    if [ "$_peer_count" -eq "$_expected" ]; then
        if [ "$LANG_ES" = "1" ]; then ok "WireGuard tiene $_peer_count peer(s) configurados"; else ok "WireGuard has $_peer_count peer(s) configured"; fi
    else
        if [ "$LANG_ES" = "1" ]; then fail "WireGuard tiene $_peer_count peer(s) activos (esperado $_expected)"; else fail "WireGuard has $_peer_count peer(s) active (expected $_expected)"; fi
    fi
    if netstat -lnu 2>/dev/null | grep -q ":$WG_PORT "; then
        if [ "$LANG_ES" = "1" ]; then ok "UDP $WG_PORT escuchando"; else ok "UDP $WG_PORT listening"; fi
    else
        if [ "$LANG_ES" = "1" ]; then fail "UDP $WG_PORT NO escuchando"; else fail "UDP $WG_PORT NOT listening"; fi
    fi
    # DNS on tunnel check
    if nslookup example.com "$WG_SERVER_IP" >/dev/null 2>&1; then
        if [ "$LANG_ES" = "1" ]; then ok "DNS por tunnel: dnsmasq responde en $WG_SERVER_IP:53"; else ok "DNS via tunnel: dnsmasq responds on $WG_SERVER_IP:53"; fi
    else
        if [ "$LANG_ES" = "1" ]; then fail "DNS por tunnel: dnsmasq NO responde en $WG_SERVER_IP:53"; else fail "DNS via tunnel: dnsmasq NOT responding on $WG_SERVER_IP:53"; fi
    fi
    # DDNS sync check
    _curip=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null)
    _resip=$(nslookup "$DYNV6_HOSTNAME" 2>/dev/null | awk '/^Address: / && !/127\./ && !/::1/ {print $2; exit}')
    if [ -n "$_curip" ] && [ -n "$_resip" ]; then
        if [ "$_curip" = "$_resip" ]; then
            ok "DDNS: $DYNV6_HOSTNAME → $_resip"
        else
            if [ "$LANG_ES" = "1" ]; then info "DDNS: $DYNV6_HOSTNAME → $_resip (WAN actual = $_curip — puede tardar)"; else info "DDNS: $DYNV6_HOSTNAME → $_resip (current WAN = $_curip — may take a minute)"; fi
        fi
    fi

    echo ""
    printf "  ${GREEN}${BOLD}✓ %s${NC}\n" "$L_WG1_COMPLETED"
    if [ "$LANG_ES" = "1" ]; then
        printf "  Para ver los QR de los peers, corré: ${CYAN}sh \$0 wg${NC} → opción 3\n"
    else
        printf "  To see peer QR codes, run: ${CYAN}sh \$0 wg${NC} → option 3\n"
    fi
    return 0
}

# =============================================================================
# Menu option 2: View or modify DDNS config
# =============================================================================

wg_option_ddns_view_modify() {
    echo ""
    printf "${BOLD}=== %s ===${NC}\n\n" "$L_WG2_TITLE"

    if ! wg_load_ddns_config; then
        info "$L_WG2_NO_VALID"
        if ! wg_prompt_ddns_fields; then return 1; fi
        wg_save_ddns_config
        ok "$L_WG1_DDNS_SAVED"
        # Apply to UCI too
        check_and_fix "$L_WG1_DDNS_UCI" wg_check_ddns_service wg_fix_ddns_service
        wg_apply_changes
        return 0
    fi

    # Show current values (token obfuscated).
    # These come from $WG_CONF_FILE (hostname/token) and UCI (protocol/server/login).
    _uci_proto=$(uci -q get ddns.dynv6_v4.ip_source 2>/dev/null)
    _uci_server=$(uci -q get ddns.dynv6_v4.service_name 2>/dev/null)
    _uci_login=$(uci -q get ddns.dynv6_v4.username 2>/dev/null)
    # We don't store protocol/server/login in $WG_CONF_FILE (only hostname+token),
    # so if UCI has values we use them; otherwise fall back to the standard dynv6
    # tuple (dyndns2 / dynv6.com / none) as that is the most common and the
    # default offered by the prompts.
    _disp_proto="${DYNV6_PROTOCOL:-dyndns2}"
    _disp_server="${_uci_server:-dynv6.com}"
    _disp_login="${_uci_login:-none}"

    printf "  ${BOLD}%s${NC}\n" "$L_WG2_CURRENT"
    printf "    ${BOLD}protocol${NC}  : %s\n" "$_disp_proto"
    printf "    ${BOLD}server${NC}    : %s\n" "$_disp_server"
    printf "    ${BOLD}login${NC}     : %s\n" "$_disp_login"
    printf "    ${BOLD}password${NC}  : %s\n" "$(wg_obfuscate_token "$DYNV6_TOKEN")"
    printf "    ${BOLD}%s${NC}   : $DYNV6_HOSTNAME\n\n" "$L_WG_LBL_DOMAIN"

    printf "  ${CYAN}%s${NC}\n" "$L_WG2_COMPARE"
    if [ "$LANG_ES" = "1" ]; then
        printf "  ${CYAN}Si el password coincide con el ${BOLD}password='...'${NC}${CYAN} del snippet, está OK.${NC}\n\n"
    else
        printf "  ${CYAN}If the password matches the ${BOLD}password='...'${NC}${CYAN} from the snippet, it's OK.${NC}\n\n"
    fi

    if prompt_yn "  ¿Modificar estos datos?" n; then
        # Re-prompt
        _old_host="$DYNV6_HOSTNAME"
        _old_tok="$DYNV6_TOKEN"
        if ! wg_prompt_ddns_fields; then return 1; fi
        # Detect change
        if [ "$DYNV6_HOSTNAME" = "$_old_host" ] && [ "$DYNV6_TOKEN" = "$_old_tok" ]; then
            info "$L_WG2_NO_CHANGES"
        else
            wg_save_ddns_config
            fixed "$L_WG2_UPDATED"
            # Apply to UCI
            check_and_fix "$L_WG2_UPDATED" wg_check_ddns_service wg_fix_ddns_service
            wg_apply_changes
        fi
    else
        info "$L_WG2_NOT_MODIFIED"
    fi
    return 0
}

# =============================================================================
# Menu option 3: Peers menu (view / regenerate QR / add / remove)
# =============================================================================

wg_option_peers_menu() {
    echo ""
    printf "${BOLD}=== %s ===${NC}\n\n" "$L_WG3_TITLE"

    # Need DDNS hostname to generate QR (endpoint field)
    if ! wg_load_ddns_config; then
        fail "$L_WG3_NO_DDNS"
        return 1
    fi

    # Need server.public for QR
    if [ ! -s "$WG_DIR/server.public" ]; then
        fail "$L_WG3_NO_SERVER_KEY"
        return 1
    fi

    wg_load_peers

    if [ -z "$PEER_NAMES" ]; then
        info "$L_WG3_NO_PEERS"
        return 0
    fi

    while true; do
        echo ""
        printf "  ${BOLD}%s${NC}\n" "$L_WG3_REGISTERED"
        _i=1
        for _n in $PEER_NAMES; do
            _ip=$(echo "$PEER_IPS" | awk -v idx=$_i '{print $idx}')
            printf "    ${BOLD}%d.${NC} %-20s ${DIM}(%s)${NC}\n" "$_i" "$_n" "$_ip"
            _i=$((_i + 1))
        done
        echo ""
        printf "  ${BOLD}%s${NC}\n" "$L_WG3_ACTIONS"
        printf "    ${BOLD}[1-$((_i-1))]${NC}  %s\n" "$L_WG3_A_SHOW_QR"
        printf "    ${BOLD}[a]${NC}    %s\n" "$L_WG3_A_ADD"
        printf "    ${BOLD}[r]${NC}    %s\n" "$L_WG3_A_REMOVE"
        printf "    ${BOLD}[v]${NC}    %s\n" "$L_WG3_A_BACK"
        printf "%s" "$L_WG3_CHOOSE"
        read -r _act

        case "$_act" in
            [0-9]|[1-9][0-9])
                # Show QR for peer $_act
                if [ "$_act" -ge 1 ] && [ "$_act" -lt "$_i" ] 2>/dev/null; then
                    _name=$(echo "$PEER_NAMES" | awk -v idx=$_act '{print $idx}')
                    _pip=$(echo "$PEER_IPS"  | awk -v idx=$_act '{print $idx}')
                    printf "\n  ${YELLOW}%s${NC}\n" "$L_WG3_QR_WARNING"
                    wg_print_peer_qr "$_name" "$_pip"
                else
                    printf "  ${RED}[!!]${NC}   %s\n" "$L_WG3_OUT_OF_RANGE"
                fi
                ;;
            a|A)
                # Add peer
                while true; do
                    printf "\n  ${BOLD}Nombre del nuevo peer${NC} ${DIM}(3-20 chars, [a-z0-9-], sin data sensible)${NC}: "
                    read -r _newname
                    _dup=0
                    for _existing in $PEER_NAMES; do
                        [ "$_existing" = "$_newname" ] && _dup=1 && break
                    done
                    if [ "$_dup" = "1" ]; then
                        printf "  ${RED}[!!]${NC}   %s\n" "$L_WG3_NEW_DUP"
                        continue
                    fi
                    if wg_validate_peer_name "$_newname"; then
                        break
                    fi
                    printf "  ${RED}[!!]${NC}   %s\n" "$L_WG3_NEW_DUP_INVALID"
                done
                _octet=$(wg_next_free_ip_octet)
                if [ "$_octet" -gt $((WG_MAX_PEERS + 1)) ]; then
                    fail "$L_WG3_MAX_REACHED $WG_MAX_PEERS $L_WG3_MAX_REACHED_SUFFIX"
                    continue
                fi
                _newip="$WG_SUBNET_BASE.$_octet"
                PEER_NAMES="$PEER_NAMES $_newname"
                PEER_IPS="$PEER_IPS $_newip"
                wg_save_peers
                wg_gen_keypair "$WG_DIR/$_newname.private" "$WG_DIR/$_newname.public"
                _pubkey=$(cat "$WG_DIR/$_newname.public")
                _section=$(wg_peer_uci_section_name "$_newname")
                uci set "network.$_section=wireguard_wg0"
                uci set "network.$_section.public_key=$_pubkey"
                uci set "network.$_section.description=$_newname"
                uci set "network.$_section.persistent_keepalive=$WG_KEEPALIVE"
                uci add_list "network.$_section.allowed_ips=$_newip/32"
                uci commit network
                DIRTY_NETWORK=1
                wg_apply_changes
                fixed "$L_WG3_ADDED $_newname ($_newip)"
                # Show QR for the new peer immediately
                printf "\n  ${CYAN}%s${NC}\n" "$L_WG3_NEW_QR"
                wg_print_peer_qr "$_newname" "$_newip"
                # Re-read peers for next iteration
                wg_load_peers
                _i=$(echo "$PEER_NAMES" | wc -w)
                _i=$((_i + 1))
                ;;
            r|R)
                # Remove peer
                printf "  ${BOLD}%s%d]:${NC} " "$L_WG3_DEL_Q" "$((_i-1))"
                read -r _del
                if [ -z "$_del" ] || ! [ "$_del" -ge 1 ] 2>/dev/null || ! [ "$_del" -lt "$_i" ] 2>/dev/null; then
                    printf "  ${RED}[!!]${NC}   %s\n" "$L_WG3_NUM_INVALID"
                    continue
                fi
                _delname=$(echo "$PEER_NAMES" | awk -v idx=$_del '{print $idx}')
                if ! prompt_yn "  Confirmá eliminar '$_delname' (perderá acceso)" n; then
                    info "$L_WG3_CANCELLED"
                    continue
                fi
                # Rebuild lists without that peer
                _new_names=""
                _new_ips=""
                _k=1
                for _n in $PEER_NAMES; do
                    if [ "$_k" != "$_del" ]; then
                        _new_names="$_new_names $_n"
                        _new_ips="$_new_ips $(echo "$PEER_IPS" | awk -v idx=$_k '{print $idx}')"
                    fi
                    _k=$((_k + 1))
                done
                PEER_NAMES="$_new_names"
                PEER_IPS="$_new_ips"
                wg_save_peers
                # Remove UCI section and key files
                _section=$(wg_peer_uci_section_name "$_delname")
                uci -q delete "network.$_section" 2>/dev/null || true
                uci commit network
                rm -f "$WG_DIR/$_delname.private" "$WG_DIR/$_delname.public"
                DIRTY_NETWORK=1
                wg_apply_changes
                fixed "$L_WG3_REMOVED $_delname"
                wg_load_peers
                _i=$(echo "$PEER_NAMES" | wc -w)
                _i=$((_i + 1))
                if [ -z "$PEER_NAMES" ]; then
                    info "$L_WG3_NO_MORE"
                    return 0
                fi
                ;;
            v|V|'')
                return 0
                ;;
            *)
                printf "  ${RED}[!!]${NC}   %s\n" "$L_WG_INVALID_OPT"
                ;;
        esac
    done
}

# =============================================================================
# WireGuard main menu
# =============================================================================

wg_main_menu() {
    # If called from full-wizard flow, first ask if user wants WG at all.
    # If called via WG_ONLY=1, skip the initial y/n — jump straight to menu.
    if [ "$WG_ONLY" != "1" ]; then
        section "WireGuard VPN (opcional)"
        printf "  ${CYAN}%s${NC}\n" "$L_WG_INTRO"
        printf "  ${CYAN}%s${NC}\n" "$L_WG_REQUIREMENTS"
        if [ "$LANG_ES" = "1" ]; then
            printf "    1. Cuenta en un servicio DDNS ${DIM}(recomendado: ${CYAN}https://dynv6.com${DIM} — gratis y FLOSS-friendly)${NC}\n"
        else
            printf "    1. Account at a DDNS service ${DIM}(recommended: ${CYAN}https://dynv6.com${DIM} — free and FLOSS-friendly)${NC}\n"
        fi
        printf "    %s\n" "$L_WG_REQ_2"
        printf "    %s\n\n" "$L_WG_REQ_3"
        if [ "$LANG_ES" = "1" ]; then
            printf "  ${YELLOW}Advertencia:${NC} esto abrirá UDP %s en WAN (silent-drop sin keys válidas)\n\n" "$WG_PORT"
        else
            printf "  ${YELLOW}Warning:${NC} this will open UDP %s on WAN (silent-drop without valid keys)\n\n" "$WG_PORT"
        fi
        if wg_is_configured; then
            _count=$(wg show wg0 peers 2>/dev/null | wc -l)
            _count=${_count:-0}
            printf "  ${CYAN}[i]${NC}    %s %s %s\n\n" "$L_WG_ALREADY_CFG" "$_count" "$L_WG_ALREADY_CFG_SUFFIX"
            if ! prompt_yn "  ¿Entrar al menú de WireGuard?" y; then
                info "$L_WG_SKIPPING"
                return 0
            fi
        else
            if ! prompt_yn "  ¿Configurar WireGuard?" n; then
                info "$L_WG_SKIPPING"
                return 0
            fi
        fi
    else
        section "WireGuard VPN (modo directo)"
    fi

    # Menu loop
    while true; do
        echo ""
        printf "  ${BOLD}%s${NC}\n" "$L_WG_MENU_Q"
        printf "    ${BOLD}[1]${NC}  %s ${DIM}%s${NC}\n" "$L_WG_OPT_1" "$L_WG_OPT_1_HINT"
        printf "    ${BOLD}[2]${NC}  %s\n" "$L_WG_OPT_2"
        printf "    ${BOLD}[3]${NC}  Ver peers / QR / agregar / eliminar\n"
        printf "    ${BOLD}[4]${NC}  Salir\n"
        printf "%s" "$L_WG_CHOOSE"
        read -r _choice
        case "$_choice" in
            1) wg_option_install ;;
            2) wg_option_ddns_view_modify ;;
            3) wg_option_peers_menu ;;
            4|q|Q|'') return 0 ;;
            *) printf "  ${RED}[!!]${NC}   %s\n" "$L_WG_INVALID_OPT" ;;
        esac
    done
}
# =============================================================================
# Custom Blocklist Manager module — menu-driven, bilingual, with hotplug persistence
# =============================================================================
#
# Storage:
#   /etc/custom-blocklist.txt           — domain list (one per line, persistent)
#   /tmp/dnsmasq.d/custom-blocklist.conf — generated dnsmasq conf (volatile)
#   /etc/hotplug.d/iface/98-custom-blocklist — boot-time regeneration hook
#
# Uses dnsmasq's "local=/domain/" format (wildcards: blocks domain + all subdomains)

BL_PERSIST="/etc/custom-blocklist.txt"
BL_CONFFILE="/tmp/dnsmasq.d/custom-blocklist.conf"
BL_INSTALL_PATH="/usr/sbin/openwrt-setup.sh"
BL_HOTPLUG_MAIN="/etc/hotplug.d/iface/99-blocklist"
BL_HOTPLUG_FALLBACK="/etc/hotplug.d/iface/98-custom-blocklist"

# --- Low-level helpers --------------------------------------------------------

bl_ensure_persist() {
    touch "$BL_PERSIST"
    chmod 644 "$BL_PERSIST"
}

bl_generate_conf() {
    mkdir -p /tmp/dnsmasq.d
    sed '/^$/d' "$BL_PERSIST" | while read -r _domain; do
        echo "local=/$_domain/"
    done > "$BL_CONFFILE"
}

bl_restart_dnsmasq() {
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
}

bl_count_domains() {
    _count=$(grep -c '[^[:space:]]' "$BL_PERSIST" 2>/dev/null)
    echo "${_count:-0}"
}

bl_is_valid_domain() {
    echo "$1" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$'
}

bl_is_already_blocked() {
    grep -qxF "$1" "$BL_PERSIST" 2>/dev/null
}

# --- Setup persistence (first-time install) ----------------------------------
# Ensures the script lives at /usr/sbin/openwrt-setup.sh and the hotplug hook
# knows to call it. Safe to call repeatedly (checks before acting).

bl_setup_persistence() {
    # 1. Install script to /usr/sbin/ if not already there
    _script_src=$(readlink -f "$0" 2>/dev/null)
    if [ -z "$_script_src" ]; then
        _script_src="$0"
    fi
    if [ "$_script_src" != "$BL_INSTALL_PATH" ] && [ ! -f "$BL_INSTALL_PATH" ]; then
        info "$L_BL_INSTALLING"
        cp "$_script_src" "$BL_INSTALL_PATH"
        chmod +x "$BL_INSTALL_PATH"
        ok "$L_BL_INSTALLED $BL_INSTALL_PATH"
    fi

    # 2. Patch or create hotplug hook
    if [ -f "$BL_HOTPLUG_MAIN" ] && ! grep -q "custom-blocklist\|blocklist apply" "$BL_HOTPLUG_MAIN"; then
        # Add a line BEFORE the existing update-blocklist.sh call
        sed -i '/\/usr\/sbin\/update-blocklist.sh/i\  '"$BL_INSTALL_PATH"' blocklist apply' "$BL_HOTPLUG_MAIN"
        ok "$L_BL_HOTPLUG_PATCHED"
    elif [ -f "$BL_HOTPLUG_MAIN" ] && grep -q "blocklist apply\|custom-blocklist" "$BL_HOTPLUG_MAIN"; then
        : # Already configured, silent
    else
        # Main hotplug doesn't exist — create our own fallback
        mkdir -p /etc/hotplug.d/iface
        cat > "$BL_HOTPLUG_FALLBACK" << HOOKEOF
#!/bin/sh
[ "\$ACTION" = ifup ] && [ "\$INTERFACE" = wan ] && {
  sleep 3
  $BL_INSTALL_PATH blocklist apply
}
HOOKEOF
        chmod +x "$BL_HOTPLUG_FALLBACK"
        ok "$L_BL_HOTPLUG_CREATED"
    fi
}

# --- Silent apply mode (used by hotplug at boot) -----------------------------

bl_apply_silent() {
    bl_ensure_persist
    if [ -s "$BL_PERSIST" ]; then
        bl_generate_conf
    fi
}

# --- List ---------------------------------------------------------------------

bl_list() {
    printf "\n${BOLD}=== %s ===${NC}\n\n" "$L_BL_LIST_TITLE"

    bl_ensure_persist
    if [ ! -s "$BL_PERSIST" ]; then
        printf "  ${YELLOW}%s${NC}\n\n" "$L_BL_EMPTY_LIST"
        return 0
    fi

    printf "  ${CYAN}%-4s  %s${NC}\n" "$L_BL_COUNT_COL" "$L_BL_DOMAIN_COL"
    printf "  %-4s  %s\n" "---" "------"
    _i=1
    while IFS= read -r _domain; do
        [ -z "$_domain" ] && continue
        printf "  %-4s  %s\n" "$_i" "$_domain"
        _i=$((_i + 1))
    done < "$BL_PERSIST"
    printf "\n  ${GREEN}%s $(bl_count_domains) %s${NC}\n\n" "$L_BL_TOTAL" "$L_BL_DOMAINS_SUFFIX"
}

# --- Add (interactive) --------------------------------------------------------

bl_add() {
    bl_ensure_persist
    printf "\n${BOLD}=== %s ===${NC}\n\n" "$L_BL_ADD_TITLE"
    printf "  %s\n" "$L_BL_SUBDOMAIN_INFO"
    printf "  %s ${CYAN}reddit.com${NC} %s\n\n" "$L_BL_EXAMPLE" "$L_BL_EXAMPLE_BLOCKS"
    printf "  ${YELLOW}%s $(bl_count_domains)${NC}\n\n" "$L_BL_CURRENT_COUNT"

    _added=0
    while true; do
        if [ $_added -eq 0 ]; then
            printf "  ${BOLD}%s${NC} " "$L_BL_PROMPT_DOMAIN"
        else
            printf "  ${BOLD}%s${NC} " "$L_BL_PROMPT_ANOTHER"
        fi
        read -r _input

        case "$_input" in
            [Nn])
                if [ $_added -eq 0 ]; then
                    printf "  ${YELLOW}%s${NC}\n\n" "$L_BL_NO_ADDED"
                    return 0
                fi
                break
                ;;
            "")
                continue
                ;;
            *)
                # Clean input: strip protocol, path, www prefix, lowercase
                # Note: BusyBox tr has bugs with [:upper:]/[:lower:] classes
                _domain=$(echo "$_input" | sed 's|^https*://||;s|/.*||;s|^www\.||' | tr 'A-Z' 'a-z')
                _domain=$(echo "$_domain" | tr -d ' ')

                [ -z "$_domain" ] && continue

                if ! bl_is_valid_domain "$_domain"; then
                    printf "  ${RED}✗ %s${NC} %s\n" "$L_BL_INVALID" "$_domain"
                    continue
                fi
                if bl_is_already_blocked "$_domain"; then
                    printf "  ${YELLOW}⚠ %s${NC} %s\n" "$L_BL_ALREADY_BLOCKED" "$_domain"
                    continue
                fi

                echo "$_domain" >> "$BL_PERSIST"
                _added=$((_added + 1))
                printf "  ${GREEN}✓ %s${NC} ${BOLD}%s${NC} ${GREEN}%s${NC}\n" "$L_BL_BLOCKED" "$_domain" "$L_BL_SUBDOMAINS_TOO"
                ;;
        esac
    done

    bl_generate_conf
    bl_restart_dnsmasq
    printf "\n  ${GREEN}✓ %s %d %s${NC}\n" "$L_BL_ADDED" "$_added" "$L_BL_DOMAINS_RESTART"
    printf "  ${GREEN}  %s $(bl_count_domains) %s${NC}\n\n" "$L_BL_TOTAL" "$L_BL_DOMAINS_SUFFIX"
}

# --- Remove (interactive) -----------------------------------------------------

bl_remove() {
    bl_ensure_persist
    printf "\n${BOLD}=== %s ===${NC}\n\n" "$L_BL_REMOVE_TITLE"

    if [ ! -s "$BL_PERSIST" ]; then
        printf "  ${YELLOW}%s${NC}\n\n" "$L_BL_EMPTY_REMOVE"
        return 0
    fi

    # Show current list first
    printf "  ${CYAN}%-4s  %s${NC}\n" "$L_BL_COUNT_COL" "$L_BL_DOMAIN_COL"
    printf "  %-4s  %s\n" "---" "------"
    _i=1
    while IFS= read -r _domain; do
        [ -z "$_domain" ] && continue
        printf "  %-4s  %s\n" "$_i" "$_domain"
        _i=$((_i + 1))
    done < "$BL_PERSIST"
    printf "\n"

    # Build queue of domains to remove, then rewrite file once at the end
    _queue="/tmp/openwrt-setup-bl-remove.$$"
    : > "$_queue"

    while true; do
        printf "  ${BOLD}%s${NC} " "$L_BL_PROMPT_REMOVE"
        read -r _input
        case "$_input" in
            [Nn]) break ;;
            "")   continue ;;
            *)
                if bl_is_already_blocked "$_input" && ! grep -qxF "$_input" "$_queue"; then
                    echo "$_input" >> "$_queue"
                    printf "  ${GREEN}✓ %s${NC} ${BOLD}%s${NC}\n" "$L_BL_WILL_REMOVE" "$_input"
                elif grep -qxF "$_input" "$_queue" 2>/dev/null; then
                    printf "  ${YELLOW}⚠ %s${NC} %s\n" "$L_BL_QUEUED" "$_input"
                else
                    printf "  ${RED}✗ %s${NC} %s\n" "$L_BL_NOT_FOUND" "$_input"
                fi
                ;;
        esac
    done

    if [ -s "$_queue" ]; then
        # Single rewrite — grep -vxFf filters out all queued domains at once
        grep -vxFf "$_queue" "$BL_PERSIST" > "${BL_PERSIST}.tmp" && mv "${BL_PERSIST}.tmp" "$BL_PERSIST"
        bl_generate_conf
        bl_restart_dnsmasq
        _removed_count=$(wc -l < "$_queue" 2>/dev/null)
        _removed_count=${_removed_count:-0}
        printf "\n  ${GREEN}✓ %s %s %s${NC}\n" "$L_BL_REMOVED" "$_removed_count" "$L_BL_DOMAINS_RESTART"
        printf "  ${GREEN}  %s $(bl_count_domains) %s${NC}\n\n" "$L_BL_TOTAL" "$L_BL_DOMAINS_SUFFIX"
    fi
    rm -f "$_queue"
}

# --- Main menu ---------------------------------------------------------------

bl_main_menu() {
    bl_ensure_persist
    # Setup persistence (install to /usr/sbin + hotplug hook) — silent if already done
    bl_setup_persistence

    while true; do
        printf "\n${BOLD}=== %s ===${NC}\n\n" "$L_BL_MENU_TITLE"
        printf "  ${YELLOW}%s $(bl_count_domains)${NC}\n\n" "$L_BL_CURRENT_COUNT"
        printf "  ${BOLD}%s${NC}\n" "$L_BL_MENU_Q"
        printf "    ${BOLD}[1]${NC}  %s\n" "$L_BL_OPT_ADD"
        printf "    ${BOLD}[2]${NC}  %s\n" "$L_BL_OPT_LIST"
        printf "    ${BOLD}[3]${NC}  %s\n" "$L_BL_OPT_REMOVE"
        printf "    ${BOLD}[4]${NC}  %s\n" "$L_BL_OPT_EXIT"
        printf "  ${BOLD}%s${NC} " "$L_BL_CHOOSE"
        read -r _choice
        case "$_choice" in
            1) bl_add ;;
            2) bl_list ;;
            3) bl_remove ;;
            4|q|Q|'') return 0 ;;
            *) printf "  ${RED}[!!]${NC}   %s\n" "$L_BL_INVALID_OPT" ;;
        esac
    done
}

# =============================================================================
# Pre-flight checks
# =============================================================================

section "$L_SEC_PREFLIGHT"

if [ "$(id -u)" -ne 0 ]; then
    fail "$L_MUST_BE_ROOT"
    exit 1
fi
ok "$L_RUNNING_AS_ROOT"

if ! grep -qi 'openwrt' /etc/os-release 2>/dev/null; then
    fail "$L_NOT_OPENWRT"
    exit 1
fi
ok "$L_OPENWRT_DETECTED ($(. /etc/openwrt_release && echo "$DISTRIB_RELEASE"))"

# Detect LAN IP + subnet (handle both legacy netmask and CIDR formats)
LAN_IP_RAW=$(uci -q get network.lan.ipaddr)
if [ -z "$LAN_IP_RAW" ]; then
    fail "$L_LAN_NOT_FOUND"
    exit 1
fi

case "$LAN_IP_RAW" in
    */*)
        LAN_IP="${LAN_IP_RAW%/*}"
        LAN_CIDR="${LAN_IP_RAW#*/}"
        ;;
    *)
        LAN_IP="$LAN_IP_RAW"
        LAN_NETMASK=$(uci -q get network.lan.netmask)
        # Convert netmask to CIDR
        case "$LAN_NETMASK" in
            255.255.255.0)   LAN_CIDR=24 ;;
            255.255.0.0)     LAN_CIDR=16 ;;
            255.0.0.0)       LAN_CIDR=8  ;;
            255.255.255.128) LAN_CIDR=25 ;;
            255.255.255.192) LAN_CIDR=26 ;;
            *)               LAN_CIDR=24 ;;  # sensible default
        esac
        ;;
esac

# Compute subnet (a.b.c.0/CIDR — simplified: zero the last octet for /24)
# For non-/24 subnets you'd need proper arithmetic; for typical home use /24 is fine.
LAN_A=$(echo "$LAN_IP" | cut -d. -f1)
LAN_B=$(echo "$LAN_IP" | cut -d. -f2)
LAN_C=$(echo "$LAN_IP" | cut -d. -f3)
LAN_SUBNET="${LAN_A}.${LAN_B}.${LAN_C}.0/${LAN_CIDR}"

ok "$L_LAN_CONFIG $LAN_IP ($LAN_SUBNET)"

# WAN reachable?
if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
    ok "$L_WAN_REACHABLE"
else
    fail "$L_WAN_UNREACHABLE"
    exit 1
fi

# Check DNS connectivity (needed for apk downloads later).
# We verify WAN connectivity (ping 1.1.1.1 — raw IP) and DNS resolution
# through the current configuration. If the router's own DNS isn't working
# right now, we try a temporary fallback via resolv.conf WITHOUT modifying UCI
# (the wizard will configure everything properly in the Encrypted DNS section).

# First: confirm we have IP connectivity
if ! ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
    fail "$L_WAN_UNREACHABLE"
    exit 1
fi

# Second: check if DNS resolves (via whatever the router has configured).
# We wait up to 10s for DNS to come up, in case network was just restarted.
DNS_WAIT=0
DNS_OK="no"
while [ "$DNS_WAIT" -lt 10 ]; do
    if nslookup downloads.openwrt.org >/dev/null 2>&1; then
        DNS_OK="yes"
        break
    fi
    sleep 1
    DNS_WAIT=$((DNS_WAIT + 1))
done

if [ "$DNS_OK" = "yes" ]; then
    ok "$L_DNS_RESOLVING"
else
    # DNS not working through the router. Fall back to direct /tmp/resolv.conf
    # so apk can still resolve downloads.openwrt.org. This file is transient
    # (regenerated by netifd on every interface event) and does NOT modify UCI.
    # Use Quad9 filtered+ECS (9.9.9.11 / 149.112.112.11) to match the
    # dnscrypt-proxy config this wizard sets up later.
    if [ "$LANG_ES" = "1" ]; then info "DNS no resuelve todavía — usando /tmp/resolv.conf temporal"; else info "DNS not resolving yet — using temporary /tmp/resolv.conf fallback"; fi
    mkdir -p /tmp/resolv.conf.d 2>/dev/null
    {
        echo "nameserver 9.9.9.11"
        echo "nameserver 149.112.112.11"
    } > /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null || \
    {
        echo "nameserver 9.9.9.11"
        echo "nameserver 149.112.112.11"
    } > /tmp/resolv.conf.auto 2>/dev/null || true
    sleep 1
    if nslookup downloads.openwrt.org >/dev/null 2>&1; then
        ok "$L_DNS_FALLBACK"
    else
        fail "$L_DNS_NOT_RESOLVING"
        exit 1
    fi
fi

# --- Short-circuit to WG menu if invoked as `sh openwrt-setup.sh wg` -----------
# After Pre-flight confirms OpenWrt + root + WAN, if WG_ONLY=1 we skip all the
# base wizard sections (timezone, DNS, firewall, etc.) and go straight to WG.

if [ "$WG_ONLY" = "1" ]; then
    wg_main_menu
    # Summary (lightweight — no check counters, just the WG action result)
    echo ""
    printf "  ${BOLD}%s${NC}\n" "$L_WG_EXIT_DIRECT"
    printf "%s ${CYAN}sh \$0${NC}\n\n" "$L_WG_FULL_WIZARD"
    exit 0
fi

# --- Short-circuit to Blocklist Manager if invoked as `sh openwrt-setup.sh blocklist` ---
# Same pattern as WG_ONLY: Pre-flight confirms basics, then jump to the menu.

if [ "$BLOCKLIST_ONLY" = "1" ]; then
    bl_main_menu
    exit 0
fi

# =============================================================================
# Timezone (interactive — only ask if not configured)
# =============================================================================

section "$L_SEC_TIMEZONE"

TZ_CURRENT=$(uci -q get system.@system[0].zonename)
TZ_STRING_CURRENT=$(uci -q get system.@system[0].timezone)

if [ -n "$TZ_CURRENT" ] && [ "$TZ_CURRENT" != "UTC" ] && [ -n "$TZ_STRING_CURRENT" ] && [ "$TZ_STRING_CURRENT" != "UTC" ]; then
    ok "$L_TZ_LABEL $TZ_CURRENT ($TZ_STRING_CURRENT)"
    TIMEZONE_NAME=""
    TIMEZONE_STRING=""
else
    info "$L_TZ_NOT_SET"
    printf "%s" "$L_TZ_PROMPT_NAME"
    read -r TIMEZONE_NAME
    if [ -n "$TIMEZONE_NAME" ]; then
        printf "%s" "$L_TZ_PROMPT_STRING"
        read -r TIMEZONE_STRING
    fi
    if [ -n "$TIMEZONE_NAME" ] && [ -n "$TIMEZONE_STRING" ]; then
        uci set system.@system[0].zonename="$TIMEZONE_NAME"
        uci set system.@system[0].timezone="$TIMEZONE_STRING"
        uci commit system
        fixed "$L_TZ_SET $TIMEZONE_NAME ($TIMEZONE_STRING)"
    else
        warn "$L_TZ_SKIPPED"
    fi
fi

# =============================================================================
# IPv6 choice (interactive — only ask if not already disabled)
# =============================================================================

section "$L_SEC_IPV6_CHOICE"

IPV6_DISABLED=$(uci -q get network.wan6.disabled)
if [ "$IPV6_DISABLED" = "1" ]; then
    ipv4 "$L_IPV6_DISABLED"
    DISABLE_IPV6="already"
else
    if [ "$LANG_ES" = "1" ]; then info "IPv6 está habilitado actualmente en WAN"; else info "IPv6 is currently enabled on WAN"; fi
    if prompt_yn "$L_IPV6_PROMPT" "n"; then
        DISABLE_IPV6="yes"
    else
        DISABLE_IPV6="no"
        ipv6 "$L_IPV6_KEPT (dual-stack)"
    fi
fi

# =============================================================================
# Packages
# =============================================================================

section "$L_SEC_PACKAGES"

check_apk_installed() {
    apk info -e "$1" >/dev/null 2>&1
}

# apk update — always refresh index (fast no-op if already current)
apk update >/dev/null 2>&1

# apk upgrade — update installed packages to their latest versions before
# installing new ones. Can take a few minutes on first run; silent no-op if
# everything is already current. Runs every time the wizard is executed.
if [ "$LANG_ES" = "1" ]; then
    info "Corriendo apk upgrade (puede tardar unos minutos)..."
else
    info "Running apk upgrade (this may take a few minutes)..."
fi
if apk upgrade >/dev/null 2>&1; then
    if [ "$LANG_ES" = "1" ]; then
        ok "apk upgrade completado"
    else
        ok "apk upgrade completed"
    fi
else
    if [ "$LANG_ES" = "1" ]; then
        warn "apk upgrade falló — continuando con los paquetes que ya tengas"
    else
        warn "apk upgrade failed — continuing with whatever packages you have"
    fi
fi

# chrony base must be removed before chrony-nts can be installed
if apk info -e chrony >/dev/null 2>&1 && ! apk info -e chrony-nts >/dev/null 2>&1; then
    info "$(if [ "$LANG_ES" = "1" ]; then echo "Removiendo chrony (conflicto con chrony-nts)"; else echo "Removing chrony (conflicts with chrony-nts)"; fi)"
    apk del chrony >/dev/null 2>&1
fi

for pkg in dnscrypt-proxy2 chrony-nts ca-certificates curl bind-dig; do
    if check_apk_installed "$pkg"; then
        ok "$L_PKG_INSTALLED $pkg"
    else
        if apk add "$pkg" >/dev/null 2>&1; then
            fixed "$L_PKG_INSTALLED $pkg (installed)"
        else
            fail "$L_PKG_INSTALLED $pkg (install failed)"
        fi
    fi
done

# Clean up leftover config from chrony-opkg package (if present)
if [ -f /etc/config/chrony-opkg ]; then
    rm -f /etc/config/chrony-opkg
    fixed "$L_PKG_REMOVED_STALE"
else
    ok "$L_PKG_NO_STALE_CHRONY"
fi


# =============================================================================
# DNS encrypted (dnscrypt-proxy2 + dnsmasq)
# =============================================================================

section "$L_SEC_ENCRYPTED_DNS"

TOML="/etc/dnscrypt-proxy2/dnscrypt-proxy.toml"

if [ ! -f "$TOML" ]; then
    if [ "$LANG_ES" = "1" ]; then fail "$TOML no existe (¿falta el paquete dnscrypt-proxy2?)"; else fail "$TOML not found (dnscrypt-proxy2 package missing?)"; fi
else
    # --- TOML block: listen_addresses + server_names + cache settings --------

    check_toml_block() {
        # Must have exactly one uncommented listen_addresses pointing to :5353
        # Note: grep -c returns "0\n" with rc=1 when no match. We do NOT chain
        # `|| echo 0` because that would produce "0\n0" (two lines) which breaks
        # numeric comparisons with -le / -eq.
        LISTEN_COUNT=$(grep -cE "^listen_addresses[[:space:]]*=" "$TOML" 2>/dev/null)
        LISTEN_COUNT=${LISTEN_COUNT:-0}
        [ "$LISTEN_COUNT" = "1" ] || return 1
        grep -E "^listen_addresses[[:space:]]*=" "$TOML" | grep -q ":5353" || return 1
        # Quad9 server must be selected
        grep -qE "^server_names[[:space:]]*=.*quad9" "$TOML" || return 1
        # cache = true top-level (not inside a [cache] section)
        grep -qE "^cache[[:space:]]*=[[:space:]]*true" "$TOML" || return 1
        # No duplicates of any top-level key (dnscrypt-proxy CRASHES on duplicates).
        # Use `[[:space:]]*=` boundary to avoid matching 'cache_size' when looking for 'cache'.
        for _key in block_ipv6 cert_ignore_timestamp server_names require_nofilter cache_size cache_min_ttl cache_max_ttl; do
            _dup=$(grep -cE "^${_key}[[:space:]]*=" "$TOML" 2>/dev/null)
            _dup=${_dup:-0}
            [ "$_dup" -le 1 ] || return 1
        done
        # No duplicate [cache] sections (also crashes dnscrypt-proxy)
        _cache_sections=$(grep -c "^\[cache\]" "$TOML" 2>/dev/null)
        _cache_sections=${_cache_sections:-0}
        [ "$_cache_sections" -le 1 ] || return 1
        # No duplicate 'cache = ' keys (boundary to avoid matching cache_size etc.)
        _cache_keys=$(grep -cE "^cache[[:space:]]*=" "$TOML" 2>/dev/null)
        _cache_keys=${_cache_keys:-0}
        [ "$_cache_keys" -le 1 ] || return 1
        return 0
    }

    fix_toml_block() {
        # Backup once
        [ ! -f "${TOML}.orig" ] && cp "$TOML" "${TOML}.orig"

        # Remove any previous openwrt-setup blocks first (idempotency)
        sed -i '/^# --- openwrt-setup START/,/^# --- openwrt-setup END/d' "$TOML"
        sed -i '/^# --- openwrt-setup cache START/,/^# --- openwrt-setup cache END/d' "$TOML"

        # Comment out any uncommented originals (no effect if already commented)
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

        # Insert our block BEFORE the first [section] header
        cat > /tmp/openwrt-setup-dns-block << 'DNSEOF'

# --- openwrt-setup START ---
listen_addresses = ['127.0.0.1:5353']
server_names = ['quad9-doh-ip4-port443-filter-ecs-pri']
require_nofilter = false
cert_ignore_timestamp = true
block_ipv6 = true
cache = true
cache_size = 1024
cache_min_ttl = 600
cache_max_ttl = 86400
# --- openwrt-setup END ---

DNSEOF
        awk -v blockfile="/tmp/openwrt-setup-dns-block" '
            /^\[/ && !done { while ((getline line < blockfile) > 0) print line; done=1 }
            { print }
        ' "$TOML" > "${TOML}.tmp" && mv "${TOML}.tmp" "$TOML"
        rm -f /tmp/openwrt-setup-dns-block

        # Restart dnscrypt-proxy to pick up config
        /etc/init.d/dnscrypt-proxy enable >/dev/null 2>&1
        DIRTY_DNSCRYPT=1
    }

    check_and_fix "$L_TOML_OK" check_toml_block fix_toml_block

    # --- dnscrypt-proxy enabled at boot --------------------------------------

    check_dnscrypt_enabled() {
        /etc/init.d/dnscrypt-proxy enabled
    }

    fix_dnscrypt_enabled() {
        /etc/init.d/dnscrypt-proxy enable
        # Mark dirty so dnscrypt-proxy actually starts at the end, not just
        # gets enabled. Without this, if it was disabled+stopped and all
        # config was correct, Runtime verification port 5353 would fail.
        DIRTY_DNSCRYPT=1
    }

    check_and_fix "$L_DNSCRYPT_ENABLED_BOOT" check_dnscrypt_enabled fix_dnscrypt_enabled

    # --- Port 5353 listening is verified in Runtime verification at the end --
    # (after all services have been restarted, so dnscrypt-proxy has time
    # to fetch the resolver list on first runs)
fi

# --- dnsmasq forwarding to 127.0.0.1#5353 (only) -----------------------------

check_dnsmasq_forward() {
    # Must be EXACTLY 127.0.0.1#5353 (single server, no fallback)
    SERVER=$(uci -q get dhcp.@dnsmasq[0].server)
    [ "$SERVER" = "127.0.0.1#5353" ]
}

fix_dnsmasq_forward() {
    uci -q delete dhcp.@dnsmasq[0].server
    uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'
    uci commit dhcp
    DIRTY_DNSMASQ=1
}

check_and_fix "$L_DNSMASQ_FORWARD" check_dnsmasq_forward fix_dnsmasq_forward

# --- noresolv=1 (ignore ISP DNS from DHCP) -----------------------------------

check_noresolv() {
    [ "$(uci -q get dhcp.@dnsmasq[0].noresolv)" = "1" ]
}

fix_noresolv() {
    uci set dhcp.@dnsmasq[0].noresolv='1'
    uci commit dhcp
    DIRTY_DNSMASQ=1
}

check_and_fix "$L_DNSMASQ_NORESOLV" check_noresolv fix_noresolv

# --- logqueries=0 (don't log DNS queries) ------------------------------------

check_logqueries() {
    [ "$(uci -q get dhcp.@dnsmasq[0].logqueries)" = "0" ]
}

fix_logqueries() {
    uci set dhcp.@dnsmasq[0].logqueries='0'
    uci commit dhcp
    DIRTY_DNSMASQ=1
}

check_and_fix "$L_DNSMASQ_LOGQUERIES" check_logqueries fix_logqueries

# --- wan.peerdns=0 + wan.dns=127.0.0.1 (router itself uses encrypted DNS) ----

check_peerdns() {
    [ "$(uci -q get network.wan.peerdns)" = "0" ]
}

fix_peerdns() {
    uci set network.wan.peerdns='0'
    uci commit network
    DIRTY_NETWORK=1
    sleep 3
}

check_and_fix "$L_WAN_PEERDNS" check_peerdns fix_peerdns

check_wan_dns() {
    [ "$(uci -q get network.wan.dns)" = "127.0.0.1" ]
}

fix_wan_dns() {
    uci set network.wan.dns='127.0.0.1'
    uci commit network
    DIRTY_NETWORK=1
    sleep 3
}

check_and_fix "$L_WAN_DNS" check_wan_dns fix_wan_dns


# =============================================================================
# Ad blocking (dnsmasq blocklist)
# =============================================================================

section "$L_SEC_AD_BLOCKING"

# --- confdir /tmp/dnsmasq.d (exactly once) -----------------------------------

check_confdir() {
    COUNT=$(uci -q show dhcp.@dnsmasq[0].confdir 2>/dev/null | grep -c "/tmp/dnsmasq.d")
    COUNT=${COUNT:-0}
    [ "$COUNT" = "1" ]
}

fix_confdir() {
    mkdir -p /tmp/dnsmasq.d
    # Remove all existing confdir entries, then add exactly one
    uci -q delete dhcp.@dnsmasq[0].confdir
    uci add_list dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'
    uci commit dhcp
    DIRTY_DNSMASQ=1
}

check_and_fix "$L_CONFDIR_OK" check_confdir fix_confdir

# --- init script to recreate /tmp/dnsmasq.d on boot --------------------------

check_initd_mkdir() {
    [ -x /etc/init.d/mkdir-dnsmasq-confdir ] || return 1
    /etc/init.d/mkdir-dnsmasq-confdir enabled 2>/dev/null
}

fix_initd_mkdir() {
    cat > /etc/init.d/mkdir-dnsmasq-confdir << 'INITEOF'
#!/bin/sh /etc/rc.common
START=18
start() {
    mkdir -p /tmp/dnsmasq.d
}
INITEOF
    chmod +x /etc/init.d/mkdir-dnsmasq-confdir
    /etc/init.d/mkdir-dnsmasq-confdir enable
}

check_and_fix "$L_INITD_MKDIR" check_initd_mkdir fix_initd_mkdir

# --- /usr/sbin/update-blocklist.sh -------------------------------------------

check_update_blocklist_script() {
    [ -x /usr/sbin/update-blocklist.sh ] || return 1
    # Must output to the right path
    grep -q '/tmp/dnsmasq.d/blocklist.conf' /usr/sbin/update-blocklist.sh || return 1
    # Must use curl
    grep -q 'curl' /usr/sbin/update-blocklist.sh || return 1
    # Must restart dnsmasq
    grep -q 'dnsmasq restart' /usr/sbin/update-blocklist.sh || return 1
    # Must reference hagezi (our chosen blocklist)
    grep -q 'hagezi' /usr/sbin/update-blocklist.sh || return 1
    return 0
}

fix_update_blocklist_script() {
    cat > /usr/sbin/update-blocklist.sh << 'BLEOF'
#!/bin/sh
TMPFILE="/tmp/dnsmasq.d/blocklist.conf.tmp"
OUTFILE="/tmp/dnsmasq.d/blocklist.conf"
MIN_LINES=100000

URLS="\
https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/dnsmasq/pro.plus.txt \
https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/pro.plus.txt \
https://codeberg.org/hagezi/mirror2/raw/branch/main/dns-blocklists/dnsmasq/pro.plus.txt"

for URL in $URLS; do
    if curl -sf --retry 2 --retry-delay 3 --connect-timeout 10 --max-time 60 -o "$TMPFILE" "$URL"; then
        [ ! -s "$TMPFILE" ] && { rm -f "$TMPFILE"; continue; }
        LINES=$(wc -l < "$TMPFILE")
        [ "$LINES" -lt "$MIN_LINES" ] 2>/dev/null && { rm -f "$TMPFILE"; continue; }
        FIRST=$(grep -m1 -v '^#' "$TMPFILE" | head -c 20)
        case "$FIRST" in
            "local=/"*|"address=/"*) ;;
            *) rm -f "$TMPFILE"; continue ;;
        esac
        mv -f "$TMPFILE" "$OUTFILE"
        /etc/init.d/dnsmasq restart >/dev/null 2>&1
        logger -t blocklist "Blocklist updated ($(wc -l < "$OUTFILE") lines)"
        exit 0
    fi
done
logger -t blocklist "ALL mirrors failed -- keeping previous blocklist"
exit 1
BLEOF
    chmod +x /usr/sbin/update-blocklist.sh
}

check_and_fix "$L_UPDATE_SCRIPT" check_update_blocklist_script fix_update_blocklist_script

# --- hotplug on WAN up -------------------------------------------------------

check_hotplug() {
    HP=/etc/hotplug.d/iface/99-blocklist
    [ -x "$HP" ] || return 1
    grep -q 'update-blocklist' "$HP" || return 1
    grep -q 'ACTION.*ifup\|ifup.*ACTION' "$HP" || return 1
    grep -q 'INTERFACE.*wan\|wan.*INTERFACE' "$HP" || return 1
    return 0
}

fix_hotplug() {
    mkdir -p /etc/hotplug.d/iface
    cat > /etc/hotplug.d/iface/99-blocklist << 'HPEOF'
#!/bin/sh
[ "$ACTION" = ifup ] && [ "$INTERFACE" = wan ] && {
  sleep 5
  /usr/sbin/update-blocklist.sh
}
HPEOF
    chmod +x /etc/hotplug.d/iface/99-blocklist
}

check_and_fix "$L_HOTPLUG" check_hotplug fix_hotplug

# --- cron daily at 4 AM ------------------------------------------------------

check_cron() {
    [ -f /etc/crontabs/root ] || return 1
    grep -q 'update-blocklist' /etc/crontabs/root
}

fix_cron() {
    mkdir -p /etc/crontabs
    # Remove any old cron lines referencing update-blocklist (idempotent)
    [ -f /etc/crontabs/root ] && sed -i '/update-blocklist/d' /etc/crontabs/root
    echo '0 4 * * * /usr/sbin/update-blocklist.sh' >> /etc/crontabs/root
    /etc/init.d/cron restart
}

check_and_fix "$L_CRON" check_cron fix_cron

# --- blocklist file loaded ---------------------------------------------------

check_blocklist_loaded() {
    [ -f /tmp/dnsmasq.d/blocklist.conf ] || return 1
    LINES=$(wc -l < /tmp/dnsmasq.d/blocklist.conf 2>/dev/null)
    [ -n "$LINES" ] && [ "$LINES" -gt 100000 ] 2>/dev/null
}

fix_blocklist_loaded() {
    /usr/sbin/update-blocklist.sh
}

check_and_fix "$L_BLOCKLIST_LOADED" check_blocklist_loaded fix_blocklist_loaded


# =============================================================================
# NTP + NTS (chrony with Cloudflare)
# =============================================================================

section "$L_SEC_NTP_NTS"

# --- sysntpd disabled --------------------------------------------------------

check_sysntpd_off() {
    # /etc/init.d/sysntpd enabled returns 0 if enabled; we want it NOT enabled
    ! /etc/init.d/sysntpd enabled 2>/dev/null
}

fix_sysntpd_off() {
    /etc/init.d/sysntpd stop
    /etc/init.d/sysntpd disable
}

check_and_fix "$L_SYSNTPD_DISABLED" check_sysntpd_off fix_sysntpd_off

# --- No default pool/server entries (must only have Cloudflare NTS) ----------

check_no_default_pools() {
    # There should be NO @pool entries, and NO @server entries other than time.cloudflare.com
    [ -z "$(uci -q get chrony.@pool[0])" ] || return 1
    # Count non-Cloudflare server entries
    _idx=0
    while uci -q get "chrony.@server[$_idx]" >/dev/null 2>&1; do
        _host=$(uci -q get "chrony.@server[$_idx].hostname")
        [ "$_host" = "time.cloudflare.com" ] || return 1
        _idx=$((_idx + 1))
    done
    # Must have at least one server (Cloudflare)
    [ -n "$(uci -q get chrony.@server[0].hostname)" ]
}

fix_no_default_pools() {
    # Remove all pool entries
    while uci -q get chrony.@pool[0] > /dev/null; do
        uci delete chrony.@pool[0]
    done
    # Remove all server entries
    while uci -q get chrony.@server[0] > /dev/null; do
        uci delete chrony.@server[0]
    done
    # Also remove any stale allow entries (handle_allow ignores them anyway)
    while uci -q get chrony.@allow[0] > /dev/null; do
        uci delete chrony.@allow[0]
    done
    # Add Cloudflare NTS
    uci add chrony server >/dev/null
    uci set chrony.@server[-1].hostname='time.cloudflare.com'
    uci set chrony.@server[-1].iburst='yes'
    uci set chrony.@server[-1].nts='yes'
    uci commit chrony
    DIRTY_CHRONYD=1
}

check_and_fix "$L_CHRONY_NTS" check_no_default_pools fix_no_default_pools

# --- chrony NTS enabled ------------------------------------------------------

check_chrony_nts() {
    [ "$(uci -q get chrony.@server[0].nts)" = "yes" ]
}

fix_chrony_nts() {
    uci set chrony.@server[-1].nts='yes'
    uci set chrony.@server[-1].iburst='yes'
    uci commit chrony
    DIRTY_CHRONYD=1
}

check_and_fix "$L_CHRONY_NTS_YES" check_chrony_nts fix_chrony_nts

# --- conf.d/ntp-server.conf with port 123 + allow LAN ------------------------

NTP_SERVER_CONF="/etc/chrony/conf.d/ntp-server.conf"

check_ntp_server_conf() {
    [ -f "$NTP_SERVER_CONF" ] || return 1
    grep -q '^port 123' "$NTP_SERVER_CONF" || return 1
    grep -q "^allow $LAN_SUBNET" "$NTP_SERVER_CONF" || return 1
    return 0
}

fix_ntp_server_conf() {
    mkdir -p /etc/chrony/conf.d
    cat > "$NTP_SERVER_CONF" << EOF
# Enable NTP server on standard port for LAN clients
port 123
allow $LAN_SUBNET
EOF
    DIRTY_CHRONYD=1
}

check_and_fix "chrony conf.d: port 123 + allow $LAN_SUBNET" check_ntp_server_conf fix_ntp_server_conf

# --- chrony.conf includes confdir --------------------------------------------

check_confdir_in_chrony_conf() {
    [ -f /etc/chrony/chrony.conf ] || return 1
    grep -q '^confdir /etc/chrony/conf.d' /etc/chrony/chrony.conf
}

fix_confdir_in_chrony_conf() {
    if [ -f /etc/chrony/chrony.conf ] && ! grep -q '^confdir /etc/chrony/conf.d' /etc/chrony/chrony.conf; then
        echo 'confdir /etc/chrony/conf.d' >> /etc/chrony/chrony.conf
    fi
    DIRTY_CHRONYD=1
}

check_and_fix "$L_CHRONY_CONFDIR" check_confdir_in_chrony_conf fix_confdir_in_chrony_conf

# --- chronyd enabled at boot -------------------------------------------------

check_chronyd_enabled() {
    /etc/init.d/chronyd enabled
}

fix_chronyd_enabled() {
    /etc/init.d/chronyd enable
    # Mark dirty so chronyd actually starts at the end, not just gets enabled.
    # Without this, if chronyd was disabled+stopped and all config was already
    # correct, the final restart phase would skip chronyd and pidof would fail.
    DIRTY_CHRONYD=1
}

check_and_fix "$L_CHRONYD_BOOT" check_chronyd_enabled fix_chronyd_enabled

# --- chronyd running is verified in Runtime verification at the end ----------

# Note: /var/etc/chrony.conf is regenerated by the init script every time
# chronyd starts. There's no value in verifying or editing it directly —
# the source of truth is /etc/chrony/chrony.conf (verified above) and
# /etc/chrony/conf.d/*.conf (verified above via conf.d ntp-server).


# =============================================================================
# Port security (bind services to LAN only)
# =============================================================================

section "$L_SEC_PORT_SECURITY"

# --- dnsmasq interface=lan + notinterface=wan/wan6 + localservice=1 ----------

check_dnsmasq_bind() {
    # Read all interface values (uci handles both string and list types).
    # We build a space-separated string of all values and grep within it.
    # This is robust to both string ('lan') and list (interface='lan', interface='other').

    # interface (list or string)
    _iface=$(uci -q get dhcp.@dnsmasq[0].interface 2>/dev/null)
    echo " $_iface " | grep -q " lan " || return 1

    # notinterface (must include both wan and wan6)
    _notiface=$(uci -q get dhcp.@dnsmasq[0].notinterface 2>/dev/null)
    echo " $_notiface " | grep -q " wan " || return 1
    echo " $_notiface " | grep -q " wan6 " || return 1

    # localservice must be 1
    [ "$(uci -q get dhcp.@dnsmasq[0].localservice)" = "1" ] || return 1
    return 0
}

fix_dnsmasq_bind() {
    # Defensive del_list (won't error if not present) to avoid duplicates
    uci -q del_list dhcp.@dnsmasq[0].interface='lan'
    uci -q del_list dhcp.@dnsmasq[0].notinterface='wan'
    uci -q del_list dhcp.@dnsmasq[0].notinterface='wan6'
    uci add_list dhcp.@dnsmasq[0].interface='lan'
    uci add_list dhcp.@dnsmasq[0].notinterface='wan'
    uci add_list dhcp.@dnsmasq[0].notinterface='wan6'
    uci set dhcp.@dnsmasq[0].localservice='1'
    uci commit dhcp
    DIRTY_DNSMASQ=1
}

check_and_fix "$L_DNSMASQ_LAN" check_dnsmasq_bind fix_dnsmasq_bind

# --- uhttpd (LuCI) listens only on LAN IP ------------------------------------

check_uhttpd_bind() {
    HTTP=$(uci -q show uhttpd.main.listen_http 2>/dev/null)
    HTTPS=$(uci -q show uhttpd.main.listen_https 2>/dev/null)
    # Must NOT listen on 0.0.0.0 or [::]
    echo "$HTTP" | grep -q '0\.0\.0\.0\|\[::\]' && return 1
    echo "$HTTPS" | grep -q '0\.0\.0\.0\|\[::\]' && return 1
    # Must listen on the LAN IP
    echo "$HTTP" | grep -q "$LAN_IP:80" || return 1
    echo "$HTTPS" | grep -q "$LAN_IP:443" || return 1
    return 0
}

fix_uhttpd_bind() {
    uci -q delete uhttpd.main.listen_http
    uci -q delete uhttpd.main.listen_https
    uci add_list uhttpd.main.listen_http="${LAN_IP}:80"
    uci add_list uhttpd.main.listen_https="${LAN_IP}:443"
    uci commit uhttpd
    DIRTY_UHTTPD=1
}

if [ "$LANG_ES" = "1" ]; then
    check_and_fix "uhttpd (LuCI) bindeado solo a LAN (${LAN_IP}:80/443)" check_uhttpd_bind fix_uhttpd_bind
else
    check_and_fix "uhttpd (LuCI) bound to LAN only (${LAN_IP}:80/443)" check_uhttpd_bind fix_uhttpd_bind
fi

# --- dropbear (SSH) bound to LAN interface -----------------------------------

check_dropbear_bind() {
    [ "$(uci -q get dropbear.@dropbear[0].Interface)" = "lan" ]
}

fix_dropbear_bind() {
    uci set dropbear.@dropbear[0].Interface='lan'
    uci commit dropbear
    DIRTY_DROPBEAR=1
}

check_and_fix "$L_DROPBEAR_LAN" check_dropbear_bind fix_dropbear_bind

# =============================================================================
# Firewall hardening
# =============================================================================

section "$L_SEC_FIREWALL"

# Find WAN zone index (robust — don't assume @zone[1])
WAN_ZONE_IDX=""
LAN_ZONE_IDX=""
_zidx=0
while uci -q get firewall.@zone["$_zidx"].name >/dev/null 2>&1; do
    _zname=$(uci -q get firewall.@zone["$_zidx"].name)
    case "$_zname" in
        wan) WAN_ZONE_IDX=$_zidx ;;
        lan) LAN_ZONE_IDX=$_zidx ;;
    esac
    _zidx=$((_zidx + 1))
done

# --- LAN zone input=ACCEPT (clients need this for NTP, DNS, LuCI) -----------
# Not something setup.sh touches, but the check.sh verifies it. If someone
# accidentally set it to DROP/REJECT, LAN clients can't use router services.

if [ -n "$LAN_ZONE_IDX" ]; then
    check_lan_accept() {
        [ "$(uci -q get firewall.@zone["$LAN_ZONE_IDX"].input)" = "ACCEPT" ]
    }

    fix_lan_accept() {
        uci set firewall.@zone["$LAN_ZONE_IDX"].input=ACCEPT
        uci commit firewall
        DIRTY_FIREWALL=1
    }

    check_and_fix "$L_LAN_ACCEPT" check_lan_accept fix_lan_accept
else
    if [ "$LANG_ES" = "1" ]; then fail "No se encontró la zona de firewall LAN"; else fail "Could not find LAN firewall zone"; fi
fi

if [ -z "$WAN_ZONE_IDX" ]; then
    if [ "$LANG_ES" = "1" ]; then fail "No se encontró la zona de firewall WAN"; else fail "Could not find WAN firewall zone"; fi
else
    # --- WAN zone input=DROP -------------------------------------------------

    check_wan_drop() {
        [ "$(uci -q get firewall.@zone["$WAN_ZONE_IDX"].input)" = "DROP" ]
    }

    fix_wan_drop() {
        uci set firewall.@zone["$WAN_ZONE_IDX"].input=DROP
        uci commit firewall
        DIRTY_FIREWALL=1
    }

    check_and_fix "$L_WAN_DROP" check_wan_drop fix_wan_drop
fi

# --- Named rules: Block-WAN-{DNS,SSH,HTTP,HTTPS,Ping,IRC} --------------------

# Each rule is declared as a named UCI section (firewall.block_wan_*)
# so it's idempotent — re-running overwrites rather than duplicating.

make_rule_check() {
    # $1=rule_name  $2=expected_proto  $3=expected_dest_port (empty for icmp)
    _rname="$1"; _rproto="$2"; _rport="$3"
    [ "$(uci -q get firewall."$_rname")" = "rule" ] || return 1
    [ "$(uci -q get firewall."$_rname".src)" = "wan" ] || return 1
    [ "$(uci -q get firewall."$_rname".target)" = "DROP" ] || return 1
    [ "$(uci -q get firewall."$_rname".proto)" = "$_rproto" ] || return 1
    if [ -n "$_rport" ]; then
        [ "$(uci -q get firewall."$_rname".dest_port)" = "$_rport" ] || return 1
    fi
    return 0
}

# Delete any anonymous rule(s) (@rule[N]) that have the given name.
# The original openwrt-setup.sh created anonymous rules — if we then create a
# named rule with the same semantics, both end up in the firewall (harmless
# but duplicated). This cleanup runs before each named fix to migrate cleanly.
delete_anon_rule_by_name() {
    _target_name="$1"
    _ridx=0
    # Iterate with a reasonable upper bound (firewall rules rarely exceed 50)
    while uci -q get "firewall.@rule[$_ridx]" >/dev/null 2>&1; do
        _rname_found=$(uci -q get "firewall.@rule[$_ridx].name")
        if [ "$_rname_found" = "$_target_name" ]; then
            uci -q delete "firewall.@rule[$_ridx]"
            # Don't increment: the list shifted, the next item is at same index
            continue
        fi
        _ridx=$((_ridx + 1))
    done
}

# Block-WAN-DNS
check_block_dns() { make_rule_check block_wan_dns tcpudp 53; }
fix_block_dns() {
    delete_anon_rule_by_name "Block-WAN-DNS"
    uci -q delete firewall.block_wan_dns
    uci set firewall.block_wan_dns=rule
    uci set firewall.block_wan_dns.name='Block-WAN-DNS'
    uci set firewall.block_wan_dns.src='wan'
    uci set firewall.block_wan_dns.dest_port='53'
    uci set firewall.block_wan_dns.proto='tcpudp'
    uci set firewall.block_wan_dns.target='DROP'
    uci commit firewall
    DIRTY_FIREWALL=1
}
check_and_fix "$L_BLOCK_DNS" check_block_dns fix_block_dns

# Block-WAN-SSH
check_block_ssh() { make_rule_check block_wan_ssh tcp 22; }
fix_block_ssh() {
    delete_anon_rule_by_name "Block-WAN-SSH"
    uci -q delete firewall.block_wan_ssh
    uci set firewall.block_wan_ssh=rule
    uci set firewall.block_wan_ssh.name='Block-WAN-SSH'
    uci set firewall.block_wan_ssh.src='wan'
    uci set firewall.block_wan_ssh.dest_port='22'
    uci set firewall.block_wan_ssh.proto='tcp'
    uci set firewall.block_wan_ssh.target='DROP'
    uci commit firewall
    DIRTY_FIREWALL=1
}
check_and_fix "$L_BLOCK_SSH" check_block_ssh fix_block_ssh

# Block-WAN-HTTP
check_block_http() { make_rule_check block_wan_http tcp 80; }
fix_block_http() {
    delete_anon_rule_by_name "Block-WAN-HTTP"
    uci -q delete firewall.block_wan_http
    uci set firewall.block_wan_http=rule
    uci set firewall.block_wan_http.name='Block-WAN-HTTP'
    uci set firewall.block_wan_http.src='wan'
    uci set firewall.block_wan_http.dest_port='80'
    uci set firewall.block_wan_http.proto='tcp'
    uci set firewall.block_wan_http.target='DROP'
    uci commit firewall
    DIRTY_FIREWALL=1
}
check_and_fix "$L_BLOCK_HTTP" check_block_http fix_block_http

# Block-WAN-HTTPS
check_block_https() { make_rule_check block_wan_https tcp 443; }
fix_block_https() {
    delete_anon_rule_by_name "Block-WAN-HTTPS"
    uci -q delete firewall.block_wan_https
    uci set firewall.block_wan_https=rule
    uci set firewall.block_wan_https.name='Block-WAN-HTTPS'
    uci set firewall.block_wan_https.src='wan'
    uci set firewall.block_wan_https.dest_port='443'
    uci set firewall.block_wan_https.proto='tcp'
    uci set firewall.block_wan_https.target='DROP'
    uci commit firewall
    DIRTY_FIREWALL=1
}
check_and_fix "$L_BLOCK_HTTPS" check_block_https fix_block_https

# --- Allow-Ping disabled -----------------------------------------------------

check_allow_ping_disabled() {
    # Find Allow-Ping rule by name; it must have enabled='0'
    _ridx=0
    while uci -q get firewall.@rule["$_ridx"] >/dev/null 2>&1; do
        if [ "$(uci -q get firewall.@rule["$_ridx"].name)" = "Allow-Ping" ]; then
            [ "$(uci -q get firewall.@rule["$_ridx"].enabled)" = "0" ] && return 0
            return 1
        fi
        _ridx=$((_ridx + 1))
    done
    # If no Allow-Ping rule exists at all, treat as OK
    return 0
}

fix_allow_ping_disabled() {
    _ridx=0
    while uci -q get firewall.@rule["$_ridx"] >/dev/null 2>&1; do
        if [ "$(uci -q get firewall.@rule["$_ridx"].name)" = "Allow-Ping" ]; then
            uci set firewall.@rule["$_ridx"].enabled=0
            uci commit firewall
            DIRTY_FIREWALL=1
            return 0
        fi
        _ridx=$((_ridx + 1))
    done
}

check_and_fix "$L_ALLOW_PING_DISABLED" check_allow_ping_disabled fix_allow_ping_disabled

# --- Block-WAN-Ping ----------------------------------------------------------

check_block_ping() {
    [ "$(uci -q get firewall.block_wan_ping)" = "rule" ] || return 1
    [ "$(uci -q get firewall.block_wan_ping.src)" = "wan" ] || return 1
    [ "$(uci -q get firewall.block_wan_ping.proto)" = "icmp" ] || return 1
    [ "$(uci -q get firewall.block_wan_ping.icmp_type)" = "echo-request" ] || return 1
    [ "$(uci -q get firewall.block_wan_ping.family)" = "ipv4" ] || return 1
    [ "$(uci -q get firewall.block_wan_ping.target)" = "DROP" ] || return 1
    return 0
}

fix_block_ping() {
    delete_anon_rule_by_name "Block-WAN-Ping"
    uci -q delete firewall.block_wan_ping
    uci set firewall.block_wan_ping=rule
    uci set firewall.block_wan_ping.name='Block-WAN-Ping'
    uci set firewall.block_wan_ping.src='wan'
    uci set firewall.block_wan_ping.proto='icmp'
    uci set firewall.block_wan_ping.icmp_type='echo-request'
    uci set firewall.block_wan_ping.family='ipv4'
    uci set firewall.block_wan_ping.target='DROP'
    uci commit firewall
    DIRTY_FIREWALL=1
}

check_and_fix "$L_BLOCK_PING" check_block_ping fix_block_ping

# --- drop_invalid=1 + flow_offloading=1 --------------------------------------

check_drop_invalid() {
    [ "$(uci -q get firewall.@defaults[0].drop_invalid)" = "1" ]
}

fix_drop_invalid() {
    uci set firewall.@defaults[0].drop_invalid='1'
    uci commit firewall
    DIRTY_FIREWALL=1
}

check_and_fix "$L_DROP_INVALID" check_drop_invalid fix_drop_invalid

check_flow_offloading() {
    [ "$(uci -q get firewall.@defaults[0].flow_offloading)" = "1" ]
}

fix_flow_offloading() {
    uci set firewall.@defaults[0].flow_offloading='1'
    uci commit firewall
    DIRTY_FIREWALL=1
}

check_and_fix "$L_FLOW_OFFLOAD" check_flow_offloading fix_flow_offloading


# =============================================================================
# Performance
# =============================================================================

section "$L_SEC_PERFORMANCE"

# --- packet_steering (MT7621 has 2 cores) ------------------------------------

check_packet_steering() {
    [ "$(uci -q get network.globals.packet_steering)" = "1" ]
}

fix_packet_steering() {
    uci set network.globals.packet_steering='1'
    uci commit network
    DIRTY_NETWORK=1
}

check_and_fix "$L_PACKET_STEERING" check_packet_steering fix_packet_steering

# --- dnsmasq cachesize=1000 (default 150) ------------------------------------

check_cachesize() {
    [ "$(uci -q get dhcp.@dnsmasq[0].cachesize)" = "1000" ]
}

fix_cachesize() {
    uci set dhcp.@dnsmasq[0].cachesize='1000'
    uci commit dhcp
    DIRTY_DNSMASQ=1
}

check_and_fix "$L_DNSMASQ_CACHESIZE" check_cachesize fix_cachesize

# --- System log buffer 32KB (save RAM on 128MB device) -----------------------

check_log_size() {
    [ "$(uci -q get system.@system[0].log_size)" = "32" ]
}

fix_log_size() {
    uci set system.@system[0].log_size='32'
    uci commit system
    DIRTY_LOG=1
}

check_and_fix "$L_LOG_BUFFER" check_log_size fix_log_size

# =============================================================================
# IPv6 apply (only if user chose to disable)
# =============================================================================

if [ "$DISABLE_IPV6" = "yes" ] || [ "$DISABLE_IPV6" = "already" ]; then
    if [ "$DISABLE_IPV6" = "yes" ]; then
        section "IPv6 disable (applying user choice)"
    else
        section "$L_IPV6_VERIFY_TITLE"
    fi

    # --- wan6.disabled=1 -----------------------------------------------------

    check_wan6_disabled() {
        [ "$(uci -q get network.wan6.disabled)" = "1" ]
    }

    fix_wan6_disabled() {
        uci set network.wan6.disabled='1'
        uci commit network
    }

    check_and_fix "network.wan6.disabled=1" check_wan6_disabled fix_wan6_disabled ipv4

    # --- ULA prefix removed (otherwise dnsmasq binds to fd:: and fe80::) -----

    check_no_ula() {
        [ -z "$(uci -q get network.globals.ula_prefix)" ]
    }

    fix_no_ula() {
        uci -q delete network.globals.ula_prefix
        uci commit network
    }

    check_and_fix "ULA prefix removed" check_no_ula fix_no_ula ipv4

    # --- odhcpd disabled -----------------------------------------------------

    check_odhcpd_off() {
        # /etc/init.d/odhcpd enabled returns 0 if enabled; we want it NOT enabled
        ! /etc/init.d/odhcpd enabled 2>/dev/null
    }

    fix_odhcpd_off() {
        service odhcpd stop
        service odhcpd disable
    }

    check_and_fix "odhcpd disabled (IPv6 DHCP/RA daemon)" check_odhcpd_off fix_odhcpd_off ipv4

    # --- wan6 interface down + dnsmasq restart to drop IPv6 binds ------------
    # Only needed if we just applied the disable (not if it was already disabled)
    if [ "$DISABLE_IPV6" = "yes" ]; then
        ifdown wan6 >/dev/null 2>&1
        DIRTY_DNSMASQ=1
        if [ "$LANG_ES" = "1" ]; then info "wan6 bajada, dnsmasq reiniciado (para liberar binds IPv6)"; else info "wan6 brought down, dnsmasq restarted (to release IPv6 binds)"; fi
    fi
fi

# =============================================================================
# Applying changes (restart only modified services) + Runtime verification
# =============================================================================

section "$L_APPLY_TITLE"

# Restart services ONLY for the ones that were actually modified.
# Order matters: network first (may drop SSH briefly), then services that
# depend on network being up.

TOTAL_RESTARTS=$((DIRTY_NETWORK + DIRTY_DNSMASQ + DIRTY_FIREWALL + DIRTY_DNSCRYPT + DIRTY_CHRONYD + DIRTY_UHTTPD + DIRTY_DROPBEAR + DIRTY_LOG))

if [ "$TOTAL_RESTARTS" -eq 0 ]; then
    info "$L_NO_CHANGES"
else
    info "$L_RESTARTING"

    # Network restart tends to briefly drop SSH. Only do it if actually needed.
    if [ "$DIRTY_NETWORK" = "1" ]; then
        if [ "$LANG_ES" = "1" ]; then info "  → network (SSH puede cortarse brevemente — la config está guardada)"; else info "  → network (SSH may drop briefly — config is saved)"; fi
        service network restart
        sleep 5
    fi

    if [ "$DIRTY_FIREWALL" = "1" ]; then
        info "  → firewall"
        service firewall restart
    fi

    if [ "$DIRTY_DNSCRYPT" = "1" ]; then
        info "  → dnscrypt-proxy"
        /etc/init.d/dnscrypt-proxy restart
    fi

    if [ "$DIRTY_DNSMASQ" = "1" ]; then
        info "  → dnsmasq"
        service dnsmasq restart
    fi

    if [ "$DIRTY_CHRONYD" = "1" ]; then
        info "  → chronyd"
        /etc/init.d/chronyd restart
    fi

    if [ "$DIRTY_UHTTPD" = "1" ]; then
        info "  → uhttpd (LuCI)"
        service uhttpd restart
    fi

    if [ "$DIRTY_DROPBEAR" = "1" ]; then
        if [ "$LANG_ES" = "1" ]; then info "  → dropbear (SSH puede cortarse brevemente si rebindea)"; else info "  → dropbear (SSH may drop briefly if it rebinds)"; fi
        service dropbear restart
    fi

    if [ "$DIRTY_LOG" = "1" ]; then
        if [ "$LANG_ES" = "1" ]; then info "  → daemon de log"; else info "  → log daemon"; fi
        /etc/init.d/log restart
    fi

    info "$L_WAITING_SETTLE"
    sleep 2
fi

# =============================================================================
# Runtime verification — checks that depend on services being up and running
# (not on UCI config in disk). Run after the restart phase above.
# =============================================================================

section "$L_RV_TITLE"

# --- Port 5353: dnscrypt-proxy listening -------------------------------------

check_5353_listening() {
    netstat -tlnup 2>/dev/null | grep -q ':5353 ' && return 0
    ss -tlnup 2>/dev/null | grep -q ':5353 ' && return 0
    return 1
}

# On first run, dnscrypt-proxy needs up to ~60s to fetch the resolver list
# before binding. Retry before declaring failure.
_retries=0
while [ "$_retries" -lt 60 ]; do
    if check_5353_listening; then
        break
    fi
    sleep 1
    _retries=$((_retries + 1))
done

if check_5353_listening; then
    ok "$L_RV_5353"
else
    fail "$L_RV_5353_FAIL"
fi

# --- chronyd process running -------------------------------------------------

if pidof chronyd >/dev/null 2>&1; then
    ok "$L_RV_CHRONYD"
else
    fail "$L_RV_CHRONYD_FAIL"
fi

# --- /etc/resolv.conf: router itself should only use 127.0.0.1 ---------------
# (Catches DNS leaks to ISP that peerdns=0 and wan.dns=127.0.0.1 should prevent)

if [ -f /etc/resolv.conf ]; then
    _resolv_ns=$(grep -E "^nameserver" /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ')
    _non_local=$(echo "$_resolv_ns" | tr ' ' '\n' | grep -vE "^(127\.|::1$|$)" | tr '\n' ' ')
    if [ -z "$_non_local" ]; then
        ok "$L_RV_RESOLV"
    else
        if [ "$LANG_ES" = "1" ]; then fail "/etc/resolv.conf tiene nameserver(s) no-locales: $_non_local (¡DNS leak al ISP!)"; else fail "/etc/resolv.conf has non-local nameserver(s): $_non_local (DNS leak to ISP!)"; fi
    fi
fi

# --- End-to-end DNS test (the ultimate smoke test) ---------------------------

if command -v dig >/dev/null 2>&1; then
    DIG_OUT=$(dig @127.0.0.1 -p 5353 example.com +short +time=5 +tries=2 2>/dev/null)
    if echo "$DIG_OUT" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
        ok "$L_RV_DNS_E2E"
    else
        # Try via dnsmasq instead
        DIG_OUT=$(dig @127.0.0.1 example.com +short +time=5 +tries=2 2>/dev/null)
        if echo "$DIG_OUT" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
            if [ "$LANG_ES" = "1" ]; then
                ok "Resolución DNS: example.com via dnsmasq → dnscrypt-proxy"
            else
                ok "DNS resolution: example.com via dnsmasq → dnscrypt-proxy"
            fi
        else
            if [ "$LANG_ES" = "1" ]; then
                fail "Resolución DNS falló — dnscrypt-proxy puede estar arrancando todavía"
            else
                fail "DNS resolution failed — dnscrypt-proxy may still be starting"
            fi
        fi
    fi
else
    warn "$L_RV_DIG_MISSING"
fi

# =============================================================================
# WireGuard VPN (optional, interactive)
# =============================================================================
# Full-wizard flow hits this block after Runtime verification. If the user
# answers 'n' to the prompt inside wg_main_menu, it returns without side effects
# and we proceed to the Summary. If 'y', the menu runs until user picks [4].

wg_main_menu

# =============================================================================
# Summary
# =============================================================================

section "$L_SUMMARY_TITLE"

# --- dnscrypt-proxy config verification (TOML values vs expected) -----------

TOML_PATH="/etc/dnscrypt-proxy2/dnscrypt-proxy.toml"

if [ ! -f "$TOML_PATH" ]; then
    if [ "$LANG_ES" = "1" ]; then
        printf "  ${RED}[!!]${NC}   dnscrypt-proxy.toml NO encontrado en ${CYAN}%s${NC}\n" "$TOML_PATH"
    else
        printf "  ${RED}[!!]${NC}   dnscrypt-proxy.toml NOT FOUND at ${CYAN}%s${NC}\n" "$TOML_PATH"
    fi
else
    if [ "$LANG_ES" = "1" ]; then
        printf "  ${BOLD}Config dnscrypt-proxy (%s):${NC}\n" "$TOML_PATH"
    else
        printf "  ${BOLD}dnscrypt-proxy config (%s):${NC}\n" "$TOML_PATH"
    fi

    # Compare each TOML key against its expected value.
    # Reads the actual value from the file (first uncommented occurrence).
    # Handles both quoted strings (listen_addresses, server_names) and
    # unquoted scalars (true/false/numbers).
    #
    # Uses printf arg expansion (not format string) to avoid SC2059.

    _toml_check() {
        # $1 = key, $2 = expected value (exact string match against raw line content after '=')
        _key="$1"
        _expected="$2"
        # Get the first uncommented line starting with "key ="
        _line=$(grep -E "^${_key}[[:space:]]*=" "$TOML_PATH" 2>/dev/null | head -1)
        if [ -z "$_line" ]; then
            printf "    ${RED}[X]${NC} ${BOLD}%s${NC} = ${RED}(missing)${NC}  ${DIM}expected:${NC} %s = ${GREEN}%s${NC}\n" \
                "$_key" "$_key" "$_expected"
            return 1
        fi
        # Extract value part (everything after first '=', trimmed)
        _actual=$(echo "$_line" | sed 's/^[^=]*=[[:space:]]*//' | sed 's/[[:space:]]*$//')
        if [ "$_actual" = "$_expected" ]; then
            printf "    ${GREEN}[✓]${NC} ${BOLD}%s${NC} = %s\n" "$_key" "$_actual"
        else
            printf "    ${RED}[X]${NC} ${BOLD}%s${NC} = ${RED}%s${NC}  ${DIM}expected:${NC} ${GREEN}%s${NC}\n" \
                "$_key" "$_actual" "$_expected"
        fi
    }

    _toml_check "listen_addresses"      "['127.0.0.1:5353']"
    _toml_check "server_names"          "['quad9-doh-ip4-port443-filter-ecs-pri']"
    _toml_check "require_nofilter"      "false"
    _toml_check "cert_ignore_timestamp" "true"
    _toml_check "block_ipv6"            "true"
    _toml_check "cache"                 "true"
    _toml_check "cache_size"            "1024"
    _toml_check "cache_min_ttl"         "600"
    _toml_check "cache_max_ttl"         "86400"
fi

echo ""

# --- Main blocklist (Hagezi Pro++) -------------------------------------------

MAIN_BLOCKLIST="/tmp/dnsmasq.d/blocklist.conf"
if [ -s "$MAIN_BLOCKLIST" ]; then
    MAIN_COUNT=$(wc -l < "$MAIN_BLOCKLIST")
    # Format with thousands separator (POSIX: use sed)
    MAIN_COUNT_FMT=$(echo "$MAIN_COUNT" | sed ':a;s/\([0-9]\)\([0-9]\{3\}\)\(,\|$\)/\1,\2\3/;ta')
    if [ "$MAIN_COUNT" -gt 100000 ]; then
        if [ "$LANG_ES" = "1" ]; then
        printf "  ${GREEN}[ok]${NC}   Blocklist principal: Hagezi Pro++ — ${BOLD}%s${NC} dominios bloqueados\n" "$MAIN_COUNT_FMT"
    else
        printf "  ${GREEN}[ok]${NC}   Main blocklist: Hagezi Pro++ — ${BOLD}%s${NC} domains blocked\n" "$MAIN_COUNT_FMT"
    fi
    else
        if [ "$LANG_ES" = "1" ]; then
        printf "  ${YELLOW}[??]${NC}   Blocklist principal cargada pero solo ${BOLD}%s${NC} dominios (esperado >100k)\n" "$MAIN_COUNT_FMT"
    else
        printf "  ${YELLOW}[??]${NC}   Main blocklist loaded but only ${BOLD}%s${NC} domains (expected >100k)\n" "$MAIN_COUNT_FMT"
    fi
    fi
else
    if [ "$LANG_ES" = "1" ]; then
    printf "  ${RED}[!!]${NC}   Blocklist principal no cargada (${CYAN}%s${NC} no existe o está vacía)\n" "$MAIN_BLOCKLIST"
else
    printf "  ${RED}[!!]${NC}   Main blocklist not loaded (${CYAN}%s${NC} does not exist or is empty)\n" "$MAIN_BLOCKLIST"
fi
fi

# --- Custom blocklist (/etc/custom-blocklist.txt) ----------------------------

CUSTOM_BLOCKLIST="/etc/custom-blocklist.txt"
if [ ! -f "$CUSTOM_BLOCKLIST" ]; then
    if [ "$LANG_ES" = "1" ]; then
        printf "  ${CYAN}[i]${NC}    Blocklist custom: archivo ${CYAN}%s${NC} no existe (sin dominios custom)\n" "$CUSTOM_BLOCKLIST"
    else
        printf "  ${CYAN}[i]${NC}    Custom blocklist: file ${CYAN}%s${NC} does not exist (no custom domains)\n" "$CUSTOM_BLOCKLIST"
    fi
else
    # Count non-empty, non-comment lines
    CUSTOM_COUNT=$(grep -cE '^[^#[:space:]]' "$CUSTOM_BLOCKLIST" 2>/dev/null)
    CUSTOM_COUNT=${CUSTOM_COUNT:-0}
    if [ "$CUSTOM_COUNT" -eq 0 ]; then
        if [ "$LANG_ES" = "1" ]; then
            printf "  ${CYAN}[i]${NC}    Blocklist custom: ${CYAN}%s${NC} existe pero sin dominios configurados\n" "$CUSTOM_BLOCKLIST"
        else
            printf "  ${CYAN}[i]${NC}    Custom blocklist: ${CYAN}%s${NC} exists but no domains configured\n" "$CUSTOM_BLOCKLIST"
        fi
    else
        if [ "$LANG_ES" = "1" ]; then
            printf "  ${GREEN}[ok]${NC}   Blocklist custom: ${BOLD}%s${NC} dominio(s) en ${CYAN}%s${NC}\n" "$CUSTOM_COUNT" "$CUSTOM_BLOCKLIST"
        else
            printf "  ${GREEN}[ok]${NC}   Custom blocklist: ${BOLD}%s${NC} domain(s) in ${CYAN}%s${NC}\n" "$CUSTOM_COUNT" "$CUSTOM_BLOCKLIST"
        fi
        # List each domain, enumerated
        _i=1
        while IFS= read -r _domain; do
            # Skip empty and comment lines
            case "$_domain" in
                ''|\#*) continue ;;
            esac
            printf "           ${DIM}%2d.${NC} %s\n" "$_i" "$_domain"
            _i=$((_i + 1))
        done < "$CUSTOM_BLOCKLIST"
    fi
fi

echo ""

# --- Check counters ----------------------------------------------------------

TOTAL_CHECKS=$((TOTAL_OK + TOTAL_FIXED + TOTAL_FAIL))

printf "  ${GREEN}${BOLD}%3d${NC} %s ${DIM}[ok]${NC}\n"  "$TOTAL_OK"    "$L_SUMMARY_ALREADY_OK"
printf "  ${YELLOW}${BOLD}%3d${NC} %s   ${DIM}[fix]${NC}\n" "$TOTAL_FIXED" "$L_SUMMARY_FIXED_BY"
printf "  ${RED}${BOLD}%3d${NC} %s     ${DIM}[!!]${NC}\n"   "$TOTAL_FAIL"  "$L_SUMMARY_STILL_FAILING"
printf "  ${BOLD}%3d${NC} %s\n" "$TOTAL_CHECKS" "$L_SUMMARY_TOTAL"
echo ""

if [ "$TOTAL_FAIL" -eq 0 ]; then
    printf "  ${GREEN}${BOLD}%s${NC}\n" "$L_SUMMARY_ALL_PASSED"
    echo ""
    printf "  ${BOLD}%s${NC}\n" "$L_SUMMARY_NEXT_STEPS"
    printf "    %s       ${CYAN}passwd${NC}\n" "$L_SUMMARY_STEP1"
    printf "    %s        ${CYAN}https://dnsleaktest.com${NC}\n" "$L_SUMMARY_STEP2"
    printf "    %s   ${CYAN}https://www.grc.com/shieldsup${NC}\n" "$L_SUMMARY_STEP3"
    printf "    %s  ${CYAN}reboot${NC}\n" "$L_SUMMARY_STEP4"
    echo ""
    exit 0
else
    printf "  ${RED}${BOLD}%d %s${NC} %s\n" "$TOTAL_FAIL" "$L_SUMMARY_SOME_FAILED" "$L_SUMMARY_REVIEW"
    echo ""
    exit 1
fi
