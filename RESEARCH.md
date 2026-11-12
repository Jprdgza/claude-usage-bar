# Phase 0 — Research: lugia19/Claude-Usage-Extension

Source studied: `github.com/lugia19/Claude-Usage-Extension` at commit `d1ede81` (2026-10-15),
manifest version **6.1.4**, plus its `common/` submodule (`lugia19/claude-ext-common` @ `01d77c2`).
Both are **GPL-3.0**. I also skimmed lugia19's `Claude-WebExtension-Launcher` because it is how
that extension runs inside Claude Desktop (see §8, it matters a lot for Phase 1).

Everything below comes from reading the code, not from live traffic. Where the code's own comments
give an observation date, I include it. I captured no live response; Phase 1/3 should save real
samples to `test/fixtures/` before the decoders are finalized.

---

## 1. Architecture of the extension (what we're replicating)

| Layer | Files | Role |
|---|---|---|
| Page world (MAIN, `document_start`) | `injections/request-hook.js`, `injections/usage-sse-watcher.js`, `common/net/*.js` | Chains onto `window.fetch`. Reports which claude.ai requests happen, tees the completion SSE stream, and decodes the "merged experience" Connect-RPC protobuf (`PerformAction`, `StreamTimeline`). |
| Content script (isolated) | `content-components/*.js`, `common/ui/*.js`, `common/claude/page.js` | DOM anchoring, rendering, model-picker reading, in-page tokenizing of the streamed reply. |
| Background (MV3 service worker) | `background.js`, `bg-components/*.js`, `shared/dataclasses.js` | All claude.ai API calls, token math, caching analysis, notifications, persistent storage. |

**For our port:** the page-world and content-script layers collapse into one injected script.
The background's claude.ai calls become same-origin `fetch` from the page. Only the Anthropic API
token counting, Keychain, and notifications move to the Node side.

---

## 2. Every claude.ai endpoint it calls

All are relative to `https://claude.ai`. `{org}` is the `lastActiveOrg` cookie value.

| # | Method + path | Used for | Notes |
|---|---|---|---|
| E1 | `GET /api/organizations/{org}/usage` | Usage bars | See §6 for the full shape. |
| E2 | `GET /api/organizations/{org}/prepaid/credits` | Credit balance | Only fetched when `spend.enabled` or `extra_usage.is_enabled`. Returns `{ amount }` in cents. 403s for Team admins without billing rights (issue #97), so it is optional. |
| E3 | `GET /api/bootstrap/{org}/app_start?statsig_hashing_algorithm=djb2` | Subscription tier + feature flags | ~850 KB. Cached 24 h (tier) and 30 min (flags). |
| E4 | `GET /api/account_profile` | Conversation preferences (user prefs) | Cached 5 min. |
| E5 | `GET /api/organizations/{org}/chat_conversations/{conv}?tree=true&rendering_mode=messages&render_all_tools=true[&consistency=strong]` | The whole message tree | Central to everything per-chat. `tree=false` also exists (flat). |
| E6 | `GET /api/organizations/{org}/projects/{project}/kb/stats` | Project knowledge size | |
| E7 | `GET <file.preview_asset.url>` / `<file.document_asset.url>` (relative, under claude.ai) | Download image/PDF to count exactly | Only with an API key. |
| E8 | `POST /v1/code/sessions/{sessionId}/events` + `GET …/events?limit=10&sort_order=desc` | Ask a workspace-upgraded chat's Claude Code session for its real context size (`get_context_usage` control request) | Headers `anthropic-version: 2023-06-01`, `anthropic-beta: ccr-byoc-2025-07-29`, `anthropic-client-feature: ccr`, `x-organization-uuid`. Must come from the page origin. **Writes to the session's event log permanently**, so it's only sent once per settled turn. |
| E9 | `POST https://api.anthropic.com/v1/messages/count_tokens` | Exact token counts | Only with a user API key; model `claude-opus-5`. |

**Requests it only observes** (to know *when* to recompute; it never calls these itself):

| Pattern | Meaning |
|---|---|
| `POST …/chat_conversations/{conv}/completion` and `…/retry_completion` | Legacy message send. JSON body has `prompt`, `model`, `parent_message_uuid`, `turn_message_uuids`, `attachments`. Response is SSE. |
| `POST /claudeai-rpc/anthropic.bard.api.v1alpha.ConversationService/PerformAction` | "Merged experience" send (binary Connect-RPC protobuf; `send_message` action). |
| `POST /claudeai-rpc/anthropic.bard.api.v1alpha.ConversationService/StreamTimeline` | Merged experience's live timeline; turn end = status leaves `RUNNING/RECOVERING/WAITING_FOR_INPUT` for `IDLE/COMPLETED/ERROR`. Also carries `message_limit`. |
| `GET …/chat_conversations/{conv}` | claude.ai's own post-message tree GET → triggers the "authoritative pass". |
| `…/chat_conversations/{conv}/current_leaf_message_uuid` | Branch switch. |
| `PUT /api/account_profile`, `POST/PATCH/PUT /api/account/settings` | Invalidate prefs/flags caches. |
| `GET /api/settings/billing` | Force tier refresh. |

**Decoding the protobuf** needs `common/net/bard-schema.js` + `net.js` (~1300 lines). The schema
was captured from claude.ai's own descriptors. That's a large, brittle dependency. For v1 I plan to
skip protobuf decoding and treat any `PerformAction`/`StreamTimeline` activity as "something
happened → debounce → refetch E5 with `consistency=strong`." That is good enough to refresh stats.
We lose the provisional (sub-second) estimate on merged accounts, and the overlay will say so.

---

## 3. Response shapes (as the code reads them)

### 3.1 Conversation tree (E5)
```jsonc
{
  "uuid": "...", "model": "claude-opus-5-5" | null,   // null briefly on a brand-new chat
  "project_uuid": "..." | null,
  "settings": { /* per-chat snapshot of flags, e.g. chat_memory_mode: "disabled" */ },
  "workspace_upgraded": true | false,                  // chat moved into a Claude Code sandbox
  "current_leaf_message_uuid": "...",
  "chat_messages": [{
    "uuid": "...", "parent_message_uuid": "..." /* root = 00000000-0000-4000-8000-000000000000 */,
    "sender": "human" | "assistant",
    "created_at": "ISO-8601",
    "content": [ { "type": "text", "text": "..." },
                 { "type": "thinking", "thinking": "..." },          // never actually returned
                 { "type": "tool_use", "name": "...", "input": {...} },
                 { "type": "tool_result", "name": "web_search", "content": [...] } ],
    "attachments": [ { "extracted_content": "..." } ],               // pasted/text files
    "files": [ { "file_uuid": "...", "file_kind": "image" | "document" | "blob",
                 "preview_asset":  { "url": "...", "image_width": n, "image_height": n },
                 "document_asset": { "url": "...", "page_count": n, "token_count": n? } } ],
    "compaction_summary": [ /* content blocks */ ]                  // legacy compaction only
  }]
}
```
A **merged-experience compaction** looks like an assistant message with empty `content` whose parent
is also an assistant message.

### 3.2 Project KB stats (E6)
`{ knowledge_size: <tokens>, use_project_knowledge_search: bool, ... }`. When retrieval (RAG) is
on, `knowledge_size` is **not** counted (set to 0) and the length is marked as an estimate.

### 3.3 Account profile (E4)
`{ conversation_preferences: "<text>" | null, ... }`

### 3.4 Bootstrap (E3) — the fields it reads
```jsonc
{
  "memory_mode": "melange" | ...,                       // "melange" ⇒ memory on
  "account": {
    "memberships": [{ "organization": {
        "uuid": "...", "name": "...",
        "capabilities": ["claude_pro" | "claude_max" | ...],
        "rate_limit_tier": "default_claude_ai" | "default_claude_max_5x" | "default_claude_max_20x",
        "raven_type": null | "..."                        // non-null ⇒ Team
    }}],
    "settings": {
      "enabled_mcp_tools": { "6f616b42-0ed8-571e-823f-ee4aca6b7ce9:show_widget": true },  // inline visuals
      "enabled_saffron_search": bool,                     // past-chat search
      "enabled_bananagrams": bool                         // Drive search
    }
  }
}
```
Tier logic: `raven_type` → team; `claude_max` capability → `max_5x` if `rate_limit_tier` contains
`5x`, else `max_20x`; `claude_pro` → pro; otherwise free.

### 3.5 Completion SSE (observed 2026-08-20)
Event order: `conversation_ready` (new chats) → `message_start{message:{uuid,parent_uuid,model}}` →
`content_block_start/delta/stop`… → `message_delta` → **`message_limit`** → `message_stop`.
No token counts, no cache info, and thinking only as summaries. A refused send (limit hit) returns JSON
`{ error: { message: "<JSON string of message_limit>" } }`.

`message_limit` shape:
```jsonc
{ "type": "within_limit" | "exceeded_limit", "representativeClaim": "five_hour",
  "windows": { "5h": {status, resets_at /*unix s*/, utilization /*0-1*/},
               "7d": {...}, "7d_oi": {...}, "overage": {...} },
  "resolved": { "status": "...", "limit": { "kind": "session", "percent": 98, "resets_at": "ISO", ... },
                "spend": ..., "notice": {...} } }
```
`utilization` can sit at 0.98 while `status = exceeded_limit`, so `status` wins (clamp to 100).

---

## 4. Per-conversation token computation (`ConversationAPI.getInfo`)

All counts are **input-token-equivalents**. The final "cost" is multiplied by a per-model weight
(§5). Order of accumulation:

1. **Fixed system prompt**, a measured constant (2026-10-08, merged-experience prompt):
   `behavior 28,600 + tools 58,500 + skills 5,500 + trailing 2,300 = 94,900`.
2. **Feature sections**, added when the effective setting is on. Effective = account flags (E3)
   overlaid by `conversation.settings`; `chat_memory_mode: "disabled"` forces memory and chat-search off:
   `memory 24,800`, `enabled_saffron_search 3,700`, `inline_visuals 4,200`.
3. **Compaction summary**: legacy uses `compaction_summary` tokenized; merged uses the constant
   `6,000`. Only messages *after* the last compaction boundary are walked.
4. **Files per trunk message.** Only `image`/`document` kinds count, minus "sandboxed" files (below):
   - API key set: download the file (E7) and count it with `count_tokens` (results cached per file_uuid).
   - Otherwise image: `min(1600, ceil(w*h/750))`; document: `document_asset.token_count ??
     2250 * page_count`.
5. **Message text.** Walk the **trunk** (leaf → root via `parent_message_uuid`, reversed):
   - Context view: `text` + `JSON.stringify(tool_use.input)` + nested `tool_result.content`
     (tool results **stay in context**), plus each attachment's `extracted_content`. No thinking.
   - All trunk human texts and assistant texts are counted in one `count_tokens` call (alternating
     roles), or locally as `o200k(text) * 1.4` per message.
6. **Output surcharge**: the reply the last turn paid for is counted again in *output view* (text +
   thinking + tool inputs, no tool results) × `OUTPUT_TOKEN_MULTIPLIER = 4`. This goes to cost
   only, not length.
7. **Project knowledge**: `knowledge_size` from E6 (0 when RAG is on).
8. **User preferences**: `tokens(conversation_preferences) + 2,000` (section overhead) if non-empty.
9. **Workspace-upgraded chats**: if E8 answers, its `totalTokens` *replaces* the estimate. Its
   `apiUsage` gives the real input/cache split. Length is then exact.

**Sandboxed files** (`sandboxedFiles`): once a chat is workspace-upgraded (first sandbox tool use:
`prepare_session, Bash, Read, Write, Edit, Glob, Grep, NotebookEdit`, or a `blob` file), later
documents/blobs and text attachments > 25,000 tokens live in `/mnt/user-data/uploads` and aren't in
context. Files on the turn that forced the upgrade are sandboxed too.

**Length is marked "estimate" (`Length*`)** when any of these hold: a web_search result in history,
Drive search on, memory on (memory files aren't counted), project RAG on, any sandboxed file, or a
merged compaction (constant summary).

**Breakdown by source.** The extension only exposes `length` and `systemPromptTokens`. Our overlay
will keep every bucket from steps 1–9 separately (system, features, preferences, project, files,
history, compaction summary) so the tooltip can show a full breakdown. This is a new feature, not
parity.

**Context windows** (`CONFIG.CONTEXT_WINDOWS`, from support article 8606394 read 2026-10-09):
e.g. `claude-opus-5-5 {chat: 1M, workspace: [1M, compact@967K]}`,
`claude-sonnet-5-5 {chat: 1M, workspace: [500K, 467K]}`. Length turns red at 75 % of the window.

---

## 5. Caching status and cost/estimate logic

**Cache model.** claude.ai prompt caching is assumed to last **1 h** (`TOKEN_CACHING_DURATION_MS`)
and cache reads are treated as **free** (`CACHING_MULTIPLIER = 0`). During extra-usage billing they
cost 10 % of input (`EXTRA_USAGE_CACHING_MULTIPLIER = 0.1`).

**`getCachingInfo` (boundary detection):**
1. Build the trunk, a children map, and the index of the latest compaction. Only humans after the
   compaction can hold an anchor.
2. **Fast path:** if the last trunk assistant is < 1 h old, the cache boundary is the latest
   candidate human. `cachedUntil = max(created_at of that human's assistant children, incl.
   off-trunk regenerations) + 1 h`.
3. **Slow path** (fast path failed): for each off-trunk assistant *leaf* younger than 1 h, walk
   back to the trunk. Require no ≥ 1 h gap between consecutive assistants on that path. The trunk
   human at the junction is an anchor; pick the latest one (ties → later expiry).
4. It computes **two** boundaries: `next` (every human eligible, used for the next message's cost)
   and `now` (excludes the just-sent human when pricing a new message). Without a new message
   they're the same object.

**Cost math.** `cost`, `futureCost`, `uncachedCost`, `uncachedFutureCost` accumulate in parallel.
Cached segments contribute `tokens × 0`, uncached ones `× 1`. Message tokens are added in full, then
the cached-prefix count is subtracted. Project knowledge is "cached" if its size equals the size
recorded at the last send within 1 h. Preferences are cached whenever the convo is (always for
next).

**Shown "Cost"** = `round((isCurrentlyCached ? futureCost : uncachedFutureCost) × modelWeight)`,
in "credits". `isCurrentlyCached` is true only if `cachedUntil > now` **and** the picker's model
equals the conversation's model **and** the effort label (`aria-label` text after `·`) is
unchanged. An unreadable picker means "not cached" (it errs against promising a discount).

**Model weights** (input $/MTok): fable-5/5.1 = 10, opus-5 = 5, opus-5-5 = 4, sonnet-5/5.5 = 2,
haiku-5-5 = 0.1 (0.5 above 100K tokens), sonnet-4-6 = 3, opus-4-x = 5, haiku-4-5 = 1. The family
fallback is Fable 10 / Opus 5 / Sonnet 3 / Haiku 1, and the unknown fallback is 5.

**"Messages left"** = for each active limit: `((100 − pct)/100 × ESTIMATED_CAP[tier][limit]) / cost`;
take the minimum. The session cap is divided by 1.5 during "peak hours" (weekdays 12:00–18:00 UTC;
note the comment says 1–7 pm). Caps are self-described "napkin math": max_5x session 15 M, weekly
150 M, sonnetWeekly 90 M, and the other tiers are scaled ×1/×1.25/×5/×20 from these. Pro/Team have
no explicit caps, so they are derived. Shown capped at "1000+", red below 15. Extra usage converts
cost to dollars: `cost × weight / 1e6`.

**Our "cost relative to the 5-hour budget"** = `nextCost / ESTIMATED_CAP[tier].session × 100 %`.
This is clearly labelled as an estimate because the caps are guesses.

**Provisional fast path**: when the SSE stream ends, the reply is tokenized in-page and added to the
cached ConversationData. That provisional estimate is served for up to 2 min until the
authoritative refetch lands.

---

## 6. `/api/organizations/{org}/usage` (E1)

Two formats coexist, and the decoder must handle both.

**Old (top-level windows):**
```jsonc
{ "five_hour":        { "utilization": 37, "resets_at": "ISO" } | null,
  "seven_day":        { "utilization": 12, "resets_at": "ISO" } | null,
  "seven_day_sonnet": {...} | null,   // Max only
  "seven_day_opus":   {...} | null,   // Max only
  "extra_usage": { "is_enabled": true, "monthly_limit": 5000, "used_credits": 1234 } | null }  // cents
```
**New (authoritative when `limits` is a non-empty array):**
```jsonc
{ "limits": [
    { "kind": "session",       "percent": 37, "resets_at": "ISO", "group": ..., "severity": ..., "is_active": ... },
    { "kind": "weekly_all",    "percent": 12, "resets_at": "ISO" },
    { "kind": "weekly_scoped", "percent": 40, "resets_at": "ISO",
      "scope": { "model": { "display_name": "Fable" | "Sonnet" | "Opus" } } } ],
  "spend": { "enabled": true,
             "limit": { "amount_minor": 5000 } /* or cap.money.amount_minor */,
             "used":  { "amount_minor": 1234 },
             "balance": null /* NOT the credit balance, use E2 */ } }
```
- `utilization`/`percent` are **0–100** here (unlike the SSE's 0–1).
- The extension maps only `session`, `weekly_all`, and `weekly_scoped{Fable,Sonnet,Opus}`. Any other
  `kind` or scope is dropped with a console warning. **Our decoder will render every entry
  generically** (label from `kind` + `scope.model.display_name`), so new windows show up without a
  code change, as you asked.
- **Free plan** (verified by the author 2026-08-22): HTTP 200 with every field null and `limits: []`.
  The extension falls back to the last `message_limit` seen in the completion stream and persists it
  until each window's `resets_at`.
- Non-2xx or HTML (Cloudflare) responses are errors, not "empty". The extension shows "Usage data
  unavailable" and keeps the previous figures.

---

## 7. Injected UI and DOM anchors

The extension adds three UI pieces, styled with claude.ai's own Tailwind classes plus `ut-*` classes.
There is no Shadow DOM, which we will change.

| Piece | Content | Anchor (desktop app layout, checked first) |
|---|---|---|
| **Sidebar "Usage" section** | One bar per active limit: label, %, reset countdown (`⏱ 2h 14m`, `3d 4h`, "Resetting..."), and a tooltip with estimated tokens (`{used}/{cap} tokens`). A weekly marker sits on the session bar. There is an extra-usage $ bar and a collapse toggle. | `.dframe-sidebar-body .dframe-nav-scroll`, inserted before `:scope > .dframe-recents-by-mode` |
| **Title line** under the chat title | `Length: N tokens \| Max: 1M \| Cost: N credits \| Cached for: 42m` | `[data-testid="session-title-split"], [data-testid="chat-title-split"]` → `.closest('.font-base-bold, .font-base')` (desktop) and inside `[data-testid="chat-header"]`. It falls back to a strip hung from `.dframe-header` when there's no room. |
| **Stat line** under the composer | `Session: 37% [bar] … PEAK  Reset in: 2h 14m  Messages left: 42` | `[data-testid="chat-input"]` (or `code-prompt-input`) → `.closest('.bg-surface-3 > .relative.w-full.min-w-0')`, insert after. Legacy fallback: `[data-testid="model-selector-dropdown"]` → `.closest('.flex.w-full.items-center')`. |

Other selectors: model picker `[data-testid="model-selector-dropdown"]` (read `aria-label`, e.g.
"Model: Opus 5.5 · High"). Desktop detection: `aside.dframe-sidebar`. Notification cards mount on
`.dframe-content-inner`. Page/IDs come from the URL (`/chat/{uuid}`, `/project/{uuid}`,
`?incognito` + `sessionStorage.incognito_temporary_conversation_uuid`) and the `lastActiveOrg` cookie.

**Re-attachment**: a `requestAnimationFrame`/interval update loop checks the anchor on every tick
and calls `mountToAnchor`, which re-inserts the element if React moved or removed it. Conversation
change is detected by polling `location` in the same loop. There is no history-API hook.

**Colors**: blue `#2c84db` normally, red `#de2929` at ≥ 90 %, green `#22c55e` for cached and
"Resetting". You asked for green < 50 / yellow 50–80 / red > 80, so we will use your thresholds.

**No pace projection exists** in the extension. Ours will be new:
`projected% = pct × windowLength / elapsed`, where `elapsed = windowLength − (resets_at − now)`.
It will be allowed to exceed 100 %. The 5 h and 7 d window lengths are inferred from `kind`, and
unknown kinds get no projection.

---

## 8. Polling, notifications, privacy

- **Polling**: there is no fixed usage poll. It refreshes on each message (authoritative pass), on a
  **3-minute heartbeat alarm**, on window focus (Electron), and when a displayed limit's reset time
  passes (backoff up to 5 min). Your spec says "at most once a minute, backoff, pause when hidden or
  asleep", which is stricter, so we'll do that.
- **Reset notification**: when a limit is ≥ threshold (default 100 %), its `resets_at` is stored. A
  heartbeat after that time refetches, and notifies only if session usage is back at 0 % (to avoid
  notifying someone already chatting). Entries older than 10 min are dropped. The threshold warnings
  you want (80 %/95 %) are new.
- **Firebase**: README and PRIVACY.md still mention Firebase sync of org ID and usage, **but the
  current code has no Firebase at all** (grep finds nothing). The docs are stale. Either way, we
  include none.
- **API key**: stored in `browser.storage.local` and sent from the background with
  `anthropic-dangerous-direct-browser-access`. In ours, the key stays in the Node process and
  Keychain.

### How lugia19 runs it inside Claude Desktop — important for Phase 1
`Claude-WebExtension-Launcher` builds a **modified copy** of Claude.app: patched `app.asar`, a patched
`ElectronAsarIntegrity` hash in Info.plist, ad-hoc re-signing, and `version.dll` on Windows. Its
`wrapper.js` says plainly:

> "Claude refuses to start when a debugging switch is on the command line, unless its E2E token
> check passes."

It removes `--remote-debugging-port/pipe` from `process.argv` before Claude's own check runs.
**That suggests stock Claude Desktop rejects both flags we plan to test in Phase 1**, and the only
known way around it is patching the app, which you've ruled out. I haven't verified this against
your installed version yet; that's what Phase 1 is for. If it holds, the verdict is **CDP BLOCKED**
and we go to the SwiftUI fallback.

---

## 9. What carries over to our build

| Item | Plan |
|---|---|
| Usage decoding (both formats, credits, free-plan SSE fallback) | Port. It moves into one `endpoints.config` plus a decoder that renders unknown limit kinds generically. |
| Tree walk, sandboxed files, compaction, caching boundaries, cost and future cost | Port the logic (GPL-3.0, so our repo must be GPL-3.0 too if we copy code; I'll attribute it). |
| Constants (system prompt sizes, weights, context windows, caps) | Move to config. These are estimates that go stale with each claude.ai change. |
| Merged-experience protobuf decoding | **Skip in v1.** Treat as a refresh trigger only. |
| E8 (Claude Code session context) | **Skip by default.** It writes to the session log, so it's opt-in at most. Workspace chats will be labelled "approx". |
| Local tokenizer | o200k_base × 1.4, via the `gpt-tokenizer` npm package (no 1 MB inline blob). |
| Not countable | Thinking tokens (never exposed), web-search page text, Research, memory files, Drive search, project RAG retrievals, merged compaction size, and the system-prompt constants themselves. These get labels in the UI. |
