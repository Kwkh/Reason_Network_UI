import Foundation

@main
struct CoreChecks {
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NetworkError("FAIL: " + message) }
    }
    static func main() async throws {
        try checkConversationGroups()
        let fm = FileManager.default
        let home = URL(fileURLWithPath: "/tmp").appendingPathComponent("reason-checks-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        for path in [".reason/network/local-ui", ".local/bin", ".codex/sessions",
                     "Library/Application Support/Reason Network Console"] {
            try fm.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let engineURL = home.appendingPathComponent(".reason/network/network.db")
        let engine = try SQLiteStore(engineURL, readOnly: false)
        _ = try engine.rows("CREATE TABLE sessions(name TEXT,key TEXT,agent TEXT,doing TEXT,attached INTEGER,last_seen INTEGER)")
        _ = try engine.rows("INSERT INTO sessions VALUES('local','codex:fixture','codex','Local title',1,1)")
        _ = try engine.rows("CREATE TABLE messages(id TEXT,sent_at INTEGER,sender TEXT,body TEXT,reply_to TEXT,recipient TEXT,held INTEGER,read_at INTEGER)")
        _ = try engine.rows("INSERT INTO messages VALUES('incoming',1000,'peer/remote','hello',NULL,'me/local',0,NULL)")
        _ = try engine.rows("INSERT INTO messages VALUES('held',2000,'peer/remote','hidden',NULL,'me/local',1,NULL)")
        _ = try engine.rows("ALTER TABLE messages ADD COLUMN files TEXT")
        _ = try engine.rows("UPDATE messages SET files=? WHERE id='incoming'",
                            [#"{"dir":"fixture","bytes":5,"files":[{"name":"notes.txt"}]}"#])
        let oldCache = try SQLiteStore(home.appendingPathComponent(".reason/network/local-ui/messages.sqlite3"), readOnly: false)
        _ = try oldCache.rows("CREATE TABLE events (id TEXT PRIMARY KEY, at REAL, local_session TEXT, peer TEXT, direction TEXT, body TEXT, result TEXT, reply_to TEXT)")
        _ = try oldCache.rows("INSERT INTO events VALUES('old-event',0,'local','old/peer','in','from the previous cache','',NULL)")
        let readonly = try SQLiteStore(engineURL, readOnly: true)
        do { _ = try readonly.rows("UPDATE messages SET read_at=5"); throw NetworkError("readonly mutation succeeded") }
        catch { try expect(error.localizedDescription != "readonly mutation succeeded", "engine must stay read-only") }
        let script = #"""
#!/usr/bin/python3
import json,sys,pathlib
home=pathlib.Path(__file__).resolve().parents[2]
if sys.argv[1]=='who':
 print(json.dumps({'team':'fixture','person':'me','machine':'fixture-mac','sessions':[{'address':'peer/remote','name':'remote','person':'peer','doing':'Remote title','tier':'push'},{'address':'me/local','name':'local','person':'me','machine':'fixture-mac','agent':'codex','tier':'push'}],'machines':[{'person':'me','machine':'fixture-mac','endpoint':'fixture','is_me':True,'online':True}]}))
elif sys.argv[1]=='send':
 (home/'sent.json').write_text(json.dumps({'args':sys.argv[2:],'body':sys.stdin.read()}))
 print('queued\nmessage id 01234567890123456789012345')
elif sys.argv[1]=='doctor': print('fixture healthy')
elif sys.argv[1]=='link': print('Join the Reason Network: https://reasonmachines.com/network/join/fixture')
elif sys.argv[1] in ('stop','setup'):
 (home/'management.log').open('a').write(sys.argv[1]+'\n')
"""#
        let cli = home.appendingPathComponent(".local/bin/reason-network")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let service = ReasonService(home: home)
        let snapshot = try await service.snapshot(local: "local", peer: "peer/remote")
        try expect(snapshot.messages.count == 1, "held messages excluded")
        try expect(snapshot.messages.first?.attachments.first?.name == "notes.txt", "engine attachment metadata decoded")
        try expect(snapshot.conversations.first?.preview == "hello", "conversation preview uses the most recent message")
        try expect(snapshot.localSessions.first?.title == "Local title", "local title retained")
        try expect(snapshot.localSessions.contains(.console), "standalone console available")
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
        let other = try await service.snapshot(local: "local", peer: "old/peer")
        try expect(other.messages.map(\.body) == ["from the previous cache"], "conversation isolation and cache migration")
        let attachment = home.appendingPathComponent("notes.txt")
        try Data("附件内容".utf8).write(to: attachment)
        _ = try await service.send(local: "local", to: "peer/remote", body: "with a file", files: [attachment], wake: false, notify: true)
        let fileSend = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("sent.json"))) as! [String: Any]
        try expect(fileSend["args"] as? [String] == ["--from", "codex:fixture", "--fyi", "--notify", "--file", attachment.path, "peer/remote", "-"],
                   "attachment, wake and notification options passed to the CLI")
        let badFile = home.appendingPathComponent("picture.bin")
        try Data([0, 255]).write(to: badFile)
        do { _ = try await service.send(local: "local", to: "peer/remote", body: "invalid file", files: [badFile]); throw NetworkError("binary attachment accepted") }
        catch { try expect(error.localizedDescription != "binary attachment accepted", "binary attachments are rejected") }
        try await service.restart()
        try await service.repair()
        let management = try String(contentsOf: home.appendingPathComponent("management.log"), encoding: .utf8)
        try expect(management == "stop\nsetup\n", "service management uses the official commands")
        let invite = try await service.inviteLink()
        try expect(invite == "https://reasonmachines.com/network/join/fixture", "invite URL extracted")
        try await checkConsole(home: home, service: service)
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
        print("PASS: Codex and console mailboxes, migrations, attachment validation, send flags, service actions, read-only Codex history, and transcript recovery")
    }

    static func checkConversationGroups() throws {
        let sessions = [
            NetworkSession(address: "noa/chat-one", name: "chat-one", person: "noa", agent: "codex", repo: "chat"),
            NetworkSession(address: "noa/chat-two", name: "chat-two", person: "noa", agent: "claude-code"),
            NetworkSession(address: "li/chat-one", name: "chat-one", person: "li", agent: "codex"),
            NetworkSession(address: "noa/archive", name: "archive", person: "noa", status: "offline")
        ]
        let people = PersonSessions.group(sessions)
        try expect(people.map(\.name) == ["li", "noa"], "agent type never combines different contacts")
        let noa = people.first { $0.name == "noa" }
        try expect(noa?.agents.first { $0.name == "Codex" }?.sessions.map(\.id) == ["noa/chat-one"], "agent group is scoped to the contact")
        try expect(noa?.agents.first { $0.name == "其他会话" }?.sessions.map(\.id) == ["noa/archive"], "offline historical conversations stay reachable")
        try expect(sessions.filter { $0.matches("noa Codex chat") }.map(\.id) == ["noa/chat-one"], "search can match contact, agent and conversation together")
    }

    static func checkConsole(home: URL, service: ReasonService) async throws {
        let firstID = "127C3D3A-EDB3-4E45-AC68-6ED87BA77B06"
        let secondID = "336CBFC5-259F-45B8-8880-E40513F32EC6"
        let state = try SQLiteStore(home.appendingPathComponent(".codex/state_5.sqlite"), readOnly: false)
        _ = try state.rows("CREATE TABLE threads(id TEXT,title TEXT,name TEXT,cwd TEXT,rollout_path TEXT,updated_at INTEGER,archived INTEGER)")
        let work = home.appendingPathComponent("fixture-project", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let transcript = home.appendingPathComponent(".codex/sessions/selected.jsonl")
        try Data().write(to: transcript)
        _ = try state.rows("INSERT INTO threads VALUES(?,?,?,?,?,100,0)", [firstID, "原始标题", "选中的会话", work.path, transcript.path])
        _ = try state.rows("INSERT INTO threads VALUES(?,?,?,?,?,90,1)", [secondID, "同目录会话", "", work.path, ""])
        let gemini = home.appendingPathComponent(".gemini/tmp/project/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: gemini, withIntermediateDirectories: true)
        try Data(#"{"sessionId":"f30283ca19","kind":"session"}"#.utf8).write(to: gemini.appendingPathComponent("session.jsonl"))
        let engine = try SQLiteStore(home.appendingPathComponent(".reason/network/network.db"), readOnly: false)
        _ = try engine.rows("ALTER TABLE sessions ADD COLUMN cwd TEXT DEFAULT '/'")
        _ = try engine.rows("ALTER TABLE sessions ADD COLUMN tier TEXT DEFAULT 'push'")
        let legacy = home.appendingPathComponent("Library/Application Support/Reason Network Console/history.json")
        let record: [String: Any] = ["id": "sent:old-console-send", "teamID": "fixture-team", "peer": "peer/remote",
                                     "body": "legacy console message", "date": 0, "outgoing": false, "status": "已收到", "unread": true,
                                     "files": [["name": "legacy.txt"]]]
        var otherRecord = record
        otherRecord["teamID"] = "different-team"
        otherRecord["id"] = "other-team"
        try JSONSerialization.data(withJSONObject: [record, otherRecord]).write(to: legacy)
        let serverScript = home.appendingPathComponent("socket_fixture.py")
        try #"""
import json, pathlib, socket, sqlite3, sys
home = pathlib.Path(sys.argv[1])
state = home / '.reason/network'
paused = set()
with socket.socket(socket.AF_UNIX) as server:
 server.bind(str(state / 'network.sock'))
 server.listen()
 (home / 'socket-ready').touch()
 while True:
  sock, _ = server.accept()
  with sock, sock.makefile('rb') as reader:
   request = json.loads(reader.readline())
   op = request['op']
   assert op in ('team', 'hook', 'session_participation', 'set_session_participation') or request['key'] == 'cli:reason-network-console'
   if op == 'team': result = {'team_id': 'fixture-team', 'relay_connected': True, 'udp': {'port': 41641}}
   elif op == 'hook':
    if request['agent'] == 'cli':
     assert request['session_id'] == 'reason-network-console'
     assert request['event'] == 'stop' and request['pid'] == int(sys.argv[2])
     result = {'address': 'me/console'}
    else:
     with (home / 'manual-joins.jsonl').open('a') as file:
      file.write(json.dumps(request)+'\n')
     result = {'address': 'me/selected-chat'}
   elif op == 'session_participation':
    result = {'version':1, 'paused':sorted(paused)}
   elif op == 'set_session_participation':
    if request['paused']: paused.add(request['key'])
    else: paused.discard(request['key'])
    result = {'paused':request['paused']}
   elif op == 'inbox':
    assert request['peek']
    result = {'messages':[{'id':'console-reply', 'from':'peer/remote', 'body':'reply to console',
                          'sent_at':1763800000000, 'files':[{'name':'reply.txt'}]}]}
   elif op == 'delivered':
    assert request['ids'] == ['console-reply']
    with sqlite3.connect(state / 'local-ui/messages.sqlite3') as cache:
     assert cache.execute("SELECT id FROM events WHERE id='console-reply'").fetchone()
    (home / 'console-acknowledged').touch()
    result = {}
   sock.sendall((json.dumps({'id': request['id'], 'ok': True, 'result': result}) + '\n').encode())
"""#.write(to: serverScript, atomically: true, encoding: .utf8)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [serverScript.path, home.path, String(ProcessInfo.processInfo.processIdentifier)]
        let exited = DispatchSemaphore(value: 0)
        server.terminationHandler = { _ in exited.signal() }
        let stopServer = {
            if server.isRunning { server.terminate() }
            _ = exited.wait(timeout: .now() + 2)
        }
        try server.run()
        defer { stopServer() }
        let ready = home.appendingPathComponent("socket-ready")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try expect(FileManager.default.fileExists(atPath: ready.path), "socket fixture ready")
        let inventory = try await service.personalSessions()
        let localChats = inventory.filter { $0.nativeID != nil }
        try expect(localChats.count == 2 && localChats.first?.title == "选中的会话" && localChats.last?.archived == true,
                   "both same-folder Codex sessions are listed with title and archive state")
        try expect(inventory.contains { $0.agent == "gemini" && !$0.canJoin }, "abbreviated Gemini identity is listed without claiming it can be resumed")
        let address = try await service.joinPersonalSession("codex:" + firstID)
        try expect(address == "me/selected-chat", "join reports the address returned by the daemon")
        let joinLog = try String(contentsOf: home.appendingPathComponent("manual-joins.jsonl"), encoding: .utf8)
        let event = try JSONSerialization.jsonObject(with: Data(joinLog.utf8)) as? [String: Any]
        try expect(event?["session_id"] as? String == firstID && event?["transcript"] as? String == transcript.resolvingSymlinksInPath().path &&
                   event?["mail"] as? Bool == false && !joinLog.contains(secondID), "only the explicitly selected identity is sent to the daemon")
        let left = try await service.leavePersonalSession("codex:fixture")
        try expect(left == "me/local", "exit returns the selected address")
        let afterLeaving = try await service.personalSessions()
        try expect(afterLeaving.first { $0.id == "codex:fixture" }?.connection == .paused("me/local"), "paused status comes from the daemon")
        let resumed = try await service.joinPersonalSession("codex:fixture")
        try expect(resumed == "me/local", "a connection-key-only session can be allowed to reconnect")
        let codex = try await service.snapshot(local: "local", peer: "peer/remote")
        try expect(codex.consoleUnread == 2 && codex.team?.udp?.port == 41641, "console mail and diagnostic details available while using Codex")
        let page = try await service.snapshot(local: "console", peer: "peer/remote", limit: 1)
        try expect(page.hasEarlierMessages && page.messages.map(\.body) == ["reply to console"], "older console messages are paginated")
        try expect(page.conversations.first?.unread == 2, "restored and new console unread counts")
        let snapshot = try await service.snapshot(local: "console", peer: "peer/remote")
        try expect(snapshot.messages.map(\.body) == ["legacy console message", "reply to console"], "console replies and matching legacy history")
        try expect(snapshot.messages.last?.attachments.first?.name == "reply.txt", "console attachments decoded")
        try expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("console-acknowledged").path), "console acknowledges only after persistence")
        let viewed = try await service.snapshot(local: "console", peer: "peer/remote", viewingConversation: true)
        try expect(viewed.consoleUnread == 0, "viewing the console thread clears app unread state")
        let seenAgain = try await service.snapshot(local: "console", peer: "peer/remote")
        try expect(seenAgain.consoleUnread == 0, "repeated delivery does not mark read messages unread again")
        _ = try await service.send(local: "console", to: "peer/remote", body: "from console")
        let sent = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("sent.json"))) as! [String: Any]
        try expect(sent["args"] as? [String] == ["--from", "cli:reason-network-console", "peer/remote", "-"], "original console mailbox identity sent")
    }
}
