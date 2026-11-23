import Foundation
import Darwin

// Extracts only successful Reason send tool calls. Never evaluates transcript code or acknowledges inboxes.
final class TranscriptMirror {
    private struct Pending { let arguments: [String: Any]; let at: Double }
    private struct Cursor {
        let device: dev_t
        let inode: ino_t
        var offset: UInt64 = 0
        var waiting: [String: Pending] = [:]
    }
    private var cursors: [URL: Cursor] = [:]
    private var files: [URL] = []
    private var lastScan = Date.distantPast
    private let root: URL
    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")) { self.root = root }

    func sync(for session: LocalSession, save: ([Message]) throws -> Void) throws {
        let now = Date()
        if now.timeIntervalSince(lastScan) > 30 {
            files = []
            let archived = root.deletingLastPathComponent().appendingPathComponent("archived_sessions")
            for folder in [root, archived] {
                guard let iterator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                for case let file as URL in iterator where file.pathExtension == "jsonl" { files.append(file) }
            }
            let current = Set(files)
            cursors = cursors.filter { current.contains($0.key) }
            lastScan = now
        }
        let thread = session.key.hasPrefix("codex:") ? String(session.key.dropFirst(6)) : session.key
        guard !thread.isEmpty else { return }
        for path in files {
            let stem = path.deletingPathExtension().lastPathComponent
            guard stem == thread || stem.hasSuffix("-" + thread) else { continue }
            let handle: FileHandle
            do { handle = try FileHandle(forReadingFrom: path) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                lastScan = .distantPast
                continue
            }
            defer { try? handle.close() }
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0 else { throw POSIXError(.EIO) }
            let size = UInt64(info.st_size)
            var cursor = cursors[path] ?? Cursor(device: info.st_dev, inode: info.st_ino)
            if cursor.inode != info.st_ino || cursor.device != info.st_dev || cursor.offset > size {
                cursor = Cursor(device: info.st_dev, inode: info.st_ino)
            }
            cursors[path] = cursor
            guard cursor.offset < size else { continue }
            try handle.seek(toOffset: cursor.offset)
            var buffer = Data()
            while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                var scan = buffer.endIndex
                buffer.append(chunk)
                var start = buffer.startIndex
                var batch: [Message] = []
                while let end = buffer[scan...].firstIndex(of: 10) {
                    if let message = event(in: buffer[start..<end], session: session, waiting: &cursor.waiting) {
                        batch.append(message)
                    }
                    start = end + 1
                    scan = start
                }
                if !batch.isEmpty { try save(batch) }
                // Advance only through complete records whose messages have been persisted.
                cursor.offset += UInt64(start - buffer.startIndex)
                if start > buffer.startIndex { buffer = Data(buffer[start...]) }
                cursors[path] = cursor
            }
        }
    }

    private let sendToken = Data("reason_network__send_message".utf8)
    private let callToken = Data("\"call_id\"".utf8)
    private func event(in line: Data, session: LocalSession, waiting: inout [String: Pending]) -> Message? {
        guard line.range(of: callToken) != nil, !waiting.isEmpty || line.range(of: sendToken) != nil,
              let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              record["type"] as? String == "response_item", let item = record["payload"] as? [String: Any],
              let type = item["type"] as? String, let call = item["call_id"] as? String else { return nil }
        var arguments: [String: Any]?
        let name = item["name"] as? String ?? ""
        if type == "custom_tool_call", name == "exec" {
            arguments = Self.literalSend(item["input"] as? String ?? "")
        } else if type == "function_call", name.contains("reason_network"), name.hasSuffix("send_message"), let input = item["arguments"] as? String, let bytes = input.data(using: .utf8) {
            arguments = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        }
        if let arguments {
            let stamp = record["timestamp"] as? String ?? ""
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let at = formatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
            if let at { waiting[call] = Pending(arguments: arguments, at: at.timeIntervalSince1970) }
            return nil
        }
        guard type == "function_call_output" || type == "custom_tool_call_output", let sent = waiting.removeValue(forKey: call) else { return nil }
        let output = String(describing: item["output"] ?? "")
        guard output.range(of: #"\b(delivered|queued)\b"#, options: .regularExpression) != nil, let id = Self.match(#"message id ([0-9A-Z]{26})"#, in: output), let to = sent.arguments["to"] as? String, let body = sent.arguments["message"] as? String else { return nil }
        let files = (sent.arguments["files"] as? [String] ?? []).map {
            MessageAttachment(name: URL(fileURLWithPath: $0).lastPathComponent)
        }
        return Message(id: id, at: sent.at, local: session.name, peer: to, direction: "out", body: body, result: output.contains("queued") ? "queued" : "delivered", replyTo: sent.arguments["reply_to"] as? String, attachments: files)
    }

    static func match(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let result = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), let range = Range(result.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
    // JSON5 covers quoted values, bare keys, arrays and booleans without running JavaScript.
    static func literalSend(_ code: String) -> [String: Any]? {
        let tool = "mcp__reason_network__send_message"
        guard let call = code.range(of: tool),
              !code[call.upperBound...].contains(tool) else { return nil }
        let tail = code[call.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard tail.first == "(", let end = tail.lastIndex(of: "}") else { return nil }
        guard tail[tail.index(after: end)...].trimmingCharacters(in: .whitespacesAndNewlines).first == ")" else { return nil }
        let object = String(tail[tail.index(after: tail.startIndex)...end])
        let quoted = #""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`"#
        guard let regex = try? NSRegularExpression(pattern: quoted, options: [.dotMatchesLineSeparators]) else { return nil }
        let normalized = NSMutableString(string: object)
        for match in regex.matches(in: object, range: NSRange(object.startIndex..., in: object)).reversed() {
            let literal = normalized.substring(with: match.range)
            guard literal.first == "`" else { continue }
            let body = literal.dropFirst().dropLast()
            // Interpolation requires runtime state. Only decode static template strings.
            guard !body.contains("${") else { return nil }
            var json = "\""
            var escaped = false
            for ch in body {
                if escaped {
                    if ch != "`" && ch != "$" { json.append("\\") }
                    json.append(ch)
                    escaped = false
                } else {
                    switch ch {
                    case "\\": escaped = true
                    case "\"": json += "\\\""
                    case "\n", "\r", "\r\n": json += "\\n"
                    case "\t": json += "\\t"
                    default: json.append(ch)
                    }
                }
            }
            normalized.replaceCharacters(in: match.range, with: json + "\"")
        }
        guard let result = try? JSONSerialization.jsonObject(with: Data((normalized as String).utf8),
                                                               options: .json5Allowed) as? [String: Any],
              result["to"] is String, result["message"] is String else { return nil }
        return result
    }
}
