# Push Notifications via Prowl

**Status:** design  
**Date:** 2026-04-27  
**Branch:** `push-notifications`

## Summary

Add Prowl push-notification support to ClaudeMonitor so users get phone/watch alerts when a Claude Code session needs attention or finishes. Configuration lives in a new "Push Notifications" settings tab. An optional "offline mode" installs a fallback shell hook that pushes via Prowl directly when the monitor app isn't running.

This is a port of the user's existing `~/.claude/claude-prowl.sh` workflow into the app, with the API key managed through the macOS Keychain and a simple master on/off toggle replacing the standalone script.

## Goals

- Push to Prowl when Claude Code fires a `Stop` or `Notification` hook for any monitored session.
- Use the same title format as `claude-prowl.sh`: `<project>: <status>`, where `<status>` is subtype-aware ("Permission needed", "Waiting for you", "Needs input", "Notification", "Done").
- Store the API key in the macOS Keychain.
- Provide an in-app "Send test notification" button that surfaces the Prowl response inline.
- Provide an opt-in "offline mode" that installs a second managed hook entry for resilience when the app isn't running. Warn the user that this stores the API key in plain text.
- Guarantee at most one push per Claude event regardless of which paths are active.

## Non-goals

- Per-project filtering (every monitored session pushes).
- Per-state filtering beyond `Stop` and `Notification` (no toggles for `working` / `waiting`).
- Configurable Prowl priority (always `priority=0`, matching `claude-prowl.sh`).
- macOS local notifications via `UNUserNotificationCenter`.
- Push providers other than Prowl (Pushover, ntfy, etc.).
- Push history / log surfaced in the UI.
- Retries on Prowl HTTP failures.

## High-level architecture

```
Claude Code event
  → ~/.claude-monitor/hook.sh (extended: forwards `notification_type` + `message`)
    │
    ├─ POST /event to local app  ──► EventServer ──► SessionStore.apply
    │                                                    │
    │                                                    ├─ StateMachine.transition (unchanged)
    │                                                    └─ PushNotifier.handle (new)
    │                                                          │
    │                                                          ├─ reads Preferences (master toggle)
    │                                                          ├─ reads KeychainStore (API key)
    │                                                          └─ ProwlClient.send (URLSession, background)
    │
    └─ if offline mode is enabled:
       ~/.claude-monitor/offline-prowl.sh (new, second hook entry)
         ├─ probes GET /health on the monitor; if up → exit 0
         └─ otherwise: parse stdin, POST to api.prowlapp.com with embedded key
```

## Components

### New types

| Type | File | Purpose |
|---|---|---|
| `PushNotifier` | `App/Core/PushNotifier.swift` | Decides whether to push for a given `HookEvent`, builds title/body, dispatches a `ProwlClient.send`. |
| `ProwlClient` | `App/Core/ProwlClient.swift` | One async method: `send(apiKey:event:description:) -> Result<Void, ProwlError>`. Single owner of the Prowl HTTP contract; used by both `PushNotifier` and the Test button. |
| `KeychainStore` | `App/Core/KeychainStore.swift` | Thin wrapper over `Security.framework` (`SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete`) for `kSecClassGenericPassword` entries scoped to one service identifier. |
| `OfflineHookDeployer` | `App/Core/OfflineHookDeployer.swift` | Renders `offline-prowl.sh` from a template (substituting the API key), writes it to `~/.claude-monitor/offline-prowl.sh` mode `0700`, and registers/unregisters the offline hook entry across all managed config dirs via `HookInstaller`. |
| `NotificationsSettingsView` | `App/UI/NotificationsSettingsView.swift` | New "Push Notifications" tab. |
| `scripts/offline-prowl.sh.template` | bundled resource | Source for the offline script with a `__PROWL_API_KEY__` placeholder. |

### Modified types

| Type | Change |
|---|---|
| `HookEvent` | Add optional `notificationType: String?` (`notification_type`) and `message: String?`. |
| `scripts/hook.sh` | Extract `notification_type` and `message` from Claude's stdin payload via the existing Python branch, include them in the POST body. The bash fallback omits them (best-effort, same as today). |
| `Preferences` | Add `prowlEnabled: Bool` (default `false`), `prowlOfflineHookEnabled: Bool` (default `false`). API key is **not** stored here — `KeychainStore` owns it. |
| `EventServer` | Add `GET /health` returning `200` with empty body. Used by the offline script's liveness probe. |
| `SessionStore.apply` | After the existing state-machine call, invoke `pushNotifier.handle(event:)`. Threaded through `AppDelegate` like other dependencies. |
| `HookInstaller` | Gain a parallel managed-block path keyed by `--managed-by=claude-monitor-offline-prowl --version=1`. The existing v3 main entry is untouched. The two managed entries can be present independently. |
| `SettingsView` | Add a fourth tab: `NotificationsSettingsView`. |
| `AppDelegate` | Construct `KeychainStore`, `ProwlClient`, `PushNotifier`; wire them into `SessionStore`. |

## Data flow

### Online path (app running)

1. Claude fires a hook (`Stop`, `Notification`, etc.).
2. `~/.claude-monitor/hook.sh` reads stdin, extracts `notification_type` and `message` along with the existing fields, POSTs to `http://127.0.0.1:<port>/event`.
3. `EventServer` decodes on its private queue, dispatches to main, calls `SessionStore.apply(event)`.
4. `SessionStore.apply`:
   - Runs `StateMachine.transition` as today.
   - Calls `pushNotifier.handle(event:)`. Returns immediately if `prowlEnabled` is `false`, the API key is missing, or the hook isn't `Stop`/`Notification`.
   - Otherwise builds title/body (see "Title and body" below) and calls `ProwlClient.send` on a background queue. Result is logged via `NSLog`; no UI surface.

### Offline path (app down, offline mode enabled)

1. Claude fires a hook.
2. `~/.claude-monitor/offline-prowl.sh` runs (it is a separate hook entry, not chained from `hook.sh`).
3. The script:
   - Probes `curl -fsS -m 1 http://127.0.0.1:$(cat ~/.claude-monitor/port)/health` if the port file exists.
   - If the probe succeeds, exits 0 (the app is handling it).
   - Otherwise, parses stdin (`hook_event_name`, `notification_type`, `message`, `cwd`) using `python3` (mirroring `hook.sh`'s parser choice — Apple ships `python3` via Command Line Tools whereas `jq` is not present by default), builds title/body, POSTs to `https://api.prowlapp.com/publicapi/add` with the embedded API key.
4. Always exits 0.

### Title and body

Identical logic in both paths:

| Hook event | Notification subtype | Title | Body |
|---|---|---|---|
| `Stop` | — | `<project>: Done` | `Finished responding.` |
| `Notification` | `permission_prompt` | `<project>: Permission needed` | `<message>` or `Claude Code sent a notification.` |
| `Notification` | `idle_prompt` | `<project>: Waiting for you` | `<message>` or fallback |
| `Notification` | `elicitation_dialog` | `<project>: Needs input` | `<message>` or fallback |
| `Notification` | (anything else / nil) | `<project>: Notification` | `<message>` or fallback |

`<project>` is `basename(cwd)`. If `cwd` is empty, the title omits the prefix and colon.

## Settings UI

Order top to bottom in the new tab (frame `560 × 420`):

1. **Master toggle:** "Enable Prowl push notifications".
2. **API key field** (`SecureField`, disabled when toggle is off) with a "Test" button to its right. Status line below: empty / "Test sent ✓" / "Invalid API key" / "Rate limited" / "Network error: <message>". Status clears after 5 s. A "Remove key" link appears below the field when a key is stored.
3. **Caption:** "Get a key at prowlapp.com → Settings → API Keys."
4. **Separator.**
5. **Offline mode toggle:** "Send pushes even when ClaudeMonitor isn't running".
6. **Warning beneath it** (visible whenever the toggle is on): "This stores your Prowl API key in plain text in `~/.claude-monitor/offline-prowl.sh`. Anyone with read access to your home folder can read it. The monitor app keeps the key in the macOS Keychain."

### Behaviors

- The Test button is disabled until the key field is non-empty. Clicking it persists the key to the Keychain (if changed) and dispatches `ProwlClient.send` with `event: "ClaudeMonitor: Test ✓"` and `description: "If you're seeing this, your API key works."`.
- Switching the master toggle off does **not** delete the key. Only the explicit "Remove key" link does.
- Toggling **offline mode on** with no key configured is blocked with an inline error ("Enter and save your Prowl API key first."). Toggling on with a key triggers `OfflineHookDeployer.install(...)` across all managed config dirs.
- Toggling **offline mode off** removes the offline script and unregisters all `--managed-by=claude-monitor-offline-prowl` entries.
- Changing the API key while offline mode is on triggers a redeploy of the script with the new key. Status line shows "Updating offline hook…" briefly, then "Updated ✓".
- The master toggle is the global gate. When it is off, **no pushes go out from any path**: the in-app `PushNotifier` short-circuits, and the offline script is uninstalled (even if `prowlOfflineHookEnabled` is `true` in preferences). When the master toggle goes back on, the offline script is reinstalled if `prowlOfflineHookEnabled` is `true`. The offline-mode toggle is disabled in the UI while the master toggle is off.

## Concurrency

- `PushNotifier.handle` is called on the main queue (the queue `SessionStore.apply` already runs on). Filter checks and `KeychainStore.get` are synchronous and main-queue-safe.
- The `URLSession.dataTask` inside `ProwlClient.send` runs on the default global queue. Result logging uses `NSLog`, which is thread-safe.
- `OfflineHookDeployer` operations (file write, hook install/uninstall) run on the main queue, blocking the UI for the duration. Operations are fast (<50 ms typical).

## Security

- API key stored in macOS Keychain via `kSecClassGenericPassword` with service `com.cliq.ClaudeMonitor.prowl` and account `default`. Access scoped to the app via the standard ACL — no entitlement changes required (the existing Hardened Runtime release config already permits Keychain access for the app's own service).
- Offline script writes the key in plain text to `~/.claude-monitor/offline-prowl.sh` mode `0700`. The settings UI explicitly warns the user. Toggling offline mode off deletes the script.
- Prowl API uses HTTPS; no certificate pinning (Prowl's cert rotates and pinning would create a maintenance burden disproportionate to the threat model).

## Error handling

| Failure | Online path | Offline path |
|---|---|---|
| Network error | `NSLog`, no UI | `exit 0`, no log |
| HTTP 401 (invalid key) | `NSLog`, no UI (Test button surfaces it) | `exit 0`, no log |
| HTTP 406 (rate limited) | `NSLog`, no UI (Test surfaces "Rate limited (1000/hr exceeded)") | `exit 0`, no log |
| Other 4xx/5xx | `NSLog` with status + body, no UI | `exit 0` |
| Master toggle off | Return before any work | n/a (script is uninstalled) |
| API key missing | `NSLog` once per launch, return | n/a (script wouldn't be installed without a key) |
| Keychain set fails | Settings UI shows "Couldn't save key to Keychain (errSec…)" | n/a |
| Offline-mode install fails | n/a | Settings toggle reverts, inline error shown with the underlying error |
| `/health` probe times out | n/a | Treat app as down, fall through to Prowl |

The offline script is silent on every error path. No log file is written.

## Testing

### Unit tests (`ClaudeMonitorTests`)

| Test | Coverage |
|---|---|
| `PushNotifierTests` | Table-driven over `(prefsState, hookName, notificationSubtype, message, cwd)`. Asserts whether `ProwlClient.send` is invoked and the exact title and body. Cases: master off → no call; missing API key → no call; non-Stop/Notification hook → no call; each `Notification` subtype → matching title; `Stop` → "Done" title; empty `cwd` → no `project:` prefix. Uses a fake `ProwlClient` that records calls. |
| `ProwlClientTests` | URL construction, form-encoded body, status-code → `ProwlError` mapping (200 → success; 400 → `.http`; 401 → `.invalidAPIKey`; 406 → `.rateLimited`; 500 → `.http`). Uses a `URLProtocol` stub. |
| `KeychainStoreTests` | `set` / `get` / `delete` round-trips on a test-only service name (`com.cliq.ClaudeMonitor.tests.prowl`). Also asserts overwrite-on-set behavior and `get` returning nil after delete. |
| `HookEventTests` (additions) | Decodes a fixture with `notification_type` and `message` populated; another with both nil; existing fixtures continue to decode. |
| `HookInstallerTests` (additions) | Fixtures: install-only-main, install-only-offline (orphaned), install-both, uninstall-offline-leaves-main. Asserts the v1-tagged offline command is detected by the `--managed-by=claude-monitor-offline-prowl` argument and updated independently of the v3 main entry. |
| `OfflineHookDeployerTests` | Renders the script template with a sample key; asserts the file is mode `0700`, the rendered script contains the key exactly once, and re-rendering with a new key overwrites the file cleanly. |

### No new integration tests

`make test-integration` already covers AppleScript / Terminal.app. Prowl integration would require a real key plus network access and is intentionally left out.

### Manual verification checklist

1. Enter a valid key, click Test → "Test sent ✓" appears; phone receives "ClaudeMonitor: Test ✓".
2. Fire a real Claude `Notification` and `Stop` event from a session → exactly one push per event with the correct subtype-aware title.
3. Quit the app, fire a Claude event with offline mode OFF → no push.
4. Quit the app, fire a Claude event with offline mode ON → push received from the offline script.
5. Relaunch the app while offline mode is ON, fire an event → exactly one push (from the app, not the script — confirms the liveness probe works).
6. Disable offline mode → confirm `~/.claude-monitor/offline-prowl.sh` is removed and the second hook entry disappears from `~/.claude/settings.json`.
7. Change the API key with offline mode on → confirm the offline script is rewritten with the new key.
8. Click "Remove key" → field clears, Keychain entry is deleted, offline mode toggle disables itself if it was on.

## Open considerations

- The `HookInstaller` schema-versioning model uses one `currentVersion` for the main hook. Adding a second managed entry with its own version tag is consistent with the existing tag-based detection (`inspect` already falls back to path-matching `.claude-monitor/hook.sh`). The offline entry follows the same pattern with its own filename and version tag — no changes to the v3 main entry are required.
- Prowl's free tier allows 1000 requests/hour per key. Even a heavy user firing 10 events per minute stays well within the limit. No rate limiting is implemented in the app.
