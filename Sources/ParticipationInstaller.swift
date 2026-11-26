import Foundation
import CryptoKit
import Darwin

/// Promote a stock per-user service to the bundled daemon. The stock CLI continues to own hooks.
struct ParticipationInstaller: Sendable {
    let home: URL
    var binary = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/reason-network-backend")
    var launchctl = URL(fileURLWithPath: "/bin/launchctl")
    var probe: @Sendable (URL, URL) -> Bool = { root, executable in
        capabilities(in: root, onlyFrom: executable)?["compact_reply_addresses"] as? Bool == true
    }

    static func capabilities(at home: URL, onlyFrom executable: URL? = nil) -> [String: Any]? {
        capabilities(in: home.appendingPathComponent(".reason/network"), onlyFrom: executable)
    }

    private static func capabilities(in root: URL, onlyFrom executable: URL?) -> [String: Any]? {
        let socket = SessionSocket(socketURL: NetworkPaths.socket(in: root))
        guard let data = try? socket.request(["op": "session_participation"], timeout: 1, onlyFrom: executable),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["version"] as? Int == 1 else { return nil }
        return result
    }

    private var backendFolder: URL { home.appendingPathComponent("Library/Application Support/Reason Network UI/Backend") }
    // CFBundleVersion increases for every published macOS build. An older copy
    // reopened from a disk image must not undo a newer App's completed migration.
    var appBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    private struct Installation: Codable {
        let appBuild: Int
        let executable: String
    }
    private var receipt: URL { backendFolder.appendingPathComponent("app-backend-installation.json") }
    private var installation: Installation? {
        guard let data = try? Data(contentsOf: receipt) else { return nil }
        return try? JSONDecoder().decode(Installation.self, from: data)
    }
    private static let workspacePrefix = "local.reasonnetwork.workspace."
    private func workspaceJobs() throws -> [String] {
        let manager = FileManager.default
        let names = try manager.contentsOfDirectory(atPath: plist.deletingLastPathComponent().path)
        var jobs = Set(names.compactMap { name -> String? in
            guard name.hasPrefix(Self.workspacePrefix), name.hasSuffix(".plist") else { return nil }
            let id = String(name.dropFirst(Self.workspacePrefix.count).dropLast(6))
            return UUID(uuidString: id) == nil ? nil : Self.workspacePrefix + id
        })
        let profiles = home.appendingPathComponent(".reason/workspaces")
        if manager.fileExists(atPath: profiles.path) {
            for id in try manager.contentsOfDirectory(atPath: profiles.path) where UUID(uuidString: id) != nil {
                let name = Self.workspacePrefix + id
                if !jobs.contains(name), try hasMembership(stateRoot(name)) { jobs.insert(name) }
            }
        }
        return jobs.sorted()
    }

    static func workspaceJob(home: URL, root: URL, binary: URL) -> [String: Any] {
        var env = NetworkPaths.workspaceEnvironment(root)
        env["HOME"] = home.path
        env["PATH"] = NetworkPaths.environment(home: home)["PATH"]
        return ["Label": workspacePrefix + root.lastPathComponent, "ProgramArguments": [binary.path, "daemon", "--service"],
                "EnvironmentVariables": env, "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 1]
    }

    private func stateRoot(_ name: String) -> URL {
        if name == label { return home.appendingPathComponent(".reason/network") }
        return home.appendingPathComponent(".reason/workspaces").appendingPathComponent(String(name.dropFirst(Self.workspacePrefix.count)))
    }

    private func destination(for digest: SHA256.Digest) -> URL {
        let suffix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return backendFolder.appendingPathComponent(suffix).appendingPathComponent("reason-network")
    }

    var managed: Bool {
        guard let definition = try? job(named: label),
              let env = definition["EnvironmentVariables"] as? [String: String] else { return false }
        return env["REASON_NETWORK_LOCAL_PARTICIPATION"] == "1"
    }

    private func hasMembership(_ root: URL) throws -> Bool {
        let file = root.appendingPathComponent("network.db")
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        let db = try SQLiteStore(file, readOnly: true)
        return try !db.rows("SELECT 1 FROM kv WHERE key='team' AND json_extract(value,'$.id') IS NOT NULL").isEmpty
    }

    func needsUpdate() async throws -> Bool {
        if let previous = installation, previous.appBuild > appBuild { return false }
        let target = destination(for: SHA256.hash(data: try Data(contentsOf: binary, options: .mappedIfSafe)))
        for name in [label] + (try workspaceJobs()) {
            let definition = try job(named: name)
            if (definition["ProgramArguments"] as? [String])?.first != target.path { return true }
            if probe(stateRoot(name), target) { continue }
            if name == label { return true }
            if try hasMembership(stateRoot(name)) { return true }
            if try await isLoaded(name) { return true }
            if FileManager.default.fileExists(atPath: NetworkPaths.socket(in: stateRoot(name)).path),
               Self.capabilities(in: stateRoot(name), onlyFrom: nil) != nil { return true }
        }
        return false
    }

    private func isLoaded(_ name: String) async throws -> Bool {
        try await SetupCommand.run(launchctl, ["print", domain + "/" + name], home: home).status == 0
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

    func activate(refreshBindings: Bool = false) async throws {
        let manager = FileManager.default
        let bytes = try Data(contentsOf: binary, options: .mappedIfSafe)
        let digest = SHA256.hash(data: bytes)
        let daemon = destination(for: digest)
        let folder = daemon.deletingLastPathComponent()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(backendFolder.appendingPathComponent("upgrade.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw POSIXError(.EACCES) }
        defer { close(lock) }
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw POSIXError(.EIO) }
            try await Task.sleep(for: .milliseconds(200))
        }
        let previous = installation
        if let previous, previous.appBuild > appBuild { return }
        if !manager.fileExists(atPath: daemon.path) {
            let staging = folder.appendingPathComponent(UUID().uuidString)
            defer { try? manager.removeItem(at: staging) }
            try manager.copyItem(at: binary, to: staging)
            try manager.moveItem(at: staging, to: daemon)
        }
        guard SHA256.hash(data: try Data(contentsOf: daemon, options: .mappedIfSafe)) == digest else {
            throw NetworkError("已安装的兼容后台校验失败。")
        }
        var firstFailure: Error?
        for name in [label] + (try workspaceJobs()) {
            do { try await activateService(name, daemon: daemon) }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        if let firstFailure { throw firstFailure }
        if refreshBindings || previous?.executable != daemon.path {
            _ = try await SetupCommand.run(binary, ["setup-agent-join", "--backend", daemon.path], home: home).checked()
            try await DshWakeSetup.shared.configure(home: home, helper: binary, backend: daemon)
        }
        if previous?.appBuild != appBuild || previous?.executable != daemon.path {
            try JSONEncoder().encode(Installation(appBuild: appBuild, executable: daemon.path)).write(to: receipt, options: .atomic)
        }
    }

    private func activateService(_ name: String, daemon: URL) async throws {
        let isPrimary = name == label
        let file = plist.deletingLastPathComponent().appendingPathComponent(name + ".plist")
        let target = domain + "/" + name
        let root = stateRoot(name)
        let manager = FileManager.default
        if !isPrimary && !manager.fileExists(atPath: file.path) {
            guard try hasMembership(root) else { return }
            let definition = Self.workspaceJob(home: home, root: root, binary: daemon)
            try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
                .write(to: file, options: .withoutOverwriting)
        }
        let original = try Data(contentsOf: file)
        var updated = try job(named: name)
        let socket = SessionSocket(socketURL: NetworkPaths.socket(in: root))
        if !isPrimary {
            guard let env = updated["EnvironmentVariables"] as? [String: String], env["REASON_NETWORK_HOME"] == root.path,
                  env["REASON_NETWORK_LOCAL_PARTICIPATION"] == "1" else { throw NetworkError(localizing: { L10n.text("无法识别工作区服务 ") + name }) }
        }
        let expectedPath = (updated["ProgramArguments"] as? [String])?.first == daemon.path
        let handoff = SessionHandoff(home: home, root: root, socket: socket)
        if expectedPath && probe(root, daemon) {
            try handoff.restore(using: daemon)
            return
        }
        let loaded = try await isLoaded(name)
        let serving = Self.capabilities(in: root, onlyFrom: nil) != nil
        let shouldRun = try isPrimary || loaded || serving || hasMembership(root)
        if !shouldRun && expectedPath { return }
        if serving { try handoff.capture() }
        updated["ProgramArguments"] = [daemon.path, "daemon", "--service"]
        var env = updated["EnvironmentVariables"] as? [String: String] ?? [:]
        env["REASON_NETWORK_LOCAL_PARTICIPATION"] = "1"
        updated["EnvironmentVariables"] = env
        let replacement = try PropertyListSerialization.data(fromPropertyList: updated, format: .xml, options: 0)
        let prefix = isPrimary ? "launch-agent-" : "workspace-" + name + "-"
        let backup = backendFolder.appendingPathComponent(prefix + UUID().uuidString + ".plist")
        try original.write(to: backup, options: .withoutOverwriting)
        if loaded { _ = try await SetupCommand.run(launchctl, ["bootout", target], home: home).checked() }
        var bootstrapped = false
        do {
            try replacement.write(to: file, options: .atomic)
            guard shouldRun else { return }
            try await bootstrap(file)
            bootstrapped = true
            var handedOff = false
            for _ in 0..<40 {
                if probe(root, daemon) { break }
                if !handedOff, let peer = try? socket.peerExecutable(), peer != daemon.resolvingSymlinksInPath() {
                    let dir = peer.deletingLastPathComponent()
                    let installed = dir.deletingLastPathComponent().path == backendFolder.resolvingSymlinksInPath().path
                        && dir.lastPathComponent.count == 16 && dir.lastPathComponent.allSatisfy(\.isHexDigit)
                        && peer.lastPathComponent == "reason-network"
                    let cli = isPrimary && peer == NetworkPaths.executable(home: home)?.resolvingSymlinksInPath()
                    let legacy = dir.path == backendFolder.resolvingSymlinksInPath().path && peer.lastPathComponent.hasPrefix("reason-network-")
                    if installed || cli || legacy {
                        handedOff = (try? socket.request(["op":"shutdown"], timeout: 1, onlyFrom: peer)) != nil
                    }
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard probe(root, daemon) else { throw NetworkError("后台未确认连接恢复功能。") }
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
        try handoff.restore(using: daemon)
    }
}

// A daemon's live directory is in memory. Capture it before stopping that particular
// worker. Persistent membership alone also includes offline conversations.
private struct SessionHandoff {
    let home: URL
    let root: URL
    let socket: SessionSocket
    private var file: URL { root.appendingPathComponent("app-upgrade-sessions.json") }
    private struct Snapshot: Codable {
        let network: String
        let keys: Set<String>
        let gemini: [String: Host]
    }

    // A Gemini CLI thread is bound to a specific host process, including its start
    // time. Only its old daemon can tell us which thread that process was serving.
    private struct Host: Codable, Equatable {
        let pid: Int32
        let seconds: UInt64
        let microseconds: UInt64
        let busy: Bool

        init?(pid: Int32, busy: Bool) {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid() else { return nil }
            self.pid = pid
            self.busy = busy
            seconds = info.pbi_start_tvsec
            microseconds = info.pbi_start_tvusec
        }
    }

    private func geminiHosts(_ statuses: [String: String]) throws -> [String: Host] {
        guard !statuses.isEmpty else { return [:] }
        let capacity = Int(proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)) / MemoryLayout<Int32>.stride + 32
        var pids = [Int32](repeating: 0, count: capacity)
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count)) }
        var result: [String: Host] = [:]
        for pid in pids.prefix(max(0, Int(bytes)) / MemoryLayout<Int32>.stride) where pid > 1 {
            let data = try socket.request(["op":"current_gemini_thread", "pid":pid])
            if let id = try JSONDecoder().decode(String?.self, from: data), let status = statuses["gemini:" + id] {
                result["gemini:" + id] = Host(pid: pid, busy: status == "busy")
                if result.count == statuses.count { break }
            }
        }
        return result
    }

    private func database() throws -> SQLiteStore {
        try SQLiteStore(root.appendingPathComponent("network.db"), readOnly: true)
    }

    private func network(in db: SQLiteStore) throws -> String? {
        try db.rows("SELECT json_extract(value,'$.id') AS team FROM kv WHERE key='team'").first?["team"]
    }

    private func directory(from daemon: URL? = nil) throws -> Directory {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Directory.self, from: socket.request(["op":"who", "all":false], timeout: 30, onlyFrom: daemon))
    }

    private func localNames(_ directory: Directory) -> Set<String> {
        Set(directory.sessions.filter {
            $0.person == directory.person && $0.machine == directory.machine && $0.available
        }.map(\.name))
    }

    private func candidates(_ db: SQLiteStore) throws -> [[String: String]] {
        // dsh discovers its still-open native session sockets independently of the App.
        try db.rows("""
            SELECT key, name, cwd, agent FROM sessions
            WHERE attached=1 AND agent IN ('codex','claude-code','gemini') AND key LIKE agent || ':%'
              AND key NOT IN (SELECT key FROM paused_sessions)
            """)
    }

    func capture() throws {
        let db = try database()
        guard let team = try network(in: db) else { return }
        let live = try directory()
        let online = localNames(live)
        let rows = try candidates(db).filter { online.contains($0["name"] ?? "") }
        var keys = Set(rows.compactMap { $0["key"] })
        var statuses: [String: String] = [:]
        for row in rows where row["agent"] == "gemini" {
            if let key = row["key"], let session = live.sessions.first(where: {
                $0.machine == live.machine && $0.person == live.person && $0.name == row["name"]
            }) { statuses[key] = session.status }
        }
        let supportsGeminiLookup = statuses.isEmpty ? false :
            (try JSONSerialization.jsonObject(with: socket.request(["op":"session_participation"])) as? [String: Any])?["agent_session_join"] as? Bool == true
        var hosts = supportsGeminiLookup ? try geminiHosts(statuses) : [:]
        if FileManager.default.fileExists(atPath: file.path) {
            let previous = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
            if previous.network == team {
                keys.formUnion(previous.keys)
                hosts.merge(previous.gemini) { current, _ in current }
            }
        }
        if !keys.isEmpty {
            try JSONEncoder().encode(Snapshot(network: team, keys: keys, gemini: hosts)).write(to: file, options: .atomic)
        }
    }

    func restore(using daemon: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
        let db = try database()
        if try network(in: db) == saved.network {
            let online = localNames(try directory(from: daemon))
            let threads = PersonalSessionCatalog(home: home).registeredThreads(Array(saved.keys))
            let scoped = try !db.rows("SELECT 1 FROM kv WHERE key='manual-network'").isEmpty ||
                root.deletingLastPathComponent().lastPathComponent == "workspaces"
            var firstFailure: Error?
            for row in try candidates(db) {
                guard let name = row["name"], !online.contains(name), let key = row["key"], saved.keys.contains(key),
                      let agent = row["agent"], let cwd = row["cwd"], threads[key]?.restriction == nil else { continue }
                var hook = ["op":"hook", "event":"app-join", "agent":agent, "cwd":cwd,
                            "session_id":String(key.dropFirst(agent.count + 1)), "mail":false] as [String: Any]
                if agent == "gemini" {
                    guard let host = saved.gemini[key], Host(pid: host.pid, busy: host.busy) == host else { continue }
                    hook["pid"] = host.pid
                    hook["event"] = host.busy ? "prompt" : "stop"
                }
                if scoped, try db.rows("SELECT 1 FROM kv WHERE key=? AND value=?", ["workspace-member:" + key, saved.network]).isEmpty { continue }
                // The daemon rechecks the Network, pause flag and current native owner.
                // Never unpause a conversation to restore it.
                let request: [String: Any] = scoped ? ["op":"workspace_dispatch", "network":saved.network, "request":hook] : hook
                do { _ = try socket.request(request, timeout: 60, onlyFrom: daemon) }
                catch { if firstFailure == nil { firstFailure = error } }
            }
            if let firstFailure { throw firstFailure }
        }
        try FileManager.default.removeItem(at: file)
    }
}
