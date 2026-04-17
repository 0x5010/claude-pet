#!/bin/bash
# uninstall.sh — Remove ClaudePet completely
set -e

INSTALL_DIR="$HOME/.claude/claude-pet"
PLIST_DST="$HOME/Library/LaunchAgents/com.claude.pet.plist"
SETTINGS_DIR="$HOME/.claude"

echo "ClaudePet: Uninstalling..."

# Step 1: Stop and remove LaunchAgent
if [ -f "$PLIST_DST" ]; then
    launchctl unload "$PLIST_DST" 2>/dev/null || true
    rm -f "$PLIST_DST"
    echo "ClaudePet: LaunchAgent removed"
fi

# Step 2: Kill any running ClaudePet processes
pkill -9 -f ClaudePet 2>/dev/null || true
echo "ClaudePet: Processes stopped"

# Step 3: Remove hooks from all Claude Code settings files
PYTHON=$(command -v python3 2>/dev/null) || { echo "Warning: python3 not found, skipping hook removal"; }
if [ -n "$PYTHON" ]; then
    "$PYTHON" << 'PYEOF'
import json
import os

settings_dir = os.path.expanduser("~/.claude")
# Common settings files to check
files_to_check = ["settings.json", "llmbox.json"]

for filename in files_to_check:
    filepath = os.path.join(settings_dir, filename)
    if not os.path.exists(filepath):
        continue

    with open(filepath, 'r') as f:
        settings = json.load(f)

    hooks = settings.get('hooks', {})
    removed_hooks = 0

    for event in list(hooks.keys()):
        original = hooks[event]
        filtered = []
        for entry in original:
            cmd = entry.get('command', '')
            nested = entry.get('hooks', [])
            is_http_hook = any(
                h.get('type') == 'http' and '23333' in h.get('url', '')
                for h in nested
            )
            is_claude_pet = (
                'claude-pet-hook' in cmd
                or 'claude-pet-statusline' in cmd
                or is_http_hook
            )
            if is_claude_pet:
                removed_hooks += 1
            else:
                filtered.append(entry)

        if filtered:
            hooks[event] = filtered
        else:
            del settings['hooks'][event]

    # Remove statusLine if it's ClaudePet
    if 'statusLine' in settings:
        sl = settings.get('statusLine', {})
        if isinstance(sl, dict) and 'claude-pet-statusline' in sl.get('command', ''):
            del settings['statusLine']

    with open(filepath, 'w') as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"ClaudePet [{filename}]: removed {removed_hooks} hooks")
PYEOF
fi

# Step 4: Delete installed files
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    echo "ClaudePet: Installed files removed"
fi

echo ""
echo "ClaudePet: Uninstall complete!"
echo ""
echo "Note: Source directory not removed. To delete:"
echo "  rm -rf ~/claude-pet"
