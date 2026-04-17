#!/bin/bash
# install.sh — Build, install ClaudePet to ~/.claude/claude-pet/, register hooks + LaunchAgent
# Usage: ./install.sh [--extra-settings FILENAME] [--extra-settings FILENAME] ...
# Example: ./install.sh --extra-settings llmbox.json
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="$HOME/.claude/claude-pet"
SETTINGS_DIR="$HOME/.claude"
DEFAULT_SETTINGS="settings.json"
HOOK_SCRIPT="claude-pet-hook.sh"
STATUSLINE_SCRIPT="claude-pet-statusline.sh"
PLIST_SRC="$SCRIPT_DIR/com.claude.pet.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.claude.pet.plist"

# Parse command line arguments for extra settings files
EXTRA_SETTINGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --extra-settings|-s)
            EXTRA_SETTINGS+=("$2")
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --extra-settings, -s FILE   Additional settings file to configure (e.g., llmbox.json)"
            echo "                              Can be specified multiple times"
            echo "  --help, -h                  Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                                    # Default: configure settings.json only"
            echo "  $0 --extra-settings llmbox.json       # Configure settings.json + llmbox.json"
            echo "  $0 -s llmbox.json -s custom.json      # Configure settings.json + llmbox.json + custom.json"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run '$0 --help' for usage"
            exit 1
            ;;
    esac
done

# Build list of settings files (always include default)
SETTINGS_FILES=("$SETTINGS_DIR/$DEFAULT_SETTINGS")

# Add extra settings files if they exist
for f in "${EXTRA_SETTINGS[@]}"; do
    if [[ "$f" != /* ]]; then
        # Relative path: treat as filename in ~/.claude/
        full_path="$SETTINGS_DIR/$f"
    else
        full_path="$f"
    fi
    if [ -f "$full_path" ]; then
        SETTINGS_FILES+=("$full_path")
    else
        echo "Warning: Extra settings file not found: $full_path (skipping)"
    fi
done

echo "ClaudePet: Settings files to configure: ${SETTINGS_FILES[*]}"

# Check for jq dependency
if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but not installed."
    echo "Install with: brew install jq"
    exit 1
fi

# Verify default settings file exists
if [ ! -f "$SETTINGS_DIR/$DEFAULT_SETTINGS" ]; then
    echo "Error: Default settings file not found: $SETTINGS_DIR/$DEFAULT_SETTINGS"
    echo "Please run Claude Code at least once to create it."
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

# Step 3: Register hooks + statusLine to all settings files
export CLAUDE_PET_HOOK_PATH="$INSTALL_DIR/$HOOK_SCRIPT"
export CLAUDE_PET_STATUSLINE_PATH="$INSTALL_DIR/$STATUSLINE_SCRIPT"
export CLAUDE_PET_SETTINGS_FILES="${SETTINGS_FILES[*]}"

PYTHON=$(command -v python3 2>/dev/null) || { echo "Error: python3 not found"; exit 1; }
"$PYTHON" << 'PYEOF'
import json
import os

hook_path = os.environ["CLAUDE_PET_HOOK_PATH"]
statusline_path = os.environ["CLAUDE_PET_STATUSLINE_PATH"]
settings_files = os.environ["CLAUDE_PET_SETTINGS_FILES"].split()

hook_marker = "claude-pet-hook.sh"
statusline_marker = "claude-pet-statusline.sh"
events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUseFailure",
          "SubagentStart", "SubagentStop", "Notification", "Elicitation",
          "Stop", "SessionEnd"]

for settings_path in settings_files:
    settings_path = os.path.expanduser(settings_path)

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
            is_permission_http = any(
                h.get("type") == "http" and h.get("url") == "http://127.0.0.1:23333/permission"
                for h in nested
            )
            is_claude_pet = (
                hook_marker in cmd
                or any(hook_marker in h.get("command", "") for h in nested)
                or is_permission_http
            )
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
        "matcher": "*",
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

    filename = os.path.basename(settings_path)
    print(f"ClaudePet [{filename}]: registered {added} hooks (removed {removed} old), statusLine={'updated' if replaced_statusline else 'installed'}")
PYEOF

# Step 4: Setup LaunchAgent
launchctl unload "$PLIST_DST" 2>/dev/null || true
sed "s|__CLAUDE_PET_BINARY__|$INSTALL_DIR/ClaudePet|g" "$PLIST_SRC" > "$PLIST_DST"
launchctl load "$PLIST_DST"
echo "ClaudePet: LaunchAgent installed and loaded"

echo ""
echo "ClaudePet: installation complete!"
echo ""
echo "Configured settings files:"
for f in "${SETTINGS_FILES[@]}"; do
    filename=$(basename "$f")
    echo "  - $filename"
done
