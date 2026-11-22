import Foundation

// Extracts only successful Reason send tool calls. Never evaluates transcript code or acknowledges inboxes.
final class TranscriptMirror {
    private struct Pending { let arguments: [String: Any]; let at: Double }
    private var offsets: [String: UInt64] = [:]
    private var pending: [String: Pending] = [:]
    private var files: [URL] = []
    private var lastScan = Date.distantPast
    private let root: URL
    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")) { self.root = root }

    func events(for session: LocalSession) throws -> [Message] {
        let now = Date()
        if now.timeIntervalSince(lastScan) > 30 {
            files = []
            if let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let file as URL in iterator where file.pathExtension == "jsonl" { files.append(file) }
            }
            lastScan = now
        }
        let thread = session.key.hasPrefix("codex:") ? String(session.key.dropFirst(6)) : session.key
        var events: [Message] = []
        for path in files where path.lastPathComponent.contains(thread) {
            let handle = try FileHandle(forReadingFrom: path)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            let old = offsets[path.path]
            let offset = old.map { $0 > size ? 0 : $0 } ?? (size > 8_000_000 ? size - 8_000_000 : 0)
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            // Keep incomplete JSONL bytes for the next pass, including a partially written UTF-8 scalar.
            var start = data.startIndex
            var consumed = 0
            var discardFirst = old == nil && offset > 0
            for index in data.indices where data[index] == 10 {
                let line = data[start..<index]
                consumed = index + 1
                start = index + 1
                if discardFirst { discardFirst = false; continue }
                guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], record["type"] as? String == "response_item", let item = record["payload"] as? [String: Any], let type = item["type"] as? String, let call = item["call_id"] as? String else { continue }
                let key = path.path + ":" + call
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
                    if let at { pending[key] = Pending(arguments: arguments, at: at.timeIntervalSince1970) }
                    continue
                }
                guard type == "function_call_output" || type == "custom_tool_call_output", let sent = pending.removeValue(forKey: key) else { continue }
                let output = String(describing: item["output"] ?? "")
                guard output.range(of: #"\b(delivered|queued)\b"#, options: .regularExpression) != nil, let id = Self.match(#"message id ([0-9A-Z]{26})"#, in: output), let to = sent.arguments["to"] as? String, let body = sent.arguments["message"] as? String else { continue }
                events.append(Message(id: id, at: sent.at, local: session.name, peer: to, direction: "out", body: body, result: output.contains("queued") ? "queued" : "delivered", replyTo: sent.arguments["reply_to"] as? String))
            }
            offsets[path.path] = offset + UInt64(consumed)
        }
        return events
    }

    static func match(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let result = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), let range = Range(result.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
    // Accept only literal string members of one tool object. Variables / nested calls are ignored.
    static func literalSend(_ code: String) -> [String: Any]? {
        guard let start = code.range(of: #"(?:tools\.)?mcp__reason_network__send_message\s*\(\s*\{"#, options: .regularExpression) else { return nil }
        var rest = String(code[start.upperBound...])
        var result: [String: Any] = [:]
        while !rest.isEmpty {
            guard let keyRegex = try? NSRegularExpression(pattern: #"^\s*(?:([a-z_]+)|"([a-z_]+)")\s*:\s*"#), let key = keyRegex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)), let full = Range(key.range, in: rest) else { return nil }
            let keyRange = Range(key.range(at: key.range(at: 1).location == NSNotFound ? 2 : 1), in: rest)!
            let name = String(rest[keyRange]); rest = String(rest[full.upperBound...])
            guard let valueRegex = try? NSRegularExpression(pattern: #"^("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')"#), let valueMatch = valueRegex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)), let range = Range(valueMatch.range, in: rest) else { return nil }
            let literal = String(rest[range])
            var json = literal
            if literal.hasPrefix("'") {
                let body = String(literal.dropFirst().dropLast()).replacingOccurrences(of: "\\'", with: "'").replacingOccurrences(of: "\"", with: "\\\"")
                json = "\"" + body + "\""
            }
            guard let data = ("[" + json + "]").data(using: .utf8), let decoded = try? JSONSerialization.jsonObject(with: data) as? [String], let value = decoded.first else { return nil }
            result[name] = value; rest = String(rest[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.first == "}" { return result["to"] is String && result["message"] is String ? result : nil }
            guard rest.first == "," else { return nil }; rest.removeFirst()
        }
        return nil
    }
}
