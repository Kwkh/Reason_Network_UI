import Foundation

@main
struct WorkspaceChecks {
    @MainActor
    static func main() async throws {
        let home = URL(fileURLWithPath: CommandLine.arguments[1])
        if CommandLine.arguments.count == 6 && CommandLine.arguments[2] == "dsh-push" {
            let helper = URL(fileURLWithPath: CommandLine.arguments[3])
            let network = CommandLine.arguments[4]
            let session = LocalSession(name: "deepseek", key: "dsh:" + CommandLine.arguments[5])
            let service = ReasonService(home: home, expectedNetwork: network, wakeSetupHelper: helper)
            do {
                let mode = try await service.setReceiveMode(.push, local: session, network: network)
                guard mode == .push else { throw NetworkError("Unexpected effective mode") }
            } catch {
                print(error.localizedDescription)
                exit(1)
            }
            return
        }
        let storage = WorkspaceStore(home: home)
        let hub = WorkspaceController(home: home)
        let first = try require(hub.selection)
        precondition(first.name == "Orange")
        // This goes through the same launchd provisioning, membership and selection as the form.
        try await hub.add(name: "Blue", invitation: nil, person: "qa")
        let second = try require(hub.selection)
        precondition(second.id != first.id && hub.items.count == 2)
        do {
            try await verify(hub, first: first, second: second, home: home)
            try await verifyTools(first: first, second: second, home: home)
        } catch {
            try? await leave(hub, workspace: second, storage: storage)
            throw error
        }
        try await leave(hub, workspace: second, storage: storage)
        precondition(hub.items.map(\.id) == [first.id])
        print("PASS: App created a workspace, switched overviews, copied scoped invites, restored selection and independent drafts, left one network")
        hub.select(first)
        await hub.current.refresh()
        let directory = try require(hub.current.directory)
        precondition(directory.managesNetwork == true)
        precondition(directory.removableDevices(for: directory.person).allSatisfy { !$0.isMe })
        // A removed member can still have cached history, but is no longer a recipient or management target.
        let remote = Device(person: "guest", machine: "laptop", endpoint: "fixture-1", isMe: false, online: false, link: nil, rttMs: nil)
        let sibling = Device(person: "guest", machine: "desktop", endpoint: "fixture-2", isMe: false, online: true, link: nil, rttMs: nil)
        var roster = Directory(managesNetwork: true, networkID: first.id, team: first.name, person: directory.person,
                               machine: directory.machine, sessions: [], machines: directory.machines + [remote, sibling])
        precondition(Set(roster.removableDevices(for: "guest").map(\.endpoint)) == [remote.endpoint, sibling.endpoint])
        roster.managesNetwork = false
        precondition(roster.removableDevices(for: "guest").isEmpty)
        let former = NetworkSession(address: "guest/chat", name: "chat", person: "guest", agent: "离线", status: "offline")
        hub.current.conversations = [former]
        hub.current.selectedPeer = former.address
        precondition(hub.current.peers.contains(former) && !former.available && !hub.current.canSend)
        precondition(directory.removableDevices(for: "guest").isEmpty)
        hub.current.conversations = []
        precondition(!hub.current.peers.contains(former))
        print("PASS: offline device management, creator scope and history-only conversations after removal")
        precondition(!roster.isOnlyLocalHistory(former.address, origins: [:], registered: [], listed: []))
        precondition(!roster.isOnlyLocalHistory(former.address, origins: [former.address: [remote.endpoint]], registered: [], listed: []))
        precondition(roster.isOnlyLocalHistory(former.address, origins: [former.address: ["departed-host"]], registered: [], listed: []))
        precondition(directory.isOnlyLocalHistory(former.address, origins: [:], registered: [], listed: []))
        try await verifyHistoryDeletion(home: home, network: first, other: second.id)
        try await hub.current.leaveNetwork(first.id, dissolving: true)
        await hub.didLeave()
        precondition(hub.items.isEmpty && hub.archives.map(\.id) == [first.id])
        let cached = try SQLiteStore(first.root.appendingPathComponent("local-ui/messages.sqlite3"), readOnly: true)
        let messages = try cached.rows("SELECT body FROM network_events WHERE network=?",[first.id])
        precondition(messages.contains { $0["body"] == first.name })
        print("PASS: founder-only App action, self-device exclusion and archived history after dissolution")
        await hub.refreshDepartureNotices()
        precondition(hub.departureNotices.isEmpty, "An initiating device must not report a remote departure")
        try await verifyDepartureNotices(home: home, first: first, second: second)


    }

    static func verifyTools(first: NetworkWorkspace, second: NetworkWorkspace, home: URL) async throws {
        let id = UUID().uuidString.lowercased()
        func fixture(_ name: String, _ rows: [[String: Any]]) throws {
            let url = home.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
                .joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        try fixture(".claude/projects/qa/" + id + ".jsonl", [["cwd": home.path, "customTitle": "Claude QA"]])
        try fixture(".gemini/projects.json", [["projects": [home.path: "qa"]]])
        try fixture(".gemini/tmp/qa/chats/session.jsonl", [["sessionId": id, "title": "Gemini QA"]])
        try fixture(".dsh/sessions/qa/" + id + "/session.v4.jsonl", [
            ["id": id, "cwd": home.path, "version": 4], ["type": "session/title", "data": ["title": "dsh QA"]]
        ])
        for ws in [first, second] {
            let service = ReasonService(home: home, workspace: ws.id == first.id ? nil : ws.root, expectedNetwork: ws.id)
            var senders: [LocalSession] = []
            for (agent, title) in [("claude-code", "Claude QA"), ("gemini", "Gemini QA"), ("dsh", "dsh QA")] {
                let key = agent + ":" + id
                let candidates = try await service.personalSessions()
                let candidate = try require(candidates.first { $0.id == key })
                precondition(candidate.title == title && candidate.canJoin)
                _ = try await service.joinPersonalSession(key)
                let snap = try await service.snapshot(local: "", peer: "")
                let sender = try require(snap.localSessions.first { $0.key == key })
                precondition(sender.title == title && snap.directory.liveLocalSession(named: sender.name, agent: agent) != nil)
                let mode = try await service.setReceiveMode(.pull, local: sender, network: ws.id)
                precondition(mode == .pull)
                senders.append(sender)
            }
            for (i, sender) in senders.enumerated() {
                let next = senders[(i + 1) % senders.count]
                let peer = "qa/" + next.name, from = "qa/" + sender.name
                let text = ws.name + "/" + sender.agent
                _ = try await service.send(network: ws.id, local: sender.name, expectedKey: sender.key, to: peer, body: text)
                _ = try await service.snapshot(local: sender.name, peer: peer)
                let sent = try await service.history(network: ws.id, local: sender.name, peer: peer)
                let got = try await service.history(network: ws.id, local: next.name, peer: from)
                precondition(sent.messages.map(\.body) == [text] && got.messages.map(\.body) == [text])
                try await service.removeLocal(sender, network: ws.id, keepListed: true)
                let offline = try await service.snapshot(local: sender.name, peer: peer)
                precondition(offline.directory.liveLocalSession(named: sender.name, agent: sender.agent) == nil)
                try await service.reconnectLocal(sender, network: ws.id)
            }
        }
        print("PASS: three native tools with identical IDs, native titles, sender selection, scoped send/receive history, pull and reconnect in two workspaces")
    }

    @MainActor
    static func verifyDepartureNotices(home: URL, first: NetworkWorkspace, second: NetworkWorkspace) async throws {
        var keys: [String] = []
        for (workspace, reason) in [(first, "dissolved"), (second, "removed")] {
            let key = "departure:" + UUID().uuidString
            keys.append(key)
            let db = try SQLiteStore(workspace.root.appendingPathComponent("network.db"), readOnly: false)
            let json = try JSONEncoder().encode(["network": workspace.id, "name": workspace.name, "reason": reason])
            _ = try db.rows("INSERT INTO kv(key,value) VALUES(?,?)", [key, String(decoding: json, as: UTF8.self)])
        }
        let reopened = WorkspaceController(home: home)
        await reopened.refreshDepartureNotices()
        await reopened.refreshDepartureNotices()
        precondition(Set(reopened.departureNotices.map(\.id)) == Set(keys))
        precondition(reopened.departureNotices.contains { $0.reason == .removed && $0.name == second.name && $0.network == second.id })
        precondition(reopened.departureNotices.contains { $0.reason == .dissolved && $0.name == first.name && $0.network == first.id })
        reopened.acknowledgeDeparture(keys[0])
        let next = WorkspaceController(home: home)
        await next.refreshDepartureNotices()
        precondition(next.departureNotices.map(\.id) == [keys[1]])
        next.acknowledgeDeparture(keys[1])
        await next.refreshDepartureNotices()
        precondition(next.departureNotices.isEmpty)
        print("PASS: pending remote departures retain reason and workspace across launches and acknowledgements")
    }

    static func verifyHistoryDeletion(home: URL, network: NetworkWorkspace, other: String) async throws {
        let cache = try SQLiteStore(network.root.appendingPathComponent("local-ui/messages.sqlite3"), readOnly: false)
        let peer = "departed/chat"
        let now = Date().timeIntervalSince1970
        func event(_ id: String, _ time: Double, local: String = "beta", to: String = "departed/chat") -> Message {
            Message(id: id, at: time, local: local, peer: to, direction: "in", body: id, result: "")
        }
        let old = event("history-delete-old", now - 10)
        try cache.insert(old, network: network.id)
        try cache.insert(old, network: other)
        try cache.insert(event(old.id, now, local: "alpha"), network: network.id)
        try cache.insert(event("other-peer", now, to: "departed/other"), network: network.id)
        let service = ReasonService(home: home, expectedNetwork: network.id)
        let engine = try SQLiteStore(network.root.appendingPathComponent("network.db"), readOnly: false)
        _ = try engine.rows("INSERT INTO workspace_sent(network,id,sender_key,sender,recipient,sent_at,body,files) VALUES(?,?,?,?,?,?,?,?)",
                            [network.id,"engine-history","codex:test","qa/beta",peer,String(Int64(now * 1000)),"engine copy","[]"])
        let before = try await service.snapshot(local: "beta", peer: peer)
        precondition(before.messages.contains { $0.id == "engine-history" })
        precondition(before.conversations.contains { $0.address == peer && $0.deletableLocalHistory })
        do {
            try await service.deleteLocalHistory(network: network.id, local: "alpha", peer: "qa/beta")
            preconditionFailure("Refused deletion expected for a current member")
        } catch is NetworkError {}
        try await service.deleteLocalHistory(network: network.id, local: "beta", peer: peer)
        let reopened = ReasonService(home: home, expectedNetwork: network.id)
        try cache.reconcileEnvelope(event(old.id, now + 100), network: network.id, knowsFiles: true)
        try cache.insertMirrored(event("late-old", now - 20), network: network.id)
        let after = try await reopened.snapshot(local: "beta", peer: peer)
        precondition(!after.conversations.contains { $0.address == peer } && after.messages.isEmpty)
        let remaining = try cache.rows("SELECT id FROM network_events WHERE id IN (?,?)", [old.id, "other-peer"])
        precondition(remaining.count == 3)
        try cache.reconcileEnvelope(event("future-new", now + 100), network: network.id, knowsFiles: true)
        let new = try await reopened.snapshot(local: "beta", peer: peer)
        precondition(new.messages.map(\.id) == ["future-new"])
        print("PASS: local history deletion validates membership, survives reopen and replay, isolates workspaces and conversations, and accepts new messages")
    }

    @MainActor
    static func verify(_ hub: WorkspaceController, first: NetworkWorkspace, second: NetworkWorkspace, home: URL) async throws {
        let threadID = UUID().uuidString.lowercased()
        let betaID = UUID().uuidString.lowercased()
        let neverJoined = UUID().uuidString.lowercased()
        let codex = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let index = try SQLiteStore(codex.appendingPathComponent("state_5.sqlite"), readOnly: false)
        _ = try index.rows("CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,cwd TEXT,rollout_path TEXT,updated_at INTEGER,archived INTEGER)")
        _ = try index.rows("INSERT INTO threads VALUES(?,?,?,NULL,1,0)", [threadID,"Alpha",home.path])
        for (id, title) in [(betaID, "Beta"), (neverJoined, "New thread")] {
            _ = try index.rows("INSERT INTO threads VALUES(?,?,?,NULL,1,0)", [id,title,home.path])
        }
        for item in [second, first] {
            hub.select(item)
            await hub.current.refresh()
            let directory = try require(hub.current.directory)
            precondition(directory.networkID == item.id && directory.team == item.name)
            let invite = try await hub.current.invitation()
            let id = try NetworkPaths.inviteID(SetupInput.invitation(invite))
            precondition(id == item.id)
            try await hub.add(name: "", invitation: invite, person: "qa")
            precondition(hub.items.count == 2 && hub.selection?.id == item.id)
            let socket = SessionSocket(socketURL: NetworkPaths.socket(in: item.root))
            for name in ["alpha","beta"] {
                let id = name == "alpha" ? threadID : betaID
                let key = "codex:" + id
                _ = try socket.request(["op":"set_session_participation","key":key,"paused":false])
                let hook: [String: Any] = ["op":"hook","agent":"codex","event":"stop","session_id":id,
                                            "name":name,"cwd":home.path,"mail":false]
                _ = try socket.request(["op":"workspace_dispatch","network":item.id,"request":hook])
                _ = try socket.request(["op":"set_receive_mode","key":key,"network":item.id,"mode":"pull"])
            }
            let service = ReasonService(home: home, workspace: item.id == first.id ? nil : item.root, expectedNetwork: item.id)
            _ = try await service.send(network: item.id, local: "alpha", to: "qa/beta", body: item.name)
            _ = try await service.snapshot(local: "alpha", peer: "qa/beta")
            let history = try await service.history(network: item.id, local: "alpha", peer: "qa/beta")
            precondition(history.messages.map(\.body) == [item.name])
            _ = try await service.snapshot(local: "beta", peer: "qa/alpha")
            let received = try await service.history(network: item.id, local: "beta", peer: "qa/alpha")
            precondition(received.messages.map(\.body) == [item.name])
            hub.current.selectedLocal = "alpha"
            hub.current.selectedPeer = "qa/beta"
            hub.current.draft = item.name
        }
        await hub.current.refresh()
        let model = hub.current
        let sender = try require(model.own)
        precondition(model.senderPresence == .online && sender.key == "codex:" + threadID)
        let history = model.messages
        let joined = Set(["codex:" + threadID, "codex:" + betaID])
        precondition(Set(model.connectionTargets(disconnect: true).map(\.key)) == joined)
        await model.changeAllReceiveModes(.push, network: second.id)
        precondition(model.tier == "pull")
        await model.changeAllReceiveModes(.push, network: first.id)
        precondition(model.receiveModeError == nil && model.notice.text.contains("2/2"))
        precondition(model.onlineReceiveTargets.allSatisfy {
            model.directory?.liveLocalSession(named: $0.name, agent: "codex")?.tier == "push"
        })
        hub.select(second)
        await hub.current.refresh()
        precondition(hub.current.tier == "pull")
        hub.select(first)
        await model.changeAllReceiveModes(.pull, network: first.id)
        precondition(model.tier == "pull" && model.notice.text.contains("2/2"))
        // One target goes offline after discovery. The other must still switch.
        let socket = SessionSocket(socketURL: NetworkPaths.socket(in: first.root))
        _ = try socket.request(["op":"set_session_participation", "key":"codex:" + betaID, "paused":true])
        await model.changeAllReceiveModes(.push, network: first.id)
        precondition(model.tier == "push" && model.receiveModeError?.text.contains("Beta") == true && model.notice.text.contains("1/2"))
        await model.changeAllReceiveModes(.pull, network: first.id)
        precondition(model.tier == "pull" && model.notice.text.contains("1/1") && model.onlineReceiveTargets.map(\.key) == [sender.key])
        _ = try socket.request(["op":"set_session_participation", "key":"codex:" + betaID, "paused":false])
        let hook: [String: Any] = ["op":"hook","agent":"codex","event":"stop","session_id":betaID,
                                   "name":"beta","cwd":home.path,"mail":false]
        _ = try socket.request(["op":"workspace_dispatch","network":first.id,"request":hook])
        await model.refresh()
        precondition(model.draft == first.name && model.messages == history)
        print("PASS: bulk receive modes confirm effective tiers, report partial failures and skip offline sessions and other networks")
        await model.changeAllConnections(network: second.id, disconnect: true)
        precondition(model.senderPresence == .online)
        await model.changeAllConnections(network: first.id, disconnect: true)
        precondition(Set(model.connectionTargets(disconnect: false).map(\.key)) == joined)
        precondition(model.connectionReport == nil && model.connectionTargets(disconnect: true).isEmpty)
        precondition(model.selectedLocal == "alpha" && model.selectedPeer == "qa/beta" && model.messages == history && model.draft == first.name)
        hub.select(second)
        await hub.current.refresh()
        precondition(Set(hub.current.connectionTargets(disconnect: true).map(\.key)) == joined)
        hub.select(first)
        // A missing project should fail only its own reconnect, and remain retryable.
        _ = try index.rows("UPDATE threads SET cwd=? WHERE id=?", [home.appendingPathComponent("missing-project").path,betaID])
        await model.changeAllConnections(network: first.id, disconnect: false)
        precondition(model.senderPresence == .online && model.connectionTargets(disconnect: false).map(\.key) == ["codex:" + betaID])
        precondition(model.connectionReport?.text.contains("1/2") == true && model.connectionReport?.text.contains("Beta") == true)
        _ = try index.rows("UPDATE threads SET cwd=? WHERE id=?", [home.path,betaID])
        await model.changeAllConnections(network: first.id, disconnect: false)
        precondition(model.connectionReport == nil && Set(model.connectionTargets(disconnect: true).map(\.key)) == joined)

        await model.changeSenderConnection(sender, network: first.id, disconnect: true)
        precondition(model.senderPresence == .offline && model.own?.key == sender.key && !model.canSend)
        precondition(model.messages == history && model.draft == first.name && model.selectedPeer == "qa/beta")
        let reopened = ReasonService(home: home, expectedNetwork: first.id)
        let snapshot = try await reopened.snapshot(local: "alpha", peer: "qa/beta")
        precondition(snapshot.localSessions.contains { $0.key == sender.key && !$0.historyOnly })
        precondition(snapshot.directory.liveLocalSession(named: "beta", agent: "codex") != nil)
        let personal = try await reopened.personalSessions().first { $0.id == sender.key }
        precondition(personal?.connection == .disconnected("qa/alpha"))
        hub.select(second)
        await hub.current.refresh()
        precondition(hub.current.senderPresence == .online)
        hub.select(first)
        await model.changeSenderConnection(sender, network: first.id, disconnect: false)
        precondition(model.senderPresence == .online && model.own?.key == sender.key && model.draft == first.name)
        precondition(model.messages == history)
        await model.changeSenderConnection(sender, network: first.id, disconnect: true)
        _ = try await model.exitLocal(sender)
        precondition(!model.locals.contains { $0.key == sender.key })
        await model.changeAllConnections(network: first.id, disconnect: true)
        await model.changeAllConnections(network: first.id, disconnect: false)
        precondition(model.connectionTargets(disconnect: true).map(\.key) == ["codex:" + betaID])
        precondition(!model.locals.contains { $0.key == "codex:" + neverJoined || $0.key == sender.key })
        print("PASS: bulk connections target joined sessions in one workspace, preserve drafts and history, report partial failures, retry only offline sessions and exclude never-joined and exited threads")
        print("PASS: disconnect preserves selection, address, history and draft, survives reload, scopes the pause and resumes; exit hides it")
        hub.select(second)
        precondition(hub.current.draft == second.name)
        let restored = WorkspaceController(home: home)
        precondition(restored.selection?.id == second.id)
        hub.select(first)
        precondition(hub.current.locals.allSatisfy { $0.key != sender.key })
    }

    @MainActor
    static func leave(_ hub: WorkspaceController, workspace: NetworkWorkspace, storage: WorkspaceStore) async throws {
        hub.select(workspace)
        await hub.current.refresh()
        try await hub.current.leaveNetwork(workspace.id)
        await hub.didLeave()
    }

    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw NetworkError("Missing workspace fixture value") }
        return value
    }
}
