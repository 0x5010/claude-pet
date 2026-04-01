# ClaudePet

A macOS menu bar pet that shows your [Claude Code](https://docs.anthropic.com/en/docs/claude-code) working status as an animated pixel-art character.

Pure Swift/AppKit. ~3MB RAM. Near-zero CPU. No Electron. Zero dependencies.

## States

ClaudePet automatically reacts to your Claude Code sessions in real-time:

<table>
<tr>
<td align="center"><img src="assets/idle.gif" width="80" /><br/><b>Idle</b><br/>Breathing + blinking</td>
<td align="center"><img src="assets/thinking.gif" width="80" /><br/><b>Thinking</b><br/>Loading dots</td>
<td align="center"><img src="assets/working.gif" width="80" /><br/><b>Working</b><br/>Typing on laptop</td>
<td align="center"><img src="assets/juggling.gif" width="80" /><br/><b>Juggling</b><br/>Subagent multitask</td>
</tr>
<tr>
<td align="center"><img src="assets/error.gif" width="80" /><br/><b>Error</b><br/>Flashing red</td>
<td align="center"><img src="assets/notification.gif" width="80" /><br/><b>Notification</b><br/>Jumping alert</td>
<td align="center"><img src="assets/happy.gif" width="80" /><br/><b>Happy</b><br/>Task complete!</td>
<td align="center"><img src="assets/sleeping.gif" width="80" /><br/><b>Sleeping</b><br/>Zzz...</td>
</tr>
</table>

## How It Works

Claude Code fires [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) on session events. ClaudePet registers shell hooks that POST state changes to a local HTTP server (port 23333). The Swift app resolves the display state across multiple concurrent sessions and animates the menu bar icon.

```
Claude Code → hook event (e.g. PreToolUse) → claude-pet-hook.sh → curl POST :23333 → ClaudePet → animation
```

Each Claude Code session gets its own menu bar icon (up to 5 concurrent sessions).

## Install

### Prerequisites

- macOS 14.0+ (Sonoma)
- Swift toolchain (`xcode-select --install` if not available)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed
- [jq](https://jqlang.github.io/jq/) (`brew install jq`)

### Quick Start

```bash
git clone https://github.com/SidKwok/claude-pet.git ~/claude-pet
cd ~/claude-pet
swift build -c release
bash hooks/install.sh
```

`install.sh` does three things:
1. Registers 11 Claude Code hooks in `~/.claude/settings.json` (with duplicate detection)
2. Installs a LaunchAgent for auto-start on login
3. Launches ClaudePet immediately

A small pixel character should appear in your menu bar.

### Verify

Click the icon to see a menu with session info. Use the **Preview States** submenu to test each animation.

### Manual Launch

```bash
~/claude-pet/.build/release/ClaudePet &
```

## Usage

| Action | Result |
|--------|--------|
| **Click** icon | Session menu (status, model, context usage, git branch) |
| **Option+Click** | Quit ClaudePet |
| Start Claude Code | New icon appears, shows thinking/working states |
| Claude Code finishes | Happy bounce, then idle |
| 60s no activity | Zzz sleeping |

### Multi-Session Support

Each Claude Code session gets its own status bar icon (up to 5). The menu shows per-session info including working directory, model name, context usage, and last prompt.

### Context Usage

The menu displays a color-coded context window usage bar:
- Green (≤40%) → Yellow (≤65%) → Orange (≤80%) → Red (>80%)

## Uninstall

```bash
# Stop and remove auto-start
launchctl unload ~/Library/LaunchAgents/com.claude.pet.plist 2>/dev/null
rm -f ~/Library/LaunchAgents/com.claude.pet.plist

# Remove hooks from Claude Code settings
python3 -c "
import json, os
p = os.path.expanduser('~/.claude/settings.json')
s = json.load(open(p))
for k in list(s.get('hooks', {}).keys()):
    s['hooks'][k] = [h for h in s['hooks'][k]
                     if 'claude-pet-hook' not in str(h)]
    if not s['hooks'][k]: del s['hooks'][k]
json.dump(s, open(p, 'w'), indent=2, ensure_ascii=False)
print('Hooks removed')
"

# Delete app
rm -rf ~/claude-pet
```

## Project Structure

```
claude-pet/
├── Sources/
│   ├── ClaudePet/main.swift              # Entry point, wires components
│   ├── ClaudePetCore/
│   │   └── StateManager.swift           # State machine, multi-session priority resolution
│   └── ClaudePetLib/
│       ├── HttpServer.swift             # NWListener on :23333, HTTP parser
│       ├── MultiStatusBarController.swift # Per-session NSStatusItems (max 5), animation
│       ├── NotificationBubble.swift     # Glass-morphism notification popup
│       ├── PixelRenderer.swift          # Core Graphics pixel art (45x36 grid, 8 states)
│       └── TranscriptParser.swift       # JSONL transcript parser
├── Tests/
│   └── StateManagerTests.swift          # 45+ unit tests for state machine
├── hooks/
│   ├── install.sh                       # One-command setup (hooks + LaunchAgent)
│   └── claude-pet-hook.sh               # Event→state mapper, POSTs to :23333
├── assets/                              # Generated GIF previews
└── com.claude.pet.plist                  # LaunchAgent template
```

## Development

```bash
# Build (debug)
swift build

# Build + restart app
swift build && cp .build/debug/ClaudePet ClaudePet.app/Contents/MacOS/ClaudePet
pkill -9 -f ClaudePet; sleep 2; open ClaudePet.app

# Run tests
swift build --build-tests 2>&1 && \
  .build/debug/ClaudePetPackageTests.xctest/Contents/MacOS/ClaudePetPackageTests

# Regenerate GIF previews
swift run GenerateGifs assets
```

## Credits

Pixel art design inspired by [Clawd on Desk](https://github.com/rullerzhou-afk/clawd-on-desk).
