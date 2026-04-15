import Foundation

/// "claude-opus-4-6" → "Opus 4.6"
public func formatModelName(_ raw: String) -> String {
    let name: String
    if raw.contains("opus") { name = "Opus" }
    else if raw.contains("sonnet") { name = "Sonnet" }
    else if raw.contains("haiku") { name = "Haiku" }
    else { return raw }
    let parts = raw.components(separatedBy: "-")
    if parts.count >= 4 {
        return "\(name) \(parts[2]).\(parts[3])"
    }
    return name
}

public enum PetState: String, Equatable, Sendable {
    case idle, thinking, working, juggling, error, notification, happy, sleeping

    public var priority: Int {
        switch self {
        case .juggling: return 4
        case .working: return 3
        case .thinking: return 2
        case .idle: return 1
        case .sleeping: return 0
        case .error, .notification, .happy: return 99  // oneshots
        }
    }
}

public enum ContextBand: String, Equatable, Sendable {
    case normal, cautious, compactSoon, urgent, critical

    var level: Int {
        switch self {
        case .normal: return 0
        case .cautious: return 1
        case .compactSoon: return 2
        case .urgent: return 3
        case .critical: return 4
        }
    }
}

public struct SessionMeta: Sendable {
    public var transcriptPath: String
    public var lastPrompt: String
    public var lastTool: String
    public var permissionMode: String
    public var startedAt: Date
    public var contextUsedPct: Double = 0
    public var contextCurrentUsage: Int = 0
    public var modelName: String = ""
    public var sessionName: String = ""
    public var contextBand: ContextBand = .normal
    public var lastAlertBand: ContextBand = .normal
    public var highContextStrikeCount: Int = 0
    public var lastHighContextAt: Date?
    public var lastSuggestionKey: String = ""
}

public struct Session: Sendable {
    public var state: PetState
    public var updatedAt: Date
    public var stoppedAt: Date?
    public var cwd: String
    public var meta: SessionMeta
}

@MainActor
public final class StateManager {
    public private(set) var sessions: [String: Session] = [:]
    public private(set) var currentDisplayState: PetState = .idle
    private var lastEventAt: Date = Date()
    private var globalStoppedAt: Date?  // global Stop timestamp — blocks working from ANY session
    private var isOneshot = false
    public var oneshotTimer: Timer?
    public var onStateChange: ((PetState) -> Void)?
    public var onSessionAdded: ((String, Session) -> Void)?
    public var onSessionStateChange: ((String, PetState) -> Void)?
    public var onSessionRemoved: ((String) -> Void)?
    public var onSessionNotification: ((String, String) -> Void)?  // (sessionId, message)

    public var sessionCount: Int { sessions.count }

    public init() {}

    public func handleEvent(sessionId: String, state: PetState, event: String, cwd: String = "",
                            transcriptPath: String = "", toolName: String = "", prompt: String = "",
                            permissionMode: String = "", message: String = "") {
        let msg = "ClaudePet: event=\(event) state=\(state) session=\(sessionId) isOneshot=\(isOneshot) display=\(currentDisplayState)\n"
        FileHandle.standardError.write(msg.data(using: .utf8)!)
        lastEventAt = Date()

        if event == "SessionEnd" {
            onSessionRemoved?(sessionId)
            sessions.removeValue(forKey: sessionId)
            resolve()
            return
        }

        let isNewSession = sessions[sessionId] == nil
        var session = sessions[sessionId] ?? Session(
            state: .idle,
            updatedAt: Date(),
            stoppedAt: nil,
            cwd: cwd,
            meta: SessionMeta(
                transcriptPath: transcriptPath,
                lastPrompt: prompt,
                lastTool: "",
                permissionMode: permissionMode,
                startedAt: Date()
            )
        )
        if isNewSession {
            onSessionAdded?(sessionId, session)
        } else {
            if !cwd.isEmpty { session.cwd = cwd }
            if !transcriptPath.isEmpty { session.meta.transcriptPath = transcriptPath }
            if !permissionMode.isEmpty { session.meta.permissionMode = permissionMode }
        }
        // Always update volatile fields
        if !prompt.isEmpty { session.meta.lastPrompt = prompt }
        if !toolName.isEmpty { session.meta.lastTool = toolName }

        // Stop → brief happy, then force idle (not resolve, to avoid race condition)
        if event == "Stop" {
            session.state = .idle
            session.stoppedAt = Date()
            session.updatedAt = Date()
            sessions[sessionId] = session
            globalStoppedAt = Date()
            if !message.isEmpty {
                onSessionNotification?(sessionId, message)
            }
            onSessionStateChange?(sessionId, .happy)
            showOneshot(.happy, duration: 5.2, thenForce: .idle, sessionId: sessionId)
            return
        }

        // UserPromptSubmit clears stoppedAt (both per-session and global)
        if event == "UserPromptSubmit" {
            session.stoppedAt = nil
            globalStoppedAt = nil
        }

        // Ignore working/juggling within 5s of Stop — check GLOBAL stoppedAt
        // (handles case where late events arrive with different session_id e.g. "default")
        if (state == .working || state == .juggling) {
            if let gStop = globalStoppedAt, Date().timeIntervalSince(gStop) < 5.0 {
                return
            }
            if let sStop = session.stoppedAt, Date().timeIntervalSince(sStop) < 5.0 {
                return
            }
        }

        // Clear persistent notification when a new user action arrives
        if isOneshot && currentDisplayState == .notification
            && (state != .notification && state != .error) {
            isOneshot = false
        }

        // Oneshot states: error (5s), notification (persistent)
        if state == .error {
            session.updatedAt = Date()
            sessions[sessionId] = session
            onSessionStateChange?(sessionId, .error)
            showOneshot(.error, duration: 5.0, sessionId: sessionId)
            return
        }
        if state == .notification {
            session.updatedAt = Date()
            sessions[sessionId] = session
            onSessionStateChange?(sessionId, .notification)
            if !message.isEmpty {
                onSessionNotification?(sessionId, message)
            }
            if event == "Elicitation" || event == "PermissionRequest" {
                // Stay in notification state until user acts
                isOneshot = true
                updateDisplay(.notification)
            } else {
                showOneshot(.notification, duration: 4.0, sessionId: sessionId)
            }
            return
        }

        session.state = state
        session.updatedAt = Date()
        sessions[sessionId] = session
        onSessionStateChange?(sessionId, state)
        resolve()
    }

    private func showOneshot(_ state: PetState, duration: TimeInterval, thenForce: PetState? = nil, sessionId: String? = nil) {
        isOneshot = true
        updateDisplay(state)
        oneshotTimer?.invalidate()
        oneshotTimer = Timer.scheduledTimer(
            withTimeInterval: duration,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isOneshot = false
                if let forced = thenForce {
                    self.updateDisplay(forced)
                    if let sid = sessionId {
                        self.onSessionStateChange?(sid, forced)
                    }
                } else {
                    self.resolve()
                    // After resolve, notify per-session with the resolved state for this session
                    if let sid = sessionId, let session = self.sessions[sid] {
                        self.onSessionStateChange?(sid, session.state)
                    }
                }
            }
        }
    }

    public func resolve() {
        if isOneshot { return }
        let resolved = resolveDisplayState()
        updateDisplay(resolved)
    }

    private func resolveDisplayState() -> PetState {
        if sessions.isEmpty { return .idle }
        var best: PetState = .sleeping
        for (_, session) in sessions {
            if session.state.priority > best.priority {
                best = session.state
            }
        }
        return best
    }

    private func updateDisplay(_ state: PetState) {
        if state != currentDisplayState {
            currentDisplayState = state
            onStateChange?(state)
        }
    }

    public func cleanStaleSessions() {
        // No-op: active states (working/thinking/juggling) should persist until
        // an explicit Stop event arrives. Previously this downgraded them to idle
        // after 30s, which caused the pet to sleep while Claude was still working.
    }

    public func updateContext(sessionId: String, usedPct: Double, currentUsage: Int, modelName: String, sessionName: String) {
        guard var session = sessions[sessionId] else { return }
        let previousMeta = session.meta

        session.meta.contextUsedPct = usedPct
        session.meta.contextCurrentUsage = currentUsage
        if !modelName.isEmpty { session.meta.modelName = modelName }
        if !sessionName.isEmpty { session.meta.sessionName = sessionName }

        let newBand = contextBand(for: usedPct)
        session.meta.contextBand = newBand
        updateHighContextStrike(for: &session.meta, previousBand: previousMeta.contextBand, newBand: newBand)

        if let alert = contextAlert(for: session, previousMeta: previousMeta) {
            session.meta.lastAlertBand = newBand
            session.meta.lastSuggestionKey = alert.key
            onSessionNotification?(sessionId, alert.message)
        }

        sessions[sessionId] = session
    }

    public func checkInactivity() {
        // Only sleep if no session is in an active state.
        // Active states (working/thinking/juggling) persist until an explicit Stop.
        let hasActive = sessions.values.contains { s in
            s.state == .working || s.state == .thinking || s.state == .juggling
        }
        if hasActive { return }

        let elapsed = Date().timeIntervalSince(lastEventAt)
        if elapsed >= 60 {
            updateDisplay(.sleeping)
        }
    }

    private func contextBand(for usedPct: Double) -> ContextBand {
        if usedPct >= 95 { return .critical }
        if usedPct >= 85 { return .urgent }
        if usedPct >= 75 { return .compactSoon }
        if usedPct >= 60 { return .cautious }
        return .normal
    }

    private func updateHighContextStrike(for meta: inout SessionMeta, previousBand: ContextBand, newBand: ContextBand) {
        let now = Date()
        if newBand == .normal {
            if let lastHighContextAt = meta.lastHighContextAt,
               now.timeIntervalSince(lastHighContextAt) > 600 {
                meta.highContextStrikeCount = 0
                meta.lastHighContextAt = nil
            }
            meta.lastAlertBand = .normal
            meta.lastSuggestionKey = ""
            return
        }

        if previousBand == .normal || newBand.level != previousBand.level {
            if let lastHighContextAt = meta.lastHighContextAt,
               now.timeIntervalSince(lastHighContextAt) > 180 {
                meta.highContextStrikeCount = 0
            }
            meta.highContextStrikeCount += 1
            meta.lastHighContextAt = now
            return
        }

        if let lastHighContextAt = meta.lastHighContextAt,
           now.timeIntervalSince(lastHighContextAt) > 180 {
            meta.highContextStrikeCount += 1
            meta.lastHighContextAt = now
        }
    }

    private func contextSuggestion(for meta: SessionMeta) -> (key: String, message: String) {
        switch meta.contextBand {
        case .critical:
            return (
                key: meta.highContextStrikeCount >= 4 ? "critical-strikes" : "critical",
                message: meta.highContextStrikeCount >= 4
                    ? "你已经连续 4 次处在高 context 区间，建议尽快结束当前子任务并开新 session"
                    : "这个 session 接近窗口极限，建议尽快结束当前子任务并开新 session"
            )
        case .urgent:
            return (
                key: meta.highContextStrikeCount >= 4 ? "urgent-strikes" : "urgent",
                message: meta.highContextStrikeCount >= 4
                    ? "你已经连续 4 次处在高 context 区间，建议 compact 或尽快收尾当前子任务"
                    : "这个 session 接近窗口极限，建议 compact soon，并准备收尾当前子任务"
            )
        case .compactSoon:
            return (key: "compactSoon", message: "context 已经偏高，compact soon")
        case .cautious:
            return (key: "cautious", message: "context 到 60% 了，开始谨慎")
        case .normal:
            return (key: "", message: "")
        }
    }

    private func contextAlert(for session: Session, previousMeta: SessionMeta) -> (key: String, message: String)? {
        let meta = session.meta
        guard meta.contextBand != .normal else { return nil }

        let suggestion = contextSuggestion(for: meta)
        if suggestion.key.isEmpty { return nil }

        let bandEscalated = meta.contextBand != previousMeta.contextBand && meta.contextBand.rawValue != previousMeta.contextBand.rawValue
        let strikesReached = meta.highContextStrikeCount >= 4 && previousMeta.highContextStrikeCount < 4
        let suggestionChanged = previousMeta.lastSuggestionKey != suggestion.key

        if bandEscalated || strikesReached || suggestionChanged {
            return suggestion
        }
        return nil
    }

    // MARK: - Test Helpers

    public func backdateSession(_ id: String, seconds: TimeInterval) {
        guard let session = sessions[id] else { return }
        sessions[id] = Session(
            state: session.state,
            updatedAt: Date().addingTimeInterval(-seconds),
            stoppedAt: session.stoppedAt,
            cwd: session.cwd,
            meta: session.meta
        )
    }

    public func backdateLastEvent(seconds: TimeInterval) {
        lastEventAt = Date().addingTimeInterval(-seconds)
    }
}
