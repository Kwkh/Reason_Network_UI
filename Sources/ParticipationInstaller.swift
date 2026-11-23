import Foundation
import CryptoKit
import Darwin

/// Promote a stock per-user service to the bundled daemon. The stock CLI continues to own hooks.
struct ParticipationInstaller: Sendable {
    let home: URL
    var binary = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/reason-network-backend")
    var launchctl = URL(fileURLWithPath: "/bin/launchctl")
    var probe: @Sendable (URL) -> Bool = { home in
        capabilities(at: home)?["codex_queue_resume"] as? Bool == true
    }

    static func capabilities(at home: URL) -> [String: Any]? {
        let socket = SessionSocket(socketURL: home.appendingPathComponent(".reason/network/network.sock"))
        guard let data = try? socket.request(["op": "session_participation"], timeout: 1),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["version"] as? Int == 1 else { return nil }
        return result
    }

    var label = "com.reasonmachines.network"
    private var plist: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    private var domain: String { "gui/\(getuid())" }
    private var target: String { domain + "/" + label }

    private func job() throws -> [String: Any] {
        let data = try Data(contentsOf: plist)
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              value["Label"] as? String == label, let args = value["ProgramArguments"] as? [String],
              args.count == 3, Array(args.dropFirst()) == ["daemon", "--service"] else {
            throw NetworkError("无法识别现有 Reason 登录服务。")
        }
        return value
    }

    var configured: Bool {
        guard let job = try? job(), let vars = job["EnvironmentVariables"] as? [String: String],
              vars["REASON_NETWORK_LOCAL_PARTICIPATION"] == "1",
              let path = (job["ProgramArguments"] as? [String])?.first else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    func validate(cli: URL) async throws {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw NetworkError("App 内缺少兼容后台，请重新安装完整的 App。")
        }
        _ = try await SetupCommand.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--strict", binary.path], home: home).checked()
        for file in Set([cli, binary]) {
            let version = try await SetupCommand.run(file, ["--version"], home: home).checked()
            guard version.trimmingCharacters(in: .whitespacesAndNewlines) == "reason-network " + SetupService.engineVersion else {
                throw NetworkError("当前 CLI 与内置兼容后台版本不同，请更新至匹配的 App 版本。")
            }
        }
    }

    private func bootstrap() async throws {
        for attempt in 0..<12 {
            let result = try await SetupCommand.run(launchctl, ["bootstrap", domain, plist.path], home: home)
            if result.status == 0 { return }
            if result.status != 5 || attempt == 11 { _ = try result.checked() }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    func activate() async throws {
        if configured && probe(home) { return }
        let original = try Data(contentsOf: plist)
        var updated = try job()
        let manager = FileManager.default
        let folder = home.appendingPathComponent("Library/Application Support/Reason Network UI/Backend")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let bytes = try Data(contentsOf: binary, options: .mappedIfSafe)
        let digest = SHA256.hash(data: bytes)
        let suffix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let daemon = folder.appendingPathComponent("reason-network-" + suffix)
        if !manager.fileExists(atPath: daemon.path) {
            let staging = folder.appendingPathComponent(UUID().uuidString)
            defer { try? manager.removeItem(at: staging) }
            try manager.copyItem(at: binary, to: staging)
            try manager.moveItem(at: staging, to: daemon)
        }
        guard SHA256.hash(data: try Data(contentsOf: daemon, options: .mappedIfSafe)) == digest else {
            throw NetworkError("已安装的兼容后台校验失败。")
        }
        updated["ProgramArguments"] = [daemon.path, "daemon", "--service"]
        var env = updated["EnvironmentVariables"] as? [String: String] ?? [:]
        env["REASON_NETWORK_LOCAL_PARTICIPATION"] = "1"
        updated["EnvironmentVariables"] = env
        let replacement = try PropertyListSerialization.data(fromPropertyList: updated, format: .xml, options: 0)
        let backup = folder.appendingPathComponent("launch-agent-" + UUID().uuidString + ".plist")
        try original.write(to: backup, options: .withoutOverwriting)
        let loaded = try await SetupCommand.run(launchctl, ["print", target], home: home).status == 0
        if loaded { _ = try await SetupCommand.run(launchctl, ["bootout", target], home: home).checked() }
        var bootstrapped = false
        do {
            try replacement.write(to: plist, options: .atomic)
            try await bootstrap()
            bootstrapped = true
            for _ in 0..<40 {
                if probe(home) { return }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw NetworkError("后台未确认 Codex 会话唤醒功能。")
        } catch {
            let failure = error
            if bootstrapped { _ = try? await SetupCommand.run(launchctl, ["bootout", target], home: home) }
            do {
                try original.write(to: plist, options: .atomic)
                if loaded { try await bootstrap() }
            } catch {
                throw NetworkError("后台切换失败，恢复服务时遇到错误。原配置备份位于 " + backup.path)
            }
            throw failure
        }
    }
}
