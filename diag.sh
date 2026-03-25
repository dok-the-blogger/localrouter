#!/bin/sh

# ============================================================
# Router Proxy Diagnostics
# Запуск: ./diag.sh
# ============================================================

PROXY_PORT=12345
SS_RU_PORT=8443
SS_CA_PORT=8444
SOCKS_PORT=1080
LOG="/tmp/diag-$(date +%Y%m%d-%H%M%S).log"

# --- Цвета ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    # Print with colors to screen
    echo -e "$1"
    # Write without colors to log
    echo "$1" | sed -r 's/\x1b\[[0-9;]*m//g' >> "$LOG"
}
header() { log ""; log "${CYAN}=== $1 ===${NC}"; }
ok() { log "  ${GREEN}[OK]${NC} $1"; }
fail() { log "  ${RED}[FAIL]${NC} $1"; }
warn() { log "  ${YELLOW}[WARN]${NC} $1"; }

log "Diagnostics started: $(date)"
log "Log file: $LOG"

# ============================================================
header "1. HARDWARE & RESOURCES"
# ============================================================

# Xray version
if command -v xray >/dev/null 2>&1; then
    XRAY_VER=$(xray version 2>/dev/null | head -1)
    ok "Xray: $XRAY_VER"
else
    warn "Xray executable not found in PATH"
fi

# Uptime
UPTIME=$(uptime)
log "  Uptime: $UPTIME"

# Memory
MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
MEM_USED=$((MEM_TOTAL - MEM_AVAIL))
MEM_PCT=$((MEM_USED * 100 / MEM_TOTAL))
if [ "$MEM_PCT" -gt 90 ]; then
    fail "Memory: ${MEM_PCT}% used (${MEM_USED}/${MEM_TOTAL} kB) — CRITICAL"
elif [ "$MEM_PCT" -gt 75 ]; then
    warn "Memory: ${MEM_PCT}% used (${MEM_USED}/${MEM_TOTAL} kB)"
else
    ok "Memory: ${MEM_PCT}% used (${MEM_USED}/${MEM_TOTAL} kB)"
fi

# Swap
if grep -q "swap" /proc/swaps 2>/dev/null; then
    SWAP_INFO=$(tail -1 /proc/swaps)
    SWAP_SIZE=$(echo "$SWAP_INFO" | awk '{print $3}')
    SWAP_USED=$(echo "$SWAP_INFO" | awk '{print $4}')
    if [ "$SWAP_SIZE" -gt 0 ]; then
        SWAP_PCT=$((SWAP_USED * 100 / SWAP_SIZE))
    else
        SWAP_PCT=0
    fi
    ok "Swap: ${SWAP_PCT}% used (${SWAP_USED}/${SWAP_SIZE} kB)"
else
    warn "Swap: not mounted"
fi

# ============================================================
header "2. PROCESSES"
# ============================================================

for PROC in xray autossh ssh transmission-da python3; do
    PID=$(pidof "$PROC" 2>/dev/null)
    if [ -n "$PID" ]; then
        RSS=$(ps -o rss= -p $(echo "$PID" | awk '{print $1}') 2>/dev/null | tr -d ' ')
        ok "$PROC running (PID: $PID, RSS: ${RSS:-?} kB)"
    else
        warn "$PROC not running"
    fi
done

# ============================================================
header "3. LISTENING PORTS"
# ============================================================

for PORT in $PROXY_PORT $SOCKS_PORT; do
    if netstat -tlnp 2>/dev/null | grep -q ":${PORT} " || \
       netstat -ulnp 2>/dev/null | grep -q ":${PORT} "; then
        ok "Port $PORT is listening"
    else
        fail "Port $PORT is NOT listening"
    fi
done

# ============================================================
header "4. DNS RESOLUTION"
# ============================================================

for DOMAIN in google.com instagram.com online.sberbank.ru api.coinmarketcap.com; do
    RESULT=$(nslookup "$DOMAIN" 2>/dev/null | grep -A1 "Name:" | tail -1)
    if [ -n "$RESULT" ]; then
        IP=$(echo "$RESULT" | awk '{print $NF}')
        ok "$DOMAIN -> $IP"
    else
        fail "$DOMAIN — DNS resolution failed"
    fi
done

# ============================================================
header "5. DIRECT CONNECTIVITY (from router, bypassing proxy)"
# ============================================================

# Тест прямого соединения с сайтами БЕЗ прокси
for URL in "https://www.google.com" "https://online.sberbank.ru" "https://www.instagram.com" "https://api.coinmarketcap.com/v1/cryptocurrency/listings/latest" "http://connectivitycheck.gstatic.com/generate_204" "http://captive.apple.com/hotspot-detect.html"; do
    DOMAIN=$(echo "$URL" | sed 's|https\?://||' | cut -d'/' -f1)
    HTTP_CODE=$(curl -so /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$URL" 2>/dev/null)
    TIME=$(curl -so /dev/null -w '%{time_total}' --connect-timeout 5 --max-time 10 "$URL" 2>/dev/null)
    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 500 ] 2>/dev/null; then
        ok "DIRECT $DOMAIN — HTTP $HTTP_CODE (${TIME}s)"
    else
        fail "DIRECT $DOMAIN — HTTP $HTTP_CODE (${TIME}s)"
    fi
done

# ============================================================
header "6. PROXY CHANNEL STATUS"
# ============================================================

# Загружаем env для IP Selectel
ENV_FILE="/opt/etc/.router.env"
if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
    ok "Loaded env from $ENV_FILE"
else
    warn "No env file found, using config values"
fi

# Тест TCP-соединения до Shadowsocks портов
for PORT in $SS_RU_PORT $SS_CA_PORT; do
    if [ -n "$SELECTEL_IP" ]; then
        TARGET="$SELECTEL_IP"
    else
        TARGET="178.72.166.42"
    fi
    # Пробуем TCP connect
    if echo "" | nc -w 3 "$TARGET" "$PORT" 2>/dev/null; then
        ok "TCP to $TARGET:$PORT — reachable"
    else
        fail "TCP to $TARGET:$PORT — connection failed or timed out"
    fi
done

# Тест через SOCKS (DO tunnel)
if curl -so /dev/null -w '%{http_code}' --socks5 127.0.0.1:$SOCKS_PORT --connect-timeout 5 --max-time 10 "https://www.google.com" 2>/dev/null | grep -q "200\|301\|302"; then
    ok "SOCKS5 tunnel (DO) — working"
else
    warn "SOCKS5 tunnel (DO) — not responding (autossh may be down)"
fi

# ============================================================
header "7. IPTABLES RULES (NAT PREROUTING)"
# ============================================================

RULES=$(iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null)
log "$RULES"

RULE_COUNT=$(echo "$RULES" | grep -c "REDIRECT\|RETURN")
if [ "$RULE_COUNT" -gt 0 ]; then
    ok "Found $RULE_COUNT proxy-related rules"
else
    fail "No proxy rules found in PREROUTING chain"
fi

# ============================================================
header "8. XRAY ROUTING TEST (domain matching)"
# ============================================================

XRAY_CONF="/opt/etc/xray/config.json"
if [ -f "$XRAY_CONF" ]; then
    DEFAULT_TAG=$(grep -A2 '"outbounds"' "$XRAY_CONF" | grep '"tag"' | head -1 | sed 's/.*"tag": *"//;s/".*//')
    log "  Default outbound: ${DEFAULT_TAG:-unknown}"

    log ""
    log "  Routing map for key domains:"
    log "  --------------------------------------------------"

    for DOMAIN in sberbank.ru coinmarketcap.com instagram.com google.com doubleclick.net; do
        OUTBOUND=$(awk -v dom="$DOMAIN" '
            BEGIN { found=0; current_outbound="" }
            /"rules":/ { in_rules=1 }
            in_rules && /{/ { in_rule=1; current_outbound="" }
            in_rules && in_rule && $0 ~ dom { found=1 }
            in_rules && in_rule && /"outboundTag":/ {
                current_outbound=$0; sub(/.*"outboundTag": *"/, "", current_outbound); sub(/".*/, "", current_outbound)
            }
            in_rules && in_rule && /}/ {
                if (found && current_outbound != "") { print current_outbound; exit_loop=1 }
                in_rule=0; found=0
            }
            exit_loop { exit }
        ' "$XRAY_CONF")

        if [ -n "$OUTBOUND" ]; then
            ok "$DOMAIN -> $OUTBOUND"
        else
            warn "$DOMAIN -> DEFAULT ($DEFAULT_TAG)"
        fi
    done
    log "  --------------------------------------------------"

    # Есть ли blackhole?
    if grep -q '"blackhole"' "$XRAY_CONF"; then
        ok "Blackhole outbound present"
        # Проверяем, не первый ли он
        FIRST_PROTO=$(grep '"protocol"' "$XRAY_CONF" | head -1)
        if echo "$FIRST_PROTO" | grep -q "blackhole"; then
            fail "BLACKHOLE IS FIRST OUTBOUND — this would block all unmatched traffic!"
        fi
    fi
else
    fail "Xray config not found at $XRAY_CONF"
fi

# ============================================================
header "9. GEOSITE/GEOIP FILES"
# ============================================================

NOW=$(date +%s)
for F in /opt/share/xray/geosite.dat /opt/share/xray/geoip.dat \
         /opt/sbin/geosite.dat /opt/sbin/geoip.dat \
         /opt/etc/xray/geosite.dat /opt/etc/xray/geoip.dat; do
    if [ -f "$F" ]; then
        SIZE=$(ls -lh "$F" | awk '{print $5}')
        MOD_STR=$(ls -l "$F" | awk '{print $6, $7, $8}')
        MOD_TS=$(stat -c %Y "$F" 2>/dev/null) # if stat exists

        if [ -z "$MOD_TS" ]; then
            # fallback for busybox without stat
            ok "$F — $SIZE, modified $MOD_STR"
        else
            DIFF=$(( (NOW - MOD_TS) / 86400 ))
            if [ "$DIFF" -gt 30 ]; then
                warn "$F — $SIZE, modified $MOD_STR ($DIFF days old)"
            else
                ok "$F — $SIZE, modified $MOD_STR ($DIFF days old)"
            fi
        fi
    fi
done

# ============================================================
header "10. LATENCY COMPARISON"
# ============================================================

# Direct ping
for HOST in online.sberbank.ru instagram.com google.com; do
    PING=$(ping -c 3 -W 3 "$HOST" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
    if [ -n "$PING" ]; then
        ok "Ping $HOST — avg ${PING}ms"
    else
        fail "Ping $HOST — no response"
    fi
done

# ============================================================
header "SUMMARY"
# ============================================================
log ""
log "Full log saved to: $LOG"
log "To share: cat $LOG"
log ""
log "Done: $(date)"
