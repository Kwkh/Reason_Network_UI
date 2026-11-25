import Foundation
import SwiftUI
import Darwin

struct NetworkWorkspace: Identifiable, Equatable {
    let id: String
    let name: String
    let root: URL
}

struct NetworkDeparture: Identifiable, Equatable, Sendable {
    enum Reason: String, Sendable { case dissolved, removed }
    let id: String
    let network: String
    let name: String
    let reason: Reason

    var title: String {
        switch reason {
        case .dissolved: L10n.format("「%@」已解散", name)
        case .removed: L10n.format("这台 Mac 已被移出「%@」", name)
        }
    }

    var detail: String {
        switch reason {
        case .dissolved: L10n.text("可在「已解散 Network 的记录」中查看本机聊天记录。")
        case .removed: L10n.text("如需重新加入，请向成员索取新的邀请链接。")
        }
    }
}

struct WorkspaceStore: Sendable {
    let home: URL
    var primary: URL { home.appendingPathComponent(".reason/network") }
    var folder: URL { home.appendingPathComponent(".reason/workspaces") }

    private func profiles() -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return [primary] + children.filter { UUID(uuidString: $0.lastPathComponent) != nil }
    }

    func membership(at root: URL) -> NetworkWorkspace? {
        guard let db = try? SQLiteStore(root.appendingPathComponent("network.db"), readOnly: true),
              let row = try? db.rows("SELECT json_extract(value,'$.id') AS id,json_extract(value,'$.meta.body.name') AS name FROM kv WHERE key='team'").first,
              let id = row["id"], let name = row["name"] else { return nil }
        return NetworkWorkspace(id: id, name: name, root: root)
    }

    func dissolved() -> [NetworkWorkspace] {
        profiles().flatMap { root -> [NetworkWorkspace] in
            guard let db = try? SQLiteStore(root.appendingPathComponent("network.db"), readOnly: true),
                  let rows = try? db.rows("SELECT substr(key,11) AS id, json_extract(value,'$.meta.body.name') AS name FROM kv WHERE key LIKE 'dissolved:%'") else { return [] }
            return rows.compactMap { row in
                guard let id = row["id"], let name = row["name"] else { return nil }
                return NetworkWorkspace(id: id, name: name, root: root)
            }
        }.sorted { ($0.name,$0.id) < ($1.name,$1.id) }
    }

    func remoteDepartures() async -> [NetworkDeparture] {
        profiles().flatMap { root -> [NetworkDeparture] in
            guard let db = try? SQLiteStore(root.appendingPathComponent("network.db"), readOnly: true),
                  let rows = try? db.rows("""
                    SELECT key, json_extract(value,'$.network') AS network, json_extract(value,'$.name') AS name,
                           json_extract(value,'$.reason') AS reason FROM kv WHERE key GLOB 'departure:*' AND json_valid(value)
                    """) else { return [] }
            return rows.compactMap { row in
                guard let key = row["key"], let network = row["network"], let name = row["name"],
                      let reason = row["reason"].flatMap(NetworkDeparture.Reason.init(rawValue:)) else { return nil }
                return NetworkDeparture(id: key, network: network, name: name, reason: reason)
            }
        }.sorted { $0.id < $1.id }
    }

    func joined() -> [NetworkWorkspace] { profiles().compactMap(membership).sorted { ($0.name,$0.id) < ($1.name,$1.id) } }

    private func previousProfile(for id: String) -> URL? {
        profiles().first { root in
            guard membership(at: root) == nil else { return false }
            if (try? String(contentsOf: root.appendingPathComponent("workspace-id"), encoding: .utf8)) == id { return true }
            let url = root.appendingPathComponent("local-ui/messages.sqlite3")
            guard let db = try? SQLiteStore(url, readOnly: true) else { return false }
            return (try? db.rows("SELECT 1 FROM network_periods WHERE network=? LIMIT 1", [id]).isEmpty) == false
        }
    }

    func stopSecondaryService(at root: URL) async throws {
        guard root.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path,
              UUID(uuidString: root.lastPathComponent) != nil, membership(at: root) == nil else { return }
        // Keep the endpoint available so offline members can learn of a dissolution.
        if let db = try? SQLiteStore(root.appendingPathComponent("network.db"), readOnly: true),
           let records = try? db.rows("SELECT 1 FROM kv WHERE key LIKE 'dissolved:%' LIMIT 1"), !records.isEmpty { return }
        let label = "local.reasonnetwork.workspace." + root.lastPathComponent
        let target = "gui/" + String(getuid()) + "/" + label
        let ctl = URL(fileURLWithPath: "/bin/launchctl")
        if try await SetupCommand.run(ctl, ["print",target], home: home).status == 0 {
            _ = try await SetupCommand.run(ctl, ["bootout",target], home: home).checked()
        }
        let file = home.appendingPathComponent("Library/LaunchAgents").appendingPathComponent(label + ".plist")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    private func startService(at root: URL, binary: URL) async throws {
        let label = "local.reasonnetwork.workspace." + root.lastPathComponent
        let domain = "gui/" + String(getuid())
        let ctl = URL(fileURLWithPath: "/bin/launchctl")
        let plist = home.appendingPathComponent("Library/LaunchAgents").appendingPathComponent(label + ".plist")
        let environment = NetworkPaths.workspaceEnvironment(root).merging(["HOME": home.path, "PATH": NetworkPaths.environment(home: home)["PATH"] ?? "/usr/bin:/bin"]) { _, new in new }
        let job: [String: Any] = ["Label": label, "ProgramArguments": [binary.path,"daemon","--service"],
                                 "EnvironmentVariables": environment, "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 1]
        let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        let old = try? Data(contentsOf: plist)
        if old != data { try data.write(to: plist, options: .atomic) }
        let loaded = try await SetupCommand.run(ctl, ["print",domain + "/" + label], home: home).status == 0
        if loaded && old != data {
            _ = try await SetupCommand.run(ctl, ["bootout",domain + "/" + label], home: home).checked()
        }
        if !loaded || old != data {
            _ = try await SetupCommand.run(ctl, ["bootstrap",domain,plist.path], home: home).checked()
        }
    }

    private func ready(_ root: URL) async throws -> SessionSocket {
        let socket = SessionSocket(socketURL: NetworkPaths.socket(in: root))
        for _ in 0..<60 {
            if let data = try? socket.request(["op":"session_participation"], timeout: 1),
               let caps = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               caps["workspaces"] as? Bool == true { return socket }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw NetworkError("工作区后台未就绪，请重新检查环境配置。")
    }

    func provision(name: String, invitation: String?, person: String) async throws -> NetworkWorkspace {
        let person = try SetupInput.name(person)
        let ticket = try invitation.map(SetupInput.invitation)
        let multi = FileManager.default.fileExists(atPath: folder.path)
        let legacyFirstJoin = !multi && joined().isEmpty && ticket?.hasPrefix("rn1-") == false
        let expected = try legacyFirstJoin ? nil : ticket.map(NetworkPaths.inviteID)
        if let expected, let existing = joined().first(where: { $0.id == expected }) { return existing }
        guard ParticipationInstaller.capabilities(at: home)?["workspaces"] as? Bool == true,
              let executable = NetworkPaths.workspaceExecutable(home: home) else {
            throw NetworkError("请先在「环境配置」更新兼容后台，再添加 Network。")
        }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ticket != nil || (!title.isEmpty && title.count <= 60) else { throw NetworkError("请输入 1–60 字的 Network 名称。") }
        let first = !multi && joined().isEmpty
        let root = expected.flatMap(previousProfile) ?? (first ? primary : folder.appendingPathComponent(UUID().uuidString))
        let fm = FileManager.default
        let broker = try await ready(primary)
        _ = try broker.request(["op":"enable_workspaces"])
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if root != primary {
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try await startService(at: root, binary: executable)
        }
        let socket = try await ready(root)
        let lock = root.appendingPathComponent("daemon.lock")
        let oldPID = try? String(contentsOf: lock, encoding: .utf8)
        var command = ["op": "create_team", "name": title, "person": person]
        if let ticket { command = ["op": "join", "ticket": ticket, "person": person] }
        do { _ = try socket.request(command, timeout: 120) }
        catch {
            if membership(at: root) == nil {
                // Only tear down a rejected join. A socket timeout may still complete in the daemon.
                if (error as? NetworkError)?.message != "本机服务没有及时响应，请稍后重试。" { try? await stopSecondaryService(at: root) }
                throw NetworkError(localizing: { SetupInput.redacted(error.localizedDescription) })
            }
        }
        guard let result = membership(at: root), expected == nil || result.id == expected else {
            throw NetworkError("后台尚未确认加入所选 Network。")
        }
        try result.id.write(to: root.appendingPathComponent("workspace-id"), atomically: true, encoding: .utf8)
        // Creation and joining both restart the engine after saving the team. An old
        // process may already know the new ID while still reporting the previous identity.
        for _ in 0..<60 {
            if let pid = try? String(contentsOf: lock, encoding: .utf8), !pid.isEmpty, pid != oldPID {
                _ = try await ready(root)
                return result
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw NetworkError("已加入 Network，后台仍在重启。请重新打开概览。")
    }
}

@MainActor
final class WorkspaceController: ObservableObject {
    private let store: WorkspaceStore
    @Published private(set) var current: NetworkModel
    @Published private(set) var items: [NetworkWorkspace] = []
    @Published private(set) var archives: [NetworkWorkspace] = []
    @Published private(set) var selection: NetworkWorkspace?
    private var models: [String: NetworkModel] = [:]
    @Published private(set) var departureNotices: [NetworkDeparture] = []
    private let receiptsKey = "acknowledgedNetworkDepartures"

    func refreshDepartureNotices() async {
        let events = await store.remoteDepartures()
        guard !Task.isCancelled else { return }
        var known = Set(UserDefaults.standard.stringArray(forKey: receiptsKey) ?? [])
        known.formUnion(departureNotices.map(\.id))
        let fresh = events.filter { known.insert($0.id).inserted }
        if !fresh.isEmpty {
            departureNotices.append(contentsOf: fresh)
            if fresh.contains(where: { $0.reason == .dissolved }) { archives = store.dissolved() }
        }
    }

    func acknowledgeDeparture(_ id: String) {
        guard departureNotices.contains(where: { $0.id == id }) else { return }
        var acknowledged = Set(UserDefaults.standard.stringArray(forKey: receiptsKey) ?? [])
        acknowledged.insert(id)
        UserDefaults.standard.set(Array(acknowledged), forKey: receiptsKey)
        departureNotices.removeAll { $0.id == id }
    }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        store = WorkspaceStore(home: home)
        current = NetworkModel(service: ReasonService(home: home))
        reload()
    }

    func reload() {
        archives = store.dissolved()
        items = store.joined()
        let preferred = selection?.id ?? UserDefaults.standard.string(forKey: "selectedReasonNetwork")
        if let next = items.first(where: { $0.id == preferred }) ?? items.first(where: { $0.root.path == store.primary.path }) ?? items.first {
            select(next)
        } else if selection != nil {
            selection = nil
            current = NetworkModel(service: ReasonService(home: store.home))
        }
    }

    func didLeave() async {
        let root = selection?.root
        if let id = selection?.id { models.removeValue(forKey: id) }
        reload()
        if let root { try? await store.stopSecondaryService(at: root) }
    }

    func select(_ workspace: NetworkWorkspace) {
        if selection?.id == workspace.id { selection = workspace; return }
        let primary = workspace.root.path == store.primary.path
        let model = models[workspace.id] ?? NetworkModel(service: ReasonService(home: store.home, workspace: primary ? nil : workspace.root, expectedNetwork: workspace.id),
                                                         preferenceScope: primary ? "" : "." + workspace.id)
        models[workspace.id] = model
        selection = workspace
        current = model
        UserDefaults.standard.set(workspace.id, forKey: "selectedReasonNetwork")
    }

    func add(name: String, invitation: String?, person: String) async throws {
        let workspace = try await store.provision(name: name, invitation: invitation, person: person)
        items = store.joined()
        select(workspace)
        await current.refresh()
    }
}
