import Foundation
import Darwin

struct ConsoleMailbox {
    struct Entry: Decodable {
        let id: String
        let teamID: String
        let peer: String
        let body: String
        let date: Date
        let outgoing: Bool
        let status: String
        let files: [MessageAttachment]
        let unread: Bool?

        func event(in mailbox: String) -> Message {
            let identifier = outgoing && id.hasPrefix("sent:") ? String(id.dropFirst(5)) : id
            return Message(id: identifier, at: date.timeIntervalSince1970, local: mailbox, peer: peer,
                           direction: outgoing ? "out" : "in", body: body, result: outgoing ? status : "", attachments: files,
                           unread: !outgoing && unread == true)
        }
    }
    struct Registration: Decodable { let address: String }
    struct Team: Decodable {
        struct UDP: Decodable { let port: Int; let fixed: Int? }
        let team_id: String?
        let id: String?
        let relay_connected: Bool?
        let udp: UDP?
        var networkID: String? { team_id?.nonEmpty ?? id?.nonEmpty }
    }
    struct Inbox: Decodable {
        struct Incoming: Decodable {
            let id: String
            let from: String
            let body: String
            let sent_at: Double
            let files: [MessageAttachment]?
        }
        let messages: [Incoming]
    }

    let home: URL
    var stateHome: URL { home.appendingPathComponent(".reason/network", isDirectory: true) }
    var socketURL: URL { stateHome.appendingPathComponent("network.sock") }
    var legacyHistory: URL { home.appendingPathComponent("Library/Application Support/Reason Network Console/history.json") }

    func register(event: String = "stop", timeout: Int = 5) throws -> String {
        let payload: [String: Any] = ["op": "hook", "agent": "cli", "event": event, "session_id": "reason-network-console",
                                      "name": LocalSession.console.name, "cwd": home.path, "mail": false, "keep": true]
        return try JSONDecoder().decode(Registration.self, from: request(payload, timeout: timeout)).address
    }

    func team() throws -> Team { try decode(["op": "team"], as: Team.self) }

    func sync(into cache: SQLiteStore, mailbox: String) throws {
        let inbox = try decode(["op": "inbox", "key": LocalSession.console.key, "wait_secs": 0, "peek": true], as: Inbox.self)
        for item in inbox.messages {
            try cache.insert(Message(id: item.id, at: item.sent_at / 1000, local: mailbox, peer: item.from,
                                     direction: "in", body: item.body, result: "", attachments: item.files ?? [], unread: true))
        }
        let ids = inbox.messages.map(\.id)
        if !ids.isEmpty { _ = try request(["op": "delivered", "key": LocalSession.console.key, "ids": ids]) }
    }

    // The official daemon accepts newline-delimited JSON over its user-private Unix socket.
    // Each operation has its own connection, timeout and bounded response buffer.
    func request(_ payload: [String: Any], timeout: Int = 5) throws -> Data {
        let path = socketURL.path
        guard path.utf8.count < 104 else { throw NetworkError("数据目录路径过长，无法连接本机服务。") }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NetworkError("无法创建本机连接。") }
        defer { Darwin.close(fd) }
        var time = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            path.utf8CString.withUnsafeBytes { bytes.copyBytes(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw NetworkError("本机网络服务尚未就绪，请检查本机服务。") }
        var body = payload
        body["id"] = 1
        var encoded = try JSONSerialization.data(withJSONObject: body)
        encoded.append(10)
        try encoded.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw NetworkError("本机服务连接中断，请重试。") }
                offset += count
            }
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while buffer.count < 8 * 1024 * 1024 {
            let size = Darwin.read(fd, &chunk, chunk.count)
            if size < 0 && errno == EINTR { continue }
            guard size > 0 else { throw NetworkError("本机服务没有及时响应，请稍后重试。") }
            buffer.append(contentsOf: chunk.prefix(size))
            while let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end)
                buffer.removeSubrange(...end)
                guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      reply["id"] as? Int == 1 else { continue }
                guard reply["ok"] as? Bool == true else {
                    throw NetworkError(reply["error"] as? String ?? "操作失败")
                }
                return try JSONSerialization.data(withJSONObject: reply["result"] ?? NSNull(), options: .fragmentsAllowed)
            }
        }
        throw NetworkError("服务返回的数据过大，已停止读取。")
    }

    func decode<T: Decodable>(_ payload: [String: Any], as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: request(payload))
    }

}
