import Foundation
import ClaudePetCore

public struct TranscriptInfo {
    public var model: String
    public var tokenUsage: Int      // current usage
    public var tokenLimit: Int      // total limit

    public var usagePercent: Int {
        guard tokenLimit > 0 else { return 0 }
        return min(100, Int(Double(tokenUsage) / Double(tokenLimit) * 100))
    }

    public var progressBar: String {
        let total = 10
        let filled = Int(Double(usagePercent) / 100.0 * Double(total))
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: total - filled)
        return "\(bar)  \(usagePercent)%"
    }

    public var modelDisplay: String {
        let base = formatModelName(model)
        let ctx = tokenLimit > 0 ? " (\(tokenLimit / 1000)K context)" : ""
        return "\(base)\(ctx)"
    }
}

public struct TranscriptParser {
    /// Parse the last N lines of a transcript JSONL file to extract model + token usage
    public static func parse(path: String, tailLines: Int = 200) -> TranscriptInfo? {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }

        // Read last chunk of file efficiently
        guard let fileHandle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { fileHandle.closeFile() }

        let fileSize = fileHandle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, 262144)  // last 256KB
        fileHandle.seek(toFileOffset: fileSize - readSize)
        let data = fileHandle.availableData
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: "\n")

        var model = ""
        var tokenUsage = 0
        var tokenLimit = 0

        for line in lines.reversed() {
            if model.isEmpty, let range = line.range(of: "\"model\":\"") {
                let start = range.upperBound
                if let end = line[start...].firstIndex(of: "\"") {
                    model = String(line[start..<end])
                }
            }
            // Parse "Token usage: 165812/980000" from system-reminder
            if tokenUsage == 0, let range = line.range(of: "Token usage: ") {
                let start = range.upperBound
                let rest = String(line[start...])
                // Extract just the digits before and after "/"
                if let slashIdx = rest.firstIndex(of: "/") {
                    let usageStr = String(rest[rest.startIndex..<slashIdx]).filter { $0.isNumber }
                    let afterSlash = rest[rest.index(after: slashIdx)...]
                    let limitStr = String(afterSlash.prefix(while: { $0.isNumber }))
                    if let usage = Int(usageStr), let limit = Int(limitStr), usage > 0, limit > 0 {
                        tokenUsage = usage
                        tokenLimit = limit
                    }
                }
            }
            // Stop early if we found both
            if !model.isEmpty && tokenUsage > 0 { break }
        }

        guard !model.isEmpty else { return nil }

        return TranscriptInfo(
            model: model,
            tokenUsage: tokenUsage,
            tokenLimit: tokenLimit
        )
    }
}
