import Foundation

@main
struct CoreChecks {
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NetworkError("FAIL: " + message) }
    }
    static func main() async throws {
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
elif sys.argv[1]=='doctor': print('fixture healthy')
"""#
        let cli = home.appendingPathComponent(".local/bin/reason-network")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let service = ReasonService(home: home)
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
