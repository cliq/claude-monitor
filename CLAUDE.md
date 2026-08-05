# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`ClaudeMonitor` is a native macOS 14+ SwiftUI app that shows the live state of every local Claude Code CLI session as colored tiles. Each session reports transitions through Claude Code hooks; clicking a tile focuses the hosting terminal tab. Terminal.app and iTerm2 are supported; other terminals (Ghostty, WezTerm, VS Code's integrated terminal) are not.

## Build / test

The Xcode project is **generated** — `ClaudeMonitor.xcodeproj/` and `App/Info.plist` are gitignored. Run `make gen` (wraps `xcodegen`) before opening in Xcode or running any `xcodebuild` command after pulling or editing `project.yml`.

```
make gen             # regenerate ClaudeMonitor.xcodeproj from project.yml
make open            # gen + open in Xcode
make test            # unit tests: scheme ClaudeMonitorTests, destination macOS
make test-integration  # integration tests (ClaudeMonitorIntegrationTests) — hits real AppleScript / Terminal.app
make clean           # remove generated .xcodeproj
```

Run a single test from the CLI:

```
xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' \
  -only-testing:ClaudeMonitorTests/StateMachineTests/testTransitionFromWorkingOnStop
```

The UI test target (`ClaudeMonitorUITests`) is currently skipped on Xcode 26.3 beta — see commit `d4441dd`.

## Architecture

### Event pipeline

```
Claude Code fires hook
  → scripts/hook.sh (installed to ~/.claude-monitor/hook.sh)
    reads stdin JSON, enriches with tty/pid/cwd/ts
  → curl -m 2 POST http://127.0.0.1:<port>/event
  → EventServer (Network.framework NWListener, bound to 127.0.0.1:0)
  → SessionStore.apply(_: HookEvent)
  → StateMachine.transition(from:for:)
  → @Published orderedSessions → SwiftUI
```

Events are decoded on the server's private queue, then dispatched onto the main queue before touching `SessionStore` (see `AppDelegate.applicationDidFinishLaunching`). Keep it that way — `SessionStore` is not thread-safe.

### Usage-limits pipeline (opt-in, Settings → Usage)

```
ClaudeCodeKeychain (Claude Code's "Claude Code-credentials-<sha256(configDir)[:8]>" items)
  → UsagePoller — polls https://api.anthropic.com/api/oauth/usage every 180s
    per account discovered by ConfigDirectoryDiscovery; refreshes OAuth tokens
    and writes them back so Claude Code stays logged in
  → UsagePanelView (menu bar → "Open Usage Panel")
  → UsageBridgeServer — GET /usage + /display on LAN port 8737 (default) for
    the ESP32 desk panel (esp32-claude-monitor firmware)
  → UsageSnapshotStore — usage-snapshot.json in the App Group container,
    written after each poll (UsagePoller's injected `publish` hook)
  → ClaudeMonitorWidget.appex — sandboxed WidgetKit extension; TimelineProvider
    reads the snapshot file, WidgetCenter reloads are triggered by the app
```

The usage endpoint is undocumented/community-discovered: it requires a `claude-code/…` User-Agent and a ≥180s interval, otherwise it 429s. `ClaudeCodeKeychain` goes through the `security` CLI (not SecItemCopyMatching) because Claude Code creates its items with that binary, so `security` is on their ACL and access never prompts. The credential payload holds more than `claudeAiOauth` (e.g. `mcpOAuth`) — only the three token fields are mutated on refresh; round-trip everything else verbatim. `AccountUsage`'s snake_case coding keys are the wire schema the ESP32 firmware parses **and** the widget's snapshot file — never rename or remove keys, additive changes only (`*_resets_at` and `schema_version` were added this way; the firmware's per-key parser ignores unknown keys). `UsagePoller.summarize`/`formatReset` forward to the pure statics in `UsageFormat` (`App/Core/Usage/UsageFormatting.swift`); keep all of them `nonisolated` pure for the tests.

### Usage widget

The widget never polls or touches the keychain: it renders the last `UsageSnapshot` the app published. `UsagePoller` gets an injected `publish:` closure (called at the end of `pollAll()`, when `accounts` and `updatedAt` are consistent — don't replace it with a Combine sink; `@Published` emits on willSet and would pair new accounts with the old timestamp). `AppDelegate` wires it to `UsageSnapshotStore.write` + a hash-throttled `WidgetCenter.reloadTimelines`; disabling usage monitoring clears the file so the widget shows its "monitoring off" state.

- The App Group is team-prefixed: `APP_GROUP_ID = $(DEVELOPMENT_TEAM).com.cliqconsulting.claudemonitor` in `Configuration/Base.xcconfig`, surfaced to code via the `AppGroupIdentifier` Info.plist key on both targets. Team-prefixed groups are authorized by the code signature alone — no provisioning profile needed for Developer ID, no macOS 15 TCC prompt.
- Everything in `UsageSnapshotStore` is nil-safe by design: with an empty `DEVELOPMENT_TEAM` (contributors without signing) or an ad-hoc signature the group container is unavailable and the publish path silently no-ops — the app, panel, ESP32 bridge, and `make test` must keep working.
- **Ad-hoc builds cannot exercise the widget** (`make install` signs with `CODE_SIGN_IDENTITY=-`; no team ID → the group entitlement doesn't validate). Test widgets from a team-signed build installed in `/Applications` — widget registration is path-sensitive, and a DerivedData copy makes `pluginkit` register a stale path so `WidgetCenter` reloads appear to do nothing.
- Files shared into the widget target are listed explicitly in `project.yml` (`UsageModels`, `RGB`, `UsagePalette`, `UsageFormatting`, `UsageSnapshotStore`). They must stay Foundation/SwiftUI-pure: no AppKit windows, keychain, discovery, or `Bundle.main` resource lookups. The widget kind string `"UsageWidget"` (`UsageSnapshotStore.widgetKind`) must never change — it's how the app targets reloads and how macOS tracks placed widgets.
- Widget views must derive "now" from `entry.date`, never `Date()`, so archived timeline entries render honestly; staleness threshold is the shared `UsageFormat.staleAfter` (= `UsagePoller.pollInterval * 3`).

### Update checks

`App/Core/UpdateChecker.swift` polls the GitHub `releases/latest` API (repo hardcoded in `latestReleaseURL`) at launch and every 24h, gated by the `updateCheckEnabled` preference (default on). It only surfaces a menu-bar item + a line in Settings → General — nothing downloads. Checks are ETag-conditional and failures are silent. `isNewer`/`parseLatestRelease` are `nonisolated` pure statics; keep them that way for the tests.

### Runtime filesystem layout

Everything the app writes outside the sandbox goes under `~/.claude-monitor/`:

- `hook.sh` — copied from the app bundle by `HookScriptDeployer`. Must be `0755`.
- `port` — ephemeral TCP port the server is listening on, written atomically (`.tmp` + rename) by `PortFileWriter`.
- `pid` — single-instance lockfile checked by `SingleInstanceGuard` with `kill(pid, 0)`.

Hook entries are installed **into the user's Claude config directories**, not this one. `HookInstaller` edits `<configDir>/settings.json` (e.g. `~/.claude/settings.json`, `~/.claudewho-work/settings.json`) and only touches objects tagged `"_managedBy": "claude-monitor"`. `ConfigDirectoryDiscovery` auto-finds these by matching `.claude` or `.claudewho-*`.

### State machine

`App/Core/StateMachine.swift` is a pure function — keep it that way so the table-driven tests stay meaningful. States are `working | waiting | needsYou | finished`. `finished` is absorbing and triggers removal from the store. Unknown sessions synthesize `SessionStart` (→ `waiting`) so the tile still appears when the app launches after Claude sessions are already running.

### Hook schema versioning

`HookInstaller.currentVersion` gates the schema of the managed block in `settings.json`. Bumping it flips previously-installed directories to `.outdated`, surfacing a one-click reinstall in Settings. **When changing what the installer writes, bump this number** and make sure the comparison in `inspect(configDir:)` still only compares commands at the current version. Schema history: v1 used a flat `{command}` shape, v2 moved to Claude Code's real `{matcher, hooks: [{type, command}]}` schema (commit `989c15e`), v3 moved the managed tag *into* the command string as `--managed-by=claude-monitor --version=3`. The arg-encoded tag is the load-bearing signal — some tools re-serialize `settings.json` and drop unknown sidecar keys like `_managedBy`/`_version`, which used to leave real installs looking "Not installed". `inspect` and `uninstall` identify our entries by the `.claude-monitor/hook.sh` path in the command as a fallback.

`HookInstaller` always copies `<path>/settings.json` to `settings.json.bak` before writing (single rolling backup).

### Terminal dispatch

Click handling goes through `App/Core/Terminal/CompositeTerminalBridge.swift`,
which fans `focus(tty:expectedPid:)` out across a list of `TerminalProvider`s
in registry order (`TerminalRegistry.all`). The first provider whose
AppleScript reports `.focused` wins.

The composite owns two guards that used to live in `TerminalBridge`:

1. `NSWorkspace.runningApplications` — skip providers whose app isn't running.
2. `kill(expectedPid, 0)` with ESRCH — short-circuit when the Claude process is
   truly gone (macOS recycles `/dev/ttysNNN` when tabs close).

Providers themselves (`AppleTerminalProvider`, `ITerm2Provider`) are thin
AppleScript wrappers. The third guard — matching on `tty` inside the AppleScript
— is per-provider because Terminal.app puts `tty` on tabs while iTerm2 puts it
on sessions.

User-disabled terminals come from `preferences.disabledTerminalBundleIDs`
(Settings: "Terminal applications" section). Disabled-list semantics mean the
default empty set opts every installed terminal in.

Unit tests drive the composite with `FakeTerminalProvider`. Real AppleScript
integration tests for each provider run only under `make test-integration`.

### SwiftUI layout

The grid is a **custom SwiftUI `Layout`** (`VerticalFirstGridLayout`), not `LazyVGrid` — tiles flow column-major (top-to-bottom then wrap right), which `LazyVGrid` can't do. Don't replace it with a stock grid.

The dashboard uses a single 1 Hz `Timer.publish` in `DashboardView` to drive all tile elapsed-time labels. Don't add per-tile timers.

## Conventions particular to this repo

- `scripts/hook.sh` is a **build resource** (see `project.yml`) for both the app and the test bundle — `HookScriptDeployer` finds it via `Bundle.main` first, then falls back to the test bundle. Don't inline its contents into Swift; edit the file.
- Set `CLAUDE_MONITOR_SKIP_ONBOARDING=1` in a scheme's environment (or `launchEnvironment`) to skip the first-run sheet in UI tests.
- Hardened runtime is **off** by default (fast local iteration; no TCC prompt on every fresh build). The release workflow (`.github/workflows/release.yml`) overrides `ENABLE_HARDENED_RUNTIME=YES` for notarization. Apple-event access to Terminal.app is plumbed through `App/ClaudeMonitor.entitlements` (`com.apple.security.automation.apple-events`) so the hardened-runtime build still works; new entitlements must be added there. Signing identity is configured via `Configuration/LocalSigning.xcconfig` (gitignored).
- Fixture JSON for `HookInstallerTests` lives at `Tests/Fixtures/` and is bundled into the test target.
