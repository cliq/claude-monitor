# Background-working state — design

**Date:** 2026-06-25
**Status:** Approved (pending spec review)

## Problem

When a Claude Code session dispatches background work (background bash commands
*or* background subagents) and the main agent's turn ends, the session's `Stop`
hook fires. ClaudeMonitor treats every `Stop` as "the agent is idle", so the
tile turns amber **Waiting** and `PushNotifier` sends a premature "Done /
Waiting for you" push — even though the session is still actively working in the
background.

Worse, it repeats: each time a background task finishes, Claude Code injects a
synthetic `<task-notification>` **user** message (which fires `UserPromptSubmit`
→ `working`), the main agent reacts, and its turn ends again (`Stop` → `waiting`
→ another push). The user gets a burst of false "done" notifications while real
work is still running.

## Goal

Detect that a session is still working in the background and represent it as a
distinct state that does **not** fire an idle push. Only notify when the session
is *genuinely* idle (main agent stopped **and** no background tasks remain).

Non-goals: tracking individual background tasks/agents, correlating subagents to
parents, surfacing per-task progress. Out of scope for this change.

## Detection signal (empirically verified)

On Claude Code 2.1.191 the `Stop` hook payload self-reports live background work.
Captured payload (background bash command still running):

```json
{
  "hook_event_name": "Stop",
  "session_id": "…",
  "stop_hook_active": false,
  "last_assistant_message": "Dispatched in the background. Task id: …",
  "background_tasks": [
    {
      "id": "byr8qn5qm",
      "type": "shell",
      "status": "running",
      "description": "Sleep 20 seconds then echo done",
      "command": "sleep 20 && echo done"
    }
  ],
  "session_crons": []
}
```

Key facts established by experiment + docs:

- Background bash **and** background subagents share one "task" system
  (`<task-id>` / `<task-notification>`). The `type` field distinguishes them
  (`"shell"`, agent types use a different value). We therefore key off `status`,
  **not** `type`, so the rule is agnostic to task kind.
- `TaskCreated` / `TaskCompleted` hooks do **not** fire for background bash, so
  an event-counting approach would be incomplete and fragile.
- The `background_tasks` array is present on the `Stop` payload we already
  receive, so detection needs **no new hook registrations** and **no stateful
  counting** — each `Stop` re-derives the truth.

### Rejected alternatives

- **Event counting** via `SubagentStart/Stop` + `TaskCreated/Completed`:
  stateful, drifts on missed events / app restart / races, and `TaskCreated`
  misses background bash. Rejected.
- **Transcript tailing** (`transcript_path` is in every payload): robust but
  heavy (parse JSONL each `Stop`), brittle (undocumented format), and
  unnecessary given the `Stop` payload already carries the data. Rejected.

## Detection rule

A background task is **active** when its `status` is non-terminal — anything
other than `completed`, `failed`, or `cancelled` (treat unknown/missing status
as active to stay on the safe side). Define:

```
backgroundTasksActive = count of background_tasks whose status is non-terminal
```

On a `Stop` hook:
- `backgroundTasksActive > 0` → state `backgroundWorking` (no push)
- `backgroundTasksActive == 0` → state `waiting` (push, as today)

This is stateless and self-healing: a session cannot get stuck silently in
`backgroundWorking`, and the app recovers correctly even if it launches while
background work is already in flight — the next `Stop` tells the truth.

## Changes

### `scripts/hook.sh`

In the Python payload builder, parse `background_tasks` from the incoming hook
JSON and emit a single integer field `background_tasks_active` = count of
entries whose `status` is not in `{completed, failed, cancelled}`. Only the
count is sent — `command`/`description` strings (potentially sensitive) stay off
the wire. Keep the existing minimal `sed` fallback unchanged (it omits the
field; absence is treated as 0). The field is only meaningful for `Stop` but may
be emitted whenever present.

No `HookInstaller.currentVersion` bump: the managed `settings.json` command
string is unchanged, and `HookScriptDeployer.deploy` overwrites
`~/.claude-monitor/hook.sh` from the bundle on every launch.

### `HookEvent` (`App/Models/HookEvent.swift`)

Add `let backgroundTasksActive: Int?` with coding key `background_tasks_active`.
Optional → decodes to `nil` for older hook scripts / non-`Stop` events.

### `SessionState` (`App/Models/SessionState.swift`)

Add a fifth case: `case backgroundWorking = "backgroundWorking"`. It is a normal
(non-absorbing) state like `working`/`waiting`.

### `StateMachine` (`App/Core/StateMachine.swift`)

Keep it a pure function. Extend the signature to take the active count, e.g.:

```swift
static func transition(from current: SessionState?,
                       for hook: HookName,
                       backgroundTasksActive: Int = 0) -> SessionState
```

`finished` stays absorbing. On `.stop`: return `.backgroundWorking` if
`backgroundTasksActive > 0`, else `.waiting`. All other transitions unchanged.
`SessionStore.apply` passes `event.backgroundTasksActive ?? 0`.

### `SessionStore` (`App/Core/SessionStore.swift`)

When a `Stop` event arrives, persist the active count on the `Session` so the
tile can show it (add `backgroundTaskCount: Int` to `Session`, default 0; set it
from the event on every apply, clearing to 0 when not a background `Stop`).

### `SessionStateColor` (`App/Models/SessionStateColor.swift`)

Add `backgroundWorking` → a **dimmed blue** (same hue family as `working`'s
`#3B82F6`, darker/desaturated). Proposed `#1E40AF` (tunable during
implementation). Update any exhaustive `switch` over `SessionState`.

### Tile / dashboard UI

- Render `backgroundWorking` with the dimmed-blue color.
- Label shows the active count, e.g. `Working · 2 tasks` (singular "1 task").
  Reuse the existing 1 Hz elapsed-time timer; no per-tile timer.
- Confirm any other `SessionState` switches (menu-bar aggregate "winning state",
  badges) handle the new case. The aggregate ordering should rank
  `backgroundWorking` as an active state (alongside `working`).

### `PushNotifier` (`App/Core/PushNotifier.swift`)

Suppress the idle push for background `Stop`s:

```swift
guard event.hook == .stop || event.hook == .notification else { return Task {} }
if event.hook == .stop, (event.backgroundTasksActive ?? 0) > 0 { return Task {} }
```

The genuinely-idle `Stop` (empty `background_tasks`) still pushes as today. The
`.notification` path (`needsYou`) is unchanged.

## Testing

- **`StateMachineTests`**: `Stop` with `backgroundTasksActive > 0` →
  `backgroundWorking`; `Stop` with `0` → `waiting`; `backgroundWorking` then a
  user prompt → `working`; `finished` remains absorbing.
- **`PushNotifierTests`**: `Stop` with active background tasks → no send; `Stop`
  with zero → send; `.notification` → send (unchanged).
- **`hook.sh`**: a small parse check (feed a JSON payload with a `running` and a
  `completed` task → `background_tasks_active == 1`; empty/missing array → 0).
- **`SessionStore`**: applying a background `Stop` sets state + count;
  a later zero-task `Stop` clears to `waiting` with count 0.

## Risks & mitigations

- **`status` vocabulary may include values we don't know** → treat any
  non-terminal/unknown status as active (fail toward "still working", never
  toward a false idle push).
- **Background subagent `type` string unconfirmed** (couldn't reproduce a
  background *agent* headlessly) → irrelevant: the rule keys off `status`, not
  `type`. Verify the agent case manually once during implementation.
- **Future Claude Code drops/renames `background_tasks`** → field is optional;
  absence ⇒ count 0 ⇒ current behavior. Graceful degradation.
