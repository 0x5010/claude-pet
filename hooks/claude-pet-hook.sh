#!/bin/bash
# claude-pet-hook.sh <EventName>
# Reads stdin JSON from Claude Code, POSTs state to ClaudePet
EVENT="$1"

# Save stdin to temp file for reliable jq parsing
TMPJSON=$(mktemp /tmp/claude-pet-hook-XXXXXX)
cat > "$TMPJSON"

JQ=/opt/homebrew/bin/jq
jq_field() { "$JQ" -r "$1 // \"\"" < "$TMPJSON" 2>/dev/null; }

SESSION_ID=$(jq_field '.session_id')
# Fallback: extract session_id with sed if jq failed
[ -z "$SESSION_ID" ] && SESSION_ID=$(sed -n 's/.*"session_id" *: *"\([^"]*\)".*/\1/p' < "$TMPJSON")
[ -z "$SESSION_ID" ] && exit 0

CWD=$(jq_field '.cwd')
TRANSCRIPT=$(jq_field '.transcript_path')
TOOL=$(jq_field '.tool_name')
PROMPT=$(jq_field '.prompt' | head -c 200)
PERM=$(jq_field '.permission_mode')
MSG=""

case "$EVENT" in
  SessionStart)       STATE="idle" ;;
  UserPromptSubmit)   STATE="thinking" ;;
  PreToolUse)         STATE="working" ;;
  PostToolUseFailure) STATE="error" ;;
  SubagentStart)      STATE="juggling" ;;
  SubagentStop)       STATE="idle" ;;
  Notification)
    STATE="notification"
    MSG=$(jq_field '.message' | head -c 200)
    ;;
  Elicitation)
    STATE="notification"
    MSG="Needs your decision"
    ;;
  PermissionRequest)
    STATE="notification"
    MSG="Authorize: $TOOL"
    ;;
  Stop)
    STATE="idle"
    MSG=$(jq_field '.last_assistant_message' | tr '\n' ' ' | head -c 120)
    ;;
  SessionEnd)         STATE="sleeping" ;;
  *) rm -f "$TMPJSON"; exit 0 ;;
esac

rm -f "$TMPJSON"

# Build JSON with jq for safety (no manual escaping needed)
OUTJSON=$("$JQ" -n \
  --arg state "$STATE" \
  --arg session_id "$SESSION_ID" \
  --arg event "$EVENT" \
  --arg cwd "$CWD" \
  --arg transcript "$TRANSCRIPT" \
  --arg tool "$TOOL" \
  --arg prompt "$PROMPT" \
  --arg perm "$PERM" \
  --arg msg "$MSG" \
  '{state: $state, session_id: $session_id, event: $event, cwd: $cwd}
   + if $transcript != "" then {transcript_path: $transcript} else {} end
   + if $tool != "" then {tool_name: $tool} else {} end
   + if $prompt != "" then {prompt: $prompt} else {} end
   + if $perm != "" then {permission_mode: $perm} else {} end
   + if $msg != "" then {message: $msg} else {} end')

curl -s -m 1 -X POST "http://127.0.0.1:23333/state" \
  -H "Content-Type: application/json" \
  -d "$OUTJSON" \
  >/dev/null 2>&1 &
