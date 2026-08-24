# Codex Usage Tracking Plan

## Goal

Extend ClaudeMonitor's opt-in usage monitoring so it can show Codex usage limits alongside Claude Code accounts in the floating panel, WidgetKit widget, snapshot file, and ESP32 bridge.

The requested "monthly" Codex value is not the same thing as the normal Codex message-rate window. Codex may return:

- one or more ordinary rate-limit windows, such as a session/five-hour or weekly allowance;
- an `individualLimit` spend-control allowance that resets at a monthly boundary;
- credit availability and plan metadata.

The implementation should preserve these distinctions rather than labeling every Codex limit as monthly.

## Decision

Use the Codex CLI's documented app-server protocol as the data source:

1. Start `codex app-server --listen stdio://` for a Codex config directory.
2. Complete the `initialize`/`initialized` handshake.
3. Call `account/rateLimits/read`.
4. Decode the response and terminate the short-lived app-server process.

Do not read or refresh Codex OAuth tokens directly, and do not call an inferred private HTTP endpoint. The app server owns authentication, token refresh, storage selection, and upstream request details.

Official references:

- [Codex app-server protocol](https://developers.openai.com/codex/app-server/)
- [Codex authentication and login caching](https://developers.openai.com/codex/auth/)
- [Codex pricing and usage limits](https://developers.openai.com/codex/pricing/)

Validated on 2026-08-24 with Codex CLI 0.149.1. A read-only local probe returned the documented rate-limit response plus the schema's `individualLimit` spend-control data. Treat fields as optional and capability-check the installed CLI because Codex can evolve independently of ClaudeMonitor.

## Why app-server is the right boundary

The existing Claude integration reads Claude Code credentials because Claude has no equivalent local usage API. Codex does:

- `account/rateLimits/read` returns the current ChatGPT rate-limit snapshot.
- `rateLimitsByLimitId` supports more than one metered bucket.
- rate-limit windows contain used percentage, duration, and reset time.
- the response can include plan, credits, reached-limit state, spend-control state, and an individual monthly limit.
- Codex can store credentials either in `CODEX_HOME/auth.json` or an OS credential store. Reading `auth.json` would therefore be incomplete as well as unnecessarily sensitive.

This also keeps ClaudeMonitor out of Codex's refresh-token lifecycle.

## Current Claude usage architecture

The relevant existing path is:

```text
UsageAccountConfig.discover()
  -> UsagePoller
     -> ClaudeCodeKeychain
     -> Anthropic OAuth usage endpoint
  -> [AccountUsage]
  -> UsagePanelView
  -> UsageSnapshotStore -> WidgetKit
  -> UsageBridgeServer -> ESP32
```

Important constraints:

- `UsagePoller` is currently Claude-specific and owns networking, OAuth refresh, formatting, and aggregation.
- `AccountUsage` assumes exactly three display slots: session, weekly, and model.
- `AccountUsage`'s snake-case fields are a published compatibility surface for the ESP32 firmware and existing widget snapshots. Existing keys must not be renamed or removed.
- `UsageSnapshotStore` must remain App Group nil-safe.
- The widget renders snapshots only; it must never launch Codex or read credentials.
- `ConfigDirectoryDiscovery.scan()` intentionally returns Claude directories only. Codex discovery must use `scanCodex()` so Claude-specific consumers never receive Codex directories accidentally.

## Expected Codex response

The app-server request is newline-delimited JSON. The wire form intentionally omits the JSON-RPC `jsonrpc` member.

```json
{"method":"initialize","id":0,"params":{"clientInfo":{"name":"claude_monitor","title":"Claude Monitor","version":"<app-version>"}}}
{"method":"initialized","params":{}}
{"method":"account/rateLimits/read","id":1}
```

The response shape to support is conceptually:

```json
{
  "id": 1,
  "result": {
    "rateLimits": {
      "limitId": "codex",
      "limitName": null,
      "primary": {
        "usedPercent": 25,
        "windowDurationMins": 10080,
        "resetsAt": 1788164537
      },
      "secondary": null,
      "individualLimit": {
        "limit": "2000",
        "used": "125",
        "remainingPercent": 94,
        "resetsAt": 1788220800
      },
      "credits": {
        "hasCredits": true,
        "unlimited": false,
        "balance": null
      },
      "spendControlReached": false,
      "planType": "team",
      "rateLimitReachedType": null
    },
    "rateLimitsByLimitId": {
      "codex": {}
    },
    "rateLimitResetCredits": null
  }
}
```

All nested fields other than the matching response ID should be decoded defensively. Notifications can arrive before the requested response and must be ignored or handled separately.

## Proposed design

### 1. Make usage accounts provider-aware

Extend the account configuration model with a provider:

```swift
enum UsageProvider: String, Codable {
    case claude
    case codex
}

struct UsageAccountConfig: Identifiable, Equatable {
    let provider: UsageProvider
    let name: String
    let configDir: String

    var id: String { "\(provider.rawValue):\(configDir)" }
}
```

Discovery should combine:

- Claude: `ConfigDirectoryDiscovery.scan(home:)`
- Codex: `ConfigDirectoryDiscovery.scanCodex(home:)`

Name derivation:

- `.claude` -> `claude`
- `.claudewho-work` -> `work`
- `.codex` -> `codex`
- `.codexwho-work` -> `work`

Provider-qualified IDs prevent Claude and Codex accounts with the same display name from colliding. Existing preference dictionaries can remain keyed by absolute config-directory path because those paths are distinct.

### 2. Split fetching from aggregation

Refactor the monolithic poller behind a small fetch boundary. One possible shape is:

```swift
protocol UsageFetching {
    func fetch(account: UsageAccountConfig) async throws -> AccountUsage
}

struct ClaudeUsageFetcher: UsageFetching { /* current OAuth behavior */ }
struct CodexUsageFetcher: UsageFetching { /* app-server client */ }
```

`UsagePoller` remains the `@MainActor` owner of:

- the poll timer;
- display sleep state;
- ordered account aggregation;
- `updatedAt`;
- the single consistent snapshot publication hook.

It selects the correct fetcher by provider. Errors are isolated per account so one failed Codex process does not suppress successful Claude results.

Keep the initial poll interval at 180 seconds. Claude requires this interval, and the same cadence avoids unnecessary Codex subprocess and upstream churn.

### 3. Add `CodexAppServerClient`

Responsibilities:

- Resolve the Codex executable.
- Launch a `Process` with `CODEX_HOME` set to the account's config directory.
- Keep the rest of the inherited environment intact.
- Connect pipes for stdin, stdout, and stderr.
- Send the handshake and rate-limit request as JSONL.
- Parse stdout incrementally by newline.
- Correlate responses by request ID; do not assume the next line is the response.
- Ignore unrelated notifications such as `remoteControl/status/changed`.
- Enforce a short overall timeout, initially 10 seconds.
- Close stdin and terminate the child after success, timeout, or failure.
- Cap captured stderr and user-visible errors to avoid unbounded or sensitive diagnostic output.
- Prevent overlapping requests for the same account.

Do not log stdout wholesale: future responses or notifications may contain account-specific information.

#### Executable discovery

A macOS GUI app may have a minimal `PATH`. Resolve in this order:

1. A future explicit user-configured Codex path, if introduced.
2. The app environment's `PATH`.
3. Common locations such as `/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, and `~/.local/bin/codex`.
4. A non-interactive login-shell lookup as a final fallback, with a timeout.

Return an actionable per-account error if no executable is found.

Do not hardcode the currently installed Homebrew cask path containing a version number.

### 4. Decode Codex data into a flexible metric model

The current three fixed fields cannot faithfully represent arbitrary Codex buckets. Add an additive metric representation:

```swift
struct UsageMetric: Codable, Hashable, Identifiable {
    var id: String
    var label: String
    var usedPct: Int
    var resetsAt: String?
    var detail: String?
}
```

Add to `AccountUsage`:

- `provider`, defaulting to `.claude` when absent;
- `metrics`, defaulting to a reconstruction of the legacy fields when absent.

Use a custom decoder so schema-v1 snapshots continue to load. Encoding must retain every existing field and add the new fields. Bump `UsageSnapshot.schemaVersion` to 2.

#### Codex metric mapping

Prefer `rateLimitsByLimitId` when non-empty; otherwise use the legacy `rateLimits` object.

For every snapshot:

1. Collect non-null `primary` and `secondary` windows.
2. Deduplicate identical windows within a limit bucket.
3. Label from `limitName` when it is meaningful.
4. Otherwise classify by duration:
   - up to 360 minutes: `SESSION`;
   - approximately seven days: `WEEKLY`;
   - other durations: a neutral duration-derived label, not a guessed product name.
5. Convert Unix reset seconds to an ISO-8601 string.
6. Clamp backend percentages to the display range `0...100`.

For `individualLimit`:

- label it `MONTHLY` only when its reset cadence/boundary supports that interpretation;
- calculate consumed percentage as `100 - remainingPercent`;
- preserve `used` and `limit` in `detail`, for example `125 / 2000`;
- retain its reset timestamp;
- if cadence cannot be inferred safely, label it `INDIVIDUAL` rather than guessing.

Use plan type as the account plan label. Surface `spendControlReached` and `rateLimitReachedType` as an exhausted/error state without discarding the last valid percentages.

Credit balance and free reset-credit redemption are out of scope for the first version. The monitor is read-only and must never consume a reset credit.

### 5. Preserve legacy ESP32 fields

The firmware ignores unknown JSON keys but depends on the existing ones. Continue populating:

| Legacy field | Claude mapping | Codex mapping |
| --- | --- | --- |
| `session_*` | Five-hour/session window | Shortest ordinary window, otherwise idle |
| `weekly_*` | Seven-day window | Seven-day ordinary window, otherwise idle |
| `model_*` | Model-scoped weekly cap | Monthly/individual limit |
| `model_label` | Model display name | `MONTHLY` or `INDIVIDUAL` |

The new `metrics` array is authoritative for native UI. Legacy fields remain an adapter for existing displays and old snapshots.

### 6. Update native UI and settings

Usage settings:

- Rename "Show Claude usage limits" to "Show usage limits".
- Describe both collection methods without claiming that Codex credentials are read.
- Show a provider badge beside each discovered account.
- Preserve reorder, rename, and disable behavior.
- Explain that Codex usage tracking requires ChatGPT authentication.
- If app-server reports an API-key login, show that ChatGPT plan limits are unavailable because API usage is billed separately.

Floating panel:

- Render `metrics` dynamically rather than hardcoding three cells.
- Keep a practical maximum per row and wrap or adapt when more buckets exist.
- Show provider and plan in the account header.
- Continue showing account-local errors without hiding other accounts.

Widget:

- Small: first two prioritized metrics.
- Medium: first three prioritized metrics.
- Large: the same account count limit as today, with up to three prioritized metrics per account unless layout testing supports more.
- Priority: session, weekly, monthly/individual, then named extra buckets.
- Continue deriving reset labels from `entry.date`, never `Date()`.
- Continue reading only `UsageSnapshotStore`.

Empty-state copy should refer to usage accounts rather than only Claude Code.

### 7. Error behavior

Map failures to concise messages:

| Condition | Display behavior |
| --- | --- |
| Codex executable missing | `Codex CLI not found` |
| App-server method unavailable | `Update Codex to track usage` |
| API-key authentication | `ChatGPT login required for plan limits` |
| Logged out/unauthorized | `Sign in to Codex again` |
| Timeout/process exit | `Codex usage request failed` |
| Partial or unknown fields | Display valid metrics and omit unsupported ones |

Do not clear a successful Claude account because a Codex account failed. A later enhancement may retain each account's last successful values during transient errors; that is not required for the first delivery.

## File-level implementation map

Expected new files:

- `App/Core/Usage/CodexAppServerClient.swift`
- `App/Core/Usage/ClaudeUsageFetcher.swift` if the current logic is extracted
- `App/Core/Usage/CodexUsageFetcher.swift`

Expected modified files:

- `App/Models/UsageAccountConfig.swift`
- `App/Models/UsageModels.swift`
- `App/Core/Usage/UsagePoller.swift`
- `App/Core/Usage/UsageFormatting.swift`
- `App/UI/UsagePanelView.swift`
- `App/UI/UsageSettingsView.swift`
- `Widget/UsageWidgetView.swift`
- `Widget/UsageTimelineProvider.swift`
- `App/AppDelegate.swift`
- `App/Settings/Preferences.swift` only if provider-specific preferences become necessary
- `project.yml` if shared/new files need explicit widget or test target membership
- `CLAUDE.md` and `README.md` after behavior is implemented

Do not add app-server or credential code to the widget target.

## Test plan

### Pure model and mapping tests

- Decode a rate-limit response with a five-hour primary and weekly secondary.
- Decode a weekly-only response.
- Decode `individualLimit` and convert remaining percentage to used percentage.
- Verify Unix timestamps become correct ISO reset values.
- Prefer `rateLimitsByLimitId` over the backward-compatible single snapshot.
- Preserve separately named buckets.
- Handle null/missing duration and reset fields.
- Clamp invalid percentages.
- Verify provider-qualified account identity.

### App-server client tests

Use an injected process/transport boundary rather than launching the real CLI in unit tests:

- Handshake and request serialization.
- Initialization response followed by unrelated notifications.
- Fragmented JSONL reads.
- Multiple lines in one read.
- Response-ID correlation.
- Malformed line followed by a valid response.
- EOF before response.
- Non-zero process exit.
- Timeout and child termination.
- Bounded stderr/error text.
- Environment contains the requested `CODEX_HOME` without losing required inherited variables.

### Discovery and preference tests

- Discover both standard and Codexwho-style Claude and Codex directories.
- Preserve the deliberate separation between `scan()` and `scanCodex()`.
- Order, rename, and disable mixed-provider accounts.
- Avoid collisions for accounts sharing a display name.

### Snapshot compatibility tests

- Decode schema-v1 snapshots without provider or metrics.
- Encode every existing firmware key unchanged.
- Encode schema version 2 and additive provider/metric fields.
- Round-trip mixed Claude and Codex accounts through `UsageSnapshotStore`.

### UI/widget tests

- Metric prioritization for small and medium widgets.
- Weekly-plus-monthly Codex layout.
- Error account alongside successful accounts.
- Stale snapshot behavior remains unchanged.

### Optional integration test

Add an opt-in test, skipped unless an environment flag is present, that invokes the installed Codex app server and asserts only structural properties. It must not print the response or assert the developer's real percentages, plan, credit balance, or reset times.

## Delivery phases

### Phase 1: Provider-aware foundation

- Add `UsageProvider` and provider-qualified IDs.
- Discover mixed Claude/Codex usage accounts.
- Add flexible metrics with schema-v1 decoding.
- Preserve and test the ESP32 compatibility fields.

### Phase 2: Codex collection

- Implement executable discovery and `CodexAppServerClient`.
- Extract provider fetchers from `UsagePoller`.
- Decode and map ordinary and individual limits.
- Add per-account error isolation and tests.

### Phase 3: Presentation and documentation

- Update settings copy and provider badges.
- Render flexible metrics in the panel and widget.
- Update placeholder/widget fixtures.
- Update README and architecture notes.
- Run the full unit suite and the opt-in integration smoke test.

## Acceptance criteria

- Enabling usage monitoring shows discovered Claude and Codex accounts together.
- A ChatGPT-authenticated Codex account displays every useful ordinary window returned by app-server and its monthly/individual spend-control percentage when present.
- Claude behavior and its token-refresh path remain unchanged.
- Codex credentials are never read, copied, logged, or refreshed by ClaudeMonitor.
- API-key Codex accounts fail gracefully with an actionable explanation.
- One provider/account failure does not suppress other accounts.
- Existing widget snapshots decode successfully.
- Existing ESP32 firmware continues receiving all original JSON keys with compatible meanings.
- The widget remains snapshot-only and App Group nil-safe.
- The implementation does not redeem credits or mutate Codex account state.
- Unit tests cover protocol parsing, mapping, discovery, compatibility, and failure paths.

## Open questions to resolve during implementation

1. Whether to keep one short-lived app-server per poll or maintain a process per account. Start short-lived for isolation and simplicity; measure before optimizing.
2. Whether accounts can return enough metrics to require horizontal scrolling or wrapping in the floating panel. Implement deterministic prioritization before changing the panel size.
3. Whether `individualLimit` always represents a monthly period across eligible plans. Infer from reset cadence and fall back to `INDIVIDUAL` when uncertain.
4. Whether a minimum Codex version should be advertised. Prefer capability detection of `account/rateLimits/read`; add a version hint only if real compatibility testing establishes a reliable cutoff.
5. Whether credit balances belong in the first release. They are intentionally excluded unless the percentage limits prove insufficient in actual use.

