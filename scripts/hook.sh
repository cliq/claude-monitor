#!/bin/bash
# claude-monitor hook — installed to ~/.claude-monitor/hook.sh
# Invoked for SessionStart, UserPromptSubmit, PostToolUse, Stop, Notification, SessionEnd.
# Reads hook JSON on stdin, enriches, POSTs to the local Claude Monitor server.
# Always exits 0 so hook failures can never affect the Claude session.

set +e

HOOK_NAME="${1:-unknown}"
PORT_FILE="$HOME/.claude-monitor/port"
[ -f "$PORT_FILE" ] || exit 0
PORT="$(tr -d ' \n\r' < "$PORT_FILE")"
[ -n "$PORT" ] || exit 0

# Read stdin payload from Claude Code. May be empty (no JSON guaranteed).
STDIN_JSON="$(cat 2>/dev/null)"
[ -n "$STDIN_JSON" ] || STDIN_JSON="{}"

# Context capture.
# TTY: Claude Code invokes us with the hook JSON piped on stdin, so `tty` on our
# own fd never works. Ask the kernel for the parent claude CLI's controlling
# terminal instead — that's the ttys device backing the Terminal.app tab.
TTY_RAW="$(ps -o tty= -p "$PPID" 2>/dev/null | awk '{print $1}')"
case "$TTY_RAW" in
  ""|\?|\?\?)   TTY_VAL="" ;;
  /dev/*)       TTY_VAL="$TTY_RAW" ;;
  tty*)         TTY_VAL="/dev/$TTY_RAW" ;;
  s[0-9]*|p[0-9]*) TTY_VAL="/dev/tty$TTY_RAW" ;;
  *)            TTY_VAL="/dev/$TTY_RAW" ;;
esac
PID_VAL="$PPID"   # the claude process that invoked us
CWD_VAL="$(pwd)"
TS_VAL="$(date +%s)"
export HOOK_NAME TTY_VAL PID_VAL CWD_VAL TS_VAL

# Build JSON — use python for safe escaping if available, otherwise a minimal fallback.
if command -v python3 >/dev/null 2>&1; then
  # Tool results can exceed the OS environment-size limit. Pipe the JSON instead.
  PAYLOAD="$(printf '%s' "$STDIN_JSON" | PYTHONIOENCODING=utf-8 python3 -c '
import json, os, sys
try:
    src = json.load(sys.stdin)
except Exception:
    src = {}
out = {
    "hook":            os.environ.get("HOOK_NAME", "unknown"),
    "session_id":      src.get("session_id") or os.environ.get("CLAUDE_SESSION_ID", ""),
    "tty":             os.environ.get("TTY_VAL", ""),
    "pid":             int(os.environ.get("PID_VAL", "0")),
    "cwd":             os.environ.get("CWD_VAL", ""),
    "ts":              int(os.environ.get("TS_VAL", "0")),
}
source = src.get("source")
if out["hook"] == "SessionStart" and isinstance(source, str):
    out["source"] = source
transcript = src.get("transcript_path")
if isinstance(transcript, str):
    out["transcript_path"] = transcript
preview = src.get("prompt") or src.get("user_prompt")
if out["hook"] == "UserPromptSubmit" and isinstance(preview, str) and not preview.lstrip().startswith("<task-notification>"):
    out["prompt_preview"] = preview[:120]
tool = src.get("tool_name")
if isinstance(tool, str):
    out["tool_name"] = tool
notif_type = src.get("notification_type")
if isinstance(notif_type, str):
    out["notification_type"] = notif_type
msg = src.get("message")
if isinstance(msg, str):
    out["message"] = msg
bg = src.get("background_tasks")
if isinstance(bg, list):
    # Only count work that will eventually wake the session (subagents, shell jobs,
    # workflows, cloud sessions...). Monitors -- artifact live-update watches and the
    # Monitor tool -- are open-ended and may never fire; counting them parks the tile
    # in "Working" forever because they may never publish a completion.
    terminal = {"completed", "failed", "cancelled", "canceled", "killed", "stopped"}
    passive_types = {"monitor", "monitor_ws", "monitor_mcp"}
    active = [
        t for t in bg
        if isinstance(t, dict)
        and str(t.get("status", "")).lower() not in terminal
        and str(t.get("type", "")).lower() not in passive_types
    ]
    out["background_tasks_active"] = len(active)
    # Keep identities so the app can reconcile cancellations recorded in the
    # transcript even when Claude does not emit another Stop hook.
    out["background_task_ids"] = list(dict.fromkeys(
        t["id"] for t in active if isinstance(t.get("id"), str) and t["id"]
    ))
print(json.dumps(out))
'
)"
else
  # Minimal fallback: no prompt_preview, best-effort.
  SID="$(echo "$STDIN_JSON" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  SOURCE="$(printf '%s' "$STDIN_JSON" | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  case "$SOURCE" in startup|resume|clear|compact) ;; *) SOURCE="" ;; esac
  PAYLOAD=$(cat <<EOF
{"hook":"$HOOK_NAME","session_id":"$SID","tty":"$TTY_VAL","pid":$PID_VAL,"cwd":"$CWD_VAL","ts":$TS_VAL,"source":"$SOURCE"}
EOF
)
fi

curl -s -m 2 -X POST -H "Content-Type: application/json" \
  --data-binary "$PAYLOAD" \
  "http://127.0.0.1:${PORT}/event" >/dev/null 2>&1

exit 0
