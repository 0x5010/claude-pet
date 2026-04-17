import AppKit
import ClaudePetCore
import QuartzCore

// MARK: - StatusBarInstance

@MainActor
private final class StatusBarInstance {
    let sessionId: String
    private(set) var cwd: String
    private let statusItem: NSStatusItem
    private(set) var currentState: PetState = .idle
    private let frameCache: [PetState: [NSImage]]
    private let cgFrameCache: [PetState: [CGImage]]
    private let contextFrameCache: [PetState: [ContextBand: [NSImage]]]
    private let contextCGFrameCache: [PetState: [ContextBand: [CGImage]]]
    weak var stateManager: StateManager?
    var lastEventAt: Date = Date()
    let createdAt: Date = Date()
    let bubble = NotificationBubble()

    private static let fps: [PetState: Double] = [
        .idle: 4, .thinking: 6, .working: 10, .juggling: 6,
        .error: 8, .notification: 4, .happy: 6, .sleeping: 3,
    ]

    private static let stateNames: [(PetState, String)] = [
        (.idle, "Idle - 空闲"),
        (.thinking, "Thinking - 思考中"),
        (.working, "Working - 工作中"),
        (.juggling, "Juggling - 多任务"),
        (.error, "Error - 出错了"),
        (.notification, "Notification - 注意"),
        (.happy, "Happy - 完成"),
        (.sleeping, "Sleeping - 休眠中"),
    ]

    init(sessionId: String, cwd: String, frameCache: [PetState: [NSImage]], cgFrameCache: [PetState: [CGImage]],
         contextFrameCache: [PetState: [ContextBand: [NSImage]]], contextCGFrameCache: [PetState: [ContextBand: [CGImage]]]) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.frameCache = frameCache
        self.cgFrameCache = cgFrameCache
        self.contextFrameCache = contextFrameCache
        self.contextCGFrameCache = contextCGFrameCache
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupButton()
        transitionTo(.idle)
    }

    func updateCwd(_ newCwd: String) {
        guard !newCwd.isEmpty else { return }
        cwd = newCwd
    }

    // MARK: - Button setup

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusBarClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.modifierFlags.contains(.option) {
            NSApp.terminate(nil)
        } else {
            showMenu()
        }
    }

    // MARK: - Menu

    private static let menuWidth: CGFloat = 244
    private static let cardInset: CGFloat = 10
    private static let cardPad: CGFloat = 8

    private func runGit(cwd: String, args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd, "--no-optional-locks"] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }

    private func getGitInfo(cwd: String) -> String {
        let branch = runGit(cwd: cwd, args: ["symbolic-ref", "--short", "HEAD"])
        guard !branch.isEmpty else { return "" }
        let toplevel = runGit(cwd: cwd, args: ["rev-parse", "--show-toplevel"])
        let repo = (toplevel as NSString).lastPathComponent
        return "\(repo):\(branch)"
    }

    private func contextBarColor(for band: ContextBand, percent: Int) -> NSColor {
        switch band {
        case .normal:
            return percent <= 40 ? .systemGreen : .systemYellow
        case .cautious:
            return .systemYellow
        case .compactSoon:
            return NSColor(red: 1.0, green: 0.53, blue: 0, alpha: 1)
        case .urgent, .critical:
            return .systemRed
        }
    }

    private func contextBandLabel(_ band: ContextBand) -> String {
        switch band {
        case .normal: return "Healthy"
        case .cautious: return "Be careful"
        case .compactSoon: return "Compact soon"
        case .urgent: return "Near limit"
        case .critical: return "Critical"
        }
    }

    private func contextHintText(meta: SessionMeta) -> String {
        switch meta.contextBand {
        case .normal:
            return "Safe"
        case .cautious:
            return "Keep prompts short"
        case .compactSoon:
            return "Compact now"
        case .urgent:
            return meta.highContextStrikeCount >= 4
                ? "Compact now, prepare a new session"
                : "Compact now and wrap up"
        case .critical:
            return meta.highContextStrikeCount >= 4
                ? "Stop and open a new session"
                : "Finish now, then restart"
        }
    }

    /// Ultra-compact context card with one line + progress bar
    private func makeContextCard(meta: SessionMeta) -> NSView {
        let w = Self.menuWidth
        let percent = Int(meta.contextUsedPct)
        let h: CGFloat = 40
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h + 2))

        let card = NSView(frame: NSRect(x: Self.cardInset, y: 1, width: w - Self.cardInset * 2, height: h))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        card.layer?.cornerRadius = 7
        wrapper.addSubview(card)

        let cw = card.frame.width
        let p = Self.cardPad
        let barColor = contextBarColor(for: meta.contextBand, percent: percent)

        let titleLabel = NSTextField(labelWithString: "Context · \(contextBandLabel(meta.contextBand))")
        titleLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: p, y: h - 17, width: cw - p * 2 - 42, height: 12)
        card.addSubview(titleLabel)

        let pctLabel = NSTextField(labelWithString: "\(percent)%")
        pctLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        pctLabel.textColor = barColor
        pctLabel.alignment = .right
        pctLabel.frame = NSRect(x: cw - p - 42, y: h - 18, width: 42, height: 14)
        card.addSubview(pctLabel)

        let barY: CGFloat = 8
        let barW = cw - p * 2
        let barBg = NSView(frame: NSRect(x: p, y: barY, width: barW, height: 4))
        barBg.wantsLayer = true
        barBg.layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.25).cgColor
        barBg.layer?.cornerRadius = 2
        card.addSubview(barBg)

        let fillW = max(0, barW * CGFloat(percent) / 100.0)
        let barFill = NSView(frame: NSRect(x: p, y: barY, width: fillW, height: 4))
        barFill.wantsLayer = true
        barFill.layer?.backgroundColor = barColor.cgColor
        barFill.layer?.cornerRadius = 2
        card.addSubview(barFill)

        return wrapper
    }

    /// Simple info card (title + value, no bar)
    private func makeInfoCard(title: String, value: String) -> NSView {
        let w = Self.menuWidth
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: w, height: 36))

        let card = NSView(frame: NSRect(x: Self.cardInset, y: 1, width: w - Self.cardInset * 2, height: 32))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        card.layer?.cornerRadius = 7
        wrapper.addSubview(card)

        let cw = card.frame.width
        let p = Self.cardPad

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: p, y: 8, width: cw * 0.38, height: 14)
        card.addSubview(titleLabel)

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = NSFont.systemFont(ofSize: 11)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.frame = NSRect(x: cw * 0.38, y: 8, width: cw * 0.62 - p, height: 14)
        card.addSubview(valueLabel)

        return wrapper
    }

    func showMenu() {
        let menu = NSMenu()

        let projectName: String = !cwd.isEmpty ?
            (cwd as NSString).lastPathComponent : String(sessionId.prefix(8))

        let session = stateManager?.sessions[sessionId]
        let meta = session?.meta
        let currentName = Self.stateNames.first(where: { $0.0 == currentState })?.1 ?? "Unknown"

        // Session + Status cards
        let sessionItem = NSMenuItem()
        sessionItem.view = makeInfoCard(title: "Session", value: projectName)
        menu.addItem(sessionItem)

        // Extract English name from "Working - 工作中" → "Working"
        let englishName = currentName.components(separatedBy: " - ").first ?? currentName
        let statusMenuItem = NSMenuItem()
        statusMenuItem.view = makeInfoCard(title: "Status", value: englishName)
        menu.addItem(statusMenuItem)

        // Model card
        if let m = meta, !m.modelName.isEmpty {
            let modelItem = NSMenuItem()
            modelItem.view = makeInfoCard(title: "Model", value: formatModelName(m.modelName))
            menu.addItem(modelItem)
        }

        // Context Usage companion card
        if let m = meta, m.contextUsedPct > 0 {
            let contextItem = NSMenuItem()
            contextItem.view = makeContextCard(meta: m)
            menu.addItem(contextItem)
        }

        // Git info
        if !cwd.isEmpty {
            let branch = runGit(cwd: cwd, args: ["symbolic-ref", "--short", "HEAD"])
            if !branch.isEmpty {
                let gitItem = NSMenuItem()
                gitItem.view = makeInfoCard(title: "Git", value: branch)
                menu.addItem(gitItem)
            }
        }

        // Last prompt
        if let prompt = meta?.lastPrompt, !prompt.isEmpty {
            let truncated = prompt.count > 28 ? String(prompt.prefix(28)) + "…" : prompt
            let promptItem = NSMenuItem()
            promptItem.view = makeInfoCard(title: "Prompt", value: truncated)
            menu.addItem(promptItem)
        }

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func previewState(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let state = PetState(rawValue: rawValue) else { return }
        lastEventAt = Date()
        transitionTo(state)
    }

    func showBubble(message: String) {
        let dir = (cwd as NSString).lastPathComponent
        let title = dir.isEmpty ? "" : dir
        bubble.show(title: title, message: message, relativeTo: statusItem.button)
    }

    func showPermissionBubble(toolName: String, toolInput: String, onDecision: @escaping (PermissionDecision) -> Void) {
        let dir = (cwd as NSString).lastPathComponent
        let title = dir.isEmpty ? "" : dir
        let trimmedTool = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolText = trimmedTool.isEmpty ? "tool" : trimmedTool
        bubble.showPermission(
            title: title,
            message: "Allow \(toolText) to run?",
            toolInput: toolInput,
            relativeTo: statusItem.button,
            duration: 20.0,
            onAllow: { onDecision(PermissionDecision(behavior: .allow)) },
            onDeny: { onDecision(PermissionDecision(behavior: .deny)) }
        )
    }

    func dismissPermissionBubble() {
        bubble.dismissPermission()
    }

    // MARK: - State & animation (Core Animation driven)

    private static let animationKey = "claude-pet-frame-animation"
    private static let transparentImage: NSImage = {
        let img = NSImage(size: NSSize(width: 22, height: 22))
        return img
    }()

    func transitionTo(_ state: PetState, forceRefresh: Bool = false) {
        guard forceRefresh || state != currentState else { return }
        currentState = state
        applyAnimation(for: state)
    }

    private func frameSet(for state: PetState) -> (nsFrames: [NSImage], cgFrames: [CGImage])? {
        if state.supportsContextAppearance,
           let band = stateManager?.sessions[sessionId]?.meta.contextBand,
           let nsFrames = contextFrameCache[state]?[band], !nsFrames.isEmpty,
           let cgFrames = contextCGFrameCache[state]?[band], !cgFrames.isEmpty {
            return (nsFrames, cgFrames)
        }

        guard let nsFrames = frameCache[state], !nsFrames.isEmpty,
              let cgFrames = cgFrameCache[state], !cgFrames.isEmpty else { return nil }
        return (nsFrames, cgFrames)
    }

    private func applyAnimation(for state: PetState) {
        guard let button = statusItem.button,
              let frames = frameSet(for: state) else { return }

        let nsFrames = frames.nsFrames
        let cgFrames = frames.cgFrames

        // Remove existing animation sublayer
        button.layer?.sublayers?.first(where: { $0.name == "claude-pet-icon" })?.removeFromSuperlayer()

        // Set first frame for menu bar sizing; single-frame states use this directly
        button.image = nsFrames[0]

        guard cgFrames.count > 1 else { return }

        button.wantsLayer = true
        guard let parentLayer = button.layer else { return }

        // Clear the static image so it doesn't show behind the animation sublayer
        button.image = Self.transparentImage

        // Sublayer for CA-driven animation (avoids AppKit's expensive image-set pipeline)
        let iconLayer = CALayer()
        iconLayer.name = "claude-pet-icon"
        iconLayer.contentsGravity = .center
        iconLayer.magnificationFilter = .nearest
        iconLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        parentLayer.addSublayer(iconLayer)
        iconLayer.frame = parentLayer.bounds

        let fps = Self.fps[state] ?? 4.0
        let totalDuration = Double(cgFrames.count) / fps

        iconLayer.removeAnimation(forKey: Self.animationKey)

        let anim = CAKeyframeAnimation(keyPath: "contents")
        anim.values = cgFrames
        anim.duration = totalDuration
        anim.calculationMode = .discrete
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false

        iconLayer.add(anim, forKey: Self.animationKey)
    }

    // MARK: - Timer control (sleep/wake)

    func pauseAnimation() {
        let iconLayer = statusItem.button?.layer?.sublayers?.first(where: { $0.name == "claude-pet-icon" })
        guard let layer = iconLayer else { return }
        layer.speed = 0
        layer.timeOffset = layer.convertTime(CACurrentMediaTime(), from: nil)
    }

    func resumeAnimation() {
        let iconLayer = statusItem.button?.layer?.sublayers?.first(where: { $0.name == "claude-pet-icon" })
        guard let layer = iconLayer else { return }
        let pausedTime = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
    }

    /// Re-apply animation after screen change (e.g. external monitor connect/disconnect)
    func reapplyAnimation() {
        applyAnimation(for: currentState)
    }

    // MARK: - Teardown

    func destroy() {
        statusItem.button?.layer?.sublayers?.first(where: { $0.name == "claude-pet-icon" })?.removeFromSuperlayer()
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

// MARK: - MultiStatusBarController

@MainActor
public final class MultiStatusBarController {
    private let stateManager: StateManager
    private var instances: [String: StatusBarInstance] = [:]
    // No default instance — only real sessions get status bar icons
    private let frameCache: [PetState: [NSImage]]
    private let cgFrameCache: [PetState: [CGImage]]
    private let contextFrameCache: [PetState: [ContextBand: [NSImage]]]
    private let contextCGFrameCache: [PetState: [ContextBand: [CGImage]]]
    private let maxInstances = 5

    private var cleanupTimer: Timer?
    private var inactivityTimer: Timer?

    private static let defaultSessionId = "__default__"

    public init(stateManager: StateManager) {
        self.stateManager = stateManager
        let (nsCache, cgCache, contextNSCache, contextCGCache) = Self.preRenderFrames()
        self.frameCache = nsCache
        self.cgFrameCache = cgCache
        self.contextFrameCache = contextNSCache
        self.contextCGFrameCache = contextCGCache

        wireCallbacks()
        setupTimers()
    }

    // MARK: - Pre-render

    private static func preRenderFrames() -> (
        [PetState: [NSImage]],
        [PetState: [CGImage]],
        [PetState: [ContextBand: [NSImage]]],
        [PetState: [ContextBand: [CGImage]]]
    ) {
        let frameCounts: [PetState: Int] = [
            .idle: 8, .thinking: 8, .working: 6, .juggling: 8, .error: 8,
            .notification: 4, .happy: 6, .sleeping: 6,
        ]
        var nsCache: [PetState: [NSImage]] = [:]
        var cgCache: [PetState: [CGImage]] = [:]
        var contextNSCache: [PetState: [ContextBand: [NSImage]]] = [:]
        var contextCGCache: [PetState: [ContextBand: [CGImage]]] = [:]
        for (state, count) in frameCounts {
            let nsImages = (0..<count).map { frame in
                PixelRenderer.render(state: state, frame: frame, totalFrames: count)
            }
            nsCache[state] = nsImages
            cgCache[state] = nsImages.compactMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }

            guard state.supportsContextAppearance else { continue }
            var stateContextImages: [ContextBand: [NSImage]] = [:]
            var stateContextCGImages: [ContextBand: [CGImage]] = [:]
            for band in [ContextBand.normal, .cautious, .compactSoon, .urgent, .critical] {
                let bandImages = (0..<count).map { frame in
                    PixelRenderer.render(state: state, frame: frame, totalFrames: count, contextBand: band)
                }
                stateContextImages[band] = bandImages
                stateContextCGImages[band] = bandImages.compactMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
            }
            contextNSCache[state] = stateContextImages
            contextCGCache[state] = stateContextCGImages
        }
        return (nsCache, cgCache, contextNSCache, contextCGCache)
    }

    // MARK: - Instance management

    func addInstance(sessionId: String, cwd: String) {
        guard instances[sessionId] == nil else {
            // Update cwd if instance already exists
            instances[sessionId]?.updateCwd(cwd)
            return
        }
        guard instances.count < maxInstances else { return }

        let instance = StatusBarInstance(
            sessionId: sessionId,
            cwd: cwd,
            frameCache: frameCache,
            cgFrameCache: cgFrameCache,
            contextFrameCache: contextFrameCache,
            contextCGFrameCache: contextCGFrameCache
        )
        instance.stateManager = stateManager
        instances[sessionId] = instance
    }

    func removeInstance(sessionId: String) {
        guard let instance = instances.removeValue(forKey: sessionId) else { return }
        instance.destroy()
    }

    func updateInstance(sessionId: String, state: PetState) {
        // Auto-create instance if it doesn't exist (e.g. ClaudePet restarted mid-session)
        if instances[sessionId] == nil {
            let cwd = stateManager.sessions[sessionId]?.cwd ?? ""
            addInstance(sessionId: sessionId, cwd: cwd)
        }
        guard let instance = instances[sessionId] else { return }
        instance.lastEventAt = Date()
        instance.transitionTo(state)
    }

    public func showPermissionBubble(sessionId: String, toolName: String, toolInput: String, onDecision: @escaping (PermissionDecision) -> Void) {
        if instances[sessionId] == nil {
            let cwd = stateManager.sessions[sessionId]?.cwd ?? ""
            addInstance(sessionId: sessionId, cwd: cwd)
        }
        guard let instance = instances[sessionId] else {
            onDecision(PermissionDecision(behavior: .deny, message: "session unavailable"))
            return
        }
        instance.showPermissionBubble(toolName: toolName, toolInput: toolInput, onDecision: onDecision)
    }

    public func dismissPermissionBubble(sessionId: String) {
        instances[sessionId]?.dismissPermissionBubble()
    }

    // MARK: - StateManager callbacks

    private func wireCallbacks() {
        stateManager.onSessionAdded = { [weak self] sessionId, session in
            DispatchQueue.main.async {
                self?.addInstance(sessionId: sessionId, cwd: session.cwd)
            }
        }

        stateManager.onSessionStateChange = { [weak self] sessionId, state in
            DispatchQueue.main.async {
                self?.updateInstance(sessionId: sessionId, state: state)
            }
        }

        stateManager.onSessionRemoved = { [weak self] sessionId in
            DispatchQueue.main.async {
                self?.removeInstance(sessionId: sessionId)
            }
        }

        stateManager.onSessionNotification = { [weak self] sessionId, message in
            DispatchQueue.main.async {
                self?.instances[sessionId]?.showBubble(message: message)
            }
        }

        stateManager.onSessionAppearanceChange = { [weak self] sessionId in
            DispatchQueue.main.async {
                guard let instance = self?.instances[sessionId] else { return }
                instance.transitionTo(instance.currentState, forceRefresh: true)
            }
        }
    }

    // MARK: - Timers

    private func setupTimers() {
        // Cleanup stale sessions every 10s
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.stateManager.cleanStaleSessions()
            }
        }

        // Per-instance inactivity check every 10s
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkPerInstanceInactivity()
            }
        }

        // System sleep/wake
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pauseAllAnimations()
            }
        }
        ws.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resumeAllAnimations()
            }
        }

        // Screen change (external monitor connect/disconnect, resolution change)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reapplyAllAnimations()
            }
        }
    }

    private func checkPerInstanceInactivity() {
        let now = Date()
        for (_, instance) in instances {
            // Skip if this instance is actively working/thinking/juggling
            let activeStates: [PetState] = [.working, .thinking, .juggling]
            if activeStates.contains(instance.currentState) { continue }

            let elapsed = now.timeIntervalSince(instance.lastEventAt)
            if elapsed >= 60 && instance.currentState != .sleeping {
                instance.transitionTo(.sleeping)
            }
        }
    }

    private func pauseAllAnimations() {
        // defaultInstance removed
        for (_, instance) in instances {
            instance.pauseAnimation()
        }
    }

    private func resumeAllAnimations() {
        for (_, instance) in instances {
            instance.resumeAnimation()
        }
    }

    private func reapplyAllAnimations() {
        for (_, instance) in instances {
            instance.reapplyAnimation()
        }
    }
}
