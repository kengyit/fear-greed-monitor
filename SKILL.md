---
name: fear-greed-monitor
description: >
  Monitors the CNN/FearGreedChart.com stock market Fear & Greed Index between
  9PM and 4:30AM SGT (US market hours overlap). When the composite score drops
  below 10 (Extreme Fear), sends an alert to Telegram with the full 5-component
  breakdown. Also sends a daily Telegram summary at 9:35 PM SGT regardless of
  the score. Runs as two macOS LaunchAgents that auto-restart on every
  boot/login (with catch-up for a daily summary missed while powered off).
  Use this skill when the user asks about market sentiment, Fear & Greed Index
  status, extreme fear alerts, the daily summary, or wants to check/modify the
  monitoring schedule or threshold.
version: 1.1.0
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

You are a market sentiment watchdog. Your job is to (1) periodically check the
stock market Fear & Greed Index (from feargreedchart.com) during US market
hours (9PM–4:30AM SGT) and alert Keng via Telegram when extreme fear is
detected (score < 10), and (2) send Keng a daily Telegram summary of the
current score every day at 9:35 PM SGT, whatever the value is.

## Architecture

```
LaunchAgent ① alert (every 30 min, RunAtLoad on boot/login)
  └── fear_greed_monitor.sh
        ├── Check SGT time window (21:00–04:30)
        ├── GET feargreedchart.com/api/?action=all
        ├── Parse composite score + 5 components via jq
        ├── IF score < 10 → POST Telegram alert
        └── Log result to ~/logs/fear_greed.log

LaunchAgent ② daily (9:35 PM daily, RunAtLoad on boot/login)
  └── fear_greed_monitor.sh --daily
        ├── Skip if before 21:35 SGT or already sent today
        │   (marker: ~/.fear_greed_daily_last_sent — reboot-safe)
        ├── GET + parse F&G score (same pipeline)
        ├── Fetch market snapshot (all best-effort, "n/a" on failure):
        │   S&P500 / Nasdaq / HSI / Bitcoin — Yahoo Finance
        │   US Fed rate, CPI YoY, unemployment — FRED CSV (no key,
        │   all United States monthly series)
        │   Top-3 headlines — CNBC Top News RSS
        ├── POST Telegram daily summary (unconditional on score)
        └── Log result to ~/logs/fear_greed.log
```

Both agents live in `~/Library/LaunchAgents`, so they reload automatically
whenever the Mac is restarted; `RunAtLoad` also fires an immediate run at
load, which catches up a 21:35 send missed while the machine was powered off.

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
| `DAILY_HOUR` | `21` | Daily summary send hour (SGT) |
| `DAILY_MIN` | `35` | Daily summary send minute (SGT) |
| `DAILY_STATE_FILE` | `~/.fear_greed_daily_last_sent` | Once-per-day marker |

## Files

- `SKILL.md` — this file (agent reads this)
- `fear_greed_monitor.sh` — main executable script (alert + `--daily` modes)
- `com.eightday.fear-greed-monitor.plist` — LaunchAgent: alert mode, every 30 min
- `com.eightday.fear-greed-daily.plist` — LaunchAgent: daily summary at 21:35 SGT
- `install.sh` — one-command installer (installs both agents)

## Telegram Daily Summary Format (21:35 SGT, unconditional)

```
📊 Daily Fear & Greed Update

📈 Fear & Greed Index: 42 (Neutral)
📅 2026-07-29, 21:35 SGT

📉 Index:
  • S&P500: 6,365 (down: 0.3%)
  • Nasdaq: 21,098 (up: 0.2%)
  • HSI: 25,524 (up: 0.7%)
  • Bitcoin: 118,024 (down: 1.2%)
  • Interest Rate: 4.25% (last: 4.33% (as of 1/6/2026))
  • CPI: 2.6% (last: 2.4% (as of 1/6/2026))
  • Unemployment Rate: 4.2% (last: 4.1% (as of 1/6/2026))
  • Top 3 breaking news:
      • China unveils new chip breakthrough, rattling US tech stocks
      • Fed holds rates steady as inflation cools & markets rally
      • Bitcoin slips below $120K after record ETF inflows pause
```

## Telegram Alert Format (score < 10 only)

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
