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
#   --test     With --daily: send immediately, ignoring the send-time
#              gate and the once-per-day guard, and WITHOUT marking
#              today as sent — the scheduled 21:35 send still happens.
#
# Part of the EightDay personal AI command centre.
# ============================================================

set -euo pipefail

# ─── MODE ───────────────────────────────────────────────────

MODE="alert"
FORCE_TEST=false
for arg in "$@"; do
    case "$arg" in
        --daily)    MODE="daily" ;;
        --test)     FORCE_TEST=true ;;
        --listener) MODE="listener" ;;
    esac
done

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
# Primary: CNN's official Fear & Greed endpoint — same number as the
# gauge on edition.cnn.com/markets/fear-and-greed
CNN_API_URL="https://production.dataviz.cnn.io/index/fearandgreed/graphdata"
# Fallback mirror (may lag/diverge from CNN), used only if CNN fails
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
# send_telegram "message text" [with_refresh] [html]
# Returns 0 on delivery, 1 on failure.
#   with_refresh — attach an inline 🔄 button that triggers a fresh
#                  summary (see --listener)
#   html         — send with parse_mode HTML (message body must already
#                  be escaped via html_escape, tags added after)

html_escape() {
    # & first, then < and > — order matters
    sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

send_telegram() {
    local message="$1"
    shift
    local payload result ok err opt

    # JSON payload for proper encoding of newlines, emoji, ampersands
    payload=$(jq -n \
        --arg chat_id "$TELEGRAM_CHAT_ID" \
        --arg text "$message" \
        '{chat_id: $chat_id, text: $text}')

    for opt in "$@"; do
        case "$opt" in
            with_refresh)
                payload=$(echo "$payload" | jq \
                    '. + {reply_markup: {inline_keyboard: [[{text: "🔄 Refresh data", callback_data: "fgi_refresh"}]]}}')
                ;;
            html)
                payload=$(echo "$payload" | jq '. + {parse_mode: "HTML"}')
                ;;
        esac
    done

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
    # Prints: "  • S&P500: 6,364 (🔴 -0.3%)" / "  • HSI: 25,808 (🟢 +2.0%)"
    # IMPORTANT: range must be 1d — with a longer range, Yahoo's
    # chartPreviousClose is the close before the range START (days ago),
    # which silently turns the %% into a multi-day cumulative move.
    local json price prev pct dir
    json=$(curl -s --max-time 10 -H "User-Agent: Mozilla/5.0" \
        "https://query1.finance.yahoo.com/v8/finance/chart/${2}?interval=1d&range=1d" 2>/dev/null) || json=""
    price=$(echo "$json" | jq -r '.chart.result[0].meta.regularMarketPrice // empty' 2>/dev/null) || price=""
    prev=$(echo "$json" | jq -r '.chart.result[0].meta.regularMarketPreviousClose // .chart.result[0].meta.previousClose // .chart.result[0].meta.chartPreviousClose // empty' 2>/dev/null) || prev=""
    if [ -z "$price" ] || [ -z "$prev" ]; then
        echo "  • ${1}: n/a"
        return 0
    fi
    pct=$(awk -v p="$price" -v q="$prev" 'BEGIN { printf "%.1f", (p - q) / q * 100 }')
    case "$pct" in
        -*) dir="🔴 -"; pct="${pct#-}" ;;
        *)  dir="🟢 +" ;;
    esac
    echo "  • ${1}: $(add_commas "$price") (${dir}${pct}%)"
}

fred_date_fmt() {
    # 2026-06-01 → 1/6/2026
    awk -v d="$1" 'BEGIN { split(d, a, "-"); printf "%d/%d/%s", a[3] + 0, a[2] + 0, a[1] }'
}

fred_line() {
    # $1 = display name, $2 = FRED series ID (US data, monthly, no API key)
    # Shows the latest monthly value and the previous month's reading:
    # "  • Interest Rate: 4.33% (last: 4.33% (as of 1/6/2026))"
    local csv rows cur last lastd
    csv=$(curl -s --max-time 10 "https://fred.stlouisfed.org/graph/fredgraph.csv?id=${2}" 2>/dev/null) || csv=""
    rows=$(echo "$csv" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2},[0-9.]+$' | tail -2) || rows=""
    if [ "$(echo "$rows" | grep -c '^[0-9]')" -ne 2 ]; then
        echo "  • ${1}: n/a"
        return 0
    fi
    lastd=$(echo "$rows" | head -1 | cut -d, -f1)
    last=$(echo "$rows" | head -1 | cut -d, -f2)
    cur=$(echo "$rows" | tail -1 | cut -d, -f2)
    echo "  • ${1}: ${cur}% (last: ${last}% (as of $(fred_date_fmt "$lastd")))"
}

cpi_line() {
    # US CPI year-over-year inflation, computed from the monthly FRED
    # CPIAUCSL index (US city average, all items)
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

news_date_fmt() {
    # RFC-822 RSS date ("Wed, 30 Jul 2026 04:12:33 GMT") → "30/7/2026 12:12 SGT"
    # Tries GNU date, then BSD (macOS) date; falls back to the raw string.
    local d="$1" out
    out=$(TZ="Asia/Singapore" date -d "$d" "+%-d/%-m/%Y %H:%M SGT" 2>/dev/null) \
        || out=$(TZ="Asia/Singapore" date -j -f "%a, %d %b %Y %H:%M:%S %Z" "$d" "+%-d/%-m/%Y %H:%M SGT" 2>/dev/null) \
        || out=$(TZ="Asia/Singapore" date -j -f "%a, %d %b %Y %H:%M:%S %z" "$d" "+%-d/%-m/%Y %H:%M SGT" 2>/dev/null) \
        || out="$d"
    echo "$out"
}

news_lines() {
    # Top 3 headlines from the CNBC Top News RSS feed, each with its
    # publish datetime (converted to SGT)
    local rss items item title pd
    rss=$(curl -s --max-time 10 -H "User-Agent: Mozilla/5.0" \
        "https://www.cnbc.com/id/100003114/device/rss/rss.html" 2>/dev/null) || rss=""
    # Flatten, then split so each <item> sits on its own line, keeping
    # title and pubDate paired per story
    items=$(echo "$rss" | tr -d '\r\n' | sed $'s/<item>/\\\n<item>/g' \
        | grep '^<item>' | head -3) || items=""
    if [ -z "$items" ]; then
        echo "      • (news unavailable)"
        return 0
    fi
    while IFS= read -r item; do
        title=$(echo "$item" | sed 's/.*<title>//; s|</title>.*||; s/<!\[CDATA\[//g; s/\]\]>//g' \
            | sed "s/&amp;/\&/g; s/&#039;/'/g; s/&quot;/\"/g; s/&apos;/'/g")
        pd=$(echo "$item" | sed -n 's/.*<pubDate>\([^<]*\)<\/pubDate>.*/\1/p')
        if [ -n "$pd" ]; then
            echo "      • ${title} ($(news_date_fmt "$pd"))"
        else
            echo "      • ${title}"
        fi
    done <<< "$items"
}

# ─── TELEGRAM LISTENER (refresh button) ────────────────────
# Long-polls Telegram for taps on the 🔄 Refresh button (or a typed
# /refresh command) and responds with a freshly-fetched summary.
# Runs forever under its own KeepAlive LaunchAgent; only requests
# from TELEGRAM_CHAT_ID are honored.

if [ "$MODE" = "listener" ]; then
    OFFSET_FILE="${FGI_TG_OFFSET_FILE:-$HOME/.fear_greed_tg_offset}"
    log "LISTENER — Telegram listener started (long-poll)."
    set +e  # a long-running daemon must survive transient errors

    while true; do
        OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null)
        [ -z "$OFFSET" ] && OFFSET=0

        UPDATES=$(curl -s --max-time 60 \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?timeout=50&offset=${OFFSET}" 2>/dev/null)
        OK=$(echo "$UPDATES" | jq -r '.ok // false' 2>/dev/null)
        if [ "$OK" != "true" ]; then
            ERR=$(echo "$UPDATES" | jq -r '.description // "no response"' 2>/dev/null)
            log "LISTENER — getUpdates failed ($ERR). Retrying in 10s."
            sleep 10
            continue
        fi

        COUNT=$(echo "$UPDATES" | jq -r '.result | length' 2>/dev/null)
        if [ -z "$COUNT" ] || [ "$COUNT" -eq 0 ]; then
            continue
        fi

        LAST_ID=$(echo "$UPDATES" | jq -r '.result[-1].update_id')
        echo $((LAST_ID + 1)) > "$OFFSET_FILE"

        for i in $(seq 0 $((COUNT - 1))); do
            U=$(echo "$UPDATES" | jq ".result[$i]")
            CB_ID=$(echo "$U" | jq -r '.callback_query.id // empty')
            CB_DATA=$(echo "$U" | jq -r '.callback_query.data // empty')
            CB_FROM=$(echo "$U" | jq -r '.callback_query.from.id // empty')
            MSG_TEXT=$(echo "$U" | jq -r '.message.text // empty')
            MSG_FROM=$(echo "$U" | jq -r '.message.from.id // empty')

            TRIGGER=false
            if [ -n "$CB_ID" ] && [ "$CB_DATA" = "fgi_refresh" ] && [ "$CB_FROM" = "$TELEGRAM_CHAT_ID" ]; then
                # Acknowledge the tap so the button stops its spinner
                curl -s --max-time 10 \
                    -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/answerCallbackQuery" \
                    -d "callback_query_id=${CB_ID}" \
                    -d "text=Refreshing — pulling latest data…" >/dev/null 2>&1
                TRIGGER=true
            elif [ "$MSG_FROM" = "$TELEGRAM_CHAT_ID" ] && { [ "$MSG_TEXT" = "/refresh" ] || [ "$MSG_TEXT" = "/now" ]; }; then
                TRIGGER=true
            fi

            if [ "$TRIGGER" = true ]; then
                log "LISTENER — Refresh requested via Telegram. Sending fresh summary."
                bash "$0" --daily --test || log "LISTENER — Refresh run failed."
            fi
        done
    done
    # not reached
fi

# ─── MODE GATES ─────────────────────────────────────────────

if [ "$MODE" = "daily" ]; then
    # Daily mode fires unconditionally at 9:35 PM SGT. The plist also runs
    # this at load (boot/login), so gate on time-of-day and a once-per-day
    # marker: send only at/after DAILY_HOUR:DAILY_MIN, and only once.
    # --test bypasses both gates for manual verification.
    if [ "$FORCE_TEST" = true ]; then
        log "DAILY-TEST — Manual test run: bypassing time gate and once-per-day guard."
    else
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
# Primary: CNN's official endpoint (matches the cnn.com gauge).
# Fallback: the feargreedchart.com mirror if CNN is unreachable.

SOURCE_NAME="CNN"
log "FETCH — Calling CNN Fear & Greed API at $SGT_TIME (mode: $MODE)"

# `|| CURL_EXIT=$?` keeps set -e from killing the script before
# the failure is logged
# CNN rejects bare/robotic user agents — send full browser-like headers
BROWSER_UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
CNN_TMP=$(mktemp)
HTTP_CODE=$(curl -s --max-time 20 --compressed \
    -H "User-Agent: $BROWSER_UA" \
    -H "Accept: application/json, text/plain, */*" \
    -H "Accept-Language: en-US,en;q=0.9" \
    -H "Origin: https://edition.cnn.com" \
    -H "Referer: https://edition.cnn.com/" \
    -o "$CNN_TMP" -w "%{http_code}" \
    "$CNN_API_URL" 2>/dev/null) || HTTP_CODE="000"
RESPONSE=$(cat "$CNN_TMP" 2>/dev/null) || RESPONSE=""
rm -f "$CNN_TMP"
RAW_SCORE=$(echo "$RESPONSE" | jq -r '.fear_and_greed.score // empty' 2>/dev/null) || RAW_SCORE=""

if [ -n "$RAW_SCORE" ]; then
    SCORE=$(printf "%.0f" "$RAW_SCORE")

    # CNN publishes 7 component indicators (score + rating, no weights)
    BREAKDOWN_FLAT=$(echo "$RESPONSE" | jq -r '
        def line(name; key):
            "  • " + name + ": "
            + ((.[key].score // empty) | round | tostring) + "/100 ("
            + (.[key].rating // "?") + ")";
        [line("Market Momentum (S&P500)"; "market_momentum_sp500"),
         line("Stock Price Strength"; "stock_price_strength"),
         line("Stock Price Breadth"; "stock_price_breadth"),
         line("Put/Call Options"; "put_call_options"),
         line("Market Volatility (VIX)"; "market_volatility_vix"),
         line("Junk Bond Demand"; "junk_bond_demand"),
         line("Safe Haven Demand"; "safe_haven_demand")] | join("\n")' 2>/dev/null) || BREAKDOWN_FLAT=""
    if [ -z "$BREAKDOWN_FLAT" ]; then
        BREAKDOWN_FLAT="  (Component breakdown not available)"
    fi
else
    log "WARN — CNN API failed (HTTP $HTTP_CODE, body: $(echo "$RESPONSE" | head -c 200)). Falling back to feargreedchart.com."
    SOURCE_NAME="feargreedchart.com"

    CURL_EXIT=0
    RESPONSE=$(curl -s --max-time 15 "$API_URL" 2>&1) || CURL_EXIT=$?

    if [ $CURL_EXIT -ne 0 ] || [ -z "$RESPONSE" ]; then
        log "ERROR — Fallback API request failed (curl exit: $CURL_EXIT)"
        exit 1
    fi

    # Mirror may return { "score": { "score": 42, ... } } or { "score": 42 }
    SCORE=$(echo "$RESPONSE" | jq -r '.score.score // empty' 2>/dev/null) || SCORE=""
    if [ -z "$SCORE" ]; then
        SCORE=$(echo "$RESPONSE" | jq -r 'if (.score | type) == "number" then .score else empty end' 2>/dev/null) || SCORE=""
    fi
    if [ -z "$SCORE" ]; then
        RESPONSE_KEYS=$(echo "$RESPONSE" | jq -r 'keys | join(", ")' 2>/dev/null) || RESPONSE_KEYS=""
        log "ERROR — Could not parse score. Top-level keys: $RESPONSE_KEYS"
        log "DEBUG — Raw response (first 500 chars): $(echo "$RESPONSE" | head -c 500)"
        exit 1
    fi

    COMP_COUNT=$(echo "$RESPONSE" | jq -r '.score.components // [] | length' 2>/dev/null) || COMP_COUNT=0
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

log "SCORE — $SCORE ($LABEL) | Source: $SOURCE_NAME | Threshold: <$THRESHOLD"

# ─── DAILY SUMMARY (daily mode) ────────────────────────────

if [ "$MODE" = "daily" ]; then
    log "DAILY — Building market snapshot for $SGT_DATE."

    SNAPSHOT=$(
        yahoo_line "S&P500" "%5EGSPC"
        yahoo_line "Nasdaq" "%5EIXIC"
        yahoo_line "HSI" "%5EHSI"
        yahoo_line "Bitcoin" "BTC-USD"
        fred_line "Interest Rate" "FEDFUNDS"   # US Effective Federal Funds Rate, monthly
        cpi_line                               # US CPI YoY, monthly
        fred_line "Unemployment Rate" "UNRATE" # US civilian unemployment rate, monthly
        echo "  • Top 3 breaking news:"
        news_lines
    )

    log "DAILY — Sending daily summary for $SGT_DATE."

    # Flag the score when it came from the fallback mirror, so a number
    # that diverges from CNN's gauge is never presented silently
    SCORE_NOTE=""
    if [ "$SOURCE_NAME" != "CNN" ]; then
        SCORE_NOTE=" ⚠️ mirror value, CNN unreachable"
    fi

    # HTML mode: escape the data-bearing parts, then add formatting tags
    SNAPSHOT_ESC=$(printf '%s\n' "$SNAPSHOT" | html_escape)
    NOTE_ESC=$(printf '%s' "$SCORE_NOTE" | html_escape)

    MESSAGE=$(cat <<EOF
<b><u>📊 Daily Fear &amp; Greed Update</u></b>

📈 Fear &amp; Greed Index: ${SCORE} (${LABEL})${NOTE_ESC}
📅 ${SGT_DATE}, ${SGT_TIME}

📉 Index:
${SNAPSHOT_ESC}
EOF
)

    if send_telegram "$MESSAGE" with_refresh html; then
        log "DAILY-SENT — Daily summary delivered successfully"
        # A --test send doesn't count as today's summary
        if [ "$FORCE_TEST" = false ]; then
            echo "$SGT_DATE" > "$DAILY_STATE_FILE"
        fi
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

Source: ${SOURCE_NAME}
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
