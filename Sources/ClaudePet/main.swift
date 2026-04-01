import AppKit
import ClaudePetLib
import ClaudePetCore

class AppDelegate: NSObject, NSApplicationDelegate {
    var multiStatusBarController: MultiStatusBarController?
    let stateManager = StateManager()
    let httpServer = HttpServer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        multiStatusBarController = MultiStatusBarController(stateManager: stateManager)

        httpServer.onStateEvent = { [weak self] e in
            guard let petState = PetState(rawValue: e.state) else { return }
            self?.stateManager.handleEvent(
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

        httpServer.start(port: 23333)
        print("ClaudePet: running")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
