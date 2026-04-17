# ClaudePet

macOS menu bar pixel pet showing Claude Code status. Pure Swift/AppKit, zero external dependencies.

## Build & Deploy

```bash
# Dev build + restart
swift build && /bin/cp -f .build/debug/ClaudePet ~/.claude/claude-pet/ClaudePet
pkill -9 -f ClaudePet; sleep 1; ~/.claude/claude-pet/ClaudePet &

# Release build (for install.sh / LaunchAgent)
swift build -c release

# Run tests
swift build --build-tests 2>&1 && .build/debug/ClaudePetPackageTests.xctest/Contents/MacOS/ClaudePetPackageTests

# Generate GIF previews for README
swift run GenerateGifs assets
```

**CRITICAL**: Run `pkill -9 -f ClaudePet` to kill all processes before restarting. Use `/bin/cp -f` to bypass interactive alias. The app runs from `~/.claude/claude-pet/ClaudePet` via LaunchAgent.

## Architecture

```
main.swift          → wires HttpServer + StateManager + MultiStatusBarController
HttpServer          → NWListener on :23333, receives hook POSTs
StateManager        → session lifecycle, state priority resolution, oneshot timers
MultiStatusBarController → up to 5 NSStatusItems (one per session), animation timers
PixelRenderer       → Core Graphics pixel art (45x36 grid → 22x22 NSImage)
NotificationBubble  → SwiftUI glass-morphism popup (macOS 14+)
TranscriptParser    → JSONL parsing for context usage (currently unused / dead code)
```

## Pixel Art

- 45x36 logical grid → 0.5x scale → 22x22 NSImage (1:1 Retina physical pixels)
- All animations in `PixelRenderer.swift`, each state has a `draw*()` function
- Frames pre-rendered at init, cached as `[PetState: [NSImage]]`
- Body coords: torso x:6-39 y:6-27, eyes x:12/x:30 y:12-18, legs x:9/15/27/33 y:21-33

1 logical pixel = 0.5pt = 1 Retina physical pixel. This is the maximum useful resolution.

## State Machine

States: idle, thinking, working, juggling, error, notification, happy, sleeping

Priority resolution (highest wins across sessions):
- juggling (4) > working (3) > thinking (2) > idle (1) > sleeping (0)
- error/notification/happy are "oneshot" (priority 99, timer-based, bypass resolve)

Key behaviors:
- Stop event → 5.2s happy animation → force idle
- 5s debounce window after Stop blocks working/juggling (prevents late event flicker)
- UserPromptSubmit clears the debounce window
- Elicitation/PermissionRequest → persistent notification (stays until next user action)
- 60s inactivity → sleeping (only if no session is in an active state)

## HTTP API

`POST http://localhost:23333/state` with `session_id`, `state`, `event`.
`POST http://localhost:23333/context` with context window usage info.

## Hooks

`hooks/claude-pet-hook.sh` reads Claude Code stdin JSON, maps event→state, POSTs to server.

Event mapping:
- SessionStart → idle, UserPromptSubmit → thinking, PreToolUse → working
- PostToolUseFailure → error, SubagentStart → juggling, SubagentStop → idle
- Stop → idle (with happy animation), SessionEnd → sleeping
- Notification/Elicitation/PermissionRequest → notification

Gotchas:
- macOS `mktemp` requires X's at END of template — no `.json` suffix (see commit fixing this)
- Manual test sessions must be cleaned up with `SessionEnd` or they leave ghost icons
- `working` overrides `thinking` — can't observe thinking while session is calling tools
- Hook runs `curl &` in background with 1s timeout — first events after cold start may be lost

## Known Issues

### Thread Safety
- `StateManager` is a plain `final class` with no `@MainActor` or locks. Currently safe because all callers dispatch to main thread, but fragile.
- `HttpServer` uses `@unchecked Sendable` to bypass Swift 6 concurrency checks. The mutable closure properties (`onStateEvent`, `onContextUpdate`) are unprotected.
- `NotificationBubble.BubbleViewModel` also uses `@unchecked Sendable`.

### HTTP Server
- Single `receive(max: 8192)` — TCP fragmentation can split a request across packets, causing parse failure and lost events. In practice, hook payloads are small enough.
- No retry or user notification when port 23333 is already in use — server silently fails.

### UI
- `showMenu()` calls `Process.waitUntilExit()` for git commands on the main thread — can freeze menu bar on slow filesystems.
- `getGitInfo()` in MultiStatusBarController is dead code (defined but never called).
- Max 5 status bar instances — 6th+ session silently ignored with no feedback.
- Multiple NotificationBubble panels can stack on top of each other.

### Dead Code
- `TranscriptParser.swift` — fully implemented but never called from anywhere. Context info now comes via `/context` HTTP endpoint instead.
- `getGitInfo()` in MultiStatusBarController — menu builds git info inline instead.

### Rendering
- `NSGraphicsContext.current!` force-unwrap in PixelRenderer.render() — crash risk under GPU pressure.

### Logging
- Every event writes to stderr (→ `/tmp/claude-pet.log`). No log rotation — file grows unbounded.
