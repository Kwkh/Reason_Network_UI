import SwiftUI

@MainActor
final class SetupModel: ObservableObject {
    @Published private(set) var snapshot = SetupSnapshot()
    @Published private(set) var checked = false
    @Published private(set) var busy = false
    @Published private(set) var activity = "正在检查…"
    @Published private(set) var error: InterfaceMessage?
    @Published var presented = false
    @Published var invitation = ""
    @Published var name = NSUserName()
    private let service: any SetupServicing
    init(service: any SetupServicing = SetupService()) { self.service = service }

    var step: Int {
        if !snapshot.installed || !snapshot.background || !snapshot.participation || !snapshot.wired { return 0 }
        if !snapshot.joined { return 1 }
        return 2
    }
    func didLeave() {
        snapshot.joined = false
        snapshot.team = nil
        snapshot.sessions = 0
        snapshot.issue = nil
        presented = false
        invitation = ""
        error = nil
    }
    func check() async {
        guard !busy else { return }
        busy = true; activity = "正在检查…"
        snapshot = await service.inspect()
        checked = true; busy = false
    }
    func install() async {
        await perform("正在安装内置后台…") {
            try await self.service.install()
            self.activity = "正在配置后台与会话…"
            try await self.service.configure()
        }
    }
    func configure() async {
        await perform("正在配置后台…") { try await self.service.configure() }
    }
    func join() async {
        // Validate before starting any process. Never persist invite credentials.
        do { _ = try SetupInput.invitation(invitation); _ = try SetupInput.name(name) }
        catch { self.error = InterfaceMessage { error.localizedDescription }; return }
        let invite = invitation, person = name
        await perform("正在加入 Network…") {
            try await self.service.join(invitation: invite, name: person)
        }
        if snapshot.joined { invitation = "" }
    }
    private func perform(_ label: String, operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; activity = label; error = nil
        defer { busy = false }
        do { try await operation() }
        catch { self.error = InterfaceMessage { SetupInput.redacted(error.localizedDescription) } }
        // Always check after failure too: joining may have succeeded before a timeout.
        snapshot = await service.inspect()
        checked = true
    }
}
