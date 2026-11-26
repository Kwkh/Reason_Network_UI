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
        await model.start()
        await model.start()
        let launchCount = await service.launchCount
        try expect(launchCount == 1, "check services once on first presentation")
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
        let launchctl = home.appendingPathComponent("launchctl-fixture")
        let control = #"""
#!/bin/sh
echo "$1" >> "$HOME/control.log"
case "$1" in
  bootstrap) if [ -f "$HOME/fail-next" ]; then /bin/rm "$HOME/fail-next"; exit 1; fi; touch "$HOME/running"; /bin/rm -f "$HOME/stale-worker";;
  bootout) /bin/rm -f "$HOME/running";;
  print) test -e "$HOME/running";;
esac
"""#
        try control.write(to: launchctl, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launchctl.path)
        let embedded = URL(fileURLWithPath: CommandLine.arguments[1])
        let installer = ParticipationInstaller(home: home, binary: embedded, launchctl: launchctl, probe: { root, _ in
            let running = FileManager.default.fileExists(atPath: home.appendingPathComponent("running").path)
            return running && (root.lastPathComponent == "network" || !FileManager.default.fileExists(atPath: home.appendingPathComponent("stale-worker").path))
        })
        let service = SetupService(home: home, installer: installer, setupHelper: home.appendingPathComponent(".local/bin/reason-network"))
        let empty = await service.inspect()
        try expect(!empty.installed && !empty.joined, "missing dependencies detected without creating configuration")
        try expect(!fm.fileExists(atPath: home.appendingPathComponent(".reason").path), "inspection of empty machine writes no state")
        let bin = home.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("reason-network")
        try await service.install()
        try expect(fm.contentsEqual(atPath: executable.path, andPath: embedded.path), "new machine installed the bundled CLI")
        try fm.removeItem(at: executable)
        let script = #"""
#!/usr/bin/python3
import sys,json,os,pathlib,plistlib
h=pathlib.Path(os.environ['HOME'])
cmd=sys.argv[1]
if cmd=='--version': print('reason-network 0.12.17')
elif cmd=='who':
 print(json.dumps({'team':'Fixture' if (h/'joined').exists() else None,'person':'fixture','machine':'test','sessions':[],'machines':[]}))
elif cmd=='setup-app-agents':
 assert sys.argv[2:4] == ['--cli', sys.argv[0]]
 (h/'setup-args.json').write_text(json.dumps(sys.argv[2:]))
 (h/'.dsh').mkdir(exist_ok=True)
 folder=h/'Library/LaunchAgents';folder.mkdir(parents=True,exist_ok=True)
 if '--no-service' not in sys.argv:
  (folder/'com.reasonmachines.network.plist').write_bytes(plistlib.dumps({'Label':'com.reasonmachines.network','ProgramArguments':[sys.argv[0],'daemon','--service'],'KeepAlive':True}))
  (h/'running').touch()
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
        fm.createFile(atPath: home.appendingPathComponent("fail-next").path, contents: Data())
        do { try await service.configure(); throw NetworkError("FAIL: activation unexpectedly succeeded") }
        catch let e as NetworkError where e.message.hasPrefix("FAIL:") { throw e }
        catch { }
        try expect(!installer.configured && installer.probe(home, embedded), "failed migration restores original job and reloads service")
        try await service.configure()
        let configured = await service.inspect()
        try expect(configured.installed && configured.background && configured.wired && !configured.joined, "verified configuration remains distinct from membership")
        try expect(configured.wiredAgents == ["dsh"] && !fm.fileExists(atPath: home.appendingPathComponent(".codex").path), "dsh alone passes first-run setup")
        // A Codex config which merely mentions the server must not count.
        let codex = home.appendingPathComponent(".codex")
        try fm.createDirectory(at: codex, withIntermediateDirectories: true)
        let config = codex.appendingPathComponent("config.toml")
        try "# [mcp_servers.reason-network]".write(to: config, atomically: true, encoding: .utf8)
        let commented = await service.inspect()
        try expect(commented.wiredAgents == ["dsh"], "commented-out servers do not satisfy setup")
        let quotedPath = String(decoding: try JSONEncoder().encode(executable.path), as: UTF8.self)
            .replacingOccurrences(of: "\\/", with: "/")
        try ("[mcp_servers.reason-network]\ncommand = " + quotedPath + "\nargs = [\"mcp\"]\n")
            .write(to: config, atomically: true, encoding: .utf8)
        let hook = ["hooks": ["SessionStart": [["hooks": [["command": executable.path + " hook codex session-start"]]]]]]
        try JSONSerialization.data(withJSONObject: hook, options: [.withoutEscapingSlashes])
            .write(to: codex.appendingPathComponent("hooks.json"))
        let multiple = await service.inspect()
        try expect(multiple.wiredAgents == ["codex", "dsh"], "configured Codex and dsh are both recognized")
        try fm.removeItem(at: codex)
        let plist = home.appendingPathComponent("Library/LaunchAgents/com.reasonmachines.network.plist")
        let data = try Data(contentsOf: plist)
        guard let installed = NetworkPaths.workspaceExecutable(home: home) else { throw NetworkError("Missing installed backend") }
        try expect(installed.lastPathComponent == "reason-network" && installed.deletingLastPathComponent().lastPathComponent.count == 16, "stable daemon filename inside its build directory")
        let legacy = installed.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("reason-network-" + installed.deletingLastPathComponent().lastPathComponent)
        try fm.copyItem(at: installed, to: legacy)
        var oldJob = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        oldJob["ProgramArguments"] = [legacy.path, "daemon", "--service"]
        try PropertyListSerialization.data(fromPropertyList: oldJob, format: .xml, options: 0).write(to: plist)
        let legacyState = await service.inspect()
        try expect(legacyState.needsBackendUpdate && legacyState.participation, "healthy legacy install offers name migration")
        try await service.updateAtLaunch()
        try expect(try Data(contentsOf: plist) == data && fm.fileExists(atPath: legacy.path), "name migration keeps rollback binary")
        let log = home.appendingPathComponent("control.log")
        let before = try Data(contentsOf: log)
        try expect(configured.participation && installer.configured, "compatible background installed and probed")
        try await service.configure()
        try expect(try Data(contentsOf: log) == before, "repair does not restart healthy daemon")
        // Disk already names the new binary. The old workspace socket is still serving.
        let root = home.appendingPathComponent(".reason/workspaces").appendingPathComponent(UUID().uuidString)
        let workspaceJob = ParticipationInstaller.workspaceJob(home: home, root: root, binary: installed)
        let worker = plist.deletingLastPathComponent().appendingPathComponent((workspaceJob["Label"] as! String) + ".plist")
        try PropertyListSerialization.data(fromPropertyList: workspaceJob, format: .xml, options: 0).write(to: worker)
        try Data().write(to: home.appendingPathComponent("stale-worker"))
        let mixed = await service.inspect()
        try expect(mixed.needsBackendUpdate, "workspace actually serving the wrong build is detected")
        let controls = try String(contentsOf: log, encoding: .utf8)
        try await service.updateAtLaunch()
        let changes = try String(contentsOf: log, encoding: .utf8).dropFirst(controls.count).split(separator: "\n")
        try expect(changes.filter { $0 == "bootout" }.count == 1, "only the stale workspace restarts")
        let repaired = await service.inspect()
        try expect(!repaired.needsBackendUpdate, "all processes and configurations match the bundled build")
        let repairedLog = try Data(contentsOf: log)
        try await service.updateAtLaunch()
        try expect(try Data(contentsOf: log) == repairedLog, "next launch leaves healthy workers running")
        var olderApp = installer
        olderApp.appBuild = installer.appBuild - 1
        olderApp.binary = executable // different bundled bytes, as in an older disk image
        try await olderApp.activate()
        try expect(try Data(contentsOf: log) == repairedLog, "opening an older app cannot roll back the newer backend")
        let setupArguments = try JSONDecoder().decode([String].self, from: Data(contentsOf: home.appendingPathComponent("setup-args.json")))
        try expect(setupArguments == ["--cli", executable.path, "--no-service"] && (try Data(contentsOf: plist)) == data, "repair retains participation daemon")
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
    private(set) var launchCount = 0
    func updateAtLaunch() { launchCount += 1 }
    func inspect() -> SetupSnapshot { state }
    func install() { state.installed = true }
    func configure() { state.participation = true; state.background = true; state.wiredAgents = ["dsh"] }
    func join(invitation: String, name: String) throws {
        state.joined = true; state.team = "Fixture"
        throw NetworkError("response timed out")
    }
}
