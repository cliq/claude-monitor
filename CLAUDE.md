# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`ClaudeMonitor` is a native macOS 14+ SwiftUI app that shows the live state of every local Claude Code CLI session (and, since the Codex integration, OpenAI Codex CLI sessions) as colored tiles. Each session reports transitions through agent lifecycle hooks; clicking a tile focuses the hosting terminal tab. Terminal.app, iTerm2, and Orca are supported; other terminals (Ghostty, WezTerm, VS Code's integrated terminal) are not.

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
UsageAccountConfig.discover() — Claude dirs via ConfigDirectoryDiscovery.scan(),
    Codex dirs via scanCodex(); provider-tagged accounts
  → UsagePoller (@MainActor: timer, ordering, updatedAt, publish) — every 180s
    dispatches per provider to a UsageFetching impl; per-account error isolation
      .claude → ClaudeUsageFetcher — ClaudeCodeKeychain (Claude Code's
        "Claude Code-credentials-<sha256(configDir)[:8]>" items) +
        https://api.anthropic.com/api/oauth/usage; refreshes OAuth tokens and
        writes them back so Claude Code stays logged in
      .codex → CodexUsageFetcher — CodexAppServerClient launches a short-lived
        `codex app-server --listen stdio://` with CODEX_HOME=<configDir>,
        calls account/rateLimits/read (JSONL, 10s timeout), maps via
        CodexUsageMapper; never reads/refreshes Codex credentials
  → UsagePanelView (menu bar → "Open Usage Panel")
  → UsageBridgeServer — GET /usage + /display on LAN port 8737 (default) for
    the ESP32 desk panel (esp32-claude-monitor firmware)
  → UsageSnapshotStore — usage-snapshot.json in the App Group container,
    written after each poll (UsagePoller's injected `publish` hook)
  → ClaudeMonitorWidget.appex — sandboxed WidgetKit extension; TimelineProvider
    reads the snapshot file, WidgetCenter reloads are triggered by the app
```

The Anthropic usage endpoint is undocumented/community-discovered: it requires a `claude-code/…` User-Agent and a ≥180s interval, otherwise it 429s. `ClaudeCodeKeychain` goes through the `security` CLI (not SecItemCopyMatching) because Claude Code creates its items with that binary, so `security` is on their ACL and access never prompts. The credential payload holds more than `claudeAiOauth` (e.g. `mcpOAuth`) — only the three token fields are mutated on refresh; round-trip everything else verbatim. `AccountUsage`'s snake_case coding keys are the wire schema the ESP32 firmware parses **and** the widget's snapshot file — never rename or remove keys, additive changes only (`*_resets_at`, `schema_version`, and the v2 `provider`/`metrics` keys were added this way; the firmware's per-key parser ignores unknown keys). `UsagePoller.summarize`/`formatReset` forward to the pure statics in `UsageFormat` (`App/Core/Usage/UsageFormatting.swift`); keep all of them (and `CodexUsageMapper`) `nonisolated` pure for the tests.

Codex specifics: `AccountUsage.metrics` (`[UsageMetric]`) is the authoritative list the panel/widget render (`displayMetrics` falls back to the legacy session/weekly/model trio for Claude accounts and schema-v1 snapshots); the flat `session_*`/`weekly_*`/`model_*` fields are populated as an adapter (shortest ordinary window → session, ~7-day window → weekly, monthly/individual spend limit → model). `CodexUsageMapper` labels windows from `limitName` or duration only — `MONTHLY` requires a month-boundary reset (else `INDIVIDUAL`), other durations get neutral labels like `30D`, never guessed product names. The app-server response is read via `CodexResponseAccumulator` (fragmented-line/notification/ID-correlation tolerant — tested without spawning processes); stderr and error strings are capped, stdout is never logged wholesale, and the monitor must never redeem Codex reset credits. Codex usage needs a ChatGPT sign-in; API-key logins surface an actionable per-account error. `AccountUsage.id` and `UsageAccountConfig.id` are provider-qualified (same display name across providers must not collide), while preferences stay keyed by `configDir`. An opt-in integration smoke test runs the real CLI: `TEST_RUNNER_CODEX_USAGE_INTEGRATION=1` + `-only-testing:ClaudeMonitorTests/CodexUsageTests`.

### Usage widget

The widget never polls or touches the keychain: it renders the last `UsageSnapshot` the app published. `UsagePoller` gets an injected `publish:` closure (called at the end of `pollAll()`, when `accounts` and `updatedAt` are consistent — don't replace it with a Combine sink; `@Published` emits on willSet and would pair new accounts with the old timestamp). `AppDelegate` wires it to `UsageSnapshotStore.write` + a hash-throttled `WidgetCenter.reloadTimelines`; disabling usage monitoring clears the file so the widget shows its "monitoring off" state.

- The App Group is team-prefixed: `APP_GROUP_ID = $(DEVELOPMENT_TEAM).com.cliqconsulting.claudemonitor` in `Configuration/Base.xcconfig`, surfaced to code via the `AppGroupIdentifier` Info.plist key on both targets. Team-prefixed groups are authorized by the code signature alone — no provisioning profile needed for Developer ID, no macOS 15 TCC prompt.
- Everything in `UsageSnapshotStore` is nil-safe by design: with an empty `DEVELOPMENT_TEAM` (contributors without signing) or an ad-hoc signature the group container is unavailable and the publish path silently no-ops — the app, panel, ESP32 bridge, and `make test` must keep working.
- **Ad-hoc builds cannot exercise the widget** (`make install` signs with `CODE_SIGN_IDENTITY=-`; no team ID → the group entitlement doesn't validate). Test widgets from a team-signed build installed in `/Applications` — widget registration is path-sensitive, and a DerivedData copy makes `pluginkit` register a stale path so `WidgetCenter` reloads appear to do nothing.
- Files shared into the widget target are listed explicitly in `project.yml` (`UsageModels`, `AgentProvider`, `RGB`, `UsagePalette`, `UsageFormatting`, `UsageSnapshotStore`). They must stay Foundation/SwiftUI-pure: no AppKit windows, keychain, discovery, or `Bundle.main` resource lookups. The widget kind string `"UsageWidget"` (`UsageSnapshotStore.widgetKind`) must never change — it's how the app targets reloads and how macOS tracks placed widgets.
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

### Codex support

Codex CLI sessions flow through the same pipeline via `scripts/codex-hook.sh` (installed to `~/.claude-monitor/codex-hook.sh`), which **normalizes** Codex events into the existing closed vocabulary before POSTing: `PermissionRequest` becomes `Notification` with `notification_type=permission_prompt`, so `StateMachine` and `PushNotifier` have zero Codex-specific code. Session IDs are namespaced `codex:<uuid>` in the script (Claude IDs stay raw — no migration), and the payload carries `provider: "codex"`; `HookEvent`/`Session` decode a missing `provider` as `.claude`. The script must never write to stdout (Codex would read JSON from a `PermissionRequest` hook as an allow/deny decision) and must not use apostrophes inside its python heredoc (macOS bash 3.2 quote-scans heredoc content inside `$(...)`).

`HookInstaller`'s `codexKind` targets `<configDir>/hooks.json` (marker files `config.toml`/`auth.json` via `ConfigDirectoryDiscovery.scanCodex`; dirs named `.codex`/`.codexwho-*`), keeps entries schema-minimal (no matcher/sidecar keys — ownership is the arg-encoded command tag only), pins `timeout: 3` on `SessionEnd` (Codex kills those hooks after 1s by default, 3s max), and backs up to `hooks.json.claude-monitor.bak` because other tools (Orca) already own `hooks.json.bak`. Foreign entries in `hooks.json` must survive install/uninstall — see `Tests/Fixtures/codex-hooks-with-foreign-entries.json`. After installation Codex requires the user to trust the hooks via `/hooks` (trust is recorded against the hook definition's hash, so changing the command string re-triggers review); the settings UI surfaces this. `scanCodex` is deliberately separate from `scan()` — Claude-only consumers must never see Codex dirs (`UsageAccountConfig.discover()` combines both on purpose, tagging each account with its provider).

### Hook schema versioning

`HookInstaller.currentVersion` gates the schema of the managed block in `settings.json`. Bumping it flips previously-installed directories to `.outdated`, surfacing a one-click reinstall in Settings. **When changing what the installer writes, bump this number** and make sure the comparison in `inspect(configDir:)` still only compares commands at the current version. Schema history: v1 used a flat `{command}` shape, v2 moved to Claude Code's real `{matcher, hooks: [{type, command}]}` schema (commit `989c15e`), v3 moved the managed tag *into* the command string as `--managed-by=claude-monitor --version=3`. The arg-encoded tag is the load-bearing signal — some tools re-serialize `settings.json` and drop unknown sidecar keys like `_managedBy`/`_version`, which used to leave real installs looking "Not installed". `inspect` and `uninstall` identify our entries by the `.claude-monitor/hook.sh` path in the command as a fallback.

`HookInstaller` always copies `<path>/settings.json` to `settings.json.bak` before writing (single rolling backup).

### Terminal dispatch

Click handling goes through `App/Core/Terminal/CompositeTerminalBridge.swift`,
which fans `focus(tty:expectedPid:)` out across a list of `TerminalProvider`s
in registry order (`TerminalRegistry.all`). The first provider that reports
`.focused` wins.

The composite owns two guards that used to live in `TerminalBridge`:

1. `NSWorkspace.runningApplications` — skip providers whose app isn't running.
2. `kill(expectedPid, 0)` with ESRCH — short-circuit when the Claude process is
   truly gone (macOS recycles `/dev/ttysNNN` when tabs close).

`AppleTerminalProvider` and `ITerm2Provider` are thin AppleScript wrappers.
The third guard — matching on `tty` inside the AppleScript — is per-provider
because Terminal.app puts `tty` on tabs while iTerm2 puts it on sessions.

`OrcaProvider` (Orca, https://onorca.dev) has no AppleScript path. Orca exports
`TERM_PROGRAM=Orca` and `ORCA_TERMINAL_HANDLE` into every pty; the provider
reads the Claude process's environment via `ps eww -p <pid>`, then runs the
bundled CLI (`Orca.app/Contents/Resources/bin/orca terminal switch --terminal
<handle>`) and activates the app itself — the CLI selects the tab but never
raises the window. If the handle is stale (Orca restart) it still activates the
app and returns `.focused`, because the env already proved no other provider
can match.

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
