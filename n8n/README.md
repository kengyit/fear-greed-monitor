# n8n Cloud Deployment

Host the Fear & Greed monitor on [n8n Cloud](https://n8n.io) instead of a Mac —
always on, no launchd, no long-polling listener. The same Telegram bot, the
same message templates.

## What's in here

| File | Workflow | Replaces (Mac version) |
|------|----------|------------------------|
| `fear-greed-daily-summary.json` | **Daily Summary & Refresh** — 21:35 SGT schedule **and** 🔄 button / `/refresh` handling in one workflow | daily agent + listener agent |
| `fear-greed-extreme-fear-alert.json` | **Extreme Fear Alert** — every 30 min, 21:00–04:30 SGT window, score < 10, 2-hour cooldown | 30-min alert agent |

Key difference from the Mac build: the refresh button is handled by n8n's
**Telegram Trigger (webhook)** — no polling daemon needed. All data parsing
lives in Code nodes; all HTTP calls are HTTP Request nodes with
continue-on-fail, so a down source renders `n/a` instead of killing the send.
The day-over-day index change and the alert cooldown persist in **workflow
static data** (no files needed).

## Setup (≈10 minutes)

1. **Import both workflows**: n8n → *Workflows* → *⋯* → *Import from File*.

2. **Create the Telegram credential**: *Credentials* → *Add* → *Telegram* →
   paste your bot token (from @BotFather). Then open each workflow and select
   this credential on every Telegram node (`Refresh Trigger`, `Answer
   Callback`, `Send Summary`, `Send Alert`).

3. **Set your chat ID** — replace `REPLACE_WITH_CHAT_ID` in **three places**:
   - *Daily Summary & Refresh* → `Filter Refresh` (Code node, `CHAT_ID` constant)
   - *Daily Summary & Refresh* → `Send Summary` (Chat ID field)
   - *Extreme Fear Alert* → `Send Alert` (Chat ID field)

4. **Check the timezone**: both workflows ship with `Asia/Singapore` in their
   settings. If your n8n instance overrides workflow timezones, confirm in
   *Workflow Settings* that the cron expressions (`35 21 * * *` and
   `*/30 * * * *`) run in SGT.

5. **Activate both workflows** (toggle top-right). Activating the Telegram
   Trigger registers the webhook with Telegram automatically.

6. **Test**: open *Daily Summary & Refresh* → *Execute Workflow* (manual run
   uses the schedule path) → the summary should land in Telegram. Then tap
   🔄 Refresh data on it.

## ⚠️ Migrating from the Mac launchd version

- **Retire the Mac agents first** — in particular the listener. n8n's
  Telegram Trigger registers a **webhook**, and Telegram forbids webhook and
  `getUpdates` polling at the same time: the Mac listener will start failing
  with 409 the moment the n8n workflow is activated (and a running poller can
  likewise prevent the webhook from receiving events). On the Mac:

  ```bash
  launchctl unload ~/Library/LaunchAgents/com.eightday.fear-greed-monitor.plist
  launchctl unload ~/Library/LaunchAgents/com.eightday.fear-greed-daily.plist
  launchctl unload ~/Library/LaunchAgents/com.eightday.fear-greed-listener.plist
  ```

- **The same rule applies to any other app** using this bot token with
  `getUpdates` (e.g. another bot framework): it will conflict with the
  webhook. If the bot is shared, give this monitor a dedicated bot.

- State does **not** migrate: the first scheduled summary seeds a fresh
  day-over-day baseline (that one message shows no delta), and the alert
  cooldown starts empty.

## Notes & quirks

- **Static data caveat**: n8n persists workflow static data only for
  executions of an *active* workflow. Manual test runs read it but their
  writes are discarded — so a manual run never pollutes the 21:35 baseline
  (which is also why refresh taps don't move it: only the schedule-trigger
  path updates `lastScore`).
- **No boot catch-up logic**: the Mac version re-sent a missed 21:35 summary
  on startup; n8n Cloud is always on, so that machinery was dropped.
- **Node versions**: built for current n8n (Schedule Trigger 1.2, HTTP
  Request 4.2, Code 2, Telegram 1.2). If an import warns about a node
  version, open the node and re-confirm its dropdown values.
- **Alert threshold / cooldown / window**: constants at the top of the
  `Evaluate Alert` and `Window Check` Code nodes.
- Data sources are identical to the shell version: CNN's official F&G API
  (mirror fallback, labeled `⚠️ mirror value` when used), Yahoo Finance
  quotes, FRED US monthly series, CNBC Top News RSS.
