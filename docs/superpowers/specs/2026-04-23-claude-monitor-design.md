# Claude Monitor — Design

**Date:** 2026-04-23
**Status:** Design approved, ready for implementation planning
**Platform:** macOS 14+, SwiftUI (native), Terminal.app only

## 1. Purpose

A macOS app that shows the live state of every Claude Code CLI session running on this machine as a small grid of colored tiles on your aux monitor. Each session registers via Claude Code hooks when it starts and reports transitions as they happen. Clicking a tile focuses the Terminal.app tab hosting that session.

The goal is an at-a-glance "who's waiting on me?" dashboard you can leave in your peripheral vision.

## 2. User experience

### 2.1 States

Each session is in exactly one of four states:

| State | Color | Meaning |
|---|---|---|
| `working` | blue `#3B82F6` | Between `UserPromptSubmit` and `Stop` — Claude is doing work |
| `waiting` | amber `#F59E0B` | After `Stop` — Claude finished, ball is in your court |
| `needsYou` | red `#EF4444` | `Notification` fired — Claude is blocked (permission prompt) |
| `finished` | grey `#6B7280` | `SessionEnd` — session closed, tile auto-removes after 10s |

### 2.2 Tile

Fixed `160×80 pt`. Contents:

- **Top row:** project name (basename of `cwd`), single line, truncated. Small state dot on the right.
- **Middle row:** state word + elapsed time in current state — e.g. `Working · 0:42`. Tabular numerals.
- **Bottom area:** up to 3 lines of the most recent `prompt_preview` (first 120 chars of last `UserPromptSubmit`). Empty if none yet. Sticks between prompts.

Whole tile is the click target.

### 2.3 Grid layout

Vertical-first flow. Fills column 1 top-to-bottom, then wraps to column 2, etc.

- `columnHeight = floor((windowHeight - padding) / (80 + 8))` tiles per column.
- 8 pt gutters.
- Implemented as a custom SwiftUI `Layout` (not `LazyVGrid`, which is row-major).
- Resizing the window reflows immediately.

### 2.4 Order

Insertion order. Tiles never auto-jump when their state changes. User can drag to reorder; the manual order persists in UserDefaults keyed by `session_id`. New sessions append to the end. Finished sessions fall out when their 10s removal timer fires.

### 2.5 Flash animation

Flash = opacity pulse 100%→70%→100%→70%→100% over ~600 ms (2 pulses). Fires on:

- Any transition **into** `waiting` or `needsYou` (catches the eye when the ball lands in your court).
- `needsYou → working` (lets you see the red→blue resolve when a permission request clears).

No flash on `finished` or on `SessionStart → waiting` (the tile appearing is signal enough).

### 2.6 Menu bar

`NSStatusItem` with a small circle glyph:

- Grey when no sessions.
- Blue when any `working`, none `waiting` or `needsYou`.
- Amber when any `waiting`, none `needsYou`.
- **Red with badge count** when any `needsYou` (count = number of red tiles).

Left click toggles the dashboard window. Right click menu: *Open Dashboard*, *Settings…*, *Quit*.

### 2.7 Window behavior

Standard `NSWindow` with a title bar (no toolbar). Remembers frame in UserDefaults and restores on launch. Normal window level — the user places it on their aux monitor, macOS Spaces handles the rest. Closing the window hides it; the app keeps running in the menu bar. `Cmd+1` reopens.

### 2.8 Onboarding

On first launch, a sheet: *"Install Claude Code hooks into the following config directories?"* with an auto-discovered checklist (see §4.5). Buttons: *Install selected*, *Show me the snippet* (for manual paste), *Skip*. Without hooks installed, the dashboard shows empty-state copy pointing to Settings.

## 3. Architecture

Small units, each with one responsibility, communicating through typed interfaces.

### 3.1 Components

- **HookScript** — `~/.claude-monitor/hook.sh`. A single bash script registered for all five Claude Code hook events. Reads hook JSON from stdin, enriches, POSTs to the local server. `curl -m 2`, always exits 0.
- **EventServer** — local HTTP server (Swift `Network.framework`) bound to `127.0.0.1` on an ephemeral port. Port written atomically to `~/.claude-monitor/port`. Single `POST /event` endpoint.
- **SessionStore** — in-memory ordered dictionary keyed by `session_id`. Applies events to produce state transitions. Emits changes via `@Published`.
- **StateMachine** — pure function `(currentState, hookEvent) → newState`. Unit-tested.
- **HookInstaller** — manages hook blocks in one or more Claude config directories. Scans for candidates, writes/merges `settings.json`, tracks per-directory install status.
- **TerminalBridge** — wraps AppleScript for Terminal.app. Typed result: `focused | noSuchTab | terminalNotRunning | scriptError(String)`.
- **DashboardWindow** — SwiftUI root: grid, drag-to-reorder, flash animation.
- **MenuBarController** — `NSStatusItem` with summary glyph + badge count.
- **Settings** — UserDefaults: window frame, manual tile order, managed config directories, hook-install status per directory.

### 3.2 Event pipeline

```
Claude Code fires hook
  → hook.sh reads stdin, enriches with tty/pid/cwd/hook/ts
  → curl POST to http://127.0.0.1:<port>/event
  → EventServer decodes
  → SessionStore applies via StateMachine
  → @Published publishes
  → SwiftUI re-renders
  → if transition is into waiting/needsYou (or needsYou→working), tile flashes
```

Events are processed serially on a single queue. Ordering is insertion-order from the HTTP server.

### 3.3 Event payload

```json
{
  "hook": "UserPromptSubmit",
  "session_id": "abc123",
  "tty": "/dev/ttys005",
  "pid": 78412,
  "cwd": "/Users/leo/Projects/foo",
  "ts": 1745438400,
  "prompt_preview": "Refactor the hook registrar…",
  "tool_name": "Bash"
}
```

`prompt_preview` is only present on `UserPromptSubmit` and is truncated to 120 chars. `tool_name` is optional (reserved for future use).

## 4. Hooks

### 4.1 Registered events

Five Claude Code hooks, all pointing to the same `hook.sh`:

| Hook | Triggers transition |
|---|---|
| `SessionStart` | create session → `waiting` |
| `UserPromptSubmit` | → `working` |
| `Stop` | → `waiting` |
| `Notification` | → `needsYou` |
| `SessionEnd` | → `finished`, schedule removal in 10s |

### 4.2 Hook script responsibilities

- Read JSON from stdin (Claude Code passes the hook payload here).
- Capture `tty` from the `tty` command (= the controlling terminal of the running `claude` process = the Terminal.app tab hosting it).
- Capture `pid` (parent pid chain — the `claude` process itself).
- Capture `cwd` via `pwd`.
- Add `ts` (unix seconds) and the hook name.
- POST merged JSON to `http://127.0.0.1:$(cat ~/.claude-monitor/port)/event` with `curl -m 2 -s`.
- Always `exit 0`. Hook failures must never affect the Claude session.

### 4.3 Install location

Hooks live in `<configDir>/settings.json`, where `configDir` is one of the user's managed Claude config directories. The user may run multiple Claude configs (e.g. `~/.claude`, `~/.claudewho-work`, `~/.claudewho-personal`) and we install into each selected one.

### 4.4 Managed block marker

Every hook entry the installer writes carries:

```json
{ "_managedBy": "claude-monitor", "_version": 1, ... }
```

The installer only touches entries it owns. User-authored hooks are never modified.

### 4.5 Directory discovery & management

- **Auto-discovery** on first launch: scan `~/.claude` and any `~/.claudewho-*` directory containing a `settings.json`. Present as a checklist.
- **Manual add/remove** in Settings: folder picker to add; per-row delete button. On remove, prompt *"Also uninstall the hook block from its settings.json?"*
- **Per-directory state** tracked in Settings: path, install-status (`installed` / `notInstalled` / `outdated`), last-installed hook-script version.
- **Outdated detection:** when the app ships a new `hook.sh` schema version, previously-installed directories are flagged `outdated` and the user is offered one-click reinstall.
- **External-modification detection:** if the managed block in `settings.json` differs from what we wrote, surface a diff preview rather than silently overwriting.

## 5. Terminal integration

> **Note (2026-04-24):** This section describes the original monolithic `TerminalBridge`
> design (Terminal.app only). Terminal dispatch has since been split into a `TerminalProvider`
> protocol with per-terminal implementations (`AppleTerminalProvider`, `ITerm2Provider`) and a
> `CompositeTerminalBridge` that fans out across all enabled providers. iTerm2 is now supported.
> See the "Terminal dispatch" section of `CLAUDE.md` for the current architecture.

### 5.1 Identifying the tab

`tty` is the stable handle. When `hook.sh` runs, its controlling terminal is the Terminal.app tab hosting `claude`. `tty` returns e.g. `/dev/ttys005`. Terminal.app's AppleScript dictionary exposes `tty` as a property of each tab.

Mapping `session_id → tty` is recorded at `SessionStart` and held for the lifetime of that session.

### 5.2 Focus script

```applescript
tell application "Terminal"
  activate
  repeat with w in windows
    repeat with t in tabs of w
      if tty of t is "<tty>" then
        set selected of t to true
        set index of w to 1
        return "focused"
      end if
    end repeat
  end repeat
  return "no-such-tab"
end tell
```

Invoked via `NSAppleScript` with the tty substituted in.

### 5.3 Result handling

| Result | Behavior |
|---|---|
| `focused` | Normal path — Terminal brought to front, tab selected. |
| `noSuchTab` | Tab was closed. Mark session `finished`, start 10s removal timer. |
| `terminalNotRunning` | Terminal quit entirely. Same as `noSuchTab`. |
| `scriptError(String)` | Log it, play a subtle shake animation on the tile, keep the tile. |

### 5.4 TTY reuse guard

After a Terminal tab closes, the OS may recycle the `/dev/ttysNNN` device. To avoid focusing the wrong session, before selecting the tab the bridge verifies the recorded `pid` is still alive (`kill(pid, 0)`) **and** queries Terminal.app for `processes of t` and confirms the list contains a process matching the recorded `pid`. If either check fails, treat as `noSuchTab`.

### 5.5 Non-goals

Resuming stopped sessions (`claude --resume`) is explicitly out of scope. "Click to take me to the session" means "focus the live tab." If the tab is gone, the session is gone.

## 6. Lifecycle & edge cases

### 6.1 App starts after sessions are running

No retroactive discovery — Claude Code only reports on events. On the next hook for an unknown `session_id`, the SessionStore synthesizes a `SessionStart` to create the tile, then applies the real event. Net result: the tile appears in whatever state the real event implies (e.g. a `UserPromptSubmit` creates it as `working`, a `Stop` as `waiting`). No data loss; the tile simply appears later than it would have.

### 6.2 App quits while sessions run

In-memory state is lost. When the app returns, section 6.1's synthesis brings tiles back. Manual drag order is keyed by `session_id` and persists in UserDefaults, so tiles land where the user put them.

### 6.3 Hook fires while app is off

`curl -m 2` fails silently; hook exits 0; Claude is unaffected. By design.

### 6.4 Stale port file

If `~/.claude-monitor/port` points to a dead port, `curl` fails fast. On launch, the app writes port atomically (`.port.tmp` → rename) to prevent partial reads.

### 6.5 Two app instances

Second launch checks `~/.claude-monitor/pid` lockfile. If the recorded PID is alive, the second instance activates the first and exits. Prevents port conflicts.

### 6.6 Tab force-closed (no `SessionEnd`)

Two guards:

1. **Stale-session sweep** — every 60s, for each tile in `working`/`waiting`/`needsYou`, check `kill(pid, 0)`. If the process is gone, mark `finished`.
2. **Click-time check** — §5.3 / §5.4 catch the remaining case on click.

### 6.7 Elapsed-time counter

One shared `Timer` at 1 Hz drives all tile timers. No per-tile timers.

### 6.8 Session ID collisions

Claude Code session IDs are UUIDs. Treated as globally unique across all managed config directories.

## 7. Testing

- **StateMachine** — table-driven unit tests; every row of the transition table + unknown-session synthesis.
- **SessionStore** — scripted event sequences, assert final tile list + order + snippet. 10s removal timer tested via injectable clock.
- **HookInstaller** — fixture `settings.json` files (empty / has-other-hooks / has-our-block / has-modified-our-block); assert merged output for install/uninstall/reinstall. Runs in a tmp dir.
- **TerminalBridge** — protocol-based; unit tests use a fake. Real AppleScript path gets one integration test that opens a Terminal tab, captures its tty, runs `focus(tty:)`, asserts Terminal is frontmost via `AXUIElement`.
- **EventServer** — in-test server on port 0, POST synthetic events with `URLSession`, assert they arrive at SessionStore. Covers malformed JSON, wrong content-type, oversized bodies.
- **HookScript** — shell-level smoke test: pipe fixture JSON into `hook.sh` against a dummy HTTP server, assert the received body has the expected enrichment fields.
- **Grid Layout** — unit-test the custom `Layout` with mocked sizes for 1/5/20/100 tiles across window heights.
- **UI smoke** — one XCUITest that launches the app, POSTs a scripted event sequence to the real server, asserts tiles appear/change color/disappear.

## 8. Distribution

- Xcode project, XcodeGen optional.
- Signed with personal Developer ID for local use; no notarization.
- Hardened runtime off for v1 (`TerminalBridge` needs Automation entitlement — macOS will prompt on first use).

## 9. Out of scope (v1)

Explicitly not building these. If they come up later, they're a v2 conversation.

- Resuming killed sessions (`claude --resume`)
- Remote / cross-machine monitoring
- Any terminal other than Terminal.app
- Historical log / transcript view
- Cost or token metrics on tiles
- Sound / OS notifications (flash only)
- Tile grouping, filtering, or search
- Themes / custom colors
