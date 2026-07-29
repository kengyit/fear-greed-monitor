#!/bin/bash
# ============================================================
# fear_greed_monitor.sh
#
# Automated stock market Fear & Greed Index monitor.
#
# Modes:
#   (default)  Alert mode — checks the CNN/FearGreedChart composite
#              index every 30 min during US market hours
#              (9PM–4:30AM SGT) and sends a Telegram alert when the
#              score enters Extreme Fear (<10).
#   --daily    Daily mode — sends a Telegram summary of the current
#              score every day at 9:35 PM SGT, regardless of value.
#              Safe to re-run: only one summary is sent per day, and
#              a missed run (machine was off) is caught up on boot.
#
# Part of the EightDay personal AI command centre.
# ============================================================

set -euo pipefail

# ─── MODE ───────────────────────────────────────────────────

MODE="alert"
if [ "${1:-}" = "--daily" ]; then
    MODE="daily"
fi

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

# Time window (SGT) — alert mode only runs between 9PM and 4:30AM
WINDOW_START="${FGI_WINDOW_START:-21}"
WINDOW_END_HOUR="${FGI_WINDOW_END_HOUR:-4}"
WINDOW_END_MIN="${FGI_WINDOW_END_MIN:-30}"

# Daily summary time (SGT) — daily mode sends at/after this time
DAILY_HOUR="${FGI_DAILY_HOUR:-21}"
DAILY_MIN="${FGI_DAILY_MIN:-35}"
# Persistent state file so a reboot never causes a duplicate daily send
# (deliberately NOT in /tmp — macOS clears /tmp on reboot)
DAILY_STATE_FILE="${FGI_DAILY_STATE_FILE:-$HOME/.fear_greed_daily_last_sent}"

# Cooldown: don't spam alerts within this many minutes
COOLDOWN_MINUTES="${FGI_COOLDOWN_MINUTES:-120}"
COOLDOWN_FILE="/tmp/fgi_last_alert_timestamp"

# ─── SETUP ──────────────────────────────────────────────────

mkdir -p "$(dirname "$LOG_FILE")"
TIMESTAMP=$(TZ="Asia/Singapore" date "+%Y-%m-%d %H:%M:%S SGT")
SGT_HOUR=$(TZ="Asia/Singapore" date "+%-H")
SGT_MIN=$(TZ="Asia/Singapore" date "+%-M")
SGT_TIME=$(TZ="Asia/Singapore" date "+%H:%M SGT")
SGT_DATE=$(TZ="Asia/Singapore" date "+%Y-%m-%d")

log() {
    echo "[$TIMESTAMP] $1" >> "$LOG_FILE"
}

# ─── TELEGRAM SENDER ────────────────────────────────────────
# send_telegram "message text" — returns 0 on delivery, 1 on failure

send_telegram() {
    local message="$1"
    local payload result ok err

    # JSON payload for proper encoding of newlines, emoji, ampersands
    payload=$(jq -n \
        --arg chat_id "$TELEGRAM_CHAT_ID" \
        --arg text "$message" \
        '{chat_id: $chat_id, text: $text}')

    result=$(curl -s --max-time 10 \
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1)

    ok=$(echo "$result" | jq -r '.ok // false' 2>/dev/null)

    if [ "$ok" = "true" ]; then
        return 0
    else
        err=$(echo "$result" | jq -r '.description // "Unknown error"' 2>/dev/null)
        log "FAIL — Telegram send failed: $err"
        return 1
    fi
}

# ─── MODE GATES ─────────────────────────────────────────────

if [ "$MODE" = "daily" ]; then
    # Daily mode fires unconditionally at 9:35 SGT. The plist also runs
    # this at load (boot/login), so gate on time-of-day and a once-per-day
    # marker: send only at/after DAILY_HOUR:DAILY_MIN, and only once.
    NOW_MINUTES=$(( SGT_HOUR * 60 + SGT_MIN ))
    DAILY_MINUTES=$(( DAILY_HOUR * 60 + DAILY_MIN ))

    if [ "$NOW_MINUTES" -lt "$DAILY_MINUTES" ]; then
        log "DAILY-SKIP — $SGT_TIME is before daily send time (${DAILY_HOUR}:$(printf '%02d' "$DAILY_MIN") SGT)."
        exit 0
    fi

    if [ -f "$DAILY_STATE_FILE" ] && [ "$(cat "$DAILY_STATE_FILE")" = "$SGT_DATE" ]; then
        log "DAILY-SKIP — Summary already sent today ($SGT_DATE)."
        exit 0
    fi
else
    # Alert mode: only run inside the window 21:00 → 04:30 (crosses midnight)
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
fi

# ─── COOLDOWN CHECK (alert mode) ────────────────────────────

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

log "FETCH — Calling API at $SGT_TIME (mode: $MODE)"

# `|| CURL_EXIT=$?` keeps set -e from killing the script before
# the failure is logged
CURL_EXIT=0
RESPONSE=$(curl -s --max-time 15 "$API_URL" 2>&1) || CURL_EXIT=$?

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

BREAKDOWN_FLAT=$(echo -e "$BREAKDOWN")

log "SCORE — $SCORE ($LABEL) | Threshold: <$THRESHOLD"

# ─── DAILY SUMMARY (daily mode) ────────────────────────────

if [ "$MODE" = "daily" ]; then
    log "DAILY — Sending daily summary for $SGT_DATE."

    MESSAGE=$(cat <<EOF
📊 Daily Fear & Greed Update

📈 Fear & Greed Index: ${SCORE} (${LABEL})
📅 ${SGT_DATE}, ${SGT_TIME}

📉 Component Breakdown:
${BREAKDOWN_FLAT}
Source: feargreedchart.com
EOF
)

    if send_telegram "$MESSAGE"; then
        log "DAILY-SENT — Daily summary delivered successfully"
        echo "$SGT_DATE" > "$DAILY_STATE_FILE"
    fi

    exit 0
fi

# ─── THRESHOLD CHECK & ALERT (alert mode) ──────────────────

if [ "$SCORE" -lt "$THRESHOLD" ]; then
    if ! check_cooldown; then
        exit 0
    fi

    log "ALERT — Score $SCORE is below threshold $THRESHOLD. Sending Telegram alert."

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

    if send_telegram "$MESSAGE"; then
        log "SENT — Telegram alert delivered successfully"
        set_cooldown
    fi
else
    log "OK — Score $SCORE is above threshold $THRESHOLD. No alert needed."
fi

exit 0
