import Foundation
import Testing
@testable import ClaudePetCore

@MainActor
private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 0.2) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

@MainActor
private func fireOneshot(_ sm: StateManager, expecting expectedState: PetState) async {
    sm.oneshotTimer?.fire()
    #expect(await waitUntil { sm.currentDisplayState == expectedState })
}

// MARK: - Basic State

@MainActor
@Test func initialStateIsIdle() {
    let sm = StateManager()
    #expect(sm.currentDisplayState == .idle)
}

@MainActor
@Test func sessionCountStartsAtZero() {
    let sm = StateManager()
    #expect(sm.sessionCount == 0)
}

// MARK: - Priority Resolution

@MainActor
@Test func sessionUpdateResolvesHighestPriority() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    #expect(sm.currentDisplayState == .thinking)
    sm.handleEvent(sessionId: "b", state: .working, event: "PreToolUse")
    #expect(sm.currentDisplayState == .working)
}

@MainActor
@Test func jugglingBeatsWorking() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "b", state: .juggling, event: "SubagentStart")
    #expect(sm.currentDisplayState == .juggling)
}

@MainActor
@Test func resolveFallsToIdleWhenAllSessionsIdle() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    // thinking < working, but this is same session overwrite
    #expect(sm.currentDisplayState == .thinking)
}

@MainActor
@Test func resolveAfterHighPrioritySessionEnds() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    sm.handleEvent(sessionId: "b", state: .working, event: "PreToolUse")
    #expect(sm.currentDisplayState == .working)
    // Remove the working session
    sm.handleEvent(sessionId: "b", state: .sleeping, event: "SessionEnd")
    #expect(sm.currentDisplayState == .thinking)
}

@MainActor
@Test func emptySessionsResolveToIdle() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .sleeping, event: "SessionEnd")
    #expect(sm.currentDisplayState == .idle)
    #expect(sm.sessionCount == 0)
}

// MARK: - Oneshot States

@MainActor
@Test func errorIsOneshotThenReturnsToResolved() async {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .error, event: "PostToolUseFailure")
    #expect(sm.currentDisplayState == .error)
    // Simulate oneshot expiry
    await fireOneshot(sm, expecting: .working)
    #expect(sm.currentDisplayState == .working)
}

@MainActor
@Test func notificationOneshotThenReturnsToResolved() async {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .notification, event: "Notification", message: "test")
    #expect(sm.currentDisplayState == .notification)
    await fireOneshot(sm, expecting: .working)
    #expect(sm.currentDisplayState == .working)
}

@MainActor
@Test func elicitationStaysPersistentUntilUserActs() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .notification, event: "Elicitation")
    #expect(sm.currentDisplayState == .notification)
    // Persistent — no timer-based resolution; new user action clears it
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    #expect(sm.currentDisplayState == .thinking)
}

@MainActor
@Test func permissionRequestStaysPersistent() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .notification, event: "PermissionRequest")
    #expect(sm.currentDisplayState == .notification)
    // Cleared by non-notification event
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    #expect(sm.currentDisplayState == .working)
}

// MARK: - Stop / Happy Flow

@MainActor
@Test func stopTriggersHappyThenIdle() async {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    // Stop triggers happy oneshot
    #expect(sm.currentDisplayState == .happy)
    // After oneshot expires, should be idle
    await fireOneshot(sm, expecting: .idle)
    #expect(sm.currentDisplayState == .idle)
}

@MainActor
@Test func stopWithMessageTriggersNotification() {
    let sm = StateManager()
    var notifiedMessage: String?
    sm.onSessionNotification = { _, msg in notifiedMessage = msg }
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop", message: "Done!")
    #expect(notifiedMessage == "Done!")
}

@MainActor
@Test func stopWithoutMessageDoesNotNotify() {
    let sm = StateManager()
    var notified = false
    sm.onSessionNotification = { _, _ in notified = true }
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    #expect(!notified)
}

// MARK: - Debouncing (5s post-Stop window)

@MainActor
@Test func workingIgnoredWithin5sOfStop() async {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    // Expire oneshot to get to idle
    await fireOneshot(sm, expecting: .idle)
    #expect(sm.currentDisplayState == .idle)
    // Working event within 5s of Stop should be ignored
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    #expect(sm.currentDisplayState == .idle)
}

@MainActor
@Test func jugglingAlsoIgnoredWithin5sOfStop() async {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    await fireOneshot(sm, expecting: .idle)
    sm.handleEvent(sessionId: "a", state: .juggling, event: "SubagentStart")
    #expect(sm.currentDisplayState == .idle)
}

@MainActor
@Test func globalStopBlocksWorkingFromDifferentSession() async {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    await fireOneshot(sm, expecting: .idle)
    // Different session's working event also blocked by globalStoppedAt
    sm.handleEvent(sessionId: "b", state: .working, event: "PreToolUse")
    #expect(sm.currentDisplayState == .idle)
}

@MainActor
@Test func userPromptSubmitClearsStoppedAt() async {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    // Expire oneshot
    await fireOneshot(sm, expecting: .idle)
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    #expect(sm.currentDisplayState == .thinking)
    // Now working should be accepted
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    #expect(sm.currentDisplayState == .working)
}

@MainActor
@Test func thinkingNotBlockedByStopDebounce() async {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    await fireOneshot(sm, expecting: .idle)
    // thinking is NOT blocked (only working/juggling are)
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    #expect(sm.currentDisplayState == .thinking)
}

// MARK: - Session Lifecycle

@MainActor
@Test func sessionEndRemovesSession() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .sleeping, event: "SessionEnd")
    #expect(sm.sessionCount == 0)
}

@MainActor
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

@MainActor
@Test func sessionStartCreatesIdleSession() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .idle, event: "SessionStart", cwd: "/test")
    #expect(sm.sessionCount == 1)
    #expect(sm.sessions["a"]?.state == .idle)
    #expect(sm.sessions["a"]?.cwd == "/test")
}

// MARK: - Metadata Updates

@MainActor
@Test func metadataUpdatesOnSubsequentEvents() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .idle, event: "SessionStart", cwd: "/old")
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit",
                   cwd: "/new", prompt: "fix the bug")
    #expect(sm.sessions["a"]?.cwd == "/new")
    #expect(sm.sessions["a"]?.meta.lastPrompt == "fix the bug")
}

@MainActor
@Test func toolNameTracked() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse", toolName: "Edit")
    #expect(sm.sessions["a"]?.meta.lastTool == "Edit")
}

@MainActor
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

@MainActor
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
    #expect(meta?.contextBand == .normal)
}

@MainActor
@Test func updateContextIgnoresUnknownSession() {
    let sm = StateManager()
    // Should not crash or create session
    sm.updateContext(sessionId: "unknown", usedPct: 50, currentUsage: 500,
                     modelName: "test", sessionName: "test")
    #expect(sm.sessionCount == 0)
}

@MainActor
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
    #expect(sm.sessions["a"]?.meta.contextBand == .cautious)
}

@MainActor
@Test func updateContextEmitsThresholdNotifications() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .idle, event: "SessionStart")
    var messages: [String] = []
    sm.onSessionNotification = { _, msg in messages.append(msg) }

    sm.updateContext(sessionId: "a", usedPct: 60, currentUsage: 600,
                     modelName: "", sessionName: "")
    sm.updateContext(sessionId: "a", usedPct: 75, currentUsage: 750,
                     modelName: "", sessionName: "")
    sm.updateContext(sessionId: "a", usedPct: 85, currentUsage: 850,
                     modelName: "", sessionName: "")
    sm.updateContext(sessionId: "a", usedPct: 95, currentUsage: 950,
                     modelName: "", sessionName: "")

    #expect(messages.count == 4)
    #expect(messages[0] == "context 到 60% 了，开始谨慎")
    #expect(messages[1] == "context 已经偏高，compact soon")
    #expect(messages[2] == "这个 session 接近窗口极限，建议 compact soon，并准备收尾当前子任务")
    #expect(messages[3] == "你已经连续 4 次处在高 context 区间，建议尽快结束当前子任务并开新 session")
}

@MainActor
@Test func updateContextTracksHighContextStrikes() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .idle, event: "SessionStart")
    var messages: [String] = []
    sm.onSessionNotification = { _, msg in messages.append(msg) }

    sm.updateContext(sessionId: "a", usedPct: 85, currentUsage: 850,
                     modelName: "", sessionName: "")
    sm.updateContext(sessionId: "a", usedPct: 50, currentUsage: 500,
                     modelName: "", sessionName: "")
    sm.updateContext(sessionId: "a", usedPct: 85, currentUsage: 850,
                     modelName: "", sessionName: "")
    sm.updateContext(sessionId: "a", usedPct: 50, currentUsage: 500,
                     modelName: "", sessionName: "")
    sm.updateContext(sessionId: "a", usedPct: 85, currentUsage: 850,
                     modelName: "", sessionName: "")
    sm.updateContext(sessionId: "a", usedPct: 50, currentUsage: 500,
                     modelName: "", sessionName: "")
    sm.updateContext(sessionId: "a", usedPct: 85, currentUsage: 850,
                     modelName: "", sessionName: "")

    #expect(sm.sessions["a"]?.meta.highContextStrikeCount == 4)
    #expect(messages.last == "你已经连续 4 次处在高 context 区间，建议 compact 或尽快收尾当前子任务")
}

// MARK: - Active States Persist (no stale decay)

@MainActor
@Test func workingPersistsAfter30s() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.backdateSession("a", seconds: 31)
    sm.cleanStaleSessions()
    // Working should NOT decay — only an explicit Stop ends it
    #expect(sm.sessions["a"]?.state == .working)
    #expect(sm.currentDisplayState == .working)
}

@MainActor
@Test func thinkingPersistsAfter30s() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    sm.backdateSession("a", seconds: 31)
    sm.cleanStaleSessions()
    #expect(sm.sessions["a"]?.state == .thinking)
}

@MainActor
@Test func jugglingPersistsAfter30s() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .juggling, event: "SubagentStart")
    sm.backdateSession("a", seconds: 31)
    sm.cleanStaleSessions()
    #expect(sm.sessions["a"]?.state == .juggling)
}

// MARK: - Inactivity

@MainActor
@Test func inactivitySleep() async {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    await fireOneshot(sm, expecting: .idle)
    sm.backdateLastEvent(seconds: 61)
    sm.checkInactivity()
    #expect(sm.currentDisplayState == .sleeping)
}

@MainActor
@Test func noInactivityWithin60s() async {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .idle, event: "SessionStart")
    sm.oneshotTimer?.fire()
    sm.backdateLastEvent(seconds: 59)
    sm.checkInactivity()
    #expect(sm.currentDisplayState == .idle)  // not sleeping
}

@MainActor
@Test func activeSessionBlocksInactivitySleep() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.backdateLastEvent(seconds: 120)
    sm.checkInactivity()
    // Should NOT sleep while a session is actively working
    #expect(sm.currentDisplayState == .working)
}

@MainActor
@Test func activeThinkingBlocksInactivitySleep() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    sm.backdateLastEvent(seconds: 120)
    sm.checkInactivity()
    #expect(sm.currentDisplayState == .thinking)
}

@MainActor
@Test func activeJugglingBlocksInactivitySleep() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .juggling, event: "SubagentStart")
    sm.backdateLastEvent(seconds: 120)
    sm.checkInactivity()
    #expect(sm.currentDisplayState == .juggling)
}

// MARK: - Callbacks

@MainActor
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

@MainActor
@Test func sessionAddedNotFiredForExistingSession() {
    let sm = StateManager()
    var addedCount = 0
    sm.onSessionAdded = { _, _ in addedCount += 1 }
    sm.handleEvent(sessionId: "a", state: .idle, event: "SessionStart")
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    #expect(addedCount == 1)
}

@MainActor
@Test func sessionRemovedCallbackFired() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "abc", state: .thinking, event: "UserPromptSubmit")
    var removedId: String?
    sm.onSessionRemoved = { id in removedId = id }
    sm.handleEvent(sessionId: "abc", state: .sleeping, event: "SessionEnd")
    #expect(removedId == "abc")
    #expect(sm.sessionCount == 0)
}

@MainActor
@Test func sessionStateChangeCallbackFired() {
    let sm = StateManager()
    var changes: [(String, PetState)] = []
    sm.onSessionStateChange = { id, state in changes.append((id, state)) }
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    #expect(changes.count >= 2)
    #expect(changes.last?.1 == .working)
}

@MainActor
@Test func onStateChangeCallbackFired() {
    let sm = StateManager()
    var displayStates: [PetState] = []
    sm.onStateChange = { state in displayStates.append(state) }
    sm.handleEvent(sessionId: "a", state: .thinking, event: "UserPromptSubmit")
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    #expect(displayStates.contains(.thinking))
    #expect(displayStates.contains(.working))
}

@MainActor
@Test func onStateChangeNotFiredWhenSameState() {
    let sm = StateManager()
    var callCount = 0
    sm.onStateChange = { _ in callCount += 1 }
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    let countAfterFirst = callCount
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    #expect(callCount == countAfterFirst)  // no duplicate callback
}

@MainActor
@Test func notificationCallbackWithMessage() {
    let sm = StateManager()
    var messages: [(String, String)] = []
    sm.onSessionNotification = { id, msg in messages.append((id, msg)) }
    sm.handleEvent(sessionId: "a", state: .notification, event: "Notification", message: "hello")
    #expect(messages.count == 1)
    #expect(messages[0].0 == "a")
    #expect(messages[0].1 == "hello")
}

@MainActor
@Test func notificationCallbackNotFiredWithEmptyMessage() {
    let sm = StateManager()
    var notified = false
    sm.onSessionNotification = { _, _ in notified = true }
    sm.handleEvent(sessionId: "a", state: .notification, event: "Notification")
    #expect(!notified)
}

// MARK: - PetState Priority

@MainActor
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

@MainActor
@Test func formatModelNameOpus() {
    #expect(formatModelName("claude-opus-4-6") == "Opus 4.6")
}

@MainActor
@Test func formatModelNameSonnet() {
    #expect(formatModelName("claude-sonnet-4-6") == "Sonnet 4.6")
}

@MainActor
@Test func formatModelNameHaiku() {
    #expect(formatModelName("claude-haiku-4-5") == "Haiku 4.5")
}

@MainActor
@Test func formatModelNameUnknownPassthrough() {
    #expect(formatModelName("gpt-4o") == "gpt-4o")
}

@MainActor
@Test func formatModelNameShortStringReturnsNameOnly() {
    #expect(formatModelName("opus") == "Opus")
}

// MARK: - Edge Cases

@MainActor
@Test func sessionEndForNonexistentSessionIsNoOp() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "ghost", state: .sleeping, event: "SessionEnd")
    #expect(sm.sessionCount == 0)
    #expect(sm.currentDisplayState == .idle)
}

@MainActor
@Test func rapidStopDoesNotCrash() async {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    await fireOneshot(sm, expecting: .idle)
    #expect(sm.currentDisplayState == .idle)
}

@MainActor
@Test func errorDuringOneshotHappyOverrides() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .working, event: "PreToolUse")
    sm.handleEvent(sessionId: "a", state: .idle, event: "Stop")
    #expect(sm.currentDisplayState == .happy)
    // Error during happy oneshot should override
    sm.handleEvent(sessionId: "a", state: .error, event: "PostToolUseFailure")
    #expect(sm.currentDisplayState == .error)
}

@MainActor
@Test func subagentStopResetsToIdle() {
    let sm = StateManager()
    sm.handleEvent(sessionId: "a", state: .juggling, event: "SubagentStart")
    #expect(sm.currentDisplayState == .juggling)
    sm.handleEvent(sessionId: "a", state: .idle, event: "SubagentStop")
    #expect(sm.currentDisplayState == .idle)
}
