# Codex Dashboard Support Plan

## Summary

Codex lifecycle hooks are the right primary integration for dashboard support. The initial implementation does not need transcript polling or a dedicated app-server daemon.

Codex provides the lifecycle events needed to mirror the existing Claude Code pipeline. Hooks receive information including the session ID, working directory, active model, and event-specific data. See the [official Codex hooks documentation](https://learn.chatgpt.com/docs/hooks).

## Event mapping

`codex-hook.sh` normalizes every Codex event into the dashboard's existing closed event vocabulary (`SessionStart`, `UserPromptSubmit`, `Stop`, `Notification`, `SessionEnd`) before POSTing. Codex has no `Notification` hook of its own; **Needs you** and the permission push are produced entirely by this normalization, so `StateMachine`, `PushNotifier`, and their table-driven tests stay untouched.

| Codex event | Normalized event posted | Dashboard behavior | Push notification |
| --- | --- | --- | --- |
| `SessionStart` | `SessionStart` | Create the card in **Waiting** | None |
| `UserPromptSubmit` | `UserPromptSubmit` | Set the card to **Working** | None |
| `Stop` | `Stop` | Set the card to **Waiting** | “Done” |
| `PermissionRequest` | `Notification` with `notification_type=permission_prompt` | Set the card to **Needs you** | “Permission needed” |
| `SessionEnd` | `SessionEnd` | Remove the card | None |

Codex `Stop` never posts `background_tasks` — that payload shape is a Claude Code detail — so a Codex `Stop` always lands in plain **Waiting**, never `backgroundWorking`.

We can optionally use `PreToolUse` and `PostToolUse` around `request_user_input` and approval-related tools. This would let a card enter **Needs you** while Codex awaits an answer and return to **Working** after the user responds (e.g. by normalizing `PostToolUse` to `UserPromptSubmit` without a prompt preview — to be validated in Phase 2).

## Recommended architecture

### 1. Identify the agent provider (decided)

Two complementary mechanisms:

- **Session-ID namespacing, done in the hook script.** `codex-hook.sh` posts `session_id` as `codex:<uuid>`. Claude IDs stay raw and unprefixed — the deployed `hook.sh` keeps working, persisted `ignoredSessionIds` need no migration, and `SessionStore` matching, ignore persistence, and ordering all work unchanged. Collisions between providers become impossible.
- **An optional `provider` field on `HookEvent` and `Session`** (`claude` | `codex`), decoded with a default of `claude` when the key is absent so older payloads keep decoding. This typed field — not string-prefix sniffing — is what the UI badge and any provider-aware logic read.

### 2. Add a Codex hook script

Deploy a separate script at:

```text
~/.claude-monitor/codex-hook.sh
```

The script should:

1. Read the Codex hook payload from standard input (`hook_event_name`, `session_id`, `cwd`, `model`, plus event-specific fields).
2. Extract the session ID, working directory, event name, prompt, and relevant approval information.
3. Capture the parent process ID and controlling TTY where available.
4. Translate the Codex event into the dashboard's normalized event format per the mapping table above, namespace the session ID as `codex:<uuid>`, and set `provider: "codex"`.
5. POST the event to the existing local `/event` endpoint.
6. Always exit successfully so monitoring failures never interfere with Codex.
7. **Never emit a hook decision.** Codex `PermissionRequest` hooks can allow or deny the request via JSON on stdout; ours must stay a pure observer — no output, so monitoring can never change Codex behavior.

**`SessionEnd` timing constraint:** Codex gives `SessionEnd` hooks a 1-second default timeout (3s max), while other events default to 600s. The installed `SessionEnd` entry must set `"timeout": 3` explicitly (or `"async": true`), and the script's curl timeout must fit inside that budget (the Claude `hook.sh` uses `curl -m 2`, which exceeds the 1s default) — otherwise card-removal events get killed mid-flight.

### 3. Install hooks into Codex configuration directories

Add a `CodexHookInstaller` that safely installs managed entries into:

- `~/.codex/hooks.json`
- Codexwho-style `~/.codexwho-*/hooks.json`

**Discovery marker:** Codex directories are identified by `config.toml` or `auth.json` — there is no `settings.json`. `ConfigDirectoryDiscovery.scan` and `HookInstaller` both hardcode `settings.json` today (`inspect`/`install`/`uninstall` all build the path from it), so the marker/target filename must become part of the installer `Kind` (or a parameter) rather than assumed.

**Real file shape:** `hooks.json` uses a top-level `"hooks"` wrapper keyed by event name, each holding matcher groups of `{ "hooks": [{ "type": "command", "command": ..., "timeout": ... }] }` — the same nesting as Claude Code's v2+ schema, but wrapped and in a dedicated file. Repo-level `<repo>/.codex/hooks.json` and inline hook tables in `config.toml` also exist and are merged with the user-level file, not replaced by it. See [hook discovery and configuration](https://learn.chatgpt.com/docs/hooks).

**Coexistence:** other tools already write managed entries here — on this machine, Orca installs its own `codex-hook.sh` hooks on 8 events in `~/.codex/hooks.json` (incidentally proving these events fire in practice). The installer must merge into a populated file and preserve every foreign entry.

The installer should:

- Preserve unrelated user and third-party hooks and configuration.
- Create a rolling backup named `hooks.json.claude-monitor.bak` — a plain `hooks.json.bak` **already exists** on disk (another tool's backup) and must not be clobbered.
- Be idempotent.
- Include a managed-by and schema-version marker in the command string (same arg-encoded scheme as v3 of the Claude installer, for the same re-serialization-safety reasons).
- Detect missing, outdated, and externally modified installations.
- Support clean uninstallation without touching user-owned or third-party hooks.

**Version requirement:** lifecycle hooks require Codex CLI ≥ 0.114 (0.149.1 is installed here). The settings UI can surface a hint when an older `codex` binary is detected, but this is optional.

### 4. Reuse the current event pipeline

After normalization, Codex events can use the existing application pipeline:

```text
Codex lifecycle hook
  -> codex-hook.sh
  -> POST /event
  -> EventServer
  -> SessionStore
  -> StateMachine
  -> dashboard and menu bar
  -> PushNotifier
```

The state machine and push policy should operate on normalized agent events rather than provider-specific hook names wherever practical. With the script-side normalization above, neither needs code changes for Phase 1/2.

**Keep Codex out of Claude-specific paths:**

- `background_tasks` / `backgroundWorking` is a Claude Code payload detail; `codex-hook.sh` never posts it.
- If `ConfigDirectoryDiscovery` is generalized, `UsageAccountConfig` (which derives usage-account display names from discovered `.claude`/`.claudewho-*` dirs) must keep seeing only Claude directories — Codex dirs have no Claude credentials and must not leak into the usage poller.

### 5. Identify Codex cards in the UI

Add a small Claude/Codex badge or icon to dashboard cards and menu rows. The existing state colors and elapsed-time behavior can remain unchanged.

Update empty-state and settings copy so it refers to both Claude Code and Codex sessions.

### 6. Make stale-session handling provider-aware

For Codex CLI sessions launched in a terminal, the hook script should normally be able to capture a useful PID and TTY. Existing process-liveness and click-to-focus behavior can then be reused.

Codex desktop or app-server sessions may not have a unique terminal process or controlling TTY. Those sessions should:

- Rely primarily on `SessionEnd` for removal.
- Skip PID-based stale sweeping when no meaningful PID is available.
- Disable terminal focusing or use a future Codex-specific focus action.

## Hook trust and installation UX

Codex requires users to review and trust newly installed, non-managed command hooks. After installation, the app should instruct the user to:

1. Start or restart Codex.
2. Run `/hooks`.
3. Review and trust the Claude Monitor hook entries.

Codex records trust against the hook definition's hash, so changing the command can require another review. The settings UI should make this requirement prominent after installation or reinstallation. See [hook review and trust](https://learn.chatgpt.com/docs/hooks).

The application should not bypass hook trust automatically.

## Push notifications

The existing in-app Prowl path can support Codex after events are normalized:

- `Stop` sends a completion notification.
- `PermissionRequest` arrives as `Notification` with `notification_type=permission_prompt`, so the existing permission-needed push fires with no `PushNotifier` changes.
- A user-input request can send a needs-input notification if that hook path proves reliable.
- Ignored-session and master-toggle behavior remains unchanged.

The offline Prowl script can be extended later with equivalent Codex hooks if notifications should continue while the dashboard application is closed.

### Why not use `notify` as the primary integration?

Codex has a user-level `notify` command setting, but it currently supports only `agent-turn-complete`. It is suitable for a simple completion alert, but it cannot reliably drive session creation or Working state. It is also a single command setting, making conflicts with existing user configuration more likely.

Lifecycle hooks provide the broader and more composable integration. See [Codex notification configuration](https://learn.chatgpt.com/docs/config-file/config-advanced#notifications).

## App-server as a future enhancement

The Codex app-server protocol exposes richer runtime information, including status changes such as `waitingOnApproval`, turn lifecycle events, and approval requests. This could provide more exact state reporting for Codex clients built on the app server. See [Codex app-server status events](https://learn.chatgpt.com/docs/app-server).

It is not the preferred initial integration because the dashboard would need to host or connect clients to that server. It does not automatically observe every independently launched Codex CLI process.

App-server support is therefore best treated as a later enhancement for Codex desktop, remote, or centrally managed sessions.

## Delivery phases

### Phase 1: Minimum viable Codex support

- Discover Codex configuration directories.
- Install `SessionStart`, `UserPromptSubmit`, `Stop`, and `SessionEnd` hooks.
- Show Codex cards with Waiting and Working states.
- Remove cards when sessions end.
- Send completion pushes through the existing Prowl pipeline.
- Identify the provider on cards and menu rows.

### Phase 2: Attention states

- Install `PermissionRequest` hooks (normalized to `Notification`/`permission_prompt` by the script; the hook must abstain from allow/deny decisions).
- Verify permission-needed pushes flow through the unchanged `PushNotifier`.
- Investigate `request_user_input` through `PreToolUse` and `PostToolUse`.
- Ensure **Needs you** returns to **Working** after approval or input is resolved.
- Prevent duplicate notifications during repeated approval events.

### Phase 3: Rich Codex integration

- Investigate Codex desktop and shared app-server sessions.
- Consume exact runtime status and approval flags where available.
- Add Codex-specific click-to-focus or open-session behavior.
- Support remote or centrally hosted Codex sessions if desired.

## Primary risks and validation work

### PID and TTY capture

Prototype parent-process and TTY discovery in:

- Terminal.app
- iTerm2
- Orca
- Codex desktop, if hooks run there

The status integration does not depend on terminal focus, but stale-session cleanup and card clicking do.

### Event ordering

Codex can run matching hooks concurrently, especially asynchronous hooks. The reporting hooks should either run synchronously with a short timeout or include timestamps and turn IDs so stale or reordered events cannot regress session state.

### Approval resolution

`PermissionRequest` precisely identifies when approval is needed, but hook events may not provide an equally direct “approval resolved” lifecycle event. `PostToolUse` is the likely recovery signal — the concrete candidate is normalizing it to `UserPromptSubmit` (no prompt preview) so the card returns to **Working** — although the card may remain in **Needs you** while an approved command executes. Note this matches Claude behavior today: a Claude card also stays **Needs you** until `Stop`. The app-server protocol can provide more exact behavior later.

### Session cleanup

Verify when `SessionEnd` fires for CLI exit, archive, delete, desktop sessions, and idle app-server sessions. Sessions without a unique PID must not be removed by the current PID-based stale sweeper.

## Test plan

- Codex hook payload decoding fixtures for every supported event.
- Provider-namespaced session identity tests.
- State transition tests for Waiting, Working, Needs you, and Finished.
- Codex installer tests covering preservation, backups, idempotency, upgrades, and uninstallation.
- Push tests for completion, permission, ignored sessions, and duplicate suppression.
- Stale-sweeper tests for sessions with and without meaningful PIDs.
- Terminal integration smoke tests for PID/TTY capture and click-to-focus.
- A manual trust-flow test using `/hooks` after installation and upgrade.

## Recommendation

Start with lifecycle hooks and reuse the existing local event server, state machine, and Prowl pipeline. This gives reliable Waiting/Working cards and completion notifications with a relatively small architectural change.

Treat app-server integration as a later path for richer approval state, Codex desktop support, and exact session control.
