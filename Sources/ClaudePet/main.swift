import AppKit
import ClaudePetLib
import ClaudePetCore

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var multiStatusBarController: MultiStatusBarController?
    let stateManager = StateManager()
    let httpServer = HttpServer()
    private var pendingPermissionSessions = Set<String>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        multiStatusBarController = MultiStatusBarController(stateManager: stateManager)

        httpServer.onStateEvent = { [weak self] e in
            guard let self, let petState = PetState(rawValue: e.state) else { return }
            if self.pendingPermissionSessions.contains(e.sessionId), e.event == "PreToolUse" {
                self.multiStatusBarController?.dismissBubble(sessionId: e.sessionId)
                self.pendingPermissionSessions.remove(e.sessionId)
            }
            self.stateManager.handleEvent(
                sessionId: e.sessionId, state: petState, event: e.event, cwd: e.cwd,
                transcriptPath: e.transcriptPath, toolName: e.toolName,
                prompt: e.prompt, permissionMode: e.permissionMode,
                message: e.message
            )
        }

        httpServer.onContextUpdate = { [weak self] sessionId, info in
            self?.stateManager.updateContext(
                sessionId: sessionId, usedPct: info.usedPercentage,
                currentUsage: info.currentUsage, modelName: info.modelName,
                sessionName: info.sessionName
            )
        }

        httpServer.onPermissionRequest = { [weak self] pending in
            guard let self else { return }
            self.pendingPermissionSessions.insert(pending.sessionId)
            self.multiStatusBarController?.showPermissionBubble(
                sessionId: pending.sessionId,
                toolName: pending.toolName
            ) { [weak self] decision in
                self?.httpServer.resolvePermission(requestId: pending.requestId, decision: decision)
                self?.pendingPermissionSessions.remove(pending.sessionId)
                self?.stateManager.handleEvent(
                    sessionId: pending.sessionId,
                    state: .thinking,
                    event: "UserPromptSubmit"
                )
            }
        }

        httpServer.start(port: 23333)
        print("ClaudePet: running")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
