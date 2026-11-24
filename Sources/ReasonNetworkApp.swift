import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidBecomeActive(_ notification: Notification) {
        for window in NSApp.windows where window.canBecomeMain {
            window.titlebarSeparatorStyle = .none
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        return true
    }
}
private enum DisplayAppearance: String, CaseIterable {
    case system = "跟随系统", light = "浅色", dark = "深色"

    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@main
struct ReasonNetworkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var workspaces = WorkspaceController()
    @AppStorage("displayAppearance") private var appearance = DisplayAppearance.system
    var body: some Scene {
        Window("Reason Network", id: "main") {
            AppRootView().environmentObject(workspaces).environmentObject(workspaces.current)
                .environment(\.locale, L10n.shared.locale)
                .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                    L10n.shared.refreshSystemLanguage()
                }
                .preferredColorScheme(appearance.scheme)
        }
        .defaultSize(width: 940, height: 780)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            SidebarCommands()
            CommandMenu("Connect") {
                ConnectionMenuItems(model: workspaces.current)
            }
            CommandMenu("Receive") {
                ReceiveMenuItems(model: workspaces.current)
            }
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .toolbar) {
                Picker(L10n.text("外观"), selection: $appearance) {
                    ForEach(DisplayAppearance.allCases, id: \.self) { option in
                        Text(L10n.text(option.rawValue)).tag(option)
                    }
                }.pickerStyle(.menu)
                Button(L10n.text("刷新 Network")) { Task { await workspaces.current.refresh() } }.keyboardShortcut("r")
            }
        }
    }
}

private struct ConnectionMenuItems: View {
    @ObservedObject var model: NetworkModel

    var body: some View {
        let network = model.directory?.networkID
        Button(L10n.text("全部接入"), systemImage: "personalhotspot") {
            if let network { Task { await model.changeAllConnections(network: network, disconnect: false) } }
        }
        .keyboardShortcut("1", modifiers: [.command, .option])
        .disabled(network == nil || model.connectionTargets(disconnect: false).isEmpty)
        Button(L10n.text("全部断开"), systemImage: "personalhotspot.slash") {
            if let network { Task { await model.changeAllConnections(network: network, disconnect: true) } }
        }
        .keyboardShortcut("0", modifiers: [.command, .option])
        .disabled(network == nil || model.connectionTargets(disconnect: true).isEmpty)
    }
}

private struct ReceiveMenuItems: View {
    @ObservedObject var model: NetworkModel

    var body: some View {
        let network = model.directory?.networkID
        Group {
            Button(L10n.text("全部设为手动接收"), systemImage: "arrow.down.circle") {
                if let network { Task { await model.changeAllReceiveModes(.pull, network: network) } }
            }
            .keyboardShortcut("2", modifiers: [.command, .option])
            Button(L10n.text("全部设为即时推送"), systemImage: "bolt.horizontal.circle") {
                if let network { Task { await model.changeAllReceiveModes(.push, network: network) } }
            }
            .keyboardShortcut("3", modifiers: [.command, .option])
        }
        .disabled(network == nil || model.onlineReceiveTargets.isEmpty)
    }
}
