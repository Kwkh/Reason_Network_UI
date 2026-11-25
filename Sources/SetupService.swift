import Foundation
import Darwin

/// The standalone installer and the official Reason CLI use different engine locations.
enum NetworkPaths {
    static func inviteID(_ ticket: String) throws -> String {
        var encoded = String(ticket.dropFirst(4)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard ticket.hasPrefix("rn1-"), let bytes = Data(base64Encoded: encoded), bytes.count >= 32 else {
            throw NetworkError("请使用完整邀请链接，以便找到这个 Network 之前的聊天记录。")
        }
        return bytes.prefix(16).map { String(format: "%02x", $0) }.joined()
    }


    static func socket(in directory: URL) -> URL {
        let path = directory.appendingPathComponent("network.sock")
        guard path.path.utf8.count >= 100 else { return path }
        let hash = path.path.utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        return URL(fileURLWithPath: String(format: "/tmp/reason-network-%u/%016llx.sock", getuid(), hash))
    }

    static func workspaceExecutable(home: URL) -> URL? {
        let file = home.appendingPathComponent("Library/LaunchAgents/com.reasonmachines.network.plist")
        guard let data = try? Data(contentsOf: file),
              let job = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let path = (job["ProgramArguments"] as? [String])?.first,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func workspaceEnvironment(_ root: URL) -> [String: String] {
        ["REASON_NETWORK_HOME": root.path, "REASON_NETWORK_NO_SERVICE": "1", "REASON_NETWORK_NO_TRAY": "1",
         "REASON_NETWORK_LOCAL_PARTICIPATION": "1"]
    }

    static func executable(home: URL) -> URL? {
        [".local/bin/reason-network", ".reason/bin/reason-network"].map(home.appendingPathComponent)
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    static func environment(home: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !["CODEX_", "CLAUDE", "TINCAN_", "REASON_NETWORK_"].contains(where: key.hasPrefix) &&
            !["COPILOT_SESSION_ID", "GEMINI_CLI", "CURSOR_TRACE_ID"].contains(key)
        }
        env["HOME"] = home.path
        env["PATH"] = [".local/bin", ".reason/bin"].map { home.appendingPathComponent($0).path }
            .joined(separator: ":") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["NO_COLOR"] = "1"
        return env
    }
}

struct SetupSnapshot: Equatable {
    var installed = false
    var needsBackendUpdate = false
    var participation = false
    var background = false
    var codex = false
    var wired = false
    var joined = false
    var sessions = 0
    var team: String?
    var issue: InterfaceMessage?
    var ready: Bool { installed && background && participation && wired && joined }
}

enum SetupInput {
    static func invitation(_ value: String) throws -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "Join the Reason Network:"
        if text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let url = URLComponents(string: text), url.scheme != nil {
            guard url.scheme == "https", url.host == "reasonmachines.com", url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "network/join",
                  url.user == nil, url.password == nil, url.port == nil, let fragment = url.fragment else {
                throw NetworkError("请粘贴 Reason Network 邀请链接或一次性代码。")
            }
            text = fragment
        }
        let ticket = text.hasPrefix("rn1-") && text.count > 30 && text.count <= 8192 &&
            text.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
        let code = text.range(of: #"^[A-Za-z]+(?:-[A-Za-z]+){3}$"#, options: .regularExpression) != nil
        guard ticket || code else { throw NetworkError("邀请格式不正确，请使用完整链接或四词一次性代码。") }
        return text
    }
    static func name(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 64, text.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else {
            throw NetworkError("名称请使用英文字母、数字、点、短横线或下划线（最多 64 字符）。")
        }
        return text
    }
    static func redacted(_ value: String) -> String {
        String(value.replacingOccurrences(of: #"(?:https://reasonmachines\.com/network/join/?)?#?rn1-[A-Za-z0-9_-]+"#,
                                         with: L10n.text("[邀请已隐藏]"), options: .regularExpression).prefix(2400))
    }
}

/// Process arguments never pass through a shell. Private files avoid pipe-capacity deadlocks.
struct SetupCommand {
    let output: String
    let status: Int32
    static func run(_ executable: URL, _ arguments: [String], home: URL, timeout: TimeInterval = 30, environment: [String: String] = [:]) async throws -> SetupCommand {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try execute(executable, arguments, home: home, timeout: timeout, environment: environment) })
            }
        }
    }

    private static func execute(_ executable: URL, _ arguments: [String], home: URL, timeout: TimeInterval, environment: [String: String]) throws -> SetupCommand {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("reason-setup-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: folder) }
        let log = folder.appendingPathComponent("output")
        fm.createFile(atPath: log.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forUpdating: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.environment = NetworkPaths.environment(home: home).merging(environment) { _, override in override }
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle; process.standardError = handle
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let deadline = DispatchTime.now() + timeout
        // Observe termination before launch so even a fast child cannot finish between checks.
        while finished.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            if DispatchTime.now() >= deadline {
                if process.isRunning { process.terminate() }
                if finished.wait(timeout: .now() + .milliseconds(250)) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = finished.wait(timeout: .now() + .seconds(2))
                }
                throw NetworkError("操作超时，请重新检查当前状态。加入请求可能已完成，请勿立即重复加入。")
            }
        }
        try handle.seek(toOffset: 0)
        let output = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        return SetupCommand(output: output, status: process.terminationStatus)
    }
    func checked() throws -> String {
        guard status == 0 else { throw NetworkError(SetupInput.redacted(output).nonEmpty ?? "操作未完成，请重试。") }
        return output
    }
}

protocol SetupServicing: Sendable {
    func inspect() async -> SetupSnapshot
    func install() async throws
    func configure() async throws
    func join(invitation: String, name: String) async throws
}

actor SetupService: SetupServicing {
    static let engineVersion = "0.12.17"
    private let home: URL
    private let installer: ParticipationInstaller
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, installer: ParticipationInstaller? = nil) {
        self.home = home
        self.installer = installer ?? ParticipationInstaller(home: home)
    }

    func inspect() async -> SetupSnapshot {
        let fm = FileManager.default
        var result = SetupSnapshot()
        result.codex = fm.fileExists(atPath: home.appendingPathComponent(".codex").path) ||
            [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")].contains { apps in
                fm.fileExists(atPath: apps.appendingPathComponent("Codex.app").path) ||
                    fm.isExecutableFile(atPath: apps.appendingPathComponent("ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex").path)
            }
        let config = (try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)) ?? ""
        result.wired = config.contains("mcp_servers.reason-network") && config.contains("reason-network")
        result.background = fm.fileExists(atPath: home.appendingPathComponent("Library/LaunchAgents/com.reasonmachines.network.plist").path)
        guard let executable = NetworkPaths.executable(home: home) else { return result }
        result.installed = true
        do {
            let output = try await SetupCommand.run(executable, ["who", "--json"], home: home, timeout: 18).checked()
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            let directory = try decoder.decode(Directory.self, from: Data(output.utf8))
            result.joined = directory.team?.isEmpty == false
            result.team = directory.team
            result.sessions = directory.sessions.filter { $0.person == directory.person && $0.machine == directory.machine && LocalSession.supportedAgents.contains($0.agent ?? "") && $0.tier != "none" }.count
        } catch { result.issue = InterfaceMessage { SetupInput.redacted(error.localizedDescription) } }
        if installer.configured {
            result.needsBackendUpdate = installer.needsPathMigration
            result.participation = installer.probe(home)
            if !result.participation && ParticipationInstaller.capabilities(at: home) != nil {
                result.participation = true
                result.needsBackendUpdate = true
            }
        }
        return result
    }

    func install() async throws {
        guard NetworkPaths.executable(home: home) == nil else { return }
        let fm = FileManager.default
        let candidate = installer.binary
        try await installer.validate(cli: candidate)
        let bin = home.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let staging = bin.appendingPathComponent(".reason-network-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: candidate, to: staging)
        // Never overwrite an engine another installer put here while we were staging the copy.
        guard NetworkPaths.executable(home: home) == nil else { return }
        try fm.moveItem(at: staging, to: bin.appendingPathComponent("reason-network"))
    }

    func configure() async throws {
        guard let executable = NetworkPaths.executable(home: home) else { throw NetworkError("请先安装内置后台。") }
        try await installer.validate(cli: executable)
        let arguments = installer.configured ? ["setup", "--no-service"] : ["setup"]
        _ = try await SetupCommand.run(executable, arguments, home: home, timeout: 90).checked()
        try await installer.activate()
        if let backend = NetworkPaths.workspaceExecutable(home: home) {
            _ = try await SetupCommand.run(backend, ["setup-native-wake"], home: home, timeout: 30).checked()
        }
        let result = await inspect()
        guard result.background && result.participation && !result.needsBackendUpdate else { throw NetworkError("后台服务未安装成功，请展开详情或重试配置。") }
        if result.codex && !result.wired { throw NetworkError("Codex 接入未完成，请检查配置文件权限后重试。") }
    }
    func join(invitation: String, name: String) async throws {
        let ticket = try SetupInput.invitation(invitation), person = try SetupInput.name(name)
        guard let executable = NetworkPaths.executable(home: home) else { throw NetworkError("请先安装内置后台。") }
        let before = await inspect()
        guard before.issue == nil else { throw NetworkError("尚无法确认此机器的 Network 状态，请先重新检查。") }
        guard !before.joined else { throw NetworkError("此机器已经加入 Network。请返回聊天，无需重复加入。") }
        try SQLiteStore.prepareNetworkJoin(home: home)
        _ = try await SetupCommand.run(executable, ["join", ticket, "--as", person, "--no-setup", "--json"], home: home, timeout: 120).checked()
        let after = await inspect()
        guard after.joined else { throw NetworkError("尚未确认加入成功，请重新检查。邀请方需要保持在线。") }
    }
}
