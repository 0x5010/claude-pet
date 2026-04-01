import Testing
@testable import ClaudePetCore

// MARK: - Basic State

@Test func initialStateIsIdle() {
    let sm = StateManager()
    #expect(sm.currentDisplayState == .idle)
}

@Test func sessionCountStartsAtZero() {
    let sm = StateManager()
    #expect(sm.sessionCount == 0)
}

// MARK: - Priority Resolution

@Test func sessionUpdateResolvesHighestPriority() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    #expect(sm.currentDisplayState == .thinking)
    sm.handleEvent(sessionId: "b", state: .working, event: "PreToolUse")
    #expect(sm.currentDisplayState == .working)
}

@Test func jugglingBeatsWorking() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "b", state: .juggling, event: "SubagentStart")
    #expect(sm.currentDisplayState == .juggling)
}

@Test func resolveFallsToIdleWhenAllSessionsIdle() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    // thinking < working, but this is same session overwrite
    #expect(sm.currentDisplayState == .thinking)
}

@Test func resolveAfterHighPrioritySessionEnds() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    sm.handleEvent(sessionId: "b", state: .working, event: "PreToolUse")
    #expect(sm.currentDisplayState == .working)
    // Remove the working session
    sm.handleEvent(sessionId: "b", state: .sleeping, event: "SessionEnd")
    #expect(sm.currentDisplayState == .thinking)
}

@Test func emptySessionsResolveToIdle() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .sleeping, event: "SessionEnd")
    #expect(sm.currentDisplayState == .idle)
    #expect(sm.sessionCount == 0)
}

// MARK: - Oneshot States

@Test func errorIsOneshotThenReturnsToResolved() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .error, event: "PostToolUseFailure")
    #expect(sm.currentDisplayState == .error)
    // Simulate oneshot expiry
    sm.oneshotTimer?.fire()
    #expect(sm.currentDisplayState == .working)
}

@Test func notificationOneshotThenReturnsToResolved() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .notification, event: "Notification", message: "test")
    #expect(sm.currentDisplayState == .notification)
    sm.oneshotTimer?.fire()
    #expect(sm.currentDisplayState == .working)
}

@Test func elicitationStaysPersistentUntilUserActs() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .notification, event: "Elicitation")
    #expect(sm.currentDisplayState == .notification)
    // Persistent — no timer-based resolution; new user action clears it
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    #expect(sm.currentDisplayState == .thinking)
}

@Test func permissionRequestStaysPersistent() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .notification, event: "PermissionRequest")
    #expect(sm.currentDisplayState == .notification)
    // Cleared by non-notification event
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    #expect(sm.currentDisplayState == .working)
}

// MARK: - Stop / Happy Flow

@Test func stopTriggersHappyThenIdle() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    // Stop triggers happy oneshot
    #expect(sm.currentDisplayState == .happy)
    // After oneshot expires, should be idle
    sm.oneshotTimer?.fire()
    #expect(sm.currentDisplayState == .idle)
}

@Test func stopWithMessageTriggersNotification() {
    let sm = StateManager()
    var notifiedMessage: String?
    sm.onSessionNotification = { _, msg in notifiedMessage = msg }
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop", message: "Done!")
    #expect(notifiedMessage == "Done!")
}

@Test func stopWithoutMessageDoesNotNotify() {
    let sm = StateManager()
    var notified = false
    sm.onSessionNotification = { _, _ in notified = true }
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    #expect(!notified)
}

// MARK: - Debouncing (5s post-Stop window)

@Test func workingIgnoredWithin5sOfStop() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    // Expire oneshot to get to idle
    sm.oneshotTimer?.fire()
    #expect(sm.currentDisplayState == .idle)
    // Working event within 5s of Stop should be ignored
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    #expect(sm.currentDisplayState == .idle)
}

@Test func jugglingAlsoIgnoredWithin5sOfStop() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    sm.oneshotTimer?.fire()
    sm.handleEvent(sessionId: "a", state: .juggling, event: "SubagentStart")
    #expect(sm.currentDisplayState == .idle)
}

@Test func globalStopBlocksWorkingFromDifferentSession() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    sm.oneshotTimer?.fire()
    // Different session's working event also blocked by globalStoppedAt
    sm.handleEvent(sessionId: "b", state: .working, event: "PreToolUse")
    #expect(sm.currentDisplayState == .idle)
}

@Test func userPromptSubmitClearsStoppedAt() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    // Expire oneshot
    sm.oneshotTimer?.fire()
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    #expect(sm.currentDisplayState == .thinking)
    // Now working should be accepted
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    #expect(sm.currentDisplayState == .working)
}

@Test func thinkingNotBlockedByStopDebounce() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    sm.oneshotTimer?.fire()
    // thinking is NOT blocked (only working/juggling are)
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    #expect(sm.currentDisplayState == .thinking)
}

// MARK: - Session Lifecycle

@Test func sessionEndRemovesSession() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .sleeping, event: "SessionEnd")
    #expect(sm.sessionCount == 0)
}

@Test func multipleSessionsTrackedIndependently() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit", cwd: "/project-a")
    sm.handleEvent(sessionId: "b", state: .working, event: "PreToolUse", cwd: "/project-b")
    sm.handleEvent(sessionId: "c", state: .idle, event: "SessionStart", cwd: "/project-c")
    #expect(sm.sessionCount == 3)
    #expect(sm.sessions["a"]?.cwd == "/project-a")
    #expect(sm.sessions["b"]?.cwd == "/project-b")
    #expect(sm.sessions["c"]?.cwd == "/project-c")
}

@Test func sessionStartCreatesIdleSession() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .idle, event: "SessionStart", cwd: "/test")
    #expect(sm.sessionCount == 1)
    #expect(sm.sessions["a"]?.state == .idle)
    #expect(sm.sessions["a"]?.cwd == "/test")
}

// MARK: - Metadata Updates

@Test func metadataUpdatesOnSubsequentEvents() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .idle, event: "SessionStart", cwd: "/old")
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit",
                   cwd: "/new", prompt: "fix the bug")
    #expect(sm.sessions["a"]?.cwd == "/new")
    #expect(sm.sessions["a"]?.meta.lastPrompt == "fix the bug")
}

@Test func toolNameTracked() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse", toolName: "Edit")
    #expect(sm.sessions["a"]?.meta.lastTool == "Edit")
}

@Test func emptyFieldsDoNotOverwriteExisting() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .idle, event: "SessionStart",
                   cwd: "/project", transcriptPath: "/path/to/transcript",
                   permissionMode: "bypassPermissions")
    // Second event with empty optional fields should not clear them
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    #expect(sm.sessions["a"]?.cwd == "/project")
    #expect(sm.sessions["a"]?.meta.transcriptPath == "/path/to/transcript")
    #expect(sm.sessions["a"]?.meta.permissionMode == "bypassPermissions")
}

@Test func updateContextStoresMetadata() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .idle, event: "SessionStart")
    sm.updateContext(sessionId: "a", usedPct: 42.5, currentUsage: 42500,
                     modelName: "claude-opus-4-6", sessionName: "my-session")
    let meta = sm.sessions["a"]?.meta
    #expect(meta?.contextUsedPct == 42.5)
    #expect(meta?.contextCurrentUsage == 42500)
    #expect(meta?.modelName == "claude-opus-4-6")
    #expect(meta?.sessionName == "my-session")
}

@Test func updateContextIgnoresUnknownSession() {
    let sm = StateManager()
    // Should not crash or create session
    sm.updateContext(sessionId: "unknown", usedPct: 50, currentUsage: 500,
                     modelName: "test", sessionName: "test")
    #expect(sm.sessionCount == 0)
}

@Test func updateContextPreservesExistingNonEmptyFields() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .idle, event: "SessionStart")
    sm.updateContext(sessionId: "a", usedPct: 50, currentUsage: 500,
                     modelName: "claude-opus-4-6", sessionName: "session-1")
    // Update with empty modelName should keep existing
    sm.updateContext(sessionId: "a", usedPct: 60, currentUsage: 600,
                     modelName: "", sessionName: "")
    #expect(sm.sessions["a"]?.meta.modelName == "claude-opus-4-6")
    #expect(sm.sessions["a"]?.meta.sessionName == "session-1")
    #expect(sm.sessions["a"]?.meta.contextUsedPct == 60)
}

// MARK: - Active States Persist (no stale decay)

@Test func workingPersistsAfter30s() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.backdateSession("a", seconds: 31)
    sm.cleanStaleSessions()
    // Working should NOT decay — only an explicit Stop ends it
    #expect(sm.sessions["a"]?.state == .working)
    #expect(sm.currentDisplayState == .working)
}

@Test func thinkingPersistsAfter30s() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    sm.backdateSession("a", seconds: 31)
    sm.cleanStaleSessions()
    #expect(sm.sessions["a"]?.state == .thinking)
}

@Test func jugglingPersistsAfter30s() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .juggling, event: "SubagentStart")
    sm.backdateSession("a", seconds: 31)
    sm.cleanStaleSessions()
    #expect(sm.sessions["a"]?.state == .juggling)
}

// MARK: - Inactivity

@Test func inactivitySleep() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    sm.oneshotTimer?.fire()
    sm.backdateLastEvent(seconds: 61)
    sm.checkInactivity()
    #expect(sm.currentDisplayState == .sleeping)
}

@Test func noInactivityWithin60s() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .idle, event: "SessionStart")
    sm.oneshotTimer?.fire()
    sm.backdateLastEvent(seconds: 59)
    sm.checkInactivity()
    #expect(sm.currentDisplayState == .idle)  // not sleeping
}

@Test func activeSessionBlocksInactivitySleep() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.backdateLastEvent(seconds: 120)
    sm.checkInactivity()
    // Should NOT sleep while a session is actively working
    #expect(sm.currentDisplayState == .working)
}

@Test func activeThinkingBlocksInactivitySleep() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    sm.backdateLastEvent(seconds: 120)
    sm.checkInactivity()
    #expect(sm.currentDisplayState == .thinking)
}

@Test func activeJugglingBlocksInactivitySleep() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .juggling, event: "SubagentStart")
    sm.backdateLastEvent(seconds: 120)
    sm.checkInactivity()
    #expect(sm.currentDisplayState == .juggling)
}

// MARK: - Callbacks

@Test func sessionAddedCallbackFired() {
    let sm = StateManager()
    var addedId: String?
    var addedCwd: String?
    sm.onSessionAdded = { id, session in
        addedId = id
        addedCwd = session.cwd
    }
    sm.handleEvent(sessionId: "abc", state: .thinking, event: "UserPromptSubmit", cwd: "/tmp/test")
    #expect(addedId == "abc")
    #expect(addedCwd == "/tmp/test")
}

@Test func sessionAddedNotFiredForExistingSession() {
    let sm = StateManager()
    var addedCount = 0
    sm.onSessionAdded = { _, _ in addedCount += 1 }
    sm.handleEvent(sessionId: "a", state: .idle, event: "SessionStart")
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    #expect(addedCount == 1)
}

@Test func sessionRemovedCallbackFired() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "abc", state: .thinking, event: "UserPromptSubmit")
    var removedId: String?
    sm.onSessionRemoved = { id in removedId = id }
    sm.handleEvent(sessionId: "abc", state: .sleeping, event: "SessionEnd")
    #expect(removedId == "abc")
    #expect(sm.sessionCount == 0)
}

@Test func sessionStateChangeCallbackFired() {
    let sm = StateManager()
    var changes: [(String, PetState)] = []
    sm.onSessionStateChange = { id, state in changes.append((id, state)) }
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    #expect(changes.count >= 2)
    #expect(changes.last?.1 == .working)
}

@Test func onStateChangeCallbackFired() {
    let sm = StateManager()
    var displayStates: [PetState] = []
    sm.onStateChange = { state in displayStates.append(state) }
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    #expect(displayStates.contains(.thinking))
    #expect(displayStates.contains(.working))
}

@Test func onStateChangeNotFiredWhenSameState() {
    let sm = StateManager()
    var callCount = 0
    sm.onStateChange = { _ in callCount += 1 }
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    let countAfterFirst = callCount
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    #expect(callCount == countAfterFirst)  // no duplicate callback
}

@Test func notificationCallbackWithMessage() {
    let sm = StateManager()
    var messages: [(String, String)] = []
    sm.onSessionNotification = { id, msg in messages.append((id, msg)) }
    sm.handleEvent(sessionId: "a", state: .notification, event: "Notification", message: "hello")
    #expect(messages.count == 1)
    #expect(messages[0].0 == "a")
    #expect(messages[0].1 == "hello")
}

@Test func notificationCallbackNotFiredWithEmptyMessage() {
    let sm = StateManager()
    var notified = false
    sm.onSessionNotification = { _, _ in notified = true }
    sm.handleEvent(sessionId: "a", state: .notification, event: "Notification")
    #expect(!notified)
}

// MARK: - PetState Priority

@Test func petStatePriorityOrder() {
    #expect(PetState.sleeping.priority < PetState.idle.priority)
    #expect(PetState.idle.priority < PetState.thinking.priority)
    #expect(PetState.thinking.priority < PetState.working.priority)
    #expect(PetState.working.priority < PetState.juggling.priority)
    #expect(PetState.error.priority == 99)
    #expect(PetState.notification.priority == 99)
    #expect(PetState.happy.priority == 99)
}

// MARK: - formatModelName

@Test func formatModelNameOpus() {
    #expect(formatModelName("claude-opus-4-6") == "Opus 4.6")
}

@Test func formatModelNameSonnet() {
    #expect(formatModelName("claude-sonnet-4-6") == "Sonnet 4.6")
}

@Test func formatModelNameHaiku() {
    #expect(formatModelName("claude-haiku-4-5") == "Haiku 4.5")
}

@Test func formatModelNameUnknownPassthrough() {
    #expect(formatModelName("gpt-4o") == "gpt-4o")
}

@Test func formatModelNameShortStringReturnsNameOnly() {
    #expect(formatModelName("opus") == "Opus")
}

// MARK: - Edge Cases

@Test func sessionEndForNonexistentSessionIsNoOp() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "ghost", state: .sleeping, event: "SessionEnd")
    #expect(sm.sessionCount == 0)
    #expect(sm.currentDisplayState == .idle)
}

@Test func rapidStopDoesNotCrash() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    sm.oneshotTimer?.fire()
    #expect(sm.currentDisplayState == .idle)
}

@Test func errorDuringOneshotHappyOverrides() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    #expect(sm.currentDisplayState == .happy)
    // Error during happy oneshot should override
    sm.handleEvent(sessionId: "a", state: .error, event: "PostToolUseFailure")
    #expect(sm.currentDisplayState == .error)
}

@Test func subagentStopResetsToIdle() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .juggling, event: "SubagentStart")
    #expect(sm.currentDisplayState == .juggling)
    sm.handleEvent(sessionId: "a", state: .idle, event: "SubagentStop")
    #expect(sm.currentDisplayState == .idle)
}
