import Foundation

@main
struct WorkspaceChecks {
    @MainActor
    static func main() async throws {
        let home = URL(fileURLWithPath: CommandLine.arguments[1])
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
        } catch {
            try? await leave(hub, workspace: second, storage: storage)
            throw error
        }
        try await leave(hub, workspace: second, storage: storage)
        precondition(hub.items.map(\.id) == [first.id])
        print("PASS: App created a workspace, switched overviews, copied scoped invites, restored selection and independent drafts, left one network")
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
