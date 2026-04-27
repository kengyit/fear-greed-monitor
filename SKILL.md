---
name: fear-greed-monitor
description: >
  Monitors the CNN/FearGreedChart.com stock market Fear & Greed Index between
  9PM and 4:30AM SGT (US market hours overlap). When the composite score drops
  below 10 (Extreme Fear), sends an alert to Telegram with the full 5-component
  breakdown. Runs as a macOS LaunchAgent cron job every 30 minutes during the
  monitoring window. Use this skill when the user asks about market sentiment,
  Fear & Greed Index status, extreme fear alerts, or wants to check/modify the
  monitoring schedule or threshold.
version: 1.0.0
metadata:
  openclaw:
    emoji: "😱"
    category: "trading"
    homepage: https://github.com/kengyt/fear-greed-monitor
    requires:
      bins:
        - curl
        - jq
---

# Fear & Greed Monitor

## Purpose

You are a market sentiment watchdog. Your job is to periodically check the
stock market Fear & Greed Index (from feargreedchart.com) during US market
hours (9PM–4:30AM SGT) and alert Keng via Telegram when extreme fear is
detected (score < 10).

## Architecture

```
LaunchAgent (every 30 min)
  └── fear_greed_monitor.sh
        ├── Check SGT time window (21:00–04:30)
        ├── GET feargreedchart.com/api/?action=all
        ├── Parse composite score + 5 components via jq
        ├── IF score < 10 → POST Telegram alert
        └── Log result to ~/logs/fear_greed.log
```

## Configuration

All config is at the top of `fear_greed_monitor.sh`:

| Variable | Default | Description |
|----------|---------|-------------|
| `THRESHOLD` | `10` | Alert when score drops below this |
| `TELEGRAM_BOT_TOKEN` | (from config.yaml) | Your Telegram bot token |
| `TELEGRAM_CHAT_ID` | (from config.yaml) | Your Telegram chat ID |
| `LOG_FILE` | `~/logs/fear_greed.log` | Execution log path |
| `WINDOW_START` | `21` | Monitoring starts (SGT hour, 24h) |
| `WINDOW_END_HOUR` | `4` | Monitoring ends (SGT hour) |
| `WINDOW_END_MIN` | `30` | Monitoring ends (SGT minute) |

## Files

- `SKILL.md` — this file (agent reads this)
- `fear_greed_monitor.sh` — main executable script
- `com.eightday.fear-greed-monitor.plist` — macOS LaunchAgent for cron scheduling
- `install.sh` — one-command installer

## Telegram Alert Format

```
🚨 EXTREME FEAR ALERT 🚨

📊 Fear & Greed Index: 7 (Extreme Fear)
🕐 Checked at: 22:30 SGT

📉 Component Breakdown:
  • Market Volatility (VIX): 5/100 (wt: 25%)
  • Market Momentum: 9/100 (wt: 25%)
  • Put/Call Ratio: 8/100 (wt: 20%)
  • Safe Haven Demand: 6/100 (wt: 15%)
  • Junk Bond Appetite: 11/100 (wt: 15%)

⚠️ Index is below 10 — market in extreme fear territory.

Source: feargreedchart.com
```

## Commands (via Telegram to OpenClaw)

- "check fear greed" → run the script immediately, report current score
- "change fear greed threshold to 20" → update THRESHOLD in the script
- "pause fear greed monitor" → unload the LaunchAgent
- "resume fear greed monitor" → reload the LaunchAgent
- "fear greed status" → show last log entry + whether LaunchAgent is loaded

## Installation

```bash
cd ~/.openclaw/workspace/skills/fear-greed-monitor
chmod +x install.sh
./install.sh
```

## Known Gaps

- API has no SLA — feargreedchart.com is free tier, may have downtime
- Score updates once per trading day (not real-time intraday)
- No historical trend tracking yet (future: append to Google Sheet)
