#!/bin/bash
# install.sh — Build, install ClawdBar to ~/.claude/clawd-bar/, register hooks + LaunchAgent
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="$HOME/.claude/clawd-bar"
SETTINGS="$HOME/.claude/settings.json"
HOOK_SCRIPT="clawd-bar-hook.sh"
PLIST_SRC="$SCRIPT_DIR/com.clawd.bar.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.clawd.bar.plist"

if [ ! -f "$SETTINGS" ]; then
  echo "Error: $SETTINGS not found"
  exit 1
fi

# Step 1: Build release binary
echo "ClawdBar: building release binary..."
(cd "$SCRIPT_DIR" && swift build -c release 2>&1 | tail -5)
BINARY="$SCRIPT_DIR/.build/release/ClawdBar"
if [ ! -f "$BINARY" ]; then
  echo "Error: build failed — release binary not found"
  exit 1
fi

# Step 2: Install to ~/.claude/clawd-bar/
mkdir -p "$INSTALL_DIR"
cp "$BINARY" "$INSTALL_DIR/ClawdBar"
cp "$SCRIPT_DIR/hooks/$HOOK_SCRIPT" "$INSTALL_DIR/$HOOK_SCRIPT"
chmod +x "$INSTALL_DIR/ClawdBar" "$INSTALL_DIR/$HOOK_SCRIPT"
echo "ClawdBar: installed to $INSTALL_DIR"

# Step 3: Register hooks (remove old entries, add new ones)
export CLAWD_HOOK_PATH="$INSTALL_DIR/$HOOK_SCRIPT"
/usr/bin/python3 << 'PYEOF'
import json, os

settings_path = os.path.expanduser("~/.claude/settings.json")
hook_path = os.environ["CLAWD_HOOK_PATH"]
marker = "clawd-bar-hook.sh"
events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUseFailure",
          "SubagentStart", "SubagentStop", "Notification", "Elicitation",
          "PermissionRequest", "Stop", "SessionEnd"]

with open(settings_path, "r") as f:
    settings = json.load(f)

hooks = settings.setdefault("hooks", {})

# Remove all old clawd-bar hooks (any path)
removed = 0
for event in list(hooks.keys()):
    original = hooks[event]
    filtered = []
    for entry in original:
        cmd = entry.get("command", "")
        nested = entry.get("hooks", [])
        is_clawd = marker in cmd or any(marker in h.get("command", "") for h in nested)
        if is_clawd:
            removed += 1
        else:
            filtered.append(entry)
    hooks[event] = filtered

# Add new hooks with canonical path
added = 0
for event in events:
    entries = hooks.setdefault(event, [])
    command = f'sh "{hook_path}" {event}'
    entries.append({
        "matcher": "",
        "hooks": [{"type": "command", "command": command}]
    })
    added += 1

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"ClawdBar: registered {added} hooks (removed {removed} old entries)")
PYEOF

# Step 4: Setup LaunchAgent
launchctl unload "$PLIST_DST" 2>/dev/null || true
sed "s|__CLAWD_BAR_BINARY__|$INSTALL_DIR/ClawdBar|g" "$PLIST_SRC" > "$PLIST_DST"
launchctl load "$PLIST_DST"
echo "ClawdBar: LaunchAgent installed and loaded"

echo "ClawdBar: installation complete!"
