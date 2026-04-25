# Menu-Bar Cards — Design

**Date:** 2026-04-25
**Status:** Design approved, ready for implementation planning
**Platform:** macOS 14+, AppKit/SwiftUI

## 1. Purpose

Let users hide the floating dashboard window and surface the same session
information inside the menu-bar status item's dropdown menu. Useful for users
who don't want a persistent floating window taking screen real estate, or who
hit window-position glitches across multi-monitor sleep/wake cycles.

This is an opt-in mode toggled from the existing status-bar menu. The default
behavior (window visible, menu minimal) is unchanged.

## 2. User experience

### 2.1 Toggle

A single checkbox-style item — **"Show Dashboard Window"** — appears in the
status-bar menu. The checkmark reflects current state; activating the item
flips it. Default: checked.

### 2.2 Menu shape

**Window mode (toggle ON, default):**

```
Open Dashboard           ⌘D
✓ Show Dashboard Window
─────
Settings…                ⌘,
─────
Quit Claude Monitor      ⌘Q
```

**Menu mode (toggle OFF):**

```
● project-a  ·  Needs You · 0:42
● project-b  ·  Working · 2:14
● project-c  ·  Waiting · 0:08
─────
  Show Dashboard Window
─────
Settings…                ⌘,
─────
Quit Claude Monitor      ⌘Q
```

When in menu mode and there are no sessions, a single disabled row
**"No active sessions"** stands in for the session list.

`Open Dashboard` is hidden in menu mode (the toggle is the only on/off
control).

### 2.3 Session row

Standard `NSMenuItem`, no custom view:

- `image`: 14×14 filled circle in the state color (same color logic as the
  aggregate status icon — extracted into a shared helper).
- `title`: `"{projectName} · {stateLabel} · {M:SS}"`.
- `toolTip`: `session.lastPromptPreview` if present.
- Click → focuses the hosting terminal tab via the existing
  `CompositeTerminalBridge` path.

### 2.4 Live elapsed time

Elapsed values are recomputed in `NSMenuDelegate.menuNeedsUpdate(_:)` — the
canonical pre-display hook for mutating menu contents. The menu is rebuilt
from scratch on each open, so the toggle checkmark, session list, and elapsed
times all reflect current state without an explicit observer for each. No
timer ticks while the menu is open. Menus auto-close on activation, so
staleness is bounded to the duration the user holds the menu open. (If this
feels frozen in practice, a 1Hz `.common`-mode timer can be added later —
out of scope for v1.)

### 2.5 Window visibility

- Toggling OFF: dashboard window is hidden via the existing
  `DashboardWindow.hide()`.
- Toggling ON: dashboard window is shown and brought to front via
  `DashboardWindow.showAndBringToFront()`.
- App launch: both the no-onboarding `showAndBringToFront()` call in
  `applicationDidFinishLaunching` and the post-onboarding completion call
  inside `presentOnboarding` are gated on `preferences.showDashboardWindow`.
  If the toggle is OFF when the app starts, the window stays hidden and only
  the menu reflects sessions.

## 3. Architecture

### 3.1 Preference

`Preferences` gains:

```swift
@Published var showDashboardWindow: Bool {
    didSet { defaults.set(showDashboardWindow, forKey: Self.showWindowKey) }
}
```

Default value: `true`. Persisted to `UserDefaults` under a new key
`"showDashboardWindow"`. Loaded from defaults in `Preferences.init` (using
`object(forKey:) as? Bool` so a missing key defaults to `true`, not `false`).

### 3.2 MenuBarController

Gains:

- A new init parameter `onSessionClick: @escaping (Session) -> Void`.
- A reference to `Preferences` (passed in init).
- A single owned `NSMenu` instance (`statusItem.menu = menu` once at init)
  whose contents are cleared and rebuilt by `rebuildMenu()`.
- `NSMenuDelegate` conformance — `menuNeedsUpdate(_:)` calls `rebuildMenu()`
  so the toggle checkmark, session list, and elapsed values are all fresh
  on each open. No separate Combine subscription on the preference is
  needed inside the controller for menu refresh purposes; the AppDelegate
  owns the observer that hides/shows the floating window.

The existing `refresh(_:)` method (which paints the status icon) is kept
as-is; only the dropdown changes shape and now sources its color from
`SessionStateColor`.

### 3.3 AppDelegate wiring

- Pass `preferences` and a session-click closure (calling the existing
  `handleClick(on:)`) when constructing `MenuBarController`.
- Observe `preferences.$showDashboardWindow` and call
  `dashboard.hide()` / `dashboard.showAndBringToFront()` accordingly.
- Gate the post-onboarding `showAndBringToFront()` on
  `preferences.showDashboardWindow`.

### 3.4 Shared color helper

The status-icon painter (`MenuBarController.refresh`) currently inlines a
map from *aggregate* state (any-needsYou / any-waiting / any-working / idle)
to color. Extract a per-state helper used by both the status icon and the
per-session row image:

```swift
enum SessionStateColor {
    static func nsColor(for state: SessionState) -> NSColor { ... }
}
```

The status icon continues to compute its winning aggregate state (existing
priority: `needsYou` > `waiting` > `working` > idle) and then calls
`SessionStateColor.nsColor(for:)` to paint the dot. The per-row dot calls
the helper directly with the session's own state. Same hex values as today
(red `#EF4444`, amber `#F59E0B`, blue `#3B82F6`, gray `#6B7280`).

## 4. Touch points

- `App/Settings/Preferences.swift` — new `showDashboardWindow` published
  property + UserDefaults persistence.
- `App/UI/MenuBarController.swift` — dynamic menu assembly, session-click
  callback, `NSMenuDelegate.menuWillOpen` hook, color helper extraction.
- `App/AppDelegate.swift` — wire callback, observe preference, gate launch
  show.

No changes to `DashboardWindow`, `SessionStore`, `Session`, or any of the
hook/event pipeline.

## 5. Tests

No unit tests added. `MenuBarController` has no existing tests because
`NSMenu`/`NSStatusItem` are difficult to drive in unit tests, and the new
logic (menu assembly, preference observation) is shallow enough to verify
by inspection plus manual smoke testing on the running app.

If isolation becomes valuable later, the menu-assembly logic can be
extracted into a pure function returning a structured `[MenuRow]` and
tested without AppKit.

## 6. Out of scope

- A 1Hz live tick on the elapsed values while the menu is open.
- A Settings-pane mirror of the toggle. (The status menu is the single
  control surface for v1.)
- A "Both" mode where sessions appear in both the menu and the window.
- Any change to the floating window's positioning or appearance.
