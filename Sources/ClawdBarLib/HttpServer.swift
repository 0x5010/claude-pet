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

public final class HttpServer: @unchecked Sendable {
    private var listener: NWListener?
    public var onStateEvent: ((HookEvent) -> Void)?
    public var onContextUpdate: ((String, ContextInfo) -> Void)?  // (sessionId, info)

    public init() {}

    public func start(port: UInt16 = 23333) {
        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            print("ClawdBar: failed to create listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("ClawdBar: listening on port \(port)")
            case .failed(let error):
                print("ClawdBar: listener failed: \(error)")
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let data = data, error == nil else {
                connection.cancel()
                return
            }
            self?.parseHttpRequest(data: data, connection: connection)
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
            // current_usage can be an Int (legacy) or a nested object from statusLine
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
        } else {
            sendResponse(connection: connection, status: 404, body: "not found")
        }
    }

    private func sendResponse(connection: NWConnection, status: Int, body: String) {
        let statusText: String = switch status { case 200: "OK"; case 404: "Not Found"; default: "Bad Request" }
        let response = "HTTP/1.1 \(status) \(statusText)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
