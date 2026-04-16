#!/bin/bash
# install.sh — Build, install ClaudePet to ~/.claude/claude-pet/, register hooks + LaunchAgent
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="$HOME/.claude/claude-pet"
SETTINGS="$HOME/.claude/settings.json"
HOOK_SCRIPT="claude-pet-hook.sh"
STATUSLINE_SCRIPT="claude-pet-statusline.sh"
PLIST_SRC="$SCRIPT_DIR/com.claude.pet.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.claude.pet.plist"

if [ ! -f "$SETTINGS" ]; then
  echo "Error: $SETTINGS not found"
  exit 1
fi

# Step 1: Build release binary
echo "ClaudePet: building release binary..."
(cd "$SCRIPT_DIR" && swift build -c release 2>&1 | tail -5)
BINARY="$SCRIPT_DIR/.build/release/ClaudePet"
if [ ! -f "$BINARY" ]; then
  echo "Error: build failed — release binary not found"
  exit 1
fi

# Step 2: Install to ~/.claude/claude-pet/
mkdir -p "$INSTALL_DIR"
cp "$BINARY" "$INSTALL_DIR/ClaudePet"
cp "$SCRIPT_DIR/hooks/$HOOK_SCRIPT" "$INSTALL_DIR/$HOOK_SCRIPT"
cp "$SCRIPT_DIR/hooks/$STATUSLINE_SCRIPT" "$INSTALL_DIR/$STATUSLINE_SCRIPT"
chmod +x "$INSTALL_DIR/ClaudePet" "$INSTALL_DIR/$HOOK_SCRIPT" "$INSTALL_DIR/$STATUSLINE_SCRIPT"
echo "ClaudePet: installed to $INSTALL_DIR"

# Step 3: Register hooks + statusLine
export CLAUDE_PET_HOOK_PATH="$INSTALL_DIR/$HOOK_SCRIPT"
export CLAUDE_PET_STATUSLINE_PATH="$INSTALL_DIR/$STATUSLINE_SCRIPT"
/usr/bin/python3 << 'PYEOF'
import json, os

settings_path = os.path.expanduser("~/.claude/settings.json")
hook_path = os.environ["CLAUDE_PET_HOOK_PATH"]
statusline_path = os.environ["CLAUDE_PET_STATUSLINE_PATH"]
hook_marker = "claude-pet-hook.sh"
statusline_marker = "claude-pet-statusline.sh"
events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUseFailure",
          "SubagentStart", "SubagentStop", "Notification", "Elicitation",
          "Stop", "SessionEnd"]

with open(settings_path, "r") as f:
    settings = json.load(f)

hooks = settings.setdefault("hooks", {})

# Remove all old claude-pet hooks (any path)
removed = 0
for event in list(hooks.keys()):
    original = hooks[event]
    filtered = []
    for entry in original:
        cmd = entry.get("command", "")
        nested = entry.get("hooks", [])
        is_permission_http = any(h.get("type") == "http" and h.get("url") == "http://127.0.0.1:23333/permission" for h in nested)
        is_claude_pet = hook_marker in cmd or any(hook_marker in h.get("command", "") for h in nested) or is_permission_http
        if is_claude_pet:
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

permission_entries = hooks.setdefault("PermissionRequest", [])
permission_entries.append({
    "matcher": "",
    "hooks": [{
        "type": "http",
        "url": "http://127.0.0.1:23333/permission",
        "timeout": 600
    }]
})
added += 1

existing_statusline = settings.get("statusLine")
replaced_statusline = 0
if isinstance(existing_statusline, dict):
    existing_command = existing_statusline.get("command", "")
    if statusline_marker in existing_command:
        replaced_statusline = 1

settings["statusLine"] = {
    "type": "command",
    "command": f'sh "{statusline_path}"',
}

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"ClaudePet: registered {added} hooks (removed {removed} old entries), statusLine={'updated' if replaced_statusline else 'installed'}")
PYEOF

# Step 4: Setup LaunchAgent
launchctl unload "$PLIST_DST" 2>/dev/null || true
sed "s|__CLAUDE_PET_BINARY__|$INSTALL_DIR/ClaudePet|g" "$PLIST_SRC" > "$PLIST_DST"
launchctl load "$PLIST_DST"
echo "ClaudePet: LaunchAgent installed and loaded"

echo "ClaudePet: installation complete!"
