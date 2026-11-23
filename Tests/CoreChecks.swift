import Foundation

@main
struct CoreChecks {
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NetworkError("FAIL: " + message) }
    }
    static func checkReadingWindow() throws {
        func sample(_ id: Int) -> Message {
            Message(id: String(id), at: Double(id), local: "local", peer: "peer", direction: "in",
                    body: "Message \(id)", result: "")
        }

        var window = ConversationReadingWindow()
        let initial = (1...99).map(sample)
        let full = initial + [sample(100)]
        let next = (2...101).map(sample)
        try expect(window.receive(initial, atBottom: false), "first load follows latest")
        try expect(!window.receive(full, atBottom: false) && window.messages == full,
                   "pure append leaves the reading position alone")
        try expect(!window.receive(next, atBottom: false) && window.messages == full && window.hasPendingUpdate,
                   "dropping the oldest row during reading preserves the displayed window")
        let burst = (202...301).map(sample)
        try expect(!window.receive(burst, atBottom: false) && window.messages == full,
                   "a burst with no overlap still preserves the paragraph")
        window.show(burst)
        try expect(window.messages == burst && !window.hasPendingUpdate, "jump shows the latest snapshot")
        try expect(!window.receive(burst, atBottom: true), "identical polling never scrolls")
        try expect(window.receive(next, atBottom: true) && window.messages == next, "pinned view follows replacement")
        try expect(!window.receive([], atBottom: false) && window.messages.isEmpty, "empty history clears visible rows")
    }

    @MainActor
    static func checkExpandedHistory(service: ReasonService, cache: SQLiteStore) async throws {
        let model = NetworkModel(service: service)
        model.selectedLocal = "local"
        model.selectedPeer = "history"
        await model.refresh()
        guard let first = model.messages.first else { throw NetworkError("missing initial history") }
        let earlier = try await model.loadEarlier(before: first)
        try expect(earlier.messages.count == 100, "second history page loaded")
        let delayed = Message(id: "page042-late", at: 42, local: "local", peer: "history", direction: "out",
                              body: "第一段\u{0}第二段", result: "queued", receiptStage: nil)
        try cache.insert(delayed, network: "team-a")
        _ = try cache.rows("UPDATE network_events SET receipt_stage='replied' WHERE network='team-a' AND id='page042-late'")
        await model.refresh()
        try expect(model.messages.count == 201 && model.messages.first?.id == earlier.messages.first?.id,
                   "poll keeps the loaded page including a delayed insertion")
        let row = model.messages.first { $0.id == delayed.id }
        try expect(row?.body == delayed.body && row?.delivery == "已回复", "backfilled body and receipt are visible on older page")
        model.selectedPeer = "peer/remote"
        do {
            _ = try await model.loadEarlier(before: first)
            throw NetworkError("wrong conversation's cursor was accepted")
        } catch is CancellationError {}
        await model.refresh()
        try expect(model.messages.allSatisfy { $0.peer == "peer/remote" }, "peer switch discards old range")
        model.selectedPeer = "history"
        await model.refresh()
        try expect(model.messages.count == 100, "reopening starts at the current latest page")
    }

    @MainActor
    static func checkOfflineSender(home: URL, service: ReasonService) async throws {
        let model = NetworkModel(service: service)
        model.selectedLocal = "local"
        model.selectedPeer = "peer/remote"
        await model.refresh()
        let original = NetworkModel.Draft(text: "待发送", files: [home.appendingPathComponent("notes.txt")], notify: true)
        model.options = original
        try expect(model.canSend, "registered local sender can send")
        try expect(model.senderPresence == .online, "sidebar and toolbar share the registered sender state")
        let connected = model.directory
        if let directory = connected, let device = directory.machines.first(where: \.isMe) {
            let unavailable = Device(person: device.person, machine: device.machine, endpoint: device.endpoint, isMe: true, online: false, link: nil, rttMs: nil)
            model.directory = Directory(networkID: directory.networkID, team: directory.team, person: directory.person,
                                        machine: directory.machine, sessions: directory.sessions, machines: [unavailable])
            try expect(model.senderPresence == .offline && !model.canSend && unavailable.state == "离线", "an offline host overrides a stale live session")
            model.directory = connected
        }
        model.error = "fixture unavailable"
        try expect(model.senderPresence == .unknown, "a failed refresh cannot publish stale online status")
        model.error = nil
        let marker = home.appendingPathComponent("offline")
        try Data().write(to: marker)
        await model.refresh()
        try expect(model.senderPresence == .offline && !model.canSend, "a live namesake on another machine cannot send for this one")
        await model.send()
        do {
            _ = try await service.send(network: "team-a", local: "local", to: "peer/remote", body: "blocked")
            throw NetworkError("offline send accepted")
        } catch is LocalSenderOffline {}
        try expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("sent.json").path), "offline sender never dispatched")
        await model.reconnectSender()
        try expect(!model.notice.isEmpty && model.senderOffline && model.options == original, "unavailable native thread leaves draft intact")
        try FileManager.default.removeItem(at: marker)
        await model.refresh()
        try expect(model.canSend && model.options == original, "confirmed return enables sending with the original draft")
    }

    static func main() async throws {
        try checkReadingWindow()
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("reason-native-checks-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        for path in [".reason/network", ".local/bin", ".codex/sessions"] {
            try fm.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let engineURL = home.appendingPathComponent(".reason/network/network.db")
        let engine = try SQLiteStore(engineURL, readOnly: false)
        _ = try engine.rows("CREATE TABLE kv(key TEXT PRIMARY KEY,value TEXT)")
        func joinFixture(_ id: String) throws {
            _ = try engine.rows("INSERT OR REPLACE INTO kv VALUES('team',json_object('id',?))", [id])
        }
        try joinFixture("team-a")
        _ = try engine.rows("CREATE TABLE sessions(name TEXT,key TEXT,agent TEXT,doing TEXT,attached INTEGER,last_seen INTEGER)")
        _ = try engine.rows("INSERT INTO sessions VALUES('local','codex:fixture','codex','Local title',1,1)")
        _ = try engine.rows("CREATE TABLE messages(id TEXT,sent_at INTEGER,sender TEXT,body TEXT,reply_to TEXT,recipient TEXT,held INTEGER,read_at INTEGER)")
        _ = try engine.rows("INSERT INTO messages VALUES('incoming',1000,'peer/remote','hello',NULL,'me/local',0,NULL)")
        _ = try engine.rows("INSERT INTO messages VALUES('held',2000,'peer/remote','hidden',NULL,'me/local',1,NULL)")
        let readonly = try SQLiteStore(engineURL, readOnly: true)
        do { _ = try readonly.rows("UPDATE messages SET read_at=5"); throw NetworkError("readonly mutation succeeded") }
        catch { try expect(error.localizedDescription != "readonly mutation succeeded", "engine must stay read-only") }
        let script = #"""
#!/usr/bin/python3
import json,sys,pathlib
home=pathlib.Path(__file__).resolve().parents[2]
if sys.argv[1]=='who':
 local={'address':'me/local','name':'local','agent':'codex','person':'me','machine':'fixture-mac','status':'live','tier':'pull'}
 if (home/'offline').exists(): local['machine']='another-mac'
 print(json.dumps({'team':'fixture','person':'me','machine':'fixture-mac','sessions':[{'address':'peer/remote','name':'remote','person':'peer','doing':'Remote title','tier':'push'},local],'machines':[{'person':'me','machine':'fixture-mac','endpoint':'fixture','is_me':True,'online':True}]}))
elif sys.argv[1]=='leave':
 assert sys.argv[2:] == []
 if (home/'refuse').exists(): sys.exit("no teammate is online")
 import sqlite3
 with sqlite3.connect(home/'.reason/network/network.db') as db: db.execute("delete from kv where key='team'")
 print("Left fixture.")
elif sys.argv[1]=='send':
 (home/'sent.json').write_text(json.dumps({'args':sys.argv[2:],'body':sys.stdin.read()}))
 print('queued\nmessage id 01234567890123456789012345')
elif sys.argv[1]=='link': print('Join the Reason Network: https://reasonmachines.com/network/join/#rn1-fixture')
elif sys.argv[1]=='doctor': print('fixture healthy')
"""#
        let cli = home.appendingPathComponent(".local/bin/reason-network")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let service = ReasonService(home: home)
        _ = try engine.rows("ALTER TABLE sessions ADD COLUMN cwd TEXT")
        _ = try engine.rows("ALTER TABLE sessions ADD COLUMN tier TEXT DEFAULT 'push'")
        let catalog = try SQLiteStore(home.appendingPathComponent(".codex/state_1.sqlite"), readOnly: false)
        _ = try catalog.rows("CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,updated_at INTEGER,source TEXT)")
        let reviewID = UUID().uuidString, userID = UUID().uuidString
        for (id, source) in [(reviewID, #"{"subagent":{"other":"guardian"}}"#), (userID, "cli")] {
            _ = try catalog.rows("INSERT INTO threads VALUES(?, 'Guardian review','/tmp','',10,?)", [id, source])
        }
        _ = try engine.rows("INSERT INTO sessions(name,key,agent,doing,attached,last_seen) VALUES('review',?,'codex','review',1,1)", ["codex:" + reviewID])
        _ = try catalog.rows("ALTER TABLE threads ADD COLUMN thread_source TEXT")
        let workerID = UUID().uuidString, legacyWorkerID = UUID().uuidString, visibleID = UUID().uuidString
        for (id, kind, source) in [(workerID, "subagent", "vscode"), (visibleID, "user", "vscode"),
                                   (legacyWorkerID, "", #"{"subagent":{"thread_spawn":{}}}"#)] {
            _ = try catalog.rows("INSERT INTO threads VALUES(?, 'hatch-pet','/tmp','',10,?,?)", [id, source, kind])
        }
        for field in ["archived INTEGER", "archived_at INTEGER", "project_id TEXT", "attached_thread_parent_id TEXT"] {
            _ = try catalog.rows("ALTER TABLE threads ADD COLUMN " + field)
        }
        let archived = UUID().uuidString, child = UUID().uuidString, voice = UUID().uuidString
        for (id, kind) in [(archived, "user"), (child, "user"), (voice, "realtime_voice")] {
            _ = try catalog.rows("INSERT INTO threads(id,title,cwd,updated_at,thread_source) VALUES(?,'old','/tmp',10,?)", [id,kind])
            _ = try engine.rows("INSERT INTO sessions(name,key,agent,attached,last_seen) VALUES('stale',?,'codex',1,1)", ["codex:" + id])
        }
        _ = try catalog.rows("UPDATE threads SET archived=1 WHERE id=?", [archived])
        _ = try catalog.rows("UPDATE threads SET attached_thread_parent_id=? WHERE id=?", [userID, child])
        let desktop: [String: Any] = [
            "local-projects": ["multi": ["name":"Grouped", "rootPaths":["/a","/tmp"]]],
            "thread-project-assignments": [userID: ["projectId":"multi"]],
            "projectless-thread-ids": [visibleID], "project-order":["multi"]
        ]
        try JSONSerialization.data(withJSONObject: desktop).write(to: home.appendingPathComponent(".codex/.codex-global-state.json"))
        let claudeFolder = home.appendingPathComponent(".claude/projects/fixture")
        try fm.createDirectory(at: claudeFolder, withIntermediateDirectories: true)
        let claudeID = UUID().uuidString
        try """
        {"customTitle":"My Claude chat"}
        {"slug":"generated-slug","aiTitle":"Generated title"}
        """.write(to: claudeFolder.appendingPathComponent(claudeID + ".jsonl"), atomically: true, encoding: .utf8)
        let personal = try await service.personalSessions()
        try expect(personal.first { $0.nativeID == claudeID }?.title == "My Claude chat", "custom Claude title wins over later generated metadata")
        try expect(!personal.contains { [archived, child, voice].contains($0.nativeID ?? String($0.id.dropFirst(6))) }, "archived and attached sessions stay hidden after engine merge")
        try expect(personal.first { $0.nativeID == userID }?.displayProject.name == "Grouped", "project assignment takes precedence over directory name")
        try expect(personal.first { $0.nativeID == visibleID }?.displayProject == .unassigned, "projectless overrides matching root")
        try expect(!personal.contains { ["codex:" + workerID, "codex:" + legacyWorkerID].contains($0.id) },
                   "worker threads hidden across index formats")
        try expect(personal.contains { $0.id == "codex:" + visibleID }, "original user skill chat preserved")
        try expect(!personal.contains { $0.id == "codex:" + reviewID }, "internal reviewer excluded from both inventories")
        try expect(personal.contains { $0.id == "codex:" + userID }, "user conversation with identical title preserved")
        try expect(personal.contains { $0.title == "Local title" && $0.agentName == "Codex" },
                   "known local session retains its title and agent")
        try expect(personal.first?.canLeave == false, "stock daemon cannot pause a session")
        let invitation = try await service.inviteLink()
        try expect(invitation == "https://reasonmachines.com/network/join/#rn1-fixture", "copy only the invitation URL")
        let snapshot = try await service.snapshot(local: "local", peer: "peer/remote")
        try expect(snapshot.messages.count == 1, "held messages excluded")
        try expect(snapshot.localSessions.first?.title == "Local title", "local title retained")
        try expect(snapshot.directory.sessions.first?.title == "Remote title", "remote title decoded")
        try expect(snapshot.directory.machines.first?.isMe == true, "snake case device fields decoded")
        _ = try catalog.rows("ALTER TABLE threads ADD COLUMN name TEXT")
        _ = try catalog.rows("INSERT INTO threads(id,title,name) VALUES('fixture','Generated','Renamed in Codex')")
        let renamed = try await service.snapshot(local: "local", peer: "peer/remote")
        try expect(renamed.localSessions.first { $0.name == "local" }?.title == "Renamed in Codex", "local picker uses native title when absent from directory")
        _ = try catalog.rows("UPDATE threads SET name='' WHERE id='fixture'")
        let reverted = try await service.snapshot(local: "local", peer: "peer/remote")
        try expect(reverted.localSessions.first { $0.name == "local" }?.title == "Generated", "refresh observes title changes, including removed custom name")
        let advertised = try JSONDecoder().decode(NetworkSession.self, from: Data(#"{"address":"other/s","name":"s","person":"other","title":"A · B","doing":"A · B · testing"}"#.utf8))
        try expect(advertised.title == "A · B", "explicit peer title takes precedence over activity")
        let unread = try engine.rows("SELECT read_at FROM messages WHERE id='incoming'").first
        try expect(unread?["read_at"] == nil, "mirror never acknowledges inbox")
        do { _ = try await service.send(network: "team-a", local: "missing", to: "peer/remote", body: "hello"); throw NetworkError("invalid local accepted") }
        catch { try expect(error.localizedDescription != "invalid local accepted", "reject detached local") }
        do { _ = try await service.send(network: "team-a", local: "local", to: "unknown/peer", body: "hello"); throw NetworkError("invalid peer accepted") }
        catch { try expect(error.localizedDescription != "invalid peer accepted", "reject unknown recipient") }
        try await checkOfflineSender(home: home, service: service)
        let body = "literal `whoami` $(touch /tmp/no-execution)\n中文"
        let status = try await service.send(network: "team-a", local: "local", to: "peer/remote", body: body)
        try expect(status == "已排队", "queued is not read")
        let sent = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("sent.json"))) as! [String: Any]
        try expect(sent["body"] as? String == body, "message passed verbatim through stdin")
        try expect(sent["args"] as? [String] == ["--from", "codex:fixture", "peer/remote", "-"], "sender identity preserved")
        let after = try await service.snapshot(local: "local", peer: "peer/remote")
        try expect(after.messages.filter(\.outgoing).count == 1, "successful outgoing cached")
        _ = try engine.rows("CREATE TABLE sent_receipts(id TEXT,sender TEXT,recipient TEXT,stage TEXT,sent_at INTEGER)")
        _ = try engine.rows("INSERT INTO sent_receipts VALUES('01234567890123456789012345','me/local','peer/remote','replied',1000)")
        let updated = try await service.snapshot(local: "local", peer: "peer/remote")
        try expect(updated.messages.first(where: { $0.outgoing })?.delivery == "已回复", "remote reply replaces initial queue status")
        var visible = ConversationReadingWindow()
        visible.show(after.messages)
        try expect(!visible.receive(updated.messages, atBottom: false) && visible.messages == updated.messages &&
                   !visible.hasPendingUpdate, "receipt-only updates preserve scroll position")
        let other = try await service.snapshot(local: "local", peer: "other/peer")
        try expect(other.messages.isEmpty, "conversation isolation")
        let file = home.appendingPathComponent("log file.txt")
        try Data("附件正文".utf8).write(to: file)
        _ = try await service.send(network: "team-a", local: "local", to: "peer/remote", body: "", files: [file], notify: true)
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("sent.json"))) as! [String: Any]
        try expect(request["args"] as? [String] == ["--from","codex:fixture","--notify","--file",file.path,"peer/remote","-"] &&
                   request["body"] as? String == "附件", "attachment-only notification uses the selected Codex sender")
        try Data([0, 255]).write(to: file)
        do { _ = try await service.send(network: "team-a", local: "local", to: "peer/remote", body: "binary", files: [file]); throw NetworkError("FAIL binary accepted") }
        catch { try expect(error.localizedDescription != "FAIL binary accepted", "binary rejected") }
        let folder = "01234567890123456789012345"
        let inbox = home.appendingPathComponent(".reason/network/inbox/" + folder)
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        try Data("received text".utf8).write(to: inbox.appendingPathComponent("log.txt"))
        _ = try engine.rows("ALTER TABLE messages ADD COLUMN files TEXT")
        _ = try engine.rows("UPDATE messages SET files=? WHERE id='incoming'", [#"{"dir":"01234567890123456789012345","files":[{"name":"log.txt","content":""}]}"#])
        let withFiles = try await service.snapshot(local: "local", peer: "peer/remote")
        guard let received = withFiles.messages.first(where: { $0.id == "incoming" })?.attachments.first else { throw NetworkError("missing cached attachment") }
        let preview = try await service.attachmentText(received)
        try expect(preview == "received text", "preview reads the engine's saved inbox file")
        let escaping = MessageAttachment(name: "../outside", directory: folder)
        do { _ = try await service.attachmentText(escaping); throw NetworkError("FAIL outside inbox") }
        catch { try expect(error.localizedDescription != "FAIL outside inbox", "preview confined to inbox") }
        let cache = try SQLiteStore(home.appendingPathComponent(".reason/network/local-ui/messages.sqlite3"), readOnly: false)
        for i in 0..<230 {
            try cache.insert(Message(id: String(format: "page%03d", i), at: 42, local: "local", peer: "history", direction: "in", body: "正文", result: ""), network: "team-a")
        }
        let newest = try await service.history(network: "team-a", local: "local", peer: "history")
        let middle = try await service.history(network: "team-a", local: "local", peer: "history", before: newest.messages[0].rowKey)
        let oldest = try await service.history(network: "team-a", local: "local", peer: "history", before: middle.messages[0].rowKey)
        let pages = oldest.messages + middle.messages + newest.messages
        try expect(pages.count == 230 && Set(pages.map(\.id)).count == 230 && pages[0].id == "page000", "keyset paging handles equal timestamps")
        try expect(newest.hasEarlier && middle.hasEarlier && !oldest.hasEarlier, "exact page boundaries")
        var reading = ConversationReadingWindow()
        reading.show(newest.messages)
        reading.prepend(middle, before: newest.messages[0].rowKey)
        try expect(!reading.receive(newest.messages, atBottom: false) && reading.messages.count == 200, "poll preserves explicitly loaded history")
        try await checkExpandedHistory(service: service, cache: cache)
        _ = try engine.rows("INSERT INTO sessions(name,key,agent,doing,attached,last_seen) VALUES('detached','codex:detached','codex',NULL,0,1)")
        _ = try engine.rows("INSERT INTO messages(id,sent_at,sender,body,recipient,held) VALUES('late-in',2000,'peer/remote','late','me/detached',0)")
        let offline = try await service.snapshot(local: "detached", peer: "peer/remote")
        try expect(offline.messages.map(\.id) == ["late-in"] && offline.localSessions.first { $0.name == "detached" }?.historyOnly == true,
                   "mail arriving before detach is mirrored without bringing the session online")
        // A second app using the same cache can have a per-mailbox primary key.
        let sharedDir = home.appendingPathComponent("shared-fixture")
        let dbDir = sharedDir.appendingPathComponent(".reason/network/local-ui")
        try fm.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let shared = try SQLiteStore(dbDir.appendingPathComponent("messages.sqlite3"), readOnly: false)
        _ = try shared.rows("""
            CREATE TABLE events(id TEXT NOT NULL, at REAL, local_session TEXT NOT NULL, peer TEXT,
              direction TEXT NOT NULL, body TEXT, result TEXT, reply_to TEXT, attachments TEXT NOT NULL DEFAULT '',
              unread INTEGER, PRIMARY KEY(id,local_session,direction))
            """)
        func sharedEvent(_ mailbox: String, _ direction: String, files: [MessageAttachment] = []) -> Message {
            Message(id: "same", at: 42, local: mailbox, peer: "peer", direction: direction, body: "original", result: "", attachments: files)
        }
        try shared.insert(sharedEvent("one", "in"))
        try shared.insert(sharedEvent("two", "in"))
        try shared.insert(sharedEvent("one", "out"))
        _ = try shared.rows("UPDATE events SET unread=1")
        try shared.insert(sharedEvent("one", "in", files: [received]))
        try shared.insert(sharedEvent("one", "in"))
        let sharedService = ReasonService(home: sharedDir)
        let sharedCli = sharedDir.appendingPathComponent(".local/bin/reason-network")
        try fm.createDirectory(at: sharedCli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: cli, to: sharedCli)
        try fm.copyItem(at: engineURL, to: sharedDir.appendingPathComponent(".reason/network/network.db"))
        _ = try await sharedService.snapshot(local: "one", peer: "peer")
        let scoped = try await sharedService.history(network: "team-a", local: "one", peer: "peer")
        try expect(scoped.messages.count == 2 && Set(scoped.messages.map(\.rowKey)).count == 2, "both directions are distinct transcript rows")
        let prior = try await sharedService.history(network: "team-a", local: "one", peer: "peer", before: scoped.messages[1].rowKey)
        try expect(prior.messages == [scoped.messages[0]], "cursor disambiguates same ID and timestamp")
        let saved = try shared.rows("SELECT * FROM events")
        try expect(saved.count == 3 && saved.allSatisfy { $0["unread"] == "1" && $0["body"] == "original" }, "existing cache content and unread flags survive")
        try expect(saved.filter { $0["attachments"]?.isEmpty == false }.count == 1 &&
                   scoped.messages.first(where: { $0.direction == "in" })?.attachments == [received], "attachment backfill scoped to the correct mailbox and direction")
        let blocked = home.appendingPathComponent("refuse")
        try Data().write(to: blocked)
        do { try await service.leaveNetwork(expected: "team-a"); throw NetworkError("FAIL refused exit accepted") }
        catch { try expect(error.localizedDescription.contains("没有在线队友"), "offline peer refusal preserves team") }
        try fm.removeItem(at: blocked)
        do { try await service.leaveNetwork(expected: "team-b"); throw NetworkError("FAIL stale confirmation") }
        catch { try expect(error.localizedDescription.contains("已变化"), "stale confirmation cannot leave another team") }
        try await service.leaveNetwork(expected: "team-a")
        try expect(try engine.rows("SELECT key FROM kv WHERE key='team'").isEmpty, "device actually left fixture team")
        try SQLiteStore.prepareNetworkJoin(home: home)
        try joinFixture("team-b")
        _ = try engine.rows("INSERT INTO messages(id,sent_at,sender,body,recipient,held) VALUES('other-team',1000,'peer/remote','another network','me/local',0)")
        let restarted = ReasonService(home: home)
        let otherNetwork = try await restarted.snapshot(local: "local", peer: "peer/remote")
        try expect(otherNetwork.messages.map(\.id) == ["other-team"], "same network name and peer address cannot show previous network inbox or outbox")
        try await restarted.leaveNetwork(expected: "team-b")
        try SQLiteStore.prepareNetworkJoin(home: home)
        try joinFixture("team-a")
        let restored = try await ReasonService(home: home).snapshot(local: "local", peer: "peer/remote")
        try expect(restored.messages == withFiles.messages, "original incoming and sent messages and attachments survive leaving, other team and restart")
        print("PASS: confirmed leave, stale confirmation, refused leave, same-address team isolation and rejoin history")
        let literal = TranscriptMirror.literalSend(#"text(await tools.mcp__reason_network__send_message({to:"peer/remote",message:"hi\nthere"}));"#)
        try expect(literal?["message"] as? String == "hi\nthere", "literal extraction")
        try expect(TranscriptMirror.literalSend(#"tools.mcp__reason_network__send_message({to:recipient,message:body})"#) == nil, "never evaluate variables")
        try expect(TranscriptMirror.literalSend(#"tools.mcp__reason_network__send_message({to:'peer/remote',message:'hello'})"#)?["to"] as? String == "peer/remote", "legacy single-quoted literals")
        let withAttachment = TranscriptMirror.literalSend(#"tools.mcp__reason_network__send_message({to:"peer/remote",files:["/tmp/a.txt"],notify:true,message:`a\nb`})"#)
        try expect(withAttachment?["files"] as? [String] == ["/tmp/a.txt"] && withAttachment?["message"] as? String == "a\nb", "static template with literal attachment array")
        try expect(TranscriptMirror.literalSend(#"tools.mcp__reason_network__send_message({to:"peer",message:`a${variable}`})"#) == nil, "dynamic templates are never reconstructed")
        let log = home.appendingPathComponent(".codex/sessions/rollout-fixture.jsonl")
        func line(_ item: [String: Any]) throws -> Data {
            var result = try JSONSerialization.data(withJSONObject: ["type":"response_item","timestamp":"2026-11-22T00:00:00.000Z","payload":item]); result.append(10); return result
        }
        let call = try line(["type":"function_call","call_id":"one","name":"mcp__reason_network__send_message","arguments":"{\"to\":\"peer/remote\",\"message\":\"from agent\"}"])
        let output = try line(["type":"function_call_output","call_id":"one","output":"queued message id 11234567890123456789012345"])
        let split = output.count / 2
        var first = call; first.append(output.prefix(split)); try first.write(to: log)
        let mirror = TranscriptMirror(root: home.appendingPathComponent(".codex/sessions"))
        let local = LocalSession(name: "local", key: "codex:fixture")
        func mirrored() throws -> [Message] {
            var events: [Message] = []
            try mirror.sync(for: local) { events += $0 }
            return events
        }
        try expect(try mirrored().isEmpty, "partial JSONL output delayed")
        let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd(); try handle.write(contentsOf: output.suffix(from: split)); try handle.close()
        do {
            try mirror.sync(for: local) { _ in throw NetworkError("simulated cache lock") }
            throw NetworkError("FAIL: missing mirror persistence attempt")
        } catch { try expect(error.localizedDescription == "simulated cache lock", "cache failure reported") }
        let events = try mirrored()
        try expect(events.count == 1 && events.first?.body == "from agent", "incremental transcript recovery")
        try expect(try mirrored().isEmpty, "transcript not duplicated")
        let replacement = try line(["type":"function_call_output","call_id":"one","output":"queued message id 21234567890123456789012345"])
        try (call + replacement).write(to: log, options: .atomic)
        try expect(try mirrored().map(\.id) == ["21234567890123456789012345"], "same path and size with a new inode is reread")
        let archive = home.appendingPathComponent(".codex/archived_sessions")
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        try (call + replacement).write(to: archive.appendingPathComponent("rollout-detached.jsonl"))
        let archivedHistory = try await ReasonService(home: home).snapshot(local: "detached", peer: "peer/remote")
        try expect(archivedHistory.messages.contains { $0.outgoing && $0.id == "21234567890123456789012345" },
                   "network history survives archiving of a detached Codex thread")
        var large = call + output
        large.append(Data(repeating: 32, count: 8_100_000))
        large.append(10)
        try large.write(to: log)
        let reopened = TranscriptMirror(root: log.deletingLastPathComponent())
        var backfill: [Message] = []
        try reopened.sync(for: local) { backfill += $0 }
        try expect(backfill.map(\.id) == events.map(\.id), "fresh mirror reads records before the former 8 MB cutoff")
        print("PASS: native adapter, read-only inbox, held-message exclusion, conversation isolation, sender identity, literal extraction, partial JSONL, and send cache")
    }
}
