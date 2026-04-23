# iTerm2 support — design

Date: 2026-04-24
Status: Approved; ready for implementation.

## Goal

Extend Claude Monitor so clicking a tile focuses the hosting Claude Code session
regardless of whether it runs in Terminal.app or iTerm2. Ship a small plug-in
seam (`TerminalProvider`) so adding Ghostty, WezTerm, etc. later is a one-line
registry addition.

## Non-goals

- Ghostty / WezTerm / Alacritty / VS Code integrated terminal. The architecture
  is ready for them; no concrete providers ship in this change.
- Hardened-runtime + entitlements flip hinted at in `CLAUDE.md`. Separate
  change; this spec assumes today's `ENABLE_HARDENED_RUNTIME: NO`.
- Hook-schema change to hint which terminal hosts a session (considered and
  rejected during brainstorming — see "Auto-detection" below).
- tmux `-CC` integration sessions — best-effort; documented, not designed around.

## Background

The hook pipeline already captures `tty` + `pid` from the parent Claude CLI, so
event ingestion is terminal-agnostic. The single place that assumes Terminal.app
is `App/Core/TerminalBridge.swift` (bundle-id check + Terminal-specific
AppleScript). That is the only surface this change touches in any material way.

## Auto-detection strategy

When a tile is clicked, the composite bridge **probes each enabled provider in
registry order** and focuses the first one whose AppleScript reports a tty
match. No change to `hook.sh`, no change to the event schema. Cost: up to N
AppleScript round-trips on click (~tens of ms each, N ≤ 2 today). Providers
whose app isn't running are skipped cheaply via `NSWorkspace`.

The alternative — walking the process ancestry in `hook.sh` to enrich the event
with a `host_terminal` hint — was rejected. It would force a
`HookInstaller.currentVersion` bump and a reinstall prompt in every managed
config directory, and TTY collisions across two simultaneously running terminal
apps are vanishingly rare.

## Architecture

### Folder layout

Move terminal-integration code into its own cluster under `App/Core/Terminal/`:

```
App/Core/Terminal/
  TerminalBridgeProtocol.swift     (moved; unchanged public surface — FocusResult + consumer API)
  TerminalProvider.swift           (NEW — narrower protocol implemented per-terminal)
  TerminalRegistry.swift           (NEW — hardcoded supported terminals + install filter)
  CompositeTerminalBridge.swift    (NEW — iterates providers, first-hit wins; conforms to TerminalBridgeProtocol)
  AppleTerminalProvider.swift      (NEW — today's TerminalBridge body, renamed)
  ITerm2Provider.swift             (NEW — iTerm2 AppleScript)
```

Rationale: `App/Core/` has 13 files already and these six are cohesive. Adding
Ghostty later means editing `TerminalRegistry.swift` plus one new
`GhosttyProvider.swift`.

The existing concrete type `TerminalBridge` goes away. The **protocol**
`TerminalBridgeProtocol` stays — it's the consumer-facing interface wired into
`DashboardView` / click handling. `CompositeTerminalBridge` conforms to it, so
call sites are unchanged.

### `TerminalProvider` protocol

```swift
protocol TerminalProvider {
    var displayName: String { get }       // "Terminal", "iTerm2"
    var bundleID: String   { get }        // "com.apple.Terminal", "com.googlecode.iterm2"
    var isInstalled: Bool  { get }        // NSWorkspace.urlForApplication(withBundleIdentifier:)
    func isRunning() -> Bool              // NSWorkspace.runningApplications filter
    func focus(tty: String, expectedPid: Int32) -> FocusResult
}
```

`FocusResult` is unchanged: `focused | noSuchTab | terminalNotRunning | scriptError(String)`.

### `TerminalRegistry`

Owns the static list of supported terminals:

```swift
enum TerminalRegistry {
    static let all: [TerminalProvider] = [
        AppleTerminalProvider(),
        ITerm2Provider(),
    ]
    static func installed() -> [TerminalProvider] { all.filter { $0.isInstalled } }
}
```

Registry order defines probe order in the composite. Stable, not
user-reorderable. `installed()` is what Settings and the composite consult.

### `CompositeTerminalBridge`

Conforms to `TerminalBridgeProtocol`. Dispatch behavior for
`focus(tty:expectedPid:)`:

1. Resolve enabled providers: `TerminalRegistry.installed()` minus
   `preferences.disabledTerminalBundleIDs`. If empty → `.terminalNotRunning`.
2. Filter by `isRunning()`. If empty after filtering → `.terminalNotRunning`.
3. Apply the existing Swift-side ESRCH guard once:
   `kill(expectedPid, 0) != 0 && errno == ESRCH` → `.noSuchTab`.
4. For each remaining provider in registry order, call `focus(...)`:
   - `.focused` → return immediately.
   - `.noSuchTab` → try next provider.
   - `.scriptError(msg)` → remember last error, keep trying.
   - `.terminalNotRunning` (should not happen after step 2) → treat as
     `.noSuchTab`.
5. After all exhausted: `.noSuchTab` if no errors seen, else the last
   `.scriptError`.

Threading: called on main queue, same as today. Two synchronous AppleScript
calls worst case — acceptable for a click handler.

### `AppleTerminalProvider`

Body is today's `TerminalBridge` logic, unchanged except for:

- It's now a `TerminalProvider`, not the top-level bridge.
- `NSWorkspace.runningApplications` and ESRCH checks move **out** (they're in
  the composite now).
- `displayName = "Terminal"`, `bundleID = "com.apple.Terminal"`.

AppleScript unchanged.

### `ITerm2Provider`

AppleScript:

```applescript
tell application "iTerm"
    if not running then return "no-such-tab"
    repeat with w in windows
        repeat with t in tabs of w
            repeat with s in sessions of t
                if tty of s is "<escaped-tty>" then
                    select s
                    tell t to select
                    set index of w to 1
                    activate
                    return "focused"
                end if
            end repeat
        end repeat
    end repeat
    return "no-such-tab"
end tell
```

Notes:
- iTerm2's scripting model places `tty` on the **session**, not the tab. Windows
  → tabs → sessions.
- AppleScript app name is `"iTerm"` (canonical in iTerm2 3.x+); bundle ID is
  `com.googlecode.iterm2`.
- `if not running` inside the tell is a secondary guard preventing accidental
  auto-launch.
- TTY format (`/dev/ttysNNN`) matches Terminal.app; no normalization.
- Handles split panes naturally (each pane is its own session with its own tty).
- tmux `-CC` mode: best-effort. Sessions fronted by tmux integration have their
  own ttys and should work; not designed around if they don't.

## Settings UI + persistence

### `Preferences` additions

```swift
@Published var disabledTerminalBundleIDs: Set<String>
```

Stored as `[String]` under `UserDefaults` key `disabledTerminals`.
**Disabled-list semantics (not enabled-list):** default empty = every installed
terminal is active. Existing users who install and then launch this version get
both terminals auto-enabled if installed; only users who opt out write to the
key. No migration needed.

### `SettingsView` addition

New section below "Managed Claude config directories":

```
─── Terminal applications ───
Claude Monitor auto-detects which app hosts each Claude session. Uncheck to skip a
terminal when focusing tabs.

☑ Terminal                (com.apple.Terminal)
☑ iTerm2                  (com.googlecode.iterm2)
```

- Rows built from `TerminalRegistry.installed()`. Uninstalled terminals are
  hidden; reopening the Settings window refreshes the list (same pattern as
  existing "Redetect" for config dirs).
- Toggle writes to `preferences.disabledTerminalBundleIDs`.
- All-disabled is allowed; a small caption surfaces: "No terminal enabled —
  clicking a tile won't focus anything." No blocking dialog.
- No side effects on toggle. TCC prompts fire only on first real focus attempt.

## Info.plist

`NSAppleEventsUsageDescription` updated to mention both apps:

> "Claude Monitor uses Apple events to focus the Terminal.app or iTerm2 tab of a
> selected Claude Code session."

## Testing strategy

### Unit (`make test`)

- **`CompositeTerminalBridgeTests` (NEW)** — the one piece of new logic that
  warrants full coverage. Uses a `FakeTerminalProvider` with scripted behavior.
  Cases:
  - No providers enabled → `.terminalNotRunning`
  - Single provider, tty matches → `.focused`
  - First `.noSuchTab`, second `.focused` → `.focused`, probe order respected
  - All `.noSuchTab` → `.noSuchTab`
  - All `.scriptError` → last `.scriptError`
  - ESRCH short-circuit before any provider call
  - `disabledTerminalBundleIDs` filters correctly
  - Provider whose `isRunning() == false` is skipped

- **`PreferencesTests`** — add a small round-trip case for
  `disabledTerminalBundleIDs` via a fresh `UserDefaults(suiteName:)`. If the
  test file doesn't exist yet, create it.

### Integration (`make test-integration`)

- Existing `TerminalBridgeIntegrationTests` (Terminal.app) is retargeted or
  duplicated to hit the new `AppleTerminalProvider` directly.
- **`ITerm2ProviderIntegrationTests` (NEW)** — mirrors the Terminal.app
  integration test: running-check, focus-known-tty, focus-nonexistent-tty.
  Skipped via XCTSkip if iTerm2 isn't installed so CI without iTerm2 passes.

### Manual smoke

Documented in the spec + PR description:

1. Open a Claude session in Terminal.app and one in iTerm2.
2. Click each tile → confirm the right app comes forward and the right tab/pane
   is focused.
3. Uncheck Terminal in Settings → click a Terminal-hosted tile → confirm no
   focus happens and flash-failure UI fires.
4. Uncheck iTerm2 symmetrically.

### Not tested

- `AppleTerminalProvider` / `ITerm2Provider` unit tests — thin AppleScript
  wrappers, same pattern as today's `TerminalBridge`. Integration tests are the
  right level.
- `TerminalRegistry.installed()` — trivial `NSWorkspace` wrapper.

## Docs to update in this change

- `CLAUDE.md` — replace "Only Terminal.app is supported — not iTerm, not VS
  Code terminals" to reflect Terminal.app + iTerm2; rewrite the `TerminalBridge`
  architecture section to describe the composite/provider split.
- `docs/superpowers/specs/2026-04-23-claude-monitor-design.md` — spot-update the
  terminal-integration section. Not a rewrite.
- `App/Info.plist` — `NSAppleEventsUsageDescription` (see above).
- `README.md` — bump if it lists supported terminals.

## Risks

- **iTerm2 AppleScript naming drift.** If the bundle ID or `application "iTerm"`
  tell-target changes, `ITerm2Provider` breaks. Blast radius is one file.
- **TCC prompt on first iTerm2 focus.** Expected macOS behavior; the existing
  flash-on-failure UI already handles `.scriptError`. No custom dialog.
- **Both terminals disabled.** Clicking does nothing (documented in Settings
  caption). User-visible and opt-in.
