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

# ─── MARKET SNAPSHOT HELPERS (daily mode) ───────────────────
# Each helper is best-effort: on any fetch/parse failure it prints
# an "n/a" line so the daily summary still goes out.

add_commas() {
    # 7400.12 → 7,400 (rounds to whole number, adds thousands separators)
    printf "%.0f" "$1" | rev | sed 's/[0-9]\{3\}/&,/g' | rev | sed 's/^,//'
}

yahoo_line() {
    # $1 = display name, $2 = URL-encoded Yahoo symbol
    # Prints: "  • S&P500: 6,364 (down: 0.3%)"
    local json price prev pct dir
    json=$(curl -s --max-time 10 -H "User-Agent: Mozilla/5.0" \
        "https://query1.finance.yahoo.com/v8/finance/chart/${2}?interval=1d&range=5d" 2>/dev/null) || json=""
    price=$(echo "$json" | jq -r '.chart.result[0].meta.regularMarketPrice // empty' 2>/dev/null) || price=""
    prev=$(echo "$json" | jq -r '.chart.result[0].meta.chartPreviousClose // .chart.result[0].meta.previousClose // empty' 2>/dev/null) || prev=""
    if [ -z "$price" ] || [ -z "$prev" ]; then
        echo "  • ${1}: n/a"
        return 0
    fi
    pct=$(awk -v p="$price" -v q="$prev" 'BEGIN { printf "%.1f", (p - q) / q * 100 }')
    case "$pct" in
        -*) dir="down"; pct="${pct#-}" ;;
        *)  dir="up" ;;
    esac
    echo "  • ${1}: $(add_commas "$price") (${dir}: ${pct}%)"
}

fred_date_fmt() {
    # 2026-06-01 → 1/6/2026
    awk -v d="$1" 'BEGIN { split(d, a, "-"); printf "%d/%d/%s", a[3] + 0, a[2] + 0, a[1] }'
}

rate_line() {
    # Effective Federal Funds Rate (FRED FEDFUNDS, monthly, no API key)
    # Prints: "  • Interest Rate: 4.33% (last: 4.33% (as of 1/6/2026))"
    local csv rows cur last lastd
    csv=$(curl -s --max-time 10 "https://fred.stlouisfed.org/graph/fredgraph.csv?id=FEDFUNDS" 2>/dev/null) || csv=""
    rows=$(echo "$csv" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2},[0-9.]+$' | tail -2) || rows=""
    if [ "$(echo "$rows" | grep -c '^[0-9]')" -ne 2 ]; then
        echo "  • Interest Rate: n/a"
        return 0
    fi
    lastd=$(echo "$rows" | head -1 | cut -d, -f1)
    last=$(echo "$rows" | head -1 | cut -d, -f2)
    cur=$(echo "$rows" | tail -1 | cut -d, -f2)
    echo "  • Interest Rate: ${cur}% (last: ${last}% (as of $(fred_date_fmt "$lastd")))"
}

cpi_line() {
    # CPI year-over-year inflation, computed from the FRED CPIAUCSL index
    # Prints: "  • CPI: 2.7% (last: 2.4% (as of 1/6/2026))"
    local csv result cur curd last lastd
    csv=$(curl -s --max-time 10 "https://fred.stlouisfed.org/graph/fredgraph.csv?id=CPIAUCSL" 2>/dev/null) || csv=""
    result=$(echo "$csv" | awk -F, '
        /^[0-9][0-9][0-9][0-9]-/ && $2 ~ /^[0-9.]+$/ { d[n] = $1; v[n] = $2; n++ }
        END {
            if (n < 14) exit 1
            printf "%.1f|%.1f|%s", (v[n-1] / v[n-13] - 1) * 100, (v[n-2] / v[n-14] - 1) * 100, d[n-2]
        }') || result=""
    if [ -z "$result" ]; then
        echo "  • CPI: n/a"
        return 0
    fi
    cur=$(echo "$result" | cut -d'|' -f1)
    last=$(echo "$result" | cut -d'|' -f2)
    lastd=$(echo "$result" | cut -d'|' -f3)
    echo "  • CPI: ${cur}% (last: ${last}% (as of $(fred_date_fmt "$lastd")))"
}

news_lines() {
    # Top 3 headlines from the CNBC Top News RSS feed
    local rss titles
    rss=$(curl -s --max-time 10 -H "User-Agent: Mozilla/5.0" \
        "https://www.cnbc.com/id/100003114/device/rss/rss.html" 2>/dev/null) || rss=""
    # Flatten, strip CDATA, pull <title> tags; first title is the channel name
    titles=$(echo "$rss" | tr -d '\r\n' | sed 's/<!\[CDATA\[//g; s/\]\]>//g' \
        | grep -o '<title>[^<]*</title>' | sed 's/<\/*title>//g' \
        | sed "s/&amp;/\&/g; s/&#039;/'/g; s/&quot;/\"/g; s/&apos;/'/g" \
        | tail -n +2 | head -3) || titles=""
    if [ -z "$titles" ]; then
        echo "      • (news unavailable)"
        return 0
    fi
    echo "$titles" | sed 's/^/      • /'
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
    log "DAILY — Building market snapshot for $SGT_DATE."

    SNAPSHOT=$(
        yahoo_line "S&P500" "%5EGSPC"
        yahoo_line "Nasdaq" "%5EIXIC"
        yahoo_line "HSI" "%5EHSI"
        yahoo_line "Bitcoin" "BTC-USD"
        rate_line
        cpi_line
        echo "  • Top 3 breaking news:"
        news_lines
    )

    log "DAILY — Sending daily summary for $SGT_DATE."

    MESSAGE=$(cat <<EOF
📊 Daily Fear & Greed Update

📈 Fear & Greed Index: ${SCORE} (${LABEL})
📅 ${SGT_DATE}, ${SGT_TIME}

📉 Index:
${SNAPSHOT}
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
