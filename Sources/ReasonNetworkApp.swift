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
    @StateObject private var model = NetworkModel()
    @AppStorage("displayAppearance") private var appearance = DisplayAppearance.system
    var body: some Scene {
        Window("Reason Network", id: "main") {
            AppRootView().environmentObject(model)
                .preferredColorScheme(appearance.scheme)
        }
        .defaultSize(width: 940, height: 780)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .toolbar) {
                Picker("外观", selection: $appearance) {
                    ForEach(DisplayAppearance.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }.pickerStyle(.menu)
                Button("刷新 Network") { Task { await model.refresh() } }.keyboardShortcut("r")
            }
        }
    }
}
