#!/bin/bash
# claude-pet-statusline.sh
# Reads Claude Code statusLine JSON from stdin, POSTs context info to ClaudePet.

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

JQ=/opt/homebrew/bin/jq
[ ! -x "$JQ" ] && exit 0

SESSION_ID=$(printf '%s' "$INPUT" | "$JQ" -r '.session_id // ""' 2>/dev/null)
[ -z "$SESSION_ID" ] && exit 0

USED_PCT=$(printf '%s' "$INPUT" | "$JQ" -r '.context_window.used_percentage // 0' 2>/dev/null)
MODEL_NAME=$(printf '%s' "$INPUT" | "$JQ" -r '.model.display_name // .model.id // ""' 2>/dev/null)
SESSION_NAME=$(printf '%s' "$INPUT" | "$JQ" -r '.session_name // .workspace.current_dir // .cwd // ""' 2>/dev/null)
CURRENT_USAGE=$(printf '%s' "$INPUT" | "$JQ" -c '.context_window.current_usage // 0' 2>/dev/null)

OUTJSON=$(
  "$JQ" -n \
    --arg session_id "$SESSION_ID" \
    --argjson used_percentage "$USED_PCT" \
    --arg model_name "$MODEL_NAME" \
    --arg session_name "$SESSION_NAME" \
    --argjson current_usage "$CURRENT_USAGE" \
    '{
      session_id: $session_id,
      context_window: {
        used_percentage: $used_percentage,
        current_usage: $current_usage
      },
      model: {
        display_name: $model_name
      },
      session_name: $session_name
    }'
)

curl -s -m 1 -X POST "http://127.0.0.1:23333/context" \
  -H "Content-Type: application/json" \
  -d "$OUTJSON" \
  >/dev/null 2>&1

printf ' '
