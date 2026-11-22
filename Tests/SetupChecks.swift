import Foundation

@main
struct SetupChecks {
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NetworkError("FAIL: " + message) }
    }
    static func reject(_ value: String) throws {
        do { _ = try SetupInput.invitation(value); throw NetworkError("FAIL: accepted " + value) }
        catch let e as NetworkError where e.message.hasPrefix("FAIL:") { throw e }
        catch { }
    }
    @MainActor static func checkModel() async throws {
        let service = SimulatedSetup()
        let model = SetupModel(service: service)
        await model.check()
        try expect(model.checked && !model.snapshot.installed, "new machine opens setup")
        await model.install()
        try expect(model.step == 1 && !model.busy, "installation progresses to network entry")
        model.invitation = "maple-ocean-piano-silver"; model.name = "fixture"
        await model.join()
        try expect(model.snapshot.ready && model.invitation.isEmpty, "success clears invite credentials")
        try expect(model.error != nil, "ambiguous join timeout is reported even if membership was established")
    }
    static func main() async throws {
        let token = "rn1-" + String(repeating: "abc_012-", count: 10)
        try expect(SetupInput.invitation("Join the Reason Network: https://reasonmachines.com/network/join/#" + token) == token, "invite line normalizes to a ticket")
        try expect(SetupInput.invitation("maple-ocean-piano-silver") == "maple-ocean-piano-silver", "one-time code")
        for value in ["", "--help", "$(touch /tmp/unsafe)", "https://evil.test/network/join/#" + token,
                      "https://reasonmachines.com@evil.test/network/join/#" + token,
                      "http://reasonmachines.com/network/join/#" + token,
                      "https://reasonmachines.com:8443/network/join/#" + token] { try reject(value) }
        try expect(!SetupInput.redacted("request " + token).contains(token), "errors redact invites")
        do { _ = try SetupInput.name("--name"); throw NetworkError("FAIL: option name accepted") }
        catch let e as NetworkError where e.message.hasPrefix("FAIL:") { throw e }
        catch { }

        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("reason-setup-checks-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let service = SetupService(home: home)
        let empty = await service.inspect()
        try expect(!empty.installed && !empty.joined, "missing dependencies detected without creating configuration")
        try expect(!fm.fileExists(atPath: home.appendingPathComponent(".reason").path), "inspection of empty machine writes no state")
        let bin = home.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("reason-network")
        let script = #"""
#!/usr/bin/python3
import sys,json,os,pathlib
h=pathlib.Path(os.environ['HOME'])
cmd=sys.argv[1]
if cmd=='who':
 print(json.dumps({'team':'Fixture' if (h/'joined').exists() else None,'person':'fixture','machine':'test','sessions':[],'machines':[]}))
elif cmd=='setup':
 (h/'.codex').mkdir(exist_ok=True)
 (h/'.codex/config.toml').write_text('[mcp_servers.reason-network]\ncommand="reason-network"')
 folder=h/'Library/LaunchAgents';folder.mkdir(parents=True,exist_ok=True)
 (folder/'com.reasonmachines.network.plist').write_text('fixture')
elif cmd=='join':
 (h/'joined').write_text('yes')
 (h/'arguments.json').write_text(json.dumps(sys.argv[2:]))
 print('{}')
else:
 sys.exit(2)
"""#
        try Data(script.utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try await service.install() // An existing engine must never be downloaded over.
        try expect(try String(contentsOf: executable, encoding: .utf8) == script, "existing binary retained")
        try await service.configure()
        let configured = await service.inspect()
        try expect(configured.installed && configured.background && configured.wired && !configured.joined, "verified configuration remains distinct from membership")
        try await service.join(invitation: token, name: "fixture")
        let ready = await service.inspect()
        try expect(ready.ready, "complete configuration ready")
        let arguments = try JSONDecoder().decode([String].self, from: Data(contentsOf: home.appendingPathComponent("arguments.json")))
        try expect(arguments == [token, "--as", "fixture", "--no-setup", "--json"], "join uses exact argument vector without a shell")
        do { try await service.join(invitation: token, name: "other"); throw NetworkError("FAIL: replaced existing network") }
        catch let e as NetworkError where e.message.hasPrefix("FAIL:") { throw e }
        catch { }
        let managed = home.appendingPathComponent(".reason/bin")
        try fm.createDirectory(at: managed, withIntermediateDirectories: true)
        try fm.moveItem(at: executable, to: managed.appendingPathComponent("reason-network"))
        try expect(NetworkPaths.executable(home: home)?.path == managed.appendingPathComponent("reason-network").path, "official managed engine is detected")
        let stillReady = await service.inspect()
        try expect(stillReady.ready, "managed installation works")
        try await checkModel()
        print("PASS: first-run detection, installer idempotency, managed paths, safe invitation parsing, setup verification, join arguments, existing-team protection, and ambiguous completion")
    }
}

actor SimulatedSetup: SetupServicing {
    var state = SetupSnapshot()
    func inspect() -> SetupSnapshot { state }
    func install() { state.installed = true }
    func configure() { state.background = true; state.wired = true; state.codex = true }
    func join(invitation: String, name: String) throws {
        state.joined = true; state.team = "Fixture"
        throw NetworkError("response timed out")
    }
}
