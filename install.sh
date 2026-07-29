#!/bin/bash
# ============================================================
# install.sh — Fear & Greed Monitor Installer
# Installs the monitoring script as a macOS LaunchAgent
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_NAME="com.eightday.fear-greed-monitor.plist"
DAILY_PLIST_NAME="com.eightday.fear-greed-daily.plist"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"

echo ""
echo "😱 Fear & Greed Monitor — Installer"
echo "============================================="
echo ""

# ─── 1. Check dependencies ─────────────────────────────────
echo "📦 Checking dependencies..."

if ! command -v jq &> /dev/null; then
    echo "   ⚠️  jq not found. Installing via Homebrew..."
    if command -v brew &> /dev/null; then
        brew install jq
    else
        echo "   ❌ Homebrew not found. Install jq manually: https://jqlang.github.io/jq/download/"
        exit 1
    fi
else
    echo "   ✅ jq $(jq --version 2>/dev/null || echo 'found')"
fi

if ! command -v curl &> /dev/null; then
    echo "   ❌ curl not found. Please install curl."
    exit 1
else
    echo "   ✅ curl found"
fi

# ─── 2. Check .env configuration ───────────────────────────
echo ""
echo "🔑 Checking configuration..."

if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "   ⚠️  No .env file found."
    echo "   Copy the template and fill in your credentials:"
    echo ""
    echo "     cp .env.example .env"
    echo "     nano .env"
    echo ""
    read -p "   Continue without .env? (y/n): " CONTINUE
    if [ "$CONTINUE" != "y" ]; then
        echo "   Exiting. Create .env and re-run."
        exit 1
    fi
else
    echo "   ✅ .env file found"

    # Validate required vars
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/.env"
    if [ -z "${FGI_TELEGRAM_BOT_TOKEN:-}" ] || [ "$FGI_TELEGRAM_BOT_TOKEN" = "your-telegram-bot-token-here" ]; then
        echo "   ⚠️  FGI_TELEGRAM_BOT_TOKEN not configured in .env"
    else
        echo "   ✅ Telegram bot token configured"
    fi
    if [ -z "${FGI_TELEGRAM_CHAT_ID:-}" ] || [ "$FGI_TELEGRAM_CHAT_ID" = "your-telegram-chat-id-here" ]; then
        echo "   ⚠️  FGI_TELEGRAM_CHAT_ID not configured in .env"
    else
        echo "   ✅ Telegram chat ID configured"
    fi
fi

# ─── 3. Create log directory ───────────────────────────────
echo ""
echo "📁 Setting up..."
mkdir -p "$HOME/logs"
echo "   ✅ Log directory: $HOME/logs"

chmod +x "$SCRIPT_DIR/fear_greed_monitor.sh"
echo "   ✅ Script is executable"

# ─── 4. Test API connectivity ──────────────────────────────
echo ""
echo "🌐 Testing API connectivity..."
TEST_SCORE=$(curl -s --max-time 10 "$API_URL" 2>/dev/null | jq -r '.score.score // empty' 2>/dev/null || true)

if [ -n "$TEST_SCORE" ]; then
    echo "   ✅ API reachable — current score: $TEST_SCORE"
else
    echo "   ⚠️  API unreachable (may be temporarily down). Script will retry on each run."
fi

# ─── 5. Install LaunchAgents ───────────────────────────────
echo ""
echo "⏰ Installing LaunchAgents..."

mkdir -p "$LAUNCH_AGENTS"

SCRIPT_PATH="$SCRIPT_DIR/fear_greed_monitor.sh"

for PLIST in "$PLIST_NAME" "$DAILY_PLIST_NAME"; do
    # Unload existing if present
    launchctl unload "$LAUNCH_AGENTS/$PLIST" 2>/dev/null || true

    # Generate plist with correct absolute path
    sed "s|/PATH/TO/fear-greed-monitor/fear_greed_monitor.sh|$SCRIPT_PATH|g" \
        "$SCRIPT_DIR/$PLIST" > "$LAUNCH_AGENTS/$PLIST"

    launchctl load -w "$LAUNCH_AGENTS/$PLIST"
    echo "   ✅ LaunchAgent loaded: $PLIST"
done

# ─── 6. Summary ────────────────────────────────────────────
echo ""
echo "============================================="
echo "✅ Installation complete!"
echo ""
echo "   Alert mode:  Every 30 min, 9:00 PM – 4:30 AM SGT, score < ${FGI_THRESHOLD:-10}"
echo "   Daily mode:  Every day at ${FGI_DAILY_HOUR:-21}:$(printf '%02d' "${FGI_DAILY_MIN:-35}") SGT, regardless of score"
echo "   Auto-start:  Both agents reload and run at every boot/login"
echo "   Alert:       Telegram push notification"
echo "   Logs:        ${FGI_LOG_FILE:-$HOME/logs/fear_greed.log}"
echo ""
echo "   Commands:"
echo "   • Test alert: bash $SCRIPT_DIR/fear_greed_monitor.sh"
echo "   • Test daily: bash $SCRIPT_DIR/fear_greed_monitor.sh --daily"
echo "   • View logs:  tail -20 ${FGI_LOG_FILE:-$HOME/logs/fear_greed.log}"
echo "   • Pause:      launchctl unload ~/Library/LaunchAgents/$PLIST_NAME"
echo "                 launchctl unload ~/Library/LaunchAgents/$DAILY_PLIST_NAME"
echo "   • Resume:     launchctl load -w ~/Library/LaunchAgents/$PLIST_NAME"
echo "                 launchctl load -w ~/Library/LaunchAgents/$DAILY_PLIST_NAME"
echo ""
