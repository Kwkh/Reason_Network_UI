import Foundation
import CryptoKit
import Darwin

/// Promote a stock per-user service to the bundled daemon. The stock CLI continues to own hooks.
struct ParticipationInstaller: Sendable {
    let home: URL
    var binary = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/reason-network-backend")
    var launchctl = URL(fileURLWithPath: "/bin/launchctl")
    var probe: @Sendable (URL) -> Bool = { home in
        guard let executable = NetworkPaths.workspaceExecutable(home: home) else { return false }
        return capabilities(at: home, onlyFrom: executable)?["workspaces"] as? Bool == true
    }

    static func capabilities(at home: URL, onlyFrom executable: URL? = nil) -> [String: Any]? {
        let socket = SessionSocket(socketURL: NetworkPaths.socket(in: home.appendingPathComponent(".reason/network")))
        guard let data = try? socket.request(["op": "session_participation"], timeout: 1, onlyFrom: executable),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["version"] as? Int == 1 else { return nil }
        return result
    }

    private var backendFolder: URL { home.appendingPathComponent("Library/Application Support/Reason Network UI/Backend") }
    private static let workspacePrefix = "local.reasonnetwork.workspace."
    private var workspaceJobs: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: plist.deletingLastPathComponent().path)) ?? []
        return names.compactMap { name in
            guard name.hasPrefix(Self.workspacePrefix), name.hasSuffix(".plist") else { return nil }
            let id = String(name.dropFirst(Self.workspacePrefix.count).dropLast(6))
            return UUID(uuidString: id) == nil ? nil : Self.workspacePrefix + id
        }.sorted()
    }

    var needsPathMigration: Bool {
        ([label] + workspaceJobs).contains { name in
            guard let args = try? job(named: name)["ProgramArguments"] as? [String], let path = args.first else { return false }
            let url = URL(fileURLWithPath: path)
            return url.deletingLastPathComponent().path == backendFolder.path && url.lastPathComponent.hasPrefix("reason-network-")
        }
    }

    var label = "com.reasonmachines.network"
    private var plist: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    private var domain: String { "gui/\(getuid())" }

    private func job(named name: String) throws -> [String: Any] {
        let file = plist.deletingLastPathComponent().appendingPathComponent(name + ".plist")
        let data = try Data(contentsOf: file)
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              value["Label"] as? String == name, let args = value["ProgramArguments"] as? [String],
              args.count == 3, Array(args.dropFirst()) == ["daemon", "--service"] else {
            throw NetworkError("无法识别现有 Reason 登录服务。")
        }
        return value
    }

    var configured: Bool {
        guard let job = try? job(named: label), let vars = job["EnvironmentVariables"] as? [String: String],
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

    private func bootstrap(_ plist: URL) async throws {
        for attempt in 0..<12 {
            let result = try await SetupCommand.run(launchctl, ["bootstrap", domain, plist.path], home: home)
            if result.status == 0 { return }
            if result.status != 5 || attempt == 11 { _ = try result.checked() }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    func activate() async throws {
        let manager = FileManager.default
        let bytes = try Data(contentsOf: binary, options: .mappedIfSafe)
        let digest = SHA256.hash(data: bytes)
        let suffix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let folder = backendFolder.appendingPathComponent(suffix)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let daemon = folder.appendingPathComponent("reason-network")
        if !manager.fileExists(atPath: daemon.path) {
            let staging = folder.appendingPathComponent(UUID().uuidString)
            defer { try? manager.removeItem(at: staging) }
            try manager.copyItem(at: binary, to: staging)
            try manager.moveItem(at: staging, to: daemon)
        }
        guard SHA256.hash(data: try Data(contentsOf: daemon, options: .mappedIfSafe)) == digest else {
            throw NetworkError("已安装的兼容后台校验失败。")
        }
        try await activateService(label, daemon: daemon)
        for name in workspaceJobs {
            try await activateService(name, daemon: daemon)
        }
    }

    private func activateService(_ name: String, daemon: URL) async throws {
        let isPrimary = name == label
        let file = plist.deletingLastPathComponent().appendingPathComponent(name + ".plist")
        let target = domain + "/" + name
        let original = try Data(contentsOf: file)
        var updated = try job(named: name)
        let root = isPrimary ? home.appendingPathComponent(".reason/network")
            : home.appendingPathComponent(".reason/workspaces").appendingPathComponent(String(name.dropFirst(Self.workspacePrefix.count)))
        let socket = SessionSocket(socketURL: NetworkPaths.socket(in: root))
        if !isPrimary {
            guard let env = updated["EnvironmentVariables"] as? [String: String], env["REASON_NETWORK_HOME"] == root.path,
                  env["REASON_NETWORK_LOCAL_PARTICIPATION"] == "1" else { throw NetworkError(localizing: { L10n.text("无法识别工作区服务 ") + name }) }
        }
        if (updated["ProgramArguments"] as? [String])?.first == daemon.path && (!isPrimary || configured && probe(home)) { return }
        updated["ProgramArguments"] = [daemon.path, "daemon", "--service"]
        var env = updated["EnvironmentVariables"] as? [String: String] ?? [:]
        env["REASON_NETWORK_LOCAL_PARTICIPATION"] = "1"
        updated["EnvironmentVariables"] = env
        let replacement = try PropertyListSerialization.data(fromPropertyList: updated, format: .xml, options: 0)
        let prefix = isPrimary ? "launch-agent-" : "workspace-" + name + "-"
        let backup = backendFolder.appendingPathComponent(prefix + UUID().uuidString + ".plist")
        try original.write(to: backup, options: .withoutOverwriting)
        let loaded = try await SetupCommand.run(launchctl, ["print", target], home: home).status == 0
        if loaded { _ = try await SetupCommand.run(launchctl, ["bootout", target], home: home).checked() }
        var bootstrapped = false
        do {
            try replacement.write(to: file, options: .atomic)
            guard loaded || isPrimary else { return }
            try await bootstrap(file)
            bootstrapped = true
            var handedOff = false
            for _ in 0..<40 {
                if isPrimary ? probe(home) : (try? socket.request(["op": "session_participation"], timeout: 1, onlyFrom: daemon)) != nil { return }
                if isPrimary, !handedOff, let cli = NetworkPaths.executable(home: home) {
                    handedOff = (try? socket.request(["op": "shutdown"], timeout: 1, onlyFrom: cli)) != nil
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw NetworkError("后台未确认连接恢复功能。")
        } catch {
            let failure = error
            if bootstrapped { _ = try? await SetupCommand.run(launchctl, ["bootout", target], home: home) }
            do {
                try original.write(to: file, options: .atomic)
                if loaded { try await bootstrap(file) }
            } catch {
                throw NetworkError(localizing: { L10n.text("后台切换失败，恢复服务时遇到错误。原配置备份位于 ") + backup.path })
            }
            throw failure
        }
    }
}
