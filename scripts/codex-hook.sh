#!/bin/bash
# claude-monitor Codex hook — installed to ~/.claude-monitor/codex-hook.sh
# Invoked by Codex CLI for SessionStart, UserPromptSubmit, Stop, PermissionRequest, SessionEnd.
# Normalizes each Codex event into Claude Monitor's event vocabulary
# (PermissionRequest becomes Notification/permission_prompt), namespaces the
# session id as "codex:<id>", and POSTs to the local Claude Monitor server.
#
# This script must stay a pure observer: Codex treats JSON printed by a
# PermissionRequest hook as an allow/deny decision, so nothing may ever reach
# stdout, and it always exits 0 so monitoring can never affect the Codex session.

set +e

HOOK_NAME="${1:-unknown}"
PORT_FILE="$HOME/.claude-monitor/port"
[ -f "$PORT_FILE" ] || exit 0
PORT="$(tr -d ' \n\r' < "$PORT_FILE")"
[ -n "$PORT" ] || exit 0

# Read stdin payload from Codex. May be empty (no JSON guaranteed).
STDIN_JSON="$(cat 2>/dev/null)"
[ -n "$STDIN_JSON" ] || STDIN_JSON="{}"

# Context capture.
# TTY: the hook JSON is piped on stdin, so `tty` on our own fd never works. Ask
# the kernel for the parent codex process's controlling terminal instead.
TTY_RAW="$(ps -o tty= -p "$PPID" 2>/dev/null | awk '{print $1}')"
case "$TTY_RAW" in
  ""|\?|\?\?)   TTY_VAL="" ;;
  /dev/*)       TTY_VAL="$TTY_RAW" ;;
  tty*)         TTY_VAL="/dev/$TTY_RAW" ;;
  s[0-9]*|p[0-9]*) TTY_VAL="/dev/tty$TTY_RAW" ;;
  *)            TTY_VAL="/dev/$TTY_RAW" ;;
esac
PID_VAL="$PPID"   # the codex process that invoked us
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
sid = src.get("session_id")
if not isinstance(sid, str) or not sid:
    sys.exit(0)   # no session identity — nothing to report
hook = os.environ.get("HOOK_NAME") or src.get("hook_event_name") or "unknown"
out = {
    "provider":        "codex",
    "session_id":      "codex:" + sid,
    "tty":             os.environ.get("TTY_VAL", ""),
    "pid":             int(os.environ.get("PID_VAL", "0")),
    "cwd":             src.get("cwd") or os.environ.get("CWD_VAL", ""),
    "ts":              int(os.environ.get("TS_VAL", "0")),
}
tool = src.get("tool_name")
if isinstance(tool, str):
    out["tool_name"] = tool
if hook == "PermissionRequest":
    # Normalize to the Notification/permission_prompt shape the dashboard already
    # understands, so the state machine and push pipeline work unchanged.
    # (No apostrophes anywhere in this heredoc: macOS bash 3.2 quote-scans
    # heredoc content inside command substitution and chokes on unbalanced ones.)
    out["hook"] = "Notification"
    out["notification_type"] = "permission_prompt"
    msg = src.get("message")
    if not isinstance(msg, str) or not msg:
        msg = "Codex needs permission" + (f" to run {tool}" if isinstance(tool, str) and tool else "")
    out["message"] = msg
else:
    out["hook"] = hook
    preview = src.get("prompt") or src.get("user_prompt")
    if isinstance(preview, str):
        out["prompt_preview"] = preview[:120]
print(json.dumps(out))
PY
)"
  [ -n "$PAYLOAD" ] || exit 0
else
  # Minimal fallback: no prompt_preview, best-effort.
  SID="$(echo "$STDIN_JSON" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  [ -n "$SID" ] || exit 0
  if [ "$HOOK_NAME" = "PermissionRequest" ]; then
    PAYLOAD=$(cat <<EOF
{"hook":"Notification","provider":"codex","session_id":"codex:$SID","tty":"$TTY_VAL","pid":$PID_VAL,"cwd":"$CWD_VAL","ts":$TS_VAL,"notification_type":"permission_prompt","message":"Codex needs permission"}
EOF
)
  else
    PAYLOAD=$(cat <<EOF
{"hook":"$HOOK_NAME","provider":"codex","session_id":"codex:$SID","tty":"$TTY_VAL","pid":$PID_VAL,"cwd":"$CWD_VAL","ts":$TS_VAL}
EOF
)
  fi
fi

# SessionEnd hooks run under Codex's tight (max 3s) timeout — curl must fit inside it.
curl -s -m 2 -X POST -H "Content-Type: application/json" \
  --data-binary "$PAYLOAD" \
  "http://127.0.0.1:${PORT}/event" >/dev/null 2>&1

exit 0
