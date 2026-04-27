#!/bin/bash
# ============================================================
# fear_greed_monitor.sh
# 
# Automated stock market Fear & Greed Index monitor.
# Checks the CNN/FearGreedChart composite index every 30 min
# during US market hours (9PM–4:30AM SGT) and sends a 
# Telegram alert when the score enters Extreme Fear (<10).
#
# Part of the EightDay personal AI command centre.
# ============================================================

set -euo pipefail

# ─── CONFIGURATION ──────────────────────────────────────────

# Load from .env if present (for local development)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/.env"
fi

# Core settings (override via .env or environment variables)
THRESHOLD="${FGI_THRESHOLD:-10}"
TELEGRAM_BOT_TOKEN="${FGI_TELEGRAM_BOT_TOKEN:?Error: Set FGI_TELEGRAM_BOT_TOKEN in .env or environment}"
TELEGRAM_CHAT_ID="${FGI_TELEGRAM_CHAT_ID:?Error: Set FGI_TELEGRAM_CHAT_ID in .env or environment}"
LOG_FILE="${FGI_LOG_FILE:-$HOME/logs/fear_greed.log}"
API_URL="https://feargreedchart.com/api/?action=all"

# Time window (SGT) — only run between 9PM and 4:30AM
WINDOW_START="${FGI_WINDOW_START:-21}"
WINDOW_END_HOUR="${FGI_WINDOW_END_HOUR:-4}"
WINDOW_END_MIN="${FGI_WINDOW_END_MIN:-30}"

# Cooldown: don't spam alerts within this many minutes
COOLDOWN_MINUTES="${FGI_COOLDOWN_MINUTES:-120}"
COOLDOWN_FILE="/tmp/fgi_last_alert_timestamp"

# ─── SETUP ──────────────────────────────────────────────────

mkdir -p "$(dirname "$LOG_FILE")"
TIMESTAMP=$(TZ="Asia/Singapore" date "+%Y-%m-%d %H:%M:%S SGT")
SGT_HOUR=$(TZ="Asia/Singapore" date "+%-H")
SGT_MIN=$(TZ="Asia/Singapore" date "+%-M")
SGT_TIME=$(TZ="Asia/Singapore" date "+%H:%M SGT")

log() {
    echo "[$TIMESTAMP] $1" >> "$LOG_FILE"
}

# ─── TIME WINDOW CHECK ─────────────────────────────────────
# Window: 21:00 → 04:30 (crosses midnight)
IN_WINDOW=false

if [ "$SGT_HOUR" -ge "$WINDOW_START" ]; then
    IN_WINDOW=true
elif [ "$SGT_HOUR" -lt "$WINDOW_END_HOUR" ]; then
    IN_WINDOW=true
elif [ "$SGT_HOUR" -eq "$WINDOW_END_HOUR" ] && [ "$SGT_MIN" -le "$WINDOW_END_MIN" ]; then
    IN_WINDOW=true
fi

if [ "$IN_WINDOW" = false ]; then
    log "SKIP — Outside monitoring window ($SGT_TIME). Window: ${WINDOW_START}:00–${WINDOW_END_HOUR}:${WINDOW_END_MIN}"
    exit 0
fi

# ─── COOLDOWN CHECK ─────────────────────────────────────────

check_cooldown() {
    if [ -f "$COOLDOWN_FILE" ]; then
        LAST_ALERT=$(cat "$COOLDOWN_FILE")
        NOW=$(date +%s)
        DIFF=$(( (NOW - LAST_ALERT) / 60 ))
        if [ "$DIFF" -lt "$COOLDOWN_MINUTES" ]; then
            log "COOLDOWN — Last alert was ${DIFF}m ago (cooldown: ${COOLDOWN_MINUTES}m). Skipping."
            return 1
        fi
    fi
    return 0
}

set_cooldown() {
    date +%s > "$COOLDOWN_FILE"
}

# ─── FETCH FEAR & GREED INDEX ──────────────────────────────

log "FETCH — Calling API at $SGT_TIME"

RESPONSE=$(curl -s --max-time 15 "$API_URL" 2>&1)
CURL_EXIT=$?

if [ $CURL_EXIT -ne 0 ] || [ -z "$RESPONSE" ]; then
    log "ERROR — API request failed (curl exit: $CURL_EXIT)"
    exit 1
fi

# ─── PARSE SCORE ───────────────────────────────────────────
# API may return { "score": { "score": 42, ... } } or { "score": 42 }
# Try nested first, then top-level

SCORE=$(echo "$RESPONSE" | jq -r '.score.score // empty' 2>/dev/null)

if [ -z "$SCORE" ]; then
    SCORE=$(echo "$RESPONSE" | jq -r 'if (.score | type) == "number" then .score else empty end' 2>/dev/null)
fi

if [ -z "$SCORE" ]; then
    RESPONSE_KEYS=$(echo "$RESPONSE" | jq -r 'keys | join(", ")' 2>/dev/null)
    log "ERROR — Could not parse score. Top-level keys: $RESPONSE_KEYS"
    log "DEBUG — Raw response (first 500 chars): $(echo "$RESPONSE" | head -c 500)"
    exit 1
fi

# ─── DETERMINE LABEL ───────────────────────────────────────

if [ "$SCORE" -le 20 ]; then
    LABEL="Extreme Fear"
elif [ "$SCORE" -le 40 ]; then
    LABEL="Fear"
elif [ "$SCORE" -le 60 ]; then
    LABEL="Neutral"
elif [ "$SCORE" -le 80 ]; then
    LABEL="Greed"
else
    LABEL="Extreme Greed"
fi

# ─── PARSE COMPONENTS ─────────────────────────────────────
# Extract each component: name, val, wt

COMP_COUNT=$(echo "$RESPONSE" | jq -r '.score.components // [] | length' 2>/dev/null)
BREAKDOWN=""

if [ -n "$COMP_COUNT" ] && [ "$COMP_COUNT" -gt 0 ]; then
    for i in $(seq 0 $((COMP_COUNT - 1))); do
        COMP_NAME=$(echo "$RESPONSE" | jq -r ".score.components[$i].name // \"Component $((i+1))\"")
        COMP_VAL=$(echo "$RESPONSE" | jq -r ".score.components[$i].val // \"?\"")
        COMP_WT=$(echo "$RESPONSE" | jq -r ".score.components[$i].wt // \"?\"")
        BREAKDOWN="${BREAKDOWN}  • ${COMP_NAME}: ${COMP_VAL}/100 (wt: ${COMP_WT}%)\n"
    done
else
    BREAKDOWN="  (Component breakdown not available)\n"
fi

log "SCORE — $SCORE ($LABEL) | Threshold: <$THRESHOLD"

# ─── THRESHOLD CHECK & ALERT ──────────────────────────────

if [ "$SCORE" -lt "$THRESHOLD" ]; then
    if ! check_cooldown; then
        exit 0
    fi

    log "ALERT — Score $SCORE is below threshold $THRESHOLD. Sending Telegram alert."

    BREAKDOWN_FLAT=$(echo -e "$BREAKDOWN")

    MESSAGE=$(cat <<EOF
🚨 EXTREME FEAR ALERT 🚨

📊 Fear & Greed Index: ${SCORE} (${LABEL})
🕐 Checked at: ${SGT_TIME}

📉 Component Breakdown:
${BREAKDOWN_FLAT}
⚠️ Index is below ${THRESHOLD} — market in extreme fear territory.

Source: feargreedchart.com
EOF
)

    # Send via Telegram Bot API (JSON payload for proper encoding)
    PAYLOAD=$(jq -n \
        --arg chat_id "$TELEGRAM_CHAT_ID" \
        --arg text "$MESSAGE" \
        '{chat_id: $chat_id, text: $text}')

    TELEGRAM_RESULT=$(curl -s --max-time 10 \
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" 2>&1)

    TG_OK=$(echo "$TELEGRAM_RESULT" | jq -r '.ok // false' 2>/dev/null)

    if [ "$TG_OK" = "true" ]; then
        log "SENT — Telegram alert delivered successfully"
        set_cooldown
    else
        TG_ERR=$(echo "$TELEGRAM_RESULT" | jq -r '.description // "Unknown error"' 2>/dev/null)
        log "FAIL — Telegram send failed: $TG_ERR"
    fi
else
    log "OK — Score $SCORE is above threshold $THRESHOLD. No alert needed."
fi

exit 0
