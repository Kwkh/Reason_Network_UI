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
 print(json.dumps({'team':'fixture','person':'me','machine':'fixture-mac','sessions':[{'address':'peer/remote','name':'remote','person':'peer','doing':'Remote title','tier':'push'}],'machines':[{'person':'me','machine':'fixture-mac','endpoint':'fixture','is_me':True,'online':True}]}))
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
        let personal = try await service.personalSessions()
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
        let unread = try engine.rows("SELECT read_at FROM messages WHERE id='incoming'").first
        try expect(unread?["read_at"] == nil, "mirror never acknowledges inbox")
        do { _ = try await service.send(local: "missing", to: "peer/remote", body: "hello"); throw NetworkError("invalid local accepted") }
        catch { try expect(error.localizedDescription != "invalid local accepted", "reject detached local") }
        do { _ = try await service.send(local: "local", to: "unknown/peer", body: "hello"); throw NetworkError("invalid peer accepted") }
        catch { try expect(error.localizedDescription != "invalid peer accepted", "reject unknown recipient") }
        let body = "literal `whoami` $(touch /tmp/no-execution)\n中文"
        let status = try await service.send(local: "local", to: "peer/remote", body: body)
        try expect(status == "已排队", "queued is not read")
        let sent = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("sent.json"))) as! [String: Any]
        try expect(sent["body"] as? String == body, "message passed verbatim through stdin")
        try expect(sent["args"] as? [String] == ["--from", "codex:fixture", "peer/remote", "-"], "sender identity preserved")
        let after = try await service.snapshot(local: "local", peer: "peer/remote")
        try expect(after.messages.filter(\.outgoing).count == 1, "successful outgoing cached")
        let other = try await service.snapshot(local: "local", peer: "other/peer")
        try expect(other.messages.isEmpty, "conversation isolation")
        let literal = TranscriptMirror.literalSend(#"text(await tools.mcp__reason_network__send_message({to:"peer/remote",message:"hi\nthere"}));"#)
        try expect(literal?["message"] as? String == "hi\nthere", "literal extraction")
        try expect(TranscriptMirror.literalSend(#"tools.mcp__reason_network__send_message({to:recipient,message:body})"#) == nil, "never evaluate variables")
        try expect(TranscriptMirror.literalSend(#"tools.mcp__reason_network__send_message({to:'peer/remote',message:'hello'})"#)?["to"] as? String == "peer/remote", "legacy single-quoted literals")
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
        try expect(try mirror.events(for: local).isEmpty, "partial JSONL output delayed")
        let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd(); try handle.write(contentsOf: output.suffix(from: split)); try handle.close()
        let events = try mirror.events(for: local)
        try expect(events.count == 1 && events.first?.body == "from agent", "incremental transcript recovery")
        try expect(try mirror.events(for: local).isEmpty, "transcript not duplicated")
        print("PASS: native adapter, read-only inbox, held-message exclusion, conversation isolation, sender identity, literal extraction, partial JSONL, and send cache")
    }
}
