#!/bin/bash
# claude-monitor hook — installed to ~/.claude-monitor/hook.sh
# Invoked by Claude Code for SessionStart, UserPromptSubmit, Stop, Notification, SessionEnd.
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

# Context capture
TTY_VAL="$(tty 2>/dev/null)"
[ -n "$TTY_VAL" ] && [ "$TTY_VAL" != "not a tty" ] || TTY_VAL=""
PID_VAL="$PPID"   # the claude process that invoked us
CWD_VAL="$(pwd)"
TS_VAL="$(date +%s)"
export HOOK_NAME STDIN_JSON TTY_VAL PID_VAL CWD_VAL TS_VAL

# Build JSON — use python for safe escaping if available, otherwise a minimal fallback.
if command -v python3 >/dev/null 2>&1; then
  PAYLOAD="$(PYTHONIOENCODING=utf-8 python3 - <<PY
import json, os, sys
try:
    src = json.loads(os.environ.get("STDIN_JSON") or "{}")
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
preview = src.get("prompt") or src.get("user_prompt")
if isinstance(preview, str):
    out["prompt_preview"] = preview[:120]
tool = src.get("tool_name")
if isinstance(tool, str):
    out["tool_name"] = tool
print(json.dumps(out))
PY
)"
else
  # Minimal fallback: no prompt_preview, best-effort.
  SID="$(echo "$STDIN_JSON" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  PAYLOAD=$(cat <<EOF
{"hook":"$HOOK_NAME","session_id":"$SID","tty":"$TTY_VAL","pid":$PID_VAL,"cwd":"$CWD_VAL","ts":$TS_VAL}
EOF
)
fi

curl -s -m 2 -X POST -H "Content-Type: application/json" \
  --data-binary "$PAYLOAD" \
  "http://127.0.0.1:${PORT}/event" >/dev/null 2>&1

exit 0
