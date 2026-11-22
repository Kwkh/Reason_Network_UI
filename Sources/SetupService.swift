import Foundation
import CryptoKit
import Darwin

/// The standalone installer and the official Reason CLI use different engine locations.
enum NetworkPaths {
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
    var background = false
    var codex = false
    var wired = false
    var joined = false
    var sessions = 0
    var team: String?
    var issue: String?
    var ready: Bool { installed && background && wired && joined }
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
                                         with: "[邀请已隐藏]", options: .regularExpression).prefix(2400))
    }
}

/// Process arguments never pass through a shell. Private files avoid pipe-capacity deadlocks.
struct SetupCommand {
    let output: String
    let status: Int32
    static func run(_ executable: URL, _ arguments: [String], home: URL, timeout: TimeInterval = 30) async throws -> SetupCommand {
        try await Task.detached(priority: .userInitiated) {
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
            process.environment = NetworkPaths.environment(home: home)
            process.currentDirectoryURL = home
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = handle; process.standardError = handle
            try Task.checkCancellation()
            try process.run()
            let start = Date()
            while process.isRunning {
                if Task.isCancelled || Date().timeIntervalSince(start) > timeout {
                    process.terminate()
                    try? await Task.sleep(for: .milliseconds(100))
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                    throw NetworkError("操作超时，请重新检查当前状态。加入请求可能已完成，请勿立即重复加入。")
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            process.waitUntilExit()
            try handle.seek(toOffset: 0)
            let output = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
            return SetupCommand(output: output, status: process.terminationStatus)
        }.value
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
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    func inspect() async -> SetupSnapshot {
        let fm = FileManager.default
        var result = SetupSnapshot()
        result.codex = fm.fileExists(atPath: home.appendingPathComponent(".codex").path) ||
            fm.fileExists(atPath: "/Applications/Codex.app") || fm.fileExists(atPath: home.appendingPathComponent("Applications/Codex.app").path)
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
            result.sessions = directory.sessions.filter { $0.person == directory.person && $0.agent == "codex" && $0.tier != "none" }.count
        } catch { result.issue = SetupInput.redacted(error.localizedDescription) }
        return result
    }

    func install() async throws {
        guard NetworkPaths.executable(home: home) == nil else { return }
        #if arch(arm64)
        let target = "aarch64-apple-darwin"
        let expected = "6676e806abba74b313ee027b5b4020634077b0ef4c01c0a9eb4dd61ec77ea705"
        #else
        let target = "x86_64-apple-darwin"
        let expected = "e71fbd5c7c080048c1220025e2aa716c3af6b18901f18e5beece1323cfcdd96f"
        #endif
        let url = URL(string: "https://github.com/reason-machines/reason-network/releases/download/v\(Self.engineVersion)/reason-network-\(target).tar.gz")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45; configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (file, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NetworkError("官方后台下载失败，请检查网络后重试。") }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { throw NetworkError("下载校验失败，未安装任何文件。请稍后重试。") }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("reason-engine-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: folder) }
        // The archive has a pinned digest; still restrict extraction to the expected member.
        _ = try await SetupCommand.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", file.path, "-C", folder.path, "reason-network"], home: home).checked()
        let candidate = folder.appendingPathComponent("reason-network")
        let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw NetworkError("官方后台文件格式异常。") }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidate.path)
        let version = try await SetupCommand.run(candidate, ["--version"], home: home).checked()
        guard version.trimmingCharacters(in: .whitespacesAndNewlines) == "reason-network \(Self.engineVersion)" else {
            throw NetworkError("官方后台版本校验失败。")
        }
        let bin = home.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let staging = bin.appendingPathComponent(".reason-network-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: candidate, to: staging)
        // Never overwrite an engine another installer put here while we were downloading.
        guard NetworkPaths.executable(home: home) == nil else { return }
        try fm.moveItem(at: staging, to: bin.appendingPathComponent("reason-network"))
    }

    func configure() async throws {
        guard let executable = NetworkPaths.executable(home: home) else { throw NetworkError("请先安装官方后台。") }
        _ = try await SetupCommand.run(executable, ["setup"], home: home, timeout: 90).checked()
        let result = await inspect()
        guard result.background else { throw NetworkError("后台服务未安装成功，请展开详情或重试配置。") }
        if result.codex && !result.wired { throw NetworkError("Codex 接入未完成，请检查配置文件权限后重试。") }
    }
    func join(invitation: String, name: String) async throws {
        let ticket = try SetupInput.invitation(invitation), person = try SetupInput.name(name)
        guard let executable = NetworkPaths.executable(home: home) else { throw NetworkError("请先安装官方后台。") }
        let before = await inspect()
        guard before.issue == nil else { throw NetworkError("尚无法确认此机器的 Network 状态，请先重新检查。") }
        guard !before.joined else { throw NetworkError("此机器已经加入 Network。请返回聊天，无需重复加入。") }
        _ = try await SetupCommand.run(executable, ["join", ticket, "--as", person, "--no-setup", "--json"], home: home, timeout: 120).checked()
        let after = await inspect()
        guard after.joined else { throw NetworkError("尚未确认加入成功，请重新检查。邀请方需要保持在线。") }
    }
}
