import Foundation
import Testing
@testable import ClaudePetLib

private func sendRawHttpRequest(path: String, body: String, port: UInt16) async -> String {
    await withCheckedContinuation { continuation in
        let task = Task.detached(priority: .userInitiated) {
            do {
                let input = InputStream(url: URL(string: "http://127.0.0.1")!)
                _ = input
            }
        }
        _ = task

        DispatchQueue.global().async {
            var readStream: Unmanaged<CFReadStream>?
            var writeStream: Unmanaged<CFWriteStream>?
            CFStreamCreatePairWithSocketToHost(
                nil,
                "127.0.0.1" as CFString,
                UInt32(port),
                &readStream,
                &writeStream
            )

            guard let readRef = readStream?.takeRetainedValue(),
                  let writeRef = writeStream?.takeRetainedValue() else {
                continuation.resume(returning: "")
                return
            }

            let input = readRef as InputStream
            let output = writeRef as OutputStream
            input.open()
            output.open()
            defer {
                input.close()
                output.close()
            }

            let request = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            let bytes = Array(request.utf8)
            _ = bytes.withUnsafeBytes { raw in
                output.write(raw.bindMemory(to: UInt8.self).baseAddress!, maxLength: bytes.count)
            }

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = input.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }

            continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
        }
    }
}

@Test("permission request callback + allow response")
@MainActor
func permissionAllowResponse() async {
    let port: UInt16 = 23339
    let server = HttpServer()
    var captured: PendingPermissionRequest?

    server.onPermissionRequest = { pending in
        captured = pending
        server.resolvePermission(requestId: pending.requestId, decision: PermissionDecision(behavior: .allow))
    }

    server.start(port: port)
    defer { server.stop() }

    let body = "{\"session_id\":\"s-allow\",\"tool_name\":\"Edit\",\"tool_input\":{\"file\":\"a.swift\"}}"
    let response = await sendRawHttpRequest(path: "/permission", body: body, port: port)

    #expect(captured != nil)
    #expect(captured?.sessionId == "s-allow")
    #expect(captured?.toolName == "Edit")
    #expect(response.contains("HTTP/1.1 200 OK"))
    #expect(response.contains("\"hookEventName\":\"PermissionRequest\""))
    #expect(response.contains("\"behavior\":\"allow\""))
}

@Test("permission request callback + deny response")
@MainActor
func permissionDenyResponse() async {
    let port: UInt16 = 23340
    let server = HttpServer()

    server.onPermissionRequest = { pending in
        server.resolvePermission(
            requestId: pending.requestId,
            decision: PermissionDecision(behavior: .deny, message: "blocked")
        )
    }

    server.start(port: port)
    defer { server.stop() }

    let body = "{\"session_id\":\"s-deny\",\"tool_name\":\"Bash\"}"
    let response = await sendRawHttpRequest(path: "/permission", body: body, port: port)

    #expect(response.contains("HTTP/1.1 200 OK"))
    #expect(response.contains("\"behavior\":\"deny\""))
    #expect(response.contains("\"message\":\"blocked\""))
}
