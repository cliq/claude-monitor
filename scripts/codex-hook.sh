#!/bin/bash
# claude-monitor Codex hook — installed to ~/.claude-monitor/codex-hook.sh
# Invoked for SessionStart, UserPromptSubmit, PostToolUse, Stop, PermissionRequest, SessionEnd.
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
# Since Codex 0.159 the TUI is a client of a shared `codex app-server` daemon
# (one per CODEX_HOME, started by whichever session came first), and hooks run
# as children of that daemon. Its pid is shared by every session and outlives
# them, it has no tty, and its environment belongs to the session that started
# it (e.g. a stale CHAUFFEUR_SESSION_URL), so it must never be reported. Codex
# does not tell hooks which client owns the thread, so look for the one TUI
# with the daemon's CODEX_HOME whose cwd is the session cwd. Zero or several
# matches report pid 0 rather than guess: a wrong pid would focus another
# session's terminal, or keep this tile alive after its TUI exits.
SOURCE_PID="$PPID"
# A per-task `codex app-server` over stdio (e.g. the Codex companion plugin)
# lives and dies with its session, so only the managed daemon is replaced.
if ps -o command= -p "$PPID" 2>/dev/null | grep -q 'app-server.*--managed-daemon'; then
  SOURCE_PID=0
  HOOK_CWD="$(pwd -P)"
  MATCHES=""
  while read -r CANDIDATE COMMAND; do
    case "${COMMAND%% *}" in */codex|codex) ;; *) continue ;; esac
    case "$COMMAND" in *app-server*) continue ;; esac
    CANDIDATE_ENV="$(ps eww -o command= -p "$CANDIDATE" 2>/dev/null) "
    if [ -n "${CODEX_HOME+set}" ]; then
      case "$CANDIDATE_ENV" in *" CODEX_HOME=$CODEX_HOME "*) ;; *) continue ;; esac
    else
      case "$CANDIDATE_ENV" in *" CODEX_HOME="*) continue ;; esac
    fi
    CANDIDATE_CWD="$(lsof -a -p "$CANDIDATE" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
    [ "$CANDIDATE_CWD" = "$HOOK_CWD" ] || continue
    MATCHES="$MATCHES $CANDIDATE"
  done < <(ps -axo pid=,command= 2>/dev/null)
  set -- $MATCHES
  [ "$#" -eq 1 ] && SOURCE_PID="$1"
fi

# TTY: the hook JSON is piped on stdin, so `tty` on our own fd never works. Ask
# the kernel for the codex process's controlling terminal instead.
TTY_RAW=""
[ "$SOURCE_PID" -gt 0 ] && TTY_RAW="$(ps -o tty= -p "$SOURCE_PID" 2>/dev/null | awk '{print $1}')"
case "$TTY_RAW" in
  ""|\?|\?\?)   TTY_VAL="" ;;
  /dev/*)       TTY_VAL="$TTY_RAW" ;;
  tty*)         TTY_VAL="/dev/$TTY_RAW" ;;
  s[0-9]*|p[0-9]*) TTY_VAL="/dev/tty$TTY_RAW" ;;
  *)            TTY_VAL="/dev/$TTY_RAW" ;;
esac
PID_VAL="$SOURCE_PID"   # the codex TUI, or 0 when it can't be identified
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
source = src.get("source")
if hook == "SessionStart" and isinstance(source, str):
    out["source"] = source
tool = src.get("tool_name")
if isinstance(tool, str):
    out["tool_name"] = tool
if hook == "PermissionRequest":
    # Normalize to the Notification/permission_prompt shape the dashboard already
    # understands, so the state machine and push pipeline work unchanged.
    out["hook"] = "Notification"
    out["notification_type"] = "permission_prompt"
    msg = src.get("message")
    if not isinstance(msg, str) or not msg:
        msg = "Codex needs permission" + (f" to run {tool}" if isinstance(tool, str) and tool else "")
    out["message"] = msg
else:
    out["hook"] = hook
    preview = src.get("prompt") or src.get("user_prompt")
    if hook == "UserPromptSubmit" and isinstance(preview, str):
        out["prompt_preview"] = preview[:120]
print(json.dumps(out))
'
)"
  [ -n "$PAYLOAD" ] || exit 0
else
  # Minimal fallback: no prompt_preview, best-effort.
  SID="$(echo "$STDIN_JSON" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  [ -n "$SID" ] || exit 0
  SOURCE="$(printf '%s' "$STDIN_JSON" | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  case "$SOURCE" in startup|resume|clear|compact) ;; *) SOURCE="" ;; esac
  if [ "$HOOK_NAME" = "PermissionRequest" ]; then
    PAYLOAD=$(cat <<EOF
{"hook":"Notification","provider":"codex","session_id":"codex:$SID","tty":"$TTY_VAL","pid":$PID_VAL,"cwd":"$CWD_VAL","ts":$TS_VAL,"notification_type":"permission_prompt","message":"Codex needs permission"}
EOF
)
  else
    PAYLOAD=$(cat <<EOF
{"hook":"$HOOK_NAME","provider":"codex","session_id":"codex:$SID","tty":"$TTY_VAL","pid":$PID_VAL,"cwd":"$CWD_VAL","ts":$TS_VAL,"source":"$SOURCE"}
EOF
)
  fi
fi

# SessionEnd hooks run under Codex's tight (max 3s) timeout — curl must fit inside it.
curl -s -m 2 -X POST -H "Content-Type: application/json" \
  --data-binary "$PAYLOAD" \
  "http://127.0.0.1:${PORT}/event" >/dev/null 2>&1

exit 0
