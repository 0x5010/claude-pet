import Foundation
import Network

public struct ContextInfo {
    public let usedPercentage: Double
    public let currentUsage: Int
    public let modelName: String
    public let sessionName: String
}

public struct HookEvent {
    public let state: String
    public let sessionId: String
    public let event: String
    public let cwd: String
    public let transcriptPath: String
    public let toolName: String
    public let prompt: String
    public let permissionMode: String
    public let message: String
}

public struct PendingPermissionRequest {
    public let requestId: String
    public let sessionId: String
    public let toolName: String
    public let toolInput: String
}

public enum PermissionBehavior: String {
    case allow
    case deny
}

public struct PermissionDecision {
    public let behavior: PermissionBehavior
    public let message: String?

    public init(behavior: PermissionBehavior, message: String? = nil) {
        self.behavior = behavior
        self.message = message
    }
}

public final class HttpServer: @unchecked Sendable {
    private var listener: NWListener?
    private var pendingPermissionConnections: [String: NWConnection] = [:]
    private var permissionShownAt: [String: Date] = [:]
    private let minBubbleDisplayTime: TimeInterval = 5.0

    public var onStateEvent: ((HookEvent) -> Void)?
    public var onContextUpdate: ((String, ContextInfo) -> Void)?
    public var onPermissionRequest: ((PendingPermissionRequest) -> Void)?
    public var onPermissionDismiss: ((String) -> Void)?  // sessionId

    public init() {}

    public func start(port: UInt16 = 23333) {
        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            print("ClaudePet: failed to create listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("ClaudePet: listening on port \(port)")
            case .failed(let error):
                print("ClaudePet: listener failed: \(error)")
            default:
                break
            }
        }

        listener?.start(queue: .main)
    }

    public func stop() {
        listener?.cancel()
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.checkPermissionConnectionClosed(connection)
            default:
                break
            }
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if isComplete || error != nil {
                self?.checkPermissionConnectionClosed(connection)
                connection.cancel()
                return
            }
            guard let data = data else {
                connection.cancel()
                return
            }
            self?.parseHttpRequest(data: data, connection: connection)
        }
    }

    private func checkPermissionConnectionClosed(_ connection: NWConnection) {
        for (requestId, pendingConn) in pendingPermissionConnections {
            if pendingConn === connection {
                let sessionId = requestId.components(separatedBy: "_").first ?? ""
                guard let shownAt = permissionShownAt[requestId] else { continue }

                let elapsed = Date().timeIntervalSince(shownAt)
                if elapsed >= minBubbleDisplayTime {
                    pendingPermissionConnections.removeValue(forKey: requestId)
                    permissionShownAt.removeValue(forKey: requestId)
                    DispatchQueue.main.async {
                        self.onPermissionDismiss?(sessionId)
                    }
                } else {
                    let remainingTime = minBubbleDisplayTime - elapsed
                    DispatchQueue.main.asyncAfter(deadline: .now() + remainingTime) { [weak self] in
                        if self?.pendingPermissionConnections[requestId] != nil {
                            self?.pendingPermissionConnections.removeValue(forKey: requestId)
                            self?.permissionShownAt.removeValue(forKey: requestId)
                            self?.onPermissionDismiss?(sessionId)
                        }
                    }
                }
                break
            }
        }
    }

    private func parseHttpRequest(data: Data, connection: NWConnection) {
        guard let raw = String(data: data, encoding: .utf8) else {
            sendResponse(connection: connection, status: 400, body: "bad encoding")
            return
        }

        guard let headerEnd = raw.range(of: "\r\n\r\n") else {
            sendResponse(connection: connection, status: 400, body: "malformed request")
            return
        }

        let headerPart = raw[raw.startIndex..<headerEnd.lowerBound]
        let bodyPart = raw[headerEnd.upperBound...]

        let firstLine = headerPart.split(separator: "\r\n").first ?? ""

        guard let jsonData = bodyPart.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            sendResponse(connection: connection, status: 400, body: "bad json")
            return
        }

        if firstLine.hasPrefix("POST /state") {
            guard let state = json["state"] as? String,
                  let sessionId = json["session_id"] as? String,
                  let event = json["event"] as? String else {
                sendResponse(connection: connection, status: 400, body: "missing fields")
                return
            }
            let hookEvent = HookEvent(
                state: state,
                sessionId: sessionId,
                event: event,
                cwd: json["cwd"] as? String ?? "",
                transcriptPath: json["transcript_path"] as? String ?? "",
                toolName: json["tool_name"] as? String ?? "",
                prompt: json["prompt"] as? String ?? "",
                permissionMode: json["permission_mode"] as? String ?? "",
                message: json["message"] as? String ?? ""
            )
            onStateEvent?(hookEvent)
            sendResponse(connection: connection, status: 200, body: "ok")
        } else if firstLine.hasPrefix("POST /context") {
            let ctxWindow = json["context_window"] as? [String: Any] ?? [:]
            let model = json["model"] as? [String: Any] ?? [:]
            let sessionId = json["session_id"] as? String ?? ""
            let currentUsage: Int
            if let directValue = ctxWindow["current_usage"] as? Int {
                currentUsage = directValue
            } else if let usageObj = ctxWindow["current_usage"] as? [String: Any] {
                let input = usageObj["input_tokens"] as? Int ?? 0
                let output = usageObj["output_tokens"] as? Int ?? 0
                currentUsage = input + output
            } else {
                currentUsage = 0
            }
            let info = ContextInfo(
                usedPercentage: ctxWindow["used_percentage"] as? Double ?? 0,
                currentUsage: currentUsage,
                modelName: model["display_name"] as? String ?? "",
                sessionName: json["session_name"] as? String ?? ""
            )
            onContextUpdate?(sessionId, info)
            sendResponse(connection: connection, status: 200, body: "ok")
        } else if firstLine.hasPrefix("POST /permission") {
            guard let sessionId = json["session_id"] as? String, !sessionId.isEmpty else {
                sendResponse(connection: connection, status: 400, body: "missing session_id")
                return
            }
            let requestId = sessionId + "_" + UUID().uuidString
            let pending = PendingPermissionRequest(
                requestId: requestId,
                sessionId: sessionId,
                toolName: json["tool_name"] as? String ?? "",
                toolInput: Self.stringifyJSON(json["tool_input"])
            )
            pendingPermissionConnections[requestId] = connection
            permissionShownAt[requestId] = Date()

            if let onPermissionRequest {
                onPermissionRequest(pending)
            } else {
                resolvePermission(requestId: requestId, decision: PermissionDecision(behavior: .deny, message: "permission handler unavailable"))
            }
        } else {
            sendResponse(connection: connection, status: 404, body: "not found")
        }
    }

    public func resolvePermission(requestId: String, decision: PermissionDecision) {
        guard let connection = pendingPermissionConnections.removeValue(forKey: requestId) else { return }
        permissionShownAt.removeValue(forKey: requestId)

        var payload: [String: Any] = [
            "behavior": decision.behavior.rawValue
        ]
        if let message = decision.message, !message.isEmpty {
            payload["message"] = message
        }

        let responseObj: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": payload
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: responseObj, options: [])) ?? Data("{}".utf8)
        let body = String(data: data, encoding: .utf8) ?? "{}"
        sendResponse(connection: connection, status: 200, body: body)
    }

    public func pendingPermissionCount() -> Int {
        pendingPermissionConnections.count
    }

    private static func stringifyJSON(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String { return text }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: []),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return ""
    }

    private func sendResponse(connection: NWConnection, status: Int, body: String) {
        let statusText: String = switch status { case 200: "OK"; case 404: "Not Found"; default: "Bad Request" }
        let response = "HTTP/1.1 \(status) \(statusText)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
