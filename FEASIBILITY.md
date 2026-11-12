# Phase 1 — Feasibility: can stock Claude Desktop be driven over CDP?

**Verdict: CDP BLOCKED.**

Tested 2026-11-04 on macOS 27.2 (26B123), Node v26.11.1. Nothing inside `/Applications/Claude.app`
was modified. All inspection of the app was read-only.

---

## 1. Version and Electron fuses

```console
$ defaults read /Applications/Claude.app/Contents/Info.plist CFBundleShortVersionString
4.16336.0
$ strings -a ".../Electron Framework.framework/Electron Framework" | grep -m1 'Chrome/.* Electron'
Chrome/152.0.7977.167 Electron/44.9.3

$ npx @electron/fuses read --app /Applications/Claude.app
Analyzing app: Claude.app
Fuse Version: v1
  RunAsNode is Disabled
  EnableCookieEncryption is Enabled
  EnableNodeOptionsEnvironmentVariable is Disabled
  EnableNodeCliInspectArguments is Disabled
  EnableEmbeddedAsarIntegrityValidation is Enabled
  OnlyLoadAppFromAsar is Enabled
  LoadBrowserProcessSpecificV8Snapshot is Disabled
  GrantFileProtocolExtraPrivileges is Enabled
  WasmTrapHandlers is Enabled
```

What these mean for debugging:
- `EnableNodeCliInspectArguments: Disabled`: `--inspect` / `--inspect-brk` on the **main (Node)
  process** are ignored. This fuse does **not** govern Chromium's `--remote-debugging-*` switches.
- `RunAsNode: Disabled`, `EnableNodeOptionsEnvironmentVariable: Disabled`: no
  `ELECTRON_RUN_AS_NODE` and no `NODE_OPTIONS=--inspect` path.
- `EnableEmbeddedAsarIntegrityValidation` + `OnlyLoadAppFromAsar: Enabled`: any edit to
  `app.asar` would fail the integrity check unless Info.plist was edited and the app re-signed.
  You've ruled that out.

So on fuses alone, CDP looks possible. The block comes from the app's own code (§3).

---

## 2. Launch tests

### Why the tests used an isolated instance instead of quitting Claude
This Claude Code session runs as a child process of Claude Desktop (`Claude.app` PID 80443 →
`disclaimer` → `claude`). Quitting Claude would have killed the session mid-test, before any result
was recorded. So each test launched a **second, isolated instance**:
`--user-data-dir=<scratch dir>`, which gives it a separate profile and its own single-instance lock.
Only the process group the probe started was killed afterwards. Your running app, login, and
data were not touched.

The refusal check (§3) runs at the top of the main process, before the single-instance lock or any
window creation. It only reads `process.argv`. A fully-quit-then-relaunch test goes through the
same code path with the same argv, so the result carries over. The exact commands for a full-quit
re-check are in §5 if you want that confirmation yourself.

The probe script is `tools/cdp-probe.mjs` (Node parent that spawns the binary and owns fds 3/4 for the
pipe transport).

### 2a. `--remote-debugging-pipe` (preferred: no network port)
The spec said `open -a Claude --args --remote-debugging-pipe`. That form can't work: `open` hands the
launch to LaunchServices, so the Node parent's fds 3/4 never reach Claude (and if Claude is already
running, `open` just activates it and drops the args). The test therefore spawned the binary
directly from Node with `stdio: [ignore, pipe, pipe, pipe, pipe]`:

```console
[+0.0s] spawn /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=…/udd-pipe --remote-debugging-pipe
  [stderr] Claude: refusing to start — a debugging or network-override switch is present on the command line.
[+0.5s] child exited 1 null
[+2.5s] no pipe reply yet
[+2.5s] RESULT {"mode":"pipe","port":null,"exited":{"code":1,"sig":null}}
```

### 2b. `--remote-debugging-port` bound to 127.0.0.1
```console
[+0.0s] spawn /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=…/udd-port --remote-debugging-port=47690 --remote-address=127.0.0.1
  [stderr] Claude: refusing to start — a debugging or network-override switch is present on the command line.
[+0.2s] child exited 1 null
[+2.0s] GET /json/version -> ECONNREFUSED
[+2.0s] RESULT {"mode":"port","port":47690,"exited":{"code":1,"sig":null}}
```
(`curl http://127.0.0.1:47690/json` gives the same answer: connection refused, because nothing is
listening.)

### Control: same isolated launch, no debugging switch
```console
$ /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=…/udd-ctrl &
# 8 s later the process (pid 92000) is still alive, logging normal startup warnings
# (MaxListenersExceededWarning …); killed afterwards.
```
This shows the refusal comes from the debugging switch, not from `--user-data-dir` or running a
second instance.

### Steps 3–4 (list targets, `Runtime.evaluate("location.href")`)
**Not reachable.** No CDP endpoint ever came up, so there were no targets to list or evaluate in.

---

## 3. Where the block lives (read-only inspection of `app.asar`)

The bundled main-process code has a denylist of command-line switches:

```js
var t6=["remote-debugging-port","remote-debugging-pipe","ignore-certificate-errors",
        "host-resolver-rules","host-rules","disable-web-security","log-net-log",
        "net-log-capture-mode","ssl-key-log-file","renderer-cmd-prefix","utility-cmd-prefix",
        "gpu-launcher","zygote-cmd-prefix","ppapi-plugin-launcher","nacl-loader-cmd-prefix", …]
```

And this runs near the top of startup:

```js
if (r6(process.argv) && !f6()) {
  fs.writeSync(2, "Claude: refusing to start — a debugging or network-override switch is present on the command line.\n");
  process.exit(1);
}
```

`r6` checks argv against the list. `f6` is an internal exemption; per lugia19's launcher comments it
is an E2E/test-token check. Getting past it would mean patching the app or forging that token, so I
didn't investigate it further.

This matches what lugia19's `Claude-WebExtension-Launcher` documents: it only gets CDP by running a
patched, re-signed copy of the app that strips these switches from `argv` before this check runs.

**Other runtime routes are also closed by the fuses above:** `--inspect` (fuse off), `NODE_OPTIONS`
(fuse off), `ELECTRON_RUN_AS_NODE` (fuse off), and `app.asar` edits (integrity check plus your rule).
Injecting via a dylib or `DYLD_INSERT_LIBRARIES` is excluded by your rules, and hardened runtime
blocks it anyway.

---

## 4. Consequence

Per the plan, **Phase 2 (CDP launcher/injector) is cancelled** and work moves to the **Fallback:
native SwiftUI MenuBarExtra app**. It talks to the claude.ai endpoints documented in RESEARCH.md
using its own session (sessionKey captured from an embedded WKWebView login and stored in
Keychain). It doesn't touch Claude Desktop at all.

What this costs compared with the in-page overlay:
- **No in-chat UI.** Stats live in the menu bar and a popover, not next to the composer.
- **No live per-message hooks.** The app can't see sends or the completion stream. Per-chat stats
  will come from polling recent conversations (`chat_conversations` list plus each tree), not from
  "the chat you're looking at right now". There's no picker reading either, so the "cached" claim
  can only compare against the conversation's own model.
- **A second login session.** The menu-bar app logs in separately (its own sessionKey). That
  session shows up in claude.ai's session list and expires on its own schedule.

The usage bars, reset countdowns, pace, notifications, and per-conversation token and caching math
(RESEARCH.md §4–5) all carry over unchanged.

---

## 5. Re-running these checks (for the "after every Claude update" rule)

Non-destructive. Nothing gets quit, and it works while Claude is running:

```bash
defaults read /Applications/Claude.app/Contents/Info.plist CFBundleShortVersionString
npx @electron/fuses read --app /Applications/Claude.app
D=$(mktemp -d); /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir="$D" --remote-debugging-port=0 --remote-address=127.0.0.1; echo "exit=$?"
# exit=1 plus the "refusing to start" line = still blocked. If it stays running instead,
# CDP may be open: kill that instance and tell me.
```

Full-quit confirmation (quits Claude Desktop, which ends any Claude Code session running in it):

```bash
osascript -e 'quit app "Claude"'; sleep 3
/Applications/Claude.app/Contents/MacOS/Claude --remote-debugging-port=9222 --remote-address=127.0.0.1; echo "exit=$?"
curl -s http://127.0.0.1:9222/json
open -a Claude   # back to stock
```
