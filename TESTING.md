# Manual test checklist

Run this after every Claude Desktop update, after claude.ai looks different, or when a number in
the app looks wrong. Takes about 10 minutes. Record the date, Claude Desktop version and app
commit at the top of your notes.

## 0. Automated
- [ ] `cd macos && swift test`: all tests pass.
- [ ] `scripts/bundle.sh --install` succeeds and ends with "valid on disk".

## 1. Claude Desktop / CDP status
- [ ] Settings → Claude Desktop → **Check now** says "Still blocked (as expected)."
      If it says Claude may accept debugging now, re-run FEASIBILITY.md §5 by hand and revisit the overlay plan.
- [ ] Optional, by hand: `npx @electron/fuses read --app /Applications/Claude.app`. Compare with FEASIBILITY.md §1.

## 2. Login
- [ ] Settings → Account → Log out, then log in again from the popover. The login window closes by itself.
- [ ] `security find-generic-password -s local.claude-usage-bar -a sessionKey` finds the item (don't print it with `-w`).
- [ ] Quit and relaunch: still logged in, no login window.

## 3. Usage windows (compare with claude.ai → Settings → Usage)
- [ ] Every limit claude.ai shows appears in the popover with the same percentage (±1).
- [ ] Reset countdowns match claude.ai's reset times.
- [ ] Menu-bar dot color matches the 5-hour %: green < 50, yellow 50–80, red > 80.
- [ ] Pace: early in a window the row shows "no pace" or nothing; later it shows a projection. It can exceed 100 %.
- [ ] Extra usage (if enabled) matches the dollars on claude.ai.
- [ ] Compare `~/Library/Application Support/ClaudeUsageBar/samples/usage-latest.json` (kept automatically) with
      `macos/Tests/UsageCoreTests/Fixtures/usage_real_2026-11-05_pro.json`. If the shape changed, add the new file as
      a fixture plus a test like `testRealProResponse`.
- [ ] The "Weekly by product" line matches claude.ai's usage page split, if claude.ai shows one.
- [ ] The debug log has no "Usage keys not understood" or "no windows on a paid plan" lines.
      If it does, the format changed: update the config or decoder.

## 4. Per-chat stats
- [ ] The recent chats listed match the most recent ones in Claude (same names, same order).
- [ ] Send a message in one, wait for the next refresh (or click ↻): its length goes up and it shows "cached ~59m" in green.
- [ ] Breakdown: the system prompt is ~95K; project knowledge appears only for chats in a project.
- [ ] A chat with an image or PDF shows a Files line.
- [ ] Without an API key the header says "approx" and lengths have `*`. With a key it says "counted via API".
- [ ] If any chat fails, the debug log says why: a 404 or HTML response means an endpoint moved, so update `endpoints.json`.

## 4b. Pace, history, Claude Code, shortcut
- [ ] The popover's pace line matches the windows' "pace" values and turns orange when a limit would be hit before reset.
- [ ] History → History shows a line per limit after a few refreshes; `history.jsonl` grows by a line per change.
- [ ] History → Claude Code: project names match your folders; tokens for this week match
      a quick independent total of the `usage` fields in `~/.claude/projects/**/*.jsonl`. Popover shows the top 3.
- [ ] ⌥⌘U opens the popover (or Settings if macOS internals changed); turning the toggle off disables it.

## 4c. Scheduled messages
- [ ] Queue one "after the 5-hour limit resets": the time shown is the reset + 1 minute.
- [ ] Cancel removes the keep-awake assertion when nothing else is queued.

## 4d. Efficiency, peak hours, Claude Code scheduling, lid mode
- [ ] After a few days of use, Efficiency shows bars; clicking one shows tokens, % of the limit and the peak-hour share.
      Grey bands line up with weekdays 12:00–18:00 UTC in your time.
- [ ] During peak hours the popover shows the "Peak hours now" line.
- [ ] Schedule → Claude Code: projects and session titles match Claude Code. Queue "Reply with just OK" to a new session
      in a test project with Send now: it finishes, and `claude --resume` shows the session.
- [ ] While any Claude Code session works, `pmset -g assertions` shows "Claude Code is working"; 3 minutes after it stops it's gone.
- [ ] Lid mode (after Set up…): while Claude Code works, `pmset -g | grep SleepDisabled` shows 1; closing the lid keeps
      the task running. After it goes idle, or after quitting the app, SleepDisabled is 0.

## 5. Notifications
- [ ] Settings shows no "macOS is blocking notifications" warning (or fix it with the button).
- [ ] Temporarily set the thresholds to something just below the current 5-hour % (e.g. `1`): one warning
      arrives within a refresh, and no repeat on the next refresh. Restore `80, 95`.
- [ ] With "notify when the 5-hour limit resets" on and "only if I reached a warning" off, the debug log
      shows "Scheduled reset notification for HH:MM" matching the reset time.

## 6. Politeness / lifecycle
- [ ] The debug log shows refreshes no more often than the interval (60 s minimum).
- [ ] Lock the screen for a minute: the log shows "Polling paused: screen locked", then "resumed".
- [ ] Turn off Wi-Fi: the error shows in the popover and retries back off (60 → 120 → 240 s …, cap 15 min).

## 7. Network allowlist
- [ ] Optional: watch the app in Little Snitch, LuLu or `nettop -p <pid>`. The only hosts are claude.ai,
      api.anthropic.com (with a key), and Cloudflare/claude.ai assets in the login window.
